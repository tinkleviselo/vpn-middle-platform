<?php
/**
 * vpnx 中台 - 机器接口入口(PHP + JSON, 无数据库)
 *
 * 路由一览:
 *   订阅(无需鉴权, token 即凭证)
 *     GET  /sub/<token>                     Base64 链接列表
 *     GET  /sub/<token>?target=raw|clash|singbox
 *     GET  /sub/<token>/clash | /singbox
 *   节点接口(节点 HMAC 签名)
 *     POST /api/v1/node/heartbeat           心跳, 返回策略版本与是否需要拉取
 *     GET  /api/v1/node/policy              拉策略(支持 format=lines)
 *     POST /api/v1/node/report              上报用量/事件/策略 ack
 *     POST /api/v1/node/subscription        推送各账号订阅内容
 *     POST /api/v1/node/script/update       脚本版本查询
 *   管理接口(Bearer token)
 *     GET  /api/v1/admin/health             健康检查(无需鉴权)
 *     GET  /api/v1/admin/stats              汇总统计
 *     GET  /api/v1/admin/nodes              节点列表(含在线状态/策略进度/接入命令)
 *     POST /api/v1/admin/nodes              注册节点, 返回一次性 secret
 *     GET|PUT|DELETE /api/v1/admin/nodes/<id>
 *     POST /api/v1/admin/nodes/<id>/rotate  轮换密钥
 *     GET  /api/v1/admin/nodes/<id>/policy  查看该节点将要收到的策略
 *     PUT  /api/v1/admin/nodes/<id>/policy  声明式下发(节点参数 + 账号增删改)
 *     GET  /api/v1/admin/nodes/<id>/usage   该节点用量明细
 *     GET  /api/v1/admin/nodes/<id>/commands 上线命令
 *     GET|POST /api/v1/admin/users          账号列表 / 新建账号
 *     GET|PUT|DELETE /api/v1/admin/users/<name>
 *     POST /api/v1/admin/users/<name>/reset|enable|disable|nodes
 *     GET  /api/v1/admin/subscriptions      订阅清单
 *     POST /api/v1/admin/enforce            立即执行到期/配额检查
 *     GET  /api/v1/admin/audit              审计日志
 */

require_once __DIR__ . '/lib/util.php';
require_once __DIR__ . '/lib/config.php';
require_once __DIR__ . '/lib/store.php';
require_once __DIR__ . '/lib/auth.php';
require_once __DIR__ . '/lib/policy.php';
require_once __DIR__ . '/lib/sub.php';
require_once __DIR__ . '/lib/views.php';

vpnx_bootstrap();

$method = vpnx_request_method();
$path   = vpnx_app_path();

// ---------------------------------------------------------------------------
// 订阅(公开)
// ---------------------------------------------------------------------------
if ($path === '/sub' || strpos($path, '/sub/') === 0) {
    vpnx_handle_sub($path);
    exit;
}

// ---------------------------------------------------------------------------
// 根路径 / 直接访问 api.php: 部署自检
// (方式 A 的路径是 /vpnx/api.php; 方式 B 是 /vpnx/ 或 /vpnx/api.php)
// ---------------------------------------------------------------------------
if ($path === '/' || preg_match('#(^|/)(api|index)\.php$#', $path)) {
    $cfg = vpnx_config();
    vpnx_json_out(200, array(
        'ok' => true,
        'service' => 'vpnx central (php)',
        'version' => isset($cfg['version']) ? $cfg['version'] : VPNX_CENTRAL_VERSION,
        'php_version' => PHP_VERSION,
        'time' => vpnx_now(),
        'admin_ui' => 'index.php',
        'hint' => '机器接口在 /api/v1/node/* 与 /api/v1/admin/*; 订阅在 /sub/<token>',
    ));
    exit;
}

