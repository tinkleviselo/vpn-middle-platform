<?php
/**
 * vpnx 中台 - 订阅聚合
 *
 * 一个账号可能同时存在于多个节点(这就是"多服务器"的意义):
 *   每个节点把自己那份分享链接推给中台, 中台按账号 token 合并, 客户端只访问一个订阅地址。
 *
 * 支持:
 *   GET /sub/<token>              默认 Base64 链接列表(小火箭 / v2rayN 可直接导入)
 *   GET /sub/<token>?target=raw   明文链接
 *   GET /sub/<token>/clash        Clash Meta / mihomo(合并各节点的 proxies)
 *   GET /sub/<token>/singbox      sing-box(优先合并节点上报的模板, 否则回溯为链接列表)
 */

/**
 * 合并某账号在所有节点上的订阅内容
 *
 * @param string $token
 * @return array|null null 表示 token 不存在
 */
/**
 * 订阅显示名统一由中台命名
 *
 *   背景: 节点上报的分享链接/Clash YAML 里的名字是 `<节点ID>-<账号>-<协议>`,
 *         会把 node_id / 主机名 / 端口这类信息暴露给客户端。这里统一换成中台的节点名
 *         (「节点」页里填的名字), 同名自动加序号, 不改代理组名。
 */
function vpnx_sub_label($base, &$used)
{
    $base = trim(preg_replace('/["\'\r\n\t]+/', ' ', (string) $base));
    if ($base === '') {
        $base = '线路';
    }
    $n = isset($used[$base]) ? (int) $used[$base] : 0;
    $used[$base] = $n + 1;
    return $n === 0 ? $base : ($base . ' ' . ($n + 1));
}

