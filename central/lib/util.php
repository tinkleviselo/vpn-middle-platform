<?php
/**
 * vpnx 中台 - 公共工具库
 *
 * 设计约束:
 *   * 零第三方依赖, 不用数据库, 全部状态落 JSON 文件
 *   * 面向 PHP 5.6+ 编写; 同时提供 hash_equals / password_hash / random_bytes 垫片,
 *     以便在 建站面板 常见的 PHP 5.3~5.5 站点环境里也能跑
 *   * 写文件一律 "临时文件 + rename" 原子替换, 并用 flock 串行化读改写
 *   * 禁止嵌套加锁(flock 对同一文件在本进程内会死锁), 需要写多处数据时在调用方锁一次
 */

// 中台版本(与 vpnx.sh 的脚本版本独立演进)
if (!defined('VPNX_CENTRAL_VERSION')) {
    define('VPNX_CENTRAL_VERSION', '1.0.0');
}

// ---------------------------------------------------------------------------
// 兼容垫片
// ---------------------------------------------------------------------------
if (!function_exists('hash_equals')) {
    /**
     * 常量时间字符串比较(PHP 5.6 以前没有该函数)
     */
    function hash_equals($known, $user)
    {
        if (!is_string($known) || !is_string($user)) {
            return false;
        }
        if (strlen($known) !== strlen($user)) {
            return false;
        }
        $diff = 0;
        for ($i = 0, $n = strlen($known); $i < $n; $i++) {
            $diff |= ord($known[$i]) ^ ord($user[$i]);
        }
        return $diff === 0;
    }
}

/**
 * 生成密码学安全的随机字节(带多级回退)
 *
 * @param int $len 字节数
 * @return string 原始字节串
 */
function vpnx_random_bytes($len)
{
    $len = (int) $len;
    if ($len < 1) {
        $len = 1;
    }
    if (function_exists('random_bytes')) {
        return random_bytes($len);
    }
    if (function_exists('openssl_random_pseudo_bytes')) {
        $strong = false;
        $buf = openssl_random_pseudo_bytes($len, $strong);
        if ($buf !== false && strlen($buf) === $len) {
            return $buf;
        }
    }
    if (is_readable('/dev/urandom')) {
        $fh = @fopen('/dev/urandom', 'rb');
        if ($fh) {
            $buf = @fread($fh, $len);
            @fclose($fh);
            if ($buf !== false && strlen($buf) === $len) {
                return $buf;
            }
        }
    }
    // 最后手段: mt_rand 拼接(不够安全, 仅在极端受限环境下使用)
    $out = '';
    while (strlen($out) < $len) {
        $out .= pack('N', mt_rand(0, 0x7fffffff));
    }
    return substr($out, 0, $len);
}

/**
 * 随机十六进制串
 *
 * @param int $bytes 字节数(输出长度为其 2 倍)
 * @return string
 */
function vpnx_random_hex($bytes)
{
    return bin2hex(vpnx_random_bytes($bytes));
}

/**
 * 生成 v4 UUID
 *
 * @return string 形如 8-4-4-4-12
 */
function vpnx_uuid_v4()
{
    $b = vpnx_random_bytes(16);
    $b[6] = chr((ord($b[6]) & 0x0f) | 0x40); // version 4
    $b[8] = chr((ord($b[8]) & 0x3f) | 0x80); // variant
    $h = bin2hex($b);
    return substr($h, 0, 8) . '-' . substr($h, 8, 4) . '-' . substr($h, 12, 4)
        . '-' . substr($h, 16, 4) . '-' . substr($h, 20, 12);
}

/**
 * 生成 SS2022 预共享密钥(base64, 与 openssl rand -base64 N 等价)
 *
 * @param int $len 字节数: 16 用于 2022-blake3-aes-128-gcm, 32 用于 aes-256-gcm/chacha20
 * @return string
 */
function vpnx_ss_psk($len)
{
    return base64_encode(vpnx_random_bytes($len));
}

/**
 * SS 加密方法对应的密钥字节数
 *
 * @param string $method
 * @return int
 */
function vpnx_ss_key_len($method)
{
    if (strpos($method, 'aes-128-gcm') !== false) {
        return 16;
    }
    return 32;
}

/**
 * 口令哈希(优先 password_hash)
 */
function vpnx_password_hash($password)
{
    if (function_exists('password_hash')) {
        return password_hash($password, PASSWORD_DEFAULT);
    }
    return 'sha256$' . hash('sha256', $password);
}

/**
 * 校验口令
 */
