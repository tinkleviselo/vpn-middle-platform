<?php
/**
 * vpnx 中台自测脚本(不需要 PHPUnit, 直接 `php tests/php_smoke.php` 运行)
 *
 * 它会:
 *   1. 造一个临时数据目录(VPNX_DATA_DIR), 让中台在该目录里初始化
 *   2. 用 PHP 内置服务器把 central/api.php 跑起来(随机空闲端口)
 *   3. 分别以"管理端"和"节点端"的身份跑完整流程, 覆盖:
 *        · 管理接口鉴权 /health 免鉴权 / 错误 token 401
 *        · 节点 HMAC 签名: 正常通过 / 错密钥 / nonce 重放 / 时钟偏移
 *        · 注册节点 -> 建账号(指定同步到哪些服务器) -> 策略生成与 revision
 *        · format=lines 协议 / unchanged 短路 / ack
 *        · 用量上报与聚合 / 到期自动停用
 *        · 订阅推送与 /sub/<token> 三种格式 + Subscription-Userinfo 头
 *        · 删除账号 -> 墓碑(action=delete) / 目录穿越防护
 *   4. 全部断言通过输出 OK, 否则列出失败项并以非 0 退出
 *
 * 用法:
 *   php tests/php_smoke.php
 *   php tests/php_smoke.php --keep    保留临时目录便于排查
 */

$ROOT = dirname(__DIR__);           // central/
$KEEP = in_array('--keep', $argv, true);

$PASS = 0;
$FAIL = 0;
$FAILED = array();

/**
 * 断言
 */
function check($name, $cond, $detail = '')
{
    global $PASS, $FAIL, $FAILED;
    if ($cond) {
        $PASS++;
        echo "  [通过] " . $name . "\n";
    } else {
        $FAIL++;
        $FAILED[] = $name . ($detail !== '' ? ' (' . $detail . ')' : '');
        echo "  [失败] " . $name . ($detail !== '' ? ' -> ' . $detail : '') . "\n";
    }
}

function section($title)
{
    echo "\n== " . $title . " ==\n";
}

/**
 * 递归建目录
 */
function mkdirp($dir)
{
    if (is_dir($dir)) {
        return true;
    }
    return @mkdir($dir, 0700, true);
}

/**
 * 递归删除
 */
function rrmdir($dir)
{
    if (!is_dir($dir)) {
        return;
    }
    $items = @scandir($dir);
    if (!is_array($items)) {
        return;
    }
    foreach ($items as $item) {
        if ($item === '.' || $item === '..') {
            continue;
        }
        $path = $dir . DIRECTORY_SEPARATOR . $item;
        if (is_dir($path)) {
            rrmdir($path);
        } else {
            @unlink($path);
        }
    }
    @rmdir($dir);
}

/**
 * 取一个空闲端口
 */
function free_port()
{
    $sock = @stream_socket_server('tcp://127.0.0.1:0', $errno, $errstr);
    if (!$sock) {
        return 18080 + mt_rand(0, 2000);
    }
    $name = stream_socket_get_name($sock, false);
    fclose($sock);
    $parts = explode(':', $name);
    return (int) array_pop($parts);
}

/**
 * HTTP 请求(优先 curl 扩展, 否则用流封装)
 *
 * @return array status / body / headers(小写键)
 */
function http_request($method, $url, $headers = array(), $body = null)
{
    $hdrLines = array();
    if (function_exists('curl_init')) {
        $ch = curl_init($url);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_CUSTOMREQUEST, $method);
        curl_setopt($ch, CURLOPT_TIMEOUT, 25);
        curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 10);
        curl_setopt($ch, CURLOPT_HTTPHEADER, $headers);
        if ($body !== null) {
            curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
        }
        curl_setopt($ch, CURLOPT_HEADERFUNCTION, function ($ch, $line) use (&$hdrLines) {
            $hdrLines[] = trim($line);
            return strlen($line);
        });
        $resp = curl_exec($ch);
        $status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $err = curl_error($ch);
        curl_close($ch);
        if ($resp === false) {
            return array('status' => 0, 'body' => '', 'headers' => array(), 'error' => $err);
        }
    } else {
        $opts = array('http' => array(
            'method' => $method,
            'header' => implode("\r\n", $headers),
            'ignore_errors' => true,
            'timeout' => 25,
        ));
        if ($body !== null) {
            $opts['http']['content'] = $body;
        }
        $ctx = stream_context_create($opts);
        $resp = @file_get_contents($url, false, $ctx);
        $status = 0;
        if (isset($http_response_header) && is_array($http_response_header)) {
            $hdrLines = $http_response_header;
        }
        foreach ($hdrLines as $h) {
            if (preg_match('#^HTTP/\S+\s+(\d+)#', $h, $m)) {
                $status = (int) $m[1];
            }
        }
        if ($resp === false) {
            return array('status' => $status, 'body' => '', 'headers' => array(), 'error' => 'request failed');
        }
    }

    $out = array();
    foreach ($hdrLines as $line) {
        $pos = strpos($line, ':');
        if ($pos > 0) {
            $out[strtolower(substr($line, 0, $pos))] = trim(substr($line, $pos + 1));
        }
    }
    return array('status' => $status, 'body' => (string) $resp, 'headers' => $out, 'error' => '');
}

/**
 * 节点签名(与方法/路径/时间戳/nonce/body 完全对齐节点侧 vpnx.sh)
 */