// ---------------------------------------------------------------------------
// 节点接口
// ---------------------------------------------------------------------------
if (strpos($path, '/api/v1/node/') === 0) {
    $body = vpnx_read_body();
    $auth = vpnx_node_authenticate($method, $body);
    $nodeId = $auth[0];
    $authErr = $auth[1];
    if ($nodeId === null) {
        vpnx_log('节点鉴权失败 method=' . $method . ' path=' . $path . ' err=' . $authErr);
        vpnx_error_out(401, 'unauthorized');
    }
    vpnx_handle_node($nodeId, $method, $path, $body);
    vpnx_error_out(404, 'not found');
    exit;
}

// ---------------------------------------------------------------------------
// 管理接口
// ---------------------------------------------------------------------------
if (strpos($path, '/api/v1/admin/') === 0) {
    $cfg = vpnx_config();
    if ($path === '/api/v1/admin/health' && ($method === 'GET' || $method === 'HEAD')) {
        $s = vpnx_stats();
        vpnx_json_out(200, array(
            'ok' => true,
            'nodes' => $s['nodes'],
            'nodes_online' => $s['nodes_online'],
            'users' => $s['users'],
            'subs' => $s['subs'],
            'version' => isset($cfg['version']) ? $cfg['version'] : VPNX_CENTRAL_VERSION,
        ));
    }
    if (!vpnx_admin_api_auth()) {
        vpnx_log('管理接口鉴权失败 method=' . $method . ' path=' . $path . ' ip=' . vpnx_client_ip());
        vpnx_error_out(401, 'unauthorized');
    }
    vpnx_handle_admin($method, $path);
    vpnx_error_out(404, 'not found');
    exit;
}

vpnx_error_out(404, 'not found');

// ===========================================================================
// 节点接口实现
// ===========================================================================
/**
 * 处理节点请求
 *
 * 注意: 全程持有全局写锁(进程退出时自动释放), 因此不会与后台管理操作交叉写坏数据。
 *
 * @param string $nodeId
 * @param string $method
 * @param string $path
 * @param string $body
 */
