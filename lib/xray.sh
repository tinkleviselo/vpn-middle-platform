#!/usr/bin/env bash
# ==============================================================================
#  lib/xray.sh - Xray 内核安装/升级/校验/服务/API 调用 + 通用 JSON 兼容解析
#  关键点:
#    * 单静态二进制, 不依赖 nginx/php/证书
#    * xray api adu/rmu 支持账号热加载(新增不重连, 停用立即踢线)
#    * 老机器没有 jq/python 时, 用 format=lines 协议 + 退化解析
# ==============================================================================

XRAY_RELEASE_BASE="${XRAY_RELEASE_BASE:-https://github.com/XTLS/Xray-core/releases/download}"
XRAY_API_PORT_DEFAULT=10085

# 只渲染配置、不动服务与防火墙(测试/预览用)
vpnx_no_service() { [ "${VPNX_NO_SERVICE:-0}" = "1" ]; }

# ---------------------------------------------------------------------------
# 版本与下载
# ---------------------------------------------------------------------------
xray_asset_name() { printf 'Xray-linux-%s.zip' "$XRAY_ARCH"; }

xray_latest_version() {
    local v=""
    v="$(fetch https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null \
         | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 \
         | sed 's/.*"\([^"]*\)"$/\1/')"
    if [ -z "$v" ] && have_cmd curl; then
        v="$(curl -fsSI -o /dev/null -w '%{redirect_url}' --max-time 20 \
             https://github.com/XTLS/Xray-core/releases/latest 2>/dev/null | sed 's#.*/tag/##')"
    fi
    printf '%s' "$v"
}

xray_installed_version() {
    [ -x "$XRAY_BIN" ] || { printf ''; return 0; }
    "$XRAY_BIN" version 2>/dev/null | head -n1 | awk '{print $2}'
}

xray_extract() {
    local zip="$1" dest="$2"
    ensure_dir "$dest"
    if [ "$HAS_UNZIP" = "1" ]; then
        unzip -oq "$zip" -d "$dest" && return 0
    fi
    if have_cmd bsdtar; then
        bsdtar -xf "$zip" -C "$dest" && return 0
    fi
    if [ "$HAS_PYTHON3" = "1" ]; then
        python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$zip" "$dest" && return 0
    fi
    if [ "$HAS_PYTHON" = "1" ]; then
        python -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$zip" "$dest" && return 0
    fi
    return 1
}

# 校验 Release 摘要文件(.dgst 内含 SHA2-256(...)= <64hex>)
xray_verify_digest() {
    local zip="$1" dgst="$2" want have
    [ -f "$dgst" ] || return 0
    want="$(grep -oE '[0-9a-fA-F]{64}' "$dgst" 2>/dev/null | head -n1 | tr 'A-F' 'a-f')"
    [ -z "$want" ] && return 0
    have="$(sha256_file "$zip" | tr 'A-F' 'a-f')"
    if [ "$want" != "$have" ]; then
        log_err "sha256 校验失败: 期望 $want 实际 $have"
        return 1
    fi
    log_debug "sha256 校验通过: $have"
    return 0
}

# xray_install [版本|latest]
xray_install() {
    local ver="${1:-}" asset url zip dgst tmpdir extracted
    tmp_init
    tmpdir="$VPNX_TMP_DIR/xray-install.$$"
    ensure_dir "$tmpdir" "$XRAY_ASSET_DIR" "$VPNX_STATE_DIR/pkg"

    if [ -z "$ver" ]; then
        ver="$(cfg_get XRAY_VERSION)"
    fi
    case "$ver" in
        ''|latest)
            if [ "${OFFLINE:-0}" = "1" ]; then
                ver=""
            else
                log_info "查询 Xray 最新版本..."
                ver="$(xray_latest_version)"
            fi
            ;;
    esac

    asset="$(xray_asset_name)"
    local cache="$VPNX_STATE_DIR/pkg/$asset"

    if [ "${OFFLINE:-0}" = "1" ] || [ -z "$ver" ]; then
        [ -f "$cache" ] || die "离线安装需要把 $asset 放到 $VPNX_STATE_DIR/pkg/ (当前缺失)"
        zip="$cache"
        log_info "使用本地缓存包: $cache"
    else
        url="$XRAY_RELEASE_BASE/$ver/$asset"
        zip="$tmpdir/$asset"
        dgst="$tmpdir/$asset.dgst"
        log_info "下载 Xray $ver ($XRAY_ARCH_NAME)..."
        if ! download "$url" "$zip" 180; then
            if [ -f "$cache" ]; then
                log_warn "在线下载失败, 回退到本地缓存包"
                zip="$cache"
            else
                die "下载失败: $url (可用 VPNX_MIRROR 指定镜像, 或把包放到 $VPNX_STATE_DIR/pkg/)"
            fi
        fi
        if [ "$zip" != "$cache" ]; then
            download "$url.dgst" "$dgst" 30 >/dev/null 2>&1 || true
            xray_verify_digest "$zip" "$dgst" || die "包校验失败, 已中止(如确认可信可设 VPNX_STRICT_VERIFY=0 跳过)"
            # 留一份缓存, 便于以后离线/回滚
            [ "${DRY_RUN:-0}" != "1" ] && cp -f "$zip" "$cache" 2>/dev/null || true
        fi
    fi

    log_info "解包 $asset ..."
    extracted="$tmpdir/x"
    ensure_dir "$extracted"
    if [ "${DRY_RUN:-0}" != "1" ]; then
        xray_extract "$zip" "$extracted" || die "解包失败(请安装 unzip 或 python)"
        [ -f "$extracted/xray" ] || die "包内未找到 xray 可执行文件"
        install -m 0755 "$extracted/xray" "$XRAY_BIN" 2>/dev/null \
            || { cp -f "$extracted/xray" "$XRAY_BIN" && chmod 755 "$XRAY_BIN"; }
        local f
        for f in geoip.dat geosite.dat; do
            [ -f "$extracted/$f" ] && cp -f "$extracted/$f" "$XRAY_ASSET_DIR/$f"
        done
    else
        printf '%s[dry-run]%s 安装 %s -> %s\n' "$C_DIM" "$C_RST" "$asset" "$XRAY_BIN"
    fi

    # 记录版本
    if [ "${DRY_RUN:-0}" != "1" ]; then
        local got
        got="$(xray_installed_version)"
        [ -n "$got" ] && cfg_set XRAY_VERSION "$got"
        [ -n "$ver" ] && [ "$ver" != "latest" ] && cfg_set XRAY_VERSION_REQUESTED "$ver"
    fi
    xray_test_mode_detect
    log_ok "Xray 已安装: $XRAY_BIN ($(xray_installed_version 2>/dev/null))"
    return 0
}

# 探测可用的配置校验命令形式(不同版本 CLI 有差异)
xray_test_mode_detect() {
    local tmpcfg probe
    XRAY_TEST_ARGS=""
    [ -x "$XRAY_BIN" ] || return 0
    tmp_init
    probe="$VPNX_TMP_DIR/probe.json"
    printf '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}\n' > "$probe" 2>/dev/null
    if "$XRAY_BIN" -test -config "$probe" >/dev/null 2>&1; then
        XRAY_TEST_ARGS="-test -config"
        cfg_set XRAY_TEST_ARGS "-test -config"
    elif "$XRAY_BIN" run -test -config "$probe" >/dev/null 2>&1; then
        XRAY_TEST_ARGS="run -test -config"
        cfg_set XRAY_TEST_ARGS "run -test -config"
    else
        XRAY_TEST_ARGS=""
        log_warn "无法确定配置校验命令形式, 服务单元将不做启动前校验(仍然会在本脚本内校验)"
    fi
    rm -f "$probe" 2>/dev/null || true
    return 0
}

# xray_test <配置文件>  成功返回 0
xray_test() {
    local cfg="$1" out=""
    [ -x "$XRAY_BIN" ] || return 1
    [ -f "$cfg" ] || return 1

    local args="${XRAY_TEST_ARGS:-$(cfg_get XRAY_TEST_ARGS '-test -config')}"
    # shellcheck disable=SC2086
    out="$("$XRAY_BIN" $args "$cfg" 2>&1)"
    if [ $? -eq 0 ]; then
        log_debug "配置校验通过: $cfg"
        return 0
    fi
    # 老核心可能不支持 run 前缀, 再试一次另一种形式
    if [ "$args" = "-test -config" ]; then
        out="$("$XRAY_BIN" run -test -config "$cfg" 2>&1)" || true
    else
        out="$("$XRAY_BIN" -test -config "$cfg" 2>&1)" || true
    fi
    if [ $? -eq 0 ]; then
        return 0
    fi
    log_err "配置校验失败: $cfg"
    printf '%s\n' "$out" | tail -n 6 >&2
    return 1
}

# ---------------------------------------------------------------------------
# 密钥生成
# ---------------------------------------------------------------------------
# 结果写入 REALITY_PRIVATE_KEY / REALITY_PUBLIC_KEY
reality_gen_keys() {
    local out priv pub
    REALITY_PRIVATE_KEY=""; REALITY_PUBLIC_KEY=""
    [ -x "$XRAY_BIN" ] || return 1
    out="$("$XRAY_BIN" x25519 2>/dev/null)"
    priv="$(printf '%s\n' "$out" | grep -i 'private' | head -n1 | awk '{print $NF}')"
    pub="$(printf '%s\n' "$out" | grep -iE 'public|password' | head -n1 | awk '{print $NF}')"
    if [ -z "$priv" ]; then
        # 极老版本只输出两行裸 key
        priv="$(printf '%s\n' "$out" | sed -n '1p' | awk '{print $NF}')"
        pub="$(printf '%s\n' "$out" | sed -n '2p' | awk '{print $NF}')"
    fi
    [ -z "$priv" ] && return 1
    if [ -z "$pub" ]; then
        # 由私钥推导公钥
        out="$("$XRAY_BIN" x25519 -i "$priv" 2>/dev/null)"
        pub="$(printf '%s\n' "$out" | grep -iE 'public|password' | head -n1 | awk '{print $NF}')"
        [ -z "$pub" ] && pub="$(printf '%s\n' "$out" | tail -n1 | awk '{print $NF}')"
    fi
    REALITY_PRIVATE_KEY="$priv"
    REALITY_PUBLIC_KEY="$pub"
    log_debug "REALITY 密钥已生成 (pub=${pub:0:8}...)"
    return 0
}

xray_gen_short_id() { rand_hex 8; }

# SS2022 预共享密钥: 16 字节用于 2022-blake3-aes-128-gcm
ss_gen_psk() {
    local len="${1:-16}"
    openssl rand -base64 "$len" 2>/dev/null | tr -d '\n'
}

# ---------------------------------------------------------------------------
# 服务安装(systemd 兼容降级 / SysV)
# ---------------------------------------------------------------------------
XRAY_SERVICE_NAME="xray"

xray_service_install() {
    local test_args unit="/etc/systemd/system/xray.service"
    test_args="${XRAY_TEST_ARGS:-$(cfg_get XRAY_TEST_ARGS '')}"

    if vpnx_no_service; then
        log_info "VPNX_NO_SERVICE=1: 跳过服务单元安装(只渲染配置)"
        return 0
    fi

    if [ "$HAS_SYSTEMD" = "1" ]; then
        if [ "${DRY_RUN:-0}" != "1" ]; then
            {
                printf '[Unit]\n'
                printf 'Description=vpnx Xray Service (VLESS-REALITY / SS2022 / VMess-WS)\n'
                printf 'Documentation=https://github.com/XTLS/Xray-core\n'
                printf 'After=network.target nss-lookup.target\n'
                printf 'Wants=network-online.target\n'
                printf '\n[Service]\n'
                printf 'Type=simple\n'
                printf 'User=root\n'
                printf 'Environment=XRAY_LOCATION_ASSET=%s\n' "$XRAY_ASSET_DIR"
                if [ -n "$test_args" ]; then
                    printf 'ExecStartPre=%s %s %s\n' "$XRAY_BIN" "$test_args" "$VPNX_XRAY_CONF"
                fi
                printf 'ExecStart=%s run -config %s\n' "$XRAY_BIN" "$VPNX_XRAY_CONF"
                printf 'Restart=on-failure\n'
                printf 'RestartSec=3\n'
                printf 'LimitNOFILE=1048576\n'
                # systemd >= 229 才支持 NoNewPrivileges/AmbientCapabilities
                if systemd_ver_ge 229; then
                    printf 'NoNewPrivileges=true\n'
                fi
                printf '\n[Install]\n'
                printf 'WantedBy=multi-user.target\n'
            } > "$unit"
            chmod 644 "$unit"
        else
            printf '%s[dry-run]%s 写入 %s\n' "$C_DIM" "$C_RST" "$unit"
        fi
        svc_daemon_reload
        svc_enable "$XRAY_SERVICE_NAME"
        log_ok "systemd 服务已就绪: xray.service (systemd $SYSTEMD_VER)"
    else
        # SysV init.d 降级路径(CentOS6 / 无 systemd 的老系统)
        if [ "${DRY_RUN:-0}" != "1" ]; then
            cat > "/etc/init.d/$XRAY_SERVICE_NAME" <<EOF
#!/bin/sh
# vpnx Xray SysV init (自动生成, chkconfig: 2345 85 15)
# chkconfig: 2345 85 15
# description: vpnx Xray Service
### BEGIN INIT INFO
# Provides:          xray
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
### END INIT INFO
XRAY_BIN="$XRAY_BIN"
CONF="$VPNX_XRAY_CONF"
PIDFILE="$VPNX_RUN_DIR/xray.pid"
LOG="$VPNX_LOG_DIR/xray.out.log"
export XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR"

is_running() {
    [ -f "\$PIDFILE" ] || return 1
    pid="\$(cat "\$PIDFILE" 2>/dev/null)"
    [ -n "\$pid" ] || return 1
    kill -0 "\$pid" 2>/dev/null
}

case "\$1" in
    start)
        if is_running; then echo "xray 已在运行"; exit 0; fi
        mkdir -p "\$(dirname "\$PIDFILE")" "\$(dirname "\$LOG")"
        nohup "\$XRAY_BIN" run -config "\$CONF" >> "\$LOG" 2>&1 &
        echo \$! > "\$PIDFILE"
        sleep 1
        if is_running; then echo "xray 已启动 (pid \$(cat \$PIDFILE))"; else echo "xray 启动失败, 见 \$LOG"; exit 1; fi
        ;;
    stop)
        if is_running; then
            kill "\$(cat "\$PIDFILE")" 2>/dev/null
            i=0
            while is_running && [ \$i -lt 10 ]; do sleep 1; i=\$((i+1)); done
            is_running && kill -9 "\$(cat "\$PIDFILE")" 2>/dev/null
            rm -f "\$PIDFILE"
            echo "xray 已停止"
        else
            echo "xray 未运行"
        fi
        ;;
    restart)
        "\$0" stop; sleep 1; "\$0" start
        ;;
    status)
        if is_running; then echo "xray 运行中 (pid \$(cat \$PIDFILE))"; exit 0; else echo "xray 未运行"; exit 3; fi
        ;;
    *)
        echo "用法: \$0 {start|stop|restart|status}"
        exit 2
        ;;
