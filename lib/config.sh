#!/usr/bin/env bash
# ==============================================================================
#  lib/config.sh - 配置初始化 + 由 users.db 渲染 xray config.json + 安全落地
#  渲染管线:  users.db + vpnx.conf + profiles  ->  config.json(临时)
#             -> xray -test 校验  ->  备份 last-good  ->  原子替换
#  任何一步失败都保持原配置不变, 因此不会把节点改挂
# ==============================================================================

is_num() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# 该账号此刻是否应出现在配置里
config_user_valid() {
    local enabled="$1" expire="$2" quota="$3" up="$4" down="$5" used now
    is_true "$enabled" || return 1
    now="$(now_epoch)"
    if is_num "$expire" && [ "$expire" -gt 0 ]; then
        [ "$now" -ge "$expire" ] && return 1
    fi
    if is_num "$quota" && [ "$quota" -gt 0 ]; then
        used=$(( ${up:-0} + ${down:-0} ))
        [ "$used" -ge "$quota" ] && return 1
    fi
    return 0
}

# 协议是否属于该账号的 protocols 列表(csv)
proto_in() {
    local csv="$1" want="$2" p
    [ -z "$csv" ] && return 1
    for p in $(printf '%s' "$csv" | tr ',' ' '); do
        [ "$p" = "$want" ] && return 0
    done
    return 1
}

# 内部协议名 -> 入站 tag / 统计 email 后缀
proto_tag() {
    case "$1" in
        reality) printf 'in-reality' ;;
        ss)      printf 'in-ss' ;;
        vmess)   printf 'in-vmess' ;;
        xhttp)   printf 'in-xhttp' ;;
        *)       printf '' ;;
    esac
}
proto_suffix() {
    case "$1" in
        reality) printf 'r' ;;
        ss)      printf 's' ;;
        vmess)   printf 'w' ;;
        xhttp)   printf 'x' ;;
        *)       printf '' ;;
    esac
}
user_email() { printf '%s@%s' "$1" "$(proto_suffix "$2")"; }

# 老核心用 tcp, 新核心(>=25) 规范名是 raw
xray_network_default() {
    local v
    v="$(xray_installed_version 2>/dev/null)"
    if [ -n "$v" ] && version_ge "$v" "25.0.0"; then
        printf 'raw'
    else
        printf 'tcp'
    fi
}

# XHTTP 传输的名称与配置字段名随内核版本变化: 老核心叫 splithttp, >=25 叫 xhttp
#   版本检测失败时按"新内核"处理 —— 现在安装的都是 v25+, 用新名字更不容易出错;
#   另外 apply_config 在校验失败时会设 VPNX_XHTTP_ALT=1 强制换另一套再试一次。
_xhttp_use_modern() {
    local v style
    style="$(cfg_get XHTTP_KEY_STYLE '')"
    [ "$style" = "legacy" ] && return 1
    [ "$style" = "modern" ] && return 0
    [ "${VPNX_XHTTP_ALT:-0}" = "1" ] && return 1
    v="$(xray_installed_version 2>/dev/null)"
    if [ -n "$v" ] && ! version_ge "$v" "25.0.0"; then
        return 1
    fi
    return 0
}
xray_xhttp_net() {
    if _xhttp_use_modern; then printf 'xhttp'; else printf 'splithttp'; fi
}
xray_xhttp_key() {
    if _xhttp_use_modern; then printf 'xhttpSettings'; else printf 'splithttpSettings'; fi
}

