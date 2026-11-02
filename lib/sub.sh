#!/usr/bin/env bash
# ==============================================================================
#  lib/sub.sh - 分享链接与订阅生成(Base64 列表 / Clash Meta / sing-box 元数据)
#  订阅思路: 节点生成 -> 推送到中台(推荐) 或 本机内置订阅服务(可选)
#            客户端(小火箭 / Clash / sing-box / v2rayN)只访问中台或本机订阅 URL
# ==============================================================================

# 对外展示用的主机名/IP
sub_public_host() {
    local h
    h="$(cfg_get PUBLIC_IP '')"
    if [ -z "$h" ]; then
        h="$(detect_public_ip)"
        [ -n "$h" ] && cfg_set PUBLIC_IP "$h"
    fi
    [ -z "$h" ] && h="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo 127.0.0.1)"
    printf '%s' "$h"
}

sub_token_ensure() {
    local name="$1" tok
    tok="$(user_field "$name" $USER_F_SUBTOKEN)"
    if [ -z "$tok" ]; then
        tok="$(rand_hex 16)"
        user_set_field "$name" $USER_F_SUBTOKEN "$tok"
    fi
    printf '%s' "$tok"
}

# 备注名(客户端里显示的节点名)
# 协议显示名(给客户端看的)
_sub_proto_label() {
    case "${1:-}" in
        reality) printf 'REALITY' ;;
        ss)      printf 'SS2022' ;;
        vmess)   printf 'VMESS-WS' ;;
        xhttp)   printf 'XHTTP' ;;
        *)       printf '%s' "${1:-}" ;;
    esac
}
sub_tag() {
    local name="$1" proto="$2" label
    # 显示名: 优先用中台下发的名字, 其次用本机 NODE_NAME, 都没有就只显示协议。
    # 注意: 绝不回退到 hostname / 节点ID / 账号名 —— 这些属于敏感信息。
    label="${VPNX_SUB_LABEL:-}"
    local node_name hn hf
    node_name="$(cfg_get NODE_NAME '')"
    hn="$(hostname 2>/dev/null)"
    hf="$(hostname -f 2>/dev/null)"
    # 只接受"人工起的名字": 等于 hostname 或带点(域名/反查域名)的都算敏感信息, 一律不用
    if [ -n "$node_name" ] && [ "$node_name" != "$hn" ] && [ "$node_name" != "$hf" ]; then
        case "$node_name" in
            *.*) ;;
            *) label="$node_name" ;;
        esac
    fi
    if [ -n "$label" ]; then
        printf '%s %s' "$label" "$(_sub_proto_label "$proto")"
    else
        printf '%s' "$(_sub_proto_label "$proto")"
    fi
}

# ---------------------------------------------------------------------------
# 单账号链接
# ---------------------------------------------------------------------------
sub_links() {
    local name="$1"
    local host uuid sspsk protos p
    user_exists "$name" || { log_err "账号不存在: $name"; return 1; }
    host="$(sub_public_host)"
    uuid="$(user_field "$name" $USER_F_UUID)"
    sspsk="$(user_field "$name" $USER_F_SSPSK)"
    protos="$(user_field "$name" $USER_F_PROTOS)"

    for p in $(printf '%s' "$protos" | tr ',' ' '); do
        user_proto_active "$p" || continue
        case "$p" in
            reality) sub_link_vless "$name" "$host" "$uuid" ;;
            ss)      sub_link_ss "$name" "$host" "$sspsk" ;;
            vmess)   sub_link_vmess "$name" "$host" "$uuid" ;;
            xhttp)   sub_link_xhttp "$name" "$host" "$uuid" ;;
        esac
    done
    return 0
}

# VLESS + XHTTP + REALITY(与 reality 共用密钥, 但 flow 必须为空)
sub_link_xhttp() {
    local name="$1" host="$2" uuid="$3"
    local port sni fp pbk sid spx net path mode tag
    port="$(cfg_get XHTTP_PORT '')"
    sni="$(cfg_get REALITY_SNI 'www.bing.com')"
    fp="$(cfg_get REALITY_FINGERPRINT 'chrome')"
    pbk="$(cfg_get REALITY_PUBLIC_KEY '')"
    sid="$(cfg_get REALITY_SHORT_IDS '' | cut -d, -f1)"
    spx="$(cfg_get REALITY_SPX '/')"
    path="$(cfg_get XHTTP_PATH '/vpnx-xhttp')"
    mode="$(cfg_get XHTTP_MODE 'auto')"
    net="$(xray_xhttp_net)"
    tag="$(sub_tag "$name" XHTTP)"
    [ -z "$port" ] && return 0
    [ -z "$pbk" ] && { log_warn "账号 $name: 缺少 REALITY 公钥, 跳过 XHTTP 链接"; return 0; }
    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&spx=%s&type=%s&path=%s&mode=%s#%s\n' \
        "$uuid" "$host" "$port" "$sni" "$fp" "$pbk" "$sid" \
        "$(url_encode "$spx")" "$net" "$(url_encode "$path")" "$mode" "$(url_encode "$tag")"
}

