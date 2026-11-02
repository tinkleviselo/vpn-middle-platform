<?php
/**
 * vpnx 中台 - 管理后台(PHP + JSON, 无数据库)
 *
 * 页面:
 *   ?p=overview  概览(节点在线/策略进度/账号统计)
 *   ?p=nodes     节点管理(注册/标签/参数/密钥/接入命令)
 *   ?p=users     账号管理(创建并在"哪些服务器"上生效)
 *   ?p=subs      订阅清单
 *   ?p=settings  中台设置(基址/档位/节点默认参数/改口令)
 *   ?p=audit     审计日志
 */

require_once __DIR__ . '/lib/util.php';
require_once __DIR__ . '/lib/config.php';
require_once __DIR__ . '/lib/store.php';
require_once __DIR__ . '/lib/auth.php';
require_once __DIR__ . '/lib/policy.php';
require_once __DIR__ . '/lib/sub.php';
require_once __DIR__ . '/lib/views.php';
require_once __DIR__ . '/lib/dist.php';

vpnx_bootstrap();

/**
 * 取 POST 里的数组字段
 */
function vpnx_post_array($key)
{
    if (!isset($_POST[$key])) {
        return array();
    }
    $v = $_POST[$key];
    return is_array($v) ? $v : array($v);
}

/**
 * 取 POST 字符串字段
 */
function vpnx_post_str($key, $default = '')
{
    return isset($_POST[$key]) ? trim((string) $_POST[$key]) : $default;
}

/**
 * 设置一次性提示
 */
function vpnx_flash($message, $type = 'ok')
{
    vpnx_session_start();
    $_SESSION['vpnx_flash'] = array('message' => $message, 'type' => $type);
}

/**
 * 取出提示
 */
function vpnx_flash_take()
{
    vpnx_session_start();
    if (empty($_SESSION['vpnx_flash'])) {
        return null;
    }
    $f = $_SESSION['vpnx_flash'];
    unset($_SESSION['vpnx_flash']);
    return $f;
}

$action = isset($_POST['action']) ? (string) $_POST['action'] : (isset($_GET['action']) ? (string) $_GET['action'] : '');

// ---------------------------------------------------------------------------
// 登出
// ---------------------------------------------------------------------------
if ($action === 'logout') {
    vpnx_admin_logout();
    header('Location: index.php');
    exit;
}

