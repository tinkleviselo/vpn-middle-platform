<?php
/**
 * vpnx 中台 - 展示层数据组装
 *
 * 这些函数把 store 里的原始数据整理成"接口/页面直接可用"的形状:
 *   * vpnx_admin_nodes_list()  节点列表(在线状态、策略进度、接入命令)
 *   * vpnx_admin_user_view()   单个账号视图(目标节点、订阅地址、用量可读化)
 *   * vpnx_admin_users_list()  账号列表(可按节点过滤)
 *   * vpnx_admin_subs_list()   订阅清单
 *   * vpnx_onboard_command() / vpnx_install_command()  节点接入命令
 *
 * api.php(机器接口)与 index.php(管理后台)共用本文件, 因此这里只做数据组装,
 * 不要 echo/header 之类的输出。
 */

/**
 * 把节点上报的入站列表整理成 "协议:端口" 文本, 便于后台一眼看到要放行哪些端口
 *
 * @param array $inbounds 形如 [{'protocol','port','network','enabled'}...]
 * @return string
 */
function vpnx_ports_text($inbounds)
{
    if (!is_array($inbounds) || !$inbounds) {
        return '-';
    }
    $out = array();
    $protoName = array(
        'vless-reality' => 'REALITY', 'reality' => 'REALITY',
        'ss2022' => 'SS2022', 'ss' => 'SS2022',
        'vmess-ws' => 'VMess', 'vmess' => 'VMess',
        'vless-xhttp' => 'XHTTP', 'xhttp' => 'XHTTP',
    );
    foreach ($inbounds as $ib) {
        if (!is_array($ib) || !isset($ib['port'])) {
            continue;
        }
        $p = isset($ib['protocol']) ? (string) $ib['protocol'] : '';
        $label = isset($protoName[$p]) ? $protoName[$p] : $p;
        $flag = (array_key_exists('enabled', $ib) && !$ib['enabled']) ? '(停)' : '';
        $out[] = $label . ':' . (int) $ib['port'] . $flag;
    }
    return $out ? implode('  ', $out) : '-';
}

/**
 * 节点列表视图
 *
 * @return array
 */
function vpnx_admin_nodes_list()
{
    $reg = vpnx_nodes_load();
    $out = array();
    foreach ($reg['nodes'] as $id => $n) {
        $st = vpnx_policy_state_load($id);
        $rt = (isset($n['runtime']) && is_array($n['runtime'])) ? $n['runtime'] : array();
        $seen = isset($rt['last_seen']) ? (int) $rt['last_seen'] : 0;
        $out[] = array(
            'id' => $id,
            'name' => isset($n['name']) ? $n['name'] : $id,
            'ip' => isset($n['ip']) ? $n['ip'] : '',
            'tags' => isset($n['tags']) ? $n['tags'] : array(),
            'settings' => isset($n['settings']) ? $n['settings'] : array(),
            'enabled' => empty($n['enabled']) ? false : true,
            'online' => ($seen > 0 && (vpnx_now() - $seen) <= 180),
            'last_seen' => $seen,
            'build' => isset($rt['build']) ? (string) $rt['build'] : '',
            'last_ip' => isset($rt['last_ip']) ? $rt['last_ip'] : '',
            'xray_version' => isset($rt['xray_version']) ? $rt['xray_version'] : '',
            'os' => isset($rt['os']) ? $rt['os'] : '',
            'users_total' => isset($rt['users_total']) ? (int) $rt['users_total'] : 0,
            'traffic_total_bytes' => isset($rt['traffic_total_bytes']) ? (int) $rt['traffic_total_bytes'] : 0,
            'health' => isset($rt['health']) ? $rt['health'] : array(),
            'inbounds' => isset($rt['inbounds']) ? $rt['inbounds'] : array(),
            'ports_text' => vpnx_ports_text(isset($rt['inbounds']) ? $rt['inbounds'] : array()),
            'users' => count(vpnx_users_for_node($n)),
            'policy' => array(
                'published_revision' => (int) $st['published_revision'],
                'applied_revision' => (int) $st['applied_revision'],
                'pending' => ((int) $st['applied_revision'] < (int) $st['published_revision']),
                'pending_deletes' => count($st['pending_deletes']),
                'last_ack_result' => $st['last_ack_result'],
                'last_error' => $st['last_error'],
                'published_at' => (int) $st['published_at'],
                'applied_at' => (int) $st['applied_at'],
            ),
            'onboard_command' => vpnx_onboard_command($n),
            'install_command' => vpnx_install_command($n),
            'update_command' => vpnx_update_command($n),
        );
    }
    return $out;
}

/**
 * 账号视图
 *
 * @param array $user
 * @return array
 */
