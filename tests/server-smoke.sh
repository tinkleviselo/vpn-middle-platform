#!/usr/bin/env bash
# ==============================================================================
#  tests/server-smoke.sh - vpnx 端到端冒烟测试(在临时目录里跑, 不碰真实系统)
#
#  原理:
#    * 用环境变量把 vpnx 的所有路径重定向到临时目录(VPNX_ETC / VPNX_LOG_DIR / XRAY_BIN ...)
#    * 放一个"假内核"脚本模拟 xray 的 uuid / x25519 / version / -test / api 子命令
#    * 设置 VPNX_NO_SERVICE=1 让脚本不去动 systemd/init.d
#    * 于是可以在任何 Linux(Python 可有可无)上验证:
#        配置渲染 -> 账号增删改 -> 分享链接 -> 订阅 -> 策略下发应用 -> 停用踢线
#
#  用法:  sudo bash tests/server-smoke.sh      (容器里也建议用 root, 因为脚本会做 root 检查)
#  退出码: 0 = 全部通过
# ==============================================================================
set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "$0")/.." >/dev/null 2>&1 && pwd)"
PASS=0
FAIL=0

ok()   { printf '  \033[32m[通过]\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m[失败]\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
step() { printf '\n== %s ==\n' "$*"; }
need() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi; }

if [ ! -x "$REPO_ROOT/vpnx.sh" ]; then
    chmod +x "$REPO_ROOT/vpnx.sh" 2>/dev/null || true
fi

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t vpnx)"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 沙盒环境
# ---------------------------------------------------------------------------
export VPNX_ETC="$TMP/etc"
export VPNX_LOG_DIR="$TMP/log"
export VPNX_RUN_DIR="$TMP/run"
export VPNX_STATE_DIR="$VPNX_ETC/state"
export VPNX_SUB_DIR="$VPNX_ETC/sub"
export VPNX_TMP_DIR="$TMP/work"
export XRAY_BIN="$TMP/bin/xray"
export XRAY_ASSET_DIR="$TMP/share"
export VPNX_NO_SERVICE=1
export VPNX_HOME="$REPO_ROOT"
mkdir -p "$VPNX_ETC" "$VPNX_LOG_DIR" "$VPNX_RUN_DIR" "$VPNX_SUB_DIR" "$VPNX_STATE_DIR" \
         "$TMP/bin" "$XRAY_ASSET_DIR" "$VPNX_TMP_DIR"

step "准备假内核 (模拟 xray 子命令)"
cat > "$XRAY_BIN" <<'STUB'
#!/bin/sh
# vpnx 冒烟测试用的假 xray
case "$1" in
    uuid)    if [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
             else echo "11111111-2222-4333-8444-555555555555"; fi ;;
    x25519)  echo "PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
             echo "Password:   BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" ;;
    version) echo "Xray 26.3.27 (stub)" ;;
    api)
        case "$2" in
            statsquery)
                # 与真实内核一致: value 是不带引号的数字, 冒号后有一个空格
                echo '{"stat": [{"name": "user>>>alice@r>>>traffic>>>uplink","value": 1048576},'
                echo '{"name": "user>>>alice@r>>>traffic>>>downlink","value": 2097152}]}'
                ;;
            statsonlineiplist)
                echo '{"users":[{"email":"alice@r","ips":[{"ip":"1.2.3.4"}]}]}'
                ;;
        esac
        exit 0 ;;
    *)
        for a in "$@"; do
            [ "$a" = "-test" ] && exit 0
        done
        exit 0 ;;
esac
STUB
chmod 755 "$XRAY_BIN"
[ -x "$XRAY_BIN" ]; need $? "假内核可执行"

# ---------------------------------------------------------------------------
step "加载模块"
# shellcheck source=/dev/null
for m in common os ports firewall xray config users sub agent health profile bbr install; do
    # shellcheck source=/dev/null
    . "$REPO_ROOT/lib/$m.sh"
done
need $? "lib/*.sh 加载成功"
DRY_RUN=0; ASSUME_YES=1; DEBUG=0; OFFLINE=0
export VPNX_DEBUG=0

os_detect
ok "发行版识别: $OS_PRETTY / $INIT_SYS"

