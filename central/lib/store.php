<?php
/**
 * vpnx 中台 - 数据层(全部落 JSON 文件, 不用数据库)
 *
 * 数据布局(data/ 目录, 可用环境变量 VPNX_DATA_DIR 覆盖):
 *   config.json            配置(管理员口令哈希/管理令牌/档位/节点默认参数)
 *   nodes.json             节点注册表 + 运行时状态
 *   users.json             账号表(中台是账号的唯一事实来源)
 *   subs.json              订阅内容(各节点上报的 links / clash / meta)
 *   nonces.json            节点请求 nonce 去重窗口
 *   policy_state/<id>.json 每个节点的策略修订号 / 内容指纹 / 待删除墓碑 / ack
 *   usage/<id>.json        每个节点的用量(账号上报的累计值)
 *   events/<id>.jsonl      节点事件流
 *   audit.jsonl            管理操作审计
 *
 * 并发约定:
 *   * 所有写操作都必须由调用方(api.php / index.php)先 vpnx_lock(),
 *     本文件里的函数一律不加锁, 以避免 flock 同进程重入死锁。
 *   * 单个 JSON 文件的写入是 "临时文件 + rename" 原子操作, 读方不会读到半个文件。
 */

// ---------------------------------------------------------------------------
// 节点
// ---------------------------------------------------------------------------
function vpnx_nodes_load()
{
    $d = vpnx_json_read(vpnx_data_dir() . DIRECTORY_SEPARATOR . 'nodes.json', array());
    if (!isset($d['nodes']) || !is_array($d['nodes'])) {
        $d = array('nodes' => array());
    }
    return $d;
}

function vpnx_nodes_save($d)
{
    return vpnx_json_write(vpnx_data_dir() . DIRECTORY_SEPARATOR . 'nodes.json', $d);
}

/**
 * 取单个节点(不存在返回 null)
 */
function vpnx_node_get($id)
{
    $d = vpnx_nodes_load();
    return isset($d['nodes'][$id]) ? $d['nodes'][$id] : null;
}

/**
 * 注册节点
 *
 * @param string $id      节点 ID(小写字母开头)
 * @param string $name    显示名
 * @param string $ip      公网 IP(可空)
 * @param array  $tags    标签, 用于"按标签圈定账号同步范围"
 * @param array  $settings 节点级参数覆盖(端口/伪装目标等)
 * @return array ok / error / node / secret
 */
function vpnx_node_add($id, $name, $ip, $tags, $settings = array())
{
    $id = strtolower(trim((string) $id));
    if (!vpnx_valid_node_id($id)) {
        return array('ok' => false, 'error' => '节点 ID 只能是小写字母/数字/._- 且以字母数字开头');
    }
    $d = vpnx_nodes_load();
    if (isset($d['nodes'][$id])) {
        return array('ok' => false, 'error' => '节点已存在: ' . $id);
    }
    $secret = vpnx_random_hex(32);
    $node = array(
        'id' => $id,
        'name' => $name !== '' ? $name : $id,
        'ip' => (string) $ip,
        'tags' => vpnx_sanitize_tags($tags),
        'settings' => is_array($settings) ? $settings : array(),
        'secret' => $secret,
        'enabled' => true,
        'created_at' => vpnx_now(),
        'runtime' => array(
            'last_seen' => 0,
            'last_ip' => '',
            'xray_version' => '',
            'os' => '',
            'agent_version' => '',
            'users_total' => 0,
            'traffic_total_bytes' => 0,
            'health' => array(),
        ),
    );
    $d['nodes'][$id] = $node;
    vpnx_nodes_save($d);
    vpnx_audit('admin', 'node_add', $id);
    return array('ok' => true, 'node' => $node, 'secret' => $secret);
}

/**
 * 更新节点可编辑字段
 */
function vpnx_node_update($id, $patch)
{
    $d = vpnx_nodes_load();
    if (!isset($d['nodes'][$id])) {
        return array('ok' => false, 'error' => '节点不存在: ' . $id);
    }
    $node = $d['nodes'][$id];
    if (isset($patch['name'])) {
        $node['name'] = (string) $patch['name'];
    }
    if (isset($patch['ip'])) {
        $node['ip'] = (string) $patch['ip'];
    }
    if (isset($patch['tags'])) {
        $node['tags'] = vpnx_sanitize_tags($patch['tags']);
    }
    if (isset($patch['settings']) && is_array($patch['settings'])) {
        foreach ($patch['settings'] as $k => $v) {
            if ($v === null || $v === '') {
                unset($node['settings'][$k]);
            } else {
                $node['settings'][$k] = $v;
            }
        }
    }
    if (isset($patch['enabled'])) {
        $node['enabled'] = (bool) $patch['enabled'];
    }
    $d['nodes'][$id] = $node;
    vpnx_nodes_save($d);
    vpnx_audit('admin', 'node_update', $id);
    return array('ok' => true, 'node' => $node);
}