# ---------------------------------------------------------------------------
# 初始化 /etc/vpnx/vpnx.conf (已存在则不覆盖)
# ---------------------------------------------------------------------------
cfg_init() {
    ensure_dirs

    if [ ! -f "$VPNX_CONF" ]; then
        local net host
        host="$(hostname 2>/dev/null || echo vps)"
        net="$(xray_network_default)"
        if [ "${DRY_RUN:-0}" = "1" ]; then
            printf '%s[dry-run]%s 创建 %s\n' "$C_DIM" "$C_RST" "$VPNX_CONF"
        else
            cat > "$VPNX_CONF" <<EOF
# vpnx 节点配置(自动生成, 可手工微调后执行 vpnx policy apply 或 vpnx install 重新渲染)
VPNX_CONF_VERSION=1
NODE_NAME=$host
PUBLIC_IP=
XRAY_VERSION=
XRAY_VERSION_REQUESTED=
XRAY_TEST_ARGS=-test -config

# --- VLESS + REALITY (主协议, 无需域名与证书) ---
REALITY_ENABLED=1
REALITY_PORT=
REALITY_TARGET=www.bing.com:443
REALITY_SNI=www.bing.com
XHTTP_ENABLED=0
XHTTP_PORT=
XHTTP_PATH=/vpnx-xhttp
XHTTP_MODE=auto
XHTTP_HOST=
XHTTP_KEY_STYLE=
UPGRADE_ENABLED=1
REALITY_PRIVATE_KEY=
REALITY_PUBLIC_KEY=
REALITY_SHORT_IDS=
REALITY_NETWORK=$net
REALITY_FLOW=xtls-rprx-vision
REALITY_FINGERPRINT=chrome
REALITY_SPX=/

# --- Shadowsocks 2022 (备用协议, 密码学更现代) ---
SS_ENABLED=0
SS_PORT=
SS_METHOD=2022-blake3-aes-128-gcm
SS_SERVER_PSK=
SS_NETWORK=tcp,udp

# --- VMess + WebSocket (老客户端兼容) ---
VMESS_ENABLED=0
VMESS_PORT=
VMESS_PATH=/vpnx-ws
VMESS_HOST=

# --- 通用 ---
LISTEN_ADDR=0.0.0.0
API_PORT=$XRAY_API_PORT_DEFAULT
LOG_LEVEL=warning
DEFAULT_PROTOCOLS=reality
SNIFFING=0
IPV6=0
ENABLE_BBR=1

# --- 中台同步 ---
SYNC_ENABLED=0
SYNC_URL=
SYNC_NODE_ID=
SYNC_TOKEN=
SYNC_INTERVAL=60
SYNC_INSECURE=0
SUB_BASE_URL=
SUB_SERVE=0
SUB_PORT=
AGENT_LAST_SYNC=0
AGENT_LAST_RESULT=
POLICY_REVISION=0
EOF
            chmod 600 "$VPNX_CONF"
        fi
    fi
    # 账号库
    if [ ! -f "$VPNX_USERS_DB" ]; then
        if [ "${DRY_RUN:-0}" != "1" ]; then
            cat > "$VPNX_USERS_DB" <<'EOF'
# vpnx 账号库: 一行一个账号, 字段用 | 分隔, 顺序固定如下(不要手工改字段数):
# name|uuid|enabled|expire_epoch|quota_bytes|used_up|used_down|speed_mbps|max_devices|protocols|ss_user_psk|sub_token|created_epoch|note
# protocols: reality,ss,vmess 的组合; expire_epoch=0 表示永不过期; quota_bytes=0 表示不限流量
EOF
            chmod 600 "$VPNX_USERS_DB"
        fi
    fi
    # 默认档位
    profile_init_defaults
    return 0
}

