#!/usr/bin/env bash
# ==============================================================================
#  lib/users.sh - 多账号管理(增删改查 / 配额 / 到期 / 设备数 / 热加载 / 用量统计)
#  账号库: /etc/vpnx/users.db  (文本, 一行一个账号, 字段用 | 分隔)
#    0 name  1 uuid  2 enabled  3 expire_epoch  4 quota_bytes  5 used_up  6 used_down
#    7 speed_mbps  8 max_devices  9 protocols  10 ss_user_psk  11 sub_token
#    12 created_epoch  13 note
#  设计: 库是唯一事实来源; 渲染出的 config.json 是它的投影;
#        运行中的内核通过 API 热增删用户(新增不重连, 停用立即踢线)
# ==============================================================================

USER_F_NAME=0; USER_F_UUID=1; USER_F_ENABLED=2; USER_F_EXPIRE=3
USER_F_QUOTA=4; USER_F_UP=5; USER_F_DOWN=6; USER_F_SPEED=7
USER_F_DEVICES=8; USER_F_PROTOS=9; USER_F_SSPSK=10; USER_F_SUBTOKEN=11
USER_F_CREATED=12; USER_F_NOTE=13
USER_FIELDS=14

users_init() {
    if [ ! -f "$VPNX_USERS_DB" ]; then
        ensure_dir "$VPNX_ETC"
        if [ "${DRY_RUN:-0}" != "1" ]; then
            printf '# vpnx 账号库 (name|uuid|enabled|expire_epoch|quota_bytes|used_up|used_down|speed_mbps|max_devices|protocols|ss_user_psk|sub_token|created_epoch|note)\n' \
                > "$VPNX_USERS_DB"
            chmod 600 "$VPNX_USERS_DB"
        fi
    fi
    ensure_dir "$VPNX_STATE_DIR"
    return 0
}

users_all_names() {
    [ -f "$VPNX_USERS_DB" ] || return 0
    awk -F'|' 'NF>=10 && $1!="" && $1 !~ /^#/ { print $1 }' "$VPNX_USERS_DB"
}

user_count() {
    # 注意: grep -c 在计数为 0 时退出码非 0, 不能写成 `... || printf '0'`,
    # 否则无账号时会输出两行(0 和 0), 让所有比较都失败。
    local n
    n="$(users_all_names 2>/dev/null | grep -c . 2>/dev/null)"
    is_num "$n" || n=0
    printf '%s\n' "$n"
}

user_exists() {
    [ -n "$1" ] || return 1
    [ -f "$VPNX_USERS_DB" ] || return 1
    awk -F'|' -v n="$1" '$1==n { found=1 } END { exit(found?0:1) }' "$VPNX_USERS_DB"
}

users_validate_name() {
    case "${1:-}" in
        '') return 1 ;;
        *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    [ "${#1}" -le 32 ] || return 1
    return 0
}

# user_field <名字> <字段序号>
user_field() {
    local name="$1" idx="$2" v
    v="$(awk -F'|' -v n="$name" -v i="$idx" '$1==n { print $(i+1); exit }' "$VPNX_USERS_DB" 2>/dev/null)"
    printf '%s' "$v"
}

# 取整行(用于备份/上报)
user_line() {
    awk -F'|' -v n="$1" '$1==n { print; exit }' "$VPNX_USERS_DB" 2>/dev/null
}

# user_set_field <名字> <字段序号> <值>
user_set_field() {
    local name="$1" idx="$2" val="$3" tmp
    [ -f "$VPNX_USERS_DB" ] || return 1
    val="$(printf '%s' "$val" | tr -d '|\r\n')"
    tmp="$VPNX_USERS_DB.tmp.$$"
    awk -F'|' -v OFS='|' -v n="$name" -v i="$idx" -v v="$val" '
        { if ($1==n) { $(i+1)=v } print }
    ' "$VPNX_USERS_DB" > "$tmp" 2>/dev/null || return 1
    cat "$tmp" > "$VPNX_USERS_DB"
    rm -f "$tmp"
    return 0
}

# SS2022 用户密钥长度
ss_psk_len_for_method() {
    case "${1:-}" in
        *aes-128-gcm*) printf '16' ;;
        *aes-256-gcm*|*chacha20*) printf '32' ;;
        *) printf '16' ;;
    esac
}