# ---------------------------------------------------------------------------
step "初始化配置"
cfg_init
[ -f "$VPNX_CONF" ]; need $? "vpnx.conf 已创建"
[ -f "$VPNX_USERS_DB" ]; need $? "users.db 已创建"
[ -f "$VPNX_PROFILE_DIR/reality-vision.json" ]; need $? "内置档位已写入"

cfg_set PUBLIC_IP "203.0.113.10"
cfg_set REALITY_PORT "8443"
cfg_set REALITY_TARGET "www.bing.com:443"
cfg_set REALITY_SNI "www.bing.com"
cfg_set REALITY_SHORT_IDS "0123456789abcdef"
cfg_set REALITY_ENABLED 1
reality_gen_keys
[ -n "$REALITY_PRIVATE_KEY" ]; need $? "REALITY 私钥解析成功 (priv=${REALITY_PRIVATE_KEY:0:6}...)"
[ -n "$REALITY_PUBLIC_KEY" ]; need $? "REALITY 公钥解析成功"
cfg_set REALITY_PRIVATE_KEY "$REALITY_PRIVATE_KEY"
cfg_set REALITY_PUBLIC_KEY "$REALITY_PUBLIC_KEY"
cfg_set SS_ENABLED 1
cfg_set SS_PORT 8388
cfg_set SS_SERVER_PSK "$(ss_gen_psk 16)"
cfg_set XHTTP_ENABLED 1
cfg_set XHTTP_PORT 8444
cfg_set XHTTP_PATH "/vpnx-xhttp"
cfg_set XHTTP_MODE "auto"
cfg_set DEFAULT_PROTOCOLS "reality,ss,xhttp"
net="$(xray_network_default)"
ok "内核 network 名称: $net (新核心 raw / 老核心 tcp)"

# ---------------------------------------------------------------------------
step "渲染配置(空账号)"
render_config "$TMP/empty.json"
need $? "render_config 返回成功"
xray_test "$TMP/empty.json"; need $? "空配置通过内核校验(假内核)"
grep -q '"in-reality"' "$TMP/empty.json"; need $? "配置内含 REALITY 入站"
grep -q '"in-ss"' "$TMP/empty.json"; need $? "配置内含 SS2022 入站"
grep -q '"stats": {}' "$TMP/empty.json"; need $? "统计已开启"
grep -q '"statsUserOnline": true' "$TMP/empty.json"; need $? "在线设备统计已开启"

# ---------------------------------------------------------------------------
step "账号: 新增"
user_add alice --expire 30d --quota 100G --devices 2 --protocols reality,ss,xhttp --note "冒烟测试"
need $? "user_add 成功"
fields="$(awk -F'|' '/^alice\|/ { print NF }' "$VPNX_USERS_DB")"
[ "$fields" = "14" ]; need $? "账号库字段数=$fields (应为 14)"
uuid="$(user_field alice 1)"
case "$uuid" in
    *-*-*-*-*) ok "UUID 格式正确: $uuid" ;;
    *) bad "UUID 异常: $uuid" ;;
esac
[ "$(user_field alice 4)" = "107374182400" ]; need $? "100G 配额换算正确"
[ "$(user_status_text alice)" = "正常" ]; need $? "账号状态正常"
[ "$(user_count)" = "1" ]; need $? "账号计数为 1"

render_config "$TMP/one.json"
grep -q "$uuid" "$TMP/one.json"; need $? "渲染结果含该账号 UUID"
grep -q 'alice@r' "$TMP/one.json"; need $? "渲染结果含 REALITY 统计标识 alice@r"
grep -q 'alice@s' "$TMP/one.json"; need $? "渲染结果含 SS 统计标识 alice@s"