# ---------------------------------------------------------------------------
# 渲染
# ---------------------------------------------------------------------------
# 生成某协议的 clients 片段
_render_clients() {
    local proto="$1" out="$2" count=0
    local name uuid enabled expire quota up down speed devices protos sspsk sub created note email
    : > "$out"
    [ -f "$VPNX_USERS_DB" ] || return 0
    while IFS='|' read -r name uuid enabled expire quota up down speed devices protos sspsk sub created note; do
        case "$name" in
            ''|\#*) continue ;;
        esac
        proto_in "$protos" "$proto" || continue
        config_user_valid "$enabled" "$expire" "$quota" "$up" "$down" || continue
        email="$(user_email "$name" "$proto")"
        case "$proto" in
            reality)
                [ "$count" -gt 0 ] && printf ',\n' >> "$out"
                printf '            {"id": "%s", "email": "%s", "flow": "%s"}' \
                    "$uuid" "$email" "${REALITY_FLOW_R}" >> "$out"
                ;;
            ss)
                [ "$count" -gt 0 ] && printf ',\n' >> "$out"
                printf '            {"password": "%s", "email": "%s", "level": 0}' \
                    "$sspsk" "$email" >> "$out"
                ;;
            vmess)
                [ "$count" -gt 0 ] && printf ',\n' >> "$out"
                printf '            {"id": "%s", "email": "%s", "alterId": 0}' \
                    "$uuid" "$email" >> "$out"
                ;;
            xhttp)
                # XHTTP 与 xtls-rprx-vision 不能同时用: 这一档 flow 必须留空
                [ "$count" -gt 0 ] && printf ',\n' >> "$out"
                printf '            {"id": "%s", "email": "%s"}' \
                    "$uuid" "$email" >> "$out"
                ;;
        esac
        count=$((count + 1))
    done < "$VPNX_USERS_DB"
    return 0
}