sub_link_vless() {
    local name="$1" host="$2" uuid="$3"
    local port sni fp pbk sid spx net flow tag
    port="$(cfg_get REALITY_PORT '')"
    sni="$(cfg_get REALITY_SNI 'www.bing.com')"
    fp="$(cfg_get REALITY_FINGERPRINT 'chrome')"
    pbk="$(cfg_get REALITY_PUBLIC_KEY '')"
    sid="$(cfg_get REALITY_SHORT_IDS '' | cut -d, -f1)"
    spx="$(cfg_get REALITY_SPX '/')"
    flow="$(cfg_get REALITY_FLOW 'xtls-rprx-vision')"
    tag="$(sub_tag "$name" REALITY)"
    [ -z "$port" ] && return 0
    # 客户端统一用 type=tcp (兼容性最好), 服务端新核心的 raw 与 tcp 等价
    net="tcp"
    printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&spx=%s&type=%s#%s\n' \
        "$uuid" "$host" "$port" "$flow" "$sni" "$fp" "$pbk" "$sid" \
        "$(url_encode "$spx")" "$net" "$(url_encode "$tag")"
}

sub_link_ss() {
    local name="$1" host="$2" sspsk="$3"
    local port method srvpsk userinfo tag
    port="$(cfg_get SS_PORT '')"
    method="$(cfg_get SS_METHOD '2022-blake3-aes-128-gcm')"
    srvpsk="$(cfg_get SS_SERVER_PSK '')"
    tag="$(sub_tag "$name" SS2022)"
    [ -z "$port" ] && return 0
    [ -z "$sspsk" ] && { log_warn "账号 $name 缺少 SS 密钥, 跳过 SS 链接"; return 0; }
    # SS2022 客户端密码 = 服务器PSK:用户PSK  (SIP002: userinfo 用 urlsafe base64)
    userinfo="$(printf '%s:%s:%s' "$method" "$srvpsk" "$sspsk" | b64_url)"
    printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$host" "$port" "$(url_encode "$tag")"
}

sub_link_vmess() {
    local name="$1" host="$2" uuid="$3"
    local port path vhost tag json
    port="$(cfg_get VMESS_PORT '')"
    path="$(cfg_get VMESS_PATH '/vpnx-ws')"
    vhost="$(cfg_get VMESS_HOST '')"
    [ -z "$vhost" ] && vhost="$host"
    tag="$(sub_tag "$name" VMess)"
    [ -z "$port" ] && return 0
    json="$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"","sni":""}' \
        "$tag" "$host" "$port" "$uuid" "$vhost" "$path")"
    printf 'vmess://%s\n' "$(printf '%s' "$json" | b64_std)"
}

