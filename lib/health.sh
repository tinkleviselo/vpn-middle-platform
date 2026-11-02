#!/usr/bin/env bash
# ==============================================================================
#  lib/health.sh - 健康检查 / 自愈 / 配置快照回滚
#  自动维护闭环: 检查 -> 发现问题 -> 修复(重启/回滚/重渲染/重放行) -> 上报中台
#  任何"改动配置"的动作都先快照 last-good, 失败自动回滚, 避免把节点改挂
# ==============================================================================

HEALTH_STATE="$VPNX_STATE_DIR/health.state"
LAST_GOOD="$VPNX_STATE_DIR/last-good.json"

# ---------------------------------------------------------------------------
# 快照与回滚
# ---------------------------------------------------------------------------
health_snapshot() {
    [ -f "$VPNX_XRAY_CONF" ] || return 0
    ensure_dir "$VPNX_STATE_DIR"
    if [ "${DRY_RUN:-0}" != "1" ]; then
        cp -f "$VPNX_XRAY_CONF" "$LAST_GOOD" 2>/dev/null || true
    fi
    log_debug "已保存配置快照: $LAST_GOOD"
    return 0
}

health_rollback() {
    if [ ! -f "$LAST_GOOD" ]; then
        log_warn "没有可用快照, 无法回滚"
        return 1
    fi
    if ! xray_test "$LAST_GOOD"; then
        log_err "快照本身校验失败, 拒绝回滚"
        return 1
    fi
    cp -f "$LAST_GOOD" "$VPNX_XRAY_CONF" 2>/dev/null || return 1
    log_warn "已回滚到上一个可用配置"
    agent_event WARN "config_rollback" "配置校验/启动失败, 已回滚到上一个可用配置"
    if ! xray_restart; then
        log_err "回滚后内核仍未启动, 请人工介入"
        return 1
    fi
    log_ok "回滚后内核运行正常"
    return 0
}

# ---------------------------------------------------------------------------
# 单项检查
# ---------------------------------------------------------------------------
_health_fail=0
_health_warn=0
_ok()   { printf '  %s[正常]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
_bad()  { printf '  %s[异常]%s %s\n' "$C_RED" "$C_RST" "$*"; _health_fail=$((_health_fail + 1)); }
_warn() { printf '  %s[注意]%s %s\n' "$C_YEL" "$C_RST" "$*"; _health_warn=$((_health_warn + 1)); }

# 配置里启用的协议端口是否都在监听(0 = 全部一致)
health_ports_match() {
    local p port
    for p in reality ss vmess xhttp; do
        user_proto_active "$p" || continue
        case "$p" in
            reality) port="$(cfg_get REALITY_PORT '')" ;;
            ss)      port="$(cfg_get SS_PORT '')" ;;
            vmess)   port="$(cfg_get VMESS_PORT '')" ;;
            xhttp)   port="$(cfg_get XHTTP_PORT '')" ;;
        esac
        [ -z "$port" ] && continue
        port_in_use "$port" tcp || return 1
    done
    return 0
}