function vpnx_handle_node($nodeId, $method, $path, $body)
{
    $lock = vpnx_lock();
    $node = vpnx_node_get($nodeId);
    if ($node === null) {
        vpnx_error_out(401, 'unauthorized');
    }

    // 每次节点交互顺手做一次到期/配额检查(内部有节流)
    vpnx_enforce(false);

    $in = json_decode($body, true);
    if (!is_array($in)) {
        $in = array();
    }

    // ---- 心跳 ----
    if ($path === '/api/v1/node/heartbeat' && $method === 'POST') {
        vpnx_node_touch($nodeId, array(
            'xray_version' => isset($in['xray_version']) ? (string) $in['xray_version'] : '',
            'os' => isset($in['os']) ? (string) $in['os'] : '',
            'kernel' => isset($in['kernel']) ? (string) $in['kernel'] : '',
            'arch' => isset($in['arch']) ? (string) $in['arch'] : '',
            'agent_version' => isset($in['agent_version']) ? (string) $in['agent_version'] : '',
            'build' => isset($in['build']) ? (string) $in['build'] : '',
            'public_ip' => isset($in['public_ip']) ? (string) $in['public_ip'] : '',
            'uptime_sec' => isset($in['uptime_sec']) ? (int) $in['uptime_sec'] : 0,
            'users_total' => isset($in['users_total']) ? (int) $in['users_total'] : 0,
            'users_active' => isset($in['users_active']) ? (int) $in['users_active'] : 0,
            'traffic_total_bytes' => isset($in['traffic_total_bytes']) ? (int) $in['traffic_total_bytes'] : 0,
            'health' => (isset($in['health']) && is_array($in['health'])) ? $in['health'] : array(),
            'inbounds' => (isset($in['inbounds']) && is_array($in['inbounds'])) ? $in['inbounds'] : array(),
        ));

        // 节点上报的 applied_policy_revision 单调不回退写入
        if (isset($in['applied_policy_revision'])) {
            $applied = (int) $in['applied_policy_revision'];
            $st = vpnx_policy_state_load($nodeId);
            if ($applied > (int) $st['applied_revision']) {
                $st['applied_revision'] = $applied;
                $st['applied_at'] = vpnx_now();
                vpnx_policy_state_save($nodeId, $st);
            }
        }

        // 关键: 心跳时必须重新计算"该节点当前应有的策略"指纹并推进 revision。
        // 否则新注册的节点会一直看到 revision=0 / pending=false, 永远不去拉策略,
        // 表现为"账号建不出来、订阅也推不上来"。
        vpnx_policy_build($node);

        $st = vpnx_policy_state_load($nodeId);
        $pending = ((int) $st['applied_revision'] < (int) $st['published_revision']);
        vpnx_json_out(200, array(
            'ok' => true,
            'server_time' => vpnx_now(),
            'policy_revision' => (int) $st['published_revision'],
            'policy_pending' => $pending,
            'next_interval_sec' => 60,
        ));
    }

    // ---- 拉策略 ----
    if ($path === '/api/v1/node/policy' && ($method === 'GET' || $method === 'HEAD')) {
        $current = -1; // 默认强制全量
        if (isset($_GET['current_revision']) && $_GET['current_revision'] !== '') {
            $current = (int) $_GET['current_revision'];
        }
        $res = vpnx_policy_for_request($node, $current);
        $lines = vpnx_wants_lines();
        if (!empty($res['unchanged'])) {
            if ($lines) {
                vpnx_text_out(200, "ok=true\nunchanged=true\nrevision=" . (int) $res['revision'] . "\n");
            }
            vpnx_json_out(200, array('ok' => true, 'unchanged' => true, 'revision' => (int) $res['revision']));
        }
        if ($lines) {
            vpnx_text_out(200, "ok=true\n" . vpnx_policy_lines($res['doc']));
        }
        $out = $res['doc'];
        $out['ok'] = true;
        vpnx_json_out(200, $out);
    }

    // ---- 上报(用量/事件/ack) ----
    if ($path === '/api/v1/node/report' && $method === 'POST') {
        $usageApplied = 0;
        if (isset($in['usage']) && is_array($in['usage'])) {
            $usageApplied = vpnx_usage_apply($nodeId, $in['usage']);
        }
        if (isset($in['events']) && is_array($in['events'])) {
            foreach ($in['events'] as $ev) {
                if (!is_array($ev)) {
                    continue;
                }
                vpnx_event(
                    $nodeId,
                    isset($ev['level']) ? (string) $ev['level'] : 'INFO',
                    isset($ev['code']) ? (string) $ev['code'] : 'generic',
                    isset($ev['message']) ? (string) $ev['message'] : ''
                );
            }
        }
        if (isset($in['ack']) && is_array($in['ack'])) {
            $result = isset($in['ack']['result']) ? (string) $in['ack']['result'] : '';
            if ($result !== '') {
                vpnx_policy_ack(
                    $nodeId,
                    isset($in['ack']['policy_revision']) ? (int) $in['ack']['policy_revision'] : 0,
                    $result,
                    isset($in['ack']['error']) ? (string) $in['ack']['error'] : ''
                );
            }
        }
        // 用量刚更新, 立刻做一次到期/配额判断
        vpnx_enforce(true);

        if (vpnx_wants_lines()) {
            vpnx_text_out(200, "ok=true\nusage_applied=" . $usageApplied . "\n");
        }
        vpnx_json_out(200, array('ok' => true, 'usage_applied' => $usageApplied));
    }

    // ---- 推送订阅 ----
    if ($path === '/api/v1/node/subscription' && $method === 'POST') {
        $rows = (isset($in['users']) && is_array($in['users'])) ? $in['users'] : array();
        $published = vpnx_subs_publish($nodeId, $rows);
        vpnx_json_out(200, array(
            'ok' => true,
            'published' => $published,
            'sub_base' => vpnx_api_base(),
            'sub_mode' => (substr(vpnx_api_base(), -4) === '.php') ? 'query' : 'path',
        ));
    }

    // ---- 脚本版本查询 ----
    if ($path === '/api/v1/node/script/update' && $method === 'POST') {
        $cfg = vpnx_config();
        vpnx_json_out(200, array(
            'ok' => true,
            'update_available' => false,
            'script_version' => isset($cfg['version']) ? $cfg['version'] : VPNX_CENTRAL_VERSION,
            'url' => '',
            'sha256' => '',
        ));
    }

    return;
}

