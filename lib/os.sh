#!/usr/bin/env bash
# ==============================================================================
#  lib/os.sh - 发行版/包管理/服务管理/计划任务 抽象层
#  目标: 同一套代码在 CentOS7(systemd 219) ~ Ubuntu24.04(systemd 255) 都能跑,
#        无 systemd 的老系统自动降级到 SysV + cron.d
# ==============================================================================

# --- 探测结果全局变量(必须先初始化, 因为脚本使用 set -u) --------------------
OS_ID=""; OS_LIKE=""; OS_VERSION_ID=""; OS_PRETTY=""; OS_FAMILY=""
OS_MAJOR=""
PKG_MGR=""; ARCH=""; XRAY_ARCH=""; XRAY_ARCH_NAME=""
INIT_SYS=""; SYSTEMD_VER=""; HAS_SYSTEMD=0
KERNEL_VER=""; KERNEL_MAJOR=0; KERNEL_MINOR=0
VIRT="unknown"
HAS_SS=0; HAS_NETSTAT=0; HAS_LSOF=0; HAS_IPTABLES=0; HAS_IP6TABLES=0
HAS_NFT=0; HAS_UFW=0; HAS_FIREWALLD=0; HAS_CSF=0
HAS_OPENSSL=0; HAS_CURL=0; HAS_WGET=0; HAS_UNZIP=0; HAS_TAR=0
HAS_JQ=0; HAS_PYTHON=0; HAS_PYTHON3=0; HAS_CRONTAB=0; HAS_FLOCK=0
APT_REFRESHED=0
OS_DETECTED=0