# 流量统计解析: 必须能在"无 jq / 无 python"的退化路径下也读出未加引号的数字值。
# 曾经因为用 -F'"' 取 $4, 数字值取到空串 -> 用量恒为 0 -> 流量配额永远不生效。
cat > "$TMP/stats.json" <<'EOF'
{"stat":[{"name":"user>>>alice@w>>>traffic>>>uplink","value":5014},
{"name":"user>>>alice@w>>>traffic>>>downlink","value":21012647},
{"name":"user>>>alice@s>>>traffic>>>uplink"}]}
EOF
_old_jq="$HAS_JQ"; _old_p3="$HAS_PYTHON3"; _old_p="$HAS_PYTHON"
HAS_JQ=0; HAS_PYTHON3=0; HAS_PYTHON=0
_parsed="$(stats_parse_users "$TMP/stats.json")"
_have_uplink="$(printf '%s\n' "$_parsed" | grep -c 'uplink|5014')"
_have_downlink="$(printf '%s\n' "$_parsed" | grep -c 'downlink|21012647')"
if [ "$_have_uplink" -gt 0 ]; then
    ok "统计解析(退化路径)读出未加引号的数字值"
else
    bad "统计解析(退化路径)第一值缺失: 输入 $(wc -c < "$TMP/stats.json") 字节, 解析出 [$(printf '%s' "$_parsed" | tr '\n' ' ')]"
fi
if [ "$_have_downlink" -gt 0 ]; then
    ok "统计解析(退化路径)读出第二个值"
else
    bad "统计解析(退化路径)第二值缺失: 解析出 [$(printf '%s' "$_parsed" | tr '\n' ' ')]"
fi
if printf '%s\n' "$_parsed" | grep -q 'alice@s>>>'; then
    bad "统计解析把没有 value 的条目也输出了: [$(printf '%s' "$_parsed" | tr '\n' ' ')]"
else
    ok "统计解析跳过无 value 的条目"
fi
HAS_JQ="$_old_jq"; HAS_PYTHON3="$_old_p3"; HAS_PYTHON="$_old_p"

# XHTTP 入站(VLESS + XHTTP + REALITY): 传输名与设置字段按内核版本, 且 clients 不能带 flow
grep -q 'alice@x' "$TMP/one.json"; need $? "渲染结果含 XHTTP 统计标识 alice@x"
if [ "$(xray_xhttp_net)" = "xhttp" ]; then
    grep -q '"network": "xhttp"' "$TMP/one.json"; need $? "渲染结果含 xhttp 传输(新核心)"
else
    grep -q '"network": "splithttp"' "$TMP/one.json"; need $? "渲染结果含 splithttp 传输(老核心)"
fi
grep -q "\"$(xray_xhttp_key)\": {\"path\": \"/vpnx-xhttp\", \"mode\": \"auto\"}" "$TMP/one.json"
need $? "XHTTP 设置字段(path/mode)已写入"
if awk '/"tag": "in-xhttp"/{f=1} f&&/"flow"/{print "F"; exit}' "$TMP/one.json" | grep -q F; then
    bad "XHTTP 入站的 clients 带了 flow(Vision 与 XHTTP 互斥)"
else
    ok "XHTTP 入站 clients 未携带 flow"
fi
# 在线 IP 列表解析(设备数限制): JSON 与表格两种形态都要能解析出 email|设备数
# 之前依赖 json_flatten, 无 jq/python 时退化分支只认扁平 JSON -> 静默跳过, 限制永不生效。
cat > "$TMP/online.json" <<'EOF'
{"users":[{"email":"alice@r","ips":[{"ip":"203.0.113.5:1234"},{"ip":"203.0.113.6:5678"}]},
{"email":"bob@w","ips":[{"ip":"198.51.100.7:999"}]}]}
EOF
_online="$(online_ips_parse "$TMP/online.json")"
printf '%s\n' "$_online" | grep -q '^alice@r|2$'; need $? "在线IP解析(JSON): alice@r 计 2 台"
printf '%s\n' "$_online" | grep -q '^bob@w|1$'; need $? "在线IP解析(JSON): bob@w 计 1 台"

cat > "$TMP/online.txt" <<'EOF'
IP                Last Seen             Email
203.0.113.9:4321  2026-10-12 12:00:00   alice@r
203.0.113.10:5555 2026-10-12 12:01:00   alice@r
198.51.100.8:777  2026-10-12 12:02:00   bob@w
EOF
_online="$(online_ips_parse "$TMP/online.txt")"
printf '%s\n' "$_online" | grep -q '^alice@r|2$'; need $? "在线IP解析(表格): alice@r 计 2 台(时间戳不误判)"
printf '%s\n' "$_online" | grep -q '^bob@w|1$'; need $? "在线IP解析(表格): bob@w 计 1 台"

