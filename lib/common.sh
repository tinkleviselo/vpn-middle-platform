#!/usr/bin/env bash
# ==============================================================================
#  lib/common.sh - 公共基础库(日志/锁/配置读写/编码/下载/单位换算)
#  兼容: bash 3.2+ (CentOS6 bash4.1 / CentOS7 bash4.2 / Debian bash5.x)
#  注意: 不使用关联数组、mapfile、${var,,} 等 bash4+ 专有语法;
#        不使用空数组展开(老 bash 在 set -u 下会报 unbound variable)
# ==============================================================================

# ---------------------------------------------------------------------------
# 固定路径
# ---------------------------------------------------------------------------
VPNX_ETC="${VPNX_ETC:-/etc/vpnx}"
VPNX_CONF="$VPNX_ETC/vpnx.conf"
VPNX_XRAY_DIR="$VPNX_ETC/xray"
VPNX_XRAY_CONF="$VPNX_XRAY_DIR/config.json"
VPNX_USERS_DB="$VPNX_ETC/users.db"
VPNX_AGENT_CONF="$VPNX_ETC/agent.conf"
VPNX_POLICY="$VPNX_ETC/policy.json"
VPNX_POLICY_APPLIED="$VPNX_ETC/policy.applied.json"
VPNX_PROFILE_DIR="$VPNX_ETC/profiles"
VPNX_SUB_DIR="$VPNX_ETC/sub"
VPNX_STATE_DIR="$VPNX_ETC/state"
VPNX_BACKUP_DIR="$VPNX_ETC/backup"
VPNX_LOG_DIR="${VPNX_LOG_DIR:-/var/log/vpnx}"
VPNX_RUN_DIR="${VPNX_RUN_DIR:-/var/run/vpnx}"
VPNX_TMP_DIR="${VPNX_TMP_DIR:-/tmp/vpnx.$$}"
export VPNX_ETC VPNX_CONF VPNX_XRAY_DIR VPNX_XRAY_CONF VPNX_USERS_DB \
       VPNX_AGENT_CONF VPNX_POLICY VPNX_POLICY_APPLIED VPNX_PROFILE_DIR \
       VPNX_SUB_DIR VPNX_STATE_DIR VPNX_BACKUP_DIR VPNX_LOG_DIR VPNX_RUN_DIR

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_ASSET_DIR="${XRAY_ASSET_DIR:-/usr/local/share/xray}"
VPNX_LOCK_FILE="${VPNX_LOCK_FILE:-$VPNX_STATE_DIR/.lock}"

# 颜色(非 tty 自动关闭)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[36m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_RST=''
fi

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
_log_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_log_to_file() {
    [ -d "$VPNX_LOG_DIR" ] || return 0
    printf '%s %s\n' "$(_log_ts)" "$1" >> "$VPNX_LOG_DIR/vpnx.log" 2>/dev/null || true
}

log_info()  { printf '%s[信息]%s %s\n' "$C_BLU" "$C_RST" "$*"; _log_to_file "[INFO] $*"; }
log_ok()    { printf '%s[成功]%s %s\n' "$C_GRN" "$C_RST" "$*"; _log_to_file "[ OK ] $*"; }
log_warn()  { printf '%s[警告]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; _log_to_file "[WARN] $*"; }
log_err()   { printf '%s[错误]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; _log_to_file "[FAIL] $*"; }
log_debug() {
    [ "${VPNX_DEBUG:-0}" = "1" ] || return 0
    printf '%s[调试] %s%s\n' "$C_DIM" "$*" "$C_RST" >&2
    _log_to_file "[DBUG] $*"
}
die() { log_err "$*"; exit 1; }

# 统一执行入口: --dry-run 时只打印
run() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '%s[dry-run]%s %s\n' "$C_DIM" "$C_RST" "$*"
        return 0
    fi
    log_debug "exec: $*"
    "$@"
}

run_q() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '%s[dry-run]%s %s\n' "$C_DIM" "$C_RST" "$*"
        return 0
    fi
    "$@" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
    local c
    for c in "$@"; do
        have_cmd "$c" || die "缺少必需命令: $c"
    done
}