/**
 * 是否要求 format=lines(节点侧没有 jq/python 时使用)
 */
function vpnx_wants_lines()
{
    if (isset($_GET['format']) && strtolower(trim($_GET['format'])) === 'lines') {
        return true;
    }
    $accept = isset($_SERVER['HTTP_ACCEPT']) ? strtolower($_SERVER['HTTP_ACCEPT']) : '';
    return (strpos($accept, 'text/plain') !== false);
}

// ===========================================================================
// 管理接口实现
// ===========================================================================
function vpnx_handle_admin($method, $path)
{
    $lock = vpnx_lock();
    $body = vpnx_read_json_body();

    // ---------------- 统计 / 强制检查 / 审计 ----------------
    if ($path === '/api/v1/admin/stats' && $method === 'GET') {
        vpnx_json_out(200, array('ok' => true, 'stats' => vpnx_stats()));
    }

    if ($path === '/api/v1/admin/enforce' && $method === 'POST') {
        $r = vpnx_enforce(true);
        vpnx_json_out(200, array('ok' => true, 'disabled' => $r['disabled']));
    }

    if ($path === '/api/v1/admin/audit' && $method === 'GET') {
        $limit = isset($_GET['limit']) ? (int) $_GET['limit'] : 100;
        if ($limit < 1 || $limit > 1000) {
            $limit = 100;
        }
        vpnx_json_out(200, array('ok' => true, 'items' => vpnx_audit_tail($limit)));
    }

    // ---------------- 节点集合 ----------------
    if ($path === '/api/v1/admin/nodes') {
        if ($method === 'GET') {
            vpnx_json_out(200, array('ok' => true, 'nodes' => vpnx_admin_nodes_list()));
        }
        if ($method === 'POST') {
            $id = '';
            if (isset($body['node_id'])) {
                $id = $body['node_id'];
            } elseif (isset($body['id'])) {
                $id = $body['id'];
            }
            $r = vpnx_node_add(
                $id,
                isset($body['name']) ? $body['name'] : '',
                isset($body['ip']) ? $body['ip'] : '',
                isset($body['tags']) ? $body['tags'] : array(),
                (isset($body['settings']) && is_array($body['settings'])) ? $body['settings'] : array()
            );
            if (empty($r['ok'])) {
                vpnx_error_out(400, $r['error']);
            }
            $node = $r['node'];
            vpnx_json_out(201, array(
                'ok' => true,
                'node' => $node,
                'secret' => $r['secret'],
                'onboard_command' => vpnx_onboard_command($node),
                'install_command' => vpnx_install_command($node),
            ));
        }
        vpnx_error_out(405, 'method not allowed');
    }

    // ---------------- 单个节点 ----------------
    if (preg_match('#^/api/v1/admin/nodes/([A-Za-z0-9._-]{1,64})$#', $path, $m)) {
        $id = $m[1];
        $node = vpnx_node_get($id);
        if ($node === null) {
            vpnx_error_out(404, 'node not found');
        }
        if ($method === 'GET') {
            $list = vpnx_admin_nodes_list();
            foreach ($list as $item) {
                if ($item['id'] === $id) {
                    $item['secret'] = $node['secret'];
                    vpnx_json_out(200, array('ok' => true, 'node' => $item));
                }
            }
            vpnx_error_out(404, 'node not found');
        }
        if ($method === 'PUT' || $method === 'PATCH' || $method === 'POST') {
            $r = vpnx_node_update($id, $body);
            if (empty($r['ok'])) {
                vpnx_error_out(400, $r['error']);
            }
            vpnx_json_out(200, array('ok' => true, 'node' => $r['node']));
        }
        if ($method === 'DELETE') {
            $r = vpnx_node_delete($id);
            if (empty($r['ok'])) {
                vpnx_error_out(404, $r['error']);
            }
            vpnx_json_out(200, array('ok' => true));
        }
        vpnx_error_out(405, 'method not allowed');
    }

    // ---------------- 轮换密钥 ----------------
    if (preg_match('#^/api/v1/admin/nodes/([A-Za-z0-9._-]{1,64})/rotate$#', $path, $m) && $method === 'POST') {
        $r = vpnx_node_rotate($m[1]);
        if (empty($r['ok'])) {
            vpnx_error_out(404, $r['error']);
        }
        $node = vpnx_node_get($m[1]);
        vpnx_json_out(200, array(
            'ok' => true,
            'secret' => $r['secret'],
            'onboard_command' => vpnx_onboard_command($node),
        ));
    }

    // ---------------- 策略查看 / 声明式下发 ----------------
    if (preg_match('#^/api/v1/admin/nodes/([A-Za-z0-9._-]{1,64})/policy$#', $path, $m)) {
        $node = vpnx_node_get($m[1]);
        if ($node === null) {
            vpnx_error_out(404, 'node not found');
        }
        if ($method === 'GET') {
            $doc = vpnx_policy_build($node);
            if (vpnx_wants_lines()) {
                vpnx_text_out(200, vpnx_policy_lines($doc));
            }
            $doc['ok'] = true;
            vpnx_json_out(200, $doc);
        }
        if ($method === 'PUT' || $method === 'POST') {
            $r = vpnx_admin_apply_policy_doc($m[1], $body);
            if (empty($r['ok'])) {
                vpnx_error_out(400, $r['error']);
            }
            vpnx_json_out(200, $r);
        }
        vpnx_error_out(405, 'method not allowed');
    }

    // ---------------- 节点用量 / 上线命令 ----------------
    if (preg_match('#^/api/v1/admin/nodes/([A-Za-z0-9._-]{1,64})/usage$#', $path, $m) && $method === 'GET') {
        if (vpnx_node_get($m[1]) === null) {
            vpnx_error_out(404, 'node not found');
        }
        vpnx_json_out(200, array(
            'ok' => true,
            'node_id' => $m[1],
            'usage' => vpnx_usage_load($m[1]),
            'events' => vpnx_events_tail($m[1], 50),
        ));
    }

    if (preg_match('#^/api/v1/admin/nodes/([A-Za-z0-9._-]{1,64})/commands$#', $path, $m) && $method === 'GET') {
        $node = vpnx_node_get($m[1]);
        if ($node === null) {
            vpnx_error_out(404, 'node not found');
        }
        vpnx_json_out(200, array(
            'ok' => true,
            'install_command' => vpnx_install_command($node),
            'onboard_command' => vpnx_onboard_command($node),
        ));
    }

    // ---------------- 账号集合 ----------------
    if ($path === '/api/v1/admin/users') {
        if ($method === 'GET') {
            $nodeFilter = isset($_GET['node']) ? (string) $_GET['node'] : '';
            vpnx_json_out(200, array('ok' => true, 'users' => vpnx_admin_users_list($nodeFilter)));
        }
        if ($method === 'POST') {
            $r = vpnx_user_add($body);
            if (empty($r['ok'])) {
                vpnx_error_out(400, $r['error']);
            }
            vpnx_json_out(201, array('ok' => true, 'user' => vpnx_admin_user_view($r['user'])));
        }
        vpnx_error_out(405, 'method not allowed');
    }

    // ---------------- 单个账号 ----------------
    if (preg_match('#^/api/v1/admin/users/([A-Za-z0-9._-]{1,64})$#', $path, $m)) {
        $name = $m[1];
        $user = vpnx_user_get($name);
        if ($user === null) {
            vpnx_error_out(404, 'user not found');
        }
        if ($method === 'GET') {
            vpnx_json_out(200, array('ok' => true, 'user' => vpnx_admin_user_view($user)));
        }
        if ($method === 'PUT' || $method === 'PATCH' || $method === 'POST') {
            $r = vpnx_user_update($name, $body);
            if (empty($r['ok'])) {
                vpnx_error_out(400, $r['error']);
            }
            vpnx_json_out(200, array('ok' => true, 'user' => vpnx_admin_user_view($r['user'])));
        }
        if ($method === 'DELETE') {
            $r = vpnx_user_delete($name);
            if (empty($r['ok'])) {
                vpnx_error_out(404, $r['error']);
            }
            vpnx_json_out(200, array('ok' => true));
        }
        vpnx_error_out(405, 'method not allowed');
    }

    // ---------------- 账号动作 ----------------
    if (preg_match('#^/api/v1/admin/users/([A-Za-z0-9._-]{1,64})/(reset|enable|disable|nodes)$#', $path, $m)) {
        $name = $m[1];
        $action = $m[2];
        if (vpnx_user_get($name) === null) {
            vpnx_error_out(404, 'user not found');
        }
        if ($method !== 'POST' && $method !== 'PUT') {
            vpnx_error_out(405, 'method not allowed');
        }
        if ($action === 'reset') {
            $r = vpnx_user_reset($name, !empty($body['traffic_only']));
        } elseif ($action === 'enable') {
            $r = vpnx_user_set_enabled($name, true);
        } elseif ($action === 'disable') {
            $r = vpnx_user_set_enabled($name, false, isset($body['reason']) ? $body['reason'] : 'manual');
        } else {
            $patch = array();
            if (array_key_exists('nodes', $body)) {
                $patch['nodes'] = $body['nodes'];
            }
            if (array_key_exists('tags', $body)) {
                $patch['tags'] = $body['tags'];
            }
            $r = vpnx_user_update($name, $patch);
        }
        if (empty($r['ok'])) {
            vpnx_error_out(400, $r['error']);
        }
        vpnx_json_out(200, array('ok' => true, 'user' => vpnx_admin_user_view(vpnx_user_get($name))));
    }

    // ---------------- 订阅清单 ----------------
    if ($path === '/api/v1/admin/subscriptions' && $method === 'GET') {
        vpnx_json_out(200, array('ok' => true, 'subscriptions' => vpnx_admin_subs_list()));
    }

    vpnx_error_out(404, 'not found');
}