function vpnx_password_verify($password, $stored)
{
    if (!is_string($stored) || $stored === '') {
        return false;
    }
    if (strpos($stored, 'sha256$') === 0) {
        return hash_equals(substr($stored, 7), hash('sha256', $password));
    }
    if (function_exists('password_verify')) {
        return password_verify($password, $stored);
    }
    return false;
}

// ---------------------------------------------------------------------------
// JSON 读写(原子)
// ---------------------------------------------------------------------------
/**
 * json_encode 包装(兼容老 PHP 没有 JSON_UNESCAPED_* 常量)
 */
function vpnx_json_encode($value)
{
    $opt = 0;
    if (defined('JSON_UNESCAPED_UNICODE')) {
        $opt |= JSON_UNESCAPED_UNICODE;
    }
    if (defined('JSON_UNESCAPED_SLASHES')) {
        $opt |= JSON_UNESCAPED_SLASHES;
    }
    return json_encode($value, $opt);
}

/**
 * json_decode 包装(统一返回关联数组)
 */
function vpnx_json_decode($text)
{
    $out = json_decode($text, true);
    return is_array($out) ? $out : array();
}

/**
 * 读 JSON 文件, 不存在或损坏时返回默认值
 *
 * @param string $file
 * @param mixed  $default
 * @return mixed
 */
function vpnx_json_read($file, $default = array())
{
    if (!is_file($file)) {
        return $default;
    }
    $raw = @file_get_contents($file);
    if ($raw === false || $raw === '') {
        return $default;
    }
    $data = json_decode($raw, true);
    if (!is_array($data)) {
        vpnx_log('JSON 解析失败, 已忽略: ' . $file);
        return $default;
    }
    return $data;
}

/**
 * 原子写 JSON 文件: 同目录临时文件 -> rename, 权限 0600
 *
 * @param string $file
 * @param mixed  $data
 * @return bool
 */
function vpnx_json_write($file, $data)
{
    $dir = dirname($file);
    if (!vpnx_mkdir($dir)) {
        return false;
    }
    $tmp = $file . '.tmp.' . getmypid() . '.' . substr(vpnx_random_hex(4), 0, 8);
    $text = vpnx_json_encode($data);
    if ($text === false) {
        return false;
    }
    if (@file_put_contents($tmp, $text) === false) {
        return false;
    }
    @chmod($tmp, 0600);
    if (!@rename($tmp, $file)) {
        @unlink($tmp);
        return false;
    }
    return true;
}

/**
 * 追加一行 JSONL
 */
function vpnx_jsonl_append($file, $row)
{
    if (!vpnx_mkdir(dirname($file))) {
        return false;
    }
    $text = vpnx_json_encode($row);
    if ($text === false) {
        return false;
    }
    $fh = @fopen($file, 'ab');
    if (!$fh) {
        return false;
    }
    @fwrite($fh, $text . "\n");
    @fclose($fh);
    @chmod($file, 0600);
    return true;
}

/**
 * 取 JSONL 末尾若干行(倒序返回解析后的数组, 最新的在前)
 *
 * @param string $file
 * @param int    $limit
 * @return array
 */
function vpnx_jsonl_tail($file, $limit)
{
    if (!is_file($file)) {
        return array();
    }
    $lines = @file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if (!is_array($lines)) {
        return array();
    }
    $lines = array_slice($lines, -1 * (int) $limit);
    $out = array();
    foreach (array_reverse($lines) as $line) {
        $row = json_decode($line, true);
        if (is_array($row)) {
            $out[] = $row;
        }
    }
    return $out;
}

/**
 * JSONL 文件按行数上限截断(防止无限增长)
 */
function vpnx_jsonl_trim($file, $keep)
{
    if (!is_file($file)) {
        return;
    }
    $lines = @file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if (!is_array($lines) || count($lines) <= $keep) {
        return;
    }
    $lines = array_slice($lines, -1 * (int) $keep);
    @file_put_contents($file, implode("\n", $lines) . "\n");
}

// ---------------------------------------------------------------------------
// 锁
// ---------------------------------------------------------------------------
/**
 * 获取全局写锁(独占)。必须在 finally/末尾释放, 且不要嵌套获取。
 *
 * @return resource|false
 */
function vpnx_lock()
{
    $file = vpnx_data_dir() . DIRECTORY_SEPARATOR . '.lock';
    if (!vpnx_mkdir(dirname($file))) {
        return false;
    }
    $fh = @fopen($file, 'c');
    if (!$fh) {
        return false;
    }
    if (!@flock($fh, LOCK_EX)) {
        @fclose($fh);
        return false;
    }
    return $fh;
}

/**
 * 释放锁
 */
function vpnx_unlock($handle)
{
    if (is_resource($handle)) {
        @flock($handle, LOCK_UN);
        @fclose($handle);
    }
}

