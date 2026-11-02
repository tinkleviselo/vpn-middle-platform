#!/usr/bin/env bash
# ==============================================================================
#  vpnx - 海外 VPS 通用 VPN/代理节点 部署 + 多账号管理 + 中台同步
#  ---------------------------------------------------------------------------
#  设计目标:
#    1. 通用: CentOS / RHEL / AlmaLinux / Rocky / Oracle / Fedora / Debian / Ubuntu
#       兼容老系统(systemd 219 的 CentOS7 / 无 systemd 的 CentOS6 / glibc 2.17)
#    2. 少依赖: 不装 nginx/php/mysql, 不需要域名与证书(REALITY 借用真实站点握手)
#    3. 与 建站面板共存: 不碰面板目录/服务/端口, 防火墙只做增量
#    4. 可托管: 账号库 + 用量 + 策略 + 订阅全部可同步到远端中台
#
#  用法:  vpnx <command> [options]   (vpnx --help 查看全部命令)
# ==============================================================================
set -uo pipefail

VPNX_VERSION="1.0.1"
VPNX_BUILD="20261010.16"
VPNX_FEATURES="sub-name-hide,auto-upgrade,stats-token-parse,stats-first-entry-fix,user-count-fix,json-get-degraded,device-online-parse,xhttp-reality,xhttp-field-fallback,ss-clients-fix,selftest-per-proto,port-align,clash-fallback,query-api,bing-target,ws-compat"
export VPNX_VERSION VPNX_BUILD VPNX_FEATURES

