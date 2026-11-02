#!/usr/bin/env bash
# ==============================================================================
#  lib/agent.sh - 中台同步代理
#    * 心跳上报(节点状态/端口/用户数/健康)
#    * 拉取并应用策略(用户增删改、端口/伪装参数调整、档位更新)
#    * 用量与事件上报(用量增量本地累计, 上报失败可重放, 不丢数据)
#    * 订阅推送(把每个账号的订阅内容推给中台, 客户端只连中台)
#  鉴权: HMAC-SHA256(secret, METHOD\nPATH\nTIMESTAMP\nNONCE\nSHA256(body))
#  老机器兼容: 优先使用 format=lines 的纯文本协议, 没有 jq/python 也能工作
# ==============================================================================

AGENT_VERSION="1.0.0"
AGENT_STATE="$VPNX_STATE_DIR/agent.state"
AGENT_EVENTS="$VPNX_STATE_DIR/events.jsonl"

# ---------------------------------------------------------------------------
# 配置读写(agent.conf 优先, 兼容写在 vpnx.conf 的 SYNC_* )
# ---------------------------------------------------------------------------
agent_cfg() {
    local key="$1" def="${2:-}" v sync_key
    v="$(kv_get "$VPNX_AGENT_CONF" "$key" '')"
    if [ -z "$v" ]; then
        case "$key" in
            URL)      sync_key=SYNC_URL ;;
            NODE_ID)  sync_key=SYNC_NODE_ID ;;
            TOKEN)    sync_key=SYNC_TOKEN ;;
            INTERVAL) sync_key=SYNC_INTERVAL ;;
            INSECURE) sync_key=SYNC_INSECURE ;;
            *)        sync_key="" ;;
        esac
        [ -n "$sync_key" ] && v="$(cfg_get "$sync_key" '')"
    fi
    [ -z "$v" ] && v="$def"
    printf '%s' "$v"
}

agent_set() {
    ensure_dir "$VPNX_ETC"
    local url node token interval insecure
    url="$(opt_val --url "$@")"
    node="$(opt_val --node-id "$@")"
    token="$(opt_val --token "$@")"
    interval="$(opt_val --interval "$@")"
    insecure="$(opt_val --insecure "$@")"

    [ -n "$url" ]      && kv_set "$VPNX_AGENT_CONF" URL "$url"
    [ -n "$node" ]     && kv_set "$VPNX_AGENT_CONF" NODE_ID "$node"
    [ -n "$token" ]    && kv_set "$VPNX_AGENT_CONF" TOKEN "$token"
    [ -n "$interval" ] && kv_set "$VPNX_AGENT_CONF" INTERVAL "$interval"
    [ -n "$insecure" ] && kv_set "$VPNX_AGENT_CONF" INSECURE "$insecure"
    chmod 600 "$VPNX_AGENT_CONF" 2>/dev/null || true

    if [ -n "$url" ]; then
        cfg_set SYNC_ENABLED 1
    fi
    log_ok "中台参数已保存到 $VPNX_AGENT_CONF"
    log_info "URL=$(agent_cfg URL '-')  NODE_ID=$(agent_cfg NODE_ID '-')  INTERVAL=$(agent_cfg INTERVAL 60)s"
}

agent_enabled() {
    is_true "$(cfg_get SYNC_ENABLED 0)" || return 1
    [ -n "$(agent_cfg URL '')" ] || return 1
    [ -n "$(agent_cfg TOKEN '')" ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# 签名与请求
# ---------------------------------------------------------------------------
agent_sign() {
    local secret="$1" method="$2" path="$3" ts="$4" nonce="$5" body="$6" bodyhash
    bodyhash="$(printf '%s' "$body" | sha256sum 2>/dev/null | awk '{print $1}')"
    if [ -z "$bodyhash" ]; then
        bodyhash="$(printf '%s' "$body" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
    fi
    printf '%s\n%s\n%s\n%s\n%s' "$method" "$path" "$ts" "$nonce" "$bodyhash" \
        | openssl dgst -sha256 -hmac "$secret" -r 2>/dev/null | awk '{print $1}'
}

# 按基址形态拼出真实请求地址
#   * 基址以 .php 结尾(如 https://面板/vpn/api.php)
#     -> 查询参数模式 ?__vpnx=/api/v1/xxx
#        原因: 很多面板/虚拟主机会拦截 ".php" 后面的附加路径(PATH_INFO) 并返回 403;
#        查询参数模式在任何 PHP 主机上都能用, 不需要改服务器配置。
#   * 基址是不带 .php 的干净地址(如 https://面板/vpn)
#     -> PATH_INFO 形态 /api/v1/xxx(需要站点已配 rewrite)
_agent_request_url() {
    local base="$1" path="$2" query="${3:-}" url
    case "$base" in
        *.php)
            url="$base?__vpnx=$path"
            if [ -n "$query" ]; then
                url="$url&${query#\?}"
            fi
            ;;
        *)
            url="$base$path$query"
            ;;
    esac
    printf '%s' "$url"
}

# agent_request <METHOD> <PATH带query> [BODY] [ACCEPT]
# 输出: 响应体写到 stdout; 返回码 0 表示 HTTP 2xx
agent_request() {
    local method="$1" fullpath="$2" body="${3:-}" accept="${4:-application/json}"
    local url ts nonce sig base insecure out code path query meta eff request_url
    url="$(agent_cfg URL '')"
    [ -n "$url" ] || { log_err "未配置中台 URL (vpnx agent set --url ...)"; return 1; }
    have_cmd curl || { log_err "中台同步需要 curl"; return 1; }
    insecure="$(agent_cfg INSECURE 0)"

    # 关键: 签名覆盖的是"去掉 query"的路径(与中台 server.py 的实现一致),
    #       但请求本身要带上 query。这两者弄反会导致策略拉取 401。
    case "$fullpath" in
        *\?*) path="${fullpath%%\?*}"; query="?${fullpath#*\?}" ;;
        *)    path="$fullpath";         query="" ;;
    esac

    ts="$(now_epoch)"
    nonce="$(rand_hex 8)"
    sig="$(agent_sign "$(agent_cfg TOKEN '')" "$method" "$path" "$ts" "$nonce" "$body")"

    base="${url%/}"
    request_url="$(_agent_request_url "$base" "$path" "$query")"

    tmp_init
    out="$VPNX_TMP_DIR/agent.resp"
    # -L: 跟随重定向(面板可能把 http 跳到 https, 或给路径补斜杠)
    meta="$(curl -sS -L --max-redirs 3 -o "$out" -w '%{http_code} %{url_effective}' \
        --connect-timeout 10 --max-time 40 \
        $([ "$insecure" = "1" ] && printf '%s' '-k') \
        -X "$method" \
        -H "X-VPNX-Node: $(agent_cfg NODE_ID '')" \
        -H "X-VPNX-Timestamp: $ts" \
        -H "X-VPNX-Nonce: $nonce" \
        -H "X-VPNX-Signature: $sig" \
        -H "Accept: $accept" \
        -H "Content-Type: application/json" \
        -H "User-Agent: vpnx/$AGENT_VERSION" \
        ${body:+--data-binary "$body"} \
        "$request_url" 2>"$VPNX_TMP_DIR/agent.err")" || meta="000"

    code="${meta%% *}"
    eff="${meta#* }"
    if [ "$eff" = "$meta" ]; then
        eff=""
    fi
    log_debug "请求 $method $request_url -> HTTP $code ${eff:+最终 $eff}"

    case "$code" in
        2*) cat "$out"; return 0 ;;
        000)
            log_err "中台不可达: $request_url"
            log_err "  curl 报错: $(head -c 300 "$VPNX_TMP_DIR/agent.err" 2>/dev/null | tr '\n' ' ')"
            log_err "  排查: ① 域名/端口是否可达 ② 证书是否有效(自签可设 SYNC_INSECURE=1) ③ DNS 是否解析正确"
            return 1 ;;
        301|302|303|307|308)
            log_err "中台返回重定向 $code ${eff:+-> $eff}"
            log_err "  请把 /etc/vpnx/agent.conf 的 URL 直接改成最终地址"
            return 1 ;;
        401)
            log_err "中台鉴权失败(401): 节点是否已在中台注册、token 是否与中台一致、两侧时间差是否 < 300 秒"
            return 1 ;;
        403)
            log_err "中台返回 403: $(head -c 200 "$out" 2>/dev/null | tr '\n' ' ')"
            log_err "  403 多半是站点拦了 \".php\" 后面的附加路径(PATH_INFO)。"
            log_err "  本机已按 URL 形态自动选择: 以 .php 结尾 -> 查询参数模式 ?__vpnx=/api/v1/...; 无需改面板配置。"
            log_err "  若仍 403, 请确认中台已升级到支持 __vpnx 的版本(central/api.php 含 vpnx_request_candidates)。"
            return 1 ;;
        404)
            log_err "中台返回 404: 路径不存在($request_url)"
            log_err "  未配 rewrite 时 URL 必须以 /api.php 结尾, 例如 https://面板/vpn/api.php"
            return 1 ;;
        *)
            log_err "中台返回 $code: $(head -c 300 "$out" 2>/dev/null | tr '\n' ' ')"
            return 1 ;;
    esac
}