// ---------------------------------------------------------------------------
// 路径与校验
// ---------------------------------------------------------------------------
/**
 * 数据目录(可用环境变量 VPNX_DATA_DIR 覆盖, 便于测试)
 */
function vpnx_data_dir()
{
    $env = getenv('VPNX_DATA_DIR');
    if ($env !== false && $env !== '') {
        return rtrim($env, "/\\");
    }
    return dirname(__DIR__) . DIRECTORY_SEPARATOR . 'data';
}

/**
 * 递归建目录(默认权限 0700)
 */
function vpnx_mkdir($dir)
{
    if (is_dir($dir)) {
        return true;
    }
    if (!@mkdir($dir, 0700, true)) {
        return is_dir($dir);
    }
    @chmod($dir, 0700);
    return true;
}

/**
 * 校验路径片段(节点 ID / 用户名 / 订阅 token / 档位名), 防目录穿越
 *
 * @param string $value
 * @return bool
 */
function vpnx_valid_component($value)
{
    if (!is_string($value) || $value === '' || strlen($value) > 64) {
        return false;
    }
    return (bool) preg_match('/^[A-Za-z0-9._-]+$/', $value);
}

/**
 * 用户名额外限制(不能是 . 或 ..)
 */
function vpnx_valid_name($value)
{
    return vpnx_valid_component($value) && $value !== '.' && $value !== '..';
}

/**
 * 节点 ID 限制为小写字母开头
 */
function vpnx_valid_node_id($value)
{
    return (bool) preg_match('/^[a-z0-9][a-z0-9._-]{0,31}$/', $value);
}

// ---------------------------------------------------------------------------
// 时间与容量
// ---------------------------------------------------------------------------
function vpnx_now()
{
    return time();
}

/**
 * 时间戳格式化(空/0 显示为 -)
 */
function vpnx_fmt_time($ts)
{
    $ts = (int) $ts;
    if ($ts <= 0) {
        return '-';
    }
    return date('Y-m-d H:i:s', $ts);
}

/**
 * 到期时间显示
 */
function vpnx_fmt_expire($ts)
{
    $ts = (int) $ts;
    if ($ts <= 0) {
        return '永不过期';
    }
    return date('Y-m-d H:i:s', $ts);
}

/**
 * 字节数可读化
 */
function vpnx_fmt_bytes($bytes)
{
    $bytes = (float) $bytes;
    $units = array('B', 'KB', 'MB', 'GB', 'TB', 'PB');
    $i = 0;
    while ($bytes >= 1024 && $i < 5) {
        $bytes /= 1024;
        $i++;
    }
    if ($i === 0) {
        return sprintf('%d%s', $bytes, $units[$i]);
    }
    return sprintf('%.2f%s', $bytes, $units[$i]);
}

/**
 * 容量字符串转字节: 100G / 500M / 1T / 1024
 */
function vpnx_size_to_bytes($text)
{
    $text = strtoupper(trim((string) $text));
    if ($text === '') {
        return 0;
    }
    if (!preg_match('/^([0-9]+(?:\.[0-9]+)?)\s*([KMGTP]?)B?$/', $text, $m)) {
        return 0;
    }
    $multi = array('' => 1, 'K' => 1024, 'M' => 1048576, 'G' => 1073741824, 'T' => 1099511627776, 'P' => 1125899906842624);
    $unit = isset($m[2]) ? $m[2] : '';
    $factor = isset($multi[$unit]) ? $multi[$unit] : 1;
    return (int) round(((float) $m[1]) * $factor);
}

/**
 * 到期时间解析: 30d / 12h / 45m / 2026-01-31 / 1767225600 / 空(永久)
 *
 * @param string $text
 * @return int epoch, 0 表示永不过期
 */
function vpnx_parse_expire($text)
{
    $text = trim((string) $text);
    if ($text === '' || $text === '0' || strtolower($text) === 'never' || $text === '永不过期') {
        return 0;
    }
    if (preg_match('/^([0-9]+)\s*([dDhHmM])$/', $text, $m)) {
        $n = (int) $m[1];
        $u = strtolower($m[2]);
        $sec = $u === 'd' ? 86400 : ($u === 'h' ? 3600 : 60);
        return vpnx_now() + $n * $sec;
    }
    if (preg_match('/^[0-9]{9,}$/', $text)) {
        return (int) $text;
    }
    $ts = strtotime($text);
    if ($ts === false) {
        $ts = strtotime($text . ' 23:59:59');
    }
    return $ts === false ? 0 : (int) $ts;
}