function node_sign($secret, $method, $path, $ts, $nonce, $body)
{
    $msg = strtoupper($method) . "\n" . $path . "\n" . $ts . "\n" . $nonce . "\n" . hash('sha256', $body);
    return hash_hmac('sha256', $msg, $secret);
}

/**
 * 带签名的节点请求
 *
 * @param string      $pathWithQuery 实际请求的路径(可带 query)
 * @param string|null $signPath      参与签名的路径; null 表示取 $pathWithQuery 去掉 query 的部分
 *                                   (查询参数模式 ?__vpnx=/api/v1/xxx 时必须显式传 /api/v1/xxx)
 */
function node_request($base, $secret, $nodeId, $method, $pathWithQuery, $body = '', $signPath = null)
{
    $pathOnly = explode('?', $pathWithQuery);
    $pathOnly = $pathOnly[0];
    if ($signPath !== null) {
        $pathOnly = $signPath;
    }
    $ts = (string) time();
    $nonce = bin2hex(function_exists('random_bytes') ? random_bytes(8) : pack('N', mt_rand()));
    $sig = node_sign($secret, $method, $pathOnly, $ts, $nonce, $body);
    $headers = array(
        'X-VPNX-Node: ' . $nodeId,
        'X-VPNX-Timestamp: ' . $ts,
        'X-VPNX-Nonce: ' . $nonce,
        'X-VPNX-Signature: ' . $sig,
        'Accept: application/json, text/plain',
        'Content-Type: application/json',
    );
    return http_request($method, $base . $pathWithQuery, $headers, ($method === 'POST' ? $body : null));
}

// ---------------------------------------------------------------------------
// 准备
// ---------------------------------------------------------------------------
$dataDir = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'vpnx-smoke-' . getmypid() . '-' . mt_rand(1000, 9999);
rrmdir($dataDir);
mkdirp($dataDir);

$port = free_port();
$base = 'http://127.0.0.1:' . $port;
$logFile = $dataDir . DIRECTORY_SEPARATOR . 'server.log';

echo "vpnx 中台自测\n";
echo "  PHP 版本   : " . PHP_VERSION . "\n";
echo "  站点目录   : " . $ROOT . "\n";
echo "  数据目录   : " . $dataDir . "\n";
echo "  测试地址   : " . $base . "\n";

$cmd = escapeshellarg(PHP_BINARY) . ' -S 127.0.0.1:' . $port . ' ' . escapeshellarg($ROOT . DIRECTORY_SEPARATOR . 'api.php');
$descriptors = array(0 => array('pipe', 'r'), 1 => array('file', $logFile, 'a'), 2 => array('file', $logFile, 'a'));
$env = array('VPNX_DATA_DIR' => $dataDir, 'PATH' => getenv('PATH'));
$proc = @proc_open($cmd, $descriptors, $pipes, $ROOT, $env);
if (!is_resource($proc)) {
    echo "[错误] 无法启动 PHP 内置服务器, 请确认 proc_open 未被禁用\n";
    exit(2);
}

// 等端口就绪
$ready = false;
for ($i = 0; $i < 50; $i++) {
    $sock = @fsockopen('127.0.0.1', $port, $errno, $errstr, 0.3);
    if ($sock) {
        fclose($sock);
        $ready = true;
        break;
    }
    usleep(200000);
}
if (!$ready) {
    echo "[错误] 内置服务器未就绪, 日志: " . @file_get_contents($logFile) . "\n";
    @proc_terminate($proc);
    exit(2);
}

$cfgFile = $dataDir . DIRECTORY_SEPARATOR . 'config.json';
$cfg = json_decode(@file_get_contents($cfgFile), true);
$adminToken = is_array($cfg) && isset($cfg['admin_token']) ? $cfg['admin_token'] : '';
check('初始化生成 config.json 与管理令牌', $adminToken !== '', 'token 为空');

$adminHeaders = array('X-Admin-Token: ' . $adminToken, 'Content-Type: application/json');

// ---------------------------------------------------------------------------
section('部署自检与鉴权');
$r = http_request('GET', $base . '/');
check('GET / 返回部署信息', $r['status'] === 200 && strpos($r['body'], 'vpnx central') !== false, 'status=' . $r['status']);

$r = http_request('GET', $base . '/api/v1/admin/health');
check('GET /admin/health 免鉴权可用', $r['status'] === 200 && strpos($r['body'], '"ok":true') !== false, 'status=' . $r['status']);

$r = http_request('GET', $base . '/api/v1/admin/nodes');
check('管理接口缺 token 返回 401', $r['status'] === 401, 'status=' . $r['status']);

$r = http_request('GET', $base . '/api/v1/admin/nodes', array('X-Admin-Token: wrong-token'));
check('管理接口错 token 返回 401', $r['status'] === 401, 'status=' . $r['status']);

// 查询参数模式(?__vpnx=...): 面板/虚拟主机拦截 ".php" 后附加路径时节点走这条路
$r = http_request('GET', $base . '/api.php?__vpnx=/api/v1/admin/health');
check('查询参数模式 ?__vpnx= 免鉴权健康检查可用', $r['status'] === 200 && strpos($r['body'], '"ok":true') !== false, 'status=' . $r['status'] . ' body=' . substr($r['body'], 0, 80));