esac
exit 0
EOF
            chmod 755 "/etc/init.d/$XRAY_SERVICE_NAME"
        else
            printf '%s[dry-run]%s 写入 /etc/init.d/%s\n' "$C_DIM" "$C_RST" "$XRAY_SERVICE_NAME"
        fi
        svc_enable "$XRAY_SERVICE_NAME"
        log_ok "SysV 服务已就绪: /etc/init.d/xray (降级模式)"
    fi
    return 0
}

xray_service_remove() {
    svc_action stop "$XRAY_SERVICE_NAME" >/dev/null 2>&1 || true
    svc_disable "$XRAY_SERVICE_NAME"
    run rm -f /etc/systemd/system/xray.service "/etc/init.d/$XRAY_SERVICE_NAME"
    svc_daemon_reload
    return 0
}

xray_is_running() { svc_is_active "$XRAY_SERVICE_NAME"; }

# 内核实际监听的 TCP 端口
#  用途: 发现"配置里写的是 A 端口, 但运行中的内核监听的是 B 端口"这种不一致
#        (典型场景: 改了端口/重装过端口, 但内核没重启)
xray_listen_ports() {
    local out=""
    if [ "$HAS_SS" = "1" ]; then
        out="$(ss -Hlntp 2>/dev/null | grep -F 'xray' | awk '{print $4}' | sed 's/.*://' | sort -n | uniq | tr '\n' ' ')"
    fi
    if [ -z "$out" ] && [ "$HAS_LSOF" = "1" ]; then
        out="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '/xray/ {print $9}' | sed 's/.*://' | sort -n | uniq | tr '\n' ' ')"
    fi
    printf '%s' "$(printf '%s' "$out" | sed 's/[[:space:]]*$//')"
    return 0
}