# 响应字段提取(JSON 优先, 退化用正则, 保证没有 jq/python 也能跑)
_resp_get() {
    local f="$1" k="$2" v
    v="$(json_get "$f" "$k" 2>/dev/null)"
    if [ -z "$v" ]; then
        v="$(tr -d '\r\n' < "$f" 2>/dev/null \
             | sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" \
             | head -n1)"
    fi
    printf '%s' "$v"
}

# ---------------------------------------------------------------------------
# 事件队列
# ---------------------------------------------------------------------------
agent_event() {
    local level="${1:-INFO}" code="${2:-generic}" msg="${3:-}" f="$AGENT_EVENTS"
    ensure_dir "$VPNX_STATE_DIR"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        return 0
    fi
    printf '{"ts":%s,"level":"%s","code":"%s","message":"%s"}\n' \
        "$(now_epoch)" "$(json_escape "$level")" "$(json_escape "$code")" "$(json_escape "$msg")" >> "$f"
    # 队列过长时截断, 只保留最近 500 条
    if [ -f "$f" ] && [ "$(wc -l < "$f" 2>/dev/null | tr -d ' ')" -gt 500 ] 2>/dev/null; then
        tail -n 500 "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
    fi
    return 0
}

_events_json_array() {
    local f="$AGENT_EVENTS" out="" line first=1
    [ -f "$f" ] || { printf '[]'; return 0; }
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        [ "$first" = "1" ] || out="$out,"
        out="$out$line"
        first=0
    done < "$f"
    printf '[%s]' "$out"
}

# ---------------------------------------------------------------------------
# 按当前配置重新放行端口(端口被中台改掉后必须重放, 否则本机防火墙还是关的)
# ---------------------------------------------------------------------------
_agent_refresh_firewall() {
    fw_detect
    local p port
    for p in reality ss vmess xhttp; do
        user_proto_active "$p" || continue
        case "$p" in
            reality)
                port="$(cfg_get REALITY_PORT '')"
                [ -n "$port" ] && fw_open "$port" tcp
                ;;
            ss)
                port="$(cfg_get SS_PORT '')"
                [ -n "$port" ] && fw_open "$port" "$(cfg_get SS_NETWORK 'tcp,udp')"
                ;;
            vmess)
                port="$(cfg_get VMESS_PORT '')"
                [ -n "$port" ] && fw_open "$port" tcp
                ;;
            xhttp)
                port="$(cfg_get XHTTP_PORT '')"
                [ -n "$port" ] && fw_open "$port" tcp
                ;;
        esac
    done
    return 0
}

# ---------------------------------------------------------------------------
# 订阅内容指纹: 账号或"影响分享链接的配置"一变就重推订阅
#   (只看影响链接的字段, 不包含用量, 否则每次上报流量都会重推)
# ---------------------------------------------------------------------------
_agent_subscription_signature() {
    local dbpart confpart
    dbpart="$(awk -F'|' 'NF>=10 && $1!~/^#/ { print $1"|"$2"|"$3"|"$4"|"$10"|"$11 }' "$VPNX_USERS_DB" 2>/dev/null | sort)"
    confpart="$(cfg_get PUBLIC_IP '')|$(cfg_get NODE_NAME '')|$(cfg_get REALITY_PORT '')|$(cfg_get REALITY_SNI '')|$(cfg_get REALITY_PUBLIC_KEY '')|$(cfg_get REALITY_SHORT_IDS '')|$(cfg_get REALITY_FLOW '')|$(cfg_get SS_PORT '')|$(cfg_get SS_METHOD '')|$(cfg_get SS_SERVER_PSK '')|$(cfg_get VMESS_PORT '')|$(cfg_get VMESS_PATH '')"
    # 前面的 v2 是"生成格式版本号": 订阅内容的生成逻辑有变化时 +1, 可强制所有节点重推一次订阅
    printf 'v2\n%s\n%s\n' "$confpart" "$dbpart" | sha256sum 2>/dev/null | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# 心跳
# ---------------------------------------------------------------------------
agent_heartbeat() {
    local body resp host xray_ver users_total users_active traffic inbounds
    host="$(hostname 2>/dev/null || echo vps)"
    xray_ver="$(xray_installed_version)"
    users_total="$(user_count)"
    users_active="$(user_count)"
    traffic="$(awk -F'|' 'NF>=10 && $1!~/^#/ { s+=($6+$7) } END { printf "%d", s+0 }' "$VPNX_USERS_DB" 2>/dev/null)"

    inbounds="$(_agent_inbounds_json)"

    body="$(printf '{"node_id":"%s","hostname":"%s","agent_version":"%s","build":"%s","xray_version":"%s","os":"%s","kernel":"%s","arch":"%s","public_ip":"%s","uptime_sec":%s,"load1":"%s","mem_used_pct":%s,"disk_used_pct":%s,"inbounds":[%s],"users_total":%s,"users_active":%s,"traffic_total_bytes":%s,"applied_policy_revision":%s,"health":{"service_ok":%s,"config_ok":%s,"ports_ok":%s,"last_error":"%s"}}' \
        "$(json_escape "$(agent_cfg NODE_ID '')")" "$(json_escape "$host")" "$AGENT_VERSION" "$VPNX_BUILD" \
        "$(json_escape "$xray_ver")" "$(json_escape "$OS_PRETTY")" "$(json_escape "$KERNEL_VER")" \
        "$(json_escape "$ARCH")" "$(json_escape "$(cfg_get PUBLIC_IP '')")" \
        "$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)" \
        "$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)" \
        "$(free 2>/dev/null | awk '/Mem:/ {printf "%d", $3*100/$2}' || echo 0)" \
        "$(df / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); printf "%d", $5}' || echo 0)" \
        "$inbounds" "$users_total" "$users_active" "${traffic:-0}" \
        "$(cfg_get POLICY_REVISION 0)" \
        "$(xray_is_running && echo true || echo false)" \
        "$([ -f "$VPNX_XRAY_CONF" ] && echo true || echo false)" \
        "true" "$(json_escape "$(_agent_last_error)")")"

    tmp_init
    resp="$VPNX_TMP_DIR/heartbeat.json"
    if ! agent_request POST "/api/v1/node/heartbeat" "$body" > "$resp"; then
        return 1
    fi
    # 防"静默错配": 中台版本过旧时不认识 ?__vpnx=, 会把请求当成直接访问 api.php,
    # 返回部署自检 JSON(HTTP 200), 这里必须识别出来并明确报错。
    if ! grep -q '"policy_revision"' "$resp" 2>/dev/null; then
        if grep -q 'vpnx central' "$resp" 2>/dev/null; then
            log_err "中台返回的是部署自检信息, 不是心跳响应"
            log_err "  原因: 中台版本过旧, 不支持 ?__vpnx= 查询参数模式"
            log_err "  处理: 更新中台的 central/ 目录(见 central.zip), 或给站点配 rewrite 后改用不带 api.php 的地址"
        else
            log_err "心跳响应异常: $(head -c 200 "$resp" 2>/dev/null | tr '\n' ' ')"
        fi
        return 1
    fi
    AGENT_POLICY_PENDING="$(_resp_get "$resp" policy_pending)"
    AGENT_POLICY_REVISION="$(_resp_get "$resp" policy_revision)"
    AGENT_NEXT_INTERVAL="$(_resp_get "$resp" next_interval_sec)"
    log_debug "心跳完成: revision=$AGENT_POLICY_REVISION pending=$AGENT_POLICY_PENDING"
    return 0
}

_agent_last_error() {
    local f="$VPNX_STATE_DIR/last_error"
    [ -f "$f" ] && head -c 200 "$f" 2>/dev/null
    return 0
}

_agent_set_last_error() {
    ensure_dir "$VPNX_STATE_DIR"
    if [ -z "${1:-}" ]; then
        rm -f "$VPNX_STATE_DIR/last_error" 2>/dev/null || true
    else
        printf '%s' "$1" > "$VPNX_STATE_DIR/last_error" 2>/dev/null || true
    fi
    return 0
}