// ---------------------------------------------------------------------------
section('节点注册与接入命令');
$r = http_request('POST', $base . '/api/v1/admin/nodes', $adminHeaders, json_encode(array(
    'node_id' => 'hk1', 'name' => '香港-1', 'ip' => '203.0.113.7', 'tags' => array('hk', 'premium'),
)));
$reg = json_decode($r['body'], true);
check('注册节点 hk1 成功', $r['status'] === 201 && !empty($reg['secret']), 'status=' . $r['status'] . ' body=' . substr($r['body'], 0, 120));
$secret = isset($reg['secret']) ? $reg['secret'] : '';
check('注册返回接入命令', !empty($reg['onboard_command']) && strpos($reg['onboard_command'], 'vpnx agent set') !== false);

$r = http_request('POST', $base . '/api/v1/admin/nodes', $adminHeaders, json_encode(array('node_id' => 'us1', 'name' => '美国-1', 'tags' => array('us'))));
check('注册第二个节点 us1 成功', $r['status'] === 201);
$reg2 = json_decode($r['body'], true);
$secret2 = isset($reg2['secret']) ? $reg2['secret'] : '';

// ---------------------------------------------------------------------------
section('节点 HMAC 鉴权');
$hb = json_encode(array(
    'node_id' => 'hk1', 'hostname' => 'hk1.example.com', 'agent_version' => '1.0.0',
    'xray_version' => '26.3.27', 'os' => 'Ubuntu 22.04', 'kernel' => '5.15.0', 'arch' => 'x86_64',
    'public_ip' => '203.0.113.7', 'uptime_sec' => 12345, 'load1' => '0.10',
    'users_total' => 0, 'users_active' => 0, 'traffic_total_bytes' => 0,
    'applied_policy_revision' => 0, 'health' => array('service_ok' => true, 'config_ok' => true, 'ports_ok' => true, 'last_error' => ''),
));
$r = node_request($base, $secret, 'hk1', 'POST', '/api/v1/node/heartbeat', $hb);
check('心跳(正确签名)通过', $r['status'] === 200 && strpos($r['body'], '"ok":true') !== false, 'status=' . $r['status'] . ' body=' . substr($r['body'], 0, 120));
$hbResp = json_decode($r['body'], true);
check('心跳返回策略版本字段', isset($hbResp['policy_revision']) && isset($hbResp['policy_pending']));
// 回归测试: 心跳必须自己推进 revision(否则新节点永远看到 pending=false, 不会去拉策略,
// 表现为账号建不出来、订阅也推不上来)
check('首次心跳即推进策略版本且 pending=true',
    isset($hbResp['policy_revision']) && (int) $hbResp['policy_revision'] >= 1 && $hbResp['policy_pending'] === true,
    json_encode($hbResp));

$r = node_request($base, 'deadbeef', 'hk1', 'POST', '/api/v1/node/heartbeat', $hb);
check('错密钥签名返回 401', $r['status'] === 401, 'status=' . $r['status']);

// 查询参数模式下的签名心跳(签名仍只覆盖 /api/v1/node/heartbeat, 不带 query)
$r = node_request($base, $secret, 'hk1', 'POST', '/api.php?__vpnx=/api/v1/node/heartbeat', $hb, '/api/v1/node/heartbeat');
check('查询参数模式 ?__vpnx= 签名心跳通过', $r['status'] === 200 && strpos($r['body'], '"ok":true') !== false, 'status=' . $r['status'] . ' body=' . substr($r['body'], 0, 120));

// nonce 重放
$ts = (string) time();
$nonce = 'fixednonce12345678';
$sig = node_sign($secret, 'POST', '/api/v1/node/heartbeat', $ts, $nonce, $hb);
$h = array('X-VPNX-Node: hk1', 'X-VPNX-Timestamp: ' . $ts, 'X-VPNX-Nonce: ' . $nonce, 'X-VPNX-Signature: ' . $sig, 'Content-Type: application/json');
$r1 = http_request('POST', $base . '/api/v1/node/heartbeat', $h, $hb);
$r2 = http_request('POST', $base . '/api/v1/node/heartbeat', $h, $hb);
check('同一 nonce 第二次被拒(防重放)', $r1['status'] === 200 && $r2['status'] === 401, 'first=' . $r1['status'] . ' second=' . $r2['status']);

// 时钟偏移
$oldTs = (string) (time() - 4000);
$sig = node_sign($secret, 'POST', '/api/v1/node/heartbeat', $oldTs, bin2hex(pack('N', mt_rand())), $hb);
$h = array('X-VPNX-Node: hk1', 'X-VPNX-Timestamp: ' . $oldTs, 'X-VPNX-Signature: ' . $sig, 'X-VPNX-Nonce: ' . bin2hex(pack('N', mt_rand())), 'Content-Type: application/json');
$r = http_request('POST', $base . '/api/v1/node/heartbeat', $h, $hb);
check('时间戳超窗返回 401', $r['status'] === 401, 'status=' . $r['status']);

$r = http_request('GET', $base . '/api/v1/admin/nodes', $adminHeaders);
$nodesList = json_decode($r['body'], true);
$node0 = isset($nodesList['nodes'][0]) ? $nodesList['nodes'][0] : array();
check('节点心跳后状态入库(在线/系统信息)', !empty($node0['online']) && $node0['xray_version'] === '26.3.27', 'online=' . (isset($node0['online']) ? var_export($node0['online'], true) : 'n/a'));