xray_restart() {
    if vpnx_no_service; then
        log_debug "VPNX_NO_SERVICE=1: 跳过内核重启"
        return 0
    fi
    svc_action restart "$XRAY_SERVICE_NAME" >/dev/null 2>&1
    sleep 1
    xray_is_running
}

# ---------------------------------------------------------------------------
# API 调用(热加载账号 / 流量统计 / 在线设备)
# ---------------------------------------------------------------------------
api_server() { printf '127.0.0.1:%s' "$(cfg_get API_PORT "$XRAY_API_PORT_DEFAULT")"; }

api_ready() {
    [ -x "$XRAY_BIN" ] || return 1
    "$XRAY_BIN" api statsquery --server="$(api_server)" -pattern "vpnx-probe" >/dev/null 2>&1
}

# 向入站热添加用户: api_add_user_file <入站tag> <含inbounds的json文件>
api_add_user_file() {
    local tag="$1" file="$2"
    [ -f "$file" ] || return 1
    "$XRAY_BIN" api adu --server="$(api_server)" -timeout 5 "$file" >/dev/null 2>&1
}

# 从入站移除用户: api_remove_user <入站tag> <email>
api_remove_user() {
    local tag="$1" email="$2"
    "$XRAY_BIN" api rmu --server="$(api_server)" -timeout 5 -tag="$tag" "$email" >/dev/null 2>&1
}

