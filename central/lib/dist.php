<?php
/**
 * 节点安装包分发(中台托管 vpn.zip)
 *
 * 目标: "上传中台 -> 节点一条命令安装" 成为唯一流程。
 *   - dist/  : 随中台包一起发布的内置节点包(优先只读)
 *   - data/dist/ : 后台页面上传的节点包(持久, 更新中台不会丢)
 *   两个目录都找, data/dist 优先。
 *
 * 安全: 只允许 dist/ 与 data/dist/ 下、文件名匹配白名单的 .zip;
 *       任何路径穿越(basename 不等)一律拒绝。
 */

function vpnx_dist_dirs()
{
    return array(
        vpnx_data_dir() . DIRECTORY_SEPARATOR . 'dist',   // 上传的(优先)
        dirname(__DIR__) . DIRECTORY_SEPARATOR . 'dist',  // 随包内置
    );
}

function vpnx_dist_name_ok($name)
{
    $name = (string) $name;
    if ($name === '' || $name !== basename($name)) {
        return false;
    }
    return (bool) preg_match('/^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$/', $name);
}

function vpnx_dist_find($name)
{
    if (!vpnx_dist_name_ok($name)) {
        return null;
    }
    foreach (vpnx_dist_dirs() as $d) {
        $p = $d . DIRECTORY_SEPARATOR . $name;
        if (is_file($p)) {
            return $p;
        }
    }
    return null;
}

/** @return array 包信息列表(name/size/mtime/sha256/source) */
function vpnx_dist_list()
{
    $out = array();
    $seen = array();
    $dirs = vpnx_dist_dirs();
    foreach ($dirs as $i => $d) {
        if (!is_dir($d)) {
            continue;
        }
        $files = glob($d . DIRECTORY_SEPARATOR . '*.zip');
        if (!is_array($files)) {
            continue;
        }
        foreach ($files as $p) {
            $n = basename($p);
            if (!is_file($p) || !vpnx_dist_name_ok($n) || isset($seen[$n])) {
                continue;
            }
            $seen[$n] = 1;
            $out[] = array(
                'name' => $n,
                'size' => (int) filesize($p),
                'mtime' => (int) filemtime($p),
                'sha256' => (string) @hash_file('sha256', $p),
                'source' => $i === 0 ? 'upload' : 'builtin',
            );
        }
    }
    return $out;
}

/** 默认要分发的包名(vpn.zip 优先, 否则第一个) */
function vpnx_dist_default_name()
{
    $list = vpnx_dist_list();
    foreach ($list as $x) {
        if ($x['name'] === 'vpn.zip') {
            return 'vpn.zip';
        }
    }
    return $list ? $list[0]['name'] : '';
}

/** dist.php 的地址(与 api.php 同级) */
function vpnx_dist_script_url()
{
    $base = vpnx_api_base();
    if (preg_match('#/api\.php$#', $base)) {
        return preg_replace('#/api\.php$#', '/dist.php', $base);
    }
    return rtrim($base, '/') . '/dist.php';
}

function vpnx_dist_download_url($name)
{
    return vpnx_dist_script_url() . '?f=' . rawurlencode($name);
}

/**
 * 保存上传的节点包(默认名 vpn.zip), 存到 data/dist/
 *
 * @param array  $file    $_FILES 里的条目
 * @param string $wantName 目标文件名
 * @return array ok/error/name/size/sha256
 */