health_check() {
    local quiet="${1:-}"
    _health_fail=0; _health_warn=0
    require_installed

    [ "$quiet" = "quiet" ] || printf '== vpnx 健康检查 %s ==\n' "$(now_str)"

    # 1) 服务
    if xray_is_running; then
        _ok "内核服务运行中 ($(xray_installed_version 2>/dev/null))"
    else
        _bad "内核服务未运行"
    fi

    # 2) 配置
    if [ -f "$VPNX_XRAY_CONF" ]; then
        if xray_test "$VPNX_XRAY_CONF"; then
            _ok "配置文件有效"
        else
            _bad "配置文件校验失败 ($VPNX_XRAY_CONF)"
        fi
    else
        _bad "配置文件不存在 ($VPNX_XRAY_CONF)"
    fi

    # 3) 端口监听(同时报告内核真实监听的端口, 便于发现"配置与运行不一致")
    local p port got=0 actual
    actual="$(xray_listen_ports)"
    for p in reality ss vmess xhttp; do
        user_proto_active "$p" || continue
        case "$p" in
            reality) port="$(cfg_get REALITY_PORT '')" ;;
            ss)      port="$(cfg_get SS_PORT '')" ;;
            vmess)   port="$(cfg_get VMESS_PORT '')" ;;
            xhttp)   port="$(cfg_get XHTTP_PORT '')" ;;
        esac
        [ -z "$port" ] && { _bad "$p 已启用但端口未配置"; continue; }
        if port_in_use "$port" tcp; then
            _ok "$p 正在监听 $port/tcp"
            got=$((got + 1))
        else
            _bad "$p 配置端口 $port/tcp 无监听; 内核实际监听: ${actual:-无} → 配置与运行不一致, 执行 vpnx health fix 会自动重启内核对齐"
        fi
    done

    # SS 入站的用户列表字段名必须是 clients
    #   Xray 对未知字段是"静默忽略": 写成 users 时服务端等于没注册任何用户,
    #   SS2022 会丢弃所有连接(客户端超时, 服务端连日志都没有)。
    if [ -f "$VPNX_XRAY_CONF" ] && is_true "$(cfg_get SS_ENABLED 0)"; then
        if grep -qE '^        "users": \[' "$VPNX_XRAY_CONF"; then
            _bad "SS 入站用户列表字段名错误: 必须是 clients(Xray 静默忽略 users, 会导致 SS 全部连接超时)"
        fi
    fi

    # 4) 管理 API
    if api_ready; then
        _ok "管理 API 可用 ($(api_server))"
    else
        _warn "管理 API 不可用(账号热加载与用量统计会退化)"
    fi

    # 5) 时间同步(REALITY 对时间偏差敏感)
    local year
    year="$(date '+%Y')"
    if [ "$year" -lt 2024 ]; then
        _bad "系统时间异常($(date '+%Y-%m-%d %H:%M:%S')), REALITY 会握手失败"
    else
        if svc_is_active chronyd || svc_is_active ntpd || svc_is_active systemd-timesyncd || svc_is_active ntp; then
            _ok "时间同步服务运行中"
        else
            _warn "未发现运行中的时间同步服务(建议开启 chronyd/ntp, REALITY 对时间差敏感)"
        fi
    fi

    # 6) 磁盘
    local use
    use="$(df -P "$VPNX_LOG_DIR" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
    if is_num "$use"; then
        if [ "$use" -ge 95 ]; then
            _bad "日志分区使用率 ${use}%"
        elif [ "$use" -ge 85 ]; then
            _warn "日志分区使用率 ${use}%"
        else
            _ok "磁盘使用率 ${use}%"
        fi
    fi

    # 7) 账号库
    local dupes badlines
    badlines="$(awk -F'|' 'NF>=10 && $1!~/^#/ && NF<14 { print $1 }' "$VPNX_USERS_DB" 2>/dev/null | head -n3)"
    if [ -n "$badlines" ]; then
        _bad "账号库存在字段不足的记录: $badlines"
    fi
    dupes="$(users_all_names | sort | uniq -d | head -n3)"
    if [ -n "$dupes" ]; then
        _bad "账号库存在重名: $dupes"
    else
        _ok "账号库正常 ($(user_count) 个账号)"
    fi

    # 8) 防火墙登记
    if [ -f "$FW_PORTS_FILE" ]; then
        _ok "防火墙已登记端口: $(tr '\n' ' ' < "$FW_PORTS_FILE")"
    else
        _warn "防火墙尚未登记端口(可能未放行, 或本就无需放行)"
    fi

    # 9) 与面板端口冲突
    local conf=""
    for p in reality ss vmess xhttp; do
        user_proto_active "$p" || continue
        case "$p" in
            reality) port="$(cfg_get REALITY_PORT '')" ;;
            ss)      port="$(cfg_get SS_PORT '')" ;;
            vmess)   port="$(cfg_get VMESS_PORT '')" ;;
            xhttp)   port="$(cfg_get XHTTP_PORT '')" ;;
        esac
        [ -z "$port" ] && continue
        if port_conflict_with_panel "$port"; then
            conf="$conf $port"
        fi
    done
    if [ -n "$conf" ]; then
        _bad "端口与面板服务冲突:$conf"
    else
        _ok "未与面板服务抢占端口"
    fi

    # REALITY 伪装目标已知坑
    #   microsoft.com 的证书链过大(约 8273 字节), REALITY 处理这种证书记录时握手无法完成,
    #   表现为"服务端日志 REALITY: processed invalid connection / handshake did not complete
    #   successfully, 客户端全部 timeout", 而参数(密钥/shortId/SNI)看起来完全正确。
    local rtarget rsni
    rtarget="$(cfg_get REALITY_TARGET '')"
    rsni="$(cfg_get REALITY_SNI '')"
    case "$rtarget|$rsni" in
        *microsoft.com*)
            _bad "REALITY 伪装目标含 microsoft.com → 微软证书链过大, REALITY 握手无法完成, 客户端会一直超时"
            printf '       修复: sed -i "s#microsoft\\.com#bing.com#g" /etc/vpnx/vpnx.conf && vpnx health fix && vpnx agent run-once --force\n'
            printf '       (中台「设置 → 节点默认」里的 reality_target/server_names 也要一起改, 否则下次下发会被改回来)\n'
            ;;
        *)
            if [ -n "$rtarget" ]; then
                _ok "REALITY 伪装目标: $rtarget (SNI: ${rsni:-未设置})"
            fi
            ;;
    esac

    # 10) 中台同步
    if agent_enabled; then
        local last result
        last="$(kv_get "$AGENT_STATE" LAST_SYNC 0)"
        result="$(kv_get "$AGENT_STATE" LAST_RESULT '-')"
        if [ "$last" = "0" ]; then
            _warn "中台同步已启用但从未成功同步"
        elif [ $(( $(now_epoch) - last )) -gt 600 ]; then
            _warn "中台同步超过 10 分钟未成功(上次结果: $result)"
        else
            _ok "中台同步正常(上次: $(epoch_to_str "$last"), 结果: $result)"
        fi
    fi

    [ "$quiet" = "quiet" ] || printf '== 结果: %s 项异常, %s 项注意 ==\n' "$_health_fail" "$_health_warn"
    [ "$_health_fail" = "0" ] && return 0
    return 1
}