# 协议是否在节点启用
user_proto_active() {
    case "$1" in
        reality) is_true "$(cfg_get REALITY_ENABLED 1)" ;;
        ss)      is_true "$(cfg_get SS_ENABLED 0)" ;;
        vmess)   is_true "$(cfg_get VMESS_ENABLED 0)" ;;
        xhttp)   is_true "$(cfg_get XHTTP_ENABLED 0)" ;;
        *) return 1 ;;
    esac
}

user_status_text() {
    local name="$1" enabled expire quota up down used now
    enabled="$(user_field "$name" $USER_F_ENABLED)"
    expire="$(user_field "$name" $USER_F_EXPIRE)"
    quota="$(user_field "$name" $USER_F_QUOTA)"
    up="$(user_field "$name" $USER_F_UP)"
    down="$(user_field "$name" $USER_F_DOWN)"
    now="$(now_epoch)"
    used=$(( ${up:-0} + ${down:-0} ))
    if ! is_true "$enabled"; then printf '停用'; return 0; fi
    if is_num "$expire" && [ "$expire" -gt 0 ] && [ "$now" -ge "$expire" ]; then printf '已过期'; return 0; fi
    if is_num "$quota" && [ "$quota" -gt 0 ] && [ "$used" -ge "$quota" ]; then printf '超配额'; return 0; fi
    printf '正常'
}

# ---------------------------------------------------------------------------
# 热加载: 向运行中的内核增/删用户(不改动其它连接)
# ---------------------------------------------------------------------------
# user_hot_add <名字> [协议...]
user_hot_add() {
    local name="$1"; shift
    local protos="$*" p tag uuid sspsk email f
    [ -z "$protos" ] && protos="$(user_field "$name" $USER_F_PROTOS)"
    api_ready || { log_debug "API 不可用, 跳过热加载(重启内核后生效)"; return 1; }
    tmp_init
    uuid="$(user_field "$name" $USER_F_UUID)"
    sspsk="$(user_field "$name" $USER_F_SSPSK)"
    for p in $(printf '%s' "$protos" | tr ',' ' '); do
        tag="$(proto_tag "$p")"
        [ -z "$tag" ] && continue
        user_proto_active "$p" || continue
        email="$(user_email "$name" "$p")"
        f="$VPNX_TMP_DIR/adu.$p.$name.json"
        case "$p" in
            reality)
                printf '{"inbounds":[{"tag":"%s","protocol":"vless","settings":{"clients":[{"id":"%s","email":"%s","flow":"%s"}]}}]}\n' \
                    "$tag" "$uuid" "$email" "$(cfg_get REALITY_FLOW 'xtls-rprx-vision')" > "$f"
                ;;
            ss)
                printf '{"inbounds":[{"tag":"%s","protocol":"shadowsocks","settings":{"method":"%s","password":"%s","clients":[{"password":"%s","email":"%s"}]}}]}\n' \
                    "$tag" "$(cfg_get SS_METHOD '2022-blake3-aes-128-gcm')" "$(cfg_get SS_SERVER_PSK '')" \
                    "$sspsk" "$email" > "$f"
                ;;
            vmess)
                printf '{"inbounds":[{"tag":"%s","protocol":"vmess","settings":{"clients":[{"id":"%s","email":"%s","alterId":0}]}}]}\n' \
                    "$tag" "$uuid" "$email" > "$f"
                ;;
            xhttp)
                # VLESS + XHTTP: 不带 flow(Vision 与 XHTTP 不能同用)
                printf '{"inbounds":[{"tag":"%s","protocol":"vless","settings":{"clients":[{"id":"%s","email":"%s"}],"decryption":"none"}}]}\n' \
                    "$tag" "$uuid" "$email" > "$f"
                ;;
        esac
        if api_add_user_file "$tag" "$f"; then
            log_debug "热加载 $name -> $tag 成功"
        else
            log_warn "热加载 $name -> $tag 失败(重启内核后自动生效)"
        fi
    done
    return 0
}