# 回归防护: SS 入站的用户列表字段名必须是 clients。
# Xray 对未知字段是"静默忽略"的 —— 曾经把这里写成 users, 结果服务端等于没有注册任何
# SS 用户, SS2022 会丢弃所有连接(客户端超时、服务端连日志都没有), 排查成本极高。
grep -qE '^        "clients": \[' "$TMP/one.json"; need $? "SS 入站用 clients 字段注册用户"
if grep -qE '^        "users": \[' "$TMP/one.json"; then
    bad "SS 入站误用了 users 字段(Xray 会静默忽略, 应为 clients)"
else
    ok "SS 入站未使用错误的 users 字段"
fi

# ---------------------------------------------------------------------------
step "JSON 结构校验"
if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TMP/one.json" 2>/dev/null
    need $? "python3 解析 config.json 成功(结构合法)"
elif command -v python >/dev/null 2>&1; then
    python -c "import json,sys; json.load(open(sys.argv[1]))" "$TMP/one.json" 2>/dev/null
    need $? "python 解析 config.json 成功(结构合法)"
else
    ok "无 python, 跳过 JSON 结构校验(已用假内核 -test 校验)"
fi

# ---------------------------------------------------------------------------
step "分享链接与订阅"
links="$(sub_links alice)"
printf '%s\n' "$links" | grep -q '^vless://'; need $? "生成 vless:// 链接"
printf '%s\n' "$links" | grep -q 'pbk='; need $? "vless 链接含 REALITY 公钥"
printf '%s\n' "$links" | grep -q 'flow=xtls-rprx-vision'; need $? "vless 链接含 Vision 流控"
printf '%s\n' "$links" | grep -q '^ss://'; need $? "生成 ss:// 链接"
printf '%s\n' "$links" | grep -q '203.0.113.10:8443'; need $? "链接里的地址端口正确"

sub_build alice > "$TMP/subbuild.txt" 2>&1
need $? "sub_build 成功"
token="$(user_field alice 11)"
[ -f "$VPNX_SUB_DIR/$token.txt" ]; need $? "订阅文件(按 token)已生成: $token.txt"
[ -f "$VPNX_SUB_DIR/$token.clash" ]; need $? "Clash 订阅已生成"
[ -f "$VPNX_SUB_DIR/$token.meta" ]; need $? "订阅流量元数据已生成"
if command -v python3 >/dev/null 2>&1; then
    decoded="$(python3 -c "
import base64,sys
d=open(sys.argv[1],'rb').read().strip()
sys.stdout.write(base64.b64decode(d).decode('utf-8'))
" "$VPNX_SUB_DIR/$token.txt" 2>/dev/null)"
    case "$decoded" in
        vless://*) ok "订阅内容 Base64 可解码且含 vless 链接" ;;
        *) bad "订阅内容解码异常: ${decoded:0:40}" ;;
    esac
fi

# ---------------------------------------------------------------------------
step "用量统计与配额"
user_sync_traffic >/dev/null 2>&1
up="$(user_field alice 5)"
[ "$up" = "1048576" ]; need $? "上行用量累加正确 ($up)"
down="$(user_field alice 6)"
[ "$down" = "2097152" ]; need $? "下行用量累加正确 ($down)"

# 把配额改成 2M, 让账号超限 -> 应被自动停用
user_set_field alice 4 2097152
user_enforce >/dev/null 2>&1
[ "$(user_field alice 2)" = "0" ]; need $? "超配额账号被自动停用"
render_config "$TMP/disabled.json"
if grep -q "$uuid" "$TMP/disabled.json"; then
    bad "停用后的账号仍出现在配置里"
else
    ok "停用后的账号已从配置移除"
fi