/**
 * 声明式下发策略文档(管理端脚本用)
 *
 * 语义:
 *   node.*      合并进该节点的 settings(reality_target / reality_server_names / ports / log_level / bbr)
 *   profiles.*  合并进中台档位配置(会带给所有节点)
 *   users[]     逐条应用到账号表:
 *                 action=upsert  新建或更新, 并把该节点加入其 nodes 列表
 *                 action=disable 停用该账号(全网生效)
 *                 action=delete  从该节点移除(留删除墓碑)
 *
 * @param string $node_id
 * @param array  $doc
 * @return array ok / error / revision / applied
 */
function vpnx_admin_apply_policy_doc($node_id, $doc)
{
    $node = vpnx_node_get($node_id);
    if ($node === null) {
        return array('ok' => false, 'error' => 'node not found');
    }
    $applied = array('node' => false, 'profiles' => array(), 'users' => array());

    // ---- 节点参数 ----
    if (isset($doc['node']) && is_array($doc['node'])) {
        $patch = array();
        foreach (array('reality_target', 'reality_server_names', 'ports', 'log_level', 'bbr') as $k) {
            if (array_key_exists($k, $doc['node'])) {
                $patch[$k] = $doc['node'][$k];
            }
        }
        if ($patch) {
            $r = vpnx_node_update($node_id, array('settings' => $patch));
            $applied['node'] = !empty($r['ok']);
        }
    }

    // ---- 档位 ----
    if (isset($doc['profiles']) && is_array($doc['profiles'])) {
        $cfg = vpnx_config();
        foreach ($doc['profiles'] as $pname => $p) {
            if (!vpnx_valid_component($pname) || !is_array($p) || !isset($p['type'])) {
                continue;
            }
            if (!isset($cfg['profiles'][$pname]) || !is_array($cfg['profiles'][$pname])) {
                $cfg['profiles'][$pname] = array();
            }
            $cfg['profiles'][$pname]['type'] = $p['type'];
            if (isset($p['params']) && is_array($p['params'])) {
                if (!isset($cfg['profiles'][$pname]['params']) || !is_array($cfg['profiles'][$pname]['params'])) {
                    $cfg['profiles'][$pname]['params'] = array();
                }
                foreach ($p['params'] as $pk => $pv) {
                    $cfg['profiles'][$pname]['params'][$pk] = $pv;
                }
            }
            $applied['profiles'][] = $pname;
        }
        vpnx_config_save($cfg);
    }

    // ---- 账号 ----
    if (isset($doc['users']) && is_array($doc['users'])) {
        foreach ($doc['users'] as $row) {
            if (!is_array($row)) {
                continue;
            }
            $name = isset($row['name']) ? trim((string) $row['name']) : '';
            if (!vpnx_valid_name($name)) {
                continue;
            }
            $action = isset($row['action']) ? strtolower((string) $row['action']) : 'upsert';
            $existing = vpnx_user_get($name);

            if ($action === 'delete') {
                if ($existing !== null) {
                    $nodes = isset($existing['nodes']) ? $existing['nodes'] : array();
                    $nodes = array_values(array_diff($nodes, array($node_id)));
                    $tags = isset($existing['tags']) ? $existing['tags'] : array();
                    if (!$nodes && !$tags) {
                        // 原本是"全部节点"语义: 改成"除本节点外的所有节点"显式指派
                        $all = array();
                        $reg = vpnx_nodes_load();
                        foreach (array_keys($reg['nodes']) as $nid) {
                            if ($nid !== $node_id) {
                                $all[] = $nid;
                            }
                        }
                        $nodes = $all;
                    }
                    vpnx_user_update($name, array('nodes' => $nodes));
                    vpnx_tombstone_add($node_id, $name);
                    $applied['users'][] = array('name' => $name, 'action' => 'delete');
                }
                continue;
            }

            if ($action === 'disable') {
                if ($existing !== null) {
                    vpnx_user_set_enabled($name, false, 'policy');
                    $applied['users'][] = array('name' => $name, 'action' => 'disable');
                }
                continue;
            }

            // upsert
            if ($existing === null) {
                $r = vpnx_user_add(array(
                    'name' => $name,
                    'uuid' => isset($row['uuid']) ? $row['uuid'] : '',
                    'expire_at' => isset($row['expire_at']) ? $row['expire_at'] : 0,
                    'quota_bytes' => isset($row['quota_bytes']) ? $row['quota_bytes'] : 0,
                    'max_devices' => isset($row['max_devices']) ? $row['max_devices'] : 0,
                    'speed_mbps' => isset($row['speed_mbps']) ? $row['speed_mbps'] : 0,
                    'protocols' => isset($row['protocols']) ? $row['protocols'] : array(),
                    'nodes' => array($node_id),
                    'note' => isset($row['note']) ? $row['note'] : '',
                ));
                $applied['users'][] = array('name' => $name, 'action' => 'upsert', 'ok' => !empty($r['ok']));
            } else {
                $nodes = isset($existing['nodes']) ? $existing['nodes'] : array();
                if (!in_array($node_id, $nodes, true) && !empty($nodes)) {
                    $nodes[] = $node_id;
                }
                $patch = array('nodes' => $nodes);
                if (isset($row['expire_at'])) {
                    $patch['expire_at'] = $row['expire_at'];
                }
                if (isset($row['quota_bytes'])) {
                    $patch['quota_bytes'] = $row['quota_bytes'];
                }
                if (isset($row['protocols'])) {
                    $patch['protocols'] = $row['protocols'];
                }
                if (isset($row['enabled'])) {
                    $patch['enabled'] = !empty($row['enabled']);
                }
                vpnx_user_update($name, $patch);
                vpnx_tombstone_drop($node_id, $name);
                $applied['users'][] = array('name' => $name, 'action' => 'upsert');
            }
        }
    }

    // 触发一次指纹计算, 让 revision 立即推进(节点下次轮询即可拉到)
    $doc2 = vpnx_policy_build(vpnx_node_get($node_id));
    vpnx_audit('admin', 'policy_apply', $node_id . ' users=' . count($applied['users']));
    return array(
        'ok' => true,
        'revision' => (int) $doc2['revision'],
        'applied' => $applied,
    );
}