/**
 * 删除节点(连带清理策略状态/用量/订阅关联)
 */
function vpnx_node_delete($id)
{
    $d = vpnx_nodes_load();
    if (!isset($d['nodes'][$id])) {
        return array('ok' => false, 'error' => '节点不存在: ' . $id);
    }
    unset($d['nodes'][$id]);
    vpnx_nodes_save($d);
    @unlink(vpnx_data_dir() . DIRECTORY_SEPARATOR . 'policy_state' . DIRECTORY_SEPARATOR . $id . '.json');
    @unlink(vpnx_data_dir() . DIRECTORY_SEPARATOR . 'usage' . DIRECTORY_SEPARATOR . $id . '.json');

    // 订阅里去掉该节点的内容
    $subs = vpnx_subs_load();
    foreach (array_keys($subs) as $token) {
        if (isset($subs[$token]['nodes'][$id])) {
            unset($subs[$token]['nodes'][$id]);
            if (!$subs[$token]['nodes']) {
                unset($subs[$token]);
            }
        }
    }
    vpnx_subs_save($subs);
    vpnx_audit('admin', 'node_delete', $id);
    return array('ok' => true);
}

/**
 * 轮换节点密钥
 */
function vpnx_node_rotate($id)
{
    $d = vpnx_nodes_load();
    if (!isset($d['nodes'][$id])) {
        return array('ok' => false, 'error' => '节点不存在: ' . $id);
    }
    $secret = vpnx_random_hex(32);
    $d['nodes'][$id]['secret'] = $secret;
    vpnx_nodes_save($d);
    vpnx_audit('admin', 'node_rotate', $id);
    return array('ok' => true, 'secret' => $secret);
}

/**
 * 心跳时更新节点运行时信息
 */
function vpnx_node_touch($id, $info)
{
    $d = vpnx_nodes_load();
    if (!isset($d['nodes'][$id])) {
        return false;
    }
    $rt = isset($d['nodes'][$id]['runtime']) && is_array($d['nodes'][$id]['runtime'])
        ? $d['nodes'][$id]['runtime'] : array();
    $fields = array('last_seen', 'last_ip', 'xray_version', 'os', 'kernel', 'arch', 'agent_version',
        'users_total', 'users_active', 'traffic_total_bytes', 'health', 'public_ip', 'uptime_sec',
        'inbounds');
    foreach ($fields as $f) {
        if (array_key_exists($f, $info)) {
            $rt[$f] = $info[$f];
        }
    }
    $rt['last_seen'] = vpnx_now();
    $rt['last_ip'] = vpnx_client_ip();
    $d['nodes'][$id]['runtime'] = $rt;
    vpnx_nodes_save($d);
    return true;
}

/**
 * 规范化标签数组(去空/去重/限制字符)
 */
function vpnx_sanitize_tags($tags)
{
    if (is_string($tags)) {
        $tags = preg_split('/[\s,]+/', $tags);
    }
    if (!is_array($tags)) {
        return array();
    }
    $out = array();
    foreach ($tags as $t) {
        $t = trim((string) $t);
        if ($t === '' || !vpnx_valid_component($t)) {
            continue;
        }
        if (!in_array($t, $out, true)) {
            $out[] = $t;
        }
    }
    return $out;
}

// ---------------------------------------------------------------------------
// 账号
// ---------------------------------------------------------------------------
function vpnx_users_load()
{
    $d = vpnx_json_read(vpnx_data_dir() . DIRECTORY_SEPARATOR . 'users.json', array());
    if (!isset($d['users']) || !is_array($d['users'])) {
        $d = array('users' => array());
    }
    return $d;
}

function vpnx_users_save($d)
{
    return vpnx_json_write(vpnx_data_dir() . DIRECTORY_SEPARATOR . 'users.json', $d);
}

function vpnx_user_get($name)
{
    $d = vpnx_users_load();
    return isset($d['users'][$name]) ? $d['users'][$name] : null;
}

/**
 * 协议名归一化: 中台统一使用 vless-reality / ss2022 / vmess-ws
 *
 * @param mixed $protocols 数组或逗号分隔字符串
 * @return array
 */