# ---------------------------------------------------------------------------
# 发行版探测
# ---------------------------------------------------------------------------
os_detect() {
    [ "$OS_DETECTED" = "1" ] && return 0

    OS_ID=""; OS_LIKE=""; OS_VERSION_ID=""; OS_PRETTY=""

    if [ -r /etc/os-release ]; then
        # os-release 是 key=value 格式, 用子 shell 读取避免污染自身变量
        OS_ID="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")"
        OS_LIKE="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-}")"
        OS_VERSION_ID="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-}")"
        OS_PRETTY="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-}")"
    fi

    if [ -z "$OS_ID" ]; then
        if [ -r /etc/redhat-release ]; then
            OS_PRETTY="$(cat /etc/redhat-release)"
            OS_ID="$(printf '%s' "$OS_PRETTY" | awk '{print tolower($1)}')"
            OS_VERSION_ID="$(printf '%s' "$OS_PRETTY" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1)"
        elif [ -r /etc/debian_version ]; then
            OS_ID="debian"; OS_VERSION_ID="$(cat /etc/debian_version)"
            OS_PRETTY="Debian $OS_VERSION_ID"
        elif [ -r /etc/alpine-release ]; then
            OS_ID="alpine"; OS_VERSION_ID="$(cat /etc/alpine-release)"
            OS_PRETTY="Alpine $OS_VERSION_ID"
        elif [ -r /etc/SuSE-release ]; then
            OS_ID="suse"; OS_PRETTY="SUSE"
        fi
    fi
    [ -z "$OS_ID" ] && OS_ID="unknown"
    [ -z "$OS_PRETTY" ] && OS_PRETTY="$OS_ID $OS_VERSION_ID"
    OS_MAJOR="$(printf '%s' "$OS_VERSION_ID" | cut -d. -f1)"

    # 家族归类
    case "$OS_ID" in
        centos|rhel|redhat|almalinux|rocky|ol|oracle|fedora|amzn|cloudlinux|virtuozzo|openEuler|anolis|kylin|uos)
            OS_FAMILY="rhel" ;;
        debian|ubuntu|linuxmint|raspbian|kali|deepin|pop|elementary|zorin)
            OS_FAMILY="debian" ;;
        opensuse*|sles|suse) OS_FAMILY="suse" ;;
        alpine) OS_FAMILY="alpine" ;;
        arch|manjaro|endeavouros) OS_FAMILY="arch" ;;
        *)
            case "$OS_LIKE" in
                *rhel*|*fedora*|*centos*) OS_FAMILY="rhel" ;;
                *debian*|*ubuntu*)        OS_FAMILY="debian" ;;
                *suse*)                   OS_FAMILY="suse" ;;
                *) OS_FAMILY="unknown" ;;
            esac
            ;;
    esac

    # 包管理器
    PKG_MGR=""
    if [ "$OS_FAMILY" = "rhel" ]; then
        if have_cmd dnf; then PKG_MGR="dnf"; elif have_cmd yum; then PKG_MGR="yum"; fi
    elif [ "$OS_FAMILY" = "debian" ]; then
        have_cmd apt-get && PKG_MGR="apt-get"
    elif [ "$OS_FAMILY" = "suse" ]; then
        have_cmd zypper && PKG_MGR="zypper"
    elif [ "$OS_FAMILY" = "alpine" ]; then
        have_cmd apk && PKG_MGR="apk"
    fi
    if [ -z "$PKG_MGR" ]; then
        if have_cmd apt-get; then PKG_MGR="apt-get"
        elif have_cmd dnf; then PKG_MGR="dnf"
        elif have_cmd yum; then PKG_MGR="yum"
        elif have_cmd zypper; then PKG_MGR="zypper"
        elif have_cmd apk; then PKG_MGR="apk"
        fi
    fi

    # 架构
    ARCH="$(uname -m 2>/dev/null || echo unknown)"
    os_map_xray_arch "$ARCH"

    # init 系统
    INIT_SYS="sysv"; HAS_SYSTEMD=0
    if [ -d /run/systemd/system ] && have_cmd systemctl; then
        INIT_SYS="systemd"; HAS_SYSTEMD=1
        SYSTEMD_VER="$(systemctl --version 2>/dev/null | head -n1 | awk '{print $2}')"
        [ -z "$SYSTEMD_VER" ] && SYSTEMD_VER="0"
    elif have_cmd rc-service; then
        INIT_SYS="openrc"
    fi

    # 内核
    KERNEL_VER="$(uname -r 2>/dev/null || echo 0.0.0)"
    KERNEL_MAJOR="$(printf '%s' "$KERNEL_VER" | sed 's/[^0-9.].*$//' | cut -d. -f1)"
    KERNEL_MINOR="$(printf '%s' "$KERNEL_VER" | sed 's/[^0-9.].*$//' | cut -d. -f2)"
    [ -z "$KERNEL_MAJOR" ] && KERNEL_MAJOR=0
    [ -z "$KERNEL_MINOR" ] && KERNEL_MINOR=0

    # 虚拟化(OpenVZ/LXC 对 BBR、iptables、内核参数有限制)
    os_detect_virt

    # 工具可用性
    have_cmd ss && HAS_SS=1
    have_cmd netstat && HAS_NETSTAT=1
    have_cmd lsof && HAS_LSOF=1
    have_cmd iptables && HAS_IPTABLES=1
    have_cmd ip6tables && HAS_IP6TABLES=1
    have_cmd nft && HAS_NFT=1
    have_cmd ufw && HAS_UFW=1
    have_cmd firewall-cmd && HAS_FIREWALLD=1
    [ -f /etc/csf/csf.conf ] && HAS_CSF=1
    have_cmd openssl && HAS_OPENSSL=1
    have_cmd curl && HAS_CURL=1
    have_cmd wget && HAS_WGET=1
    have_cmd unzip && HAS_UNZIP=1
    have_cmd tar && HAS_TAR=1
    have_cmd jq && HAS_JQ=1
    have_cmd python && HAS_PYTHON=1
    have_cmd python3 && HAS_PYTHON3=1
    have_cmd crontab && HAS_CRONTAB=1
    have_cmd flock && HAS_FLOCK=1

    OS_DETECTED=1
    return 0
}

# Xray Release 资产名映射
os_map_xray_arch() {
    local m="$1"
    XRAY_ARCH=""; XRAY_ARCH_NAME=""
    case "$m" in
        x86_64|amd64)        XRAY_ARCH="64";           XRAY_ARCH_NAME="x86_64" ;;
        i386|i486|i586|i686|x86) XRAY_ARCH="32";       XRAY_ARCH_NAME="i386" ;;
        aarch64|arm64)       XRAY_ARCH="arm64-v8a";    XRAY_ARCH_NAME="arm64" ;;
        armv7l|armv7|armhf)  XRAY_ARCH="arm32-v7a";    XRAY_ARCH_NAME="armv7" ;;
        armv6l)              XRAY_ARCH="arm32-v6";     XRAY_ARCH_NAME="armv6" ;;
        mips)                XRAY_ARCH="mips32";       XRAY_ARCH_NAME="mips" ;;
        mipsel)              XRAY_ARCH="mips32le";     XRAY_ARCH_NAME="mipsle" ;;
        mips64)              XRAY_ARCH="mips64";       XRAY_ARCH_NAME="mips64" ;;
        mips64el)            XRAY_ARCH="mips64le";     XRAY_ARCH_NAME="mips64le" ;;
        ppc64)               XRAY_ARCH="ppc64";        XRAY_ARCH_NAME="ppc64" ;;
        ppc64le)             XRAY_ARCH="ppc64le";      XRAY_ARCH_NAME="ppc64le" ;;
        riscv64)             XRAY_ARCH="riscv64";      XRAY_ARCH_NAME="riscv64" ;;
        s390x)               XRAY_ARCH="s390x";        XRAY_ARCH_NAME="s390x" ;;
    esac
    [ -z "$XRAY_ARCH" ] && { XRAY_ARCH="64"; XRAY_ARCH_NAME="$m"; }
}

