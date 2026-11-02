#!/usr/bin/env bash
# ==============================================================================
#  lib/profile.sh - 加密与传输"档位"(profile)管理
#  目的: 把 REALITY target/SNI、传输方式、SS2022 加密方法等参数做成可热更新的
#        档位文件, 中台下发新档位 -> 校验(可选签名) -> 应用 -> 重渲染 -> 平滑重启,
#        从而在不升级节点脚本的前提下持续更换加密/伪装策略。
#  格式: JSON(嵌套或扁平均可), 关键字段:
#        name / type / version_min / description / signature / params.*
#        支持用签名(ed25519, openssl dgst -sha256 -verify)校验来源
# ==============================================================================

PROFILE_TRUST_PUB="$VPNX_ETC/trusted_pub.pem"

profile_dir_init() { ensure_dir "$VPNX_PROFILE_DIR"; }

# 内置档位(首次安装时写入; 已存在则不覆盖, 避免覆盖中台下发的版本)
profile_init_defaults() {
    profile_dir_init
    local net
    net="$(xray_network_default)"

    _profile_write_if_absent reality-vision <<EOF
{
  "name": "reality-vision",
  "type": "vless-reality",
  "version_min": "1.8.0",
  "description": "VLESS + REALITY + XTLS Vision, 借用真实站点 TLS 握手, 无需域名与证书",
  "signature": "",
  "params": {
    "network": "$net",
    "flow": "xtls-rprx-vision",
    "fingerprint": "chrome",
    "spx": "/",
    "target": "www.bing.com:443",
    "sni": "www.bing.com",
    "mldsa65": "0"
  }
}
EOF

    _profile_write_if_absent ss2022 <<EOF
{
  "name": "ss2022",
  "type": "ss2022",
  "version_min": "1.8.0",
  "description": "Shadowsocks 2022 (多用户), 仅支持 2022-blake3-aes-*-gcm",
  "signature": "",
  "params": {
    "method": "2022-blake3-aes-128-gcm",
    "network": "tcp,udp"
  }
}
EOF

    _profile_write_if_absent vmess-ws <<EOF
{
  "name": "vmess-ws",
  "type": "vmess-ws",
  "version_min": "1.4.0",
  "description": "VMess + WebSocket, 用于兼容很老的客户端(无 REALITY 支持)",
  "signature": "",
  "params": {
    "path": "/vpnx-ws",
    "alter_id": "0",
    "host": ""
  }
}
EOF

    # VLESS + XHTTP + REALITY: 与 reality-vision 共用同一套 REALITY 密钥/伪装站点,
    # 只是把传输层换成 XHTTP。注意 flow 必须为空(XHTTP 与 xtls-rprx-vision 互斥)。
    _profile_write_if_absent xhttp-reality <<EOF
{
  "name": "xhttp-reality",
  "type": "vless-xhttp",
  "version_min": "25.0.0",
  "description": "VLESS + XHTTP + REALITY, 直连即可用(无需域名/证书/CDN), 传输层更像普通 HTTP",
  "signature": "",
  "params": {
    "transport": "xhttp",
    "path": "/vpnx-xhttp",
    "mode": "auto",
    "flow": "",
    "fingerprint": "chrome",
    "spx": "/",
    "target": "www.bing.com:443",
    "sni": "www.bing.com"
  }
}
EOF
    return 0
}

_profile_write_if_absent() {
    local name="$1"
    local f="$VPNX_PROFILE_DIR/$name.json"
    if [ -f "$f" ]; then
        return 0
    fi
    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '%s[dry-run]%s 写入档位 %s\n' "$C_DIM" "$C_RST" "$f"
        cat > /dev/null
        return 0
    fi
    atomic_write "$f" 600
    return 0
}

profile_path() { printf '%s/%s.json' "$VPNX_PROFILE_DIR" "$1"; }
profile_exists() { [ -f "$(profile_path "$1")" ]; }

