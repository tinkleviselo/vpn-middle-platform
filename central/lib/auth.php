<?php
/**
 * vpnx 中台 - 鉴权
 *
 * 三类身份:
 *   1. 节点(机器): HMAC-SHA256 签名, 见 vpnx_node_authenticate()
 *   2. 管理 API:   Bearer token / X-Admin-Token
 *   3. 后台界面:   会话 + CSRF
 */

// ---------------------------------------------------------------------------
// 请求路径解析
// ---------------------------------------------------------------------------
/**
 * 推断"应用相对路径"的候选列表。
 *
 * 部署方式不同, PHP 看到的路径也不同:
 *   * 有 rewrite + PATH_INFO : PATH_INFO = /api/v1/node/heartbeat
 *   * 直接访问 api.php/xxx   : SCRIPT_NAME = /vpnx/api.php, REQUEST_URI = /vpnx/api.php/api/v1/...
 *   * rewrite 到 api.php     : REQUEST_URI = /vpnx/api/v1/node/heartbeat (需要从 /api/v1/ 处截取)
 *
 * 返回值用于两件事: 路由匹配, 以及"节点签名串里的 PATH 该取哪一个"。
 * 签名校验会逐个候选尝试, 只要有一个匹配即通过。
 *
 * @return array 归一化后的候选路径(去重, 第一个最可能是路由路径)
 */
function vpnx_request_candidates()
{
    $cands = array();

    // 查询参数模式: 节点 URL 以 .php 结尾时使用 ?__vpnx=/api/v1/xxx
    // 有些面板/虚拟主机会拦截 ".php" 后面的附加路径并直接返回 403, 该模式可绕开,
    // 因此在候选列表里放在第一位(路由与签名校验都会优先用它)。
    if (isset($_GET['__vpnx']) && is_string($_GET['__vpnx']) && $_GET['__vpnx'] !== '') {
        $cands[] = $_GET['__vpnx'];
    }

    if (!empty($_SERVER['PATH_INFO'])) {
        $cands[] = $_SERVER['PATH_INFO'];
    }
    if (!empty($_SERVER['ORIG_PATH_INFO'])) {
        $cands[] = $_SERVER['ORIG_PATH_INFO'];
    }

    $uri = isset($_SERVER['REQUEST_URI']) ? $_SERVER['REQUEST_URI'] : '/';
    $path = parse_url($uri, PHP_URL_PATH);
    if ($path === null || $path === false || $path === '') {
        $path = '/';
    }

    $script = isset($_SERVER['SCRIPT_NAME']) ? $_SERVER['SCRIPT_NAME'] : '';
    if ($script !== '' && strpos($path, $script) === 0) {
        $cands[] = substr($path, strlen($script));
    }

    // 从 /api/v1/... 或 /sub/... 处截取
    if (preg_match('#(/(?:api/v1|sub)/[A-Za-z0-9_./-]*)$#', $path, $m)) {
        $cands[] = $m[1];
    }

    $cands[] = $path;

    $out = array();
    foreach ($cands as $c) {
        if (!is_string($c) || $c === '') {
            continue;
        }
        $c = preg_replace('#/+#', '/', $c);
        if (strlen($c) > 1) {
            $c = rtrim($c, '/');
        }
        if ($c === '') {
            $c = '/';
        }
        if (!in_array($c, $out, true)) {
            $out[] = $c;
        }
    }
    if (!$out) {
        $out[] = '/';
    }
    return $out;
}

/**
 * 路由用路径: 优先取 /api/v1/ 或 /sub/ 开头的候选
 */
function vpnx_app_path()
{
    $cands = vpnx_request_candidates();
    foreach ($cands as $c) {
        if (strpos($c, '/api/v1/') === 0 || strpos($c, '/sub/') === 0) {
            return $c;
        }
    }
    return $cands[0];
}

/**
 * 当前请求方法(大写)
 */