function vpnx_normalize_protocols($protocols)
{
    if (is_string($protocols)) {
        $protocols = preg_split('/[\s,]+/', $protocols);
    }
    if (!is_array($protocols)) {
        return array();
    }
    $map = array(
        'vless-reality' => 'vless-reality', 'reality' => 'vless-reality', 'vless' => 'vless-reality',
        'ss2022' => 'ss2022', 'ss' => 'ss2022', 'shadowsocks' => 'ss2022',
        'vmess-ws' => 'vmess-ws', 'vmess' => 'vmess-ws',
        'vless-xhttp' => 'vless-xhttp', 'xhttp' => 'vless-xhttp', 'splithttp' => 'vless-xhttp',
    );
    $out = array();
    foreach ($protocols as $p) {
        $p = strtolower(trim((string) $p));
        if (isset($map[$p]) && !in_array($map[$p], $out, true)) {
            $out[] = $map[$p];
        }
    }
    return $out;
}

/**
 * 新增账号
 *
 * @param array $in name/expire_at/quota_bytes/max_devices/speed_mbps/protocols/nodes/tags/note/uuid/ss_password
 * @return array ok / error / user
 */
function vpnx_user_add($in)
{
    $name = isset($in['name']) ? trim((string) $in['name']) : '';
    if (!vpnx_valid_name($name)) {
        return array('ok' => false, 'error' => '账号名只能包含字母/数字/._- 且不超过 64 字符');
    }
    if (vpnx_user_get($name) !== null) {
        return array('ok' => false, 'error' => '账号已存在: ' . $name);
    }

    $cfg = vpnx_config();
    $allowed = isset($cfg['allow_protocols']) ? $cfg['allow_protocols'] : array();
    $protocols = vpnx_normalize_protocols(isset($in['protocols']) ? $in['protocols'] : array());
    if (!$protocols) {
        $protocols = vpnx_normalize_protocols($cfg['default_protocols']);
    }
    foreach ($protocols as $p) {
        if ($allowed && !in_array($p, $allowed, true)) {
            return array('ok' => false, 'error' => '协议 ' . $p . ' 不在中台允许列表(allow_protocols)中');
        }
    }

    // 目标节点: 显式指定 + 标签圈定; 两者都为空表示"所有节点"
    $nodes = array();
    if (isset($in['nodes'])) {
        $list = is_array($in['nodes']) ? $in['nodes'] : preg_split('/[\s,]+/', (string) $in['nodes']);
        $reg = vpnx_nodes_load();
        foreach ($list as $nid) {
            $nid = strtolower(trim((string) $nid));
            if ($nid === '') {
                continue;
            }
            if (!isset($reg['nodes'][$nid])) {
                return array('ok' => false, 'error' => '节点不存在: ' . $nid);
            }
            if (!in_array($nid, $nodes, true)) {
                $nodes[] = $nid;
            }
        }
    }
    $tags = vpnx_sanitize_tags(isset($in['tags']) ? $in['tags'] : array());

    $uuid = isset($in['uuid']) && vpnx_valid_uuid($in['uuid']) ? $in['uuid'] : vpnx_uuid_v4();
    $ss = null;
    if (in_array('ss2022', $protocols, true)) {
        $method = '2022-blake3-aes-128-gcm';
        if (isset($cfg['profiles']['ss']['params']['method'])) {
            $method = $cfg['profiles']['ss']['params']['method'];
        }
        $ss = vpnx_ss_psk(vpnx_ss_key_len($method));
    }

    $user = array(
        'name' => $name,
        'uuid' => $uuid,
        'ss_password' => $ss,
        'sub_token' => vpnx_random_hex(16),
        'enabled' => true,
        'expire_at' => vpnx_parse_expire(isset($in['expire_at']) ? $in['expire_at'] : 0),
        'quota_bytes' => vpnx_size_to_bytes(isset($in['quota_bytes']) ? $in['quota_bytes'] : 0),
        'used_up' => 0,
        'used_down' => 0,
        'max_devices' => (int) (isset($in['max_devices']) ? $in['max_devices'] : 0),
        'speed_mbps' => (int) (isset($in['speed_mbps']) ? $in['speed_mbps'] : 0),
        'protocols' => $protocols,
        'nodes' => $nodes,
        'tags' => $tags,
        'note' => isset($in['note']) ? (string) $in['note'] : '',
        'created_at' => vpnx_now(),
        'updated_at' => vpnx_now(),
    );

    $d = vpnx_users_load();
    $d['users'][$name] = $user;
    vpnx_users_save($d);

    // 该账号重新出现, 清掉可能存在的删除墓碑
    foreach (vpnx_user_resolve_nodes($user) as $nid) {
        vpnx_tombstone_drop($nid, $name);
    }
    vpnx_audit('admin', 'user_add', $name . ' nodes=' . implode(',', $nodes) . ' tags=' . implode(',', $tags));
    return array('ok' => true, 'user' => $user);
}

/**
 * 更新账号(局部字段)
 */