# profile_get <名字> <点号路径>  (先按嵌套解析, 再兼容扁平写法)
profile_get() {
    local name="$1" key="$2" f v
    f="$(profile_path "$name")"
    [ -f "$f" ] || { printf ''; return 0; }
    v="$(json_get "$f" "$key")"
    if [ -z "$v" ]; then
        # 扁平写法兜底: "params.network": "raw"
        v="$(sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$f" 2>/dev/null | head -n1)"
    fi
    printf '%s' "$v"
}

profile_type() { profile_get "$1" type; }

# profile_add <文件>  —— 校验 + (可选)验签 + 落地
profile_add() {
    local src="$1" name
    [ -f "$src" ] || die "档位文件不存在: $src"
    profile_validate "$src" || die "档位文件校验失败: $src"
    name="$(json_get "$src" name)"
    [ -z "$name" ] && name="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$src" | head -n1)"
    [ -z "$name" ] && die "档位文件缺少 name 字段"

    if ! profile_verify_signature "$src"; then
        die "档位签名校验失败, 拒绝安装(如需信任该来源, 请把对应公钥放到 $PROFILE_TRUST_PUB)"
    fi

    profile_dir_init
    backup_file "$(profile_path "$name")" "profile" >/dev/null 2>&1 || true
    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '%s[dry-run]%s 安装档位 %s\n' "$C_DIM" "$C_RST" "$name"
    else
        cp -f "$src" "$(profile_path "$name")"
        chmod 600 "$(profile_path "$name")"
    fi
    log_ok "档位已安装: $name ($(profile_type "$name"))"
    return 0
}

# 可选签名校验: 有 trust 公钥就必须验; 无公钥时, 若文件带 signature 则拒绝
profile_verify_signature() {
    local src="$1" sig f tmp
    sig="$(json_get "$src" signature)"
    if [ -z "$sig" ]; then
        return 0
    fi
    if [ ! -f "$PROFILE_TRUST_PUB" ]; then
        log_err "档位带签名但本机没有可信公钥($PROFILE_TRUST_PUB)"
        return 1
    fi
    tmp_init
    f="$VPNX_TMP_DIR/profile.sig.bin"
    printf '%s' "$sig" | openssl base64 -d -A > "$f" 2>/dev/null || return 1
    # 用去掉 signature 的内容验签
    local body="$VPNX_TMP_DIR/profile.body.json"
    grep -v '"signature"' "$src" > "$body" 2>/dev/null || cp -f "$src" "$body"
    if openssl dgst -sha256 -verify "$PROFILE_TRUST_PUB" -signature "$f" "$body" >/dev/null 2>&1; then
        log_ok "档位签名校验通过"
        return 0
    fi
    return 1
}

# 基本结构校验(不依赖 jq)
profile_validate() {
    local src="$1" t
    [ -f "$src" ] || return 1
    grep -q '"name"' "$src" || { log_err "缺少 name"; return 1; }
    t="$(json_get "$src" type)"
    [ -z "$t" ] && t="$(sed -n 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$src" | head -n1)"
    case "$t" in
        vless-reality|ss2022|vmess-ws) ;;
        '') log_err "缺少 type"; return 1 ;;
        *)  log_err "未知档位类型: $t (支持 vless-reality / ss2022 / vmess-ws)"; return 1 ;;
    esac
    return 0
}