// ---------------------------------------------------------------------------
section('账号创建与"同步到哪些服务器"');
$r = http_request('POST', $base . '/api/v1/admin/users', $adminHeaders, json_encode(array(
    'name' => 'alice', 'expire_at' => '90d', 'quota_bytes' => '100G', 'max_devices' => 3,
    'protocols' => array('vless-reality', 'ss2022'), 'nodes' => array('hk1'), 'note' => '自测账号',
)));
$u1 = json_decode($r['body'], true);
check('创建账号 alice 并指定只同步到 hk1', $r['status'] === 201 && isset($u1['user']['nodes_resolved'])
    && $u1['user']['nodes_resolved'] === array('hk1'), 'status=' . $r['status'] . ' body=' . substr($r['body'], 0, 160));
$aliceToken = isset($u1['user']['sub_token']) ? $u1['user']['sub_token'] : '';
check('账号生成 UUID 与订阅 token', !empty($u1['user']['uuid']) && $aliceToken !== '');

$r = http_request('POST', $base . '/api/v1/admin/users', $adminHeaders, json_encode(array(
    'name' => 'bob', 'expire_at' => '0', 'quota_bytes' => '0', 'protocols' => array('vless-reality'), 'tags' => array('us'),
)));
$u2 = json_decode($r['body'], true);
check('创建账号 bob 并按标签 us 圈定', $r['status'] === 201 && $u2['user']['nodes_resolved'] === array('us1'), 'resolved=' . json_encode(isset($u2['user']['nodes_resolved']) ? $u2['user']['nodes_resolved'] : null));

// ---------------------------------------------------------------------------
section('策略下发(JSON 与 format=lines)');
$r = node_request($base, $secret, 'hk1', 'GET', '/api/v1/node/policy?node_id=hk1&current_revision=0&format=lines');
$lines = $r['body'];
check('节点拉取策略(lines)成功', $r['status'] === 200 && strpos($lines, 'ok=true') === 0, 'status=' . $r['status'] . ' body=' . substr($lines, 0, 120));
check('策略包含 hk1 上的 alice', strpos($lines, 'users.0.name=alice') !== false, substr($lines, 0, 200));
check('策略不含 us1 上的 bob', strpos($lines, 'bob') === false);
check('策略包含节点级参数', strpos($lines, 'node.reality_target=') !== false && strpos($lines, 'node.log_level=') !== false);
check('策略包含档位定义', strpos($lines, 'profiles.std.type=vless-reality') !== false);
$rev = 0;
if (preg_match('/^revision=(\d+)$/m', $lines, $m)) {
    $rev = (int) $m[1];
}
check('策略 revision 已推进(>=1)', $rev >= 1, 'rev=' . $rev);

$r = node_request($base, $secret, 'hk1', 'GET', '/api/v1/node/policy?node_id=hk1&current_revision=' . $rev . '&format=lines');
check('revision 相同时返回 unchanged', strpos($r['body'], 'unchanged=true') !== false, substr($r['body'], 0, 100));

// 查询参数模式拉策略
$r = node_request($base, $secret, 'hk1', 'GET', '/api.php?__vpnx=/api/v1/node/policy&node_id=hk1&current_revision=0&format=lines', '', '/api/v1/node/policy');
check('查询参数模式 ?__vpnx= 拉策略成功', $r['status'] === 200 && strpos($r['body'], 'users.') !== false, 'status=' . $r['status'] . ' body=' . substr($r['body'], 0, 120));

$r = node_request($base, $secret2, 'us1', 'GET', '/api/v1/node/policy?node_id=us1&current_revision=0');
$usDoc = json_decode($r['body'], true);
$usNames = array();
if (isset($usDoc['users']) && is_array($usDoc['users'])) {
    foreach ($usDoc['users'] as $row) {
        $usNames[] = $row['name'];
    }
}
check('us1 只拿到 bob 的策略(JSON)', in_array('bob', $usNames, true) && !in_array('alice', $usNames, true), json_encode($usNames));

// ---------------------------------------------------------------------------
section('用量上报 / 聚合 / 到期停用');
$report = json_encode(array(
    'node_id' => 'hk1', 'report_type' => 'usage', 'revision' => $rev,
    'usage' => array(array('name' => 'alice', 'email' => 'alice@r', 'up' => 1048576, 'down' => 2097152, 'online_ips' => 2, 'last_seen' => time())),
    'events' => array(array('ts' => time(), 'level' => 'INFO', 'code' => 'device_limit', 'message' => '自测事件')),
    'ack' => array('policy_revision' => $rev, 'result' => 'applied', 'error' => ''),
));
$r = node_request($base, $secret, 'hk1', 'POST', '/api/v1/node/report', $report);
check('上报用量+事件+ack 成功', $r['status'] === 200 && strpos($r['body'], '"usage_applied":1') !== false, 'status=' . $r['status'] . ' body=' . substr($r['body'], 0, 120));

$r = http_request('GET', $base . '/api/v1/admin/users/alice', $adminHeaders);
$ua = json_decode($r['body'], true);
check('用量聚合到账号(1MB+2MB)', isset($ua['user']['used_bytes']) && $ua['user']['used_bytes'] === 3145728, 'used=' . json_encode(isset($ua['user']['used_bytes']) ? $ua['user']['used_bytes'] : null));

$r = http_request('GET', $base . '/api/v1/admin/nodes/hk1/usage', $adminHeaders);
check('节点用量与事件可查', strpos($r['body'], 'alice') !== false && strpos($r['body'], 'device_limit') !== false);