function vpnx_request_method()
{
    return isset($_SERVER['REQUEST_METHOD']) ? strtoupper($_SERVER['REQUEST_METHOD']) : 'GET';
}

/**
 * 读取原始请求体
 */
function vpnx_read_body()
{
    $body = @file_get_contents('php://input');
    return $body === false ? '' : $body;
}

/**
 * 请求体解析为数组(非 JSON 返回空数组)
 */
function vpnx_read_json_body()
{
    $raw = vpnx_read_body();
    if ($raw === '') {
        return array();
    }
    $data = json_decode($raw, true);
    return is_array($data) ? $data : array();
}

// ---------------------------------------------------------------------------
// 节点鉴权
// ---------------------------------------------------------------------------
/**
 * 校验节点请求签名
 *
 * 签名串: METHOD \n PATH(不含 query) \n TIMESTAMP \n NONCE \n SHA256_HEX(body)
 *
 * @param string $method 大写方法
 * @param string $body   原始请求体
 * @return array array(node_id|null, error_code|null)
 */
function vpnx_node_authenticate($method, $body)
{
    $nodeId = isset($_SERVER['HTTP_X_VPNX_NODE']) ? trim($_SERVER['HTTP_X_VPNX_NODE']) : '';
    $ts     = isset($_SERVER['HTTP_X_VPNX_TIMESTAMP']) ? trim($_SERVER['HTTP_X_VPNX_TIMESTAMP']) : '';
    $nonce  = isset($_SERVER['HTTP_X_VPNX_NONCE']) ? trim($_SERVER['HTTP_X_VPNX_NONCE']) : '';
    $sig    = isset($_SERVER['HTTP_X_VPNX_SIGNATURE']) ? strtolower(trim($_SERVER['HTTP_X_VPNX_SIGNATURE'])) : '';

    if ($nodeId === '' || $ts === '' || $nonce === '' || $sig === '') {
        return array(null, 'missing_headers');
    }
    if (!ctype_digit($ts)) {
        return array(null, 'bad_timestamp');
    }
    $cfg = vpnx_config();
    if (abs(vpnx_now() - (int) $ts) > (int) $cfg['clock_skew']) {
        return array(null, 'clock_skew');
    }
    if (!vpnx_valid_node_id($nodeId)) {
        return array(null, 'bad_node_id');
    }

    $node = vpnx_node_get($nodeId);
    // 节点不存在时也用占位密钥计算, 保证响应不泄露节点是否存在
    $secret = ($node !== null && !empty($node['secret'])) ? $node['secret'] : str_repeat('0', 64);
    $bodyHash = hash('sha256', $body === null ? '' : $body);

    $matched = null;
    foreach (vpnx_request_candidates() as $cand) {
        $msg = $method . "\n" . $cand . "\n" . $ts . "\n" . $nonce . "\n" . $bodyHash;
        $expect = hash_hmac('sha256', $msg, $secret);
        if (hash_equals($expect, $sig)) {
            $matched = $cand;
            break;
        }
    }
    if ($matched === null) {
        return array(null, 'bad_signature');
    }
    if ($node === null) {
        return array(null, 'unknown_node');
    }
    if (!vpnx_nonce_check_and_store($nodeId . ':' . $nonce, (int) $ts)) {
        return array(null, 'nonce_replay');
    }
    return array($nodeId, null);
}

// ---------------------------------------------------------------------------
// 管理 API 鉴权
// ---------------------------------------------------------------------------
/**
 * 管理 API 令牌校验(Bearer 或 X-Admin-Token)
 *
 * @return bool
 */