# user_kick <名字> [协议...]  —— 立即断开该账号在线连接
user_kick() {
    local name="$1"; shift
    local protos="$*" p tag email
    [ -z "$protos" ] && protos="$(user_field "$name" $USER_F_PROTOS)"
    [ -z "$protos" ] && protos="reality,ss,vmess,xhttp"
    api_ready || return 1
    for p in $(printf '%s' "$protos" | tr ',' ' '); do
        tag="$(proto_tag "$p")"
        [ -z "$tag" ] && continue
        email="$(user_email "$name" "$p")"
        api_remove_user "$tag" "$email" >/dev/null 2>&1 || true
    done
    log_debug "已踢下线: $name"
    return 0
}

# ---------------------------------------------------------------------------
# 新增账号
# ---------------------------------------------------------------------------
user_add() {
    local name="${1:-}"
    if [ $# -gt 0 ]; then shift; fi
    [ -n "$name" ] || die "用法: vpnx user add <名字> [--expire 30d|2026-01-31] [--quota 100G] [--speed 100] [--devices 3] [--protocols reality,ss] [--note 备注]"

    users_validate_name "$name" || die "账号名只能包含字母/数字/._- 且不超过 32 字符: $name"
    users_init
    if user_exists "$name"; then
        die "账号已存在: $name (如需重建请先 vpnx user del $name)"
    fi

    local opt_expire opt_quota opt_speed opt_devices opt_protos opt_note
    local uuid sspsk expire quota speed devices protos sub_token created p
    opt_expire="$(opt_val --expire "$@")"
    opt_quota="$(opt_val --quota "$@")"
    opt_speed="$(opt_val --speed "$@")"
    opt_devices="$(opt_val --devices "$@")"
    opt_protos="$(opt_val --protocols "$@")"
    opt_note="$(opt_val --note "$@")"

    expire="$(parse_expire "${opt_expire:-0}")"
    quota="$(size_to_bytes "${opt_quota:-0}")"
    speed="${opt_speed:-0}"
    devices="${opt_devices:-0}"
    protos="${opt_protos:-$(cfg_get DEFAULT_PROTOCOLS 'reality')}"
    [ -z "$protos" ] && protos="reality"

    # 协议校验
    local clean_protos="" any=0
    for p in $(printf '%s' "$protos" | tr ',' ' '); do
        case "$p" in
            vless-reality|vless) p=reality ;;
            shadowsocks|ss2022)  p=ss ;;
            vless-xhttp|xhttp|splithttp) p=xhttp ;;
            vmess-ws|ws)         p=vmess ;;
        esac
        case "$p" in
            reality|ss|vmess|xhttp)
                if user_proto_active "$p"; then
                    clean_protos="${clean_protos:+$clean_protos,}$p"
                    any=1
                else
                    log_warn "协议 $p 在节点上未启用, 已跳过"
                fi
                ;;
            *) log_warn "忽略未知协议: $p" ;;
        esac
    done
    [ "$any" = "1" ] || die "没有任何可用协议(请先 vpnx install 或启用 SS/VMess/XHTTP)"
    protos="$clean_protos"

    is_num "$speed" || speed=0
    is_num "$devices" || devices=0

    uuid="$(gen_uuid)"
    sub_token="$(rand_hex 16)"
    created="$(now_epoch)"
    sspsk=""
    if proto_in "$protos" ss; then
        sspsk="$(ss_gen_psk "$(ss_psk_len_for_method "$(cfg_get SS_METHOD '')")")"
    fi

    # 先备份账号库, 渲染失败可回滚
    cp -f "$VPNX_USERS_DB" "$VPNX_STATE_DIR/users.db.beforeadd" 2>/dev/null || true

    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '%s[dry-run]%s 新增账号 %s protos=%s expire=%s quota=%s\n' \
            "$C_DIM" "$C_RST" "$name" "$protos" "$(epoch_to_str "$expire")" "$(bytes_to_size "$quota")"
    else
        printf '%s|%s|%s|%s|%s|0|0|%s|%s|%s|%s|%s|%s|%s\n' \
            "$name" "$uuid" 1 "$expire" "$quota" "$speed" "$devices" "$protos" \
            "$sspsk" "$sub_token" "$created" "$(printf '%s' "$opt_note" | tr -d '|\r\n')" \
            >> "$VPNX_USERS_DB"
    fi

    # 渲染(持久化) + 热加载(不断开现有连接)
    if ! apply_config; then
        log_err "账号写入后配置渲染失败, 已回滚本次新增"
        if [ "${DRY_RUN:-0}" != "1" ] && [ -f "$VPNX_STATE_DIR/users.db.beforeadd" ]; then
            cp -f "$VPNX_STATE_DIR/users.db.beforeadd" "$VPNX_USERS_DB"
        fi
        return 1
    fi
    user_hot_add "$name" "$protos" || true

    # 订阅
    sub_build "$name" >/dev/null 2>&1 || true

    log_ok "账号已创建: $name"
    printf '  UUID      : %s\n' "$uuid"
    printf '  协议      : %s\n' "$protos"
    printf '  到期      : %s\n' "$(epoch_to_str "$expire")"
    printf '  流量配额  : %s\n' "$(bytes_to_size "$quota")"
    [ "$speed" != "0" ] && printf '  限速(记录): %s Mbps (内核不支持用户级限速, 仅记录并上报中台)\n' "$speed"
    [ "$devices" != "0" ] && printf '  设备数上限: %s (超出会被自动踢下线)\n' "$devices"
    printf '  订阅 token: %s\n' "$sub_token"
    printf '\n查看链接:  vpnx user link %s\n' "$name"
    return 0
}