os_detect_virt() {
    VIRT="none"
    if have_cmd systemd-detect-virt; then
        VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
    else
        if [ -f /proc/user_beancounters ]; then
            VIRT="openvz"
        elif [ -f /.dockerenv ]; then
            VIRT="docker"
        elif grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
            VIRT="lxc"
        elif grep -qa 'container=' /proc/1/environ 2>/dev/null; then
            VIRT="container"
        elif grep -qai 'qemu\|kvm' /proc/cpuinfo 2>/dev/null; then
            VIRT="kvm"
        elif grep -qai 'vmware' /proc/cpuinfo 2>/dev/null; then
            VIRT="vmware"
        elif grep -qai 'microsoft' /proc/cpuinfo 2>/dev/null; then
            VIRT="hyperv"
        fi
    fi
    return 0
}

kernel_ge() {
    local maj="${1:-0}" min="${2:-0}"
    [ "$KERNEL_MAJOR" -gt "$maj" ] && return 0
    [ "$KERNEL_MAJOR" -lt "$maj" ] && return 1
    [ "$KERNEL_MINOR" -ge "$min" ] && return 0
    return 1
}

systemd_ver_ge() {
    [ "$HAS_SYSTEMD" = "1" ] || return 1
    version_ge "$SYSTEMD_VER" "$1"
}

os_print_info() {
    cat <<EOF
发行版      : $OS_PRETTY (id=$OS_ID family=$OS_FAMILY version=$OS_VERSION_ID)
包管理器    : ${PKG_MGR:-未知}
架构        : $ARCH (Xray 资产后缀: $XRAY_ARCH)
初始化系统  : $INIT_SYS${SYSTEMD_VER:+ (systemd $SYSTEMD_VER)}
内核        : $KERNEL_VER  (BBR 需要 >= 4.9)
虚拟化      : $VIRT
EOF
}

# 发行版支持提示(不阻断, 只警告)
os_support_check() {
    case "$OS_FAMILY" in
        rhel)
            if [ "$OS_ID" = "centos" ] && [ "${OS_MAJOR:-0}" -lt 7 ]; then
                log_warn "CentOS ${OS_VERSION_ID} 已停止维护且无 systemd, 将使用 SysV + cron 降级模式"
                log_warn "该系统的 CA 根证书可能过期, 若下载失败请手动放置内核包到 $VPNX_STATE_DIR/pkg/"
            fi
            ;;
        debian)
            if [ "$OS_ID" = "ubuntu" ] && [ "${OS_MAJOR:-0}" -lt 16 ]; then
                log_warn "Ubuntu ${OS_VERSION_ID} 较老, 建议使用 18.04 及以上"
            fi
            if [ "$OS_ID" = "debian" ] && [ "${OS_MAJOR:-0}" -lt 9 ]; then
                log_warn "Debian ${OS_VERSION_ID} 较老, 将使用兼容模式"
            fi
            ;;
        unknown)
            log_warn "未能识别的发行版($OS_PRETTY), 将尽力以通用方式安装; 如失败请反馈"
            ;;
    esac
    if [ "$VIRT" = "openvz" ]; then
        log_warn "检测到 OpenVZ: 内核参数(BBR)与部分 iptables 功能不可用, 已自动跳过"
    fi
}

# ---------------------------------------------------------------------------
# 包管理
# ---------------------------------------------------------------------------
pkg_install() {
    [ $# -eq 0 ] && return 0
    case "$PKG_MGR" in
        apt-get)
            if [ "${OFFLINE:-0}" != "1" ] && [ "$APT_REFRESHED" != "1" ]; then
                run env DEBIAN_FRONTEND=noninteractive apt-get update -qq || log_warn "apt-get update 失败, 继续尝试安装"
                APT_REFRESHED=1
            fi
            run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
            ;;
        dnf)    run dnf install -y "$@" ;;
        yum)    run yum install -y "$@" ;;
        zypper) run zypper -n install "$@" ;;
        apk)    run apk add --no-cache "$@" ;;
        *)
            log_warn "未知包管理器, 无法自动安装: $* (请手动安装)"
            return 1
            ;;
    esac
}