# ---------------------------------------------------------------------------
# 订阅文件: <名字>.txt(base64) / <token>.txt / .raw / .clash
# ---------------------------------------------------------------------------
sub_build() {
    local name="$1" tok raw b64
    user_exists "$name" || return 1
    ensure_dir "$VPNX_SUB_DIR"
    tok="$(sub_token_ensure "$name")"
    raw="$(sub_links "$name")"
    if [ -z "$raw" ]; then
        log_warn "账号 $name 当前没有任何可用链接(协议未启用或已到期)"
        return 1
    fi
    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '%s[dry-run]%s 生成订阅 %s (token %s)\n' "$C_DIM" "$C_RST" "$name" "$tok"
        return 0
    fi
    printf '%s\n' "$raw" > "$VPNX_SUB_DIR/$name.raw"
    b64="$(printf '%s' "$raw" | b64_std)"
    printf '%s\n' "$b64" > "$VPNX_SUB_DIR/$name.txt"
    cp -f "$VPNX_SUB_DIR/$name.txt" "$VPNX_SUB_DIR/$tok.txt"
    # 供中台/内置订阅服务读取的用户信息
    sub_meta "$name" > "$VPNX_SUB_DIR/$tok.meta"
    sub_clash "$name" > "$VPNX_SUB_DIR/$tok.clash"
    chmod 644 "$VPNX_SUB_DIR/$name.txt" "$VPNX_SUB_DIR/$tok.txt" 2>/dev/null || true

    printf '账号      : %s\n' "$name"
    printf '订阅 token: %s\n' "$tok"
    printf '订阅串(小火箭/v2rayN 直接导入):\n%s\n' "$b64"
    local base
    base="$(cfg_get SUB_BASE_URL '')"
    if [ -n "$base" ]; then
        printf '订阅地址  : %s%s\n' "${base%/}/" "$tok"
    else
        printf '订阅地址  : (未设置 SUB_BASE_URL, 可在中台配置后用中台地址访问 /sub/%s)\n' "$tok"
    fi
    printf '本机文件  : %s/%s.txt\n' "$VPNX_SUB_DIR" "$tok"
    return 0
}

sub_build_all() {
    local name n=0
    for name in $(users_all_names); do
        sub_build "$name" >/dev/null 2>&1 && n=$((n + 1))
    done
    log_ok "已生成 $n 个账号的订阅文件"
    return 0
}

# 订阅流量/到期头信息
sub_meta() {
    local name="$1" up down used quota expire
    up="$(user_field "$name" $USER_F_UP)"
    down="$(user_field "$name" $USER_F_DOWN)"
    quota="$(user_field "$name" $USER_F_QUOTA)"
    expire="$(user_field "$name" $USER_F_EXPIRE)"
    is_num "$up" || up=0
    is_num "$down" || down=0
    used=$((up + down))
    printf 'upload=%s\n' "$up"
    printf 'download=%s\n' "$down"
    printf 'total=%s\n' "${quota:-0}"
    printf 'expire=%s\n' "${expire:-0}"
    printf 'used=%s\n' "$used"
    return 0
}

# Clash Meta / mihomo 订阅
sub_clash() {
    local name="$1" host uuid sspsk protos p
    host="$(sub_public_host)"
    uuid="$(user_field "$name" $USER_F_UUID)"
    sspsk="$(user_field "$name" $USER_F_SSPSK)"
    protos="$(user_field "$name" $USER_F_PROTOS)"

    printf 'proxies:\n'
    local first=1 pname tags=""
    for p in $(printf '%s' "$protos" | tr ',' ' '); do
        user_proto_active "$p" || continue
        case "$p" in
            reality)
                pname="$(sub_tag "$name" REALITY)"
                clash_vless "$pname" "$host" "$uuid"
                tags="${tags:+$tags, }$pname"
                ;;
            ss)
                [ -z "$sspsk" ] && continue
                pname="$(sub_tag "$name" SS2022)"
                clash_ss "$pname" "$host" "$sspsk"
                tags="${tags:+$tags, }$pname"
                ;;
            vmess)
                pname="$(sub_tag "$name" VMess)"
                clash_vmess "$pname" "$host" "$uuid"
                tags="${tags:+$tags, }$pname"
                ;;
            # xhttp 故意不写进 clash 订阅: 老客户端遇到不认识的 network 会拒绝加载整份配置
            # (Clash for Android 的教训)。需要 xhttp 的客户端请用中台的 .../clash-xhttp 独立链接。
        esac
        first=0
    done
    if [ "$first" = "1" ]; then
        printf '  []\n'
    fi
    printf 'proxy-groups:\n'
    printf '  - name: PROXY\n'
    printf '    type: select\n'
    printf '    proxies: [%s]\n' "$tags"
    printf 'rules:\n'
    printf '  - MATCH,PROXY\n'
    return 0
}