# ---------------------------------------------------------------------------
# 删除 / 启停 / 重置
# ---------------------------------------------------------------------------
user_del() {
    local name="$1" tmp
    user_exists "$name" || die "账号不存在: $name"
    user_kick "$name" >/dev/null 2>&1 || true
    tmp="$VPNX_USERS_DB.tmp.$$"
    awk -F'|' -v n="$name" '$1!=n' "$VPNX_USERS_DB" > "$tmp" 2>/dev/null
    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '%s[dry-run]%s 删除账号 %s\n' "$C_DIM" "$C_RST" "$name"
    else
        cat "$tmp" > "$VPNX_USERS_DB"
        rm -f "$VPNX_SUB_DIR/$name".* 2>/dev/null || true
        rm -f "$VPNX_SUB_DIR/$(user_field "$name" $USER_F_SUBTOKEN).txt" 2>/dev/null || true
    fi
    rm -f "$tmp"
    apply_config || log_warn "配置重渲染失败, 请执行 vpnx health fix"
    log_ok "账号已删除: $name"
    return 0
}

user_disable() {
    local name="$1" reason="${2:-手动停用}"
    user_exists "$name" || die "账号不存在: $name"
    user_set_field "$name" $USER_F_ENABLED 0
    user_kick "$name" >/dev/null 2>&1 || true
    apply_config || log_warn "配置重渲染失败"
    log_ok "账号已停用: $name ($reason)"
    return 0
}

user_enable() {
    local name="$1"
    user_exists "$name" || die "账号不存在: $name"
    user_set_field "$name" $USER_F_ENABLED 1
    apply_config || log_warn "配置重渲染失败"
    user_hot_add "$name" >/dev/null 2>&1 || true
    log_ok "账号已启用: $name"
    return 0
}

user_reset() {
    local name="$1"; shift
    local traffic_only=0
    has_flag --traffic-only "$@" && traffic_only=1
    user_exists "$name" || die "账号不存在: $name"

    if [ "$traffic_only" = "1" ]; then
        user_set_field "$name" $USER_F_UP 0
        user_set_field "$name" $USER_F_DOWN 0
        apply_config >/dev/null 2>&1 || true
        log_ok "已清零流量: $name"
        return 0
    fi

    local uuid sspsk protos
    protos="$(user_field "$name" $USER_F_PROTOS)"
    uuid="$(gen_uuid)"
    user_kick "$name" "$protos" >/dev/null 2>&1 || true
    user_set_field "$name" $USER_F_UUID "$uuid"
    user_set_field "$name" $USER_F_UP 0
    user_set_field "$name" $USER_F_DOWN 0
    if proto_in "$protos" ss; then
        sspsk="$(ss_gen_psk "$(ss_psk_len_for_method "$(cfg_get SS_METHOD '')")")"
        user_set_field "$name" $USER_F_SSPSK "$sspsk"
    fi
    apply_config || die "配置重渲染失败"
    user_hot_add "$name" "$protos" >/dev/null 2>&1 || true
    sub_build "$name" >/dev/null 2>&1 || true
    log_ok "已重置账号: $name (新 UUID: $uuid)"
    return 0
}

# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------
user_list() {
    local show_traffic=0
    has_flag --traffic "$@" && show_traffic=1
    users_init
    local n=0 name
    printf '%-20s %-8s %-20s %-12s %-16s %s\n' "账号" "状态" "到期" "配额" "已用" "协议"
    printf '%-20s %-8s %-20s %-12s %-16s %s\n' "--------------------" "--------" "--------------------" "------------" "----------------" "----"
    for name in $(users_all_names); do
        local expire quota used protos
        expire="$(user_field "$name" $USER_F_EXPIRE)"
        quota="$(user_field "$name" $USER_F_QUOTA)"
        used=$(( $(user_field "$name" $USER_F_UP) + $(user_field "$name" $USER_F_DOWN) ))
        protos="$(user_field "$name" $USER_F_PROTOS)"
        printf '%-20s %-8s %-20s %-12s %-16s %s\n' \
            "$name" "$(user_status_text "$name")" "$(epoch_to_str "${expire:-0}")" \
            "$([ "${quota:-0}" = "0" ] && echo 不限 || bytes_to_size "$quota")" \
            "$(bytes_to_size "$used")" "$protos"
        n=$((n + 1))
        if [ "$show_traffic" = "1" ]; then
            printf '  └ 上行 %s / 下行 %s\n' \
                "$(bytes_to_size "$(user_field "$name" $USER_F_UP)")" \
                "$(bytes_to_size "$(user_field "$name" $USER_F_DOWN)")"
        fi
    done
    [ "$n" = "0" ] && printf '(还没有账号, 用 vpnx user add <名字> 创建)\n'
    printf '\n共 %s 个账号\n' "$n"
    return 0
}

user_info() {
    local name="$1"
    user_exists "$name" || die "账号不存在: $name"
    printf '账号        : %s\n' "$name"
    printf '状态        : %s\n' "$(user_status_text "$name")"
    printf 'UUID        : %s\n' "$(user_field "$name" $USER_F_UUID)"
    printf '协议        : %s\n' "$(user_field "$name" $USER_F_PROTOS)"
    printf '创建时间    : %s\n' "$(epoch_to_str "$(user_field "$name" $USER_F_CREATED)")"
    printf '到期时间    : %s\n' "$(epoch_to_str "$(user_field "$name" $USER_F_EXPIRE)")"
    printf '流量配额    : %s\n' "$(bytes_to_size "$(user_field "$name" $USER_F_QUOTA)")"
    printf '已用(上/下) : %s / %s\n' \
        "$(bytes_to_size "$(user_field "$name" $USER_F_UP)")" \
        "$(bytes_to_size "$(user_field "$name" $USER_F_DOWN)")"
    printf '限速(记录)  : %s Mbps\n' "$(user_field "$name" $USER_F_SPEED)"
    printf '设备数上限  : %s\n' "$(user_field "$name" $USER_F_DEVICES)"
    printf '订阅 token  : %s\n' "$(user_field "$name" $USER_F_SUBTOKEN)"
    printf '备注        : %s\n' "$(user_field "$name" $USER_F_NOTE)"
    return 0
}