_agent_inbounds_json() {
    local out="" first=1 p port tag enabled
    for p in reality ss vmess xhttp; do
        port=""
        case "$p" in
            reality) port="$(cfg_get REALITY_PORT '')" ;;
            ss)      port="$(cfg_get SS_PORT '')" ;;
            vmess)   port="$(cfg_get VMESS_PORT '')" ;;
            xhttp)   port="$(cfg_get XHTTP_PORT '')" ;;
        esac
        [ -z "$port" ] && continue
        tag="$(proto_tag "$p")"
        user_proto_active "$p" && enabled=true || enabled=false
        [ "$first" = "1" ] || out="$out,"
        case "$p" in
            reality) out="$out{\"tag\":\"$tag\",\"protocol\":\"vless-reality\",\"port\":$port,\"network\":\"$(cfg_get REALITY_NETWORK tcp)\",\"enabled\":$enabled}" ;;
            ss)      out="$out{\"tag\":\"$tag\",\"protocol\":\"ss2022\",\"port\":$port,\"network\":\"$(cfg_get SS_NETWORK 'tcp,udp')\",\"enabled\":$enabled}" ;;
            vmess)   out="$out{\"tag\":\"$tag\",\"protocol\":\"vmess-ws\",\"port\":$port,\"network\":\"ws\",\"enabled\":$enabled}" ;;
            xhttp)   out="$out{\"tag\":\"$tag\",\"protocol\":\"vless-xhttp\",\"port\":$port,\"network\":\"$(xray_xhttp_net)\",\"enabled\":$enabled}" ;;
        esac
        first=0
    done
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# 策略拉取与解析
# ---------------------------------------------------------------------------
# 拉取策略: 优先 lines 协议(老机器无需解析器), 中台返回 JSON 时自动扁平化
agent_pull_policy() {
    local cur resp
    cur="$(cfg_get POLICY_REVISION 0)"
    tmp_init
    resp="$VPNX_TMP_DIR/policy.resp"
    if ! agent_request GET "/api/v1/node/policy?node_id=$(agent_cfg NODE_ID '')&current_revision=$cur&format=lines" \
            "" "text/plain, application/json" > "$resp"; then
        return 1
    fi
    [ -s "$resp" ] || { log_warn "策略响应为空"; return 1; }

    # 同样防错配: 正常策略响应一定带 revision
    if ! grep -q 'revision=' "$resp" 2>/dev/null && ! grep -q '"revision"' "$resp" 2>/dev/null; then
        if grep -q 'vpnx central' "$resp" 2>/dev/null; then
            log_err "中台返回的是部署自检信息, 不是策略(中台版本过旧, 不支持 ?__vpnx=)"
            log_err "  处理: 更新中台的 central/ 目录, 或配 rewrite 后改用不带 api.php 的地址"
        else
            log_err "策略响应异常(缺少 revision): $(head -c 200 "$resp" 2>/dev/null | tr '\n' ' ')"
        fi
        return 1
    fi

    # 未变化: 兼容 JSON 的 "unchanged":true 与 format=lines 的 unchanged=true 两种形态
    if grep -qE '("unchanged"[[:space:]]*:[[:space:]]*true|^unchanged=true)' "$resp" 2>/dev/null; then
        log_debug "中台策略未变化(revision=$cur)"
        return 2
    fi

    local lines="$VPNX_TMP_DIR/policy.lines"
    if head -c 1 "$resp" 2>/dev/null | grep -q '{'; then
        # JSON 响应 -> 扁平化
        if [ "$(json_backend)" = "none" ]; then
            log_err "中台返回了 JSON 但本机没有 jq/python, 无法解析; 请让中台支持 format=lines 或安装 jq"
            return 1
        fi
        json_flatten "$resp" > "$lines" 2>/dev/null
    else
        cp -f "$resp" "$lines"
    fi
    [ -s "$lines" ] || { log_err "策略解析结果为空"; return 1; }

    if [ -f "$VPNX_POLICY" ]; then
        backup_file "$VPNX_POLICY" "policy" >/dev/null 2>&1 || true
    fi
    cp -f "$lines" "$VPNX_POLICY" 2>/dev/null || true
    printf '%s' "$lines"
    return 0
}

policy_line_get() {
    local file="$1" key="$2"
    awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/,""); print; exit }' "$file" 2>/dev/null
}

# 把中台协议名映射为内部名
policy_proto_map() {
    case "$1" in
        vless-reality|reality|vless) printf 'reality' ;;
        ss2022|ss|shadowsocks)       printf 'ss' ;;
        vmess-ws|vmess)              printf 'vmess' ;;
        vless-xhttp|xhttp)           printf 'xhttp' ;;
        *) printf '' ;;
    esac
}

_policy_proto_of() { policy_proto_map "${1:-}"; }

# 中台可能下发 null / None, 统一当作空值处理
_policy_norm() {
    case "${1:-}" in
        ''|null|NULL|None|none|~) printf '' ;;
        *) printf '%s' "$1" ;;
    esac
}

# 设置某协议端口; 有实际变化返回 0
_policy_set_port() {
    local p="$1" val="$2"
    [ -n "$val" ] || return 1
    is_num "$val" || return 1
    case "$p" in
        reality)
            [ "$(cfg_get REALITY_PORT '')" = "$val" ] && return 1
            cfg_set REALITY_PORT "$val" ;;
        ss)
            [ "$(cfg_get SS_PORT '')" = "$val" ] && return 1
            cfg_set SS_PORT "$val" ;;
        vmess)
            [ "$(cfg_get VMESS_PORT '')" = "$val" ] && return 1
            cfg_set VMESS_PORT "$val" ;;
        xhttp)
            [ "$(cfg_get XHTTP_PORT '')" = "$val" ] && return 1
            cfg_set XHTTP_PORT "$val" ;;
        *) return 1 ;;
    esac
    return 0
}