clash_vless() {
    local pname="$1" host="$2" uuid="$3"
    local mode="${4:-reality}"
    if [ "$mode" = "xhttp" ]; then
        # VLESS + XHTTP + REALITY: 不带 flow
        printf '  - name: "%s"\n' "$pname"
        printf '    type: vless\n'
        printf '    server: %s\n' "$host"
        printf '    port: %s\n' "$(cfg_get XHTTP_PORT '')"
        printf '    uuid: %s\n' "$uuid"
        printf '    network: %s\n' "$(xray_xhttp_net)"
        printf '    tls: true\n'
        printf '    udp: true\n'
        printf '    servername: %s\n' "$(cfg_get REALITY_SNI 'www.bing.com')"
        printf '    client-fingerprint: %s\n' "$(cfg_get REALITY_FINGERPRINT 'chrome')"
        printf '    reality-opts:\n'
        printf '      public-key: %s\n' "$(cfg_get REALITY_PUBLIC_KEY '')"
        printf '      short-id: "%s"\n' "$(cfg_get REALITY_SHORT_IDS '' | cut -d, -f1)"
        printf '    xhttp-opts:\n'
        printf '      path: %s\n' "$(cfg_get XHTTP_PATH '/vpnx-xhttp')"
        printf '      mode: %s\n' "$(cfg_get XHTTP_MODE 'auto')"
        return 0
    fi
    printf '  - name: "%s"\n' "$pname"
    printf '    type: vless\n'
    printf '    server: %s\n' "$host"
    printf '    port: %s\n' "$(cfg_get REALITY_PORT '')"
    printf '    uuid: %s\n' "$uuid"
    printf '    network: tcp\n'
    printf '    tls: true\n'
    printf '    udp: true\n'
    printf '    flow: %s\n' "$(cfg_get REALITY_FLOW 'xtls-rprx-vision')"
    printf '    servername: %s\n' "$(cfg_get REALITY_SNI 'www.bing.com')"
    printf '    client-fingerprint: %s\n' "$(cfg_get REALITY_FINGERPRINT 'chrome')"
    printf '    reality-opts:\n'
    printf '      public-key: %s\n' "$(cfg_get REALITY_PUBLIC_KEY '')"
    printf '      short-id: "%s"\n' "$(cfg_get REALITY_SHORT_IDS '' | cut -d, -f1)"
}

clash_ss() {
    local pname="$1" host="$2" sspsk="$3"
    printf '  - name: "%s"\n' "$pname"
    printf '    type: ss\n'
    printf '    server: %s\n' "$host"
    printf '    port: %s\n' "$(cfg_get SS_PORT '')"
    printf '    cipher: %s\n' "$(cfg_get SS_METHOD '2022-blake3-aes-128-gcm')"
    printf '    password: "%s:%s"\n' "$(cfg_get SS_SERVER_PSK '')" "$sspsk"
    printf '    udp: true\n'
}

clash_vmess() {
    local pname="$1" host="$2" uuid="$3"
    printf '  - name: "%s"\n' "$pname"
    printf '    type: vmess\n'
    printf '    server: %s\n' "$host"
    printf '    port: %s\n' "$(cfg_get VMESS_PORT '')"
    printf '    uuid: %s\n' "$uuid"
    printf '    alterId: 0\n'
    printf '    cipher: auto\n'
    printf '    network: ws\n'
    printf '    udp: true\n'
    # 两套写法都写上, 兼容性最好:
    #   老 Clash(Clash for Android) 只认 ws-path / ws-headers
    #   mihomo(Clash.Meta) 认 ws-opts, 同时也兼容老写法
    printf '    ws-path: %s\n' "$(cfg_get VMESS_PATH '/vpnx-ws')"
    printf '    ws-headers:\n'
    printf '      Host: %s\n' "$(cfg_get VMESS_HOST "$host")"
    printf '    ws-opts:\n'
    printf '      path: %s\n' "$(cfg_get VMESS_PATH '/vpnx-ws')"
    printf '      headers:\n'
    printf '        Host: %s\n' "$(cfg_get VMESS_HOST "$host")"
}

# ---------------------------------------------------------------------------
# 本机内置订阅服务(可选; 默认建议由中台提供订阅)
#  - 用 python2/3 兼容的小型 HTTP 服务, 绑高位端口, 不占用 80/443
# ---------------------------------------------------------------------------
SUB_SERVICE_NAME="vpnx-sub"