# ---------------------------------------------------------------------------
# 用量统计(从内核 API 拉取增量并累加到账号库)
# ---------------------------------------------------------------------------
user_sync_traffic() {
    users_init
    api_ready || { log_debug "API 不可用, 跳过用量同步"; return 1; }
    local stats="$VPNX_STATE_DIR/stats.json"
    local last="$VPNX_STATE_DIR/usage.last"
    local agg="$VPNX_STATE_DIR/usage.delta"

    api_statsquery "user>>>" > "$stats" 2>/dev/null || return 1
    [ -s "$stats" ] || return 1

    : > "$agg"
    local statname value email rest tail kind prev delta name
    stats_parse_users "$stats" | while IFS='|' read -r statname value; do
        [ -z "$statname" ] && continue
        rest="${statname#user>>>}"
        email="${rest%%>>>*}"
        tail="${rest#*>>>}"
        kind="${tail##*>>>}"
        case "$kind" in
            uplink)   kind=up ;;
            downlink) kind=down ;;
            *) continue ;;
        esac
        is_num "$value" || value=0
        name="${email%@*}"
        [ -z "$name" ] && continue
        prev="$(awk -v k="$email|$kind" -F'|' '$1"|"$2==k { print $3; exit }' "$last" 2>/dev/null)"
        is_num "$prev" || prev=0
        if [ "$value" -ge "$prev" ]; then
            delta=$(( value - prev ))
        else
            # 内核重启后计数器归零, 直接把当前值当作增量
            delta=$value
        fi
        if [ "$kind" = "up" ]; then
            printf '%s|%s|0\n' "$name" "$delta" >> "$agg"
        else
            printf '%s|0|%s\n' "$name" "$delta" >> "$agg"
        fi
    done

    # 汇总并累加
    local totals
    totals="$(awk -F'|' '{ u[$1]+=$2; d[$1]+=$3 } END { for (n in u) printf "%s|%d|%d\n", n, u[n], d[n] }' "$agg" 2>/dev/null)"
    local du dd ou od
    printf '%s\n' "$totals" | while IFS='|' read -r name du dd; do
        [ -z "$name" ] && continue
        user_exists "$name" || continue
        ou="$(user_field "$name" $USER_F_UP)"
        od="$(user_field "$name" $USER_F_DOWN)"
        is_num "$ou" || ou=0
        is_num "$od" || od=0
        user_set_field "$name" $USER_F_UP "$(( ou + du ))"
        user_set_field "$name" $USER_F_DOWN "$(( od + dd ))"
    done

    # 记录本次累计值, 供下次算增量
    stats_parse_users "$stats" | while IFS='|' read -r statname value; do
        [ -z "$statname" ] && continue
        rest="${statname#user>>>}"
        email="${rest%%>>>*}"
        kind="${rest##*>>>}"
        is_num "$value" || value=0
        printf '%s|%s|%s\n' "$email" "$kind" "$value"
    done > "$last.new" 2>/dev/null
    mv -f "$last.new" "$last" 2>/dev/null || true

    return 0
}

# 设备数限制(靠内核在线 IP 列表; 用格式无关解析, 不需要 jq/python)
user_check_devices() {
    local json="$VPNX_STATE_DIR/online.json"
    is_true "$(cfg_get ENFORCE_DEVICES 1)" || return 0
    api_ready || return 0
    api_online_iplist > "$json" 2>/dev/null || return 0
    [ -s "$json" ] || return 0

    # 输出: email|设备数  (纯 awk 解析, JSON 与表格两种形态都支持)
    local counts
    counts="$(online_ips_parse "$json")"
    [ -z "$counts" ] && return 0

    local email cnt name maxd protos
    printf '%s\n' "$counts" | while IFS='|' read -r email cnt; do
        [ -z "$email" ] && continue
        name="${email%@*}"
        user_exists "$name" || continue
        maxd="$(user_field "$name" $USER_F_DEVICES)"
        is_num "$maxd" || maxd=0
        [ "$maxd" = "0" ] && continue
        if [ "$cnt" -gt "$maxd" ]; then
            protos="$(user_field "$name" $USER_F_PROTOS)"
            log_warn "账号 $name 在线设备数 $cnt 超过上限 $maxd, 已踢下线"
            user_kick "$name" "$protos" >/dev/null 2>&1 || true
            agent_event WARN "device_limit" "账号 $name 设备数超限($cnt/$maxd), 已踢下线"
            # 超限次数累计, 避免反复踢反复连
            local vf="$VPNX_STATE_DIR/violations.$name"
            local n=0
            [ -f "$vf" ] && n="$(cat "$vf" 2>/dev/null || echo 0)"
            is_num "$n" || n=0
            n=$((n + 1))
            printf '%s\n' "$n" > "$vf"
        fi
    done
    return 0
}

