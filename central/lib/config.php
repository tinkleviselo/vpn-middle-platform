<?php
/**
 * vpnx 中台 - 配置与初始化
 *
 * 全部配置保存在 data/config.json; 首次访问时自动生成:
 *   * 管理员账号与随机口令 -> 写入 data/install-info.txt (部署后请立即删除该文件)
 *   * 管理 API 的 Bearer token
 *   * 默认协议白名单 / 档位 / 节点默认参数
 */

/**
 * 配置默认值
 *
 * @return array
 */
function vpnx_config_defaults()
{
    return array(
        'version' => '1.0.0',
        'site_name' => 'vpnx 中台',
        'base_url' => '',                 // 如 https://panel.example.com/vpnx, 用于生成订阅地址与节点接入命令
        'admin_user' => 'admin',
        'admin_pass' => '',               // 口令哈希
        'admin_token' => '',              // 管理 API Bearer token
        'clock_skew' => 300,              // 节点签名时间窗(秒)
        'nonce_window' => 300,            // nonce 去重窗口(秒)
        'sub_interval' => 12,             // Profile-Update-Interval
        'enforce_interval' => 30,         // 到期/超配额检查最小间隔(秒)
        'default_protocols' => array('vless-reality', 'ss2022'),
        'allow_protocols' => array('vless-reality', 'ss2022', 'vmess-ws', 'vless-xhttp'),
        // 节点级默认参数(节点侧 vpnx 会读取并落到配置)
        'node_defaults' => array(
            'log_level' => 'warning',
            'bbr' => true,
            'reality_target' => 'www.bing.com:443',
            'reality_server_names' => array('www.bing.com'),
            'ports' => array(),
        ),
        // 加密/传输档位: 键名是档位名, 节点会按 name 或 type 匹配本地内置档位
        'profiles' => array(
            'std' => array(
                'type' => 'vless-reality',
                'params' => array(
                    'flow' => 'xtls-rprx-vision',
                    'fingerprint' => 'chrome',
                    'spider_x' => '/',
                ),
            ),
            'ss' => array(
                'type' => 'ss2022',
                'params' => array('method' => '2022-blake3-aes-128-gcm'),
            ),
            'ws' => array(
                'type' => 'vmess-ws',
                'params' => array('path' => '/vpnx-ws'),
            ),
            'xhttp' => array(
                'type' => 'vless-xhttp',
                'params' => array(
                    'transport' => 'xhttp',
                    'path' => '/vpnx-xhttp',
                    'mode' => 'auto',
                    'flow' => '',
                ),
            ),
        ),
        'maintenance' => array(
            'window' => '03:00-04:00',
            'auto_update' => true,
            'max_xray_version' => '',
        ),
    );
}

/**
 * 读取配置(带进程内缓存)
 *
 * @return array
 */
function vpnx_config()
{
    static $cache = null;
    if ($cache !== null) {
        return $cache;
    }
    $file = vpnx_data_dir() . DIRECTORY_SEPARATOR . 'config.json';
    $cfg = vpnx_json_read($file, array());
    $defaults = vpnx_config_defaults();
    foreach ($defaults as $k => $v) {
        if (!array_key_exists($k, $cfg)) {
            $cfg[$k] = $v;
        }
    }
    $cache = $cfg;
    return $cache;
}

/**
 * 保存配置
 *
 * @param array $cfg
 * @return bool
 */
function vpnx_config_save($cfg)
{
    $file = vpnx_data_dir() . DIRECTORY_SEPARATOR . 'config.json';
    return vpnx_json_write($file, $cfg);
}

/**
 * 初始化数据目录与配置文件
 *
 * 幂等: 已存在 config.json 时只补齐缺失的键, 不会覆盖管理员口令
 *
 * @return array 初始化结果(created=true 表示首次生成)
 */