function vpnx_user_update($name, $in)
{
    $d = vpnx_users_load();
    if (!isset($d['users'][$name])) {
        return array('ok' => false, 'error' => '账号不存在: ' . $name);
    }
    $u = $d['users'][$name];

    if (array_key_exists('expire_at', $in)) {
        $u['expire_at'] = vpnx_parse_expire($in['expire_at']);
    }
    if (array_key_exists('quota_bytes', $in)) {
        $u['quota_bytes'] = vpnx_size_to_bytes($in['quota_bytes']);
    }
    if (array_key_exists('max_devices', $in)) {
        $u['max_devices'] = (int) $in['max_devices'];
    }
    if (array_key_exists('speed_mbps', $in)) {
        $u['speed_mbps'] = (int) $in['speed_mbps'];
    }
    if (array_key_exists('note', $in)) {
        $u['note'] = (string) $in['note'];
    }
    if (array_key_exists('protocols', $in)) {
        $p = vpnx_normalize_protocols($in['protocols']);
        if (!$p) {
            return array('ok' => false, 'error' => '协议列表不能为空');
        }
        $cfg = vpnx_config();
        foreach ($p as $one) {
            if (!empty($cfg['allow_protocols']) && !in_array($one, $cfg['allow_protocols'], true)) {
                return array('ok' => false, 'error' => '协议 ' . $one . ' 不在允许列表');
            }
        }
        $u['protocols'] = $p;
        if (in_array('ss2022', $p, true) && empty($u['ss_password'])) {
            $u['ss_password'] = vpnx_ss_psk(16);
        }
    }
    if (array_key_exists('nodes', $in)) {
        $reg = vpnx_nodes_load();
        $list = is_array($in['nodes']) ? $in['nodes'] : preg_split('/[\s,]+/', (string) $in['nodes']);
        $nodes = array();
        foreach ($list as $nid) {
            $nid = strtolower(trim((string) $nid));
            if ($nid === '') {
                continue;
            }
            if (!isset($reg['nodes'][$nid])) {
                return array('ok' => false, 'error' => '节点不存在: ' . $nid);
            }
            if (!in_array($nid, $nodes, true)) {
                $nodes[] = $nid;
            }
        }
        $u['nodes'] = $nodes;
    }
    if (array_key_exists('tags', $in)) {
        $u['tags'] = vpnx_sanitize_tags($in['tags']);
    }
    if (array_key_exists('enabled', $in)) {
        $u['enabled'] = (bool) $in['enabled'];
    }
    $u['updated_at'] = vpnx_now();
    $d['users'][$name] = $u;
    vpnx_users_save($d);
    vpnx_audit('admin', 'user_update', $name);
    return array('ok' => true, 'user' => $u);
}

/**
 * 删除账号: 在曾同步过的节点上留下删除墓碑, 并让订阅立即失效
 */
function vpnx_user_delete($name)
{
    $d = vpnx_users_load();
    if (!isset($d['users'][$name])) {
        return array('ok' => false, 'error' => '账号不存在: ' . $name);
    }
    $u = $d['users'][$name];

    // 1) 给所有"该账号本该存在"的节点打墓碑(它们下次拉策略时会收到 action=delete)
    $reg = vpnx_nodes_load();
    foreach ($reg['nodes'] as $nid => $node) {
        if (vpnx_user_targets_node($u, $node)) {
            vpnx_tombstone_add($nid, $name);
        }
    }
    // 2) 订阅失效
    $subs = vpnx_subs_load();
    if (isset($u['sub_token']) && isset($subs[$u['sub_token']])) {
        unset($subs[$u['sub_token']]);
        vpnx_subs_save($subs);
    }
    // 3) 删除账号
    unset($d['users'][$name]);
    vpnx_users_save($d);
    vpnx_audit('admin', 'user_delete', $name);
    return array('ok' => true);
}

/**
 * 启用/停用账号
 */
function vpnx_user_set_enabled($name, $enabled, $reason = '')
{
    $d = vpnx_users_load();
    if (!isset($d['users'][$name])) {
        return array('ok' => false, 'error' => '账号不存在: ' . $name);
    }
    $d['users'][$name]['enabled'] = (bool) $enabled;
    $d['users'][$name]['updated_at'] = vpnx_now();
    if ($enabled) {
        unset($d['users'][$name]['disabled_reason']);
    } elseif ($reason !== '') {
        $d['users'][$name]['disabled_reason'] = $reason;
    }
    vpnx_users_save($d);
    vpnx_audit('admin', $enabled ? 'user_enable' : 'user_disable', $name . ' ' . $reason);
    return array('ok' => true);
}

/**
 * 重置账号: 换 UUID / SS 密钥, 可选清零流量
 *
 * @param bool $trafficOnly 只清零流量
 */