// ---------------------------------------------------------------------------
// 扁平化(与节点侧 format=lines 协议对齐)
// ---------------------------------------------------------------------------
/**
 * 把嵌套结构扁平化为 key=value 行数组, 数组下标用数字
 *
 * @param mixed  $obj
 * @param string $prefix
 * @return array 元素形如 "users.0.name=alice"
 */
function vpnx_flatten($obj, $prefix = '')
{
    $out = array();
    if (is_array($obj)) {
        foreach ($obj as $k => $v) {
            $child = $prefix === '' ? (string) $k : $prefix . '.' . (string) $k;
            $out = array_merge($out, vpnx_flatten($v, $child));
        }
        return $out;
    }
    if (is_bool($obj)) {
        $val = $obj ? 'true' : 'false';
    } elseif ($obj === null) {
        $val = '';
    } else {
        $val = (string) $obj;
    }
    $out[] = $prefix . '=' . $val;
    return $out;
}

/**
 * 扁平化为文本(每行 key=value)
 */
function vpnx_to_lines($obj)
{
    $rows = vpnx_flatten($obj);
    if (!$rows) {
        return '';
    }
    return implode("\n", $rows) . "\n";
}

// ---------------------------------------------------------------------------
// HTTP 输出
// ---------------------------------------------------------------------------
/**
 * 给 URL 追加 query 参数(自动判断用 ? 还是 &)
 *
 * @param string $url
 * @param string $query 形如 target=raw
 * @return string
 */
function vpnx_url_add_query($url, $query)
{
    if ($query === '') {
        return $url;
    }
    $sep = (strpos($url, '?') === false) ? '?' : '&';
    return $url . $sep . $query;
}

/**
 * 输出 JSON 响应并结束
 *
 * @param int   $code    HTTP 状态码
 * @param mixed $payload 响应体
 * @param array $headers 额外响应头
 */
function vpnx_json_out($code, $payload, $headers = array())
{
    if (!headers_sent()) {
        @header('Content-Type: application/json; charset=utf-8');
        @header('Cache-Control: no-store');
        foreach ($headers as $k => $v) {
            @header($k . ': ' . $v);
        }
        if (function_exists('http_response_code')) {
            @http_response_code($code);
        } else {
            @header('HTTP/1.1 ' . $code . ' ' . vpnx_status_text($code));
        }
    }
    echo vpnx_json_encode($payload);
    exit;
}

/**
 * 输出纯文本(订阅用)
 */
function vpnx_text_out($code, $body, $headers = array())
{
    if (!headers_sent()) {
        @header('Content-Type: text/plain; charset=utf-8');
        foreach ($headers as $k => $v) {
            @header($k . ': ' . $v);
        }
        if (function_exists('http_response_code')) {
            @http_response_code($code);
        } else {
            @header('HTTP/1.1 ' . $code . ' ' . vpnx_status_text($code));
        }
    }
    echo $body;
    exit;
}

/**
 * 状态码文本
 */
function vpnx_status_text($code)
{
    $map = array(200 => 'OK', 201 => 'Created', 400 => 'Bad Request', 401 => 'Unauthorized',
        403 => 'Forbidden', 404 => 'Not Found', 405 => 'Method Not Allowed',
        409 => 'Conflict', 500 => 'Internal Server Error');
    return isset($map[$code]) ? $map[$code] : 'Status';
}

/**
 * 统一错误响应(与 Python 参考实现保持扁平结构: {"ok":false,"error":"..."})
 */
function vpnx_error_out($code, $message)
{
    vpnx_json_out($code, array('ok' => false, 'error' => $message));
}

/**
 * HTML 转义
 */
function vpnx_h($text)
{
    if (function_exists('htmlspecialchars')) {
        return htmlspecialchars((string) $text, ENT_QUOTES, 'UTF-8');
    }
    return htmlspecialchars((string) $text);
}

/**
 * 客户端 IP
 */
function vpnx_client_ip()
{
    if (!empty($_SERVER['REMOTE_ADDR'])) {
        return $_SERVER['REMOTE_ADDR'];
    }
    return '-';
}

/**
 * 写运行日志(轮转: 超过 2MB 截断一半)
 */
function vpnx_log($message)
{
    $file = vpnx_data_dir() . DIRECTORY_SEPARATOR . 'central.log';
    if (!vpnx_mkdir(dirname($file))) {
        return;
    }
    if (is_file($file) && @filesize($file) > 2097152) {
        $lines = @file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        if (is_array($lines)) {
            @file_put_contents($file, implode("\n", array_slice($lines, -2000)) . "\n");
        }
    }
    $line = date('Y-m-d H:i:s') . ' [' . vpnx_client_ip() . '] ' . $message . "\n";
    @file_put_contents($file, $line, FILE_APPEND);
}
