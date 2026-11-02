#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
lint_php.py - vpnx 中台(PHP)静态检查器(零依赖, python2.7 / python3 通用)

用途: 在没有 PHP 可执行文件的开发机上, 尽可能提前发现 PHP 代码里的低级错误,
      以及"在 面板常见的老 PHP(5.6)上会直接报错"的新语法。

检查项:
  1. 文件必须是 UTF-8 + LF, 无 BOM; 以 <?php 开头; 结尾不应有 ?>
  2. 括号/花括号/方括号配对(先剥掉注释与字符串)
  3. 项目内函数定义与调用一致性(重点抓 vpnx_* 拼写错误)
  4. require/include 的文件存在性
  5. PHP 7.0+ / 7.4+ / 8.0+ 专属语法(?? ?-> match fn str_contains 等) -> 报错
  6. 类型声明与返回类型(5.6 不支持) -> 报错
  7. random_bytes / password_hash 必须被 function_exists 包着(垫片) -> 警告

用法:
  python tests/lint_php.py [仓库根目录]
  python tests/lint_php.py --balance <文件...>
退出码: 0 = 无错误
"""

from __future__ import print_function

import io
import os
import re
import sys

# PHP 内置函数大表(只列本项目可能用到的, 不在此表内且以 vpnx_ 开头的才会被判定为错误)
BUILTINS = set("""
abs array array_diff array_filter array_key_exists array_keys array_map array_merge
array_reverse array_search array_slice array_unique array_values array_walk asort
base64_decode base64_encode bin2hex ceil chmod chr count ctype_digit date define
defined dirname empty error_log explode fclose filesize file file_get_contents
file_put_contents file_exists flock fopen fread fwrite fgets fpassthru function_exists
glob hash hash_equals hash_hmac header headers_sent htmlspecialchars http_response_code
implode in_array ini_get intval is_array is_bool is_dir is_file is_int is_null is_readable
is_resource is_string isset json_decode json_encode json_last_error key ksort ltrim
max md5 microtime min mkdir move_uploaded_file mt_rand number_format ob_end_clean
ob_get_clean ob_start ord parse_url parse_str preg_match preg_match_all preg_replace
preg_split print printf print_r rand range rawurlencode readfile realpath rename
round rmdir rtrim session_destroy session_id session_name session_regenerate_id
session_set_cookie_params session_start session_status setcookie settype sha1
sprintf str_replace str_repeat str_split strip_tags stripos strlen strpos strtolower
strtoupper strtr strstr substr trim uasort uksort uniqid unlink urlencode usort
var_export version_compare wordwrap floatval boolval php_sapi_name phpversion
getenv putenv getmypid sleep usleep time mktime strtotime checkdate gmdate
filter_var filter_input is_callable call_user_func call_user_func_array
func_get_args class_exists method_exists property_exists get_class gettype
in_array iterator_to_array json_encode error_reporting ini_set set_time_limit
curl_init curl_setopt curl_exec curl_getinfo curl_close curl_error stream_context_create
hash_pbkdf2 openssl_random_pseudo_bytes password_hash password_verify random_bytes
number_format array_pop array_shift array_unshift array_splice array_combine
array_flip array_column array_pad array_fill array_sum array_product array_reduce
sort rsort asort arsort krsort natsort natcasesort shuffle compact extract
pack unpack random_int hash hash_file hash_algos getallheaders str_pad preg_quote
filemtime touch is_writable disk_free_space nl2br ucfirst lcfirst dechex hexdec
http_build_query http_response_header stream_socket_server stream_socket_client
stream_socket_get_name stream_context_create proc_open proc_terminate proc_close
proc_get_status fsockopen fwrite fread feof usleep sys_get_temp_dir tempnam
mkdir rmdir unlink chmod is_dir is_file file_exists file_get_contents
file_put_contents file_append serialize unserialize var_dump print_r sprintf
vsprintf set_error_handler error_get_last register_shutdown_function
error_reporting ini_set ini_get php_sapi_name phpversion getenv putenv
curl_init curl_setopt curl_exec curl_getinfo curl_close curl_error curl_errno
escapeshellarg escapeshellcmd scandir array_slice array_splice array_diff_key
array_intersect array_intersect_key array_unique array_reverse array_search
strrpos urldecode rawurldecode rawurlencode ucwords array_shift array_unshift
array_walk array_walk_recursive preg_replace_callback array_fill_keys substr_count
basename is_uploaded_file ob_get_level ob_end_clean ZipArchive hash_file filemtime glob unlink chmod mkdir
""".split())

KEYWORDS = set("""
if else elseif endif while endwhile for endfor foreach endforeach switch endswitch
case default break continue return function fn class new clone echo print exit die
isset unset empty list array match try catch finally throw use namespace require
require_once include include_once global static public private protected abstract
final const extends implements interface trait instanceof as and or xor not
declare enddeclare yield endforeach endif
""".split())

PHP7_RE = [
    (re.compile(r'\?\?'), '?? 空合并运算符(PHP 7.0+)'),
    (re.compile(r'\?->'), '?-> nullsafe(PHP 8.0+)'),
    (re.compile(r'(?<![\w$>])\bmatch\s*\('), 'match 表达式(PHP 8.0+)'),
    (re.compile(r'(?<![\w$])\bfn\s*\('), '箭头函数 fn(PHP 7.4+)'),
    (re.compile(r'\bstr_contains\s*\('), 'str_contains(PHP 8.0+)'),
    (re.compile(r'\bstr_starts_with\s*\('), 'str_starts_with(PHP 8.0+)'),
    (re.compile(r'\bstr_ends_with\s*\('), 'str_ends_with(PHP 8.0+)'),
    (re.compile(r'\bintdiv\s*\('), 'intdiv(PHP 7.0+)'),
    (re.compile(r'\bJSON_THROW_ON_ERROR\b'), 'JSON_THROW_ON_ERROR(PHP 7.3+)'),
    (re.compile(r'\bdeclare\s*\(\s*strict_types'), 'declare(strict_types)(PHP 7.0+)'),
    (re.compile(r'\.\.\.\s*\$'), '展开运算符 ...(PHP 5.6 起支持数组展开, 参数展开 5.6+; 若用于解包请确认)'),
    (re.compile(r'\bfunction\s+\w+\s*\([^)]*\)\s*:\s*\??[A-Za-z_\\]'), '返回值类型声明(PHP 7.0+)'),
    (re.compile(r'\bfunction\s+\w+\s*\([^)]*\b(int|float|string|bool|iterable|object|self)\s+\$'), '标量参数类型声明(PHP 7.0+)'),
    (re.compile(r'\bfunction\s+\w+\s*\([^)]*\?[A-Za-z_\\]+\s+\$'), '可空类型声明(PHP 7.1+)'),
]

FUNC_DEF_RE = re.compile(r'\bfunction\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(')
CALL_RE = re.compile(r'(?<![\w$>:])([A-Za-z_][A-Za-z0-9_]*)\s*\(')
REQUIRE_RE = re.compile(r'\b(?:require|require_once|include|include_once)\b[^;\n]{0,160}?[\'"]([^\'"]+)[\'"]')
POLYFILL_RE = re.compile(r'function_exists\(\s*[\'"]([A-Za-z_][A-Za-z0-9_]*)[\'"]')

# 项目里已经有垫片的函数(在 main 里两遍扫描后填充)
POLYFILLED = set()


def blank_non_php(text):
    """把非 PHP 区域(HTML/CSS/JS)整段替换为空白, 保留换行以保持行号"""
    return ''.join('\n' if ch == '\n' else ' ' for ch in text)


def extract_php(text):
    """
    只保留 <?php ... ?> / <?= ... ?> 里的内容, 其余区域挖空(保持行号)。

    这一步很关键: index.php 是 PHP + HTML 混排, 里面的 CSS 花括号
    (如 body{...}) 如果按 PHP 解析会产生大量假报错。
    """
    out = []
    pos = 0
    n = len(text)
    open_re = re.compile(r'<\?(?:php\b|=)?', re.I)
    while pos < n:
        m = open_re.search(text, pos)
        if not m:
            out.append(blank_non_php(text[pos:]))
            break
        out.append(blank_non_php(text[pos:m.start()]))
        start = m.end()
        end = text.find('?>', start)
        if end == -1:
            out.append(text[start:])
            break
        out.append(text[start:end])
        out.append('  ')  # 占位 '?>' 两个字符, 不引入换行
        pos = end + 2
    return ''.join(out)


class Issue(object):
    def __init__(self, path, line, level, msg):
        self.path, self.line, self.level, self.msg = path, line, level, msg

    def __str__(self):
        loc = self.path if not self.line else "%s:%d" % (self.path, self.line)
        return "[%s] %s: %s" % (self.level, loc, self.msg)


def strip_php(code):
    """把注释、单/双引号字符串、heredoc 内容替换成空白(保留换行以保持行号)"""
    out = []
    i = 0
    n = len(code)
    while i < n:
        c = code[i]
        # 行注释
        if c == '/' and i + 1 < n and code[i + 1] == '/':
            while i < n and code[i] != '\n':
                out.append(' ')
                i += 1
            continue
        if c == '#':
            while i < n and code[i] != '\n':
                out.append(' ')
                i += 1
            continue
        # 块注释
        if c == '/' and i + 1 < n and code[i + 1] == '*':
            out.append('  ')
            i += 2
            while i < n and not (code[i] == '*' and i + 1 < n and code[i + 1] == '/'):
                out.append('\n' if code[i] == '\n' else ' ')
                i += 1
            out.append('  ')
            i += 2
            continue
        # 单引号
        if c == "'":
            out.append("'")
            i += 1
            while i < n:
                if code[i] == '\\' and i + 1 < n:
                    out.append('  ')
                    i += 2
                    continue
                if code[i] == "'":
                    out.append("'")
                    i += 1
                    break
                out.append('\n' if code[i] == '\n' else ' ')
                i += 1
            continue
        # 双引号
        if c == '"':
            out.append('"')
            i += 1
            while i < n:
                if code[i] == '\\' and i + 1 < n:
                    out.append('  ')
                    i += 2
                    continue
                if code[i] == '"':
                    out.append('"')
                    i += 1
                    break
                out.append('\n' if code[i] == '\n' else ' ')
                i += 1
            continue
        # heredoc / nowdoc
        m = re.match(r'<<<[ \t]*[\'"]?([A-Za-z_][A-Za-z0-9_]*)[\'"]?', code[i:])
        if m:
            tag = m.group(1)
            out.append(' ' * len(m.group(0)))
            i += len(m.group(0))
            end = re.search(r'\n[ \t]*' + re.escape(tag) + r'\b', code[i:])
            if end:
                seg = code[i:i + end.start()]
                out.append(''.join('\n' if ch == '\n' else ' ' for ch in seg))
                i += end.start()
            else:
                seg = code[i:]
                out.append(''.join('\n' if ch == '\n' else ' ' for ch in seg))
                i = n
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def check_balance(code_lines, rel):
    pairs = {')': '(', ']': '[', '}': '{'}
    stack = []
    found = []
    for idx, line in enumerate(code_lines):
        for ch in line:
            if ch in '([{':
                stack.append((ch, idx + 1))
            elif ch in ')]}':
                if stack and stack[-1][0] == pairs[ch]:
                    stack.pop()
                else:
                    found.append((idx + 1, "多余的 %s" % ch))
    for ch, ln in stack:
        found.append((ln, "未闭合的 %s" % ch))
    return found


def analyze(path, rel):
    issues = []
    with io.open(path, 'rb') as fh:
        raw = fh.read()
    if raw.startswith(b'\xef\xbb\xbf'):
        issues.append(Issue(rel, 1, '错误', '文件带 UTF-8 BOM'))
        raw = raw[3:]
    if b'\r\n' in raw:
        issues.append(Issue(rel, 0, '错误', '存在 CRLF 换行(PHP 文件会带上多余输出)'))
    try:
        text = raw.decode('utf-8')
    except UnicodeDecodeError:
        issues.append(Issue(rel, 0, '错误', '不是合法 UTF-8'))
        return issues, set()

    if not text.lstrip().startswith('<?php'):
        issues.append(Issue(rel, 1, '错误', '文件没有以 <?php 开头'))
    stripped = text.rstrip()
    if stripped.endswith('?>'):
        issues.append(Issue(rel, 0, '警告', '纯 PHP 文件建议省略结尾 ?> 以免产生额外输出'))

    masked = strip_php(extract_php(text))
    lines = masked.split('\n')

    # 括号配对
    for ln, msg in check_balance(lines, rel):
        issues.append(Issue(rel, ln, '错误', '括号配对问题: ' + msg))

    # 函数定义
    defined = set()
    for m in FUNC_DEF_RE.finditer(masked):
        defined.add(m.group(1))

    # 调用
    called = set()
    for m in CALL_RE.finditer(masked):
        name = m.group(1)
        called.add(name)

    # require 路径(只看 PHP 区域)
    php_text = extract_php(text)
    for m in REQUIRE_RE.finditer(php_text):
        cand = resolve_include(path, m.group(1))
        if cand is None:
            continue
        if not os.path.isfile(cand):
            issues.append(Issue(rel, 0, '错误', 'require/include 的文件不存在: ' + m.group(1)))

    # PHP 版本语法
    for idx, line in enumerate(lines):
        for rx, what in PHP7_RE:
            if rx.search(line):
                issues.append(Issue(rel, idx + 1, '错误', '使用了 %s, 老 PHP(5.6) 会报错' % what))

    # 兼容垫片必须有 function_exists 保护(项目里已有垫片的函数直接放行)
    for fn, why in (('random_bytes', 'PHP 7.0+'), ('password_hash', 'PHP 5.5+'), ('hash_equals', 'PHP 5.6+')):
        if fn in POLYFILLED:
            continue
        for idx, line in enumerate(lines):
            if re.search(r'(?<![\w$])' + fn + r'\s*\(', line):
                # 允许出现在 function_exists('xxx') 判断附近的 3 行内
                window = '\n'.join(lines[max(0, idx - 3):idx + 2])
                if 'function_exists' not in window and 'function ' + fn not in window:
                    issues.append(Issue(rel, idx + 1, '警告',
                                        '%s() 需要 %s, 建议用 function_exists 包一层垫片' % (fn, why)))

    return issues, defined, called


def resolve_include(path, target):
    """
    把 require/include 的字符串解析成绝对路径。

    本项目的写法是 `require_once __DIR__ . '/lib/util.php';`,
    正则只能抓到字符串部分 '/lib/util.php', 所以这里要按"相对当前文件所在目录"来解析
    (否则会被误当成绝对路径而跳过)。
    """
    if target.startswith('$'):
        return None
    t = target.lstrip('/')
    return os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(path)), t))


def include_closure(path, seen=None):
    """
    计算一个 PHP 文件的 require/include 传递闭包(含自身)。

    这一步能抓住"函数定义在别的文件里, 但当前文件没有 require 那个文件"这类
    只有在运行时才会致命、静态看却很正常的错误。
    """
    if seen is None:
        seen = set()
    path = os.path.abspath(path)
    if path in seen:
        return seen
    seen.add(path)
    try:
        with io.open(path, 'rb') as fh:
            text = fh.read().decode('utf-8', 'replace')
    except Exception:
        return seen
    for m in REQUIRE_RE.finditer(extract_php(text)):
        cand = resolve_include(path, m.group(1))
        if cand is None:
            continue
        if os.path.isfile(cand) and os.path.abspath(cand) not in seen:
            include_closure(cand, seen)
    return seen


def main():
    args = list(sys.argv[1:])
    if args and args[0] == '--balance':
        bad = 0
        for t in args[1:]:
            with io.open(t, 'rb') as fh:
                text = fh.read().decode('utf-8', 'replace')
            found = check_balance(strip_php(text).split('\n'), t)
            print('--- %s: %d 处 ---' % (t, len(found)))
            for ln, msg in found:
                print('  %s:%d %s' % (t, ln, msg))
            bad += len(found)
        return 1 if bad else 0

    root = os.path.abspath(args[0]) if args else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    php_files = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ('.git', 'node_modules', 'data', '__pycache__')]
        for fn in sorted(filenames):
            if fn.endswith('.php'):
                php_files.append(os.path.join(dirpath, fn))
    php_files.sort()

    if not php_files:
        print('未找到 PHP 文件')
        return 1

    issues = []
    defined_all = set()
    called_all = set()
    per_file_defined = {}
    per_file_called = {}

    # 第一遍: 收集项目里已有的兼容垫片(被 function_exists 包住的函数)
    for path in php_files:
        with io.open(path, 'rb') as fh:
            text = fh.read().decode('utf-8', 'replace')
        php_text = extract_php(text)
        for m in POLYFILL_RE.finditer(php_text):
            POLYFILLED.add(m.group(1))

    for path in php_files:
        rel = os.path.relpath(path, root).replace('\\', '/')
        iss, defined, called = analyze(path, rel)
        issues.extend(iss)
        defined_all.update(defined)
        called_all.update(called)
        per_file_defined[os.path.abspath(path)] = defined
        per_file_called[os.path.abspath(path)] = called

    # 包含闭包检查: 只对"入口文件"(没有被任何文件 require 的文件)生效。
    # 库文件本来就不互相 require(由入口统一引入), 对它们做这个检查全是误报。
    included = set()
    for path in php_files:
        for f in include_closure(path):
            if os.path.abspath(f) != os.path.abspath(path):
                included.add(os.path.abspath(f))
    entry_points = [p for p in php_files if os.path.abspath(p) not in included]

    for path in entry_points:
        rel = os.path.relpath(path, root).replace('\\', '/')
        closure = include_closure(path)
        available = set()
        for f in closure:
            available |= per_file_defined.get(os.path.abspath(f), set())
        for name in sorted(per_file_called.get(os.path.abspath(path), set())):
            if not name.startswith('vpnx_'):
                continue
            if name in available:
                continue
            if name in defined_all:
                issues.append(Issue(rel, 0, '错误',
                                    '调用了 %s, 但它定义在未 require 的文件里(运行时会致命)' % name))

    # 跨文件函数一致性: 只严格检查 vpnx_ 前缀(内置函数可能不在白名单里)
    for name in sorted(called_all):
        if name in defined_all or name in BUILTINS or name in KEYWORDS:
            continue
        if name.startswith('vpnx_'):
            issues.append(Issue('(跨文件)', 0, '错误', '调用了未定义的函数 ' + name))
        else:
            issues.append(Issue('(跨文件)', 0, '提示', '未识别的函数调用(请人工确认): ' + name))

    errors = [i for i in issues if i.level == '错误']
    warns = [i for i in issues if i.level == '警告']
    tips = [i for i in issues if i.level == '提示']

    print('=' * 74)
    print('vpnx PHP 静态检查: %d 个文件' % len(php_files))
    print('  ' + ', '.join(sorted(os.path.relpath(p, root).replace('\\', '/') for p in php_files)))
    print('=' * 74)
    for i in issues:
        print(i)
    print('-' * 74)
    print('结果: %d 个错误, %d 个警告, %d 个提示' % (len(errors), len(warns), len(tips)))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
