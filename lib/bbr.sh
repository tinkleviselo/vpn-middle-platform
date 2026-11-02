#!/usr/bin/env bash
# ==============================================================================
#  lib/bbr.sh - 内核 BBR 与网络缓冲区调优(可选, 失败不影响 VPN 本身)
#  限制: 需要内核 >= 4.9; OpenVZ/LXC 等容器通常不允许改拥塞算法, 自动跳过
# ==============================================================================

VPNX_SYSCTL_FILE="/etc/sysctl.d/99-vpnx.conf"

bbr_current() {
    local cc
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    printf '%s' "${cc:-unknown}"
}

bbr_available() {
    if kernel_ge 4 9; then
        return 0
    fi
    return 1
}

bbr_status() {
    local qdisc support
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    if [ -z "$qdisc" ]; then
        qdisc="unknown"
    fi
    support="否"
    if bbr_available; then
        support="是"
    fi
    printf '内核版本      : %s\n' "$KERNEL_VER"
    printf '虚拟化        : %s\n' "$VIRT"
    printf '拥塞控制算法  : %s\n' "$(bbr_current)"
    printf '队列算法      : %s\n' "$qdisc"
    printf '内核支持 BBR  : %s\n' "$support"
    if [ -f "$VPNX_SYSCTL_FILE" ]; then
        printf 'vpnx 调优文件 : 已存在 (%s)\n' "$VPNX_SYSCTL_FILE"
    else
        printf 'vpnx 调优文件 : 不存在\n'
    fi
    return 0
}

bbr_on() {
    if ! bbr_available; then
        log_warn "内核 $KERNEL_VER 低于 4.9, 不支持 BBR, 已跳过"
        return 1
    fi
    case "$VIRT" in
        openvz|lxc|docker)
            log_warn "当前虚拟化类型($VIRT)通常不允许修改内核网络参数, 已跳过 BBR"
            return 1
            ;;
    esac

    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '%s[dry-run]%s 写入 %s 并加载 tcp_bbr\n' "$C_DIM" "$C_RST" "$VPNX_SYSCTL_FILE"
        return 0
    fi

    modprobe tcp_bbr 2>/dev/null || true
    # 模块未内置时尝试加载
    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        log_warn "内核未提供 bbr 模块(tcp_available_congestion_control 无 bbr), 仅做缓冲区调优"
    fi

    cat > "$VPNX_SYSCTL_FILE" <<'EOF'
# vpnx 网络调优(可安全删除以恢复默认)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10000 65000
fs.file-max = 1048576
EOF
    chmod 644 "$VPNX_SYSCTL_FILE"

    # 应用(优先 sysctl --system, 老系统退化为 -p)
    sysctl --system >/dev/null 2>&1 || sysctl -p "$VPNX_SYSCTL_FILE" >/dev/null 2>&1 || true

    # 提高 ulimit(写 limits.conf, 只加一段带标记的内容)
    if ! grep -q 'vpnx' /etc/security/limits.conf 2>/dev/null; then
        {
            printf '# vpnx\n'
            printf '* soft nofile 1048576\n'
            printf '* hard nofile 1048576\n'
        } >> /etc/security/limits.conf 2>/dev/null || true
    fi

    if [ "$(bbr_current)" = "bbr" ]; then
        log_ok "BBR 已启用"
        return 0
    fi
    log_warn "BBR 未生效(可能内核模块不可用或被容器限制), 已保留缓冲区调优"
    return 1
}

bbr_off() {
    if [ -f "$VPNX_SYSCTL_FILE" ]; then
        run rm -f "$VPNX_SYSCTL_FILE"
    fi
    if [ "${DRY_RUN:-0}" != "1" ]; then
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    fi
    log_info "已关闭 vpnx 的网络调优(BBR 设置已移除)"
    return 0
}

cmd_bbr() {
    local sub="${1:-status}"
    require_root
    case "$sub" in
        on|enable)  bbr_on ;;
        off|disable) bbr_off ;;
        status)     bbr_status ;;
        *)
            printf '用法: vpnx bbr on|off|status\n'
            return 2
            ;;
    esac
}
