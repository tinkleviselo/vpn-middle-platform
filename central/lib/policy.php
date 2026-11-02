<?php
/**
 * vpnx 中台 - 策略生成
 *
 * 每个节点看到的策略文档由中台按"该节点实际应该有哪些账号"实时生成:
 *   * 账号命中该节点(显式指定节点 / 标签命中 / 两者都空视为全部节点) -> action=upsert
 *   * 账号被停用(手动停用或到期/超配额自动停用)                   -> action=disable
 *   * 账号被移出该节点或整体删除                                    -> action=delete(墓碑, ack 后清除)
 *
 * 修订号(revision)是单调递增的, 由"内容指纹"驱动:
 *   指纹 = sha256( node + users + profiles + maintenance ), 不含 revision/issued_at/expires_at。
 *   指纹变化 -> revision = 上次 + 1; 指纹不变 -> revision 保持不变(节点据此跳过应用)。
 * 这样中台不需要人工维护版本号, 只要有任何影响该节点的改动, 节点下次轮询就会生效。
 */

/**
 * 节点的有效参数(中台默认值 + 该节点覆盖)
 *
 * @param array $node
 * @return array
 */
function vpnx_node_settings($node)
{
    $cfg = vpnx_config();
    $settings = isset($cfg['node_defaults']) && is_array($cfg['node_defaults'])
        ? $cfg['node_defaults'] : array();
    if (isset($node['settings']) && is_array($node['settings'])) {
        foreach ($node['settings'] as $k => $v) {
            $settings[$k] = $v;
        }
    }
    return $settings;
}

/**
 * 下发给节点的档位集合
 */
function vpnx_profiles_for_policy()
{
    $cfg = vpnx_config();
    $out = array();
    if (!isset($cfg['profiles']) || !is_array($cfg['profiles'])) {
        return $out;
    }
    foreach ($cfg['profiles'] as $name => $p) {
        if (!is_array($p) || !isset($p['type'])) {
            continue;
        }
        $out[$name] = array(
            'type' => $p['type'],
            'params' => isset($p['params']) && is_array($p['params']) ? $p['params'] : array(),
        );
    }
    return $out;
}

/**
 * 账号 -> 策略行
 */
function vpnx_policy_user_row($user)
{
    return array(
        'action' => empty($user['enabled']) ? 'disable' : 'upsert',
        'name' => $user['name'],
        'email' => '',
        'uuid' => $user['uuid'],
        'ss_password' => $user['ss_password'],
        'expire_at' => (int) $user['expire_at'],
        'quota_bytes' => (int) $user['quota_bytes'],
        'enabled' => empty($user['enabled']) ? false : true,
        'speed_mbps' => (int) $user['speed_mbps'],
        'max_devices' => (int) $user['max_devices'],
        'protocols' => $user['protocols'],
        'sub_token' => $user['sub_token'],
        'note' => isset($user['note']) ? $user['note'] : '',
    );
}

/**
 * 生成策略文档(同时维护 revision)
 *
 * @param array $node 节点记录
 * @return array 策略文档
 */