# 解析本地可用档位名: 名字优先, 其次按 type 匹配
_resolve_local_profile() {
    local name="$1" type="$2" f
    if [ -n "$name" ] && [ -f "$VPNX_PROFILE_DIR/$name.json" ]; then
        printf '%s' "$name"
        return 0
    fi
    case "$type" in
        vless-reality) printf 'reality-vision'; return 0 ;;
        ss2022)        printf 'ss2022';         return 0 ;;
        vmess-ws)      printf 'vmess-ws';       return 0 ;;
        vless-xhttp)   printf 'xhttp-reality';  return 0 ;;
    esac
    for f in "$VPNX_PROFILE_DIR"/*.json; do
        [ -f "$f" ] || continue
        if [ "$(json_get "$f" type)" = "$type" ]; then
            basename "$f" .json
            return 0
        fi
    done
    return 1
}

# 把中台档位参数落到 vpnx.conf(渲染真正读取的地方), 并同步写回档位文件
_policy_apply_profile_param() {
    local lname="$1" ptype="$2" key="$3" val="$4" pf="$VPNX_PROFILE_DIR/$1.json" lkey=""
    case "$key" in
        spider_x|spx)     lkey=spx;         cfg_set REALITY_SPX "$val" ;;
        flow)
            # XHTTP 与 XTLS Vision 互斥: vless-xhttp 档位的 flow 必须忽略,
            # 否则会把 in-reality 用的 Vision flow 一起清掉。
            if [ "$ptype" = "vless-xhttp" ]; then
                log_debug "vless-xhttp 档位不使用 flow(已忽略)"
                return 0
            fi
            lkey=flow; cfg_set REALITY_FLOW "$val" ;;
        fingerprint)      lkey=fingerprint; cfg_set REALITY_FINGERPRINT "$val" ;;
        network)
            lkey=network
            if [ "$ptype" = "ss2022" ]; then cfg_set SS_NETWORK "$val"; else cfg_set REALITY_NETWORK "$val"; fi
            ;;
        method)
            lkey=method
            case "$val" in
                2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|aes-128-gcm|aes-256-gcm) ;;
                *)
                    log_warn "SS 多用户模式只支持 blake3-aes-*-gcm, 已忽略加密方法 $val"
                    return 1
                    ;;
            esac
            if [ "$(cfg_get SS_METHOD '')" != "$val" ]; then
                cfg_set SS_METHOD "$val"
                _policy_regen_ss_keys "$val"
            fi
            ;;
        target|dest)      lkey=target;      cfg_set REALITY_TARGET "$val" ;;
        sni|server_names) lkey=sni;         cfg_set REALITY_SNI "$val" ;;
        transport)
            # 传输层名字(xhttp/splithttp): 仅记录到档位文件, 不改配置
            if [ "$ptype" = "vless-xhttp" ]; then
                lkey=transport
            else
                return 1
            fi
            ;;
        mode)
            if [ "$ptype" = "vless-xhttp" ]; then
                lkey=mode
                cfg_set XHTTP_MODE "$val"
            else
                return 1
            fi
            ;;
        path)
            lkey=path
            if [ "$ptype" = "vless-xhttp" ]; then cfg_set XHTTP_PATH "$val"; else cfg_set VMESS_PATH "$val"; fi
            ;;
        host)
            lkey=host
            if [ "$ptype" = "vless-xhttp" ]; then cfg_set XHTTP_HOST "$val"; else cfg_set VMESS_HOST "$val"; fi
            ;;
        *) return 1 ;;
    esac
    if [ -n "$lkey" ] && [ -f "$pf" ]; then
        _profile_param_set "$pf" "$lkey" "$val"
    fi
    return 0
}

# SS 加密方法变化后密钥长度也会变, 必须同步重生成, 否则内核会因密钥非法而启动失败
_policy_regen_ss_keys() {
    local method="$1" len name protos psk
    len="$(ss_psk_len_for_method "$method")"
    if is_true "$(cfg_get SS_ENABLED 0)"; then
        cfg_set SS_SERVER_PSK "$(ss_gen_psk "$len")"
        log_info "SS 加密方法变更, 已重新生成服务端密钥(${len} 字节)"
    fi
    for name in $(users_all_names); do
        protos="$(user_field "$name" $USER_F_PROTOS)"
        proto_in "$protos" ss || continue
        psk="$(ss_gen_psk "$len")"
        user_set_field "$name" $USER_F_SSPSK "$psk"
    done
    return 0
}

# allow_protocols 白名单: 不在名单里的协议关闭; 有变化返回 0
_policy_apply_allow_protocols() {
    local lines="$1" list="" p pv allowed changed=0
    list="$(policy_line_get "$lines" node.allow_protocols)"
    if [ -z "$list" ]; then
        list="$(awk -F= '/^node\.allow_protocols\.[0-9]+=/ { printf "%s,", $2 }' "$lines" 2>/dev/null)"
    fi
    [ -z "$list" ] && return 1
    list="$(printf '%s' "$list" | tr -d ' ')"
    for p in reality ss vmess xhttp; do
        allowed=0
        case "$p" in
            reality) pv="vless-reality" ;;
            ss)      pv="ss2022" ;;
            vmess)   pv="vmess-ws" ;;
            xhttp)   pv="vless-xhttp" ;;
        esac
        case ",$list," in
            *",$pv,"*|*",$p,"*) allowed=1 ;;
        esac
        # 白名单里包含但本机没开: 若中台给了端口就按策略启用(方便在台上给节点开兼容协议)
        if [ "$allowed" = "1" ] && ! user_proto_active "$p"; then
            case "$p" in
                reality)
                    if [ -n "$(cfg_get REALITY_PORT '')" ]; then
                        log_info "按策略启用 vless-reality (端口 $(cfg_get REALITY_PORT ''))"
                        cfg_set REALITY_ENABLED 1
                        changed=1
                    fi
                    ;;
                ss)
                    if [ -n "$(cfg_get SS_PORT '')" ]; then
                        if [ -z "$(cfg_get SS_SERVER_PSK '')" ]; then
                            cfg_set SS_SERVER_PSK "$(ss_gen_psk "$(ss_psk_len_for_method "$(cfg_get SS_METHOD '')")")"
                        fi
                        log_info "按策略启用 ss2022 (端口 $(cfg_get SS_PORT ''))"
                        cfg_set SS_ENABLED 1
                        changed=1
                    fi
                    ;;
                vmess)
                    if [ -n "$(cfg_get VMESS_PORT '')" ]; then
                        log_info "按策略启用 vmess-ws (端口 $(cfg_get VMESS_PORT ''))"
                        cfg_set VMESS_ENABLED 1
                        changed=1
                    fi
                    ;;
                xhttp)
                    if [ -n "$(cfg_get XHTTP_PORT '')" ] && [ -n "$(cfg_get REALITY_PRIVATE_KEY '')" ]; then
                        log_info "按策略启用 vless-xhttp (端口 $(cfg_get XHTTP_PORT ''))"
                        cfg_set XHTTP_ENABLED 1
                        changed=1
                    fi
                    ;;
            esac
        fi
        if [ "$allowed" = "0" ] && user_proto_active "$p"; then
            log_info "策略白名单未包含 $pv, 关闭该协议"
            case "$p" in
                reality) cfg_set REALITY_ENABLED 0 ;;
                ss)      cfg_set SS_ENABLED 0 ;;
                vmess)   cfg_set VMESS_ENABLED 0 ;;
                xhttp)   cfg_set XHTTP_ENABLED 0 ;;
            esac
            changed=1
        fi
    done
    # 兜底: 不允许把全部协议关掉, 否则节点就废了
    if ! user_proto_active reality && ! user_proto_active ss && ! user_proto_active vmess && ! user_proto_active xhttp; then
        log_warn "该白名单会导致所有协议关闭, 已回滚为启用 REALITY"
        cfg_set REALITY_ENABLED 1
        changed=1
    fi
    [ "$changed" = "1" ] && return 0
    return 1
}

# ---------------------------------------------------------------------------
# 应用策略
# ---------------------------------------------------------------------------
# agent_apply_policy <文件>   文件可以是 lines 或 JSON
# 中台推送的"脚本自升级"
#   策略里出现 node.upgrade_build 且与本机 build 不同 -> 下载 -> 校验 sha256 -> 结构自检
#   -> 备份 -> 覆盖 vpnx.sh 与 lib/tools/tests(不动 /etc/vpnx 状态, 不重启内核)
#   任何一步不通过都放弃并上报, 绝不半途覆盖。
agent_upgrade_check() {
    local lines="$1"
    is_true "$(cfg_get UPGRADE_ENABLED 1)" || return 0

    local want_build want_url want_sha cur_build root
    want_build="$(policy_line_get "$lines" node.upgrade_build)"
    [ -n "$want_build" ] || return 0
    cur_build="$VPNX_BUILD"
    [ "$want_build" = "$cur_build" ] && return 0

    want_url="$(policy_line_get "$lines" node.upgrade_url)"
    want_sha="$(policy_line_get "$lines" node.upgrade_sha256)"
    # 已经升级过同一个包(sha256 相同)就直接跳过 —— 比只比 build 字符串可靠
    if [ -n "$want_sha" ] && [ "$want_sha" = "$(cfg_get UPGRADE_APPLIED_SHA '')" ]; then
        return 0
    fi
    if [ -z "$want_url" ]; then
        log_warn "中台要求升级到 $want_build, 但没给下载地址, 已跳过"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || { log_warn "缺少 curl, 跳过自升级"; return 0; }
    command -v unzip >/dev/null 2>&1 || { log_warn "缺少 unzip, 跳过自升级"; return 0; }

    root="${VPNX_INSTALL_DIR:-/usr/local/vpnx}"
    [ -f "$root/vpnx.sh" ] || root="/usr/local/vpnx"
    [ -d "$root" ] || { log_warn "找不到程序目录 $root, 跳过自升级"; return 0; }

    tmp_init
    local dir="$VPNX_TMP_DIR/upgrade" zip="$VPNX_TMP_DIR/upgrade.zip"
    rm -rf "$dir" 2>/dev/null
    mkdir -p "$dir" 2>/dev/null
    log_info "中台要求自升级: $cur_build -> $want_build"

    if ! curl -fsSL -m 90 -o "$zip" "$want_url" 2>/dev/null; then
        log_err "自升级下载失败: $want_url"
        agent_event WARN "upgrade_fail" "下载失败($want_build)"
        return 0
    fi
    if [ -n "$want_sha" ]; then
        local got
        got="$(sha256sum "$zip" 2>/dev/null | awk '{print $1}')"
        if [ "$got" != "$want_sha" ]; then
            log_err "自升级包 sha256 不符, 已放弃(期望 ${want_sha%${want_sha#??????}}… 实际 ${got%${got#??????}}…)"
            agent_event WARN "upgrade_fail" "sha256 不符($want_build)"
            return 0
        fi
    fi
    if ! unzip -oq "$zip" -d "$dir" 2>/dev/null; then
        log_err "自升级包解压失败, 已放弃"
        agent_event WARN "upgrade_fail" "解压失败($want_build)"
        return 0
    fi
    if [ ! -f "$dir/vpnx.sh" ] || [ ! -f "$dir/lib/common.sh" ]; then
        log_err "自升级包结构不对(缺 vpnx.sh 或 lib/common.sh), 已放弃"
        agent_event WARN "upgrade_fail" "包结构不对($want_build)"
        return 0
    fi

    local bak="$root.bak.$(date +%Y%m%d%H%M%S)" d ok=1
    mkdir -p "$bak" 2>/dev/null
    cp -a "$root/vpnx.sh" "$bak/" 2>/dev/null
    for d in lib tools tests; do
        [ -d "$root/$d" ] && cp -a "$root/$d" "$bak/" 2>/dev/null
    done

    cp -f "$dir/vpnx.sh" "$root/vpnx.sh" 2>/dev/null || ok=0
    for d in lib tools tests; do
        [ -d "$dir/$d" ] || continue
        rm -rf "$root/$d.new" 2>/dev/null
        if cp -a "$dir/$d" "$root/$d.new" 2>/dev/null && rm -rf "$root/$d" && mv "$root/$d.new" "$root/$d"; then
            :
        else
            ok=0
        fi
    done
    chmod +x "$root/vpnx.sh" 2>/dev/null || true

    if [ "$ok" != "1" ]; then
        log_err "自升级覆盖失败, 备份在 $bak"
        agent_event WARN "upgrade_fail" "覆盖失败($want_build)"
        return 0
    fi
    [ -n "$want_sha" ] && cfg_set UPGRADE_APPLIED_SHA "$want_sha"
    log_ok "脚本已自升级: $cur_build -> $want_build (备份 $bak, 内核未重启, 下次调用即生效)"
    agent_event INFO "upgrade_ok" "$cur_build -> $want_build"
    return 0
}
agent_apply_policy() {
    local src="$1" lines="$2" revision="" workdb realdb
    [ -f "$src" ] || die "策略文件不存在: $src"

    tmp_init
    if [ -z "$lines" ] || [ ! -f "$lines" ]; then
        lines="$VPNX_TMP_DIR/policy.apply.lines"
        if head -c 1 "$src" 2>/dev/null | grep -q '{'; then
            json_flatten "$src" > "$lines" 2>/dev/null || die "策略 JSON 无法解析(需要 jq 或 python)"
        else
            cp -f "$src" "$lines"
        fi
    fi
    [ -s "$lines" ] || die "策略内容为空"

    revision="$(policy_line_get "$lines" revision)"
    is_num "$revision" || revision=""
    log_info "应用策略 revision=${revision:-未知}"

    realdb="$VPNX_USERS_DB"
    workdb="$VPNX_STATE_DIR/users.db.policywork"
    cp -f "$VPNX_CONF" "$VPNX_STATE_DIR/vpnx.conf.policybak" 2>/dev/null || true
    cp -f "$realdb" "$VPNX_STATE_DIR/users.db.policybak" 2>/dev/null || true
    cp -f "$realdb" "$workdb" 2>/dev/null || : > "$workdb"
    # 从这里开始所有账号操作都作用于工作副本, 校验也基于工作副本渲染,
    # 只有全部通过才会覆盖真实账号库(失败时真实库与配置都没被改过)。
    VPNX_USERS_DB="$workdb"

    local node_changed=0
    # ---------- 1) 节点级参数 ----------
    local v
    v="$(policy_line_get "$lines" node.log_level)";     [ -n "$v" ] && { cfg_set LOG_LEVEL "$v"; }
    v="$(policy_line_get "$lines" node.reality_target)"; [ -n "$v" ] && { cfg_set REALITY_TARGET "$v"; node_changed=1; }
    v="$(policy_line_get "$lines" node.reality_server_names)"
    if [ -z "$v" ]; then
        # 兼容扁平数组形态(PHP 中台的 flatten 把数组写成 node.reality_server_names.0/.1)
        v="$(awk -F= '/^node\.reality_server_names\.[0-9]+=/ { printf "%s,", $2 }' "$lines" 2>/dev/null | sed 's/,$//')"
    fi
    if [ -n "$v" ]; then
        cfg_set REALITY_SNI "$(printf '%s' "$v" | cut -d, -f1)"
        node_changed=1
    fi
    v="$(policy_line_get "$lines" node.bbr)"
    if [ -n "$v" ]; then
        if is_true "$v"; then bbr_on >/dev/null 2>&1 || true; else bbr_off >/dev/null 2>&1 || true; fi
    fi
    # 端口: 同时兼容节点侧键名(reality/ss/vmess)与中台示例里的协议名键(vless-reality/ss2022/vmess-ws)
    local p pv idx2
    for p in reality ss vmess xhttp; do
        v="$(policy_line_get "$lines" "node.ports.$p")"
        if [ -z "$v" ]; then
            case "$p" in
                reality) pv="vless-reality" ;;
                ss)      pv="ss2022" ;;
                vmess)   pv="vmess-ws" ;;
                xhttp)   pv="vless-xhttp" ;;
            esac
            v="$(policy_line_get "$lines" "node.ports.$pv")"
        fi
        _policy_set_port "$p" "$v" && node_changed=1
    done

    # 入站列表: node.inbounds.N.{protocol,port,enabled}
    for idx2 in $(awk -F= '/^node\.inbounds\.[0-9]+\./ { split($1,a,"."); print a[3] }' "$lines" 2>/dev/null | sort -n -u); do
        p="$(_policy_proto_of "$(policy_line_get "$lines" "node.inbounds.$idx2.protocol")")"
        [ -z "$p" ] && continue
        _policy_set_port "$p" "$(policy_line_get "$lines" "node.inbounds.$idx2.port")" && node_changed=1
        v="$(policy_line_get "$lines" "node.inbounds.$idx2.enabled")"
        if [ -n "$v" ]; then
            case "$p" in
                reality) cfg_set REALITY_ENABLED "$(is_true "$v" && echo 1 || echo 0)" ;;
                ss)      cfg_set SS_ENABLED "$(is_true "$v" && echo 1 || echo 0)" ;;
                vmess)   cfg_set VMESS_ENABLED "$(is_true "$v" && echo 1 || echo 0)" ;;
                xhttp)   cfg_set XHTTP_ENABLED "$(is_true "$v" && echo 1 || echo 0)" ;;
            esac
        fi
    done

    # 协议白名单(allow_protocols): 不在名单内的协议会被关闭(但不会三个全关)
    _policy_apply_allow_protocols "$lines" && node_changed=1

    # 档位热更新: profiles.<名字>.{type,params.*}
    # 中台档位名(std/ss)与节点内置档位名(reality-vision/ss2022)可能不同,
    # 先按名字找, 找不到就按 type 找同类型的本地档位; 参数最终要落到 vpnx.conf 才生效。
    local pname ptype pkey pval lname
    for pname in $(awk -F= '/^profiles\./ { split($1,a,"."); print a[2] }' "$lines" 2>/dev/null | sort -u); do
        ptype="$(policy_line_get "$lines" "profiles.$pname.type")"
        lname="$(_resolve_local_profile "$pname" "$ptype")"
        if [ -z "$lname" ]; then
            log_warn "策略档位 $pname (type=${ptype:-未知}) 在本节点没有对应档位, 已跳过"
            continue
        fi
        for pkey in flow fingerprint spider_x spx network method target dest sni server_names path host; do
            pval="$(policy_line_get "$lines" "profiles.$pname.params.$pkey")"
            [ -z "$pval" ] && continue
            pval="$(printf '%s' "$pval" | cut -d, -f1)"
            log_info "档位 $pname -> $lname: $pkey=$pval"
            _policy_apply_profile_param "$lname" "$ptype" "$pkey" "$pval" && node_changed=1
        done
    done

    # ---------- 2) 账号级参数(仍作用于工作副本) ----------
    local idxs idx action uname
    idxs="$(awk -F= '/^users\.[0-9]+\./ { split($1,a,"."); print a[2] }' "$lines" 2>/dev/null | sort -n -u)"
    if [ -n "$idxs" ]; then
        for idx in $idxs; do
            action="$(policy_line_get "$lines" "users.$idx.action")"
            uname="$(policy_line_get "$lines" "users.$idx.name")"
            [ -z "$action" ] && action="upsert"
            if [ -z "$uname" ]; then
                log_warn "策略 users.$idx 缺少 name, 跳过"
                continue
            fi
            case "$action" in
                delete)
                    if user_exists "$uname"; then
                        _policy_user_delete "$uname"
                        log_info "策略: 删除账号 $uname"
                    fi
                    ;;
                disable)
                    if user_exists "$uname"; then
                        user_set_field "$uname" $USER_F_ENABLED 0
                        log_info "策略: 停用账号 $uname"
                    fi
                    ;;
                upsert|*)
                    _policy_user_upsert "$lines" "$idx" "$uname"
                    ;;
            esac
        done
    fi
    VPNX_USERS_DB="$realdb"

    # ---------- 3) 渲染校验(基于工作副本, 才能真正校验策略带来的账号变化) ----------
    if ! render_config "$VPNX_TMP_DIR/policy.new.json" || ! xray_test "$VPNX_TMP_DIR/policy.new.json"; then
        log_err "策略渲染/校验失败, 已放弃本次策略(账号库与配置均未改动)"
        VPNX_USERS_DB="$realdb"
        rm -f "$workdb"
        _agent_set_last_error "策略渲染或校验失败 revision=${revision:-?}"
        agent_event ERROR "policy_invalid" "策略渲染或校验失败, 已放弃"
        if [ -n "$revision" ]; then
            agent_ack "$revision" "failed" "策略渲染或校验失败"
        fi
        return 1
    fi

    # ---------- 4) 提交 ----------
    VPNX_USERS_DB="$realdb"
    cp -f "$workdb" "$realdb"
    rm -f "$workdb"
    if ! apply_config; then
        log_err "配置落地失败, 回滚账号库"
        cp -f "$VPNX_STATE_DIR/users.db.policybak" "$realdb" 2>/dev/null || true
        cp -f "$VPNX_STATE_DIR/vpnx.conf.policybak" "$VPNX_CONF" 2>/dev/null || true
        _agent_set_last_error "策略落地失败"
        [ -n "$revision" ] && agent_ack "$revision" "failed" "配置落地失败"
        return 1
    fi

    # 节点级参数(端口/伪装)变化需要重启内核
    if [ "$node_changed" = "1" ]; then
        log_info "节点级参数有变化, 重启内核"
        if ! xray_restart; then
            log_err "内核重启失败, 回滚配置"
            health_rollback
            [ -n "$revision" ] && agent_ack "$revision" "failed" "内核重启失败"
            return 1
        fi
        # 端口可能被改过: 重新放行, 否则新端口在本机防火墙上仍是关闭的
        _agent_refresh_firewall
    fi

    # ---------- 5) 热同步运行中的内核 ----------
    _agent_hot_sync "$VPNX_STATE_DIR/users.db.policybak" "$realdb"

    if [ -n "$revision" ]; then
        cfg_set POLICY_REVISION "$revision"
        cp -f "$lines" "$VPNX_POLICY_APPLIED" 2>/dev/null || true
        agent_ack "$revision" "applied" ""
    fi
    _agent_set_last_error ""
    log_ok "策略已应用 (revision=${revision:-未知})"

    # ---------- 6) 中台推送的脚本自升级(放最后: 不影响本次策略应用) ----------
    agent_upgrade_check "$lines"
    return 0
}

# 单账号 upsert(工作副本)
_policy_user_upsert() {
    local lines="$1" idx="$2" uname="$3"
    local uuid psk expire quota enabled protos speed devices subtoken note protos_csv="" pp
    uuid="$(policy_line_get "$lines" "users.$idx.uuid")"
    psk="$(policy_line_get "$lines" "users.$idx.ss_password")"
    expire="$(policy_line_get "$lines" "users.$idx.expire_at")"
    quota="$(policy_line_get "$lines" "users.$idx.quota_bytes")"
    enabled="$(policy_line_get "$lines" "users.$idx.enabled")"
    speed="$(policy_line_get "$lines" "users.$idx.speed_mbps")"
    devices="$(policy_line_get "$lines" "users.$idx.max_devices")"
    subtoken="$(policy_line_get "$lines" "users.$idx.sub_token")"
    note="$(policy_line_get "$lines" "users.$idx.note")"

    # 中台可能用 null 表示"由节点生成", 这里统一归一化为空串, 避免把字符串 "null" 当成密钥
    uuid="$(_policy_norm "$uuid")"
    psk="$(_policy_norm "$psk")"
    subtoken="$(_policy_norm "$subtoken")"
    note="$(_policy_norm "$note")"
    enabled="$(_policy_norm "$enabled")"

    # protocols 支持 csv 或扁平数组
    protos="$(policy_line_get "$lines" "users.$idx.protocols")"
    if [ -z "$protos" ]; then
        for pp in $(awk -F= -v p="users.$idx.protocols." 'index($1,p)==1 { print $2 }' "$lines" 2>/dev/null); do
            pp="$(policy_proto_map "$pp")"
            [ -n "$pp" ] && protos_csv="${protos_csv:+$protos_csv,}$pp"
        done
        protos="$protos_csv"
    else
        for pp in $(printf '%s' "$protos" | tr ',' ' '); do
            pp="$(policy_proto_map "$pp")"
            [ -n "$pp" ] && protos_csv="${protos_csv:+$protos_csv,}$pp"
        done
        protos="$protos_csv"
    fi
    [ -z "$protos" ] && protos="$(cfg_get DEFAULT_PROTOCOLS reality)"

    is_num "$expire" || expire="$(parse_expire "${expire:-0}")"
    is_num "$quota" || quota="$(size_to_bytes "${quota:-0}")"
    [ -z "$enabled" ] && enabled=1
    is_num "$speed" || speed=0
    is_num "$devices" || devices=0

    if user_exists "$uname"; then
        [ -n "$uuid" ] && user_set_field "$uname" $USER_F_UUID "$uuid"
        [ -n "$psk" ]  && user_set_field "$uname" $USER_F_SSPSK "$psk"
        [ -n "$expire" ] && user_set_field "$uname" $USER_F_EXPIRE "$expire"
        user_set_field "$uname" $USER_F_QUOTA "$quota"
        user_set_field "$uname" $USER_F_PROTOS "$protos"
        user_set_field "$uname" $USER_F_SPEED "$speed"
        user_set_field "$uname" $USER_F_DEVICES "$devices"
        user_set_field "$uname" $USER_F_ENABLED "$([ "$enabled" = "1" ] || is_true "$enabled" && echo 1 || echo 0)"
        [ -n "$subtoken" ] && user_set_field "$uname" $USER_F_SUBTOKEN "$subtoken"
        [ -n "$note" ] && user_set_field "$uname" $USER_F_NOTE "$note"
        log_info "策略: 更新账号 $uname"
    else
        [ -z "$uuid" ] && uuid="$(gen_uuid)"
        if proto_in "$protos" ss && [ -z "$psk" ]; then
            psk="$(ss_gen_psk "$(ss_psk_len_for_method "$(cfg_get SS_METHOD '')")")"
        fi
        [ -z "$subtoken" ] && subtoken="$(rand_hex 16)"
        printf '%s|%s|%s|%s|%s|0|0|%s|%s|%s|%s|%s|%s|%s\n' \
            "$uname" "$uuid" "$([ "$enabled" = "1" ] || is_true "$enabled" && echo 1 || echo 0)" \
            "$expire" "$quota" "$speed" "$devices" "$protos" "$psk" "$subtoken" \
            "$(now_epoch)" "$(printf '%s' "$note" | tr -d '|\r\n')" >> "$VPNX_USERS_DB"
        log_info "策略: 新增账号 $uname"
    fi
    return 0
}

_policy_user_delete() {
    local uname="$1" tmp
    tmp="$VPNX_USERS_DB.tmp.$$"
    awk -F'|' -v n="$uname" '$1!=n' "$VPNX_USERS_DB" > "$tmp" 2>/dev/null || : > "$tmp"
    cat "$tmp" > "$VPNX_USERS_DB"
    rm -f "$tmp"
    return 0
}

# 档位文件里替换某个参数
_profile_param_set() {
    local pf="$1" key="$2" val="$3" tmp
    tmp="$pf.tmp.$$"
    if grep -q "\"$key\"" "$pf" 2>/dev/null; then
        sed "s|\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"$key\": \"$val\"|" "$pf" > "$tmp" 2>/dev/null \
            && cat "$tmp" > "$pf"
    else
        log_warn "档位 $(basename "$pf") 中没有参数 $key, 已忽略"
    fi
    rm -f "$tmp"
    return 0
}

# 对比新旧账号库, 把差异热同步到运行中的内核
_agent_hot_sync() {
    local olddb="$1" newdb="$2" name old_enabled new_enabled old_uuid new_uuid old_psk new_psk protos
    [ -f "$olddb" ] || olddb="/dev/null"
    api_ready || return 0

    # 删除与停用 -> rmu
    local oldnames
    oldnames="$(awk -F'|' 'NF>=10 && $1!~/^#/ { print $1 }' "$olddb" 2>/dev/null)"
    for name in $oldnames; do
        local in_new=0
        if awk -F'|' -v n="$name" '$1==n { found=1 } END { exit(found?0:1) }' "$newdb" 2>/dev/null; then
            in_new=1
        fi
        old_enabled="$(awk -F'|' -v n="$name" '$1==n { print $3; exit }' "$olddb")"
        new_enabled="$(awk -F'|' -v n="$name" '$1==n { print $3; exit }' "$newdb")"
        protos="$(awk -F'|' -v n="$name" '$1==n { print $10; exit }' "$olddb")"
        if [ "$in_new" = "0" ] || { is_true "$old_enabled" && ! is_true "$new_enabled"; }; then
            local p tag email
            for p in $(printf '%s' "$protos" | tr ',' ' '); do
                tag="$(proto_tag "$p")"; [ -z "$tag" ] && continue
                email="$(user_email "$name" "$p")"
                api_remove_user "$tag" "$email" >/dev/null 2>&1 || true
            done
            log_debug "热同步: 移除/停用 $name"
        fi
    done

    # 新增与重新启用 -> adu; 凭证变化 -> 先 rmu 再 adu
    local newnames
    newnames="$(awk -F'|' 'NF>=10 && $1!~/^#/ { print $1 }' "$newdb" 2>/dev/null)"
    for name in $newnames; do
        local in_old=0
        if awk -F'|' -v n="$name" '$1==n { found=1 } END { exit(found?0:1) }' "$olddb" 2>/dev/null; then
            in_old=1
        fi
        old_enabled="$(awk -F'|' -v n="$name" '$1==n { print $3; exit }' "$olddb")"
        new_enabled="$(awk -F'|' -v n="$name" '$1==n { print $3; exit }' "$newdb")"
        old_uuid="$(awk -F'|' -v n="$name" '$1==n { print $2; exit }' "$olddb")"
        new_uuid="$(awk -F'|' -v n="$name" '$1==n { print $2; exit }' "$newdb")"
        old_psk="$(awk -F'|' -v n="$name" '$1==n { print $11; exit }' "$olddb")"
        new_psk="$(awk -F'|' -v n="$name" '$1==n { print $11; exit }' "$newdb")"
        is_true "$new_enabled" || continue

        if [ "$in_old" = "0" ] || { ! is_true "$old_enabled"; }; then
            user_hot_add "$name" >/dev/null 2>&1 || true
            log_debug "热同步: 新增/启用 $name"
        elif [ "$old_uuid" != "$new_uuid" ] || [ "$old_psk" != "$new_psk" ]; then
            # 凭证变化必须先踢掉旧连接
            local protos_new
            protos_new="$(awk -F'|' -v n="$name" '$1==n { print $10; exit }' "$newdb")"
            local p tag email
            for p in $(printf '%s' "$protos_new" | tr ',' ' '); do
                tag="$(proto_tag "$p")"; [ -z "$tag" ] && continue
                email="$(user_email "$name" "$p")"
                api_remove_user "$tag" "$email" >/dev/null 2>&1 || true
            done
            user_hot_add "$name" "$protos_new" >/dev/null 2>&1 || true
            log_debug "热同步: 凭证变更并重载 $name"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# 上报
# ---------------------------------------------------------------------------
agent_ack() {
    local revision="$1" result="$2" err="${3:-}" body
    body="$(printf '{"node_id":"%s","report_type":"ack","revision":%s,"usage":[],"events":[],"ack":{"policy_revision":%s,"result":"%s","error":"%s"}}' \
        "$(json_escape "$(agent_cfg NODE_ID '')")" "${revision:-0}" "${revision:-0}" "$result" "$(json_escape "$err")")"
    agent_request POST "/api/v1/node/report" "$body" >/dev/null 2>&1 || log_warn "策略 ack 上报失败"
    return 0
}

agent_report_usage() {
    local usage="" name first=1 up down ips
    for name in $(users_all_names); do
        up="$(user_field "$name" $USER_F_UP)"; is_num "$up" || up=0
        down="$(user_field "$name" $USER_F_DOWN)"; is_num "$down" || down=0
        [ "$first" = "1" ] || usage="$usage,"
        usage="$usage$(printf '{"name":"%s","email":"%s","up":%s,"down":%s,"online_ips":0,"last_seen":%s}' \
            "$(json_escape "$name")" "$(json_escape "$(user_email "$name" reality)")" "$up" "$down" "$(now_epoch)")"
        first=0
    done

    local body events
    events="$(_events_json_array)"
    body="$(printf '{"node_id":"%s","report_type":"usage","revision":%s,"usage":[%s],"events":%s,"ack":null}' \
        "$(json_escape "$(agent_cfg NODE_ID '')")" "$(cfg_get POLICY_REVISION 0)" "$usage" "$events")"

    if agent_request POST "/api/v1/node/report" "$body" >/dev/null 2>&1; then
        if [ -f "$AGENT_EVENTS" ]; then
            mv -f "$AGENT_EVENTS" "$AGENT_EVENTS.sent.$(date '+%s')" 2>/dev/null || rm -f "$AGENT_EVENTS"
            ls -1t "$VPNX_STATE_DIR"/events.jsonl.sent.* 2>/dev/null | tail -n +6 | while read -r f; do rm -f "$f"; done
        fi
        return 0
    fi
    return 1
}

agent_push_subs() {
    local users="" name first=1 links tok meta clash clash_raw
    for name in $(users_all_names); do
        tok="$(user_field "$name" $USER_F_SUBTOKEN)"
        [ -z "$tok" ] && tok="$(sub_token_ensure "$name")"
        links="$(sub_links "$name")"
        [ -z "$links" ] && continue
        # 链接数组
        local arr="" l firstl=1
        while IFS= read -r l; do
            [ -z "$l" ] && continue
            [ "$firstl" = "1" ] || arr="$arr,"
            arr="$arr\"$(json_escape "$l")\""
            firstl=0
        done <<EOF
$links
EOF
        meta="$(sub_meta "$name" | tr '\n' ';')"
        # 注意: json_escape 从参数取值(不读 stdin), 所以必须先落到变量再转义,
        # 不能写成 `sub_clash | json_escape`(那样会得到空串, 客户端拿不到 Clash 配置)。
        clash_raw="$(sub_clash "$name")"
        clash="$(json_escape "$clash_raw")"
        [ "$first" = "1" ] || users="$users,"
        users="$users$(printf '{"name":"%s","email":"%s","sub_token":"%s","expire_at":%s,"quota_bytes":%s,"used_bytes":%s,"links":[%s],"extra":{"meta":"%s","clash_yaml":"%s"}}' \
            "$(json_escape "$name")" "$(json_escape "$(user_email "$name" reality)")" "$tok" \
            "$(user_field "$name" $USER_F_EXPIRE)" "$(user_field "$name" $USER_F_QUOTA)" \
            "$(( $(user_field "$name" $USER_F_UP) + $(user_field "$name" $USER_F_DOWN) ))" \
            "$arr" "$(json_escape "$meta")" "$clash")"
        first=0
    done
    [ "$first" = "1" ] && { log_debug "没有可推送的订阅"; return 0; }

    local body
    body="$(printf '{"node_id":"%s","users":[%s]}' "$(json_escape "$(agent_cfg NODE_ID '')")" "$users")"
    if agent_request POST "/api/v1/node/subscription" "$body" >/dev/null 2>&1; then
        log_ok "订阅已推送到中台"
        return 0
    fi
    log_warn "订阅推送失败(下次同步会重试)"
    return 1
}

# ---------------------------------------------------------------------------
# 一次完整同步
# ---------------------------------------------------------------------------
agent_state_get() { kv_get "$AGENT_STATE" "$1" "${2:-}"; }
agent_state_set() { kv_set "$AGENT_STATE" "$1" "$2"; }

agent_run_once() {
    local force=0
    has_flag --force "$@" && force=1
    # 人工在终端里执行时默认强制执行(想同步就同步);
    # 定时任务(cron/systemd timer)没有 TTY, 仍然按 INTERVAL 节流。
    if [ -t 1 ]; then
        force=1
    fi

    require_installed
    if ! agent_enabled; then
        log_debug "中台同步未启用(设置 SYNC_ENABLED=1 与 agent.conf 后生效)"
        return 0
    fi

    lock_acquire 20 || return 1

    # 节流: 定时器是每分钟触发一次, 真正的间隔由 SYNC_INTERVAL 控制
    local interval last now elapsed
    interval="$(agent_cfg INTERVAL 60)"
    is_num "$interval" || interval=60
    last="$(agent_state_get LAST_SYNC 0)"
    is_num "$last" || last=0
    now="$(now_epoch)"
    elapsed=$((now - last))
    if [ "$force" != "1" ] && [ "$last" != "0" ] && [ "$elapsed" -lt "$interval" ]; then
        log_debug "距上次同步 ${elapsed}s < ${interval}s, 跳过(立即执行请加 --force: vpnx agent run-once --force)"
        return 0
    fi

    log_info "开始中台同步 (node=$(agent_cfg NODE_ID '-'))"

    # 1) 本地状态先行: 用量累计 + 配额/到期强制 + 设备数
    user_sync_traffic >/dev/null 2>&1 || true
    user_enforce >/dev/null 2>&1 || true
    user_check_devices >/dev/null 2>&1 || true

    # 2) 心跳
    local hb_ok=0
    if agent_heartbeat; then
        hb_ok=1
        agent_state_set LAST_HEARTBEAT "$now"
    else
        log_warn "心跳失败, 本轮只做本地维护"
        agent_state_set LAST_SYNC "$now"
        agent_state_set LAST_RESULT "heartbeat_failed"
        return 1
    fi

    # 3) 策略
    if [ "${AGENT_POLICY_PENDING:-}" = "true" ] || [ -n "${AGENT_POLICY_REVISION:-}" ]; then
        local cur
        cur="$(cfg_get POLICY_REVISION 0)"
        if [ -n "${AGENT_POLICY_REVISION:-}" ] && [ "${AGENT_POLICY_REVISION}" != "$cur" ]; then
            local lines
            if lines="$(agent_pull_policy)"; then
                agent_apply_policy "$VPNX_POLICY" "$lines" || log_warn "策略应用失败, 已保留原状态"
            fi
        fi
    fi

    # 4) 订阅推送(账号/端口等有变化时立即推; 上次失败则重试; 否则每 10 轮兜底推一次)
    local run_no push_flag subsig
    subsig="$(_agent_subscription_signature)"
    if [ "$subsig" != "$(agent_state_get SUB_SIG '')" ]; then
        agent_state_set SUB_SIG "$subsig"
        agent_state_set NEED_PUSH 1
        log_debug "账号或端口配置有变化, 本轮重推订阅"
    fi
    run_no="$(agent_state_get RUN_NO 0)"; is_num "$run_no" || run_no=0
    run_no=$((run_no + 1))
    agent_state_set RUN_NO "$run_no"
    push_flag="$(agent_state_get NEED_PUSH 0)"
    if [ "$push_flag" = "1" ] || [ "$force" = "1" ] || [ $((run_no % 10)) -eq 0 ]; then
        if agent_push_subs; then
            agent_state_set NEED_PUSH 0
        else
            agent_state_set NEED_PUSH 1
        fi
    fi

    # 5) 用量与事件上报
    if agent_report_usage; then
        agent_state_set LAST_REPORT "$now"
    else
        log_warn "用量上报失败(数据已本地累计, 下次重试)"
    fi

    agent_state_set LAST_SYNC "$now"
    agent_state_set LAST_RESULT "ok"
    log_ok "同步完成 (revision=$(cfg_get POLICY_REVISION 0))"
    return 0
}

# ---------------------------------------------------------------------------
# 安装/卸载定时任务
# ---------------------------------------------------------------------------
agent_install() {
    require_root
    require_installed
    local self="/usr/local/bin/vpnx"
    if [ ! -x "$self" ]; then
        self="$VPNX_HOME/vpnx.sh"
    fi
    sched_install "agent" "vpnx 中台同步" "every:60" "$self agent run-once"
    sched_install "health" "vpnx 健康看护" "every:120" "$self health watch"
    log_ok "已安装定时任务(agent 每 60s 触发, health 每 120s 触发)"
    log_info "实际同步频率由 agent.conf 的 INTERVAL 控制"
    return 0
}

agent_uninstall() {
    sched_remove "agent"
    sched_remove "health"
    return 0
}

agent_status() {
    printf '中台地址    : %s\n' "$(agent_cfg URL '-')"
    printf '节点 ID     : %s\n' "$(agent_cfg NODE_ID '-')"
    printf '令牌        : %s\n' "$([ -n "$(agent_cfg TOKEN '')" ] && echo '已配置' || echo '未配置')"
    printf '同步开关    : %s\n' "$([ "$(cfg_get SYNC_ENABLED 0)" = "1" ] && echo 启用 || echo 停用)"
    printf '同步间隔    : %s 秒\n' "$(agent_cfg INTERVAL 60)"
    printf '跳过证书校验: %s\n' "$(agent_cfg INSECURE 0)"
    printf '当前策略版本: %s\n' "$(cfg_get POLICY_REVISION 0)"
    printf '上次同步    : %s\n' "$(epoch_to_str "$(agent_state_get LAST_SYNC 0)")"
    printf '上次心跳    : %s\n' "$(epoch_to_str "$(agent_state_get LAST_HEARTBEAT 0)")"
    printf '上次结果    : %s\n' "$(agent_state_get LAST_RESULT '-')"
    printf '待上报事件  : %s 条\n' "$( [ -f "$AGENT_EVENTS" ] && wc -l < "$AGENT_EVENTS" | tr -d ' ' || echo 0)"
    printf '最后错误    : %s\n' "$(_agent_last_error)"
    printf '定时任务    :\n'
    sched_status "agent" 2>/dev/null | sed 's/^/  /' || printf '  (未安装)\n'
    return 0
}

# ---------------------------------------------------------------------------
# 中台可达性探测(免鉴权): 用来区分"地址/网络不通" 与 "鉴权失败"
# ---------------------------------------------------------------------------
_agent_probe_health() {
    local url base insecure out code err target
    url="$(agent_cfg URL '')"
    [ -n "$url" ] || { log_err "未配置中台 URL, 请先执行: vpnx agent set --url ... --node-id ... --token ..."; return 1; }
    have_cmd curl || { log_err "缺少 curl, 无法同步"; return 1; }
    insecure="$(agent_cfg INSECURE 0)"
    base="${url%/}"
    target="$(_agent_request_url "$base" "/api/v1/admin/health" "")"
    tmp_init
    out="$VPNX_TMP_DIR/health.json"
    err="$VPNX_TMP_DIR/health.err"
    code="$(curl -sS -L --max-redirs 3 -o "$out" -w '%{http_code}' \
        --connect-timeout 10 --max-time 20 \
        $([ "$insecure" = "1" ] && printf '%s' '-k') \
        "$target" 2>"$err")" || code="000"
    case "$code" in
        2*)
            log_ok "中台可达($code): $(head -c 200 "$out" 2>/dev/null | tr '\n' ' ')"
            return 0 ;;
        000)
            log_err "中台不可达: $target"
            log_err "  curl 报错: $(head -c 200 "$err" 2>/dev/null | tr '\n' ' ')"
            return 1 ;;
        *)
            log_warn "中台健康检查返回 $code(非 2xx): $(head -c 200 "$out" 2>/dev/null | tr '\n' ' ')"
            log_warn "  探测地址: $target"
            return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
cmd_agent() {
    local sub="${1:-status}"
    if [ $# -gt 0 ]; then shift; fi
    case "$sub" in
        install)   agent_install ;;
        uninstall) require_root; agent_uninstall ;;
        set)       require_root; agent_set "$@" ;;
        run-once)  agent_run_once "$@" ;;
        status)    agent_status ;;
        test)
            require_root
            require_installed
            printf '中台地址    : %s\n' "$(agent_cfg URL '-')"
            printf '节点 ID     : %s\n' "$(agent_cfg NODE_ID '-')"
            printf '令牌        : %s\n' "$([ -n "$(agent_cfg TOKEN '')" ] && echo 已配置 || echo '未配置!')"
            printf '跳过证书校验: %s\n' "$(agent_cfg INSECURE 0)"
            printf '本机时间    : %s\n' "$(now_str)"
            printf '\n[1/2] 免鉴权探测(判断地址与网络是否通)\n'
            _agent_probe_health || true
            printf '\n[2/2] 带签名心跳(验证节点注册与密钥)\n'
            if agent_heartbeat; then
                log_ok "中台连通正常 (policy_revision=${AGENT_POLICY_REVISION:-?}, pending=${AGENT_POLICY_PENDING:-?})"
                return 0
            fi
            printf '\n排查顺序:\n'
            printf '  1) agent.conf 的 URL 是否能直接访问到 api.php(未配 rewrite 时必须带 /api.php)\n'
            printf '  2) 中台"节点"页里该节点 ID 与 token 是否与这里一致\n'
            printf '  3) 两侧时间差是否小于 300 秒(用 date 与中台对比)\n'
            printf '  4) 中台站点 data/ 目录对 PHP 用户是否可写, 否则会返回 500\n'
            die "中台连通失败"
            ;;
        *)
            printf '用法: vpnx agent install|uninstall|set|run-once|status|test\n'
            printf '      vpnx agent run-once [--force]     --force 忽略同步间隔, 立刻执行一次\n'
            printf '      vpnx agent set --url https://central.example.com --node-id n1 --token SECRET [--interval 60] [--insecure 1]\n'
            return 2
            ;;
    esac
}

cmd_policy() {
    local sub="${1:-show}"
    if [ $# -gt 0 ]; then shift; fi
    require_root
    require_installed
    case "$sub" in
        apply)
            [ -n "${1:-}" ] || die "用法: vpnx policy apply <文件|->"
            local f="$1"
            if [ "$f" = "-" ]; then
                tmp_init
                f="$VPNX_TMP_DIR/policy.stdin"
                cat > "$f"
            fi
            lock_acquire 30
            agent_apply_policy "$f" ""
            ;;
        pull)
            lock_acquire 30
            local lines
            if lines="$(agent_pull_policy)"; then
                agent_apply_policy "$VPNX_POLICY" "$lines"
            else
                log_info "没有需要应用的策略"
            fi
            ;;
        show)
            printf '当前 revision: %s\n' "$(cfg_get POLICY_REVISION 0)"
            if [ -f "$VPNX_POLICY_APPLIED" ]; then
                printf '已应用策略文件: %s\n' "$VPNX_POLICY_APPLIED"
                sed 's/^/  /' "$VPNX_POLICY_APPLIED" | head -n 60
            else
                printf '(还没有应用过中台策略)\n'
            fi
            ;;
        *)
            printf '用法: vpnx policy apply <文件|-> | vpnx policy pull | vpnx policy show\n'
            return 2
            ;;
    esac
}