require_root() {
    [ "$(id -u)" = "0" ] || die "需要 root 权限执行(请用 sudo 或 root 登录)"
}

now_epoch() { date '+%s'; }
now_str()   { date '+%Y-%m-%d %H:%M:%S'; }

to_lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }
to_upper() { printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]'; }

is_true() {
    case "$(to_lower "${1:-}")" in
        1|yes|true|y|on|enable|enabled) return 0 ;;
        *) return 1 ;;
    esac
}

trim() {
    local s="${1:-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

ensure_dir() {
    local d
    for d in "$@"; do
        [ -d "$d" ] || run mkdir -p "$d"
    done
}

ensure_dirs() {
    ensure_dir "$VPNX_ETC" "$VPNX_XRAY_DIR" "$VPNX_PROFILE_DIR" "$VPNX_SUB_DIR" \
               "$VPNX_STATE_DIR" "$VPNX_BACKUP_DIR" "$VPNX_LOG_DIR" "$VPNX_RUN_DIR"
    if [ "${DRY_RUN:-0}" != "1" ]; then
        chmod 700 "$VPNX_ETC" 2>/dev/null || true
        chmod 755 "$VPNX_STATE_DIR" "$VPNX_SUB_DIR" "$VPNX_LOG_DIR" 2>/dev/null || true
    fi
}

# 版本比较: version_ge A B  (A >= B 返回 0)
version_ge() {
    local a b lowest
    a="$(printf '%s' "${1:-0}" | sed 's/^v//')"
    b="$(printf '%s' "${2:-0}" | sed 's/^v//')"
    [ "$a" = "$b" ] && return 0
    lowest="$(printf '%s\n%s\n' "$a" "$b" | sort -V 2>/dev/null | head -n1)"
    if [ -z "$lowest" ]; then
        # sort -V 不可用时按数字段比较
        local a1 a2 a3 b1 b2 b3
        a1="$(printf '%s' "$a" | cut -d. -f1)"; a2="$(printf '%s' "$a" | cut -d. -f2)"; a3="$(printf '%s' "$a" | cut -d. -f3)"
        b1="$(printf '%s' "$b" | cut -d. -f1)"; b2="$(printf '%s' "$b" | cut -d. -f2)"; b3="$(printf '%s' "$b" | cut -d. -f3)"
        a1="${a1:-0}"; a2="${a2:-0}"; a3="${a3:-0}"
        b1="${b1:-0}"; b2="${b2:-0}"; b3="${b3:-0}"
        [ "$a1" -gt "$b1" ] && return 0
        [ "$a1" -lt "$b1" ] && return 1
        [ "$a2" -gt "$b2" ] && return 0
        [ "$a2" -lt "$b2" ] && return 1
        [ "$a3" -ge "$b3" ] && return 0
        return 1
    fi
    [ "$lowest" = "$a" ]
}

# ---------------------------------------------------------------------------
# 互斥锁(目录锁, 不依赖 flock, 兼容所有老系统)
# ---------------------------------------------------------------------------
VPNX_LOCK_HELD=0
lock_acquire() {
    local wait="${1:-30}" i=0 p
    ensure_dir "$VPNX_STATE_DIR"
    while ! mkdir "$VPNX_LOCK_FILE" 2>/dev/null; do
        if [ -f "$VPNX_LOCK_FILE/pid" ]; then
            p="$(cat "$VPNX_LOCK_FILE/pid" 2>/dev/null || echo 0)"
            if [ -n "$p" ] && [ "$p" != "0" ] && ! kill -0 "$p" 2>/dev/null; then
                log_warn "清理残留锁(进程 $p 已不存在)"
                rm -rf "$VPNX_LOCK_FILE"
                continue
            fi
        fi
        i=$((i + 1))
        if [ "$i" -ge "$wait" ]; then
            die "获取锁超时($VPNX_LOCK_FILE); 确认无其它 vpnx 在运行后可删除该目录重试"
        fi
        sleep 1
    done
    if [ "${DRY_RUN:-0}" != "1" ]; then
        printf '%s\n' "$$" > "$VPNX_LOCK_FILE/pid" 2>/dev/null || true
    fi
    VPNX_LOCK_HELD=1
}
lock_release() {
    [ "${VPNX_LOCK_HELD:-0}" = "1" ] || return 0
    rm -rf "$VPNX_LOCK_FILE" 2>/dev/null || true
    VPNX_LOCK_HELD=0
}

# ---------------------------------------------------------------------------
# 配置读写 (KEY=value 文本, 值可含空格与 =)
# ---------------------------------------------------------------------------
kv_get() {
    local file="$1" key="$2" def="${3:-}" v
    [ -f "$file" ] || { printf '%s' "$def"; return 0; }
    v="$(awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$file" 2>/dev/null)"
    v="${v%$'\r'}"
    if [ -z "$v" ]; then printf '%s' "$def"; else printf '%s' "$v"; fi
}

