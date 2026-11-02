#!/usr/bin/env bash
# ==============================================================================
#  lib/firewall.sh - 防火墙抽象层(只做增量, 绝不 flush, 不影响 建站面板/CSF)
#  支持: firewalld / ufw / iptables(自建 VPNX 链) / CSF / 无防火墙
# ==============================================================================

FW_MODE="unknown"
FW_PORTS_FILE="$VPNX_STATE_DIR/fw.ports"
IPT_W_SUPPORT=0

# ---------------------------------------------------------------------------
# 探测当前生效的防火墙
# ---------------------------------------------------------------------------
fw_detect() {
    FW_MODE="none"
    local st=""

    if [ "$HAS_FIREWALLD" = "1" ]; then
        st="$(firewall-cmd --state 2>/dev/null)"
        if [ "$st" = "running" ]; then
            FW_MODE="firewalld"
        fi
    fi

    if [ "$FW_MODE" = "none" ] && [ "$HAS_UFW" = "1" ]; then
        if ufw status 2>/dev/null | grep -qi '^Status:[[:space:]]*active'; then
            FW_MODE="ufw"
        fi
    fi

    # CSF 与 iptables 并存: CSF 会周期性重建 iptables, 必须走 csf.conf
    if [ "$HAS_CSF" = "1" ] && have_cmd csf; then
        FW_MODE="csf"
    fi

    if [ "$FW_MODE" = "none" ] && [ "$HAS_IPTABLES" = "1" ]; then
        if iptables -w -L -n >/dev/null 2>&1; then
            IPT_W_SUPPORT=1
        elif iptables -L -n >/dev/null 2>&1; then
            IPT_W_SUPPORT=0
        else
            log_debug "iptables 不可用(可能无 NET_ADMIN 权限)"
        fi
        FW_MODE="iptables"
    fi

    if [ "$FW_MODE" = "none" ] && [ "$HAS_NFT" = "1" ]; then
        FW_MODE="nft"
    fi
    [ "$FW_MODE" = "unknown" ] && FW_MODE="none"
    return 0
}

_fw_ipt() {
    if [ "$IPT_W_SUPPORT" = "1" ]; then
        iptables -w "$@"
    else
        iptables "$@"
    fi
}

# ---------------------------------------------------------------------------
# 端口清单(state/fw.ports) — 顺序无关, 一行一个 "端口/协议"
# ---------------------------------------------------------------------------
fw_ports_list() { [ -f "$FW_PORTS_FILE" ] && cat "$FW_PORTS_FILE" 2>/dev/null; return 0; }

fw_port_registered() {
    [ -f "$FW_PORTS_FILE" ] || return 1
    grep -qx "$1/$2" "$FW_PORTS_FILE" 2>/dev/null
}

fw_port_register() {
    local p="$1" pr="${2:-tcp}"
    ensure_dir "$VPNX_STATE_DIR"
    fw_port_registered "$p" "$pr" && return 0
    printf '%s/%s\n' "$p" "$pr" >> "$FW_PORTS_FILE"
}

fw_port_unregister() {
    local p="$1" pr="${2:-tcp}" tmp
    [ -f "$FW_PORTS_FILE" ] || return 0
    tmp="$FW_PORTS_FILE.tmp.$$"
    grep -vx "$p/$pr" "$FW_PORTS_FILE" > "$tmp" 2>/dev/null || : > "$tmp"
    cat "$tmp" > "$FW_PORTS_FILE"
    rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# 放行 / 关闭
# ---------------------------------------------------------------------------
fw_open() {
    local port="$1" proto="${2:-tcp}"
    [ -z "$port" ] && return 0
    local p pr
    # 端口与协议都支持逗号/空格分隔: 端口 "8443,8444", 协议 "tcp,udp"
    for p in $(printf '%s' "$port" | tr ',' ' '); do
        for pr in $(printf '%s' "$proto" | tr ',' ' '); do
            [ -z "$pr" ] && pr="tcp"
            case "$pr" in tcp|udp) ;; *) pr="tcp" ;; esac
            fw_port_register "$p" "$pr"
            fw_open_one "$p" "$pr"
        done
    done
}