# 查询入站用户
api_inbound_users() {
    local tag="$1"
    "$XRAY_BIN" api inbounduser --server="$(api_server)" -timeout 5 -tag="$tag" 2>/dev/null
}

api_inbound_user_count() {
    local tag="$1"
    "$XRAY_BIN" api inboundusercount --server="$(api_server)" -timeout 5 -tag="$tag" 2>/dev/null
}

# 流量统计(不重置, 由我们自己算增量, 上报失败可重放)
api_statsquery() {
    local pattern="${1:-user>>>}"
    "$XRAY_BIN" api statsquery --server="$(api_server)" -timeout 5 -pattern "$pattern" 2>/dev/null
}

# 在线用户与 IP(用于设备数限制)
api_online_iplist() {
    "$XRAY_BIN" api statsonlineiplist --server="$(api_server)" -timeout 5 -all -include-traffic 2>/dev/null
}

api_online_user_count() {
    "$XRAY_BIN" api statsonline --server="$(api_server)" -timeout 5 2>/dev/null
}

# ---------------------------------------------------------------------------
# 通用 JSON 兼容解析(供 agent 策略 / profile 档位复用)
#   后端优先级: jq > python3 > python > 退化(仅支持极简扁平结构)
# ---------------------------------------------------------------------------
json_backend() {
    if [ "$HAS_JQ" = "1" ]; then printf 'jq'; return 0; fi
    if [ "$HAS_PYTHON3" = "1" ]; then printf 'python3'; return 0; fi
    if [ "$HAS_PYTHON" = "1" ]; then printf 'python'; return 0; fi
    printf 'none'
}