kv_set() {
    local file="$1" key="$2" val="$3" tmp
    ensure_dir "$(dirname "$file")"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '%s[dry-run]%s 设置 %s: %s=%s\n' "$C_DIM" "$C_RST" "$file" "$key" "$val"
        return 0
    fi
    [ -f "$file" ] || : > "$file"
    tmp="${TMPDIR:-/tmp}/.vpnx-kv.$$"
    awk -F= -v k="$key" '$1!=k' "$file" > "$tmp" 2>/dev/null || : > "$tmp"
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

kv_del() {
    local file="$1" key="$2" tmp
    [ -f "$file" ] || return 0
    tmp="${TMPDIR:-/tmp}/.vpnx-kvdel.$$"
    awk -F= -v k="$key" '$1!=k' "$file" > "$tmp" 2>/dev/null || : > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# 原子写: 从标准输入写入文件
atomic_write() {
    local file="$1" mode="${2:-600}" tmp
    ensure_dir "$(dirname "$file")"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        cat > /dev/null
        printf '%s[dry-run]%s 写入 %s\n' "$C_DIM" "$C_RST" "$file"
        return 0
    fi
    tmp="$file.tmp.$$"
    cat > "$tmp"
    chmod "$mode" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file"
}

backup_file() {
    local f="$1" tag="${2:-bak}"
    [ -f "$f" ] || return 0
    ensure_dir "$VPNX_BACKUP_DIR"
    run cp -f "$f" "$VPNX_BACKUP_DIR/$(basename "$f").$tag.$(date '+%Y%m%d%H%M%S')"
}

# ---------------------------------------------------------------------------
# 编码 / 随机 / 哈希
# ---------------------------------------------------------------------------
rand_hex() {
    local n="${1:-16}"
    if [ -r /dev/urandom ]; then
        od -An -N "$n" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
    else
        openssl rand -hex "$n"
    fi
}

rand_b64() {
    local n="${1:-16}"
    openssl rand -base64 "$n" 2>/dev/null | tr -d '\n'
}

gen_uuid() {
    local u
    if [ -x "$XRAY_BIN" ]; then
        u="$("$XRAY_BIN" uuid 2>/dev/null)"
        case "$u" in
            *-*-*-*-*) printf '%s' "$u"; return 0 ;;
        esac
    fi
    if [ -r /proc/sys/kernel/random/uuid ]; then
        tr -d '\n' < /proc/sys/kernel/random/uuid
        return 0
    fi
    local h
    h="$(rand_hex 16)"
    printf '%s-%s-4%s-%s%s-%s\n' \
        "${h:0:8}" "${h:8:4}" "${h:13:3}" \
        "$(printf '%s' "${h:16:1}" | tr '0123456789abcdef' '89ab')" "${h:17:3}" \
        "${h:20:12}"
}

b64_std() { openssl base64 -A 2>/dev/null | tr -d '\n'; }
b64_url() { openssl base64 -A 2>/dev/null | tr -d '\n' | tr '+/' '-_' | tr -d '='; }

sha256_hex()  { printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}'; }
sha256_file() {
    if have_cmd sha256sum; then sha256sum "$1" | awk '{print $1}'
    else openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'; fi
}

json_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

url_encode() {
    local s="${1:-}" out='' c i
    i=0
    while [ "$i" -lt "${#s}" ]; do
        c="${s:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out="$out$c" ;;
            *) out="$out$(printf '%%%02X' "'$c")" ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# 单位与时间
# ---------------------------------------------------------------------------
size_to_bytes() {
    local s num unit
    s="$(to_upper "$(trim "${1:-0}")")"
    [ -z "$s" ] && { printf '0'; return 0; }
    case "$s" in
        *K|*KB) unit=1024 ;;
        *M|*MB) unit=1048576 ;;
        *G|*GB) unit=1073741824 ;;
        *T|*TB) unit=1099511627776 ;;
        *)      unit=1 ;;
    esac
    num="$(printf '%s' "$s" | sed 's/[^0-9.]//g')"
    [ -z "$num" ] && num=0
    awk -v n="$num" -v u="$unit" 'BEGIN { printf "%.0f", n*u }'
}