$r = http_request('GET', $base . '/api/v1/admin/nodes/hk1', $adminHeaders);
$n1 = json_decode($r['body'], true);
check('ack 后已应用版本追上已发布版本', isset($n1['node']['policy']['applied_revision'])
    && $n1['node']['policy']['applied_revision'] >= $rev
    && $n1['node']['policy']['pending'] === false, json_encode(isset($n1['node']['policy']) ? $n1['node']['policy'] : null));

// 到期自动停用
$r = http_request('POST', $base . '/api/v1/admin/users', $adminHeaders, json_encode(array(
    'name' => 'expired1', 'expire_at' => '2000-01-01', 'protocols' => array('vless-reality'), 'nodes' => array('hk1'),
)));
check('创建已过期账号 expired1', $r['status'] === 201);
$r = http_request('POST', $base . '/api/v1/admin/enforce', $adminHeaders, '{}');
$r = http_request('GET', $base . '/api/v1/admin/users/expired1', $adminHeaders);
$ue = json_decode($r['body'], true);
check('到期账号被自动停用', isset($ue['user']['enabled']) && $ue['user']['enabled'] === false
    && $ue['user']['disabled_reason'] === 'expired', json_encode(isset($ue['user']) ? $ue['user'] : null));

// ---------------------------------------------------------------------------
section('订阅推送与聚合');
$subPayload = json_encode(array(
    'node_id' => 'hk1',
    'users' => array(array(
        'name' => 'alice', 'email' => 'alice@r', 'sub_token' => $aliceToken,
        'expire_at' => 0, 'quota_bytes' => 107374182400, 'used_bytes' => 3145728,
        'links' => array('vless://11111111-2222-4333-8444-555555555555@203.0.113.7:8443?security=reality&sni=www.bing.com#hk1-alice-REALITY'),
        'extra' => array(
            'meta' => 'upload=1048576;download=2097152;total=107374182400;expire=0;',
            'clash_yaml' => "proxies:\n  - name: \"hk1-alice-REALITY\"\n    type: vless\n    server: 203.0.113.7\n    port: 8443\n    uuid: 11111111-2222-4333-8444-555555555555\nproxy-groups:\n  - name: PROXY\n    type: select\n    proxies: [hk1-alice-REALITY]\nrules:\n  - MATCH,PROXY\n",
        ),
    )),
));
$r = node_request($base, $secret, 'hk1', 'POST', '/api/v1/node/subscription', $subPayload);
check('节点推送订阅成功', $r['status'] === 200 && strpos($r['body'], '"published":1') !== false, 'status=' . $r['status'] . ' body=' . substr($r['body'], 0, 120));

$r = http_request('GET', $base . '/sub/' . $aliceToken);
$decoded = base64_decode(trim($r['body']));
check('订阅 base64 可取回且含 vless 链接', $r['status'] === 200 && strpos($decoded, 'vless://') === 0, 'status=' . $r['status'] . ' body=' . substr($r['body'], 0, 80));
check('订阅响应带 Subscription-Userinfo', isset($r['headers']['subscription-userinfo'])
    && strpos($r['headers']['subscription-userinfo'], 'download=') !== false, json_encode($r['headers']));
check('订阅响应带更新间隔头', isset($r['headers']['profile-update-interval']));

$r = http_request('GET', $base . '/sub/' . $aliceToken . '/clash');
check('Clash 订阅可用且包含 proxies', $r['status'] === 200 && strpos($r['body'], 'proxies:') !== false, 'status=' . $r['status']);
    check('Clash 订阅用中台命名(不泄露节点ID/账号/端口)',
        strpos($r['body'], 'hk1-') === false && strpos($r['body'], 'alice-REALITY') === false,
        substr($r['body'], 0, 240));
    check('Clash 订阅保留代理组与规则', strpos($r['body'], 'proxy-groups:') !== false && strpos($r['body'], 'MATCH') !== false);
check('Clash 订阅 Content-Type 为 yaml', isset($r['headers']['content-type']) && strpos($r['headers']['content-type'], 'yaml') !== false);

$r = http_request('GET', $base . '/sub/' . $aliceToken . '?target=raw');
check('订阅 raw 模式返回明文链接', $r['status'] === 200 && strpos($r['body'], 'vless://') === 0);

// 查询参数模式订阅(订阅地址形如 .../api.php?__vpnx=/sub/<token>)
$r = http_request('GET', $base . '/api.php?__vpnx=/sub/' . $aliceToken);
$decodedQ = base64_decode(trim($r['body']));
check('查询参数模式 ?__vpnx= 订阅可取回', $r['status'] === 200 && strpos($decodedQ, 'vless://') === 0, 'status=' . $r['status'] . ' body=' . substr($r['body'], 0, 80));
$r = http_request('GET', $base . '/api.php?__vpnx=/sub/' . $aliceToken . '&target=raw');
check('查询参数模式 + target=raw 组合可用', $r['status'] === 200 && strpos($r['body'], 'vless://') === 0);

// ---- 节点没上报 clash_yaml 时, 中台必须能从链接自己生成 Clash 配置 ----
// (真实踩过的坑: 节点侧 clash_yaml 传空 -> /clash 返回 base64 -> Clash 客户端订阅失败)
$ssUser = str_replace(array('+', '/', '='), array('-', '_', ''),
    base64_encode('2022-blake3-aes-128-gcm:c2VydmVyUFNL:dxNlclBTSw=='));