profile_list() {
    profile_dir_init
    profile_init_defaults          # 保证内置档位存在(空目录也能正确列出)
    local f name t desc
    printf '%-18s %-14s %s\n' "档位名" "类型" "说明"
    printf '%-18s %-14s %s\n' "------------------" "--------------" "----"
    for f in "$VPNX_PROFILE_DIR"/*.json; do
        [ -f "$f" ] || continue
        name="$(basename "$f" .json)"
        t="$(json_get "$f" type)"
        desc="$(json_get "$f" description)"
        printf '%-18s %-14s %s\n' "$name" "${t:--}" "${desc:--}"
    done
    return 0
}

profile_show() {
    local name="$1" f
    f="$(profile_path "$name")"
    [ -f "$f" ] || die "档位不存在: $name"
    if [ "$HAS_JQ" = "1" ]; then
        jq . "$f"
    else
        cat "$f"
    fi
    printf '\n--- 解析出的关键参数 ---\n'
    local k
    for k in type params.network params.flow params.method params.target params.sni params.path params.fingerprint; do
        printf '%-20s = %s\n' "$k" "$(profile_get "$name" "$k")"
    done
    return 0
}

# profile_apply <名字>  —— 把档位参数写进 vpnx.conf 并重渲染
profile_apply() {
    local name="$1" t
    profile_exists "$name" || die "档位不存在: $name"
    t="$(profile_type "$name")"
    log_info "应用档位 $name (类型 $t)"

    case "$t" in
        vless-reality)
            local network flow fp spx target sni
            network="$(profile_get "$name" params.network)"
            flow="$(profile_get "$name" params.flow)"
            fp="$(profile_get "$name" params.fingerprint)"
            spx="$(profile_get "$name" params.spx)"
            target="$(profile_get "$name" params.target)"
            sni="$(profile_get "$name" params.sni)"
            [ -n "$network" ] && cfg_set REALITY_NETWORK "$network"
            [ -n "$flow" ]    && cfg_set REALITY_FLOW "$flow"
            [ -n "$fp" ]      && cfg_set REALITY_FINGERPRINT "$fp"
            [ -n "$spx" ]     && cfg_set REALITY_SPX "$spx"
            [ -n "$target" ]  && cfg_set REALITY_TARGET "$target"
            [ -n "$sni" ]     && cfg_set REALITY_SNI "$sni"
            cfg_set REALITY_ENABLED 1
            ;;
        ss2022)
            local method net psk len
            method="$(profile_get "$name" params.method)"
            net="$(profile_get "$name" params.network)"
            [ -n "$method" ] && cfg_set SS_METHOD "$method"
            [ -n "$net" ]    && cfg_set SS_NETWORK "$net"
            psk="$(cfg_get SS_SERVER_PSK '')"
            if [ -z "$psk" ]; then
                case "$method" in
                    *aes-128-gcm*) len=16 ;;
                    *)             len=32 ;;
                esac
                psk="$(ss_gen_psk "$len")"
                cfg_set SS_SERVER_PSK "$psk"
                log_info "已生成 SS2022 服务端预共享密钥"
            fi
            cfg_set SS_ENABLED 1
            ;;
        vmess-ws)
            local path host
            path="$(profile_get "$name" params.path)"
            host="$(profile_get "$name" params.host)"
            [ -n "$path" ] && cfg_set VMESS_PATH "$path"
            [ -n "$host" ] && cfg_set VMESS_HOST "$host"
            cfg_set VMESS_ENABLED 1
            ;;
        *)
            die "不支持的档位类型: $t"
            ;;
    esac

    apply_config --restart || die "档位应用失败(配置未通过校验或内核启动失败)"
    log_ok "档位 $name 已生效"
    return 0
}

# ---------------------------------------------------------------------------
# CLI: vpnx profile list|show|add|apply|verify
# ---------------------------------------------------------------------------
cmd_profile() {
    local sub="${1:-list}"
    if [ $# -gt 0 ]; then shift; fi
    require_root
    case "$sub" in
        list) profile_list ;;
        show)
            [ -n "${1:-}" ] || die "用法: vpnx profile show <档位名>"
            profile_show "$1"
            ;;
        add)
            [ -n "${1:-}" ] || die "用法: vpnx profile add <文件>"
            require_installed
            profile_add "$1"
            ;;
        apply)
            [ -n "${1:-}" ] || die "用法: vpnx profile apply <档位名>"
            require_installed
            profile_apply "$1"
            ;;
        verify)
            [ -n "${1:-}" ] || die "用法: vpnx profile verify <文件>"
            profile_validate "$1" && profile_verify_signature "$1" \
                && log_ok "校验通过" || die "校验失败"
            ;;
        *)
            printf '用法: vpnx profile list|show <名>|add <文件>|apply <名>|verify <文件>\n'
            return 2
            ;;
    esac
}