function vpnx_user_reset($name, $trafficOnly = false)
{
    $d = vpnx_users_load();
    if (!isset($d['users'][$name])) {
        return array('ok' => false, 'error' => '账号不存在: ' . $name);
    }
    $d['users'][$name]['used_up'] = 0;
    $d['users'][$name]['used_down'] = 0;
    if (!$trafficOnly) {
        $d['users'][$name]['uuid'] = vpnx_uuid_v4();
        if (in_array('ss2022', $d['users'][$name]['protocols'], true)) {
            $d['users'][$name]['ss_password'] = vpnx_ss_psk(16);
        }
    }
    $d['users'][$name]['updated_at'] = vpnx_now();
    vpnx_users_save($d);
    vpnx_audit('admin', $trafficOnly ? 'user_reset_traffic' : 'user_reset', $name);
    return array('ok' => true, 'user' => $d['users'][$name]);
}

/**
 * 账号是否应同步到该节点
 *
 * 规则: nodes 显式命中 -> 是; tags 命中节点标签 -> 是;
 *       nodes 与 tags 都为空 -> 视为"全部节点"(便于只用一个开关控制全网)
 */
function vpnx_user_targets_node($user, $node)
{
    $id = isset($node['id']) ? $node['id'] : '';
    $explicit = (isset($user['nodes']) && is_array($user['nodes'])) ? $user['nodes'] : array();
    $utags = (isset($user['tags']) && is_array($user['tags'])) ? $user['tags'] : array();
    if (in_array($id, $explicit, true)) {
        return true;
    }
    $ntags = (isset($node['tags']) && is_array($node['tags'])) ? $node['tags'] : array();
    foreach ($utags as $t) {
        if (in_array($t, $ntags, true)) {
            return true;
        }
    }
    if (!$explicit && !$utags) {
        return true;
    }
    return false;
}

/**
 * 解析账号实际会同步到哪些节点(只算启用中的节点)
 *
 * @return array 节点 ID 列表
 */
function vpnx_user_resolve_nodes($user)
{
    $reg = vpnx_nodes_load();
    $out = array();
    foreach ($reg['nodes'] as $nid => $node) {
        if (isset($node['enabled']) && !$node['enabled']) {
            continue;
        }
        if (vpnx_user_targets_node($user, $node)) {
            $out[] = $nid;
        }
    }
    return $out;
}

/**
 * 某节点生效的账号集合
 *
 * @return array name => user
 */
function vpnx_users_for_node($node)
{
    $d = vpnx_users_load();
    $out = array();
    foreach ($d['users'] as $name => $u) {
        if (vpnx_user_targets_node($u, $node)) {
            $out[$name] = $u;
        }
    }
    return $out;
}

/**
 * UUID 格式校验
 */
function vpnx_valid_uuid($value)
{
    return (bool) preg_match('/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/', (string) $value);
}

// ---------------------------------------------------------------------------
// 策略修订状态 / 删除墓碑
// ---------------------------------------------------------------------------
function vpnx_policy_state_load($node_id)
{
    $file = vpnx_data_dir() . DIRECTORY_SEPARATOR . 'policy_state' . DIRECTORY_SEPARATOR . $node_id . '.json';
    $st = vpnx_json_read($file, array());
    $defaults = array(
        'published_revision' => 0,
        'published_hash' => '',
        'applied_revision' => 0,
        'pending_deletes' => array(),
        'last_ack_result' => '',
        'last_error' => '',
        'published_at' => 0,
        'applied_at' => 0,
    );
    foreach ($defaults as $k => $v) {
        if (!array_key_exists($k, $st)) {
            $st[$k] = $v;
        }
    }
    return $st;
}

function vpnx_policy_state_save($node_id, $st)
{
    $dir = vpnx_data_dir() . DIRECTORY_SEPARATOR . 'policy_state';
    vpnx_mkdir($dir);
    return vpnx_json_write($dir . DIRECTORY_SEPARATOR . $node_id . '.json', $st);
}

/**
 * 记录"该账号需要从某节点删除"
 */
function vpnx_tombstone_add($node_id, $name)
{
    $st = vpnx_policy_state_load($node_id);
    if (!in_array($name, $st['pending_deletes'], true)) {
        $st['pending_deletes'][] = $name;
        vpnx_policy_state_save($node_id, $st);
    }
    return true;
}

/**
 * 取消墓碑(账号又被指派回该节点时)
 */
function vpnx_tombstone_drop($node_id, $name)
{
    $st = vpnx_policy_state_load($node_id);
    $idx = array_search($name, $st['pending_deletes'], true);
    if ($idx !== false) {
        unset($st['pending_deletes'][$idx]);
        $st['pending_deletes'] = array_values($st['pending_deletes']);
        vpnx_policy_state_save($node_id, $st);
    }
    return true;
}