function vpnx_admin_api_auth()
{
    $header = '';
    if (isset($_SERVER['HTTP_AUTHORIZATION'])) {
        $header = $_SERVER['HTTP_AUTHORIZATION'];
    } elseif (isset($_SERVER['REDIRECT_HTTP_AUTHORIZATION'])) {
        // Apache + CGI 常见: Authorization 被重定向到该变量
        $header = $_SERVER['REDIRECT_HTTP_AUTHORIZATION'];
    }
    $token = '';
    if (stripos($header, 'bearer ') === 0) {
        $token = trim(substr($header, 7));
    }
    if ($token === '' && isset($_SERVER['HTTP_X_ADMIN_TOKEN'])) {
        $token = trim($_SERVER['HTTP_X_ADMIN_TOKEN']);
    }
    $expect = vpnx_admin_token();
    if ($expect === '' || $token === '') {
        return false;
    }
    return hash_equals($expect, $token);
}

// ---------------------------------------------------------------------------
// 后台会话
// ---------------------------------------------------------------------------
/**
 * 启动会话(只调用一次)
 */
function vpnx_session_start()
{
    if (function_exists('session_status') && session_status() === PHP_SESSION_ACTIVE) {
        return;
    }
    if (session_id() !== '') {
        return;
    }
    if (!headers_sent()) {
        $secure = (!empty($_SERVER['HTTPS']) && strtolower($_SERVER['HTTPS']) !== 'off');
        if (function_exists('session_set_cookie_params')) {
            @session_set_cookie_params(0, '/', '', $secure, true);
        }
        @session_name('vpnxsid');
    }
    @session_start();
}

function vpnx_admin_logged_in()
{
    vpnx_session_start();
    return !empty($_SESSION['vpnx_admin']);
}

function vpnx_current_admin()
{
    vpnx_session_start();
    return isset($_SESSION['vpnx_admin']) ? $_SESSION['vpnx_admin'] : '';
}

/**
 * 登录校验
 *
 * @return bool
 */
function vpnx_admin_login($user, $pass)
{
    $cfg = vpnx_config();
    if (!hash_equals((string) $cfg['admin_user'], (string) $user)) {
        return false;
    }
    if (!vpnx_password_verify($pass, $cfg['admin_pass'])) {
        return false;
    }
    vpnx_session_start();
    if (function_exists('session_regenerate_id')) {
        @session_regenerate_id(true);
    }
    $_SESSION['vpnx_admin'] = $user;
    $_SESSION['vpnx_login_at'] = vpnx_now();
    vpnx_audit('admin', 'login', $user);
    return true;
}

function vpnx_admin_logout()
{
    vpnx_session_start();
    $_SESSION = array();
    if (ini_get('session.use_cookies') && !headers_sent()) {
        @setcookie(session_name(), '', time() - 42000, '/');
    }
    @session_destroy();
}

/**
 * 修改管理员口令
 *
 * @return array ok / error
 */
function vpnx_change_password($old, $new)
{
    $cfg = vpnx_config();
    if (!vpnx_password_verify($old, $cfg['admin_pass'])) {
        return array('ok' => false, 'error' => '原口令不正确');
    }
    if (strlen((string) $new) < 8) {
        return array('ok' => false, 'error' => '新口令至少 8 位');
    }
    $cfg['admin_pass'] = vpnx_password_hash($new);
    // 口令变更同时轮换管理令牌, 避免旧令牌继续可用
    $cfg['admin_token'] = vpnx_random_hex(32);
    vpnx_config_save($cfg);
    vpnx_audit('admin', 'change_password', 'password + admin_token rotated');
    return array('ok' => true);
}

/**
 * CSRF token
 */
function vpnx_csrf_token()
{
    vpnx_session_start();
    if (empty($_SESSION['vpnx_csrf'])) {
        $_SESSION['vpnx_csrf'] = vpnx_random_hex(16);
    }
    return $_SESSION['vpnx_csrf'];
}

/**
 * CSRF 校验
 */
function vpnx_csrf_check($token)
{
    vpnx_session_start();
    if (empty($_SESSION['vpnx_csrf'])) {
        return false;
    }
    return hash_equals($_SESSION['vpnx_csrf'], (string) $token);
}