function vpnx_admin_user_view($user)
{
    $nodes = vpnx_user_resolve_nodes($user);
    $used = (int) $user['used_up'] + (int) $user['used_down'];
    return array(
        'name' => $user['name'],
        'uuid' => $user['uuid'],
        'ss_password' => $user['ss_password'],
        'sub_token' => $user['sub_token'],
        'sub_url' => vpnx_machine_url('/sub/' . $user['sub_token']),
        'legacy_url' => vpnx_machine_url('/sub/' . $user['sub_token'] . '/clash-legacy'),
        'xhttp_url' => vpnx_machine_url('/sub/' . $user['sub_token'] . '/clash-xhttp'),
        'sub_published' => (vpnx_sub_get($user['sub_token']) !== null),
        'enabled' => empty($user['enabled']) ? false : true,
        'disabled_reason' => isset($user['disabled_reason']) ? $user['disabled_reason'] : '',
        'expire_at' => (int) $user['expire_at'],
        'expire_text' => vpnx_fmt_expire($user['expire_at']),
        'quota_bytes' => (int) $user['quota_bytes'],
        'used_up' => (int) $user['used_up'],
        'used_down' => (int) $user['used_down'],
        'used_bytes' => $used,
        'used_text' => vpnx_fmt_bytes($used),
        'quota_text' => ((int) $user['quota_bytes'] > 0) ? vpnx_fmt_bytes($user['quota_bytes']) : '不限',
        'max_devices' => (int) $user['max_devices'],
        'speed_mbps' => (int) $user['speed_mbps'],
        'protocols' => $user['protocols'],
        'nodes' => isset($user['nodes']) ? $user['nodes'] : array(),
        'tags' => isset($user['tags']) ? $user['tags'] : array(),
        'nodes_resolved' => $nodes,
        'note' => isset($user['note']) ? $user['note'] : '',
        'created_at' => (int) $user['created_at'],
        'updated_at' => (int) $user['updated_at'],
    );
}

/**
 * 账号列表($nodeFilter 非空时只列该节点上的账号)
 *
 * @param string $nodeFilter
 * @return array
 */
function vpnx_admin_users_list($nodeFilter = '')
{
    $d = vpnx_users_load();
    $out = array();
    $node = ($nodeFilter !== '') ? vpnx_node_get($nodeFilter) : null;
    foreach ($d['users'] as $name => $u) {
        if ($node !== null && !vpnx_user_targets_node($u, $node)) {
            continue;
        }
        $out[] = vpnx_admin_user_view($u);
    }
    return $out;
}

/**
 * 订阅清单
 *
 * @return array
 */
function vpnx_admin_subs_list()
{
    $subs = vpnx_subs_load();
    $out = array();
    foreach ($subs as $token => $entry) {
        $links = 0;
        $nodes = array();
        if (isset($entry['nodes']) && is_array($entry['nodes'])) {
            foreach ($entry['nodes'] as $nid => $x) {
                $nodes[] = $nid;
                $links += isset($x['links']) ? count($x['links']) : 0;
            }
        }
        $subUrl = vpnx_machine_url('/sub/' . $token);
        $out[] = array(
            'token' => $token,
            'name' => isset($entry['name']) ? $entry['name'] : '',
            'nodes' => $nodes,
            'links' => $links,
            'updated_at' => isset($entry['updated_at']) ? (int) $entry['updated_at'] : 0,
            'url' => $subUrl,
            'clash_url' => vpnx_machine_url('/sub/' . $token . '/clash'),
            'singbox_url' => vpnx_machine_url('/sub/' . $token . '/singbox'),
            'raw_url' => vpnx_url_add_query($subUrl, 'target=raw'),
            'legacy_url' => vpnx_machine_url('/sub/' . $token . '/clash-legacy'),
            'xhttp_url' => vpnx_machine_url('/sub/' . $token . '/clash-xhttp'),
        );
    }
    return $out;
}

/**
 * 节点接入命令(脚本已在服务器上时执行)
 *
 * @param array $node
 * @return string
 */
function vpnx_onboard_command($node)
{
    return 'vpnx agent set --url ' . vpnx_api_base()
        . ' --node-id ' . $node['id']
        . ' --token ' . $node['secret']
        . ' && vpnx agent install && vpnx agent test';
}

/**
 * 完整安装命令(全新服务器一条命令接入)
 *
 * @param array $node
 * @return string
 */
function vpnx_install_command($node)
{
    // 中台有节点包时, 直接给出"下载 + 解压 + 安装"的一条命令(节点上无需任何前置文件)
    if (function_exists('vpnx_dist_default_name')) {
        $pkg = vpnx_dist_default_name();
        if ($pkg !== '') {
            return vpnx_dist_command($node, 'install', $pkg, 'reality,ss2022,vmess-ws,xhttp');
        }
    }
    return 'bash vpnx.sh install --profiles reality,ss2022,vmess-ws,xhttp --central-url ' . vpnx_api_base()
        . ' --node-id ' . $node['id']
        . ' --token ' . $node['secret'];
}

/**
 * 已装过节点的"只更新脚本"命令(幂等: 覆盖 vpnx.sh 与 lib/tools/tests, 不影响运行中的内核)
 *
 * @param array $node
 * @return string
 */
function vpnx_update_command($node)
{
    if (function_exists('vpnx_dist_default_name')) {
        $pkg = vpnx_dist_default_name();
        if ($pkg !== '') {
            return vpnx_dist_command($node, 'update', $pkg, '');
        }
    }
    return 'vpnx upgrade   # 或把 vpnx.sh 与 lib/ 覆盖到 /usr/local/vpnx/ 后 vpnx version 确认';
}