# 确保基础依赖存在(curl/openssl 必需, unzip 用于解包)
pkg_ensure_base() {
    local need=""
    [ "$HAS_OPENSSL" = "1" ] || need="$need openssl"
    [ "$HAS_CURL" = "1" ] || [ "$HAS_WGET" = "1" ] || need="$need curl"
    [ "$HAS_UNZIP" = "1" ] || [ "$HAS_TAR" = "1" ] || need="$need unzip"
    need="$(trim "$need")"
    if [ -n "$need" ]; then
        log_info "安装基础依赖: $need"
        # shellcheck disable=SC2086
        pkg_install $need || true
    fi
    # 防火墙/网络工具(失败不阻断)
    if [ "$HAS_SS" = "0" ] && [ "$OS_FAMILY" = "rhel" ]; then
        pkg_install iproute >/dev/null 2>&1 || true
    fi
    OS_DETECTED=0
    os_detect
}

# ---------------------------------------------------------------------------
# 服务管理(systemd / openrc / sysv)
# ---------------------------------------------------------------------------
svc_action() {
    local action="$1" name="$2"
    case "$INIT_SYS" in
        systemd) run systemctl "$action" "$name" ;;
        openrc)  run rc-service "$name" "$action" ;;
        *)
            if have_cmd service; then
                run service "$name" "$action"
            elif [ -x "/etc/init.d/$name" ]; then
                run "/etc/init.d/$name" "$action"
            else
                log_warn "找不到服务 $name 的管理方式"
                return 1
            fi
            ;;
    esac
}

svc_is_active() {
    local name="$1"
    case "$INIT_SYS" in
        systemd) systemctl is-active --quiet "$name" 2>/dev/null && return 0; return 1 ;;
        openrc)  rc-service "$name" status >/dev/null 2>&1 && return 0; return 1 ;;
        *)
            if [ -x "/etc/init.d/$name" ]; then
                "/etc/init.d/$name" status >/dev/null 2>&1 && return 0
            fi
            return 1
            ;;
    esac
}

svc_exists() {
    local name="$1"
    case "$INIT_SYS" in
        systemd) systemctl list-unit-files 2>/dev/null | grep -q "^$name\." && return 0
                 [ -f "/etc/systemd/system/$name.service" ] && return 0
                 return 1 ;;
        *) [ -f "/etc/init.d/$name" ] && return 0; return 1 ;;
    esac
}

svc_enable() {
    local name="$1"
    case "$INIT_SYS" in
        systemd) run systemctl enable "$name" >/dev/null 2>&1 || log_warn "enable $name 失败" ;;
        openrc)  run rc-update add "$name" default >/dev/null 2>&1 || true ;;
        *)
            if have_cmd chkconfig; then
                run chkconfig --add "$name" >/dev/null 2>&1 || true
                run chkconfig "$name" on >/dev/null 2>&1 || true
            elif have_cmd update-rc.d; then
                run update-rc.d "$name" defaults >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

svc_disable() {
    local name="$1"
    case "$INIT_SYS" in
        systemd) run systemctl disable "$name" >/dev/null 2>&1 || true ;;
        openrc)  run rc-update del "$name" default >/dev/null 2>&1 || true ;;
        *)
            if have_cmd chkconfig; then
                run chkconfig "$name" off >/dev/null 2>&1 || true
                run chkconfig --del "$name" >/dev/null 2>&1 || true
            elif have_cmd update-rc.d; then
                run update-rc.d -f "$name" remove >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

svc_daemon_reload() {
    [ "$HAS_SYSTEMD" = "1" ] && run systemctl daemon-reload >/dev/null 2>&1
    return 0
}

# ---------------------------------------------------------------------------
# 计划任务: systemd timer 优先, 否则 /etc/cron.d
#   sched_install <名字> <描述> <every:秒 | cron表达式> <命令>
# ---------------------------------------------------------------------------
_sched_cron_expr() {
    local sched="$1" sec
    case "$sched" in
        every:*)
            sec="$(printf '%s' "$sched" | sed 's/every://')"
            if [ "$sec" -le 60 ]; then printf '* * * * *'
            elif [ "$sec" -le 300 ]; then printf '*/5 * * * *'
            elif [ "$sec" -le 1800 ]; then printf '*/30 * * * *'
            else printf '0 * * * *'; fi
            ;;
        *) printf '%s' "$sched" ;;
    esac
}

_sched_timer_sec() {
    local sched="$1"
    case "$sched" in
        every:*) printf '%s' "$(printf '%s' "$sched" | sed 's/every://')" ;;
        *) printf '60' ;;
    esac
}