/**
 * 节点 ack 成功后清掉已投递的墓碑
 */
function vpnx_tombstone_clear($node_id, $names)
{
    if (!is_array($names) || !$names) {
        return false;
    }
    $st = vpnx_policy_state_load($node_id);
    $left = array();
    foreach ($st['pending_deletes'] as $n) {
        if (!in_array($n, $names, true)) {
            $left[] = $n;
        }
    }
    $st['pending_deletes'] = $left;
    vpnx_policy_state_save($node_id, $st);
    return true;
}

// ---------------------------------------------------------------------------
// 用量
// ---------------------------------------------------------------------------
function vpnx_usage_load($node_id)
{
    $file = vpnx_data_dir() . DIRECTORY_SEPARATOR . 'usage' . DIRECTORY_SEPARATOR . $node_id . '.json';
    $d = vpnx_json_read($file, array());
    if (!isset($d['users']) || !is_array($d['users'])) {
        $d['users'] = array();
    }
    if (!isset($d['updated_at'])) {
        $d['updated_at'] = 0;
    }
    return $d;
}

function vpnx_usage_save($node_id, $d)
{
    $dir = vpnx_data_dir() . DIRECTORY_SEPARATOR . 'usage';
    vpnx_mkdir($dir);
    return vpnx_json_write($dir . DIRECTORY_SEPARATOR . $node_id . '.json', $d);
}

/**
 * 写入某节点上报的用量, 并重算各账号的跨节点总量
 *
 * 注意: 节点上报的是"该节点上的累计值", 因此这里是覆盖而不是累加;
 *       跨节点总量 = 各节点最新值之和。
 *
 * @param string $node_id
 * @param array  $rows 每项 name/up/down/online_ips/last_seen
 * @return int 更新的账号数
 */
function vpnx_usage_apply($node_id, $rows)
{
    if (!is_array($rows) || !$rows) {
        return 0;
    }
    $usage = vpnx_usage_load($node_id);
    $n = 0;
    foreach ($rows as $row) {
        $name = isset($row['name']) ? trim((string) $row['name']) : '';
        if (!vpnx_valid_name($name)) {
            continue;
        }
        $usage['users'][$name] = array(
            'up' => (int) (isset($row['up']) ? $row['up'] : 0),
            'down' => (int) (isset($row['down']) ? $row['down'] : 0),
            'online_ips' => (int) (isset($row['online_ips']) ? $row['online_ips'] : 0),
            'last_seen' => (int) (isset($row['last_seen']) ? $row['last_seen'] : vpnx_now()),
        );
        $n++;
    }
    $usage['updated_at'] = vpnx_now();
    vpnx_usage_save($node_id, $usage);

    vpnx_usage_recompute_totals();
    return $n;
}

/**
 * 汇总所有节点的用量到 users.json
 */
function vpnx_usage_recompute_totals()
{
    $dir = vpnx_data_dir() . DIRECTORY_SEPARATOR . 'usage';
    $totals = array();
    $files = glob($dir . DIRECTORY_SEPARATOR . '*.json');
    if (is_array($files)) {
        foreach ($files as $f) {
            $d = vpnx_json_read($f, array());
            if (!isset($d['users']) || !is_array($d['users'])) {
                continue;
            }
            foreach ($d['users'] as $name => $x) {
                if (!isset($totals[$name])) {
                    $totals[$name] = array('up' => 0, 'down' => 0, 'updated_at' => 0);
                }
                $totals[$name]['up'] += (int) $x['up'];
                $totals[$name]['down'] += (int) $x['down'];
                if ((int) $x['last_seen'] > $totals[$name]['updated_at']) {
                    $totals[$name]['updated_at'] = (int) $x['last_seen'];
                }
            }
        }
    }
    $d = vpnx_users_load();
    $changed = false;
    foreach ($d['users'] as $name => $u) {
        $up = isset($totals[$name]) ? $totals[$name]['up'] : 0;
        $down = isset($totals[$name]) ? $totals[$name]['down'] : 0;
        if ((int) $u['used_up'] !== $up || (int) $u['used_down'] !== $down) {
            $d['users'][$name]['used_up'] = $up;
            $d['users'][$name]['used_down'] = $down;
            $changed = true;
        }
    }
    if ($changed) {
        vpnx_users_save($d);
    }
    return $totals;
}