# render_config [输出文件]
render_config() {
    local out="${1:-$VPNX_XRAY_CONF}"
    local tmpd="${VPNX_TMP_DIR}/render"
    ensure_dir "$tmpd"

    local r_enabled r_port r_target r_sni r_priv r_ids r_net r_flow r_fp r_spx
    local s_enabled s_port s_method s_psk s_net
    local v_enabled v_port v_path v_host
    local x_enabled x_port x_path x_mode x_host
    local listen api_port log_level sniffing ipv6 def_protos

    r_enabled="$(cfg_get REALITY_ENABLED 1)"
    r_port="$(cfg_get REALITY_PORT '')"
    r_target="$(cfg_get REALITY_TARGET 'www.bing.com:443')"
    r_sni="$(cfg_get REALITY_SNI 'www.bing.com')"
    r_priv="$(cfg_get REALITY_PRIVATE_KEY '')"
    r_ids="$(cfg_get REALITY_SHORT_IDS '')"
    r_net="$(cfg_get REALITY_NETWORK "$(xray_network_default)")"
    r_flow="$(cfg_get REALITY_FLOW 'xtls-rprx-vision')"
    r_fp="$(cfg_get REALITY_FINGERPRINT 'chrome')"
    r_spx="$(cfg_get REALITY_SPX '/')"

    s_enabled="$(cfg_get SS_ENABLED 0)"
    s_port="$(cfg_get SS_PORT '')"
    s_method="$(cfg_get SS_METHOD '2022-blake3-aes-128-gcm')"
    s_psk="$(cfg_get SS_SERVER_PSK '')"
    s_net="$(cfg_get SS_NETWORK 'tcp,udp')"

    v_enabled="$(cfg_get VMESS_ENABLED 0)"
    v_port="$(cfg_get VMESS_PORT '')"
    v_path="$(cfg_get VMESS_PATH '/vpnx-ws')"
    v_host="$(cfg_get VMESS_HOST '')"

    # VLESS + XHTTP + REALITY(与 reality 共用同一套 REALITY 密钥/shortIds, 只是换了传输层)
    x_enabled="$(cfg_get XHTTP_ENABLED 0)"
    x_port="$(cfg_get XHTTP_PORT '')"
    x_path="$(cfg_get XHTTP_PATH '/vpnx-xhttp')"
    x_mode="$(cfg_get XHTTP_MODE 'auto')"
    x_host="$(cfg_get XHTTP_HOST '')"

    listen="$(cfg_get LISTEN_ADDR '0.0.0.0')"
    api_port="$(cfg_get API_PORT "$XRAY_API_PORT_DEFAULT")"
    log_level="$(cfg_get LOG_LEVEL warning)"
    sniffing="$(cfg_get SNIFFING 0)"
    ipv6="$(cfg_get IPV6 0)"
    def_protos="$(cfg_get DEFAULT_PROTOCOLS 'reality')"

    [ "$ipv6" = "1" ] && listen="::"

    # 没有启用任何协议 -> 至少要求 reality
    if ! is_true "$r_enabled" && ! is_true "$s_enabled" && ! is_true "$v_enabled" && ! is_true "$x_enabled"; then
        log_warn "所有协议都被禁用, 强制启用 REALITY"
        r_enabled=1
    fi
    if is_true "$r_enabled" && { [ -z "$r_port" ] || [ -z "$r_priv" ]; }; then
        log_err "REALITY 端口或私钥缺失, 请先执行 vpnx install 或 vpnx policy apply"
        return 1
    fi
    if is_true "$s_enabled" && { [ -z "$s_port" ] || [ -z "$s_psk" ]; }; then
        log_err "SS2022 端口或服务端密钥缺失"
        return 1
    fi
    if is_true "$v_enabled" && [ -z "$v_port" ]; then
        log_err "VMess 端口缺失"
        return 1
    fi
    if is_true "$x_enabled" && { [ -z "$x_port" ] || [ -z "$r_priv" ]; }; then
        log_err "XHTTP 端口或 REALITY 私钥缺失(XHTTP+REALITY 复用 REALITY 密钥)"
        return 1
    fi

    # REALITY clients 的 flow(客户端与入站值一致)
    REALITY_FLOW_R="$r_flow"

    local frag_r="$tmpd/clients.reality" frag_s="$tmpd/clients.ss" frag_v="$tmpd/clients.vmess" frag_x="$tmpd/clients.xhttp"
    _render_clients reality "$frag_r"
    _render_clients ss "$frag_s"
    _render_clients vmess "$frag_v"
    _render_clients xhttp "$frag_x"

    local body="$tmpd/config.body.json"
    {
        printf '{\n'
        printf '  "log": {"loglevel": "%s", "access": "%s/access.log", "error": "%s/error.log"},\n' \
            "$log_level" "$VPNX_LOG_DIR" "$VPNX_LOG_DIR"
        printf '  "api": {"tag": "api", "services": ["HandlerService", "StatsService", "LoggerService"]},\n'
        printf '  "stats": {},\n'
        printf '  "policy": {\n'
        printf '    "levels": {\n'
        printf '      "0": {"handshake": 4, "connIdle": 300, "uplinkOnly": 1, "downlinkOnly": 1,'
        printf ' "statsUserUplink": true, "statsUserDownlink": true, "statsUserOnline": true}\n'
        printf '    },\n'
        printf '    "system": {"statsInboundUplink": true, "statsInboundDownlink": true}\n'
        printf '  },\n'

        # ---------------- inbounds ----------------
        printf '  "inbounds": [\n'
        printf '    {\n'
        printf '      "tag": "api",\n'
        printf '      "listen": "127.0.0.1",\n'
        printf '      "port": %s,\n' "$api_port"
        printf '      "protocol": "dokodemo-door",\n'
        printf '      "settings": {"address": "127.0.0.1"}\n'
        printf '    }'

        if is_true "$r_enabled"; then
            printf ',\n    {\n'
            printf '      "tag": "%s",\n' "$(proto_tag reality)"
            printf '      "listen": "%s",\n' "$listen"
            printf '      "port": %s,\n' "$r_port"
            printf '      "protocol": "vless",\n'
            printf '      "settings": {\n'
            printf '        "clients": [\n'
            cat "$frag_r"
            printf '\n        ],\n'
            printf '        "decryption": "none"\n'
            printf '      },\n'
            printf '      "streamSettings": {\n'
            printf '        "network": "%s",\n' "$r_net"
            printf '        "security": "reality",\n'
            printf '        "realitySettings": {\n'
            printf '          "show": false,\n'
            printf '          "target": "%s",\n' "$r_target"
            printf '          "xver": 0,\n'
            printf '          "serverNames": ["%s"],\n' "$r_sni"
            printf '          "privateKey": "%s",\n' "$r_priv"
            printf '          "shortIds": [%s],\n' "$(_render_short_ids "$r_ids")"
            printf '          "maxTimeDiff": 0\n'
            printf '        }\n'
            printf '      },\n'
            printf '      "sniffing": {"enabled": %s, "destOverride": ["http", "tls"]}\n' \
                "$(_json_bool "$sniffing")"
            printf '    }'
        fi

        if is_true "$s_enabled"; then
            printf ',\n    {\n'
            printf '      "tag": "%s",\n' "$(proto_tag ss)"
            printf '      "listen": "%s",\n' "$listen"
            printf '      "port": %s,\n' "$s_port"
            printf '      "protocol": "shadowsocks",\n'
            printf '      "settings": {\n'
            printf '        "method": "%s",\n' "$s_method"
            printf '        "password": "%s",\n' "$s_psk"
            printf '        "network": "%s",\n' "$s_net"
            printf '        "clients": [\n'
            cat "$frag_s"
            printf '\n        ]\n'
            printf '      },\n'
            printf '      "sniffing": {"enabled": %s, "destOverride": ["http", "tls"]}\n' \
                "$(_json_bool "$sniffing")"
            printf '    }'
        fi

        if is_true "$v_enabled"; then
            printf ',\n    {\n'
            printf '      "tag": "%s",\n' "$(proto_tag vmess)"
            printf '      "listen": "%s",\n' "$listen"
            printf '      "port": %s,\n' "$v_port"
            printf '      "protocol": "vmess",\n'
            printf '      "settings": {"clients": [\n'
            cat "$frag_v"
            printf '\n      ]},\n'
            printf '      "streamSettings": {\n'
            printf '        "network": "ws",\n'
            printf '        "wsSettings": {"path": "%s"%s}\n' \
                "$v_path" "$(_render_ws_host "$v_host")"
            printf '      },\n'
            printf '      "sniffing": {"enabled": %s, "destOverride": ["http", "tls"]}\n' \
                "$(_json_bool "$sniffing")"
            printf '    }'
        fi

        # VLESS + XHTTP + REALITY(与 in-reality 共用同一套 REALITY 密钥/shortIds)
        #   注意: XHTTP 与 xtls-rprx-vision 不能同时用, 所以这一档 clients 不带 flow
        if is_true "$x_enabled"; then
            printf ',\n    {\n'
            printf '      "tag": "%s",\n' "$(proto_tag xhttp)"
            printf '      "listen": "%s",\n' "$listen"
            printf '      "port": %s,\n' "$x_port"
            printf '      "protocol": "vless",\n'
            printf '      "settings": {\n'
            printf '        "clients": [\n'
            cat "$frag_x"
            printf '\n        ],\n'
            printf '        "decryption": "none"\n'
            printf '      },\n'
            printf '      "streamSettings": {\n'
            printf '        "network": "%s",\n' "$(xray_xhttp_net)"
            printf '        "security": "reality",\n'
            printf '        "realitySettings": {\n'
            printf '          "show": false,\n'
            printf '          "target": "%s",\n' "$r_target"
            printf '          "xver": 0,\n'
            printf '          "serverNames": ["%s"],\n' "$r_sni"
            printf '          "privateKey": "%s",\n' "$r_priv"
            printf '          "shortIds": [%s],\n' "$(_render_short_ids "$r_ids")"
            printf '          "maxTimeDiff": 0\n'
            printf '        },\n'
            printf '        "%s": {"path": "%s", "mode": "%s"%s}\n' \
                "$(xray_xhttp_key)" "$x_path" "$x_mode" "$(_render_xhttp_host "$x_host")"
            printf '      },\n'
            printf '      "sniffing": {"enabled": %s, "destOverride": ["http", "tls"]}\n' \
                "$(_json_bool "$sniffing")"
            printf '    }'
        fi
        printf '\n  ],\n'

        # ---------------- outbounds ----------------
        printf '  "outbounds": [\n'
        printf '    {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4v6"}},\n'
        printf '    {"tag": "block", "protocol": "blackhole", "settings": {}}\n'
        printf '  ],\n'

        # ---------------- routing ----------------
        # 不依赖 geoip.dat, 直接用内网网段, 避免数据文件缺失导致启动失败
        printf '  "routing": {\n'
        printf '    "domainStrategy": "AsIs",\n'
        printf '    "rules": [\n'
        printf '      {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},\n'
        printf '      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"}\n'
        printf '    ]\n'
        printf '  }\n'
        printf '}\n'
    } > "$body"

    # geoip 数据存在时用 geoip:private, 否则换成显式私有网段
    if [ ! -f "$XRAY_ASSET_DIR/geoip.dat" ]; then
        sed -i 's|"ip": \["geoip:private"\]|"ip": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16", "::1/128", "fc00::/7", "fe80::/10"]|' "$body" 2>/dev/null || true
    fi

    if [ "$out" = "-" ]; then
        cat "$body"
    else
        cp -f "$body" "$out"
    fi
    log_debug "已渲染配置 -> $out"
    return 0
}