# 把 JSON 扁平化成 key=value 行(数组用下标, 如 users.0.name=x)
# json_flatten <文件或->
json_flatten() {
    local src="$1" backend
    backend="$(json_backend)"
    case "$backend" in
        jq)
            jq -r 'paths(scalars) as $p | "\($p|map(tostring)|join("."))=\(getpath($p))"' "$src" 2>/dev/null
            ;;
        python3|python)
            "$backend" -c '
import json,sys
def walk(o, p, out):
    if isinstance(o, dict):
        for k in o: walk(o[k], (p + "." + str(k)) if p else str(k), out)
    elif isinstance(o, list):
        for i, v in enumerate(o): walk(v, (p + "." + str(i)) if p else str(i), out)
    else:
        if isinstance(o, bool): v = "true" if o else "false"
        elif o is None: v = ""
        else: v = str(o)
        out.append(p + "=" + v)
data = json.load(sys.stdin)
out = []
walk(data, "", out)
sys.stdout.write("\n".join(out) + ("\n" if out else ""))
' < "$src"
            ;;
        *)
            # 退化: 只处理 "key": "value" / "key": 123 这类扁平结构
            tr -d '\r' < "$src" | tr -d ' ' | sed 's/[{}]//g' | tr ',' '\n' \
                | sed -n 's/^"\([^"]*\)":\("\)\?\([^"]*\)\("\)\?$/\1=\3/p'
            ;;
    esac
}