// ---------------------------------------------------------------------------
// 订阅
// ---------------------------------------------------------------------------
function vpnx_subs_load()
{
    // 请求内缓存: 同一个请求里可能会多次查询订阅是否已发布, 避免反复读盘
    if (isset($GLOBALS['vpnx_subs_cache'])) {
        return $GLOBALS['vpnx_subs_cache'];
    }
    $d = vpnx_json_read(vpnx_data_dir() . DIRECTORY_SEPARATOR . 'subs.json', array());
    $GLOBALS['vpnx_subs_cache'] = is_array($d) ? $d : array();
    return $GLOBALS['vpnx_subs_cache'];
}

function vpnx_subs_save($d)
{
    $GLOBALS['vpnx_subs_cache'] = $d;
    return vpnx_json_write(vpnx_data_dir() . DIRECTORY_SEPARATOR . 'subs.json', $d);
}

/**
 * 保存某节点上报的订阅内容
 *
 * @param string $node_id
 * @param array  $rows 每项 name/sub_token/links/extra/used_bytes/expire_at/quota_bytes
 * @return int 发布的账号数
 */
function vpnx_subs_publish($node_id, $rows)
{
    if (!is_array($rows)) {
        return 0;
    }
    $subs = vpnx_subs_load();
    $incoming = array();
    $n = 0;
    foreach ($rows as $r) {
        $name = isset($r['name']) ? trim((string) $r['name']) : '';
        if (!vpnx_valid_name($name)) {
            continue;
        }
        $token = isset($r['sub_token']) ? trim((string) $r['sub_token']) : '';
        if (!preg_match('/^[A-Za-z0-9_-]{8,64}$/', $token)) {
            // 节点没给 token 时派生一个稳定值, 保证同一账号跨节点一致
            $token = substr(hash('sha256', 'vpnx|' . $name), 0, 32);
        }
        $links = array();
        if (isset($r['links']) && is_array($r['links'])) {
            foreach ($r['links'] as $l) {
                $l = trim((string) $l);
                if ($l !== '') {
                    $links[] = $l;
                }
            }
        }
        $extra = (isset($r['extra']) && is_array($r['extra'])) ? $r['extra'] : array();
        if (!isset($subs[$token])) {
            $subs[$token] = array('name' => $name, 'created_at' => vpnx_now(), 'nodes' => array());
        }
        $subs[$token]['name'] = $name;
        $subs[$token]['expire_at'] = (int) (isset($r['expire_at']) ? $r['expire_at'] : 0);
        $subs[$token]['quota_bytes'] = (int) (isset($r['quota_bytes']) ? $r['quota_bytes'] : 0);
        $subs[$token]['nodes'][$node_id] = array(
            'links' => $links,
            'clash_yaml' => isset($extra['clash_yaml']) ? $extra['clash_yaml'] : '',
            'singbox_json' => isset($extra['singbox_json']) ? $extra['singbox_json'] : '',
            'meta' => isset($extra['meta']) ? $extra['meta'] : '',
            'used_bytes' => (int) (isset($r['used_bytes']) ? $r['used_bytes'] : 0),
            'updated_at' => vpnx_now(),
        );
        $subs[$token]['updated_at'] = vpnx_now();
        $incoming[$token] = true;
        $n++;
    }
    // 该节点本次没有上报的账号, 视为已从该节点移除
    foreach (array_keys($subs) as $token) {
        if (isset($subs[$token]['nodes'][$node_id]) && !isset($incoming[$token])) {
            unset($subs[$token]['nodes'][$node_id]);
            if (!$subs[$token]['nodes']) {
                unset($subs[$token]);
            }
        }
    }
    vpnx_subs_save($subs);
    return $n;
}

/**
 * 按 token 取订阅(不在库中返回 null)
 */
function vpnx_sub_get($token)
{
    if (!preg_match('/^[A-Za-z0-9_-]{8,64}$/', (string) $token)) {
        return null;
    }
    $subs = vpnx_subs_load();
    return isset($subs[$token]) ? $subs[$token] : null;
}

// ---------------------------------------------------------------------------
// nonce 去重(防重放)
// ---------------------------------------------------------------------------
/**
 * 检查并记录 nonce; 返回 true 表示是新请求, false 表示重放
 */
function vpnx_nonce_check_and_store($key, $timestamp)
{
    $file = vpnx_data_dir() . DIRECTORY_SEPARATOR . 'nonces.json';
    $d = vpnx_json_read($file, array());
    $now = vpnx_now();
    $cfg = vpnx_config();
    $window = (int) $cfg['nonce_window'];
    if ($window < 60) {
        $window = 60;
    }
    $pruned = array();
    foreach ($d as $k => $t) {
        if ($now - (int) $t <= $window) {
            $pruned[$k] = (int) $t;
        }
    }
    if (isset($pruned[$key])) {
        return false;
    }
    $pruned[$key] = $now;
    vpnx_json_write($file, $pruned);
    return true;
}