sched_install() {
    local name="$1" desc="$2" sched="$3" cmd="$4"
    local vname="vpnx-$name" sec expr

    if [ "$HAS_SYSTEMD" = "1" ]; then
        sec="$(_sched_timer_sec "$sched")"
        if [ "${DRY_RUN:-0}" != "1" ]; then
            cat > "/etc/systemd/system/$vname.service" <<EOF
[Unit]
Description=$desc
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$cmd
Nice=10
EOF
            cat > "/etc/systemd/system/$vname.timer" <<EOF
[Unit]
Description=$desc (timer)

[Timer]
OnBootSec=2min
OnUnitActiveSec=${sec}
AccuracySec=10s
Persistent=true
Unit=$vname.service

[Install]
WantedBy=timers.target
EOF
        else
            printf '%s[dry-run]%s 写入 %s.{service,timer}\n' "$C_DIM" "$C_RST" "/etc/systemd/system/$vname"
        fi
        svc_daemon_reload
        run systemctl enable "$vname.timer" >/dev/null 2>&1 || true
        run systemctl restart "$vname.timer" >/dev/null 2>&1 || true
        log_ok "已安装定时任务 $vname.timer (每 ${sec} 秒)"
    else
        expr="$(_sched_cron_expr "$sched")"
        if [ "${DRY_RUN:-0}" != "1" ]; then
            printf '# %s (vpnx 自动生成, 请勿手工编辑)\n%s root %s\n' \
                "$desc" "$expr" "$cmd" > "/etc/cron.d/$vname"
            chmod 644 "/etc/cron.d/$vname" 2>/dev/null || true
        else
            printf '%s[dry-run]%s 写入 /etc/cron.d/%s\n' "$C_DIM" "$C_RST" "$vname"
        fi
        # 确保 crond 在跑
        if ! svc_is_active crond 2>/dev/null; then
            svc_is_active cron 2>/dev/null || { svc_action start crond >/dev/null 2>&1 || svc_action start cron >/dev/null 2>&1 || true; }
        fi
        log_ok "已安装 cron 任务 /etc/cron.d/$vname ($expr)"
    fi
}

sched_remove() {
    local name="$1" vname="vpnx-$name"
    if [ "$HAS_SYSTEMD" = "1" ]; then
        run systemctl stop "$vname.timer" >/dev/null 2>&1 || true
        run systemctl disable "$vname.timer" >/dev/null 2>&1 || true
        run rm -f "/etc/systemd/system/$vname.timer" "/etc/systemd/system/$vname.service"
        svc_daemon_reload
    fi
    run rm -f "/etc/cron.d/$vname"
    log_info "已移除定时任务 $vname"
}

sched_status() {
    local name="$1" vname="vpnx-$name"
    if [ "$HAS_SYSTEMD" = "1" ] && [ -f "/etc/systemd/system/$vname.timer" ]; then
        systemctl list-timers "$vname.timer" --no-pager 2>/dev/null | sed -n '1,3p'
        return 0
    fi
    if [ -f "/etc/cron.d/$vname" ]; then
        cat "/etc/cron.d/$vname"
        return 0
    fi
    printf '未安装 (%s)\n' "$vname"
    return 1
}

# ---------------------------------------------------------------------------
# 端口监听信息
# ---------------------------------------------------------------------------
listen_tcp_ports() {
    if [ "$HAS_SS" = "1" ]; then
        ss -Hlnt 2>/dev/null | awk '{print $4}' | sed 's/.*://'
    elif [ "$HAS_NETSTAT" = "1" ]; then
        netstat -lnt 2>/dev/null | awk 'NR>2 {print $4}' | sed 's/.*://'
    elif [ -r /proc/net/tcp ]; then
        awk 'NR>1 {print $2}' /proc/net/tcp 2>/dev/null | cut -d: -f2 | while read -r h; do
            printf '%d\n' "0x$h" 2>/dev/null || true
        done
    fi
    return 0
}

listen_udp_ports() {
    if [ "$HAS_SS" = "1" ]; then
        ss -Hlnu 2>/dev/null | awk '{print $4}' | sed 's/.*://'
    elif [ "$HAS_NETSTAT" = "1" ]; then
        netstat -lnu 2>/dev/null | awk 'NR>2 {print $4}' | sed 's/.*://'
    elif [ -r /proc/net/udp ]; then
        awk 'NR>1 {print $2}' /proc/net/udp 2>/dev/null | cut -d: -f2 | while read -r h; do
            printf '%d\n' "0x$h" 2>/dev/null || true
        done
    fi
    return 0
}