function vpnx_policy_build($node)
{
    $cfg = vpnx_config();
    $nodeId = $node['id'];
    $settings = vpnx_node_settings($node);
    $st = vpnx_policy_state_load($nodeId);

    // ---- 账号 ----
    $users = array();
    foreach (vpnx_users_for_node($node) as $name => $u) {
        $users[] = vpnx_policy_user_row($u);
    }
    // ---- 墓碑(需要在该节点上删除的账号) ----
    foreach ($st['pending_deletes'] as $name) {
        if (!vpnx_valid_name($name)) {
            continue;
        }
        $users[] = array(
            'action' => 'delete',
            'name' => $name,
            'email' => '',
            'uuid' => '',
            'ss_password' => '',
            'expire_at' => 0,
            'quota_bytes' => 0,
            'enabled' => false,
            'speed_mbps' => 0,
            'max_devices' => 0,
            'protocols' => array(),
            'sub_token' => '',
        );
    }

    // ---- 节点级参数 ----
    $nodePart = array(
        'reality_target' => isset($settings['reality_target']) ? (string) $settings['reality_target'] : '',
        // 中台推送的脚本自升级(由「节点安装」页设置; 节点比对 build/sha 后自行升级)
        'upgrade_build' => isset($node['upgrade_build']) ? (string) $node['upgrade_build'] : '',
        'upgrade_url' => isset($node['upgrade_url']) ? (string) $node['upgrade_url'] : '',
        'upgrade_sha256' => isset($node['upgrade_sha256']) ? (string) $node['upgrade_sha256'] : '',
        'reality_server_names' => isset($settings['reality_server_names']) && is_array($settings['reality_server_names'])
            ? array_values($settings['reality_server_names']) : array(),
        'ports' => (isset($settings['ports']) && is_array($settings['ports'])) ? $settings['ports'] : array(),
        'log_level' => isset($settings['log_level']) ? (string) $settings['log_level'] : 'warning',
        'bbr' => !empty($settings['bbr']),
        'allow_protocols' => isset($cfg['allow_protocols']) && is_array($cfg['allow_protocols'])
            ? array_values($cfg['allow_protocols']) : array(),
    );

    $profiles = vpnx_profiles_for_policy();
    $maintenance = isset($cfg['maintenance']) && is_array($cfg['maintenance']) ? $cfg['maintenance'] : array();

    // ---- 指纹与修订号 ----
    $fingerprintSource = array(
        'node' => $nodePart,
        'users' => $users,
        'profiles' => $profiles,
        'maintenance' => $maintenance,
    );
    $hash = hash('sha256', vpnx_json_encode($fingerprintSource));
    if ($st['published_hash'] !== $hash) {
        $st['published_revision'] = (int) $st['published_revision'] + 1;
        $st['published_hash'] = $hash;
        $st['published_at'] = vpnx_now();
        vpnx_policy_state_save($nodeId, $st);
        vpnx_log('策略更新: node=' . $nodeId . ' revision=' . $st['published_revision']
            . ' users=' . count($users));
    }

    return array(
        'revision' => (int) $st['published_revision'],
        'issued_at' => vpnx_now(),
        'expires_at' => vpnx_now() + 3600,
        'node' => $nodePart,
        'users' => $users,
        'profiles' => $profiles,
        'maintenance' => $maintenance,
    );
}

/**
 * 策略文档 -> format=lines 文本(节点侧无 jq/python 时使用)
 */
function vpnx_policy_lines($doc)
{
    return vpnx_to_lines($doc);
}

/**
 * 节点拉取策略时的"是否需要更新"判断
 *
 * @param array $node
 * @param int   $currentRevision 节点当前已应用的 revision(-1 表示强制全量)
 * @return array array(unchanged=>bool, revision=>int, doc=>array|null)
 */
function vpnx_policy_for_request($node, $currentRevision)
{
    $doc = vpnx_policy_build($node);
    if ($currentRevision >= 0 && $currentRevision === (int) $doc['revision']) {
        return array('unchanged' => true, 'revision' => (int) $doc['revision'], 'doc' => null);
    }
    return array('unchanged' => false, 'revision' => (int) $doc['revision'], 'doc' => $doc);
}

/**
 * 记录节点 ack, 并清理已投递的墓碑
 *
 * @param string $node_id
 * @param int    $revision 节点回报的 revision
 * @param string $result   applied | failed
 * @param string $error
 * @return array
 */
function vpnx_policy_ack($node_id, $revision, $result, $error)
{
    $st = vpnx_policy_state_load($node_id);
    $st['last_ack_result'] = (string) $result;
    $st['last_error'] = (string) $error;
    if ($result === 'applied') {
        $applied = (int) $revision;
        if ($applied > (int) $st['applied_revision']) {
            $st['applied_revision'] = $applied;
            $st['applied_at'] = vpnx_now();
        }
        // 已成功应用的 revision 覆盖到的墓碑可以清掉:
        // 简化处理 —— applied_revision >= published_revision 时认为墓碑已投递完毕
        if ((int) $st['applied_revision'] >= (int) $st['published_revision'] && $st['pending_deletes']) {
            $st['pending_deletes'] = array();
        }
    }
    vpnx_policy_state_save($node_id, $st);
    return $st;
}