fw_open_one() {
    local port="$1" proto="${2:-tcp}" pflag
    case "$proto" in
        udp) pflag="udp" ;;
        *)   pflag="tcp" ;;
    esac

    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '%s[dry-run]%s 防火墙放行 %s/%s (模式: %s)\n' "$C_DIM" "$C_RST" "$port" "$pflag" "$FW_MODE"
        return 0
    fi

    case "$FW_MODE" in
        firewalld)
            if firewall-cmd --query-port="$port/$pflag" >/dev/null 2>&1; then
                log_debug "firewalld 已放行 $port/$pflag"
            else
                firewall-cmd --permanent --add-port="$port/$pflag" >/dev/null 2>&1
                firewall-cmd --reload >/dev/null 2>&1
                log_ok "firewalld 放行 $port/$pflag"
            fi
            ;;
        ufw)
            if ufw status 2>/dev/null | grep -qE "^$port/$pflag[[:space:]]+ALLOW"; then
                log_debug "ufw 已放行 $port/$pflag"
            else
                ufw allow "$port/$pflag" >/dev/null 2>&1 && log_ok "ufw 放行 $port/$pflag"
            fi
            ;;
        csf)
            _fw_csf_add "$port" "$pflag"
            ;;
        iptables)
            _fw_chain_ensure
            if _fw_ipt -C VPNX -p "$pflag" --dport "$port" -j ACCEPT >/dev/null 2>&1; then
                log_debug "iptables 已放行 $port/$pflag"
            else
                _fw_ipt -A VPNX -p "$pflag" --dport "$port" -j ACCEPT >/dev/null 2>&1 \
                    && log_ok "iptables(VPNX 链) 放行 $port/$pflag" \
                    || log_warn "iptables 放行 $port/$pflag 失败"
            fi
            fw_persist_install
            ;;
        nft)
            log_warn "系统只有 nft, 未自动改动规则; 请手动执行以下命令后按回车确认:"
            printf '  nft add table inet vpnx\n'
            printf '  nft add chain inet vpnx input { type filter hook input priority 0 \\; policy accept \\; }\n'
            printf '  nft add rule inet vpnx input tcp dport %s accept\n' "$port"
            ;;
        *)
            log_warn "系统未启用本地防火墙; 已登记端口 $port/$pflag, 如需放行请在云厂商安全组自行添加"
            ;;
    esac
    return 0
}

fw_close() {
    local port="$1" proto="${2:-tcp}" p pr
    for p in $(printf '%s' "$port" | tr ',' ' '); do
        for pr in $(printf '%s' "$proto" | tr ',' ' '); do
            [ -z "$pr" ] && pr="tcp"
            case "$pr" in tcp|udp) ;; *) pr="tcp" ;; esac
            fw_close_one "$p" "$pr"
            fw_port_unregister "$p" "$pr"
        done
    done
}

fw_close_one() {
    local port="$1" proto="${2:-tcp}"
    case "$FW_MODE" in
        firewalld) run firewall-cmd --permanent --remove-port="$port/$proto" >/dev/null 2>&1 || true
                   run firewall-cmd --reload >/dev/null 2>&1 || true ;;
        ufw)       run ufw delete allow "$port/$proto" >/dev/null 2>&1 || true ;;
        csf)       _fw_csf_del "$port" "$proto" ;;
        iptables)  while _fw_ipt -C VPNX -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1; do
                       _fw_ipt -D VPNX -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 || break
                   done ;;
        *) : ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# iptables 自建链(永远不碰 INPUT 上已有的规则, 只插一条跳到 VPNX)
# ---------------------------------------------------------------------------
_fw_chain_ensure() {
    local ipt=""
    _fw_ipt -n VPNX >/dev/null 2>&1 || _fw_ipt -N VPNX >/dev/null 2>&1
    if ! _fw_ipt -C INPUT -j VPNX >/dev/null 2>&1; then
        _fw_ipt -I INPUT 1 -j VPNX >/dev/null 2>&1 || log_warn "无法在 INPUT 挂载 VPNX 链"
    fi
    # 记录来源注释, 方便面板/人工识别
    _fw_ipt -C VPNX -m comment --comment "vpnx-managed" >/dev/null 2>&1 || true
    return 0
}

fw_reapply() {
    fw_detect
    log_info "重新应用防火墙规则(模式: $FW_MODE)"
    local line p pr
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        p="${line%%/*}"; pr="${line##*/}"
        case "$pr" in tcp|udp) ;; *) pr=tcp ;; esac
        fw_open_one "$p" "$pr"
    done <<EOF
$(fw_ports_list)
EOF
    return 0
}

# 开机自动恢复(iptables 模式下 iptables 规则不持久)
fw_persist_install() {
    [ "$FW_MODE" = "iptables" ] || return 0
    if [ "$HAS_SYSTEMD" = "1" ]; then
        [ -f /etc/systemd/system/vpnx-fw.service ] && return 0
        if [ "${DRY_RUN:-0}" != "1" ]; then
            cat > /etc/systemd/system/vpnx-fw.service <<EOF
[Unit]
Description=vpnx 防火墙规则恢复(iptables)
After=network.target firewalld.service
Before=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpnx fw restore
RemainAfterExit=yes
EOF
        fi
        svc_daemon_reload
        run systemctl enable vpnx-fw.service >/dev/null 2>&1 || true
        log_debug "已安装 vpnx-fw.service 用于开机恢复 iptables 规则"
    else
        if [ ! -f /etc/cron.d/vpnx-fw ]; then
            if [ "${DRY_RUN:-0}" != "1" ]; then
                printf '# vpnx 开机恢复 iptables 规则(自动生成)\n@reboot root /usr/local/bin/vpnx fw restore\n' \
                    > /etc/cron.d/vpnx-fw
                chmod 644 /etc/cron.d/vpnx-fw 2>/dev/null || true
            fi
        fi
    fi
    return 0
}

