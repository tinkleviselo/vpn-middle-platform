#!/usr/bin/env bash
# ==============================================================================
#  lib/install.sh - 部署 / 卸载 / 升级 / 状态 / 自检
# ==============================================================================

VPNX_INSTALL_DIR="/usr/local/vpnx"
VPNX_BIN_LINK="/usr/local/bin/vpnx"

# ---------------------------------------------------------------------------
# 自安装: 把程序目录放到 /usr/local/vpnx 并建立 vpnx 命令
# ---------------------------------------------------------------------------
self_install() {
    if [ "$VPNX_HOME" != "$VPNX_INSTALL_DIR" ]; then
        log_info "安装程序到 $VPNX_INSTALL_DIR"
        run mkdir -p "$VPNX_INSTALL_DIR"
        run cp -f "$VPNX_HOME/vpnx.sh" "$VPNX_INSTALL_DIR/" 2>/dev/null || true
        run cp -rf "$VPNX_HOME/lib" "$VPNX_INSTALL_DIR/" 2>/dev/null || true
        run cp -rf "$VPNX_HOME/tools" "$VPNX_INSTALL_DIR/" 2>/dev/null || true
        [ -d "$VPNX_HOME/docs" ] && run cp -rf "$VPNX_HOME/docs" "$VPNX_INSTALL_DIR/" 2>/dev/null || true
        run chmod 755 "$VPNX_INSTALL_DIR/vpnx.sh"
        [ -d "$VPNX_INSTALL_DIR/lib" ] && run chmod 644 "$VPNX_INSTALL_DIR/lib/"*.sh 2>/dev/null || true
    fi
    if [ ! -L "$VPNX_BIN_LINK" ] && [ ! -f "$VPNX_BIN_LINK" ]; then
        run ln -sf "$VPNX_INSTALL_DIR/vpnx.sh" "$VPNX_BIN_LINK"
    fi
    log_ok "命令已就绪: vpnx (-> $VPNX_BIN_LINK)"
    return 0
}

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
cmd_install() {
    require_root
    os_detect
    os_support_check

    local opt_port opt_sni opt_target opt_profiles opt_url opt_node opt_token
    local no_fw=0 no_bbr=0 with_user=""
    opt_port="$(opt_val --port "$@")"
    opt_sni="$(opt_val --sni "$@")"
    opt_target="$(opt_val --target "$@")"
    opt_profiles="$(opt_val --profiles "$@")"
    opt_url="$(opt_val --central-url "$@")"
    opt_node="$(opt_val --node-id "$@")"
    opt_token="$(opt_val --token "$@")"
    with_user="$(opt_val --with-user "$@")"
    has_flag --no-firewall "$@" && no_fw=1
    has_flag --no-bbr "$@" && no_bbr=1

    printf '\n===== vpnx 部署开始 =====\n'
    os_print_info
    printf '\n'

    # 0) 已部署? 走更新流程
    if is_installed; then
        log_warn "检测到已部署(vpnx $(cfg_get VPNX_CONF_VERSION 0))"
        if ! confirm "继续执行部署流程(会重新渲染配置并重启内核)?" y; then
            die "已取消"
        fi
    fi

    tmp_init
    lock_acquire 60

    # 1) 基础依赖
    pkg_ensure_base
    [ "$HAS_OPENSSL" = "1" ] || die "缺少 openssl, 无法生成密钥"

    # 2) 目录与配置
    ensure_dirs
    cfg_init

    # 3) 安装内核
    xray_install "$(opt_val --version "$@")"

    # 4) REALITY 密钥
    if [ -z "$(cfg_get REALITY_PRIVATE_KEY '')" ] || [ -z "$(cfg_get REALITY_PUBLIC_KEY '')" ]; then
        log_info "生成 REALITY 密钥对..."
        reality_gen_keys || die "REALITY 密钥生成失败"
        cfg_set REALITY_PRIVATE_KEY "$REALITY_PRIVATE_KEY"
        cfg_set REALITY_PUBLIC_KEY "$REALITY_PUBLIC_KEY"
        cfg_set REALITY_SHORT_IDS "$(xray_gen_short_id)"
    else
        log_info "复用已有 REALITY 密钥"
    fi

    # 5) 伪装目标(建议与 VPS 同区域的大站)
    local sni target
    sni="$(cfg_get REALITY_SNI 'www.bing.com')"
    target="$(cfg_get REALITY_TARGET 'www.bing.com:443')"
    if [ -n "$opt_sni" ]; then
        sni="$opt_sni"
        case "$sni" in
            *:*) target="$sni" ;;
            *)   target="$sni:443" ;;
        esac
        sni="${sni%%:*}"
        cfg_set REALITY_SNI "$sni"
        cfg_set REALITY_TARGET "$target"
        log_info "REALITY 伪装目标: $target (SNI: $sni)"
    fi
    if [ -n "$opt_target" ]; then
        cfg_set REALITY_TARGET "$opt_target"
        log_info "REALITY target: $opt_target"
    fi

    # 6) 端口
    local port
    port="$opt_port"
    if [ -z "$port" ]; then
        port="$(cfg_get REALITY_PORT '')"
    fi
    if [ -z "$port" ]; then
        log_info "自动挑选空闲端口..."
        port="$(pick_free_port)" || die "找不到可用端口, 请用 --port 指定"
    fi
    validate_port "$port" || die "端口不合法: $port"
    fw_detect

    # 重新安装时, 这个端口往往正被"本节点自己的 xray"占用 —— 那是我们自己的端口,
    # 必须保持不变; 否则每次重装都会换端口, 导致订阅、防火墙、客户端全部对不上。
    local old_port port_is_ours=0
    old_port="$(cfg_get REALITY_PORT '')"
    if [ -n "$old_port" ] && [ "$port" = "$old_port" ]; then
        port_is_ours=1
    fi

    if [ "$port_is_ours" = "1" ]; then
        log_info "端口 $port 是本节点当前配置的端口(xray 正在使用), 保持不变"
    elif ! port_free "$port"; then
        log_warn "端口 $port 当前被占用: $(port_owner "$port")"
        if [ -z "$opt_port" ]; then
            log_info "自动改用其它端口"
            local alt
            alt="$(pick_free_port)" && port="$alt"
            log_info "改用端口 $port"
        fi
    fi
    if [ "$port_is_ours" = "1" ]; then
        : # 自己正在用的端口不需要安全确认
    else
        port_assert_safe "$port"
    fi
    # 端口发生变化时, 把旧端口的放行摘掉(前提是它不再被其它协议使用)
    if [ -n "$old_port" ] && [ "$old_port" != "$port" ]; then
        local old_used=0
        [ "$(cfg_get SS_PORT '')" = "$old_port" ] && old_used=1
        [ "$(cfg_get VMESS_PORT '')" = "$old_port" ] && old_used=1
        if [ "$old_used" = "0" ]; then
            log_info "端口已从 $old_port 换到 $port, 关闭旧端口放行"
            fw_close "$old_port" tcp
        fi
    fi
    cfg_set REALITY_PORT "$port"
    cfg_set REALITY_ENABLED 1
    log_ok "REALITY 端口: $port"

    # 7) 可选协议
    local prof
    if [ -n "$opt_profiles" ]; then
        for prof in $(printf '%s' "$opt_profiles" | tr ',' ' '); do
            case "$prof" in
                reality|vless-reality|reality-vision) ;;
                ss|ss2022)
                    if [ "$(cfg_get SS_ENABLED 0)" != "1" ]; then
                        local sport
                        sport="$(pick_free_port 8388 8389 18388 28388)" || sport=""
                        [ -z "$sport" ] && { log_warn "找不到 SS 端口, 跳过"; continue; }
                        cfg_set SS_PORT "$sport"
                        cfg_set SS_ENABLED 1
                        cfg_set SS_SERVER_PSK "$(ss_gen_psk "$(ss_psk_len_for_method "$(cfg_get SS_METHOD '')")")"
                        log_ok "SS2022 已启用, 端口 $sport"
                    fi
                    ;;
                vmess|vmess-ws)
                    if [ "$(cfg_get VMESS_ENABLED 0)" != "1" ]; then
                        local vport
                        vport="$(pick_free_port 8081 8082 18081)" || vport=""
                        [ -z "$vport" ] && { log_warn "找不到 VMess 端口, 跳过"; continue; }
                        cfg_set VMESS_PORT "$vport"
                        cfg_set VMESS_ENABLED 1
                        log_ok "VMess-WS 已启用, 端口 $vport"
                    fi
                    ;;
                xhttp|vless-xhttp)
                    if [ "$(cfg_get XHTTP_ENABLED 0)" != "1" ]; then
                        local xport
                        if [ -z "$(cfg_get REALITY_PRIVATE_KEY '')" ]; then
                            log_warn "XHTTP 依赖 REALITY 密钥, 但私钥缺失, 跳过"
                            continue
                        fi
                        xport="$(pick_free_port 8444 8445 8446 18444)" || xport=""
                        [ -z "$xport" ] && { log_warn "找不到 XHTTP 端口, 跳过"; continue; }
                        cfg_set XHTTP_PORT "$xport"
                        cfg_set XHTTP_PATH "$(cfg_get XHTTP_PATH '/vpnx-xhttp')"
                        cfg_set XHTTP_MODE "$(cfg_get XHTTP_MODE 'auto')"
                        cfg_set XHTTP_ENABLED 1
                        log_ok "VLESS+XHTTP+REALITY 已启用, 端口 $xport (复用 REALITY 密钥)"
                    fi
                    ;;
                *) log_warn "未知协议: $prof" ;;
            esac
        done
    fi

    # 8) 公网 IP
    if [ -z "$(cfg_get PUBLIC_IP '')" ]; then
        local pip
        pip="$(detect_public_ip)"
        [ -n "$pip" ] && { cfg_set PUBLIC_IP "$pip"; log_info "公网 IP: $pip"; }
    fi

    # 9) 服务单元 + 配置落地
    xray_service_install
    apply_config --restart || die "配置落地或内核启动失败, 请查看 $VPNX_LOG_DIR/error.log"

    # 10) 防火墙(增量放行, 不碰面板)
    if [ "$no_fw" = "1" ]; then
        log_info "按参数要求跳过防火墙配置"
    else
        fw_detect
        log_info "配置防火墙(模式: $FW_MODE)"
        local p2
        for p2 in reality ss vmess xhttp; do
            user_proto_active "$p2" || continue
            case "$p2" in
                reality) fw_open "$(cfg_get REALITY_PORT '')" tcp ;;
                ss)      fw_open "$(cfg_get SS_PORT '')" "$(cfg_get SS_NETWORK 'tcp,udp' | tr ',' ' ')" ;;
                vmess)   fw_open "$(cfg_get VMESS_PORT '')" tcp ;;
                xhttp)   fw_open "$(cfg_get XHTTP_PORT '')" tcp ;;
            esac
        done
    fi

    # 11) BBR
    if [ "$no_bbr" = "1" ]; then
        log_info "按参数要求跳过 BBR 调优"
    elif is_true "$(cfg_get ENABLE_BBR 1)"; then
        bbr_on || true
    fi

    # 12) 中台
    if [ -n "$opt_url" ]; then
        agent_set "--url=$opt_url" ${opt_node:+--node-id=$opt_node} ${opt_token:+--token=$opt_token}
        agent_install
    fi

    # 13) 自安装 + 首个账号
    self_install

    if [ -n "$with_user" ]; then
        user_add "$with_user" --protocols "$(cfg_get DEFAULT_PROTOCOLS reality)"
    fi

    tmp_cleanup
    lock_release
    _install_summary
    return 0
}