// ---------------------------------------------------------------------------
// 审计与事件
// ---------------------------------------------------------------------------
function vpnx_audit($actor, $action, $detail)
{
    $file = vpnx_data_dir() . DIRECTORY_SEPARATOR . 'audit.jsonl';
    vpnx_jsonl_append($file, array(
        'ts' => vpnx_now(),
        'time' => date('Y-m-d H:i:s'),
        'actor' => $actor,
        'ip' => vpnx_client_ip(),
        'action' => $action,
        'detail' => $detail,
    ));
}

function vpnx_audit_tail($limit)
{
    return vpnx_jsonl_tail(vpnx_data_dir() . DIRECTORY_SEPARATOR . 'audit.jsonl', $limit);
}

function vpnx_event($node_id, $level, $code, $message)
{
    $dir = vpnx_data_dir() . DIRECTORY_SEPARATOR . 'events';
    vpnx_mkdir($dir);
    $file = $dir . DIRECTORY_SEPARATOR . $node_id . '.jsonl';
    vpnx_jsonl_append($file, array(
        'ts' => vpnx_now(),
        'level' => $level,
        'code' => $code,
        'message' => $message,
    ));
    vpnx_jsonl_trim($file, 500);
}

function vpnx_events_tail($node_id, $limit)
{
    $file = vpnx_data_dir() . DIRECTORY_SEPARATOR . 'events' . DIRECTORY_SEPARATOR . $node_id . '.jsonl';
    return vpnx_jsonl_tail($file, $limit);
}

// ---------------------------------------------------------------------------
// 到期 / 配额 集中管控
// ---------------------------------------------------------------------------
/**
 * 中台侧的到期与超配额检查: 命中则停用账号, 各节点下次拉策略即收到 disable
 *
 * @param bool $force 跳过节流立即执行
 * @return array skipped / disabled(name=>reason)
 */
function vpnx_enforce($force = false)
{
    $cfg = vpnx_config();
    $stateFile = vpnx_data_dir() . DIRECTORY_SEPARATOR . '.enforce.state';
    $now = vpnx_now();
    $last = is_file($stateFile) ? (int) @file_get_contents($stateFile) : 0;
    $interval = (int) $cfg['enforce_interval'];
    if ($interval < 5) {
        $interval = 5;
    }
    if (!$force && $last > 0 && ($now - $last) < $interval) {
        return array('skipped' => true, 'disabled' => array());
    }

    $d = vpnx_users_load();
    $disabled = array();
    foreach (array_keys($d['users']) as $name) {
        $u = $d['users'][$name];
        if (empty($u['enabled'])) {
            continue;
        }
        $reason = '';
        if ((int) $u['expire_at'] > 0 && $now >= (int) $u['expire_at']) {
            $reason = 'expired';
        } elseif ((int) $u['quota_bytes'] > 0
            && ((int) $u['used_up'] + (int) $u['used_down']) >= (int) $u['quota_bytes']) {
            $reason = 'quota_exceeded';
        }
        if ($reason !== '') {
            $d['users'][$name]['enabled'] = false;
            $d['users'][$name]['disabled_reason'] = $reason;
            $d['users'][$name]['updated_at'] = $now;
            $disabled[$name] = $reason;
            vpnx_audit('system', 'user_auto_disable', $name . ' ' . $reason);
        }
    }
    if ($disabled) {
        vpnx_users_save($d);
    }
    @file_put_contents($stateFile, (string) $now);
    @chmod($stateFile, 0600);
    return array('skipped' => false, 'disabled' => $disabled);
}

/**
 * 全局统计(概览页用)
 */
function vpnx_stats()
{
    $nodes = vpnx_nodes_load();
    $users = vpnx_users_load();
    $totalUp = 0;
    $totalDown = 0;
    $enabled = 0;
    $online = 0;
    $now = vpnx_now();
    foreach ($users['users'] as $u) {
        $totalUp += (int) $u['used_up'];
        $totalDown += (int) $u['used_down'];
        if (!empty($u['enabled'])) {
            $enabled++;
        }
    }
    $nodeCount = 0;
    $nodeOnline = 0;
    foreach ($nodes['nodes'] as $n) {
        $nodeCount++;
        $seen = isset($n['runtime']['last_seen']) ? (int) $n['runtime']['last_seen'] : 0;
        if ($seen > 0 && ($now - $seen) <= 180) {
            $nodeOnline++;
        }
    }
    return array(
        'nodes' => $nodeCount,
        'nodes_online' => $nodeOnline,
        'users' => count($users['users']),
        'users_enabled' => $enabled,
        'traffic_up' => $totalUp,
        'traffic_down' => $totalDown,
        'subs' => count(vpnx_subs_load()),
    );
}