# ---------------------------------------------------------------------------
step "账号: 启用 / 重置 / 删除"
user_enable alice >/dev/null 2>&1
[ "$(user_field alice 2)" = "1" ]; need $? "user_enable 生效"
user_reset alice --traffic-only >/dev/null 2>&1
[ "$(user_field alice 5)" = "0" ]; need $? "user reset --traffic-only 清零流量"
new_uuid_before="$(user_field alice 1)"
user_reset alice >/dev/null 2>&1
new_uuid_after="$(user_field alice 1)"
[ "$new_uuid_before" != "$new_uuid_after" ]; need $? "user reset 更换了 UUID"

# ---------------------------------------------------------------------------
step "策略下发(lines 协议)"
cat > "$TMP/policy.lines" <<'POL'
revision=7
node.reality_target=www.cloudflare.com:443
node.reality_server_names=www.cloudflare.com
node.log_level=warning
users.0.action=upsert
users.0.name=bob
users.0.uuid=99999999-8888-4777-8666-555555555555
users.0.expire_at=0
users.0.quota_bytes=0
users.0.enabled=1
users.0.protocols.0=vless-reality
users.0.protocols.1=ss2022
users.1.action=disable
users.1.name=alice
POL
# 策略里的 ack 需要中台, 这里禁用中台只验证本地应用逻辑
cfg_set SYNC_ENABLED 0
agent_apply_policy "$TMP/policy.lines" "" > "$TMP/policy.log" 2>&1
need $? "策略应用成功"
user_exists bob; need $? "策略新增账号 bob 成功"
[ "$(user_field bob 3)" = "0" ]; need $? "bob 到期时间解析正确(0=永久)"
[ "$(user_field bob 9)" = "reality,ss" ]; need $? "协议名映射正确: $(user_field bob 9)"
[ "$(user_field alice 2)" = "0" ]; need $? "策略停用 alice 成功"
[ "$(cfg_get REALITY_TARGET)" = "www.cloudflare.com:443" ]; need $? "节点级 target 已更新"
render_config "$TMP/policy.json"
grep -q 'bob@r' "$TMP/policy.json"; need $? "策略新增账号已进入配置"

# ---------------------------------------------------------------------------
step "档位(加密传输热更新)"
profile_list > "$TMP/profiles.out" 2>&1
if grep -q 'reality-vision' "$TMP/profiles.out"; then
    ok "profile list 输出包含内置档位"
else
    bad "profile list 缺少内置档位(输出前 3 行): $(head -n3 "$TMP/profiles.out" | tr '\n' ' ')"
fi
profile_validate "$VPNX_PROFILE_DIR/reality-vision.json"
need $? "内置档位结构校验通过"
profile_get reality-vision params.flow | grep -q 'xtls-rprx-vision'
need $? "档位参数可读取"

# ---------------------------------------------------------------------------
step "命令行入口"
bash "$REPO_ROOT/vpnx.sh" version > "$TMP/ver.out" 2>&1
if grep -q 'vpnx 1\.' "$TMP/ver.out"; then
    ok "vpnx version 正常"
else
    bad "vpnx version 异常: $(head -n1 "$TMP/ver.out")"
fi
bash "$REPO_ROOT/vpnx.sh" help > "$TMP/help.out" 2>&1
if grep -q 'user add' "$TMP/help.out"; then
    ok "vpnx help 正常"
else
    bad "vpnx help 异常(输出前 2 行): $(head -n2 "$TMP/help.out" | tr '\n' ' ')"
fi
(cd "$REPO_ROOT" && bash vpnx.sh --dry-run fw open 12345 tcp) | grep -q 'dry-run'
need $? "--dry-run 不执行真实动作"

# ---------------------------------------------------------------------------
step "账号: 删除"
user_del alice >/dev/null 2>&1
need $? "user_del 成功"
user_exists alice && bad "alice 仍然存在" || ok "alice 已删除"
user_del bob >/dev/null 2>&1
if [ "$(user_count)" = "0" ]; then
    ok "账号库已清空"
else
    bad "账号库未清空(计数=$(user_count)): $(grep -v '^#' "$VPNX_USERS_DB" | cut -d'|' -f1 | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
printf '\n========================================\n'
printf '冒烟测试结果: %d 通过, %d 失败\n' "$PASS" "$FAIL"
printf '========================================\n'
[ "$FAIL" = "0" ] || exit 1
exit 0