fw_persist_remove() {
    run rm -f /etc/systemd/system/vpnx-fw.service
    [ "$HAS_SYSTEMD" = "1" ] && run systemctl disable vpnx-fw.service >/dev/null 2>&1
    run rm -f /etc/cron.d/vpnx-fw
    svc_daemon_reload
    return 0
}

# ---------------------------------------------------------------------------
# CSF(常见于 cPanel 面板): 只能改 csf.conf 再 csf -r
# ---------------------------------------------------------------------------
_fw_csf_key() {
    case "$1" in udp) printf 'UDP_IN' ;; *) printf 'TCP_IN' ;; esac
}

_fw_csf_add() {
    local port="$1" proto="$2" key cur new
    key="$(_fw_csf_key "$proto")"
    cur="$(sed -n "s/^${key}[[:space:]]*=[[:space:]]*\"\(.*\)\".*/\1/p" /etc/csf/csf.conf 2>/dev/null | head -n1)"
    case ",$cur," in
        *",$port,"*) log_debug "CSF $key 已包含 $port"; return 0 ;;
    esac
    new="${cur:+$cur,}$port"
    ensure_dir "$VPNX_BACKUP_DIR"
    cp -f /etc/csf/csf.conf "$VPNX_BACKUP_DIR/csf.conf.$(date '+%Y%m%d%H%M%S').bak" 2>/dev/null || true
    sed -i "s|^${key}[[:space:]]*=.*|${key} = \"${new}\"|" /etc/csf/csf.conf 2>/dev/null
    run csf -r >/dev/null 2>&1 || run csf -ra >/dev/null 2>&1 || true
    log_ok "CSF $key 增加 $port 并已重载"
}

_fw_csf_del() {
    local port="$1" proto="$2" key cur new
    key="$(_fw_csf_key "$proto")"
    cur="$(sed -n "s/^${key}[[:space:]]*=[[:space:]]*\"\(.*\)\".*/\1/p" /etc/csf/csf.conf 2>/dev/null | head -n1)"
    [ -z "$cur" ] && return 0
    new="$(printf '%s' "$cur" | tr ',' '\n' | grep -vx "$port" | paste -sd, - 2>/dev/null)"
    [ -z "$new" ] && new="$cur"
    sed -i "s|^${key}[[:space:]]*=.*|${key} = \"${new}\"|" /etc/csf/csf.conf 2>/dev/null
    run csf -r >/dev/null 2>&1 || true
    log_info "CSF $key 移除 $port"
}

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------
fw_status() {
    fw_detect
    printf '防火墙模式  : %s\n' "$FW_MODE"
    [ "$FW_MODE" = "iptables" ] && printf 'iptables -w : %s\n' "$([ "$IPT_W_SUPPORT" = "1" ] && echo 支持 || echo 不支持)"
    printf '已登记端口  :\n'
    if [ -f "$FW_PORTS_FILE" ] && [ -s "$FW_PORTS_FILE" ]; then
        sed 's/^/  - /' "$FW_PORTS_FILE"
    else
        printf '  (无)\n'
    fi
    case "$FW_MODE" in
        firewalld) printf '实际放行    : %s\n' "$(firewall-cmd --list-ports 2>/dev/null)" ;;
        ufw)       printf '实际放行    :\n'; ufw status 2>/dev/null | sed 's/^/  /' ;;
        iptables)  printf '实际放行(VPNX 链):\n'; _fw_ipt -S VPNX 2>/dev/null | sed 's/^/  /' || printf '  (链不存在)\n' ;;
        csf)       printf 'CSF TCP_IN  : %s\n' "$(sed -n 's/^TCP_IN[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' /etc/csf/csf.conf 2>/dev/null | head -n1)"
                   printf 'CSF UDP_IN  : %s\n' "$(sed -n 's/^UDP_IN[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' /etc/csf/csf.conf 2>/dev/null | head -n1)" ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# CLI: vpnx fw open|close|status|restore
# ---------------------------------------------------------------------------
cmd_fw() {
    local sub="${1:-status}"
    if [ $# -gt 0 ]; then shift; fi
    require_root
    fw_detect
    case "$sub" in
        open)
            [ -n "${1:-}" ] || die "用法: vpnx fw open <端口> [tcp|udp]"
            fw_open "$1" "${2:-tcp}"
            ;;
        close)
            [ -n "${1:-}" ] || die "用法: vpnx fw close <端口> [tcp|udp]"
            fw_close "$1" "${2:-tcp}"
            ;;
        status|list) fw_status ;;
        restore)     fw_reapply ;;
        *)
            printf '用法: vpnx fw open|close|status [端口] [tcp|udp]\n'
            printf '      vpnx fw restore   重新应用已登记的端口规则\n'
            return 2
            ;;
    esac
}