bytes_to_size() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KB MB GB TB PB", u, " ");
        i = 1;
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        if (i == 1) printf "%d%s", b, u[i];
        else printf "%.2f%s", b, u[i];
    }'
}

# parse_expire 2026-01-31 | "2026-01-31 12:00" | 30d | 12h | 0 -> epoch (0=永不过期)
parse_expire() {
    local s e n
    s="$(trim "${1:-}")"
    case "$s" in
        ''|0|never|none|永不过期) printf '0'; return 0 ;;
    esac
    n="$(printf '%s' "$s" | sed 's/[^0-9]//g')"
    case "$s" in
        *d|*D) printf '%s' "$(( $(now_epoch) + n * 86400 ))"; return 0 ;;
        *h|*H) printf '%s' "$(( $(now_epoch) + n * 3600 ))"; return 0 ;;
        *m|*M) printf '%s' "$(( $(now_epoch) + n * 60 ))"; return 0 ;;
    esac
    e="$(date -d "$s" '+%s' 2>/dev/null)"
    if [ -z "$e" ]; then
        e="$(date -d "$s 23:59:59" '+%s' 2>/dev/null)"
    fi
    [ -n "$e" ] && { printf '%s' "$e"; return 0; }
    printf '0'
}

epoch_to_str() {
    local e="${1:-0}"
    [ "$e" = "0" ] && { printf '永不过期'; return 0; }
    date -d "@$e" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$e"
}

# ---------------------------------------------------------------------------
# 下载(支持 VPNX_MIRROR 前缀镜像, curl/wget 双通道)
# ---------------------------------------------------------------------------
_download_url_rewrite() {
    local url="$1"
    case "$url" in
        http://*|https://*) ;;
        *) url="https://$url" ;;
    esac
    if [ -n "${VPNX_MIRROR:-}" ]; then
        printf '%s%s' "${VPNX_MIRROR%/}/" "$url"
        return 0
    fi
    printf '%s' "$url"
}

download() {
    local url="$1" dest="$2" tmo="${3:-60}" real
    real="$(_download_url_rewrite "$url")"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '%s[dry-run]%s 下载 %s -> %s\n' "$C_DIM" "$C_RST" "$real" "$dest"
        return 0
    fi
    log_debug "下载 $real"
    if have_cmd curl; then
        curl -fsSL --connect-timeout 15 --max-time "$tmo" -o "$dest" "$real" && return 0
        log_debug "curl 下载失败, 尝试 wget"
    fi
    if have_cmd wget; then
        wget -q --timeout="$tmo" -O "$dest" "$real" && return 0
    fi
    return 1
}