$fallbackLinks = array(
    'vless://11111111-2222-4333-8444-555555555555@203.0.113.9:2053?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.bing.com&fp=chrome&pbk=w99lWWzdWPLd3goqEAddQWxn7dZP4row1TO5ur1KjiA&sid=0cabbc3ac1dd7cde&spx=%2F&type=tcp#test-hk1-REALITY',
    'ss://' . $ssUser . '@203.0.113.9:8388#test-hk1-SS2022',
    'vmess://' . base64_encode(json_encode(array(
        'v' => '2', 'ps' => 'test-hk1-VMess', 'add' => '203.0.113.9', 'port' => '8081',
        'id' => '11111111-2222-4333-8444-555555555555', 'aid' => '0', 'net' => 'ws',
        'type' => 'none', 'host' => 'example.com', 'path' => '/vpnx-ws', 'tls' => '',
    ))),
    'vless://11111111-2222-4333-8444-555555555555@203.0.113.9:8444?encryption=none&security=reality&sni=www.bing.com&fp=chrome&pbk=w99lWWzdWPLd3goqEAddQWxn7dZP4row1TO5ur1KjiA&sid=0cabbc3ac1dd7cde&spx=%2F&type=xhttp&path=%2Fvpnx-xhttp&mode=auto#test-hk1-XHTTP',
);
$fbToken = 'fallback0123456789abcdef01234567';
$fbPayload = json_encode(array(
    'node_id' => 'hk1',
    'users' => array(array(
        'name' => 'fbuser', 'email' => 'fbuser@r', 'sub_token' => $fbToken,
        'expire_at' => 0, 'quota_bytes' => 0, 'used_bytes' => 0,
        'links' => $fallbackLinks,
        'extra' => array('meta' => 'upload=0;download=0;total=0;expire=0;'),  // 故意不给 clash_yaml
    )),
));
$r = node_request($base, $secret, 'hk1', 'POST', '/api/v1/node/subscription', $fbPayload);
check('推送不含 clash_yaml 的订阅成功', $r['status'] === 200 && strpos($r['body'], '"published":1') !== false);

$r = http_request('GET', $base . '/sub/' . $fbToken . '/clash');
check('无 clash_yaml 时中台从链接生成 Clash YAML',
    $r['status'] === 200 && strpos($r['body'], 'proxies:') === 0
    && strpos($r['body'], 'type: vless') !== false,
    'status=' . $r['status'] . ' body=' . substr($r['body'], 0, 120));
check('生成的 Clash 含 REALITY 公钥与 short-id',
    strpos($r['body'], 'reality-opts:') !== false
    && strpos($r['body'], 'w99lWWzdWPLd3goqEAddQWxn7dZP4row1TO5ur1KjiA') !== false);
check('生成的 Clash 含 SS 条目(cipher/password)',
    strpos($r['body'], 'type: ss') !== false
    && strpos($r['body'], 'cipher: 2022-blake3-aes-128-gcm') !== false
    && strpos($r['body'], 'c2VydmVyUFNL:dxNlclBTSw==') !== false,
    substr($r['body'], 0, 300));
check('生成的 Clash 含代理组与 MATCH 规则',
    strpos($r['body'], 'proxy-groups:') !== false && strpos($r['body'], 'MATCH,PROXY') !== false);

// ---- 老 Clash 兼容订阅(只含 VMess), 给 Clash for Android 等老内核用 ----
$r = http_request('GET', $base . '/sub/' . $fbToken . '/clash-legacy');
$legacyBody = $r['body'];
check('兼容订阅返回 YAML 且只含 VMess 节点',
    $r['status'] === 200 && strpos($legacyBody, 'type: vmess') !== false
    && strpos($legacyBody, 'type: vless') === false && strpos($legacyBody, 'type: ss') === false,
    'status=' . $r['status'] . ' body=' . substr($legacyBody, 0, 160));
check('兼容订阅的 VMess 同时带老写法 ws-path 与新写法 ws-opts',
    strpos($legacyBody, 'ws-path:') !== false && strpos($legacyBody, 'ws-opts:') !== false);
check('兼容订阅含代理组与 MATCH 规则',
    strpos($legacyBody, 'proxy-groups:') !== false && strpos($legacyBody, 'MATCH,PROXY') !== false);
check('兼容订阅可通过 ?__vpnx= 查询参数模式取回',
    strpos(http_request('GET', $base . '/api.php?__vpnx=/sub/' . $fbToken . '/clash-legacy')['body'], 'type: vmess') !== false);

// 只有 vless/ss 链接(没有 VMess)时, 兼容订阅也必须返回"能被老 Clash 加载"的配置:
// 老 Clash 不允许 proxies 为空, 否则报 "profile does not contain proxies or proxy-providers"
$onlyNewToken = 'onlynew0123456789abcdef01234567';
$onlyNew = json_encode(array(
    'node_id' => 'hk1',
    'users' => array(array(
        'name' => 'onlynew', 'email' => 'onlynew@r', 'sub_token' => $onlyNewToken,
        'expire_at' => 0, 'quota_bytes' => 0, 'used_bytes' => 0,
        'links' => array($fallbackLinks[0], $fallbackLinks[1]),   // 只有 vless + ss
        'extra' => array('meta' => 'upload=0;download=0;total=0;expire=0;'),
    )),
));
$r = node_request($base, $secret, 'hk1', 'POST', '/api/v1/node/subscription', $onlyNew);
$r = http_request('GET', $base . '/sub/' . $onlyNewToken . '/clash-legacy');
check('无 VMess 节点时兼容订阅不是空 proxies(老 Clash 会拒绝加载)',
    $r['status'] === 200 && strpos($r['body'], 'proxies:') !== false
    && strpos($r['body'], 'proxies: []') === false
    && strpos($r['body'], '未启用VMess') !== false,
    'status=' . $r['status'] . ' body=' . substr($r['body'], 0, 120));