/** 把分享链接的显示名换成给定名字 */
function vpnx_sub_link_rename($link, $label)
{
    $link = (string) $link;
    if ($link === '') {
        return $link;
    }

    // vmess:// 的显示名在 base64 里的 ps 字段 —— 多数客户端(v2rayN/小火箭)只看 ps,
    // 不看 #片段, 所以必须解出来改 ps 再编码回去, 否则节点上报的
    // "<节点ID>-<账号>-VMess" / hostname 这类信息仍然会显示出来。
    if (stripos($link, 'vmess://') === 0) {
        $body = substr($link, 8);
        $h = strpos($body, '#');
        if ($h !== false) {
            $body = substr($body, 0, $h);
        }
        $json = @base64_decode(str_replace(array('-', '_'), array('+', '/'), $body));
        $obj = ($json !== false && $json !== '') ? @json_decode($json, true) : null;
        if (is_array($obj)) {
            $obj['ps'] = $label;
            // 只改 ps, 不追加 #片段 —— vmess 的名称就在 payload 里, 追加片段会让
            // 解析端把 "#..." 一起当作 base64 解码而失败(整份兼容订阅会变空)。
            return 'vmess://' . base64_encode(json_encode($obj, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
        }
        return $link;   // 解不出来就原样返回, 绝不改动
    }

    $hash = strpos($link, '#');
    $url = $hash === false ? $link : substr($link, 0, $hash);
    return $url . '#' . rawurlencode($label);
}

/** 把节点上报的 Clash YAML 里的代理名换掉(只改 proxies 段, 代理组名保留) */
function vpnx_sub_yaml_rename($yaml, $base, &$used)
{
    $yaml = (string) $yaml;
    if ($yaml === '') {
        return $yaml;
    }
    $pos = strpos($yaml, "\nproxy-groups:");
    $head = $pos === false ? $yaml : substr($yaml, 0, $pos);
    $tail = $pos === false ? '' : substr($yaml, $pos);
    $head = preg_replace_callback('/^(\s*-\s*name:\s*).*$/m', function ($m) use ($base, &$used) {
        return $m[1] . '"' . vpnx_sub_label($base, $used) . '"';
    }, $head);
    return $head . $tail;
}
function vpnx_sub_aggregate($token)
{
    $entry = vpnx_sub_get($token);
    if ($entry === null) {
        return null;
    }

    // 按节点注册顺序输出, 保证同一账号的订阅内容稳定(客户端不会来回抖动)
    $ordered = array();
    $reg = vpnx_nodes_load();
    foreach (array_keys($reg['nodes']) as $nid) {
        if (isset($entry['nodes'][$nid])) {
            $ordered[$nid] = $entry['nodes'][$nid];
        }
    }
    foreach ($entry['nodes'] as $nid => $x) {
        if (!isset($ordered[$nid])) {
            $ordered[$nid] = $x;
        }
    }

    $links = array();
    $clash = array();
    $singbox = array();
    $download = 0;
    $usedLabels = array();      // 中台命名去重(同名节点加序号)
    foreach ($ordered as $nid => $x) {
        // 该节点的中台名字(「节点」页填的名称); 没有就退化成"线路"
        $label = isset($reg['nodes'][$nid]['name']) ? (string) $reg['nodes'][$nid]['name'] : '';
        if (isset($x['links']) && is_array($x['links'])) {
            foreach ($x['links'] as $l) {
                $l = trim((string) $l);
                if ($l === '') {
                    continue;
                }
                // 显示名换成中台命名, 不再暴露 node_id / 主机名 / 端口
                $l = vpnx_sub_link_rename($l, vpnx_sub_label($label, $usedLabels));
                if (!in_array($l, $links, true)) {
                    $links[] = $l;
                }
            }
        }
        if (!empty($x['clash_yaml'])) {
            $clash[] = vpnx_sub_yaml_rename($x['clash_yaml'], $label, $usedLabels);
        }
        if (!empty($x['singbox_json'])) {
            $singbox[] = $x['singbox_json'];
        }
        $download += (int) $x['used_bytes'];
    }

    // 中台的账号表是流量与到期的权威来源
    $user = vpnx_user_get($entry['name']);
    $total = (int) $entry['quota_bytes'];
    $expire = (int) $entry['expire_at'];
    if ($user !== null) {
        $total = (int) $user['quota_bytes'];
        $expire = (int) $user['expire_at'];
        $download = (int) $user['used_up'] + (int) $user['used_down'];
    }

    return array(
        'token' => $token,
        'name' => $entry['name'],
        'nodes' => array_keys($ordered),
        'links' => $links,
        'clash' => $clash,
        'singbox' => $singbox,
        'download' => $download,
        'total' => $total,
        'expire' => $expire,
    );
}

/**
 * 生成响应体
 *
 * @param array  $agg
 * @param string $target base64|raw|clash|singbox
 * @return string
 */
function vpnx_sub_render($agg, $target)
{
    $target = strtolower(trim((string) $target));

    // XHTTP 专用订阅(只含 vless+xhttp 节点): 这类节点不能混进普通 clash 订阅
    if ($target === 'clash-xhttp' || $target === 'clashxhttp' || $target === 'xhttp') {
        $body = vpnx_clash_xhttp_from_links($agg['links']);
        if ($body === '') {
            $body = vpnx_clash_no_proxy_placeholder(
                "该账号暂无 XHTTP 节点\n"
                . "处理: ① 节点上启用 vless-xhttp\n"
                . "         vpnx install --profiles reality,ss2022,vmess-ws,xhttp --yes\n"
                . "      ② 中台给该账号勾选 vless-xhttp 协议"
            );
        }
        return $body;
    }

    // 老 Clash 兼容模式(Clash for Android / Clash Premium 等)
    //   这类内核不支持 VLESS 与 SS2022, 且"遇到不认识的节点类型会拒绝加载整份订阅",
    //   所以必须只输出它认得的协议(VMess), 否则手机上会出现"不支持类型 vless"。
    if ($target === 'clash-legacy' || $target === 'clashlegacy' || $target === 'clash-old'
        || $target === 'clash-android' || $target === 'clash-classic' || $target === 'legacy') {
        $body = vpnx_clash_legacy_from_links($agg['links']);
        if ($body === '') {
            $body = vpnx_clash_no_proxy_placeholder(
                "该账号暂无兼容老 Clash 的节点(需要 VMess)\n"
                . "处理: ① 节点上启用 vmess-ws  ② 中台给该账号勾选 vmess-ws 协议"
            );
        }
        return $body;
    }

    if ($target === 'clash' || $target === 'clashmeta' || $target === 'mihomo' || $target === 'yaml') {
        $body = vpnx_clash_merge($agg['clash']);
        if ($body === '') {
            // 节点没上报 clash_yaml(旧版本节点或数据未刷新)时, 中台自己从分享链接生成;
            // 这里必须排除 XHTTP 节点 —— 不认识该 transport 的客户端会拒绝加载整份订阅。
            $body = vpnx_clash_from_links(vpnx_links_without_xhttp($agg['links']));
        }
        if ($body === '') {
            $body = base64_encode(implode("\n", $agg['links']));
        }
        return $body;
    }
    if ($target === 'singbox' || $target === 'sing-box' || $target === 'sing_box') {
        $body = vpnx_singbox_merge($agg['singbox']);
        if ($body === '') {
            $body = base64_encode(implode("\n", $agg['links']));
        }
        return $body;
    }
    if ($target === 'raw' || $target === 'plain' || $target === 'base64decode') {
        return implode("\n", $agg['links']);
    }
    // 默认: Base64(标准编码, 可被绝大多数客户端直接导入)
    return base64_encode(implode("\n", $agg['links']));
}

/**
 * 订阅响应头(流量/到期/更新间隔)
 */
function vpnx_sub_headers($agg)
{
    $cfg = vpnx_config();
    $interval = isset($cfg['sub_interval']) ? (int) $cfg['sub_interval'] : 12;
    return array(
        'Subscription-Userinfo' => sprintf(
            'upload=0; download=%d; total=%d; expire=%d',
            (int) $agg['download'],
            (int) $agg['total'],
            (int) $agg['expire']
        ),
        'Profile-Update-Interval' => (string) $interval,
        'Cache-Control' => 'no-store',
    );
}

/**
 * 订阅内容的 Content-Type
 */
function vpnx_sub_content_type($target)
{
    $target = strtolower(trim((string) $target));
    if ($target === 'clash' || $target === 'clashmeta' || $target === 'mihomo' || $target === 'yaml'
        || $target === 'clash-legacy' || $target === 'clashlegacy' || $target === 'clash-old'
        || $target === 'clash-android' || $target === 'clash-classic' || $target === 'legacy'
        || $target === 'clash-xhttp' || $target === 'clashxhttp' || $target === 'xhttp') {
        return 'text/yaml; charset=utf-8';
    }
    return 'text/plain; charset=utf-8';
}

/**
 * 合并多个节点的 Clash 配置
 *
 * 做法: 从各份 YAML 里抽出 proxies 列表项(以 "- name:" 开头的一段), 拼接后重建一份
 * 最小可用配置。这样只依赖 vpnx 自己生成的固定结构, 不需要引入 YAML 解析器。
 */
function vpnx_clash_merge($docs)
{
    if (!is_array($docs) || !$docs) {
        return '';
    }
    $blocks = array();
    $names = array();
    foreach ($docs as $doc) {
        $lines = preg_split("/\r\n|\n|\r/", (string) $doc);
        $inProxies = false;
        $current = array();
        $currentName = '';
        foreach ($lines as $line) {
            if (preg_match('/^proxies:\s*$/', $line)) {
                $inProxies = true;
                continue;
            }
            if ($inProxies && preg_match('/^[A-Za-z_-]+:/', $line)) {
                $inProxies = false; // 进入下一个顶层键
            }
            if (!$inProxies) {
                continue;
            }
            if (preg_match('/^\s*-\s*name:\s*"?(.+?)"?\s*$/', $line, $m)) {
                if ($current) {
                    $blocks[] = implode("\n", $current);
                    $names[] = $currentName;
                }
                $current = array($line);
                $currentName = $m[1];
                continue;
            }
            if ($current) {
                $current[] = $line;
            }
        }
        if ($current) {
            $blocks[] = implode("\n", $current);
            $names[] = $currentName;
        }
    }
    if (!$blocks) {
        // 结构不符合预期时, 直接返回第一份原文(至少客户端能用)
        return isset($docs[0]) ? $docs[0] : '';
    }
    $out = "proxies:\n" . implode("\n", $blocks) . "\n";
    $out .= "proxy-groups:\n";
    $out .= "  - name: PROXY\n";
    $out .= "    type: select\n";
    $out .= "    proxies: [" . implode(', ', $names) . "]\n";
    $out .= "rules:\n";
    $out .= "  - MATCH,PROXY\n";
    return $out;
}

/**
 * 没有任何可用节点时的占位配置
 *
 * 老 Clash 不允许 proxies 为空(会报 profile does not contain proxies or proxy-providers),
 * 所以放一个自解释的占位节点, 并让默认路由走 DIRECT(不影响客户端正常上网)。
 *
 * @param string $reason 用 # 注释写进配置的说明(可多行)
 * @return string
 */
function vpnx_clash_no_proxy_placeholder($reason)
{
    return '# ' . str_replace("\n", "\n# ", (string) $reason) . "\n"
        . "proxies:\n"
        . "  - name: \"⚠ 无可用节点-看配置里的说明\"\n"
        . "    type: vmess\n"
        . "    server: 127.0.0.1\n"
        . "    port: 1\n"
        . "    uuid: 00000000-0000-0000-0000-000000000000\n"
        . "    alterId: 0\n"
        . "    cipher: auto\n"
        . "proxy-groups:\n"
        . "  - name: PROXY\n"
        . "    type: select\n"
        . "    proxies: [\"⚠ 无可用节点-看配置里的说明\", DIRECT]\n"
        . "rules:\n"
        . "  - MATCH,DIRECT\n";
}

/**
 * 过滤掉 XHTTP 节点(用于默认 clash 订阅: 老客户端不认这个 transport)
 *
 * @param array $links
 * @return array
 */
function vpnx_links_without_xhttp($links)
{
    $out = array();
    foreach ((array) $links as $l) {
        $s = strtolower(trim((string) $l));
        if (strpos($s, 'type=xhttp') !== false || strpos($s, 'type=splithttp') !== false) {
            continue;
        }
        $out[] = $l;
    }
    return $out;
}

/**
 * 只保留 VLESS + XHTTP 节点, 生成 XHTTP 专用订阅
 *
 * 为什么要单独一条订阅: XHTTP 需要较新的客户端, 混进普通 clash 订阅会让
 * 不认识该 transport 的老客户端拒绝加载整份配置。
 *
 * @param array $links
 * @return string YAML 文本; 没有 XHTTP 节点时返回空串
 */
function vpnx_clash_xhttp_from_links($links)
{
    $keep = array();
    foreach ((array) $links as $l) {
        $s = strtolower(trim((string) $l));
        if (strpos($s, 'vless://') !== 0) {
            continue;
        }
        if (strpos($s, 'type=xhttp') !== false || strpos($s, 'type=splithttp') !== false) {
            $keep[] = $l;
        }
    }
    if (!$keep) {
        return '';
    }
    return vpnx_clash_from_links($keep);
}

/**
 * 只保留老 Clash 支持的协议(VMess), 生成"兼容订阅"
 *
 * 老 Clash(Clash for Android / Clash Premium)不支持 VLESS 与 SS2022,
 * 且遇到不认识的节点类型会拒绝加载整份配置 —— 所以兼容订阅必须把这些节点过滤掉。
 *
 * @param array $links
 * @return string YAML 文本; 没有兼容节点时返回空串
 */
function vpnx_clash_legacy_from_links($links)
{
    $keep = array();
    foreach ((array) $links as $l) {
        $s = strtolower(trim((string) $l));
        if (strpos($s, 'vmess://') === 0) {
            // 容错: 万一链接被追加过 #片段, 这里去掉再交给解析器(vmess 的载荷是整段 base64)
            $h = strpos($l, '#');
            $keep[] = $h === false ? $l : substr($l, 0, $h);
        }
    }
    if (!$keep) {
        return '';
    }
    return vpnx_clash_from_links($keep);
}

/**
 * 从分享链接(vless:// / ss:// / vmess://)自己生成一份 Clash 配置
 *
 * 用途: 节点没上报 clash_yaml 时兜底(旧节点, 或订阅数据尚未刷新),
 *       保证 /clash 永远返回真正的 YAML, 而不是 base64 链接列表
 *       (返回 base64 会让 Clash 类客户端订阅解析失败)。
 *
 * @param array $links 分享链接数组
 * @return string YAML 文本; 无法生成时返回空串
 */
function vpnx_clash_from_links($links)
{
    if (!is_array($links) || !$links) {
        return '';
    }
    $proxies = array();
    $names = array();
    foreach ($links as $link) {
        $item = vpnx_clash_proxy_from_link($link);
        if ($item === null) {
            continue;
        }
        $proxies[] = $item['yaml'];
        $names[] = $item['name'];
    }
    if (!$proxies) {
        return '';
    }
    $out = "proxies:\n" . implode("\n", $proxies) . "\n";
    $out .= "proxy-groups:\n";
    $out .= "  - name: PROXY\n";
    $out .= "    type: select\n";
    $out .= "    proxies: [" . implode(', ', $names) . "]\n";
    $out .= "rules:\n";
    $out .= "  - MATCH,PROXY\n";
    return $out;
}

/**
 * 单条分享链接 -> Clash 代理条目
 *
 * @param string $link
 * @return array|null array(name, yaml)
 */
function vpnx_clash_proxy_from_link($link)
{
    $link = trim((string) $link);
    if ($link === '') {
        return null;
    }

    // ---------------- VLESS(含 REALITY) ----------------
    if (strpos($link, 'vless://') === 0) {
        $parts = parse_url($link);
        if (!is_array($parts) || !isset($parts['host']) || !isset($parts['port'])) {
            return null;
        }
        $query = array();
        if (isset($parts['query'])) {
            parse_str($parts['query'], $query);
        }
        $name = (isset($parts['fragment']) && $parts['fragment'] !== '')
            ? urldecode($parts['fragment'])
            : ('vless-' . $parts['host'] . '-' . $parts['port']);
        $uuid = isset($parts['user']) ? $parts['user'] : '';
        $sni = isset($query['sni']) ? $query['sni'] : '';
        $flow = isset($query['flow']) ? $query['flow'] : '';
        $fp = (isset($query['fp']) && $query['fp'] !== '') ? $query['fp'] : 'chrome';
        $pbk = isset($query['pbk']) ? $query['pbk'] : '';
        $sid = isset($query['sid']) ? $query['sid'] : '';
        $security = isset($query['security']) ? strtolower($query['security']) : '';
        $net = (isset($query['type']) && $query['type'] !== '') ? $query['type'] : 'tcp';
        if ($net === 'raw') {
            $net = 'tcp';
        }
        if ($net === 'splithttp') {
            $net = 'xhttp';   // 老核心叫 splithttp, 统一按 xhttp 输出
        }

        $yaml = '  - name: "' . $name . "\"\n";
        $yaml .= "    type: vless\n";
        $yaml .= '    server: ' . $parts['host'] . "\n";
        $yaml .= '    port: ' . (int) $parts['port'] . "\n";
        $yaml .= '    uuid: ' . $uuid . "\n";
        $yaml .= '    network: ' . $net . "\n";
        $yaml .= "    udp: true\n";
        if ($security === 'reality') {
            $yaml .= "    tls: true\n";
            if ($sni !== '') {
                $yaml .= '    servername: ' . $sni . "\n";
            }
            $yaml .= '    client-fingerprint: ' . $fp . "\n";
            $yaml .= "    reality-opts:\n";
            $yaml .= '      public-key: ' . $pbk . "\n";
            $yaml .= '      short-id: "' . $sid . "\"\n";
        } elseif ($security === 'tls') {
            $yaml .= "    tls: true\n";
            if ($sni !== '') {
                $yaml .= '    servername: ' . $sni . "\n";
            }
        }
        // XHTTP 传输: 不能带 flow(xtls-rprx-vision 与 XHTTP 互斥), 需要 xhttp-opts
        if ($net === 'xhttp') {
            $yaml .= "    xhttp-opts:\n";
            $yaml .= '      path: ' . ((isset($query['path']) && $query['path'] !== '') ? $query['path'] : '/') . "\n";
            if (isset($query['mode']) && $query['mode'] !== '') {
                $yaml .= '      mode: ' . $query['mode'] . "\n";
            }
            return array('name' => $name, 'yaml' => rtrim($yaml, "\n"));
        }
        if ($flow !== '') {
            $yaml .= '    flow: ' . $flow . "\n";
        }
        return array('name' => $name, 'yaml' => rtrim($yaml, "\n"));
    }

    // ---------------- Shadowsocks(SIP002) ----------------
    // ss://base64url(method:password)@host:port#tag
    if (strpos($link, 'ss://') === 0) {
        $hashPos = strpos($link, '#');
        $name = ($hashPos !== false) ? urldecode(substr($link, $hashPos + 1)) : 'ss';
        $core = ($hashPos !== false) ? substr($link, 5, $hashPos - 5) : substr($link, 5);
        $atPos = strrpos($core, '@');
        if ($atPos === false) {
            return null;
        }
        $userinfo = substr($core, 0, $atPos);
        $hostport = substr($core, $atPos + 1);
        $padded = strtr($userinfo, '-_', '+/');
        $pad = strlen($padded) % 4;
        if ($pad > 0) {
            $padded .= str_repeat('=', 4 - $pad);
        }
        $decoded = base64_decode($padded);
        if ($decoded === false || strpos($decoded, ':') === false) {
            return null;
        }
        $pos = strpos($decoded, ':');
        $method = substr($decoded, 0, $pos);
        $password = substr($decoded, $pos + 1);
        $hp = explode(':', $hostport);
        if (count($hp) < 2) {
            return null;
        }
        $port = (int) array_pop($hp);
        $host = implode(':', $hp);
        if ($name === '') {
            $name = 'ss-' . $host . '-' . $port;
        }
        $yaml = '  - name: "' . $name . "\"\n";
        $yaml .= "    type: ss\n";
        $yaml .= '    server: ' . $host . "\n";
        $yaml .= '    port: ' . $port . "\n";
        $yaml .= '    cipher: ' . $method . "\n";
        $yaml .= '    password: "' . $password . "\"\n";
        $yaml .= "    udp: true\n";
        return array('name' => $name, 'yaml' => rtrim($yaml, "\n"));
    }

    // ---------------- VMess(base64 JSON) ----------------
    if (strpos($link, 'vmess://') === 0) {
        $json = base64_decode(substr($link, 8));
        if ($json === false) {
            return null;
        }
        $v = json_decode($json, true);
        if (!is_array($v) || !isset($v['add']) || !isset($v['port']) || !isset($v['id'])) {
            return null;
        }
        $name = (isset($v['ps']) && $v['ps'] !== '') ? $v['ps'] : ('vmess-' . $v['add']);
        $host = (isset($v['host']) && $v['host'] !== '') ? $v['host'] : $v['add'];
        $path = (isset($v['path']) && $v['path'] !== '') ? $v['path'] : '/';
        $yaml = '  - name: "' . $name . "\"\n";
        $yaml .= "    type: vmess\n";
        $yaml .= '    server: ' . $v['add'] . "\n";
        $yaml .= '    port: ' . (int) $v['port'] . "\n";
        $yaml .= '    uuid: ' . $v['id'] . "\n";
        $yaml .= '    alterId: ' . (isset($v['aid']) ? (int) $v['aid'] : 0) . "\n";
        $yaml .= "    cipher: auto\n";
        $yaml .= "    udp: true\n";
        if (isset($v['net']) && strtolower($v['net']) === 'ws') {
            $yaml .= "    network: ws\n";
            // 两套写法都写上: 老 Clash(Clash for Android)只认 ws-path/ws-headers,
            // mihomo(Clash.Meta)认 ws-opts 且兼容老写法。
            $yaml .= '    ws-path: ' . $path . "\n";
            $yaml .= "    ws-headers:\n";
            $yaml .= '      Host: ' . $host . "\n";
            $yaml .= "    ws-opts:\n";
            $yaml .= '      path: ' . $path . "\n";
            $yaml .= "      headers:\n";
            $yaml .= '        Host: ' . $host . "\n";
        }
        if (isset($v['tls']) && $v['tls'] !== '' && strtolower($v['tls']) !== 'none') {
            $yaml .= "    tls: true\n";
            if (isset($v['sni']) && $v['sni'] !== '') {
                $yaml .= '    servername: ' . $v['sni'] . "\n";
            }
        }
        return array('name' => $name, 'yaml' => rtrim($yaml, "\n"));
    }

    return null;
}

/**
 * 合并多个节点的 sing-box 配置(合并 outbounds, 生成最小可用配置)
 */
function vpnx_singbox_merge($docs)
{
    if (!is_array($docs) || !$docs) {
        return '';
    }
    $outbounds = array();
    foreach ($docs as $doc) {
        $json = json_decode((string) $doc, true);
        if (!is_array($json) || !isset($json['outbounds']) || !is_array($json['outbounds'])) {
            continue;
        }
        foreach ($json['outbounds'] as $ob) {
            if (is_array($ob)) {
                $outbounds[] = $ob;
            }
        }
    }
    if (!$outbounds) {
        return '';
    }
    $final = isset($outbounds[0]['tag']) ? $outbounds[0]['tag'] : 'proxy';
    return vpnx_json_encode(array(
        'log' => array('level' => 'info'),
        'outbounds' => $outbounds,
        'route' => array('rules' => array(), 'final' => $final),
    ));
}

/**
 * 不带鉴权的订阅入口
 *
 * @param string $path 应用相对路径
 */
function vpnx_handle_sub($path)
{
    if (!preg_match('#^/sub/([A-Za-z0-9_-]{8,64})(?:/([A-Za-z0-9_-]+))?$#', $path, $m)) {
        vpnx_json_out(404, array('ok' => false, 'error' => 'not found'));
    }
    $token = $m[1];
    $target = isset($m[2]) ? strtolower($m[2]) : '';
    if ($target === '') {
        if (isset($_GET['target']) && $_GET['target'] !== '') {
            $target = strtolower(trim($_GET['target']));
        } elseif (isset($_GET['format']) && $_GET['format'] !== '') {
            $target = strtolower(trim($_GET['format']));
        }
    }

    $agg = vpnx_sub_aggregate($token);
    if ($agg === null) {
        vpnx_log('订阅 token 不存在: ' . substr($token, 0, 6) . '...');
        vpnx_text_out(404, "subscription not found\n"
            . "token 前缀: " . substr($token, 0, 8) . "...\n"
            . "可能原因:\n"
            . "  1) 账号刚创建, 节点还没上报订阅内容(节点每 60 秒同步一次, 请稍等)\n"
            . "  2) 节点同步异常(中台「节点」页看是否在线 / 是否显示\"待应用\")\n"
            . "  3) 账号已被删除, 或这是旧 token\n");
    }
    $headers = vpnx_sub_headers($agg);
    $headers['Content-Type'] = vpnx_sub_content_type($target);
    vpnx_text_out(200, vpnx_sub_render($agg, $target), $headers);
}
