#!/usr/bin/env bash
# ==============================================================================
#  lib/ports.sh - 端口占用探测 / 端口选择 / 建站面板 冲突检查
#  关键原则: 绝不占用 建站面板正在使用的端口(80/443/8888/3306/6379/888 等),
#            REALITY 不需要 80/443, 默认只挑高位端口
# ==============================================================================

# 默认端口候选池(按优先级): 443 只有在确认空闲时才会被选中(面板通常占了它)
VPNX_PORT_POOL="${VPNX_PORT_POOL:-443 8443 2053 2083 2087 2096 9443 8444 8081 2082}"

port_in_use() {
    local port="$1" proto="${2:-tcp}" ports
    case "$proto" in
        udp) ports="$(listen_udp_ports)" ;;
        *)   ports="$(listen_tcp_ports)" ;;
    esac
    printf '%s\n' "$ports" | grep -qx "$port"
}

# 占用该端口(IPv4/IPv6 任一监听)即返回 0(视为占用)
port_free() {
    ! port_in_use "$1" "${2:-tcp}"
}

port_owner() {
    local port="$1" out=""
    if [ "$HAS_SS" = "1" ]; then
        out="$(ss -Hlntp 2>/dev/null | awk -v p=":$port\$" '$4 ~ p {print $NF}' | head -n2)"
    fi
    if [ -z "$out" ] && [ "$HAS_NETSTAT" = "1" ]; then
        out="$(netstat -lntp 2>/dev/null | awk -v p=":$port\$" '$4 ~ p {print $7}' | head -n2)"
    fi
    if [ -z "$out" ] && [ "$HAS_LSOF" = "1" ]; then
        out="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1"("$2")"}')"
    fi
    printf '%s' "$out"
}

validate_port() {
    local p="$1"
    case "$p" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

# pick_free_port [候选列表...]  -> 输出一个空闲端口
pick_free_port() {
    local cands="$*" p tried=0
    [ -z "$cands" ] && cands="$VPNX_PORT_POOL"

    for p in $cands; do
        if validate_port "$p" && port_free "$p"; then
            printf '%s' "$p"
            return 0
        fi
    done

    # 候选池都被占用: 随机高位端口
    while [ "$tried" -lt 30 ]; do
        p="$(awk -v s="$RANDOM$RANDOM$$" 'BEGIN { srand(s); printf "%d", 20000 + rand()*40000 }')"
        if validate_port "$p" && port_free "$p"; then
            printf '%s' "$p"
            return 0
        fi
        tried=$((tried + 1))
    done
    return 1
}

# ---------------------------------------------------------------------------
# 建站面板共存检查
# ---------------------------------------------------------------------------
PANEL_PATHS="/usr/local/amh-5.0 /usr/local/amh-6.0 /usr/local/amh-7.0 /usr/local/amh-8.0"
PANEL_RESERVED_PORTS="8888 888 80 443 3306 6379 8889 889 21 22 25"
PANEL_SERVICES="amh amh-nginx nginx apache httpd mysqld mariadb redis php-fpm"

panel_present() {
    local p
    for p in $PANEL_PATHS; do
        [ -d "$p" ] && return 0
    done
    # 目录带版本号, 用通配匹配
    if ls -d /usr/local/amh-* >/dev/null 2>&1; then
        return 0
    fi
    [ -f /usr/local/bin/amh ] && return 0
    [ -d /home/wwwroot/htdocs ] && return 0
    return 0   # 始终执行后续端口检查(函数返回 0 表示"需要做共存检查")
}

panel_version_hint() {
    local d
    for d in /usr/local/amh-*; do
        [ -d "$d" ] && { printf '%s' "$(basename "$d" | sed 's/^amh-//')"; return 0; }
    done
    printf '未知'
}

# 检查指定端口是否可能撞上 面板生态的服务
port_conflict_with_panel() {
    local port="$1" owner
    owner="$(port_owner "$port")"
    [ -z "$owner" ] && return 1
    case "$owner" in
        *nginx*|*httpd*|*apache*|*mysqld*|*mariadb*|*redis*|*php-fpm*|*amh*)
            return 0 ;;
    esac
    return 1
}

# 输出 面板共存体检报告
panel_check_report() {
    local d found=0
    for d in /usr/local/amh-*; do
        if [ -d "$d" ]; then
            printf '  发现面板目录      : %s\n' "$d"
            found=1
        fi
    done
    if [ -f /usr/local/bin/amh ]; then
        printf '  发现面板命令      : /usr/local/bin/amh\n'
        found=1
    fi
    if [ -d /home/wwwroot/htdocs ]; then
        printf '  发现面板站点目录  : /home/wwwroot/htdocs\n'
        found=1
    fi
    if [ "$found" = "0" ]; then
        printf '  未检测到 建站面板(无需共存处理)\n'
        return 0
    fi
    printf '  vpnx 不会触碰      : /usr/local/amh-*, /home/wwwroot, 面板的 nginx/mysql/php 服务\n'
    printf '  vpnx 不使用端口    : %s\n' "$PANEL_RESERVED_PORTS"
    local p
    for p in $PANEL_RESERVED_PORTS; do
        if port_in_use "$p"; then
            printf '  端口 %-5s 正被占用  : %s (vpnx 会避开)\n' "$p" "$(port_owner "$p")"
        fi
    done
    return 0
}

# 校验: 用户指定的端口是否与面板冲突
port_assert_safe() {
    local port="$1"
    if port_conflict_with_panel "$port"; then
        log_warn "端口 $port 已被 $(port_owner "$port") 占用, 且看起来属于面板生态服务"
        log_warn "强烈建议换一个端口(vpnx install --port <其它端口>), 否则会打断面板服务"
        if ! confirm "仍要使用端口 $port 吗?" n; then
            die "已取消(建议使用 --port 指定 8443 之类的高位端口)"
        fi
    elif port_in_use "$port"; then
        log_warn "端口 $port 已被占用: $(port_owner "$port")"
        if ! confirm "仍要使用端口 $port 吗?" n; then
            die "已取消"
        fi
    fi
    return 0
}

# 端口是否在 面板保留列表里
port_is_panel_reserved() {
    local p
    for p in $PANEL_RESERVED_PORTS; do
        [ "$p" = "$1" ] && return 0
    done
    return 1
}