check('无 VMess 节点时默认路由为 DIRECT(不影响手机正常上网)',
    strpos($r['body'], 'MATCH,DIRECT') !== false);

// ---- XHTTP 专用订阅(只含 vless+xhttp), 且默认 clash 订阅必须排除 XHTTP ----
$r = http_request('GET', $base . '/sub/' . $fbToken . '/clash-xhttp');
check('XHTTP 订阅只含一个节点(即 xhttp 节点)',
    $r['status'] === 200 && substr_count($r['body'], '- name:') === 1,
    'status=' . $r['status'] . ' body=' . substr($r['body'], 0, 140));
check('XHTTP 节点含 network: xhttp 与 xhttp-opts(path/mode)',
    strpos($r['body'], 'network: xhttp') !== false
    && strpos($r['body'], 'xhttp-opts:') !== false
    && strpos($r['body'], 'path: /vpnx-xhttp') !== false
    && strpos($r['body'], 'mode: auto') !== false);
check('XHTTP 节点不带 flow(Vision 与 XHTTP 互斥)',
    strpos($r['body'], 'flow:') === false);
$r = http_request('GET', $base . '/sub/' . $fbToken . '/clash');
check('默认 clash 订阅排除 XHTTP 节点(老客户端不会因此加载失败)',
    strpos($r['body'], 'network: xhttp') === false && strpos($r['body'], 'xhttp-opts') === false
    && strpos($r['body'], 'type: vless') !== false,
    'body=' . substr($r['body'], 0, 120));