# 配额/到期强制下线
user_enforce() {
    local name enabled expire quota used now changed=0
    now="$(now_epoch)"
    for name in $(users_all_names); do
        enabled="$(user_field "$name" $USER_F_ENABLED)"
        is_true "$enabled" || continue
        expire="$(user_field "$name" $USER_F_EXPIRE)"
        quota="$(user_field "$name" $USER_F_QUOTA)"
        used=$(( $(user_field "$name" $USER_F_UP) + $(user_field "$name" $USER_F_DOWN) ))
        if is_num "$expire" && [ "$expire" -gt 0 ] && [ "$now" -ge "$expire" ]; then
            log_info "账号 $name 已到期, 自动停用"
            user_disable "$name" "到期自动停用" >/dev/null 2>&1 || true
            agent_event INFO "expired" "账号 $name 已到期并停用"
            changed=1
            continue
        fi
        if is_num "$quota" && [ "$quota" -gt 0 ] && [ "$used" -ge "$quota" ]; then
            log_info "账号 $name 流量超限($(bytes_to_size "$used")/$(bytes_to_size "$quota")), 自动停用"
            user_disable "$name" "超配额自动停用" >/dev/null 2>&1 || true
            agent_event INFO "quota_exceeded" "账号 $name 流量超限并停用"
            changed=1
        fi
    done
    return 0
}

# 批量清理
user_prune() {
    local name enabled expire quota used now n=0
    now="$(now_epoch)"
    for name in $(users_all_names); do
        enabled="$(user_field "$name" $USER_F_ENABLED)"
        is_true "$enabled" || continue
        expire="$(user_field "$name" $USER_F_EXPIRE)"
        quota="$(user_field "$name" $USER_F_QUOTA)"
        used=$(( $(user_field "$name" $USER_F_UP) + $(user_field "$name" $USER_F_DOWN) ))
        if { is_num "$expire" && [ "$expire" -gt 0 ] && [ "$now" -ge "$expire" ]; } \
           || { is_num "$quota" && [ "$quota" -gt 0 ] && [ "$used" -ge "$quota" ]; }; then
            user_disable "$name" "prune" >/dev/null 2>&1 || true
            log_info "已停用: $name"
            n=$((n + 1))
        fi
    done
    log_ok "共停用 $n 个账号"
    return 0
}

# ---------------------------------------------------------------------------
# CLI: vpnx user ...
# ---------------------------------------------------------------------------
cmd_user() {
    local sub="${1:-list}"
    if [ $# -gt 0 ]; then shift; fi
    require_root
    case "$sub" in
        add)
            require_installed
            lock_acquire 30
            user_add "$@"
            ;;
        del|delete|rm)
            require_installed
            [ -n "${1:-}" ] || die "用法: vpnx user del <名字>"
            lock_acquire 30
            user_del "$1"
            ;;
        enable)
            require_installed
            [ -n "${1:-}" ] || die "用法: vpnx user enable <名字>"
            lock_acquire 30
            user_enable "$1"
            ;;
        disable)
            require_installed
            [ -n "${1:-}" ] || die "用法: vpnx user disable <名字>"
            lock_acquire 30
            user_disable "$1"
            ;;
        reset)
            require_installed
            [ -n "${1:-}" ] || die "用法: vpnx user reset <名字> [--traffic-only]"
            lock_acquire 30
            user_reset "$@"
            ;;
        info|show)
            [ -n "${1:-}" ] || die "用法: vpnx user info <名字>"
            user_info "$1"
            ;;
        list|ls)
            user_list "$@"
            ;;
        link|links)
            require_installed
            [ -n "${1:-}" ] || die "用法: vpnx user link <名字>"
            user_exists "$1" || die "账号不存在: $1"
            sub_links "$1"
            ;;
        sub|subinfo)
            require_installed
            [ -n "${1:-}" ] || die "用法: vpnx user sub <名字>"
            user_exists "$1" || die "账号不存在: $1"
            sub_build "$1"
            ;;
        sync)
            user_sync_traffic
            ;;
        prune)
            require_installed
            lock_acquire 30
            user_prune
            ;;
        "")
            user_list ;;
        *)
            printf '用法: vpnx user add|del|enable|disable|reset|info|list|link|sub|prune ...\n'
            return 2
            ;;
    esac
}
