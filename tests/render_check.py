#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tests/render_check.py - 渲染产物结构校验(不需要 bash / xray)

做法: 从 lib/config.sh 里把 printf 渲染语句机械还原成文本, 再交给 json 解析,
      验证 in-xhttp 的结构正确性; 附带源码级回归断言(SS 的 clients/users 字段)。
这样在没有 bash/xray 的机器上也能拦住"字段名写错 / JSON 少逗号 / flow 混进 XHTTP"这类静默回归。

用法:  python3 tests/render_check.py       (退出码 0 = 全部通过)
"""
import io
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.path.join(ROOT, 'lib', 'config.sh')
USERS = os.path.join(ROOT, 'lib', 'users.sh')

ARGS = {
    '"$listen"': ['0.0.0.0'],
    '"$(proto_tag xhttp)"': ['in-xhttp'],
    '"$x_port"': ['8444'],
    '"$r_target"': ['www.bing.com:443'],
    '"$r_sni"': ['www.bing.com'],
    '"$r_priv"': ['PRIVKEY'],
    '"$(_render_short_ids "$r_ids")"': ['"0cabbc3ac1dd7cde"'],
    '"$(xray_xhttp_net)"': ['xhttp'],
    '"$(xray_xhttp_key)" "$x_path" "$x_mode" "$(_render_xhttp_host "$x_host")"': [
        'xhttpSettings', '/vpnx-xhttp', 'auto', ''],
    '"$(_json_bool "$sniffing")"': ['false'],
}

PASS = []
FAIL = []


def check(name, cond):
    (PASS if cond else FAIL).append(name)
    print(('  [通过] ' if cond else '  [失败] ') + name)


def render_block(src):
    start = src.index('# VLESS + XHTTP + REALITY(与 in-reality')
    end = src.index("        printf '\\n  ],\\n'", start)
    block = src[start:end]
    out = []
    lines = block.split('\n')
    i = 0
    while i < len(lines):
        ln = lines[i]
        if ln.strip().startswith('cat "$frag_x"'):
            out.append('            {"id": "UUID-1", "email": "my@x"}')
            i += 1
            continue
        if 'printf' in ln:
            stmt = ln
            while stmt.rstrip().endswith('\\'):
                i += 1
                stmt = stmt.rstrip()[:-1] + lines[i]
            m = re.search(r"printf\s+'((?:[^'\\]|\\.)*)'(.*)$", stmt)
            if not m:
                raise ValueError('printf 解析失败: ' + stmt)
            fmt = m.group(1).replace('\\n', '\n').replace("\\'", "'")
            argv = m.group(2).strip()
            if argv:
                if argv not in ARGS:
                    raise ValueError('未知参数列表: ' + argv)
                out.append(fmt % tuple(ARGS[argv]))
            else:
                out.append(fmt)
        i += 1
    return ''.join(out)


def main():
    src = io.open(CONFIG, encoding='utf-8').read()
    users_src = io.open(USERS, encoding='utf-8').read()

    print('== in-xhttp 渲染结构校验 ==')
    try:
        text = render_block(src)
    except ValueError as exc:
        print('  [失败] 提取渲染语句: %s' % exc)
        return 1
    try:
        cfg = json.loads('{"inbounds": [{"tag": "in-reality"}' + text + ']}')
    except ValueError as exc:
        print('  [失败] 渲染结果不是合法 JSON: %s' % exc)
        return 1
    check('渲染结果可被 json 解析', True)

    ib = [x for x in cfg['inbounds'] if x.get('tag') == 'in-xhttp']
    check('存在 in-xhttp 入站', len(ib) == 1)
    if not ib:
        return 1
    ss = ib[0]
    stream = ss.get('streamSettings', {})
    reality = stream.get('realitySettings', {})
    clients = ss.get('settings', {}).get('clients', [])
    check('protocol 为 vless', ss.get('protocol') == 'vless')
    check('network 为 xhttp', stream.get('network') == 'xhttp')
    check('security 为 reality', stream.get('security') == 'reality')
    check('xhttpSettings 含 path/mode',
          stream.get('xhttpSettings') == {'path': '/vpnx-xhttp', 'mode': 'auto'})
    check('clients 非空', len(clients) > 0)
    check('clients 不带 flow(XHTTP 与 Vision 互斥)', all('flow' not in c for c in clients))
    check('clients 含 id/email',
          bool(clients) and 'id' in clients[0] and clients[0].get('email') == 'my@x')
    check('复用 REALITY 私钥', reality.get('privateKey') == 'PRIVKEY')
    check('shortIds 已写入', reality.get('shortIds') == ['0cabbc3ac1dd7cde'])
    check('target/serverNames 正确',
          reality.get('target') == 'www.bing.com:443'
          and reality.get('serverNames') == ['www.bing.com'])

    print('== 源码级回归断言 ==')
    # SS 入站的用户列表字段名必须是 clients(Xray 静默忽略 users -> SS 永远连不上)
    check('SS 入站使用 clients 字段', '        "clients": [' in src)
    check('SS 入站未使用 users 字段', '        "users": [' not in src)
    check('SS 热加载也用 clients(users.sh)',
          '"protocol":"shadowsocks"' in users_src and '"password":"%s","clients"' in users_src)

    print('\n结果: %d 通过, %d 失败' % (len(PASS), len(FAIL)))
    if FAIL:
        print('失败项: ' + ', '.join(FAIL))
        return 1
    print('全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())