# ---------------------------------------------------------------------------
# 自愈
# ---------------------------------------------------------------------------
health_fix() {
    require_installed
    local fixed=0

    # 测试/预览模式: 只做配置层面的修复
    if vpnx_no_service; then
        log_info "VPNX_NO_SERVICE=1: 只做配置校验与重渲染"
        if [ -f "$VPNX_XRAY_CONF" ] && ! xray_test "$VPNX_XRAY_CONF"; then
            apply_config || health_rollback || return 1
        fi
        if [ -f "$VPNX_USERS_DB" ] && [ -f "$VPNX_XRAY_CONF" ] && [ "$VPNX_USERS_DB" -nt "$VPNX_XRAY_CONF" ]; then
            apply_config || return 1
        fi
        log_ok "配置检查完成(未触碰服务)"
        return 0
    fi

    # 1) 配置无效 -> 先尝试用账号库重渲染, 再回滚
    if [ -f "$VPNX_XRAY_CONF" ] && ! xray_test "$VPNX_XRAY_CONF"; then
        log_warn "配置无效, 尝试按账号库重渲染"
        if apply_config; then
            fixed=$((fixed + 1))
        elif health_rollback; then
            fixed=$((fixed + 1))
        fi
    fi

    # 2) 配置源(vpnx.conf / 账号库 / 档位)比渲染产物新 -> 重新渲染
    #    手工改过 vpnx.conf、或上次渲染失败时, 都靠这一步兜底
    if [ -f "$VPNX_XRAY_CONF" ]; then
        local need_render=0 pf
        if [ -f "$VPNX_USERS_DB" ] && [ "$VPNX_USERS_DB" -nt "$VPNX_XRAY_CONF" ]; then
            need_render=1
        fi
        if [ -f "$VPNX_CONF" ] && [ "$VPNX_CONF" -nt "$VPNX_XRAY_CONF" ]; then
            need_render=1
        fi
        for pf in "$VPNX_PROFILE_DIR"/*.json; do
            [ -f "$pf" ] || continue
            if [ "$pf" -nt "$VPNX_XRAY_CONF" ]; then
                need_render=1
                break
            fi
        done
        if [ "$need_render" = "1" ]; then
            log_info "配置源比渲染产物新, 重新渲染配置"
            apply_config && fixed=$((fixed + 1))
        fi
    fi

    # 2.5) 运行中的内核监听端口与配置不一致(典型: 改过端口但没重启内核) -> 重启内核
    if ! health_ports_match; then
        log_warn "内核监听端口与配置不一致 (配置 reality=$(cfg_get REALITY_PORT '-') ss=$(cfg_get SS_PORT '-'); 实际监听: $(xray_listen_ports))"
        if xray_restart; then
            log_ok "已重启内核, 现在实际监听: $(xray_listen_ports)"
            fixed=$((fixed + 1))
        else
            log_err "内核重启失败, 见 $VPNX_LOG_DIR/error.log"
        fi
    fi

    # 3) 服务异常 -> 重启
    if ! xray_is_running; then
        log_warn "内核未运行, 尝试启动"
        svc_action start xray >/dev/null 2>&1 || true
        sleep 2
        if xray_is_running; then
            log_ok "内核已启动"
            fixed=$((fixed + 1))
            agent_event INFO "service_restarted" "内核未运行, 已自动拉起"
        else
            log_err "启动失败, 尝试回滚配置后重启"
            if health_rollback; then
                fixed=$((fixed + 1))
            else
                agent_event ERROR "service_start_failed" "内核无法启动且回滚失败, 需人工介入"
                printf '\n--- 最近错误日志 ---\n'
                tail -n 20 "$VPNX_LOG_DIR/error.log" 2>/dev/null || true
                return 1
            fi
        fi
    fi

    # 4) API 不可用但服务在跑 -> 重启一次
    if xray_is_running && ! api_ready; then
        log_warn "管理 API 不可用, 重启内核恢复"
        xray_restart && fixed=$((fixed + 1))
    fi

    # 5) 防火墙端口补齐
    fw_detect
    local p port
    for p in reality ss vmess xhttp; do
        user_proto_active "$p" || continue
        case "$p" in
            reality) port="$(cfg_get REALITY_PORT '')" ;;
            ss)      port="$(cfg_get SS_PORT '')" ;;
            vmess)   port="$(cfg_get VMESS_PORT '')" ;;
            xhttp)   port="$(cfg_get XHTTP_PORT '')" ;;
        esac
        [ -z "$port" ] && continue
        if ! fw_port_registered "$port" tcp; then
            log_info "补放行端口 $port/tcp"
            fw_open "$port" tcp
            fixed=$((fixed + 1))
        elif [ "$FW_MODE" = "iptables" ] && ! _fw_ipt -C VPNX -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
            log_info "iptables 规则缺失, 重建 $port/tcp"
            fw_open_one "$port" tcp
            fixed=$((fixed + 1))
        fi
    done

    # 6) 日志过大 -> 轮转
    local size
    size="$(du -sk "$VPNX_LOG_DIR" 2>/dev/null | awk '{print $1}')"
    if is_num "$size" && [ "$size" -gt 102400 ]; then
        log_info "日志目录超过 100MB, 轮转"
        for f in "$VPNX_LOG_DIR"/*.log; do
            [ -f "$f" ] || continue
            tail -n 2000 "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
        done
        fixed=$((fixed + 1))
    fi

    # 7) 账号用量/配额维护
    user_sync_traffic >/dev/null 2>&1 || true
    user_enforce >/dev/null 2>&1 || true

    if [ "$fixed" = "0" ]; then
        log_ok "无需修复"
    else
        log_ok "已完成 $fixed 项修复"
    fi
    return 0
}

# 看护一轮(给定时任务用): 出错才输出, 正常静默
health_watch() {
    local fails
    fails="$(kv_get "$HEALTH_STATE" FAILS 0)"
    is_num "$fails" || fails=0

    if health_check quiet; then
        if [ "$fails" != "0" ]; then
            log_ok "健康检查恢复正常"
            kv_set "$HEALTH_STATE" FAILS 0
            agent_event INFO "health_recovered" "健康检查恢复正常"
        fi
        kv_set "$HEALTH_STATE" LAST_OK "$(now_epoch)"
        # 定期做轻量维护
        user_sync_traffic >/dev/null 2>&1 || true
        user_enforce >/dev/null 2>&1 || true
        user_check_devices >/dev/null 2>&1 || true
        return 0
    fi

    fails=$((fails + 1))
    kv_set "$HEALTH_STATE" FAILS "$fails"
    kv_set "$HEALTH_STATE" LAST_FAIL "$(now_epoch)"
    log_warn "健康检查异常(第 $fails 次), 执行自愈"
    agent_event WARN "health_failed" "健康检查异常(第 $fails 次), 触发自愈"

    if health_fix; then
        if health_check quiet; then
            log_ok "自愈成功"
            kv_set "$HEALTH_STATE" FAILS 0
            agent_event INFO "health_fixed" "自愈成功"
            return 0
        fi
    fi

    if [ "$fails" -ge 3 ]; then
        log_err "连续 $fails 次自愈失败, 需要人工介入"
        agent_event ERROR "health_unrecoverable" "连续 $fails 次自愈失败, 需要人工介入"
    fi
    return 1
}

# ---------------------------------------------------------------------------
# 节点自测: 用本机 xray 以"客户端身份"逐协议连自己的端口跑真实握手
#   reality / ss / vmess 各自独立测试, 直接告出"哪个协议在节点侧就不通"
#   通过 -> 节点侧参数与链路都正常(问题在客户端或其网络)
#   失败 -> 打印该协议的客户端日志, 直接指出不匹配的地方
# ---------------------------------------------------------------------------

# _selftest_write_config <proto> <名字> <socks端口> <输出文件>
_selftest_write_config() {
    local proto="$1" name="$2" cport="$3" cfile="$4"
    local uuid port sni pbk sid flow net method srvpsk userpsk vpath vhost xpath xmode
    case "$proto" in
        reality)
            port="$(cfg_get REALITY_PORT '')"
            sni="$(cfg_get REALITY_SNI 'www.bing.com')"
            pbk="$(cfg_get REALITY_PUBLIC_KEY '')"
            sid="$(cfg_get REALITY_SHORT_IDS '' | cut -d, -f1)"
            flow="$(cfg_get REALITY_FLOW 'xtls-rprx-vision')"
            net="$(cfg_get REALITY_NETWORK "$(xray_network_default)")"
            uuid="$(user_field "$name" $USER_F_UUID)"
            [ -n "$port" ] && [ -n "$uuid" ] && [ -n "$pbk" ] || return 1
            cat > "$cfile" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"tag": "socks", "listen": "127.0.0.1", "port": $cport, "protocol": "socks", "settings": {"udp": true}}],
  "outbounds": [{
    "tag": "out",
    "protocol": "vless",
    "settings": {"vnext": [{"address": "127.0.0.1", "port": $port, "users": [{"id": "$uuid", "encryption": "none", "flow": "$flow"}]}]},
    "streamSettings": {
      "network": "$net",
      "security": "reality",
      "realitySettings": {"serverName": "$sni", "fingerprint": "chrome", "publicKey": "$pbk", "shortId": "$sid", "spiderX": "/"}
    }
  }]
}
EOF
            ;;
        ss)
            port="$(cfg_get SS_PORT '')"
            method="$(cfg_get SS_METHOD '2022-blake3-aes-128-gcm')"
            srvpsk="$(cfg_get SS_SERVER_PSK '')"
            userpsk="$(user_field "$name" $USER_F_SSPSK)"
            [ -n "$port" ] && [ -n "$srvpsk" ] && [ -n "$userpsk" ] || return 1
            cat > "$cfile" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"tag": "socks", "listen": "127.0.0.1", "port": $cport, "protocol": "socks", "settings": {"udp": true}}],
  "outbounds": [{
    "tag": "out",
    "protocol": "shadowsocks",
    "settings": {"servers": [{"address": "127.0.0.1", "port": $port, "method": "$method", "password": "$srvpsk:$userpsk"}]}
  }]
}
EOF
            ;;
        vmess)
            port="$(cfg_get VMESS_PORT '')"
            uuid="$(user_field "$name" $USER_F_UUID)"
            vpath="$(cfg_get VMESS_PATH '/vpnx-ws')"
            vhost="$(cfg_get VMESS_HOST "$(cfg_get PUBLIC_IP '')")"
            [ -n "$port" ] && [ -n "$uuid" ] || return 1
            cat > "$cfile" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"tag": "socks", "listen": "127.0.0.1", "port": $cport, "protocol": "socks", "settings": {"udp": true}}],
  "outbounds": [{
    "tag": "out",
    "protocol": "vmess",
    "settings": {"vnext": [{"address": "127.0.0.1", "port": $port, "users": [{"id": "$uuid", "alterId": 0, "security": "auto"}]}]},
    "streamSettings": {"network": "ws", "wsSettings": {"path": "$vpath", "headers": {"Host": "$vhost"}}}
  }]
}
EOF
            ;;
        xhttp)
            port="$(cfg_get XHTTP_PORT '')"
            sni="$(cfg_get REALITY_SNI 'www.bing.com')"
            pbk="$(cfg_get REALITY_PUBLIC_KEY '')"
            sid="$(cfg_get REALITY_SHORT_IDS '' | cut -d, -f1)"
            uuid="$(user_field "$name" $USER_F_UUID)"
            xpath="$(cfg_get XHTTP_PATH '/vpnx-xhttp')"
            xmode="$(cfg_get XHTTP_MODE 'auto')"
            [ -n "$port" ] && [ -n "$uuid" ] && [ -n "$pbk" ] || return 1
            cat > "$cfile" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"tag": "socks", "listen": "127.0.0.1", "port": $cport, "protocol": "socks", "settings": {"udp": true}}],
  "outbounds": [{
    "tag": "out",
    "protocol": "vless",
    "settings": {"vnext": [{"address": "127.0.0.1", "port": $port, "users": [{"id": "$uuid", "encryption": "none"}]}]},
    "streamSettings": {
      "network": "$(xray_xhttp_net)",
      "security": "reality",
      "realitySettings": {"serverName": "$sni", "fingerprint": "chrome", "publicKey": "$pbk", "shortId": "$sid", "spiderX": "/"},
      "$(xray_xhttp_key)": {"path": "$xpath", "mode": "$xmode"}
    }
  }]
}
EOF
            ;;
        *) return 1 ;;
    esac
    return 0
}

# 内部协议名 -> 中台协议名(用于给用户看的提示)
proto_policy_name() {
    case "$1" in
        reality) printf 'vless-reality' ;;
        ss)      printf 'ss2022' ;;
        vmess)   printf 'vmess-ws' ;;
        xhttp)   printf 'vless-xhttp' ;;
        *)       printf '%s' "$1" ;;
    esac
}

# 渲染产物里该协议是否已注册该账号(按 email 判断)
#   没注册时自测必然失败(客户端 UUID 未被服务端授权), 提前给出可执行提示
_proto_has_clients() {
    local proto="$1" name="$2" email
    [ -f "$VPNX_XRAY_CONF" ] || return 0
    email="$(user_email "$name" "$proto")"
    [ -n "$email" ] || return 0
    grep -q "\"email\": \"$email\"" "$VPNX_XRAY_CONF"
}

# _selftest_one <proto> <名字> <socks端口>  -> 0 表示该协议通过
_selftest_one() {
    local proto="$1" name="$2" cport="$3"
    local socks cfile clog pid ok=0 target direct code tried=0
    socks="127.0.0.1:$cport"
    cfile="$VPNX_TMP_DIR/selftest.$proto.json"
    clog="$VPNX_TMP_DIR/selftest.$proto.log"
    : > "$clog"

    if ! _selftest_write_config "$proto" "$name" "$cport" "$cfile"; then
        log_err "$proto: 缺少必要参数(端口/密钥/UUID), 无法测试"
        return 1
    fi
    # 账号没被授权该协议时, 服务端会直接断开(客户端表现为瞬间失败/HTTP 000);
    # 这里提前判定并给出可执行的处理办法, 避免又去猜网络或参数。
    if ! _proto_has_clients "$proto" "$name"; then
        log_err "$proto: 该账号没有获得此协议的授权(配置里没有 $name 的 $proto 条目) → 必然失败"
        printf '        处理: 中台「账号」→ 编辑 %s → 协议勾上 %s → 保存, 等一次同步后再自测\n' \
            "$name" "$(proto_policy_name "$proto")"
        return 1
    fi
    if ! xray_test "$cfile"; then
        log_err "$proto: 生成的客户端配置不合法"
        return 1
    fi

    "$XRAY_BIN" run -config "$cfile" >>"$clog" 2>&1 &
    pid=$!
    sleep 2

    # 先确认"节点自己直连"通不通: 直连都不通的地址不能用来判定隧道
    for target in \
        "http://www.msftconnecttest.com/connecttest.txt" \
        "http://cp.cloudflare.com/generate_204" \
        "http://connectivitycheck.gstatic.com/generate_204" \
        "https://www.gstatic.com/generate_204" ; do
        direct="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "$target" 2>/dev/null)"
        case "$direct" in
            ""|000) continue ;;
        esac
        tried=$((tried + 1))
        code="$(curl -sS -m 15 --socks5-hostname "$socks" -o /dev/null -w '%{http_code}' "$target" 2>"$VPNX_TMP_DIR/selftest.$proto.err")"
        case "$code" in
            200|204|301|302) ok=1; break ;;
        esac
    done

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    if [ "$ok" = "1" ]; then
        log_ok "$proto: 通过 ($target -> HTTP $code)"
        return 0
    fi
    if [ "$tried" = "0" ]; then
        log_err "$proto: 无法判定(节点直连所有测试地址都不通, 属于出网受限)"
    else
        log_err "$proto: 失败 ($target -> HTTP ${code:-无})"
    fi
    printf '  --- %s 客户端日志 ---\n' "$proto"
    tail -n 12 "$clog" 2>/dev/null | sed 's/^/  /'
    return 1
}

cmd_selftest() {
    require_root
    require_installed
    os_detect

    local name="${1:-}" n proto ok=0 fail=0
    if [ -z "$name" ]; then
        for n in $(users_all_names); do
            if is_true "$(user_field "$n" $USER_F_ENABLED)"; then
                name="$n"
                break
            fi
        done
    fi
    [ -n "$name" ] || die "没有启用中的账号, 请先执行: vpnx user add <名字>"
    user_exists "$name" || die "账号不存在: $name"

    printf '===== vpnx 节点自测 =====\n'
    printf '账号        : %s\n' "$name"
    printf '账号协议    : %s\n' "$(user_field "$name" $USER_F_PROTOS)"
    printf '实际监听    : %s\n' "$(xray_listen_ports)"
    printf '\n'

    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '%s[dry-run]%s 逐协议生成客户端配置并试连\n' "$C_DIM" "$C_RST"
        return 0
    fi

    tmp_init
    for proto in reality ss vmess xhttp; do
        if ! user_proto_active "$proto"; then
            printf -- '-- %s: 未启用, 跳过\n' "$proto"
            continue
        fi
        if _selftest_one "$proto" "$name" "$(pick_free_port 10808 10809 10810 20808 30808 || printf '10808')"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done
    printf '\n'

    if [ "$fail" = "0" ] && [ "$ok" -gt 0 ]; then
        log_ok "自测通过: 已启用协议在节点侧全部正常 → 客户端若仍不通, 问题在客户端或其网络"
        return 0
    fi
    if [ "$ok" -gt 0 ]; then
        log_warn "部分协议不通: 上面已按协议分别给出结果与日志"
    fi
    printf '提示: 逐协议日志用 warning 级别; 想看服务端判定过程可临时把\n'
    printf '      /etc/vpnx/xray/config.json 的 loglevel 改成 debug 再 systemctl restart xray\n'
    return 1
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
cmd_health() {
    local sub="${1:-check}"
    if [ $# -gt 0 ]; then shift; fi
    case "$sub" in
        check) require_root; health_check ;;
        fix)   require_root; require_installed; health_fix ;;
        watch) require_root; require_installed; health_watch ;;
        selftest|self-test) cmd_selftest "$@" ;;
        snapshot) health_snapshot; log_ok "已保存配置快照" ;;
        rollback) require_root; health_rollback ;;
        *)
            printf '用法: vpnx health check|fix|watch|selftest|snapshot|rollback\n'
            printf '      vpnx selftest [账号名]   用客户端身份连自己的 REALITY 端口做真实握手\n'
            return 2
            ;;
    esac
}