// ---------------------------------------------------------------------------
// 登录
// ---------------------------------------------------------------------------
if (!vpnx_admin_logged_in()) {
    if ($action === 'login') {
        if (!vpnx_csrf_check(vpnx_post_str('_csrf'))) {
            vpnx_flash('会话已过期, 请重试', 'err');
        } elseif (vpnx_admin_login(vpnx_post_str('user'), isset($_POST['pass']) ? (string) $_POST['pass'] : '')) {
            vpnx_flash('登录成功');
            header('Location: index.php');
            exit;
        } else {
            vpnx_flash('账号或口令不正确', 'err');
            vpnx_log('后台登录失败 user=' . vpnx_post_str('user'));
        }
    }
    $cfg = vpnx_config();
    $hasInfoFile = is_file(vpnx_data_dir() . DIRECTORY_SEPARATOR . 'install-info.txt');
    ?>
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>登录 - <?php echo vpnx_h($cfg['site_name']); ?></title>
<style>
body{font-family:-apple-system,"Segoe UI",Roboto,"Helvetica Neue","Microsoft YaHei",sans-serif;background:#0f172a;color:#e2e8f0;margin:0;display:flex;align-items:center;justify-content:center;min-height:100vh}
.box{background:#1e293b;padding:28px 32px;border-radius:12px;width:340px;box-shadow:0 10px 30px rgba(0,0,0,.4)}
h1{font-size:18px;margin:0 0 18px}
label{display:block;font-size:13px;color:#94a3b8;margin:12px 0 4px}
input{width:100%;box-sizing:border-box;padding:9px 10px;border-radius:8px;border:1px solid #334155;background:#0f172a;color:#e2e8f0}
button{width:100%;margin-top:18px;padding:10px;border:0;border-radius:8px;background:#2563eb;color:#fff;font-size:15px;cursor:pointer}
button:hover{background:#1d4ed8}
.msg{margin-top:14px;font-size:13px;padding:8px 10px;border-radius:8px}
.ok{background:#064e3b;color:#6ee7b7}.err{background:#7f1d1d;color:#fecaca}
.tip{margin-top:14px;font-size:12px;color:#94a3b8;line-height:1.6}
code{background:#0f172a;padding:1px 4px;border-radius:4px}
</style>
</head>
<body>
<div class="box">
  <h1><?php echo vpnx_h($cfg['site_name']); ?></h1>
  <?php $f = vpnx_flash_take(); if ($f) { ?>
    <div class="msg <?php echo vpnx_h($f['type']); ?>"><?php echo vpnx_h($f['message']); ?></div>
  <?php } ?>
  <form method="post" action="index.php">
    <input type="hidden" name="action" value="login">
    <input type="hidden" name="_csrf" value="<?php echo vpnx_h(vpnx_csrf_token()); ?>">
    <label>管理员</label>
    <input type="text" name="user" value="<?php echo vpnx_h($cfg['admin_user']); ?>" autocomplete="username">
    <label>口令</label>
    <input type="password" name="pass" autocomplete="current-password">
    <button type="submit">登录</button>
  </form>
  <?php if ($hasInfoFile) { ?>
    <div class="tip">首次部署: 初始口令与管理令牌写在 <code>data/install-info.txt</code>, 登录后请修改口令并删除该文件。</div>
  <?php } ?>
</div>
</body>
</html>
    <?php
    exit;
}

// ---------------------------------------------------------------------------
// 已登录: 处理动作(全部要求 CSRF)
// ---------------------------------------------------------------------------
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action !== '') {
    if (!vpnx_csrf_check(vpnx_post_str('_csrf'))) {
        vpnx_flash('CSRF 校验失败, 请重试', 'err');
        header('Location: index.php');
        exit;
    }
    $lock = vpnx_lock();
    $result = null;

    if ($action === 'node_add') {
        $result = vpnx_node_add(
            vpnx_post_str('node_id'),
            vpnx_post_str('name'),
            vpnx_post_str('ip'),
            vpnx_post_array('tags')
        );
        if (!empty($result['ok'])) {
            vpnx_flash('节点已注册: ' . $result['node']['id'] . ' (密钥只显示一次, 见节点列表)');
        }
    } elseif ($action === 'node_update') {
        // 端口: 留空表示不改, 填了才覆盖(需要把已有值取出来合并, 否则会被清空)
        $curNode = vpnx_node_get(vpnx_post_str('id'));
        $ports = (is_array($curNode) && isset($curNode['settings']['ports']) && is_array($curNode['settings']['ports']))
            ? $curNode['settings']['ports'] : array();
        foreach (array('reality', 'ss', 'vmess', 'xhttp') as $pn) {
            $pv = vpnx_post_str('ports_' . $pn);
            if ($pv !== '') {
                $ports[$pn] = (int) $pv;
            }
        }
        $result = vpnx_node_update(vpnx_post_str('id'), array(
            'name' => vpnx_post_str('name'),
            'ip' => vpnx_post_str('ip'),
            'tags' => vpnx_post_array('tags'),
            'settings' => array(
                'reality_target' => vpnx_post_str('reality_target'),
                'reality_server_names' => vpnx_post_str('reality_server_names'),
                'log_level' => vpnx_post_str('log_level'),
                'bbr' => vpnx_post_str('bbr') === '1',
                'ports' => $ports,
            ),
        ));
        if (!empty($result['ok'])) {
            vpnx_flash('节点已更新: ' . vpnx_post_str('id') . '（端口变更会在节点下次同步时生效并自动重启内核、补放行）');
        }
    } elseif ($action === 'node_delete') {
        $result = vpnx_node_delete(vpnx_post_str('id'));
        if (!empty($result['ok'])) {
            vpnx_flash('节点已删除: ' . vpnx_post_str('id'));
        }
    } elseif ($action === 'node_rotate') {
        $result = vpnx_node_rotate(vpnx_post_str('id'));
        if (!empty($result['ok'])) {
            vpnx_flash('已轮换密钥, 新密钥: ' . $result['secret'] . ' (请立刻更新节点配置)');
        }
    } elseif ($action === 'user_add') {
        $result = vpnx_user_add(array(
            'name' => vpnx_post_str('name'),
            'expire_at' => vpnx_post_str('expire_at'),
            'quota_bytes' => vpnx_post_str('quota_bytes'),
            'max_devices' => vpnx_post_str('max_devices'),
            'protocols' => vpnx_post_array('protocols'),
            'nodes' => vpnx_post_array('nodes'),
            'tags' => vpnx_post_array('tags'),
            'note' => vpnx_post_str('note'),
        ));
        if (!empty($result['ok'])) {
            $v = vpnx_admin_user_view($result['user']);
            vpnx_flash('账号已创建: ' . $v['name'] . ' -> 同步到 ' . (count($v['nodes_resolved']) ? implode(', ', $v['nodes_resolved']) : '无节点')
                . '; 订阅: ' . $v['sub_url']);
        }
    } elseif ($action === 'user_update') {
        $result = vpnx_user_update(vpnx_post_str('name'), array(
            'expire_at' => vpnx_post_str('expire_at'),
            'quota_bytes' => vpnx_post_str('quota_bytes'),
            'max_devices' => vpnx_post_str('max_devices'),
            'protocols' => vpnx_post_array('protocols'),
            'nodes' => vpnx_post_array('nodes'),
            'tags' => vpnx_post_array('tags'),
            'note' => vpnx_post_str('note'),
        ));
        if (!empty($result['ok'])) {
            vpnx_flash('账号已更新: ' . vpnx_post_str('name'));
        }
    } elseif ($action === 'user_delete') {
        $result = vpnx_user_delete(vpnx_post_str('name'));
        if (!empty($result['ok'])) {
            vpnx_flash('账号已删除: ' . vpnx_post_str('name') . ' (已向相关节点下发删除)');
        }
    } elseif ($action === 'user_reset') {
        $result = vpnx_user_reset(vpnx_post_str('name'), vpnx_post_str('traffic_only') === '1');
        if (!empty($result['ok'])) {
            vpnx_flash('账号已重置: ' . vpnx_post_str('name'));
        }
    } elseif ($action === 'user_toggle') {
        $enable = vpnx_post_str('enabled') === '1';
        $result = vpnx_user_set_enabled(vpnx_post_str('name'), $enable, 'manual');
        if (!empty($result['ok'])) {
            vpnx_flash('账号已' . ($enable ? '启用' : '停用') . ': ' . vpnx_post_str('name'));
        }
    } elseif ($action === 'enforce') {
        $r = vpnx_enforce(true);
        vpnx_flash('已执行到期/配额检查, 停用 ' . count($r['disabled']) . ' 个账号');
        $result = array('ok' => true);
    } elseif ($action === 'settings_save') {
        $cfg = vpnx_config();
        $cfg['site_name'] = vpnx_post_str('site_name', $cfg['site_name']);
        $cfg['base_url'] = rtrim(vpnx_post_str('base_url'), '/');
        $cfg['sub_interval'] = (int) vpnx_post_str('sub_interval', (string) $cfg['sub_interval']);
        $cfg['allow_protocols'] = vpnx_normalize_protocols(vpnx_post_array('allow_protocols'));
        if (!$cfg['allow_protocols']) {
            $cfg['allow_protocols'] = array('vless-reality');
        }
        $cfg['node_defaults']['reality_target'] = vpnx_post_str('reality_target', $cfg['node_defaults']['reality_target']);
        $sni = vpnx_post_str('reality_server_names');
        if ($sni !== '') {
            $cfg['node_defaults']['reality_server_names'] = array_values(array_filter(preg_split('/[\s,]+/', $sni)));
        }
        $cfg['node_defaults']['log_level'] = vpnx_post_str('log_level', $cfg['node_defaults']['log_level']);
        $cfg['node_defaults']['bbr'] = vpnx_post_str('bbr') === '1';
        if (isset($cfg['profiles']['std']['params'])) {
            $cfg['profiles']['std']['params']['flow'] = vpnx_post_str('flow', 'xtls-rprx-vision');
            $cfg['profiles']['std']['params']['fingerprint'] = vpnx_post_str('fingerprint', 'chrome');
            $cfg['profiles']['std']['params']['spider_x'] = vpnx_post_str('spider_x', '/');
        }
        $ssMethod = vpnx_post_str('ss_method');
        if ($ssMethod !== '' && isset($cfg['profiles']['ss']['params'])) {
            $cfg['profiles']['ss']['params']['method'] = $ssMethod;
        }
        if (isset($cfg['profiles']['ws']['params'])) {
            $cfg['profiles']['ws']['params']['path'] = vpnx_post_str('ws_path', '/vpnx-ws');
        }
        vpnx_config_save($cfg);
        vpnx_audit('admin', 'settings_save', 'site=' . $cfg['site_name']);
        vpnx_flash('设置已保存(节点将在下次轮询时收到新档位)');
        $result = array('ok' => true);
    } elseif ($action === 'dist_upload') {
        $want = vpnx_post_str('pkgname');
        $r = vpnx_dist_upload(isset($_FILES['pkg']) ? $_FILES['pkg'] : null, $want === '' ? 'vpn.zip' : $want);
        if (!empty($r['ok'])) {
            vpnx_flash('节点包已上传: ' . $r['name'] . '（' . vpnx_dist_size_text($r['size']) . '，sha256 ' . substr($r['sha256'], 0, 16) . '…）');
        } else {
            vpnx_flash('上传失败: ' . (isset($r['error']) ? $r['error'] : '未知错误'), 'warn');
        }
    } elseif ($action === 'upgrade_push' || $action === 'upgrade_push_all') {
        $pkg = vpnx_post_str('pkg');
        if ($pkg === '') { $pkg = vpnx_dist_default_name(); }
        $info = vpnx_dist_pick($pkg);
        if ($info === null) {
            vpnx_flash('节点包不存在: ' . $pkg . '（请先在上方上传）', 'warn');
        } else {
            $targets = array();
            if ($action === 'upgrade_push_all') {
                foreach (vpnx_nodes_load() as $id => $n) { $targets[] = $id; }
            } else {
                $targets[] = vpnx_post_str('node');
            }
            $bld = vpnx_dist_build($info['name']);
            $patch = array(
                'upgrade_build' => $bld,
                'upgrade_url' => vpnx_dist_download_url($info['name']),
                'upgrade_sha256' => $info['sha256'],
                'upgrade_at' => vpnx_now(),
            );
            $n = 0;
            foreach ($targets as $tid) {
                if ($tid === '' || !vpnx_node_get($tid)) { continue; }
                vpnx_node_update($tid, $patch);
                $n++;
            }
            if ($n > 0) {
                vpnx_flash('已向 ' . $n . ' 个节点推送升级：' . $info['name']
                    . ($bld !== '' ? '（build ' . $bld . '）' : '') . '，节点会在 60 秒内自动下载、校验并升级');
            } else {
                vpnx_flash('没有匹配的节点', 'warn');
            }
        }
    } elseif ($action === 'upgrade_clear') {
        $tid = vpnx_post_str('node');
        if ($tid !== '' && vpnx_node_get($tid)) {
            vpnx_node_update($tid, array('upgrade_build' => '', 'upgrade_url' => '', 'upgrade_sha256' => '', 'upgrade_at' => 0));
            vpnx_flash('已取消节点 ' . $tid . ' 的待升级指令');
        } else {
            vpnx_flash('节点不存在: ' . $tid, 'warn');
        }
    } elseif ($action === 'dist_delete') {
        $r = vpnx_dist_delete(vpnx_post_str('pkgname'));
        vpnx_flash(!empty($r['ok']) ? '已删除该节点包' : ('删除失败: ' . (isset($r['error']) ? $r['error'] : '未知错误')), !empty($r['ok']) ? 'ok' : 'warn');
    } elseif ($action === 'password') {
        $result = vpnx_change_password(
            isset($_POST['old_pass']) ? (string) $_POST['old_pass'] : '',
            isset($_POST['new_pass']) ? (string) $_POST['new_pass'] : ''
        );
        if (!empty($result['ok'])) {
            vpnx_flash('口令已修改, 管理令牌也已轮换(API 调用方需更新 token)', 'ok');
        }
    }

    if (is_array($result) && empty($result['ok'])) {
        vpnx_flash('操作失败: ' . $result['error'], 'err');
    }
    vpnx_unlock($lock);
    header('Location: index.php' . (isset($_POST['_p']) ? '?p=' . urlencode($_POST['_p']) : ''));
    exit;
}

// ---------------------------------------------------------------------------
// 页面数据
// ---------------------------------------------------------------------------
$page = isset($_GET['p']) ? (string) $_GET['p'] : 'overview';
$allowedPages = array('overview', 'nodes', 'users', 'subs', 'settings', 'audit');
if (!in_array($page, $allowedPages, true)) {
    $page = 'overview';
}

$cfg = vpnx_config();
$stats = vpnx_stats();
$flash = vpnx_flash_take();
$csrf = vpnx_csrf_token();
$baseUrl = vpnx_api_base();
$profileUrl = 'index.php';
?>
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?php echo vpnx_h($cfg['site_name']); ?> - 控制台</title>
<style>
*{box-sizing:border-box}
body{font-family:-apple-system,"Segoe UI",Roboto,"Helvetica Neue","Microsoft YaHei",sans-serif;background:#0f172a;color:#e2e8f0;margin:0;font-size:14px}
a{color:#60a5fa;text-decoration:none}a:hover{text-decoration:underline}
header{background:#1e293b;padding:12px 20px;display:flex;align-items:center;gap:18px;border-bottom:1px solid #334155;flex-wrap:wrap}
header h1{font-size:16px;margin:0}
nav a{padding:6px 10px;border-radius:6px;color:#cbd5e1}
nav a.on{background:#2563eb;color:#fff}
main{padding:20px;max-width:1400px;margin:0 auto}
.cards{display:flex;gap:14px;flex-wrap:wrap;margin-bottom:18px}
.card{background:#1e293b;border:1px solid #334155;border-radius:10px;padding:14px 18px;min-width:150px}
.card .k{color:#94a3b8;font-size:12px}.card .v{font-size:22px;font-weight:600;margin-top:4px}
table{width:100%;border-collapse:collapse;background:#1e293b;border-radius:10px;overflow:hidden}
th,td{padding:9px 10px;text-align:left;border-bottom:1px solid #334155;vertical-align:top}
th{background:#172033;color:#94a3b8;font-size:12px;font-weight:600}
tr:last-child td{border-bottom:0}
code{background:#0f172a;padding:1px 5px;border-radius:4px;font-size:12px}
pre{background:#0f172a;padding:10px;border-radius:8px;overflow:auto;font-size:12px;border:1px solid #334155}
.badge{display:inline-block;padding:1px 7px;border-radius:999px;font-size:11px}
.b-ok{background:#064e3b;color:#6ee7b7}.b-warn{background:#78350f;color:#fcd34d}
.b-err{background:#7f1d1d;color:#fecaca}.b-off{background:#334155;color:#cbd5e1}
form.inline{display:inline}
input,select,textarea{background:#0f172a;border:1px solid #334155;color:#e2e8f0;border-radius:7px;padding:7px 9px;font-size:13px;max-width:100%}
button{background:#2563eb;border:0;color:#fff;padding:7px 13px;border-radius:7px;cursor:pointer;font-size:13px}
button:hover{background:#1d4ed8}
button.ghost{background:#334155}button.ghost:hover{background:#475569}
button.danger{background:#b91c1c}button.danger:hover{background:#991b1b}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:10px}
.label{color:#94a3b8;font-size:12px;display:block;margin-bottom:3px}
.panel{background:#1e293b;border:1px solid #334155;border-radius:10px;padding:16px;margin-bottom:18px}
.msg{padding:9px 12px;border-radius:8px;margin-bottom:14px}
.m-ok{background:#064e3b;color:#6ee7b7}.m-err{background:#7f1d1d;color:#fecaca}
.chk{display:inline-flex;align-items:center;gap:5px;margin:0 12px 6px 0;font-size:13px}
.small{font-size:12px;color:#94a3b8}
.nowrap{white-space:nowrap}
</style>
</head>
<body>
<header>
  <h1><?php echo vpnx_h($cfg['site_name']); ?></h1>
  <nav>
    <a class="<?php echo $page === 'overview' ? 'on' : ''; ?>" href="?p=overview">概览</a>
    <a class="<?php echo $page === 'nodes' ? 'on' : ''; ?>" href="?p=nodes">节点</a>
    <a class="<?php echo $page === 'install' ? 'on' : ''; ?>" href="?p=install">节点安装</a>
    <a class="<?php echo $page === 'users' ? 'on' : ''; ?>" href="?p=users">账号</a>
    <a class="<?php echo $page === 'subs' ? 'on' : ''; ?>" href="?p=subs">订阅</a>
    <a class="<?php echo $page === 'settings' ? 'on' : ''; ?>" href="?p=settings">设置</a>
    <a class="<?php echo $page === 'audit' ? 'on' : ''; ?>" href="?p=audit">审计</a>
  </nav>
  <span class="small" style="margin-left:auto"><?php echo vpnx_h(vpnx_current_admin()); ?> · <a href="?action=logout">退出</a></span>
</header>
<main>
<?php if ($flash) { ?>
  <div class="msg <?php echo $flash['type'] === 'err' ? 'm-err' : 'm-ok'; ?>"><?php echo vpnx_h($flash['message']); ?></div>
<?php } ?>

<?php if ($page === 'overview') { ?>
  <div class="cards">
    <div class="card"><div class="k">节点</div><div class="v"><?php echo (int) $stats['nodes_online']; ?> / <?php echo (int) $stats['nodes']; ?></div><div class="small">在线 / 总数</div></div>
    <div class="card"><div class="k">账号</div><div class="v"><?php echo (int) $stats['users_enabled']; ?> / <?php echo (int) $stats['users']; ?></div><div class="small">启用 / 总数</div></div>
    <div class="card"><div class="k">流量</div><div class="v"><?php echo vpnx_h(vpnx_fmt_bytes($stats['traffic_up'] + $stats['traffic_down'])); ?></div><div class="small">↑<?php echo vpnx_h(vpnx_fmt_bytes($stats['traffic_up'])); ?> ↓<?php echo vpnx_h(vpnx_fmt_bytes($stats['traffic_down'])); ?></div></div>
    <div class="card"><div class="k">订阅</div><div class="v"><?php echo (int) $stats['subs']; ?></div><div class="small">已发布 token</div></div>
  </div>

  <div class="panel">
    <h3 style="margin-top:0">节点状态与策略进度</h3>
    <table>
      <tr><th>节点</th><th>状态</th><th>已发布/已应用</th><th>账号</th><th>最近心跳</th></tr>
      <?php foreach (vpnx_admin_nodes_list() as $n) { ?>
      <tr>
        <td><strong><?php echo vpnx_h($n['id']); ?></strong><div class="small"><?php echo vpnx_h($n['name']); ?> <?php echo vpnx_h($n['ip']); ?></div></td>
        <td>
          <?php if ($n['online']) { ?><span class="badge b-ok">在线</span><?php } else { ?><span class="badge b-off">离线</span><?php } ?>
          <?php if ($n['policy']['pending']) { ?> <span class="badge b-warn">待应用</span><?php } ?>
        </td>
        <td><?php echo (int) $n['policy']['published_revision']; ?> / <?php echo (int) $n['policy']['applied_revision']; ?>
          <?php if ($n['policy']['pending_deletes']) { ?><div class="small">待删 <?php echo (int) $n['policy']['pending_deletes']; ?></div><?php } ?>
          <?php if ($n['policy']['last_error'] !== '') { ?><div class="small" style="color:#fca5a5"><?php echo vpnx_h($n['policy']['last_error']); ?></div><?php } ?>
        </td>
        <td><?php echo (int) $n['users']; ?></td>
        <td class="nowrap"><?php echo vpnx_h(vpnx_fmt_time($n['last_seen'])); ?></td>
      </tr>
      <?php } ?>
    </table>
    <form class="inline" method="post" style="margin-top:12px">
      <input type="hidden" name="action" value="enforce"><input type="hidden" name="_csrf" value="<?php echo vpnx_h($csrf); ?>">
      <button class="ghost" type="submit">立即执行到期/配额检查</button>
    </form>
  </div>

<?php } elseif ($page === 'nodes') { ?>
  <div class="panel">
    <h3 style="margin-top:0">注册新节点</h3>
    <form method="post">
      <input type="hidden" name="action" value="node_add"><input type="hidden" name="_csrf" value="<?php echo vpnx_h($csrf); ?>"><input type="hidden" name="_p" value="nodes">
      <div class="grid">
        <div><span class="label">节点 ID(小写字母/数字/._-)</span><input name="node_id" placeholder="hk1" required></div>
        <div><span class="label">显示名</span><input name="name" placeholder="香港-1"></div>
        <div><span class="label">公网 IP(可空)</span><input name="ip" placeholder="1.2.3.4"></div>
        <div><span class="label">标签(逗号分隔, 供账号按标签分发)</span><input name="tags" placeholder="hk,premium"></div>
      </div>
      <p class="small">注册后中台会给出该节点的完整安装/接入命令, 在对应 VPS 上执行即可纳管。</p>
      <button type="submit">注册节点</button>
    </form>
  </div>

  <?php foreach (vpnx_admin_nodes_list() as $n) { ?>
  <div class="panel">
    <h3 style="margin-top:0">
      <?php echo vpnx_h($n['id']); ?> <span class="small"><?php echo vpnx_h($n['name']); ?></span>
      <?php if ($n['online']) { ?><span class="badge b-ok">在线</span><?php } else { ?><span class="badge b-off">离线</span><?php } ?>
      <?php if ($n['policy']['pending']) { ?><span class="badge b-warn">待应用</span><?php } ?>
    </h3>
    <table>
      <tr><th>公网 IP</th><td><?php echo vpnx_h($n['ip']); ?> <span class="small">(节点自报 <?php echo vpnx_h($n['last_ip']); ?>)</span></td>
          <th>最近心跳</th><td><?php echo vpnx_h(vpnx_fmt_time($n['last_seen'])); ?></td></tr>
      <tr><th>内核/系统</th><td><?php echo vpnx_h($n['xray_version']); ?> <span class="small"><?php echo vpnx_h($n['os']); ?></span></td>
          <th>版本进度</th><td>已发布 <?php echo (int) $n['policy']['published_revision']; ?> / 已应用 <?php echo (int) $n['policy']['applied_revision']; ?>
            <?php if ($n['policy']['last_ack_result'] !== '') { ?><span class="small">(<?php echo vpnx_h($n['policy']['last_ack_result']); ?>)</span><?php } ?></td></tr>
      <tr><th>该节点账号数</th><td><?php echo (int) $n['users']; ?></td>
          <th>监听端口</th><td><code><?php echo vpnx_h($n['ports_text']); ?></code>
            <div class="small">云厂商安全组需放行这些端口(中台节点参数里改端口后会自动更新)</div></td></tr>
      <tr><th>标签</th><td colspan="3"><?php echo vpnx_h(implode(', ', $n['tags'])); ?></td></tr>
    </table>

    <p class="small" style="margin:12px 0 6px">全新服务器部署(在 VPS 上执行):</p>
    <pre><?php echo vpnx_h($n['install_command']); ?></pre>
    <p class="small" style="margin:12px 0 6px">脚本已在服务器上, 仅接入中台:</p>
    <pre><?php echo vpnx_h($n['onboard_command']); ?></pre>

    <form method="post" style="margin-top:12px">
      <input type="hidden" name="action" value="node_update"><input type="hidden" name="_csrf" value="<?php echo vpnx_h($csrf); ?>"><input type="hidden" name="_p" value="nodes">
      <input type="hidden" name="id" value="<?php echo vpnx_h($n['id']); ?>">
      <div class="grid">
        <div><span class="label">显示名</span><input name="name" value="<?php echo vpnx_h($n['name']); ?>"></div>
        <div><span class="label">公网 IP</span><input name="ip" value="<?php echo vpnx_h($n['ip']); ?>"></div>
        <div><span class="label">标签</span><input name="tags" value="<?php echo vpnx_h(implode(',', $n['tags'])); ?>"></div>
        <div><span class="label">REALITY 伪装目标</span><input name="reality_target" value="<?php echo vpnx_h(isset($n['settings']['reality_target']) ? $n['settings']['reality_target'] : $cfg['node_defaults']['reality_target']); ?>"></div>
        <div><span class="label">SNI 列表(逗号分隔)</span><input name="reality_server_names" value="<?php echo vpnx_h(isset($n['settings']['reality_server_names']) && is_array($n['settings']['reality_server_names']) ? implode(',', $n['settings']['reality_server_names']) : implode(',', $cfg['node_defaults']['reality_server_names'])); ?>"></div>
        <div><span class="label">日志级别</span><input name="log_level" value="<?php echo vpnx_h(isset($n['settings']['log_level']) ? $n['settings']['log_level'] : $cfg['node_defaults']['log_level']); ?>"></div>
        <?php
        $curPorts = (isset($n['settings']['ports']) && is_array($n['settings']['ports'])) ? $n['settings']['ports'] : array();
        ?>
        <div><span class="label">REALITY 端口(留空不改)</span><input name="ports_reality" placeholder="<?php echo vpnx_h(isset($curPorts['reality']) ? $curPorts['reality'] : '当前端口'); ?>"></div>
        <div><span class="label">SS2022 端口(留空不改)</span><input name="ports_ss" placeholder="<?php echo vpnx_h(isset($curPorts['ss']) ? $curPorts['ss'] : '当前端口'); ?>"></div>
        <div><span class="label">VMess 端口(留空不改)</span><input name="ports_vmess" placeholder="<?php echo vpnx_h(isset($curPorts['vmess']) ? $curPorts['vmess'] : '当前端口'); ?>"></div>
        <div><span class="label">XHTTP 端口(留空不改)</span><input name="ports_xhttp" placeholder="<?php echo vpnx_h(isset($curPorts['xhttp']) ? $curPorts['xhttp'] : '当前端口'); ?>"></div>
        <div><span class="label">BBR</span>
          <select name="bbr">
            <option value="1" <?php echo (!isset($n['settings']['bbr']) || $n['settings']['bbr']) ? 'selected' : ''; ?>>启用</option>
            <option value="0" <?php echo (isset($n['settings']['bbr']) && !$n['settings']['bbr']) ? 'selected' : ''; ?>>关闭</option>
          </select>
        </div>
      </div>
      <p><button type="submit">保存节点参数</button></p>
    </form>
    <form class="inline" method="post" onsubmit="return confirm('轮换密钥后需在节点上更新 token, 确定?')">
      <input type="hidden" name="action" value="node_rotate"><input type="hidden" name="_csrf" value="<?php echo vpnx_h($csrf); ?>"><input type="hidden" name="_p" value="nodes">
      <input type="hidden" name="id" value="<?php echo vpnx_h($n['id']); ?>">
      <button class="ghost" type="submit">轮换密钥</button>
    </form>
    <form class="inline" method="post" onsubmit="return confirm('删除节点会同时清理其策略状态与订阅内容, 确定?')">
      <input type="hidden" name="action" value="node_delete"><input type="hidden" name="_csrf" value="<?php echo vpnx_h($csrf); ?>"><input type="hidden" name="_p" value="nodes">
      <input type="hidden" name="id" value="<?php echo vpnx_h($n['id']); ?>">
      <button class="danger" type="submit">删除节点</button>
    </form>
  </div>
  <?php } ?>

<?php } elseif ($page === 'install') { ?>
  <h2>节点安装（用中台分发的安装包）</h2>
  <p class="small">流程：<b>① 确认/上传节点包 → ② 复制该节点的一条命令 → ③ 到新服务器粘贴执行 → ④ 回来看是否在线 → ⑤ 建账号、分发订阅</b>。<br>
     以后你只管上传中台：<code>central.zip</code> 里已附带最新 <code>vpn.zip</code>，<b>节点侧不需要再手工传任何文件</b>。</p>

  <?php $pkgs = vpnx_dist_list(); $defPkg = vpnx_dist_default_name(); ?>

  <h3>① 节点包</h3>
  <?php if (!$pkgs) { ?>
    <p class="small" style="color:#fcd34d">还没有节点包：在下面上传 <code>vpn.zip</code>，或重新上传带 <code>dist/vpn.zip</code> 的 <code>central.zip</code>。</p>
  <?php } else { ?>
    <table>
      <tr><th>包名</th><th>大小</th><th>来源</th><th>时间</th><th>sha256</th><th>操作</th></tr>
      <?php foreach ($pkgs as $pk) { ?>
      <tr>
        <td><strong><?php echo vpnx_h($pk['name']); ?></strong><?php if ($pk['name'] === $defPkg) { ?> <span class="badge b-ok">默认分发</span><?php } ?></td>
        <td><?php echo vpnx_h(vpnx_dist_size_text($pk['size'])); ?></td>
        <td><?php echo $pk['source'] === 'upload' ? '后台上传' : '随中台包'; ?></td>
        <td class="small"><?php echo vpnx_h(date('Y-m-d H:i', $pk['mtime'])); ?></td>
        <td class="small"><code><?php echo vpnx_h(substr($pk['sha256'], 0, 16)); ?>…</code></td>
        <td class="small">
          <a href="<?php echo vpnx_h(vpnx_dist_download_url($pk['name'])); ?>">下载</a>
          <?php if ($pk['source'] === 'upload') { ?>
          <form method="post" style="display:inline" onsubmit="return confirm('删除该节点包?')">
            <input type="hidden" name="action" value="dist_delete">
            <input type="hidden" name="pkgname" value="<?php echo vpnx_h($pk['name']); ?>">
            <button type="submit">删除</button>
          </form>
          <?php } ?>
        </td>
      </tr>
      <?php } ?>
    </table>
    <p class="small">下载地址：<code><?php echo vpnx_h(vpnx_dist_download_url($defPkg)); ?></code><br>
      包里只有脚本，不含任何密钥（节点 token 不在包里，安装时才由命令传入）。</p>
  <?php } ?>

  <form method="post" enctype="multipart/form-data" style="margin-top:12px">
    <input type="hidden" name="action" value="dist_upload">
    <div><span class="label">上传节点包(.zip)</span><input type="file" name="pkg" accept=".zip"></div>
    <div><span class="label">保存为</span><input name="pkgname" value="vpn.zip"></div>
    <div><button type="submit">上传</button></div>
    <p class="small">上传的包保存在 <code>data/dist/</code>（更新中台不会丢，且优先于内置包分发）；<code>dist/</code> 里的内置包随中台包发布，不能删除。<br>
      若报"超过 upload_max_filesize"，可在面板里调大 PHP 上传上限，或直接把 zip 放进 <code>data/dist/</code>。</p>
  </form>

  <h3>② 安装 / 更新 / 升级命令（按节点复制）</h3>
  <p class="small">也可以不用逐台粘贴：下方「推送升级」会把升级指令写进该节点的策略，节点 60 秒内自动下载新包、校验 sha256、备份后覆盖脚本（<b>不断线、不重启内核</b>，失败会自动放弃并上报）。</p>
  <?php if ($defPkg !== '' && vpnx_admin_nodes_list()) { ?>
  <form method="post" onsubmit="return confirm('向所有节点下发升级指令？')">
    <input type="hidden" name="action" value="upgrade_push_all">
    <input type="hidden" name="pkg" value="<?php echo vpnx_h($defPkg); ?>">
    <button type="submit">推送升级到全部节点（<?php echo vpnx_h($defPkg); ?>）</button>
  </form>
  <?php } ?>
  <?php $instNodes = vpnx_admin_nodes_list(); ?>
  <?php if (!$instNodes) { ?>
    <p class="small">还没有节点：先到「节点」页注册一台（填个名称即可），回到这里就会出现它专属的命令。</p>
  <?php } else { ?>
    <?php foreach ($instNodes as $nd) { ?>
      <div style="border:1px solid #26314a;border-radius:8px;padding:10px;margin:10px 0">
        <div><strong><?php echo vpnx_h($nd['name']); ?></strong>
          <span class="small">id <code><?php echo vpnx_h($nd['id']); ?></code>
            · <?php echo $nd['online'] ? '<span class="badge b-ok">在线</span>' : '<span class="badge b-warn">离线</span>'; ?></span></div>
        <p class="small" style="margin:8px 0 4px">全新服务器（一条命令：下载节点包 → 解压 → 安装并接入中台）：</p>
        <pre><?php echo vpnx_h($nd['install_command']); ?></pre>
        <p class="small" style="margin:8px 0 4px">已装过的节点（只更新脚本，幂等，不影响正在运行的内核）：</p>
        <pre><?php echo vpnx_h($nd['update_command']); ?></pre>

        <?php
        $curBuild = isset($nd['build']) ? (string) $nd['build'] : '';
        $wantBuild = isset($nd['upgrade_build']) ? (string) $nd['upgrade_build'] : '';
        $pkgBuild = ($defPkg !== '' && function_exists('vpnx_dist_build')) ? vpnx_dist_build($defPkg) : '';
        $pending = (isset($nd['upgrade_url']) && $nd['upgrade_url'] !== '');
        ?>
        <p class="small" style="margin:8px 0 4px">
          节点当前版本：<code><?php echo vpnx_h($curBuild === '' ? '未上报' : $curBuild); ?></code>
          · 中台分发包：<code><?php echo vpnx_h($defPkg === '' ? '无' : $defPkg); ?><?php echo $pkgBuild !== '' ? '（build ' . vpnx_h($pkgBuild) . '）' : ''; ?></code>
          <?php if ($pending) { ?>
            · <span class="badge b-warn">已下发升级指令<?php echo $wantBuild !== '' ? '（目标 ' . vpnx_h($wantBuild) . '）' : ''; ?></span>
          <?php } elseif ($pkgBuild !== '' && $curBuild !== '' && $pkgBuild === $curBuild) { ?>
            · <span class="badge b-ok">已是最新</span>
          <?php } ?>
        </p>
        <form method="post" style="display:inline" onsubmit="return confirm('向该节点下发升级指令？节点 60 秒内自动下载、校验 sha256 并升级脚本（不断线、不重启内核）')">
          <input type="hidden" name="action" value="upgrade_push">
          <input type="hidden" name="node" value="<?php echo vpnx_h($nd['id']); ?>">
          <input type="hidden" name="pkg" value="<?php echo vpnx_h($defPkg); ?>">
          <button type="submit">推送升级</button>
        </form>
        <?php if ($pending) { ?>
        <form method="post" style="display:inline">
          <input type="hidden" name="action" value="upgrade_clear">
          <input type="hidden" name="node" value="<?php echo vpnx_h($nd['id']); ?>">
          <button type="submit">取消升级</button>
        </form>
        <?php } ?>
      </div>
    <?php } ?>
    <p class="small" style="color:#fcd34d">命令里带着该节点的 token（等于节点凭证），不要外泄；换机器请到「节点」页轮换密钥。</p>
  <?php } ?>

  <h3>③ 装完怎么确认</h3>
  <pre><?php echo vpnx_h('vpnx agent test && vpnx selftest && vpnx health check'); ?></pre>
  <ol class="small">
    <li><code>vpnx agent test</code>：应显示「中台连通正常」</li>
    <li><code>vpnx selftest</code>：逐协议自测，已启用的协议应逐行「通过」</li>
    <li><code>vpnx health check</code>：有问题会直接给出修复命令</li>
    <li>可选但强烈建议：<code>sudo bash /usr/local/vpnx/tests/server-smoke.sh</code>（70 项断言，改完就跑）</li>
    <li>回「节点」页：该节点应变成 <b>在线</b>，并显示「已应用」的版本进度</li>
  </ol>

  <h3>④ 日常使用逻辑</h3>
  <table>
    <tr><th>想做什么</th><th>在中台哪里做</th><th>节点侧会发生什么</th></tr>
    <tr><td>装一台新节点</td><td>本页复制「全新服务器」命令</td><td>粘贴执行，约 1 分钟内上线</td></tr>
    <tr><td>更新节点脚本（升级脚本/修复）</td><td>本页复制「已装过的节点」命令</td><td>覆盖脚本即可，无需重装、不断线</td></tr>
    <tr><td><b>批量升级节点脚本</b></td><td>本页「推送升级」（单台或全部）</td><td><b>自动</b>下载新包→校验 sha256→备份→覆盖，60 秒内完成；失败自动放弃并上报</td></tr>
    <tr><td>加账号 / 改到期 / 改配额</td><td>「账号」页</td><td>60 秒内自动建号并重推订阅</td></tr>
    <tr><td>改端口 / 伪装站点 / 协议白名单</td><td>「节点」页或「设置」页</td><td>自动重渲染 → 校验 → 重启内核 → 补放行端口</td></tr>
    <tr><td>给客户端订阅</td><td>「账号」页每行的链接</td><td>—</td></tr>
    <tr><td>看用量 / 停用 / 踢下线</td><td>「概览」「账号」「订阅」页</td><td>每 60 秒自动执行配额、到期、设备数检查</td></tr>
  </table>
  <p class="small">客户端与链接对应：<b>base64</b> → Xray 系（v2rayN / 小火箭 / sing-box / NekoBox）；
     <b>clash</b> → mihomo 系（Clash Verge / Clash Meta / FlClash）；<b>XHTTP</b> → 只含 VLESS+XHTTP 节点（需较新客户端）；
     <b>兼容(旧Clash)</b> → 只含 VMess 节点（Clash for Android 等老内核专用）。</p>
<?php } elseif ($page === 'users') { ?>
  <?php $nodes = vpnx_admin_nodes_list(); ?>
  <div class="panel">
    <h3 style="margin-top:0">新建账号(并选择要在哪些服务器上创建)</h3>
    <form method="post">
      <input type="hidden" name="action" value="user_add"><input type="hidden" name="_csrf" value="<?php echo vpnx_h($csrf); ?>"><input type="hidden" name="_p" value="users">
      <div class="grid">
        <div><span class="label">账号名</span><input name="name" placeholder="alice" required></div>
        <div><span class="label">到期(30d / 2026-01-31 / 空=永久)</span><input name="expire_at" placeholder="90d"></div>
        <div><span class="label">流量配额(100G / 空=不限)</span><input name="quota_bytes" placeholder="100G"></div>
        <div><span class="label">设备数上限(0=不限)</span><input name="max_devices" value="0"></div>
        <div><span class="label">备注</span><input name="note"></div>
      </div>
      <p class="small" style="margin:12px 0 4px">协议(中台会按白名单校验, 未启用的协议在节点上会被忽略):</p>
      <div>
        <?php foreach ($cfg['allow_protocols'] as $p) { ?>
          <label class="chk"><input type="checkbox" name="protocols[]" value="<?php echo vpnx_h($p); ?>" <?php echo in_array($p, $cfg['default_protocols'], true) ? 'checked' : ''; ?>> <?php echo vpnx_h($p); ?></label>
        <?php } ?>
      </div>
      <p class="small" style="margin:12px 0 4px">同步到哪些服务器(不选任何节点且不填标签 = 全部节点):</p>
      <div>
        <?php foreach ($nodes as $n) { ?>
          <label class="chk"><input type="checkbox" name="nodes[]" value="<?php echo vpnx_h($n['id']); ?>"> <?php echo vpnx_h($n['id']); ?><?php echo $n['online'] ? '' : '(离线)'; ?></label>
        <?php } ?>
        <?php if (!$nodes) { ?><span class="small">还没有节点, 请先到"节点"页注册</span><?php } ?>
      </div>
      <p class="small" style="margin:8px 0 4px">或按标签圈定(例如 hk / premium):</p>
      <div><input name="tags" placeholder="hk,premium" style="width:260px"></div>
      <p><button type="submit">创建并下发</button></p>
      <p class="small">创建后中台会自动推进相关节点的策略版本; 节点每 60 秒轮询一次, 收到后即在本机创建账号。</p>
    </form>
  </div>

  <div class="panel">
    <h3 style="margin-top:0">账号列表</h3>
    <table>
      <tr>
        <th>账号</th><th>协议</th><th>到期</th><th>用量</th><th>目标节点(策略范围)</th><th>订阅</th><th>操作</th>
      </tr>
      <?php foreach (vpnx_admin_users_list() as $u) { ?>
      <tr>
        <td>
          <strong><?php echo vpnx_h($u['name']); ?></strong>
          <?php if ($u['enabled']) { ?><span class="badge b-ok">启用</span><?php } else { ?><span class="badge b-err">停用<?php echo $u['disabled_reason'] !== '' ? '/' . vpnx_h($u['disabled_reason']) : ''; ?></span><?php } ?>
          <div class="small">UUID <code><?php echo vpnx_h($u['uuid']); ?></code></div>
        </td>
        <td><?php echo vpnx_h(implode(',', $u['protocols'])); ?></td>
        <td class="nowrap"><?php echo vpnx_h($u['expire_text']); ?></td>
        <td class="nowrap"><?php echo vpnx_h($u['used_text']); ?> / <?php echo vpnx_h($u['quota_text']); ?></td>
        <td>
          <?php if ($u['nodes_resolved']) { ?>
            <?php foreach ($u['nodes_resolved'] as $nid) { echo '<span class="badge b-ok">' . vpnx_h($nid) . '</span> '; } ?>
          <?php } else { ?><span class="badge b-warn">未匹配任何节点</span><?php } ?>
          <div class="small"><?php echo vpnx_h($u['nodes'] || $u['tags'] ? ('指定: ' . implode(',', $u['nodes']) . ' 标签: ' . implode(',', $u['tags'])) : '全部节点'); ?></div>
        </td>
        <td class="small">
          <?php if (!empty($u['sub_published'])) { ?>
            <a href="<?php echo vpnx_h($u['sub_url']); ?>" target="_blank">base64</a> ·
            <a href="<?php echo vpnx_h(vpnx_machine_url('/sub/' . $u['sub_token'] . '/clash')); ?>" target="_blank">clash</a> ·
            <a href="<?php echo vpnx_h($u['legacy_url']); ?>" target="_blank" title="只含 VMess 节点，给 Clash for Android 等老内核用">兼容(旧Clash)</a> ·
            <a href="<?php echo vpnx_h($u['xhttp_url']); ?>" target="_blank" title="只含 XHTTP 节点，给支持 XHTTP 的新客户端用">XHTTP</a> ·
            <a href="<?php echo vpnx_h(vpnx_url_add_query($u['sub_url'], 'target=raw')); ?>" target="_blank">raw</a>
          <?php } else { ?>
            <span class="badge b-warn">未发布</span>
            <div class="small">节点还没把订阅内容推上来。等 1 分钟或到「节点」页看该节点是否<b>在线</b>、<br>
              是否显示<b>待应用</b>（节点同步异常时不会有订阅内容）</div>
          <?php } ?>
        </td>
        <td>
          <form class="inline" method="post">
            <input type="hidden" name="action" value="user_toggle"><input type="hidden" name="_csrf" value="<?php echo vpnx_h($csrf); ?>"><input type="hidden" name="_p" value="users">
            <input type="hidden" name="name" value="<?php echo vpnx_h($u['name']); ?>">
            <input type="hidden" name="enabled" value="<?php echo $u['enabled'] ? '0' : '1'; ?>">
            <button class="ghost" type="submit"><?php echo $u['enabled'] ? '停用' : '启用'; ?></button>
          </form>
          <form class="inline" method="post">
            <input type="hidden" name="action" value="user_reset"><input type="hidden" name="_csrf" value="<?php echo vpnx_h($csrf); ?>"><input type="hidden" name="_p" value="users">
            <input type="hidden" name="name" value="<?php echo vpnx_h($u['name']); ?>">
            <button class="ghost" type="submit" onclick="return confirm('重置会更换 UUID/密钥, 客户端需重新导入, 确定?')">重置</button>
          </form>
          <form class="inline" method="post" onsubmit="return confirm('删除账号会向所有相关节点下发删除, 确定?')">
            <input type="hidden" name="action" value="user_delete"><input type="hidden" name="_csrf" value="<?php echo vpnx_h($csrf); ?>"><input type="hidden" name="_p" value="users">
            <input type="hidden" name="name" value="<?php echo vpnx_h($u['name']); ?>">
            <button class="danger" type="submit">删除</button>
          </form>
        </td>
      </tr>
      <tr>
        <td colspan="7">
          <form method="post">
            <input type="hidden" name="action" value="user_update"><input type="hidden" name="_csrf" value="<?php echo vpnx_h($csrf); ?>"><input type="hidden" name="_p" value="users">
            <input type="hidden" name="name" value="<?php echo vpnx_h($u['name']); ?>">
            <span class="label">编辑 <?php echo vpnx_h($u['name']); ?>: 到期 / 配额 / 设备数 / 协议 / 同步节点</span>
            <input name="expire_at" value="<?php echo $u['expire_at'] > 0 ? vpnx_h(date('Y-m-d H:i:s', $u['expire_at'])) : ''; ?>" placeholder="30d 或 2026-01-31" style="width:170px">
            <input name="quota_bytes" value="<?php echo $u['quota_bytes'] > 0 ? vpnx_h((string) $u['quota_bytes']) : ''; ?>" placeholder="100G" style="width:110px">
            <input name="max_devices" value="<?php echo (int) $u['max_devices']; ?>" style="width:70px">
            <?php foreach ($cfg['allow_protocols'] as $p) { ?>
              <label class="chk"><input type="checkbox" name="protocols[]" value="<?php echo vpnx_h($p); ?>" <?php echo in_array($p, $u['protocols'], true) ? 'checked' : ''; ?>> <?php echo vpnx_h($p); ?></label>
            <?php } ?>
            <div style="margin-top:6px">
              <?php foreach ($nodes as $n) { ?>
                <label class="chk"><input type="checkbox" name="nodes[]" value="<?php echo vpnx_h($n['id']); ?>" <?php echo in_array($n['id'], $u['nodes'], true) ? 'checked' : ''; ?>> <?php echo vpnx_h($n['id']); ?></label>
              <?php } ?>
              <label class="chk">标签 <input name="tags" value="<?php echo vpnx_h(implode(',', $u['tags'])); ?>" style="width:150px"></label>
              <input name="note" value="<?php echo vpnx_h($u['note']); ?>" placeholder="备注" style="width:150px">
              <button type="submit">保存</button>
            </div>
          </form>
        </td>
      </tr>
      <?php } ?>
    </table>
  </div>

<?php } elseif ($page === 'subs') { ?>
  <div class="panel">
    <h3 style="margin-top:0">订阅清单</h3>
    <p class="small">客户端只需要这一个地址; 一个账号在多台服务器上时, 订阅里会包含所有服务器的节点。</p>
    <table>
      <tr><th>账号</th><th>节点</th><th>链接数</th><th>订阅地址</th><th>更新时间</th></tr>
      <?php foreach (vpnx_admin_subs_list() as $s) { ?>
      <tr>
        <td><?php echo vpnx_h($s['name']); ?><div class="small">token <code><?php echo vpnx_h(substr($s['token'], 0, 8)); ?>…</code></div></td>
        <td><?php echo vpnx_h(implode(', ', $s['nodes'])); ?></td>
        <td><?php echo (int) $s['links']; ?></td>
        <td class="small">
          <a href="<?php echo vpnx_h($s['url']); ?>" target="_blank">base64</a> ·
          <a href="<?php echo vpnx_h($s['clash_url']); ?>" target="_blank">clash</a> ·
          <a href="<?php echo vpnx_h($s['legacy_url']); ?>" target="_blank" title="只含 VMess 节点，给 Clash for Android 等老内核用">兼容(旧Clash)</a> ·
          <a href="<?php echo vpnx_h($s['xhttp_url']); ?>" target="_blank" title="只含 XHTTP 节点">XHTTP</a> ·
          <a href="<?php echo vpnx_h($s['singbox_url']); ?>" target="_blank">singbox</a> ·
          <a href="<?php echo vpnx_h($s['raw_url']); ?>" target="_blank">raw</a>
        </td>
        <td class="nowrap"><?php echo vpnx_h(vpnx_fmt_time($s['updated_at'])); ?></td>
      </tr>
      <?php } ?>
    </table>
    <?php if (!vpnx_admin_subs_list()) { ?><p class="small">还没有订阅内容: 节点首次成功推送后这里会出现。</p><?php } ?>
  </div>

<?php } elseif ($page === 'settings') { ?>
  <div class="panel">
    <h3 style="margin-top:0">中台设置</h3>
    <form method="post">
      <input type="hidden" name="action" value="settings_save"><input type="hidden" name="_csrf" value="<?php echo vpnx_h($csrf); ?>"><input type="hidden" name="_p" value="settings">
      <div class="grid">
        <div><span class="label">站点名称</span><input name="site_name" value="<?php echo vpnx_h($cfg['site_name']); ?>"></div>
        <div><span class="label">站点基址(留空=自动)</span><input name="base_url" value="<?php echo vpnx_h($cfg['base_url']); ?>" placeholder="留空即自动使用 /api.php"></div>
        <div><span class="label">订阅更新间隔(小时)</span><input name="sub_interval" value="<?php echo (int) $cfg['sub_interval']; ?>"></div>
        <div><span class="label">REALITY 伪装目标(默认)</span><input name="reality_target" value="<?php echo vpnx_h($cfg['node_defaults']['reality_target']); ?>"></div>
        <div><span class="label">SNI 列表(逗号分隔)</span><input name="reality_server_names" value="<?php echo vpnx_h(implode(',', $cfg['node_defaults']['reality_server_names'])); ?>"></div>
        <div><span class="label">日志级别</span><input name="log_level" value="<?php echo vpnx_h($cfg['node_defaults']['log_level']); ?>"></div>
        <div><span class="label">BBR</span>
          <select name="bbr"><option value="1" <?php echo !empty($cfg['node_defaults']['bbr']) ? 'selected' : ''; ?>>启用</option><option value="0" <?php echo empty($cfg['node_defaults']['bbr']) ? 'selected' : ''; ?>>关闭</option></select>
        </div>
        <div><span class="label">XTLS 流控</span><input name="flow" value="<?php echo vpnx_h(isset($cfg['profiles']['std']['params']['flow']) ? $cfg['profiles']['std']['params']['flow'] : 'xtls-rprx-vision'); ?>"></div>
        <div><span class="label">uTLS 指纹</span><input name="fingerprint" value="<?php echo vpnx_h(isset($cfg['profiles']['std']['params']['fingerprint']) ? $cfg['profiles']['std']['params']['fingerprint'] : 'chrome'); ?>"></div>
        <div><span class="label">REALITY spiderX</span><input name="spider_x" value="<?php echo vpnx_h(isset($cfg['profiles']['std']['params']['spider_x']) ? $cfg['profiles']['std']['params']['spider_x'] : '/'); ?>"></div>
        <div><span class="label">SS2022 加密方法</span>
          <?php $curMethod = isset($cfg['profiles']['ss']['params']['method']) ? $cfg['profiles']['ss']['params']['method'] : '2022-blake3-aes-128-gcm'; ?>
          <select name="ss_method">
            <option value="2022-blake3-aes-128-gcm" <?php echo $curMethod === '2022-blake3-aes-128-gcm' ? 'selected' : ''; ?>>2022-blake3-aes-128-gcm</option>
            <option value="2022-blake3-aes-256-gcm" <?php echo $curMethod === '2022-blake3-aes-256-gcm' ? 'selected' : ''; ?>>2022-blake3-aes-256-gcm</option>
          </select>
        </div>
        <div><span class="label">VMess WS 路径</span><input name="ws_path" value="<?php echo vpnx_h(isset($cfg['profiles']['ws']['params']['path']) ? $cfg['profiles']['ws']['params']['path'] : '/vpnx-ws'); ?>"></div>
      </div>
      <p class="small" style="margin-top:10px">
        当前机器接口地址: <code><?php echo vpnx_h(vpnx_machine_url('/api/v1/admin/health')); ?></code><br>
        模式: <?php echo (substr(vpnx_api_base(), -4) === '.php')
            ? '查询参数模式(?__vpnx=...) —— 不需要任何 rewrite, 兼容会被拦截 PATH_INFO 的面板/虚拟主机'
            : 'PATH_INFO 模式(/api/v1/...) —— 需要站点已按 nginx.conf.example 配好 rewrite'; ?><br>
        留空即自动推导; 填成不带 <code>.php</code> 的干净地址可让订阅 URL 更好看(但需要 rewrite)。
      </p>
      <p class="small" style="margin-top:10px">允许的协议:</p>
      <?php foreach (array('vless-reality', 'ss2022', 'vmess-ws', 'vless-xhttp') as $p) { ?>
        <label class="chk"><input type="checkbox" name="allow_protocols[]" value="<?php echo vpnx_h($p); ?>" <?php echo in_array($p, $cfg['allow_protocols'], true) ? 'checked' : ''; ?>> <?php echo vpnx_h($p); ?></label>
      <?php } ?>
      <p><button type="submit">保存设置</button></p>
      <p class="small">修改档位参数会推进所有节点的策略版本, 节点下次轮询即热更新(REALITY 目标/SNI/流控、SS 加密方法等)。</p>
    </form>
  </div>

  <div class="panel">
    <h3 style="margin-top:0">管理 API 令牌</h3>
    <p class="small">用于脚本调用管理接口(centralctl / curl):</p>
    <pre>Authorization: Bearer <?php echo vpnx_h($cfg['admin_token']); ?>
或  X-Admin-Token: <?php echo vpnx_h($cfg['admin_token']); ?></pre>
    <p class="small">接口示例:<br>
      <code>curl -H "X-Admin-Token: &lt;token&gt;" '<?php echo vpnx_h(vpnx_machine_url('/api/v1/admin/nodes')); ?>'</code>
    </p>
    <p class="small">修改口令会自动轮换该令牌。</p>
  </div>

  <div class="panel">
    <h3 style="margin-top:0">修改口令</h3>
    <form method="post">
      <input type="hidden" name="action" value="password"><input type="hidden" name="_csrf" value="<?php echo vpnx_h($csrf); ?>"><input type="hidden" name="_p" value="settings">
      <div class="grid">
        <div><span class="label">原口令</span><input type="password" name="old_pass"></div>
        <div><span class="label">新口令(≥8 位)</span><input type="password" name="new_pass"></div>
      </div>
      <p><button type="submit">修改口令</button></p>
    </form>
    <?php if (is_file(vpnx_data_dir() . DIRECTORY_SEPARATOR . 'install-info.txt')) { ?>
      <p class="small" style="color:#fcd34d">检测到 data/install-info.txt 仍存在(内含初始口令), 请修改口令后删除该文件。</p>
    <?php } ?>
  </div>

<?php } elseif ($page === 'audit') { ?>
  <div class="panel">
    <h3 style="margin-top:0">审计日志(最近 200 条)</h3>
    <table>
      <tr><th>时间</th><th>操作者</th><th>IP</th><th>动作</th><th>详情</th></tr>
      <?php foreach (vpnx_audit_tail(200) as $row) { ?>
      <tr>
        <td class="nowrap"><?php echo vpnx_h(isset($row['time']) ? $row['time'] : ''); ?></td>
        <td><?php echo vpnx_h(isset($row['actor']) ? $row['actor'] : ''); ?></td>
        <td><?php echo vpnx_h(isset($row['ip']) ? $row['ip'] : ''); ?></td>
        <td><?php echo vpnx_h(isset($row['action']) ? $row['action'] : ''); ?></td>
        <td class="small"><?php echo vpnx_h(isset($row['detail']) ? $row['detail'] : ''); ?></td>
      </tr>
      <?php } ?>
    </table>
  </div>
<?php } ?>
</main>
</body>
</html>
