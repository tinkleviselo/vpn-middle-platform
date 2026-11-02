<?php
/**
 * 节点安装包下载端点(与 api.php 同级)
 *
 *   GET dist.php?f=vpn.zip
 *
 * 只允许访问 data/dist/ 与 dist/ 下的 .zip; 拒绝任何路径穿越。
 * 包里不含任何密钥(节点 token 不写在包里), 因此默认允许匿名下载;
 * 如需限制, 可在站点层给 dist.php 加访问控制。
 */
require_once __DIR__ . '/lib/util.php';
require_once __DIR__ . '/lib/config.php';
require_once __DIR__ . '/lib/dist.php';

$name = isset($_GET['f']) ? (string) $_GET['f'] : '';
if ($name === '') {
    $name = vpnx_dist_default_name();
}
$path = vpnx_dist_find($name);
if ($path === null) {
    header('HTTP/1.1 404 Not Found');
    header('Content-Type: text/plain; charset=utf-8');
    echo "package not found\n";
    echo "请在中台「节点安装」页上传节点包(vpn.zip), 或确认文件名\n";
    exit;
}

$size = (int) filesize($path);
header('Content-Type: application/zip');
header('Content-Length: ' . $size);
header('Content-Disposition: attachment; filename="' . basename($path) . '"');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

while (ob_get_level() > 0) {
    ob_end_clean();
}
readfile($path);