_install_summary() {
    printf '\n===== 部署完成 =====\n'
    printf '程序目录    : %s\n' "$VPNX_INSTALL_DIR"
    printf '配置文件    : %s\n' "$VPNX_CONF"
    printf '账号库      : %s\n' "$VPNX_USERS_DB"
    printf '内核版本    : %s\n' "$(xray_installed_version 2>/dev/null)"
    printf '服务状态    : %s\n' "$(xray_is_running && echo 运行中 || echo 未运行)"
    printf '初始化系统  : %s\n' "$INIT_SYS"
    printf '\n--- 节点参数 ---\n'
    config_show
    printf '\n--- 下一步 ---\n'
    printf '  1) 创建账号     : vpnx user add alice --expire 90d --quota 100G\n'
    printf '  2) 查看链接     : vpnx user link alice\n'
    printf '  3) 查看订阅串   : vpnx user sub alice\n'
    printf '  4) 健康检查     : vpnx health check\n'
    printf '  5) 接入中台     : vpnx agent set --url https://<中台> --node-id <节点ID> --token <令牌>\n'
    printf '                    vpnx agent install && vpnx agent test\n'
    if [ "$FW_MODE" = "none" ]; then
        printf '\n注意: 本机未启用防火墙。如果云厂商有安全组, 记得放行上述端口。\n'
    fi
    printf '\n提示: 请确认在符合当地法律与服务商条款的前提下使用本工具。\n'
    return 0
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
cmd_uninstall() {
    require_root
    local purge=0
    has_flag --purge "$@" && purge=1
    if ! confirm "确定要卸载 vpnx 吗?" n; then
        die "已取消"
    fi
    lock_acquire 30

    # 停服务
    agent_uninstall >/dev/null 2>&1 || true
    sub_serve_remove >/dev/null 2>&1 || true
    xray_service_remove
    fw_persist_remove

    # 移除防火墙登记端口
    if [ -f "$FW_PORTS_FILE" ]; then
        fw_detect
        local line p pr
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            p="${line%%/*}"; pr="${line##*/}"
            fw_close_one "$p" "$pr"
        done < "$FW_PORTS_FILE"
        run rm -f "$FW_PORTS_FILE"
    fi

    run rm -f "$VPNX_BIN_LINK"
    if [ "$purge" = "1" ]; then
        log_warn "彻底清除配置、账号库与日志"
        run rm -rf "$VPNX_ETC" "$VPNX_LOG_DIR"
    else
        log_info "已保留 $VPNX_ETC (账号库与配置) 与 $VPNX_LOG_DIR"
        log_info "如需彻底清除: vpnx uninstall --purge"
    fi
    if [ "$VPNX_HOME" = "$VPNX_INSTALL_DIR" ]; then
        run rm -rf "$VPNX_INSTALL_DIR"
    fi
    if confirm "是否同时删除 Xray 内核($XRAY_BIN)?" n; then
        run rm -f "$XRAY_BIN"
    fi
    log_ok "卸载完成"
    return 0
}

# ---------------------------------------------------------------------------
# 升级内核
# ---------------------------------------------------------------------------
cmd_upgrade() {
    require_root
    require_installed
    local ver
    ver="$(opt_val --version "$@")"
    local old
    old="$(xray_installed_version)"
    log_info "当前内核版本: $old"
    lock_acquire 60
    xray_install "$ver" || die "内核安装失败"
    xray_test_mode_detect
    # 版本变化后渲染参数可能不同(如 tcp/raw 命名), 重新渲染并重启
    apply_config --restart || die "升级后配置落地失败, 已保留原配置"
    log_ok "内核升级完成: $old -> $(xray_installed_version)"
    return 0
}

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------
cmd_status() {
    os_detect
    printf '===== vpnx 状态 =====\n'
    printf '版本        : %s (build %s)\n' "$VPNX_VERSION" "${VPNX_BUILD:-?}"
    if ! is_installed; then
        log_warn "尚未部署, 请执行: vpnx install"
        return 1
    fi
    # --- 运行状态(最关键的信息放最前面) ---
    local uptime actual
    uptime="$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)"
    actual="$(xray_listen_ports)"
    printf '服务状态    : %s\n' "$(xray_is_running && echo 运行中 || echo 未运行)"
    printf '内核版本    : %s\n' "$(xray_installed_version 2>/dev/null)"
    printf '实际监听    : %s\n' "${actual:-无(没有任何端口在监听)}"
    printf '系统运行    : %s 秒\n' "$uptime"
    printf '\n'
    config_show
    if ! health_ports_match; then
        printf '\n%s[警告]%s 配置端口与内核实际监听不一致(%s)! 执行 vpnx health fix 自动对齐\n' \
            "$C_YEL" "$C_RST" "${actual:-无}"
    fi
    printf '\n'
    printf '账号总数    : %s\n' "$(user_count)"
    printf '总流量      : 上 %s / 下 %s\n' \
        "$(bytes_to_size "$(awk -F'|' 'NF>=10 && $1!~/^#/ { s+=$6 } END { printf "%d", s+0 }' "$VPNX_USERS_DB")")" \
        "$(bytes_to_size "$(awk -F'|' 'NF>=10 && $1!~/^#/ { s+=$7 } END { printf "%d", s+0 }' "$VPNX_USERS_DB")")"
    printf '\n'
    fw_status
    printf '\n'
    printf 'BBR         : %s\n' "$(bbr_current)"
    printf '\n'
    if agent_enabled; then
        printf '中台同步    : 启用 (revision %s, 上次 %s)\n' \
            "$(cfg_get POLICY_REVISION 0)" "$(epoch_to_str "$(kv_get "$AGENT_STATE" LAST_SYNC 0)")"
    else
        printf '中台同步    : 未启用\n'
    fi
    printf '订阅服务    : %s\n' "$([ "$(cfg_get SUB_SERVE 0)" = "1" ] && echo "启用(端口 $(cfg_get SUB_PORT '-'))" || echo 未启用)"
    printf '日志目录    : %s\n' "$VPNX_LOG_DIR"
    printf '\n--- 系统信息 ---\n'
    os_print_info
    return 0
}

# ---------------------------------------------------------------------------
# 自检(doctor)
# ---------------------------------------------------------------------------
cmd_doctor() {
    require_root
    os_detect
    printf '===== vpnx 自检 =====\n\n'
    printf '--- 系统 ---\n'
    os_print_info
    printf '\n--- 面板共存(建站面板) ---\n'
    panel_check_report
    printf '\n--- 端口占用 ---\n'
    local p
    for p in 80 443 8888 3306 6379; do
        if port_in_use "$p"; then
            printf '  %-6s 占用: %s\n' "$p" "$(port_owner "$p")"
        fi
    done
    if is_installed; then
        for p in reality ss vmess xhttp; do
            user_proto_active "$p" || continue
            local port owner
            case "$p" in
                reality) port="$(cfg_get REALITY_PORT '')" ;;
                ss)      port="$(cfg_get SS_PORT '')" ;;
                vmess)   port="$(cfg_get VMESS_PORT '')" ;;
                xhttp)   port="$(cfg_get XHTTP_PORT '')" ;;
            esac
            [ -z "$port" ] && continue
            owner="$(port_owner "$port")"
            printf '  %-6s (%s) %s\n' "$port" "$p" "${owner:-空闲}"
        done
    fi
    printf '\n--- 依赖工具 ---\n'
    local t
    for t in curl wget openssl unzip tar iptables ss jq python python3; do
        if have_cmd "$t"; then printf '  %-10s 有\n' "$t"; else printf '  %-10s 无\n' "$t"; fi
    done
    printf '\n--- 时间同步 ---\n'
    printf '  当前时间: %s\n' "$(now_str)"
    printf '  时区    : %s\n' "$(date '+%Z %z')"
    printf '  同步服务: %s\n' "$(svc_is_active chronyd && echo chronyd || (svc_is_active ntpd && echo ntpd || (svc_is_active systemd-timesyncd && echo systemd-timesyncd || echo 未运行)))"
    printf '\n--- JSON 解析能力(影响中台策略解析) ---\n'
    printf '  后端    : %s\n' "$(json_backend)"

    if is_installed; then
        printf '\n--- VPN 健康 ---\n'
        health_check
        local rc=$?
        printf '\n--- 近期错误日志 ---\n'
        tail -n 10 "$VPNX_LOG_DIR/error.log" 2>/dev/null || printf '  (无)\n'
        return $rc
    fi
    return 0
}