function vpnx_dist_upload($file, $wantName = 'vpn.zip')
{
    if (!is_array($file) || !isset($file['tmp_name'])) {
        return array('ok' => false, 'error' => '没有收到文件(检查表单 enctype 与 upload_max_filesize)');
    }
    if ((int) $file['error'] !== UPLOAD_ERR_OK) {
        $map = array(
            UPLOAD_ERR_INI_SIZE => '超过 php.ini 的 upload_max_filesize',
            UPLOAD_ERR_FORM_SIZE => '超过表单 MAX_FILE_SIZE',
            UPLOAD_ERR_PARTIAL => '只上传了一部分',
            UPLOAD_ERR_NO_FILE => '没有选择文件',
            UPLOAD_ERR_NO_TMP_DIR => '缺少临时目录',
            UPLOAD_ERR_CANT_WRITE => '写入失败(磁盘权限)',
            UPLOAD_ERR_EXTENSION => '被 PHP 扩展中断',
        );
        $code = (int) $file['error'];
        return array('ok' => false, 'error' => isset($map[$code]) ? $map[$code] : ('上传错误码 ' . $code));
    }
    $name = $wantName === '' ? 'vpn.zip' : basename($wantName);
    if (!vpnx_dist_name_ok($name)) {
        return array('ok' => false, 'error' => '文件名不合法(只允许字母数字与 . _ - , 且以 .zip 结尾)');
    }
    if (!is_uploaded_file($file['tmp_name'])) {
        return array('ok' => false, 'error' => '临时文件校验失败');
    }
    if (class_exists('ZipArchive')) {
        $z = new ZipArchive();
        if ($z->open($file['tmp_name']) !== true) {
            return array('ok' => false, 'error' => '不是有效的 zip 包');
        }
        $z->close();
    }
    $dir = vpnx_data_dir() . DIRECTORY_SEPARATOR . 'dist';
    if (!is_dir($dir) && !@mkdir($dir, 0700, true)) {
        return array('ok' => false, 'error' => '无法创建 data/dist 目录');
    }
    $dest = $dir . DIRECTORY_SEPARATOR . $name;
    if (!@move_uploaded_file($file['tmp_name'], $dest)) {
        return array('ok' => false, 'error' => '保存失败(检查 data/dist 权限)');
    }
    @chmod($dest, 0600);
    return array('ok' => true, 'name' => $name, 'size' => (int) filesize($dest), 'sha256' => (string) @hash_file('sha256', $dest));
}

function vpnx_dist_delete($name)
{
    $dir = vpnx_data_dir() . DIRECTORY_SEPARATOR . 'dist';
    $p = $dir . DIRECTORY_SEPARATOR . basename((string) $name);
    if (!vpnx_dist_name_ok($name) || !is_file($p)) {
        return array('ok' => false, 'error' => '包不存在(内置包不能删除)');
    }
    return @unlink($p) ? array('ok' => true) : array('ok' => false, 'error' => '删除失败');
}

/** 人类可读大小 */
function vpnx_dist_size_text($bytes)
{
    $b = (float) $bytes;
    if ($b >= 1048576) {
        return sprintf('%.1f MB', $b / 1048576);
    }
    if ($b >= 1024) {
        return sprintf('%.1f KB', $b / 1024);
    }
    return ((int) $b) . ' B';
}

/**
 * 节点侧命令
 *
 * @param array  $node  节点记录(需要 id/secret)
 * @param string $kind  install|update|verify
 * @param string $pkg   包名
 * @param string $profiles 协议档位
 * @return string
 */
function vpnx_dist_command($node, $kind, $pkg, $profiles = 'reality,ss2022,vmess-ws,xhttp')
{
    $url = vpnx_dist_download_url($pkg);
    $dl = 'curl -fsSL "' . $url . '" -o /tmp/vpn.zip && rm -rf /tmp/vpnnew && mkdir -p /tmp/vpnnew && unzip -oq /tmp/vpn.zip -d /tmp/vpnnew';
    if ($kind === 'update') {
        return $dl . ' && \\cp -f /tmp/vpnnew/vpnx.sh /usr/local/vpnx/'
            . ' && \\cp -rf /tmp/vpnnew/lib /tmp/vpnnew/tools /tmp/vpnnew/tests /usr/local/vpnx/'
            . ' && vpnx version';
    }
    if ($kind === 'verify') {
        return 'vpnx agent test && vpnx selftest && vpnx health check';
    }
    $api = vpnx_api_base();
    $id = isset($node['id']) ? $node['id'] : '';
    $secret = isset($node['secret']) ? $node['secret'] : '';
    return $dl . ' && cd /tmp/vpnnew && bash vpnx.sh install --profiles ' . $profiles
        . ($api !== '' ? ' --central-url ' . $api : '')
        . ($id !== '' ? ' --node-id ' . $id : '')
        . ($secret !== '' ? ' --token ' . $secret : '');
}

/** 取指定包的信息(不存在返回 null) */
function vpnx_dist_pick($name)
{
    foreach (vpnx_dist_list() as $x) {
        if ($x['name'] === (string) $name) {
            return $x;
        }
    }
    return null;
}

/** 从节点包里读出 build 号(读不出返回空串) */
function vpnx_dist_build($name)
{
    $p = vpnx_dist_find($name);
    if ($p === null || !class_exists('ZipArchive')) {
        return '';
    }
    $z = new ZipArchive();
    if ($z->open($p) !== true) {
        return '';
    }
    $src = $z->getFromName('vpnx.sh');
    $z->close();
    if (!is_string($src) || $src === '') {
        return '';
    }
    if (preg_match('/VPNX_BUILD="([^"]+)"/', $src, $m)) {
        return $m[1];
    }
    return '';
}