_json_bool() { is_true "$1" && printf 'true' || printf 'false'; }

_render_short_ids() {
    local ids="$1" out="" first=1 i
    for i in $(printf '%s' "$ids" | tr ',' ' '); do
        [ -z "$i" ] && continue
        [ "$first" = "1" ] || out="$out, "
        out="$out\"$i\""
        first=0
    done
    [ -z "$out" ] && out="\"\""
    printf '%s' "$out"
}

_render_ws_host() {
    local h="$1"
    [ -z "$h" ] && { printf ''; return 0; }
    printf ', "host": "%s"' "$h"
}

# xhttpSettings 的 host 字段(空则省略)
_render_xhttp_host() {
    local h="$1"
    [ -z "$h" ] && { printf ''; return 0; }
    printf ', "host": "%s"' "$h"
}

# ---------------------------------------------------------------------------
# 落地: 校验 -> then 替换 (+可选重启)
# ---------------------------------------------------------------------------
config_hash() {
    local f="${1:-$VPNX_XRAY_CONF}"
    [ -f "$f" ] || { printf ''; return 0; }
    sha256_file "$f"
}

apply_config() {
    local restart=0 a
    for a in "$@"; do
        case "$a" in
            --restart) restart=1 ;;
        esac
    done

    ensure_dirs
    tmp_init
    local new="$VPNX_TMP_DIR/config.new.json"

    render_config "$new" || return 1

    if ! xray_test "$new"; then
        # XHTTP 的传输/字段名随内核版本变化(xhttp vs splithttp)。版本判断有可能不准,
        # 所以这里做一次"换名重试": 用另一套字段名再渲染一次, 避免整个配置落地失败。
        if [ "${VPNX_XHTTP_ALT:-0}" != "1" ] && is_true "$(cfg_get XHTTP_ENABLED 0)" \
           && grep -q '"network": "xhttp"\|"network": "splithttp"' "$new" 2>/dev/null; then
            log_warn "配置校验失败, 疑似 XHTTP 字段名与内核不匹配, 换另一套字段名重试"
            VPNX_XHTTP_ALT=1
            export VPNX_XHTTP_ALT
            if render_config "$new" && xray_test "$new"; then
                log_ok "换用另一套 XHTTP 字段名后校验通过(已记住该选择)"
                cfg_set XHTTP_KEY_STYLE "legacy"
                unset VPNX_XHTTP_ALT
            else
                unset VPNX_XHTTP_ALT
            fi
        fi
    fi

    if ! xray_test "$new"; then
        log_err "新配置未通过内核校验, 已保留原配置(节点不受影响)"
        cp -f "$new" "$VPNX_STATE_DIR/config.rejected.json" 2>/dev/null || true
        rm -f "$new"
        return 1
    fi

    if [ -f "$VPNX_XRAY_CONF" ] && cmp -s "$new" "$VPNX_XRAY_CONF"; then
        log_debug "配置无变化, 跳过写入"
        rm -f "$new"
    else
        if [ -f "$VPNX_XRAY_CONF" ]; then
            health_snapshot
            backup_file "$VPNX_XRAY_CONF" "autobak" >/dev/null 2>&1 || true
        fi
        if [ "${DRY_RUN:-0}" = "1" ]; then
            printf '%s[dry-run]%s 替换 %s\n' "$C_DIM" "$C_RST" "$VPNX_XRAY_CONF"
        else
            cp -f "$new" "$VPNX_XRAY_CONF"
            chmod 600 "$VPNX_XRAY_CONF" 2>/dev/null || true
        fi
        rm -f "$new"
        log_ok "配置已更新: $VPNX_XRAY_CONF"
    fi

    if vpnx_no_service; then
        log_debug "VPNX_NO_SERVICE=1: 跳过内核启停(仅落地配置)"
        return 0
    fi

    if [ "$restart" = "1" ]; then
        if ! xray_is_running; then
            svc_action start xray >/dev/null 2>&1 || true
            sleep 1
        else
            if ! xray_restart; then
                log_err "内核重启失败, 尝试回滚到上一个可用配置"
                health_rollback && {
                    log_warn "已回滚, 请检查 vpnx health check"
                }
                return 1
            fi
        fi
        if ! xray_is_running; then
            log_err "内核未能启动, 尝试回滚"
            health_rollback
            return 1
        fi
        log_ok "内核已重启并运行"
    else
        # 未运行则拉起
        if ! xray_is_running; then
            svc_action start xray >/dev/null 2>&1 || true
            sleep 1
            xray_is_running && log_ok "内核已启动"
        fi
    fi
    return 0
}