# 解析内核在线 IP 列表 -> email|设备数(每个 email 一行)
#
#   stats onlineiplist 的输出格式随版本变化(JSON 或表格文本), 这里做"格式无关"解析:
#     · 同一行里同时出现 email 与 ip  -> 本行的 ip 都算给本行的 email(表格形态)
#     · 只有 ip 的行                 -> 算给"最近出现的 email"(JSON 嵌套形态)
#   纯 awk 实现, 不依赖 jq / python(很多精简系统两者都没有, 之前的 json_flatten
#   退化分支只认扁平 JSON, 结果设备数超限永远检测不到, 静默跳过)。
online_ips_parse() {
    local src="$1"
    [ -s "$src" ] || return 0
    awk '
    function is_email(t) {
        return (t ~ /^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$/)
    }
    function is_ip(t) {
        if (t ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]{1,5})?$/) return 1
        if (t ~ /^\[[0-9a-fA-F:]{2,}\]/) return 1
        if (t ~ /^[0-9a-fA-F]{0,4}(:[0-9a-fA-F]{0,4}){3,}$/) return 1
        return 0
    }
    {
        n = split($0, tok, /[^A-Za-z0-9@._:\[\]-]+/)
        ne = 0; ni = 0
        for (i = 1; i <= n; i++) {
            t = tok[i]
            if (t == "") continue
            if (is_email(t)) { em[++ne] = t }
            else if (is_ip(t)) { ip[++ni] = t }
        }
        if (ne > 0) last = em[ne]
        if (ne > 0 && ni > 0) {
            for (e = 1; e <= ne; e++) for (k = 1; k <= ni; k++) cnt[em[e]]++
        } else if (ni > 0 && last != "") {
            cnt[last] += ni
        }
    }
    END { for (e in cnt) printf "%s|%d\n", e, cnt[e] }
    ' "$src" 2>/dev/null
}

# json_get <文件> <点号路径>   (无解析器时返回退化结果)
json_get() {
    local src="$1" path="$2" backend val
    backend="$(json_backend)"
    case "$backend" in
        jq) jq -r --arg p "$path" 'getpath($p|split(".")) | if . == null then "" else tostring end' "$src" 2>/dev/null ;;
        python3|python)
            "$backend" -c '
import json,sys
path = sys.argv[1].split(".")
data = json.load(sys.stdin)
for k in path:
    if isinstance(data, list):
        try: data = data[int(k)]
        except Exception: data = None
    elif isinstance(data, dict):
        data = data.get(k)
    else:
        data = None
    if data is None: break
if data is None: sys.stdout.write("")
elif isinstance(data, bool): sys.stdout.write("true" if data else "false")
else: sys.stdout.write(str(data))
' "$path" < "$src"
            ;;
        *)
            # 退化解析(无 jq/python): 直接按"路径最后一段键名"取值。
            #   profile / 策略这类结构里键名基本唯一(params.flow / params.path / name / type ...),
            #   比 json_flatten 的退化分支可靠 —— 后者只认扁平 JSON, 嵌套字段永远取不到,
            #   表现为 profile list / 档位参数读取静默失败。
            local key="${path##*.}"
            [ -n "$key" ] || return 1
            tr -d '\r\n' < "$src" 2>/dev/null \
                | sed 's/[[:space:]][[:space:]]*/ /g' \
                | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\(\"[^\"]*\"\|[^,}]*\)" \
                | head -n1 \
                | sed 's/^[^:]*:[[:space:]]*//; s/^"//; s/"[[:space:]]*$//; s/[[:space:]]*$//'
            ;;
    esac
}

# 从流量统计 JSON 解析出 email|uplink|downlink (每行一条)
stats_parse_users() {
    local src="$1" backend
    backend="$(json_backend)"
    case "$backend" in
        jq)
            jq -r '.stat[]? | select(.name|test("^user>>>")) | "\(.name)|\(.value)"' "$src" 2>/dev/null
            ;;
        python3|python)
            "$backend" -c '
import json,sys
data = json.load(sys.stdin)
for s in data.get("stat", []) or []:
    n = s.get("name", "")
    if n.startswith("user>>>"):
        sys.stdout.write(n + "|" + str(s.get("value", "0")) + "\n")
' < "$src"
            ;;
        *)
            # 退化解析(无 jq/python): 逐 token 扫描 —— 见到 user>>> 开头的名字就记住,
            # 见到纯数字就与它配对输出。这样对四种形态都成立:
            #   "value": 5014 / "value":5014 / "value":"5014" / 名字与数值分行
            #   (真实内核是第一种; 之前的正则写法在引号/空格形态之间反复出错)
            tr -d '\r\n' < "$src" \
                | sed 's/}[[:space:]]*,[[:space:]]*{/}\n{/g' \
                | awk '
                    {
                        n = split($0, t, /[^A-Za-z0-9>@._-]+/)
                        for (i = 1; i <= n; i++) {
                            s = t[i]
                            if (s == "") continue
                            if (s ~ /^user>>>/) { cur = s; continue }
                            if (s ~ /^[0-9]+$/ && cur != "") print cur "|" s
                        }
                    }
                  '
            ;;
    esac
}