# 从 URL 取内容到 stdout
fetch() {
    local url="$1" real
    real="$(_download_url_rewrite "$url")"
    if have_cmd curl; then
        curl -fsSL --connect-timeout 10 --max-time 30 "$real" 2>/dev/null && return 0
    fi
    if have_cmd wget; then
        wget -q -O - --timeout=30 "$real" 2>/dev/null && return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# 交互
# ---------------------------------------------------------------------------
confirm() {
    local msg="$1" def="${2:-n}" ans
    [ "${ASSUME_YES:-0}" = "1" ] && return 0
    if [ "$def" = "y" ]; then
        printf '%s [Y/n]: ' "$msg"
    else
        printf '%s [y/N]: ' "$msg"
    fi
    read -r ans 2>/dev/null || ans=""
    ans="$(to_lower "$(trim "$ans")")"
    if [ -z "$ans" ]; then
        [ "$def" = "y" ] && return 0 || return 1
    fi
    case "$ans" in y|yes) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# 临时目录
# ---------------------------------------------------------------------------
tmp_init() {
    # 每个进程用独立临时目录: 否则并发的 vpnx(例如每分钟一次的 agent 同步)
    # 会在退出时把别人正在用的 /tmp/vpnx 一起删掉, 导致文件突然"不存在"。
    if [ -n "${VPNX_TMP_DIR:-}" ] && [ -d "$VPNX_TMP_DIR" ]; then
        return 0
    fi
    if have_cmd mktemp; then
        VPNX_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vpnx.XXXXXX" 2>/dev/null)" || VPNX_TMP_DIR=""
    fi
    [ -n "${VPNX_TMP_DIR:-}" ] || VPNX_TMP_DIR="/tmp/vpnx.$$"
    ensure_dir "$VPNX_TMP_DIR"
    export VPNX_TMP_DIR
}
tmp_cleanup() {
    if [ -n "${VPNX_TMP_DIR:-}" ] && [ -d "$VPNX_TMP_DIR" ]; then
        rm -rf "$VPNX_TMP_DIR" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# 参数解析辅助(供各模块复用)
# ---------------------------------------------------------------------------
# opt_val <参数名> <后续参数列表...>  --name=value / --name value 两种写法统一取值
opt_val() {
    local name="$1"; shift
    local a val=""
    for a in "$@"; do
        case "$a" in
            "$name"=*) val="${a#*=}" ;;
        esac
    done
    if [ -z "$val" ]; then
        local next=0
        for a in "$@"; do
            if [ "$next" = "1" ]; then val="$a"; break; fi
            case "$a" in
                "$name") next=1 ;;
                *) next=0 ;;
            esac
        done
    fi
    printf '%s' "$val"
}

has_flag() {
    local name="$1"; shift
    local a
    for a in "$@"; do
        [ "$a" = "$name" ] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# 配置读取便捷函数
# ---------------------------------------------------------------------------
cfg_get() { kv_get "$VPNX_CONF" "$1" "${2:-}"; }
cfg_set() { kv_set "$VPNX_CONF" "$1" "$2"; }

is_installed() {
    [ -f "$VPNX_CONF" ] && [ -x "$XRAY_BIN" ]
}

require_installed() {
    is_installed || die "尚未部署, 请先执行: vpnx install"
}

# 公网 IP 探测(多源兜底, 失败返回空)
detect_public_ip() {
    local ip=""
    if have_cmd curl; then
        ip="$(curl -fsS --connect-timeout 8 --max-time 12 https://api.ipify.org 2>/dev/null)"
        [ -z "$ip" ] && ip="$(curl -fsS --connect-timeout 8 --max-time 12 https://ifconfig.me/ip 2>/dev/null)"
        [ -z "$ip" ] && ip="$(curl -fsS --connect-timeout 8 --max-time 12 https://ipinfo.io/ip 2>/dev/null)"
    fi
    if [ -z "$ip" ]; then
        # 本地网卡兜底(取第一个非内网 IPv4)
        ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
              | grep -vE '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | head -n1)"
    fi
    printf '%s' "$ip"
}