# ---------------------------------------------------------------------------
# 自身路径解析(支持 /usr/local/bin/vpnx 软链)
# ---------------------------------------------------------------------------
_vpnx_self="$0"
while [ -L "$_vpnx_self" ]; do
    _vpnx_dir="$(cd -P "$(dirname "$_vpnx_self")" >/dev/null 2>&1 && pwd)"
    _vpnx_self="$(readlink "$_vpnx_self")"
    case "$_vpnx_self" in
        /*) ;;
        *) _vpnx_self="$_vpnx_dir/$_vpnx_self" ;;
    esac
done
VPNX_HOME="${VPNX_HOME:-$(cd -P "$(dirname "$_vpnx_self")" >/dev/null 2>&1 && pwd)}"
export VPNX_HOME

VPNX_LIBS="common os ports firewall xray config users sub agent health profile bbr install"
for _lib in $VPNX_LIBS; do
    if [ -r "$VPNX_HOME/lib/$_lib.sh" ]; then
        # shellcheck source=/dev/null
        . "$VPNX_HOME/lib/$_lib.sh"
    else
        printf 'vpnx: 缺少模块 lib/%s.sh (VPNX_HOME=%s)\n' "$_lib" "$VPNX_HOME" >&2
        exit 1
    fi
done

export VPNX_VERSION

# ---------------------------------------------------------------------------
# 全局开关
# ---------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
DEBUG=0
OFFLINE=0
export DRY_RUN ASSUME_YES DEBUG OFFLINE

# 退出时释放锁与临时目录
trap 'lock_release; tmp_cleanup' EXIT
trap 'lock_release; tmp_cleanup; exit 130' INT TERM

usage() {
    cat <<'EOF'
vpnx - VPS 通用 VPN 节点部署与多账号管理

部署与维护
  vpnx install [选项]              一键部署(安装 Xray、生成 REALITY 密钥、放行端口、建服务)
  vpnx uninstall [--purge]         卸载(--purge 连账号库与日志一起删)
  vpnx upgrade [--version vX.Y.Z]  升级/降级 Xray 内核
  vpnx status                      运行状态总览
  vpnx doctor                      自检(含 建站面板 冲突、端口占用、时间同步)

账号管理
  vpnx user add <名字> [选项]      新建账号
  vpnx user del <名字>             删除账号
  vpnx user enable|disable <名字>  启用/停用(停用会立刻踢掉在线连接)
  vpnx user reset <名字>           重置 UUID 与密钥(--traffic-only 只清流量)
  vpnx user info <名字>            查看单个账号
  vpnx user list [--traffic]       列出账号
  vpnx user link <名字>            输出分享链接
  vpnx user sub <名字>             生成订阅文件并输出订阅串
  vpnx user prune                  批量停用已到期/超配额账号

订阅
  vpnx sub serve on|off|status     本机内置订阅服务(可选,默认走中台)
  vpnx sub export                  导出全部账号订阅到 /etc/vpnx/sub/

中台同步
  vpnx agent install               安装定时同步(systemd timer 或 cron)
  vpnx agent uninstall             卸载定时同步
  vpnx agent set --url U --node-id I --token T
  vpnx agent run-once [--force]    立即执行一次同步(--force 忽略间隔)
  vpnx agent status                查看同步状态
  vpnx sync now                    同 agent run-once
  vpnx policy pull                 从中台拉取并应用策略
  vpnx policy apply <文件|->       本地应用策略
  vpnx policy show                 查看当前策略

加密与传输档位(热更新)
  vpnx profile list                列出可用档位
  vpnx profile show <名字>         查看档位详情
  vpnx profile add <文件>          安装/更新档位(支持签名校验)

健康与网络
  vpnx health check|fix|watch      自检 / 自愈 / 看护一轮
  vpnx selftest [账号]             节点自测: 用客户端身份连自己的 REALITY 端口做真实握手
  vpnx fw open|close|status        防火墙端口(只做增量,不影响面板)
  vpnx bbr on|off                  内核 BBR 与网络调优

全局选项
  --dry-run    只打印将要执行的动作,不修改系统
  --yes        所有确认一律回答 yes
  --offline    不联网(使用本地缓存的内核包)
  --debug      输出调试日志

环境变量
  VPNX_HOME    程序目录(默认 /usr/local/vpnx)
  VPNX_MIRROR  下载镜像前缀,如 https://mirror.example.com/
EOF
    printf '\n版本: vpnx %s (build %s; 功能: %s)\n' "$VPNX_VERSION" "${VPNX_BUILD:-?}" "${VPNX_FEATURES:-}"
}

# ---------------------------------------------------------------------------
# 参数预处理: 抽掉全局开关(注意: 老 bash(<=4.3) 在 set -u 下不能展开空数组)
# ---------------------------------------------------------------------------
_args=()
for _a in "$@"; do
    case "$_a" in
        --dry-run)  DRY_RUN=1 ;;
        --yes|-y)   ASSUME_YES=1 ;;
        --offline)  OFFLINE=1 ;;
        --debug)    DEBUG=1 ;;
        *)          _args[${#_args[@]}]="$_a" ;;
    esac
done
if [ "${#_args[@]}" -gt 0 ]; then
    set -- ${_args[@]+"${_args[@]}"}
else
    set --
fi

if [ "$DEBUG" = "1" ]; then
    export VPNX_DEBUG=1
fi

cmd="${1:-help}"
if [ $# -gt 0 ]; then shift; fi

# 除 help/version 外先做一次轻量环境探测
case "$cmd" in
    help|--help|-h|version|--version|-v) ;;
    *) os_detect >/dev/null 2>&1 || true ;;
esac

case "$cmd" in
    # ---------------- 部署 ----------------
    install)        cmd_install "$@" ;;
    uninstall)      cmd_uninstall "$@" ;;
    upgrade|update) cmd_upgrade "$@" ;;
    status)         cmd_status "$@" ;;
    doctor)         cmd_doctor "$@" ;;

    # ---------------- 账号 ----------------
    user|users|u)   cmd_user "$@" ;;

    # ---------------- 订阅 ----------------
    sub|subscription) cmd_sub "$@" ;;

    # ---------------- 中台 ----------------
    agent)  cmd_agent "$@" ;;
    sync)
        case "${1:-now}" in
            now)
                if [ $# -gt 0 ]; then shift; fi
                cmd_agent run-once "$@"
                ;;
            *) die "未知 sync 子命令: ${1:-} (可用: now)" ;;
        esac
        ;;
    policy) cmd_policy "$@" ;;

    # ---------------- 档位/健康 ----------------
    profile|profiles) cmd_profile "$@" ;;
    health) cmd_health "$@" ;;
    selftest|self-test) cmd_selftest "$@" ;;
    fw|firewall) cmd_fw "$@" ;;
    bbr) cmd_bbr "$@" ;;

    # ---------------- 其它 ----------------
    version|--version|-v)
        printf 'vpnx %s (build %s; 功能: %s)\n' "$VPNX_VERSION" "${VPNX_BUILD:-?}" "${VPNX_FEATURES:-}"
        ;;
    help|--help|-h|"") usage ;;
    *)
        log_err "未知命令: $cmd"
        usage
        exit 2
        ;;
esac