sub_serve_install() {
    local port="${1:-$(cfg_get SUB_PORT '')}"
    if [ -z "$port" ]; then
        port="$(pick_free_port 18080 18081 28080 38080)" || die "找不到空闲端口"
        cfg_set SUB_PORT "$port"
    fi
    cfg_set SUB_SERVE 1

    local py=""
    [ "$HAS_PYTHON3" = "1" ] && py="python3"
    [ -z "$py" ] && [ "$HAS_PYTHON" = "1" ] && py="python"
    [ -z "$py" ] && die "内置订阅服务需要 python, 未检测到; 建议直接使用中台订阅"

    local script="$VPNX_HOME/tools/vpnx-subserver.py"
    [ -f "$script" ] || die "缺少 $script"

    if [ "$HAS_SYSTEMD" = "1" ]; then
        if [ "${DRY_RUN:-0}" != "1" ]; then
            cat > "/etc/systemd/system/$SUB_SERVICE_NAME.service" <<EOF
[Unit]
Description=vpnx 内置订阅服务
After=network.target

[Service]
Type=simple
ExecStart=$py $script --dir $VPNX_SUB_DIR --host 0.0.0.0 --port $port
Restart=on-failure
RestartSec=5
EOF
        fi
        svc_daemon_reload
        svc_enable "$SUB_SERVICE_NAME"
        svc_action restart "$SUB_SERVICE_NAME" >/dev/null 2>&1 || true
    else
        if [ "${DRY_RUN:-0}" != "1" ]; then
            cat > "/etc/init.d/$SUB_SERVICE_NAME" <<EOF
#!/bin/sh
# chkconfig: 2345 86 14
case "\$1" in
  start) nohup $py $script --dir $VPNX_SUB_DIR --host 0.0.0.0 --port $port >/dev/null 2>&1 & ;;
  stop) pkill -f "vpnx-subserver.py" ;;
  restart) \$0 stop; sleep 1; \$0 start ;;
  status) pgrep -f "vpnx-subserver.py" >/dev/null && exit 0 || exit 3 ;;
esac
exit 0
EOF
            chmod 755 "/etc/init.d/$SUB_SERVICE_NAME"
        fi
        svc_enable "$SUB_SERVICE_NAME"
        svc_action restart "$SUB_SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    fw_open "$port" tcp
    local base
    base="$(cfg_get SUB_BASE_URL '')"
    [ -z "$base" ] && { base="http://$(sub_public_host):$port"; cfg_set SUB_BASE_URL "$base"; }
    log_ok "内置订阅服务已启动: $base/<token>"
    return 0
}

sub_serve_remove() {
    cfg_set SUB_SERVE 0
    svc_action stop "$SUB_SERVICE_NAME" >/dev/null 2>&1 || true
    svc_disable "$SUB_SERVICE_NAME"
    run rm -f "/etc/systemd/system/$SUB_SERVICE_NAME.service" "/etc/init.d/$SUB_SERVICE_NAME"
    svc_daemon_reload
    log_info "内置订阅服务已停止"
    return 0
}

sub_serve_status() {
    local port
    port="$(cfg_get SUB_PORT '')"
    printf '内置订阅服务: %s\n' "$([ "$(cfg_get SUB_SERVE 0)" = "1" ] && echo 已启用 || echo 未启用)"
    [ -n "$port" ] && printf '监听端口    : %s\n' "$port"
    if svc_is_active "$SUB_SERVICE_NAME"; then
        printf '服务状态    : 运行中\n'
    else
        printf '服务状态    : 未运行\n'
    fi
    local base
    base="$(cfg_get SUB_BASE_URL '')"
    [ -n "$base" ] && printf '订阅基址    : %s\n' "$base"
    return 0
}

# ---------------------------------------------------------------------------
# CLI: vpnx sub ...
# ---------------------------------------------------------------------------
cmd_sub() {
    local sub="${1:-status}"
    if [ $# -gt 0 ]; then shift; fi
    require_root
    require_installed
    case "$sub" in
        serve)
            case "${1:-status}" in
                on|start)  lock_acquire 30; sub_serve_install "${2:-}" ;;
                off|stop)  sub_serve_remove ;;
                status)    sub_serve_status ;;
                *) die "用法: vpnx sub serve on|off|status [端口]" ;;
            esac
            ;;
        export)
            lock_acquire 30
            user_sync_traffic >/dev/null 2>&1 || true
            sub_build_all
            printf '订阅文件目录: %s\n' "$VPNX_SUB_DIR"
            ;;
        build)
            [ -n "${1:-}" ] || die "用法: vpnx sub build <账号>"
            sub_build "$1"
            ;;
        status)
            sub_serve_status
            ;;
        *)
            printf '用法: vpnx sub serve on|off|status [端口] | vpnx sub export | vpnx sub build <账号>\n'
            return 2
            ;;
    esac
}