$r = http_request('GET', $base . '/sub/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
check('未知订阅 token 返回 404', $r['status'] === 404, 'status=' . $r['status']);

$r = http_request('GET', $base . '/sub/..%2F..%2Fetc%2Fpasswd');
check('目录穿越被拦截', $r['status'] === 404, 'status=' . $r['status']);

$r = http_request('GET', $base . '/api/v1/admin/subscriptions', $adminHeaders);
check('管理端订阅清单可读', strpos($r['body'], $aliceToken) !== false && strpos($r['body'], 'clash_url') !== false);

// ---------------------------------------------------------------------------
section('停用 / 删除 / 墓碑下发');
$r = http_request('POST', $base . '/api/v1/admin/users/alice/disable', $adminHeaders, '{}');
check('停用 alice 成功', $r['status'] === 200);

$r = node_request($base, $secret, 'hk1', 'GET', '/api/v1/node/policy?node_id=hk1&current_revision=0&format=lines');
check('策略中 alice 变为 disable', strpos($r['body'], 'users.0.action=disable') !== false, substr($r['body'], 0, 220));
if (preg_match('/^revision=(\d+)$/m', $r['body'], $m)) {
    $rev2 = (int) $m[1];
} else {
    $rev2 = $rev + 1;
}

// 重新启用, 确认回到 upsert
$r = http_request('POST', $base . '/api/v1/admin/users/alice/enable', $adminHeaders, '{}');
check('重新启用 alice 成功', $r['status'] === 200);
$r = node_request($base, $secret, 'hk1', 'GET', '/api/v1/node/policy?node_id=hk1&current_revision=0&format=lines');
check('策略中 alice 回到 upsert', strpos($r['body'], 'users.0.action=upsert') !== false);

// 删除 -> 墓碑
$r = http_request('DELETE', $base . '/api/v1/admin/users/alice', $adminHeaders);
check('删除 alice 成功', $r['status'] === 200);
$r = node_request($base, $secret, 'hk1', 'GET', '/api/v1/node/policy?node_id=hk1&current_revision=0&format=lines');
check('删除后策略下发 action=delete(墓碑)', strpos($r['body'], 'action=delete') !== false && strpos($r['body'], 'name=alice') !== false, substr($r['body'], 0, 220));
$r = http_request('GET', $base . '/sub/' . $aliceToken);
check('账号删除后订阅失效', $r['status'] === 404, 'status=' . $r['status']);

// ---------------------------------------------------------------------------
section('声明式策略下发(管理端 PUT policy)');
$doc = json_encode(array(
    'node' => array('reality_target' => 'www.cloudflare.com:443', 'reality_server_names' => array('www.cloudflare.com'), 'log_level' => 'info'),
    'profiles' => array('std' => array('type' => 'vless-reality', 'params' => array('flow' => 'xtls-rprx-vision', 'fingerprint' => 'firefox', 'spider_x' => '/abc'))),
    'users' => array(array('action' => 'upsert', 'name' => 'carol', 'expire_at' => 0, 'quota_bytes' => 0, 'protocols' => array('vless-reality'))),
));
$r = http_request('PUT', $base . '/api/v1/admin/nodes/hk1/policy', $adminHeaders, $doc);
$ap = json_decode($r['body'], true);
check('PUT policy 应用成功', $r['status'] === 200 && !empty($ap['ok']) && isset($ap['revision']), 'status=' . $r['status'] . ' body=' . substr($r['body'], 0, 160));

$r = node_request($base, $secret, 'hk1', 'GET', '/api/v1/node/policy?node_id=hk1&current_revision=0&format=lines');
check('节点参数已生效(target)', strpos($r['body'], 'node.reality_target=www.cloudflare.com:443') !== false, substr($r['body'], 0, 200));
check('档位参数已生效(fingerprint)', strpos($r['body'], 'profiles.std.params.fingerprint=firefox') !== false);
check('声明式新增账号 carol 进入策略', strpos($r['body'], 'name=carol') !== false);

$r = http_request('GET', $base . '/api/v1/admin/users?node=hk1', $adminHeaders);
$hkUsers = json_decode($r['body'], true);
$hkNames = array();
if (isset($hkUsers['users']) && is_array($hkUsers['users'])) {
    foreach ($hkUsers['users'] as $u) {
        $hkNames[] = $u['name'];
    }
}
check('按节点筛选账号列表可用', in_array('carol', $hkNames, true), json_encode($hkNames));

// ---------------------------------------------------------------------------
section('审计与收尾');
$r = http_request('GET', $base . '/api/v1/admin/audit', $adminHeaders);
check('审计日志记录了管理操作', strpos($r['body'], 'node_add') !== false && strpos($r['body'], 'user_delete') !== false);
    section('节点分包分发(dist.php)');

    require_once __DIR__ . '/../lib/dist.php';

    check('dist: 非法文件名被拒(路径穿越/子目录)', vpnx_dist_name_ok('../evil.zip') === false && vpnx_dist_name_ok('a/b.zip') === false);
    check('dist: 合法文件名通过', vpnx_dist_name_ok('vpn.zip') === true && vpnx_dist_name_ok('vpn-2026.zip') === true);

    $pkList = vpnx_dist_list();
    check('dist: 能列出节点包(至少内置 vpn.zip)', count($pkList) > 0 && $pkList[0]['name'] === 'vpn.zip', json_encode($pkList));
    $pkUrl = vpnx_dist_download_url('vpn.zip');
    check('dist: 下载地址指向 dist.php', strpos($pkUrl, '/dist.php?f=vpn.zip') !== false, $pkUrl);

    $r = http_request('GET', $base . '/dist.php?f=vpn.zip');
    check('dist: 节点包可下载(200 + zip 头)', $r['status'] === 200 && substr($r['body'], 0, 2) === 'PK', 'status=' . $r['status'] . ' head=' . substr($r['body'], 0, 8));
    check('dist: 下载响应为 zip 类型', isset($r['headers']['content-type']) && strpos($r['headers']['content-type'], 'zip') !== false, isset($r['headers']['content-type']) ? $r['headers']['content-type'] : 'n/a');

    $r = http_request('GET', $base . '/dist.php?f=../api.php');
    check('dist: 路径穿越下载被拒(404)', $r['status'] === 404, 'status=' . $r['status']);
    $r = http_request('GET', $base . '/dist.php?f=nope.zip');
    check('dist: 不存在的包返回 404', $r['status'] === 404, 'status=' . $r['status']);

    $fakeNode = array('id' => 'hk1', 'secret' => 'SECRET123');
    $ic = vpnx_dist_command($fakeNode, 'install', 'vpn.zip', 'reality,ss2022,vmess-ws,xhttp');
    check('dist: 安装命令含下载+解压+安装+节点凭证',
        strpos($ic, 'dist.php?f=vpn.zip') !== false && strpos($ic, 'unzip') !== false
        && strpos($ic, 'vpnx.sh install') !== false && strpos($ic, '--node-id hk1') !== false
        && strpos($ic, '--token SECRET123') !== false, $ic);
    $uc = vpnx_dist_command($fakeNode, 'update', 'vpn.zip', '');
    // 中台分发的升级包: 能从包内读出 build, 才能让节点判断"是否需要升级"
    $pkBuild = vpnx_dist_build('vpn.zip');
    check('dist: 能从包内读出 build(用于对比节点版本)', $pkBuild !== '', 'build=' . $pkBuild);
    $pkPick = vpnx_dist_pick('vpn.zip');
    check('dist: pick 返回包信息(含 sha256)', is_array($pkPick) && strlen($pkPick['sha256']) === 64, json_encode($pkPick));
    check('dist: pick 未命中返回 null', vpnx_dist_pick('../none.zip') === null);

    check('dist: 更新命令只覆盖脚本(不重装)', strpos($uc, 'vpnx.sh install') === false && strpos($uc, '\cp -f') !== false, $uc);

$r = http_request('GET', $base . '/api/v1/admin/stats', $adminHeaders);
check('统计接口可用', $r['status'] === 200 && strpos($r['body'], '"nodes":2') !== false, substr($r['body'], 0, 160));

// ---------------------------------------------------------------------------
// 收尾
@proc_terminate($proc);
@proc_close($proc);
if (!$KEEP) {
    rrmdir($dataDir);
} else {
    echo "\n临时数据目录已保留: " . $dataDir . "\n";
}

echo "\n========================================\n";
echo "自测结果: " . $PASS . " 通过, " . $FAIL . " 失败\n";
if ($FAIL > 0) {
    echo "失败项:\n";
    foreach ($FAILED as $f) {
        echo "  - " . $f . "\n";
    }
    echo "服务器日志尾部:\n" . implode("\n", array_slice(explode("\n", (string) @file_get_contents($logFile)), -15)) . "\n";
}
echo "========================================\n";
exit($FAIL > 0 ? 1 : 0);