function vpnx_bootstrap()
{
    $data = vpnx_data_dir();
    vpnx_mkdir($data);
    foreach (array('usage', 'events', 'policy_state') as $sub) {
        vpnx_mkdir($data . DIRECTORY_SEPARATOR . $sub);
    }

    $configFile = $data . DIRECTORY_SEPARATOR . 'config.json';
    $created = false;
    $plain = '';
    $changed = false;
    $cfg = vpnx_json_read($configFile, array());
    if (isset($cfg['_initial_admin_pass'])) {
        unset($cfg['_initial_admin_pass']); // 兼容早期版本, 绝不把明文口令留在配置里
        $changed = true;
    }

    if (!isset($cfg['admin_token']) || $cfg['admin_token'] === '') {
        $cfg['admin_token'] = vpnx_random_hex(32);
        $changed = true;
    }
    if (!isset($cfg['admin_pass']) || $cfg['admin_pass'] === '') {
        $plain = vpnx_random_hex(6); // 12 位十六进制
        $cfg['admin_pass'] = vpnx_password_hash($plain);
        $created = true;
        $changed = true;
    }

    $defaults = vpnx_config_defaults();
    foreach ($defaults as $k => $v) {
        if (!array_key_exists($k, $cfg)) {
            $cfg[$k] = $v;
            $changed = true;
        }
    }
    // 只在真正有变化时落盘, 避免每个请求都写配置
    if ($changed || !is_file($configFile)) {
        vpnx_json_write($configFile, $cfg);
    }

    if ($created && $plain !== '') {
        $info = "vpnx 中台初始化信息\n"
            . "站点      : " . (isset($cfg['site_name']) ? $cfg['site_name'] : 'vpnx') . "\n"
            . "管理员    : " . $cfg['admin_user'] . "\n"
            . "初始口令  : " . $plain . "\n"
            . "管理令牌  : " . $cfg['admin_token'] . "\n"
            . "生成时间  : " . date('Y-m-d H:i:s') . "\n\n"
            . "安全提示: 登录后请立即修改口令, 并删除本文件!\n";
        @file_put_contents($data . DIRECTORY_SEPARATOR . 'install-info.txt', $info);
        @chmod($data . DIRECTORY_SEPARATOR . 'install-info.txt', 0600);
        vpnx_log('首次初始化完成, 管理信息写入 install-info.txt');
    }

    // 确保基础数据文件存在
    foreach (array('nodes.json', 'users.json', 'subs.json', 'nonces.json') as $f) {
        $p = $data . DIRECTORY_SEPARATOR . $f;
        if (!is_file($p)) {
            $empty = ($f === 'nonces.json') ? array() : array();
            vpnx_json_write($p, $empty);
        }
    }
    return array('created' => $created, 'config' => $cfg);
}

/**
 * 管理 API 的 Bearer token
 */
function vpnx_admin_token()
{
    $cfg = vpnx_config();
    return isset($cfg['admin_token']) ? $cfg['admin_token'] : '';
}

/**
 * 机器接口基址(节点请求的前缀)
 *
 * 未配置 base_url 时自动推断到 api.php 本身, 例如
 *   https://panel.example.com/vpnx/api.php
 * 于是节点请求 https://panel.example.com/vpnx/api.php/api/v1/node/heartbeat
 * 在没有做任何 rewrite 的站点上也能路由成功(PATH_INFO), 并且签名校验通过。
 *
 * 若配置了 base_url(如 https://panel.example.com/vpnx), 则按配置返回,
 * 此时需要站点把 /api/v1/... 与 /sub/... 交给 api.php(见 nginx.conf.example)。
 *
 * @return string 不带末尾斜杠
 */
function vpnx_api_base()
{
    $cfg = vpnx_config();
    if (!empty($cfg['base_url'])) {
        return rtrim($cfg['base_url'], '/');
    }
    $scheme = 'http';
    if (!empty($_SERVER['HTTPS']) && strtolower($_SERVER['HTTPS']) !== 'off') {
        $scheme = 'https';
    } elseif (!empty($_SERVER['HTTP_X_FORWARDED_PROTO'])) {
        $scheme = strtolower($_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https' ? 'https' : 'http';
    }
    $host = isset($_SERVER['HTTP_HOST']) ? $_SERVER['HTTP_HOST'] : '127.0.0.1';
    $dir = dirname(isset($_SERVER['SCRIPT_NAME']) ? $_SERVER['SCRIPT_NAME'] : '/');
    $dir = rtrim(str_replace('\\', '/', $dir), '/');
    return $scheme . '://' . $host . $dir . '/api.php';
}

/**
 * 机器接口地址(按基址形态自动选择请求方式)
 *
 * 基址以 .php 结尾 -> 查询参数模式: https://面板/vpn/api.php?__vpnx=/sub/<token>
 *   (不需要任何 rewrite, 也不怕主机拦截 .php 后面的附加路径)
 * 基址是干净地址   -> PATH_INFO 模式: https://面板/vpn/sub/<token>
 *   (需要按 nginx.conf.example 配 rewrite)
 *
 * @param string $path 形如 /api/v1/node/heartbeat 或 /sub/<token>
 * @return string
 */
function vpnx_machine_url($path)
{
    $base = vpnx_api_base();
    if (substr($base, -4) === '.php') {
        return vpnx_url_add_query($base, '__vpnx=' . $path);
    }
    return $base . $path;
}

/**
 * 站点基址(去掉末尾斜杠), 未配置时按当前请求推断
 */
function vpnx_base_url()
{
    $cfg = vpnx_config();
    if (!empty($cfg['base_url'])) {
        return rtrim($cfg['base_url'], '/');
    }
    $scheme = 'http';
    if (!empty($_SERVER['HTTPS']) && strtolower($_SERVER['HTTPS']) !== 'off') {
        $scheme = 'https';
    } elseif (!empty($_SERVER['HTTP_X_FORWARDED_PROTO'])) {
        $scheme = strtolower($_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https' ? 'https' : 'http';
    }
    $host = isset($_SERVER['HTTP_HOST']) ? $_SERVER['HTTP_HOST'] : '127.0.0.1';
    $dir = dirname(isset($_SERVER['SCRIPT_NAME']) ? $_SERVER['SCRIPT_NAME'] : '/');
    $dir = rtrim(str_replace('\\', '/', $dir), '/');
    return $scheme . '://' . $host . $dir;
}