# 状态用: 概览
config_show() {
    require_installed
    local r_enabled r_port s_enabled s_port v_enabled v_port
    r_enabled="$(cfg_get REALITY_ENABLED 1)"
    r_port="$(cfg_get REALITY_PORT '')"
    s_enabled="$(cfg_get SS_ENABLED 0)"
    s_port="$(cfg_get SS_PORT '')"
    v_enabled="$(cfg_get VMESS_ENABLED 0)"
    v_port="$(cfg_get VMESS_PORT '')"
    printf 'REALITY    : %s  端口 %s  target=%s sni=%s  network=%s flow=%s\n' \
        "$([ "$r_enabled" = "1" ] && echo 启用 || echo 停用)" "${r_port:--}" \
        "$(cfg_get REALITY_TARGET)" "$(cfg_get REALITY_SNI)" \
        "$(cfg_get REALITY_NETWORK "$(xray_network_default)")" "$(cfg_get REALITY_FLOW '-')"
    printf 'SS2022     : %s  端口 %s  方法 %s\n' \
        "$([ "$s_enabled" = "1" ] && echo 启用 || echo 停用)" "${s_port:--}" "$(cfg_get SS_METHOD)"
    printf 'VMess-WS   : %s  端口 %s  路径 %s\n' \
        "$([ "$v_enabled" = "1" ] && echo 启用 || echo 停用)" "${v_port:--}" "$(cfg_get VMESS_PATH)"
    printf 'API 端口   : %s (仅 127.0.0.1)\n' "$(cfg_get API_PORT "$XRAY_API_PORT_DEFAULT")"
    printf '默认协议   : %s\n' "$(cfg_get DEFAULT_PROTOCOLS reality)"
    printf 'IPv6 监听  : %s\n' "$(cfg_get IPV6 0)"
}
