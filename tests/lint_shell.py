#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
lint_shell.py - vpnx 的 bash 静态检查器(零依赖, 兼容 python2.7 / python3)

在没有 bash 可用的环境下(例如 Windows 开发机)也能做这些事:
  1. 换行符必须是 LF(CRLF 会让内核找不到解释器); 无 BOM; 首行 shebang
  2. 关键块关键字配对: if/fi, case/esac, do/done —— 栈式扫描, 精确到行号
     * 先剥掉 heredoc 正文、注释、单引号串内容;
       双引号串内容也会被剥掉, 但其中的 $(...) 命令替换会被正确识别并继续扫描,
       因此内嵌 awk / python / JSON / systemd 单元都不会造成误报
  3. vpnx.sh 声明的模块列表与实际 lib 文件一致, dispatcher 调用的 cmd_* 有定义
  4. 跨文件函数定义/调用一致性(抓拼写错误的函数名, 排除赋值语句)
  5. 禁止 bash4+ 专有语法(declare -A / mapfile / ${var,,} / ${var^^})
  6. 空数组展开在 set -u 下的老 bash 陷阱
  7. source 引用的文件存在性
  8. 若有 bash, 追加 bash -n 语法检查

用法:
  python tests/lint_shell.py [仓库根目录]
  python tests/lint_shell.py --balance <脚本...>     # 只打印配对问题与行号
退出码: 0=全部通过, 1=有错误
"""

from __future__ import print_function

import io
import os
import re
import subprocess
import sys

SHELL_KEYWORDS = set("""
if then else elif fi case esac for while until do done in function select time
return break continue exit local export readonly declare typeset unset shift set
source eval exec trap wait true false test command builtin let read printf echo cd
pwd umask alias unalias getopts type hash jobs bg fg kill disown times suspend
""".split())

EXTERNAL_CMDS = set("""
printf echo awk sed grep egrep fgrep cat rm cp mv mkdir chmod chown chgrp ln install
tar unzip zip gzip bsdtar curl wget openssl sha256sum sha1sum md5sum base64 tr cut
sort uniq head tail wc date sleep kill pgrep pkill pstree nohup id whoami hostname
uname df du free ip ss netstat lsof iptables ip6tables nft ufw firewall-cmd csf
systemctl service rc-service rc-update chkconfig update-rc.d crontab runlevel
modprobe sysctl python python3 python2 jq od mktemp cmp diff find xargs tee touch
sync env su sudo useradd usermod groupadd getent stat readlink realpath basename
dirname seq expr timeout nice ionice dd split tac rev paste column less more vi
which whereis file strings ldd mount umount blkid lsblk swapon swapoff mkswap
""".split())

OUR_PREFIXES = (
    "cmd_", "agent_", "user_", "users_", "sub_", "health_", "bbr_", "fw_",
    "xray_", "api_", "cfg_", "config_", "profile_", "os_", "port_", "pick_",
    "listen_", "sched_", "svc_", "pkg_", "json_", "stats_", "kv_", "lock_",
    "tmp_", "ensure_", "detect_", "proto_", "parse_", "size_", "bytes_",
    "epoch_", "rand_", "gen_", "b64_", "sha256_", "url_", "apply_config",
    "render_config", "require_", "backup_file", "atomic_write", "opt_val",
    "has_flag", "version_ge", "kernel_ge", "systemd_ver_ge", "ss_psk_len",
    "reality_gen_keys", "xray_gen_short_id", "_render", "_policy", "_profile",
    "_agent", "_events", "_resp", "_health", "_fw", "_ipt", "_sched",
    "_download", "_log", "_csf", "_json",
)

HEREDOC_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
FUNC_DEF_RE = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)")
BASH4_RE = [
    (re.compile(r"\bdeclare\s+-A\b"), "declare -A (关联数组, bash4+)"),
    (re.compile(r"\bmapfile\b"), "mapfile (bash4+)"),
    (re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*,,?[^}]*\}"), "${var,,} 小写展开 (bash4+)"),
    (re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\^\^?[^}]*\}"), "${var^^} 大写展开 (bash4+)"),
]
EMPTY_ARRAY_RE = re.compile(r'"\$\{([A-Za-z_][A-Za-z0-9_]*)\[@\]\}"')
KW_RE = re.compile(r"(?<![A-Za-z0-9_$])(if|fi|case|esac|do|done)(?![A-Za-z0-9_])")


class Issue(object):
    def __init__(self, path, line, level, msg):
        self.path, self.line, self.level, self.msg = path, line, level, msg

    def __str__(self):
        loc = self.path if not self.line else "%s:%d" % (self.path, self.line)
        return "[%s] %s: %s" % (self.level, loc, self.msg)


# ---------------------------------------------------------------------------
# 第一步: heredoc 正文挖空(保持行号与换行)
# ---------------------------------------------------------------------------
def blank_heredocs(text):
    lines = text.split("\n")
    out = []
    in_heredoc = None
    for raw in lines:
        if in_heredoc is not None:
            if raw.strip() == in_heredoc:
                in_heredoc = None
            out.append("")
            continue
        out.append(raw)
        m = HEREDOC_RE.search(raw)
        if m:
            in_heredoc = m.group(2)
    return "\n".join(out)


# ---------------------------------------------------------------------------
# 第二步: 词法遮罩
#   keep_strings=False -> 注释/单引号/双引号内容挖空(但 $(...) 内部继续按代码扫描)
#   keep_strings=True  -> 只挖空注释(用于检查写在引号里的 ${var,,} 等)
# ---------------------------------------------------------------------------
def mask(text, keep_strings=False, quote_issues=None):
    out = list(text)
    n = len(text)

    def blank(a, b):
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "

    def is_comment_start(i):
        if i == 0:
            return True
        prev = text[i - 1]
        return prev in " \t;&|(" or prev == "\n"

    def scan_dquote(i):
        """i 指向开引号之后"""
        start = i - 1
        while i < n:
            c = text[i]
            if c == "\\":
                i += 2
                continue
            if c == '"':
                return i + 1
            if c == "$" and i + 1 < n and text[i + 1] == "(":
                i = scan_sub(i + 1)
                continue
            if c == "`":
                i = scan_seq(i + 1, "`")
                if i < n:
                    i += 1
                continue
            if not keep_strings and c != "\n":
                out[i] = " "
            i += 1
        if quote_issues is not None:
            quote_issues.append((text.count("\n", 0, start) + 1, "双引号未闭合"))
        return i

    def scan_sub(i):
        """i 指向 '(' —— 命令替换内部是真实代码, 继续扫描"""
        depth = 1
        i += 1
        while i < n and depth > 0:
            c = text[i]
            if c == "\\":
                i += 2
                continue
            if c == "'":
                j = text.find("'", i + 1)
                if j == -1:
                    if quote_issues is not None:
                        quote_issues.append((text.count("\n", 0, i) + 1, "单引号未闭合"))
                    j = n - 1
                blank(i + 1, j)
                i = j + 1
                continue
            if c == '"':
                i = scan_dquote(i + 1)
                continue
            if c == "(":
                depth += 1
                i += 1
                continue
            if c == ")":
                depth -= 1
                i += 1
                continue
            if c == "#" and is_comment_start(i):
                j = text.find("\n", i)
                if j == -1:
                    j = n
                blank(i, j)
                i = j
                continue
            if c == "$" and i + 1 < n and text[i + 1] == "(":
                i = scan_sub(i + 1)
                continue
            if c == "`":
                i = scan_seq(i + 1, "`")
                if i < n:
                    i += 1
                continue
            i += 1
        return i

    def scan_seq(i, stop):
        while i < n:
            c = text[i]
            if c == "\\":
                i += 2
                continue
            if stop is not None and c == stop:
                return i
            if c == "'":
                j = text.find("'", i + 1)
                if j == -1:
                    if quote_issues is not None:
                        quote_issues.append((text.count("\n", 0, i) + 1, "单引号未闭合"))
                    j = n - 1
                blank(i + 1, j)
                i = j + 1
                continue
            if c == '"':
                i = scan_dquote(i + 1)
                continue
            if c == "#" and is_comment_start(i):
                j = text.find("\n", i)
                if j == -1:
                    j = n
                blank(i, j)
                i = j
                continue
            if c == "$" and i + 1 < n and text[i + 1] == "(":
                i = scan_sub(i + 1)
                continue
            if c == "`":
                i = scan_seq(i + 1, "`")
                if i < n:
                    i += 1
                continue
            i += 1
        return i

    scan_seq(0, None)
    return "".join(out)


def words_in_command_position(code):
    """命令行首位置的标识符(排除 NAME=... 赋值)"""
    parts = re.split(r"(?:;|&&|\|\||\||\$\(|`|\bthen\b|\bdo\b|\belse\b|\bif\b|\{|\})", code)
    out = []
    for p in parts:
        p = p.strip()
        if not p:
            continue
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\b(.*)$", p)
        if not m:
            continue
        name, rest = m.group(1), m.group(2)
        if rest.startswith("=") and not rest.startswith("=="):
            continue
        out.append(name)
    return out


def balance_issues(code_lines):
    stack = []
    found = []
    for idx, code in enumerate(code_lines):
        no = idx + 1
        for kw in KW_RE.findall(code):
            if kw in ("if", "case", "do"):
                stack.append((kw, no))
            elif kw == "fi":
                if stack and stack[-1][0] == "if":
                    stack.pop()
                else:
                    found.append((no, "多余的 fi(栈顶: %s)" % (stack[-1][0] if stack else "空")))
            elif kw == "esac":
                if stack and stack[-1][0] == "case":
                    stack.pop()
                else:
                    found.append((no, "多余的 esac(栈顶: %s)" % (stack[-1][0] if stack else "空")))
            elif kw == "done":
                if stack and stack[-1][0] == "do":
                    stack.pop()
                else:
                    found.append((no, "多余的 done(栈顶: %s)" % (stack[-1][0] if stack else "空")))
    for kw, no in stack:
        found.append((no, "未闭合的 %s(在第 %d 行打开)" % (kw, no)))
    return sorted(found)


def paren_balance(code_lines):
    """
    检查 ( ) 配平(遮罩后的代码里)。

    规则: 遇到栈空的 `)` 时, 若本行该位置之前没有 `(`, 判定为 case 分支的终结符
    (如 `udp) ... ;;`), 跳过; 否则就是多余右括号 —— 用来抓
    `printf '%s' "$(cmd)")` 这类低级错误。
    """
    findings = []
    stack = []
    for idx, line in enumerate(code_lines):
        no = idx + 1
        i = 0
        n = len(line)
        while i < n:
            c = line[i]
            if c == "\\":
                i += 2
                continue
            if c == "$" and i + 1 < n and line[i + 1] == "(":
                stack.append(("subst", no))
                i += 2
                continue
            if c == "(":
                stack.append(("paren", no))
                i += 1
                continue
            if c == ")":
                # 栈空且本行该位置之前没有 '(' -> 这是 case 分支的 ) 终结符(如 `udp) ...`)
                if not stack and line.rfind("(", 0, i) == -1:
                    i += 1
                    continue
                if stack:
                    stack.pop()
                else:
                    findings.append((no, "多余的 )"))
                i += 1
                continue
            i += 1
    for kind, no in stack:
        findings.append((no, "未闭合的 %s" % ("$(" if kind == "subst" else "(")))
    return findings


def analyze(path, rel):
    issues = []
    with io.open(path, "rb") as fh:
        data = fh.read()

    if data.startswith(b"\xef\xbb\xbf"):
        issues.append(Issue(rel, 1, "错误", "文件带 UTF-8 BOM, bash 会报错"))
        data = data[3:]
    if b"\r\n" in data:
        issues.append(Issue(rel, 0, "错误", "存在 CRLF 换行(bash 脚本必须是 LF)"))

    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        issues.append(Issue(rel, 0, "错误", "不是合法 UTF-8"))
        return issues, set(), set()

    if not text.startswith("#!"):
        issues.append(Issue(rel, 1, "错误", "第一行缺少 shebang"))

    body = blank_heredocs(text)
    quote_issues = []
    code_lines = mask(body, keep_strings=False, quote_issues=quote_issues).split("\n")
    str_lines = mask(body, keep_strings=True).split("\n")

    for no, msg in quote_issues:
        issues.append(Issue(rel, no, "错误", "引号未闭合: " + msg))
    for no, msg in paren_balance(code_lines):
        issues.append(Issue(rel, no, "错误", "括号不配平: " + msg))

    defined = set()
    called = set()
    for idx, code in enumerate(code_lines):
        no = idx + 1
        m = FUNC_DEF_RE.match(code)
        if m:
            defined.add(m.group(1))
        for name in words_in_command_position(code):
            called.add(name)
        for rx, what in BASH4_RE:
            if rx.search(str_lines[idx]):
                issues.append(Issue(rel, no, "错误", "使用了 %s, 老系统可能不支持" % what))
        for m2 in EMPTY_ARRAY_RE.finditer(str_lines[idx]):
            arr = m2.group(1)
            if ("%s[@]+" % arr) not in str_lines[idx]:
                issues.append(Issue(rel, no, "警告",
                                    '"${%s[@]}" 在 bash<=4.3 + set -u 下会报 unbound variable, '
                                    '建议写成 ${%s[@]+"${%s[@]}"}' % (arr, arr, arr)))

    for no, msg in balance_issues(code_lines):
        issues.append(Issue(rel, no, "错误", "块关键字配对问题: " + msg))

    return issues, defined, called


def collect_shell_files(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
        for fn in sorted(filenames):
            if fn.endswith(".sh") or fn == "vpnx.sh":
                out.append(os.path.join(dirpath, fn))
    out.sort()
    return out


def main():
    args = list(sys.argv[1:])
    if args and args[0] == "--balance":
        targets = args[1:]
        if not targets:
            print("用法: python tests/lint_shell.py --balance <脚本...>")
            return 2
        bad = 0
        for t in targets:
            rel = t.replace("\\", "/")
            with io.open(t, "rb") as fh:
                text = fh.read().decode("utf-8", "replace")
            found = balance_issues(mask(blank_heredocs(text), keep_strings=False).split("\n"))
            print("--- %s: %d 处 ---" % (rel, len(found)))
            for no, msg in found:
                print("  %s:%d %s" % (rel, no, msg))
            bad += len(found)
        return 1 if bad else 0

    root = os.path.abspath(args[0]) if args else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    sh_files = collect_shell_files(root)
    if not sh_files:
        print("未找到 shell 脚本")
        return 1

    issues = []
    defined_all = set()
    called_all = set()
    for path in sh_files:
        rel = os.path.relpath(path, root).replace("\\", "/")
        iss, defined, called = analyze(path, rel)
        issues.extend(iss)
        defined_all.update(defined)
        called_all.update(called)

    vpnx_sh = os.path.join(root, "vpnx.sh")
    if os.path.isfile(vpnx_sh):
        with io.open(vpnx_sh, "r", encoding="utf-8", errors="replace") as fh:
            content = fh.read()
        m = re.search(r'VPNX_LIBS="([^"]+)"', content)
        if m:
            for mod in m.group(1).split():
                if not os.path.isfile(os.path.join(root, "lib", mod + ".sh")):
                    issues.append(Issue("vpnx.sh", 0, "错误", "模块列表里的 lib/%s.sh 不存在" % mod))
        else:
            issues.append(Issue("vpnx.sh", 0, "错误", "未找到 VPNX_LIBS 模块列表"))
        for cmdfn in sorted(set(re.findall(r"\b(cmd_[a-z_]+)\b", content))):
            if cmdfn not in defined_all:
                issues.append(Issue("vpnx.sh", 0, "错误", "调用了未定义的函数 %s" % cmdfn))

    for name in sorted(called_all):
        if name in defined_all or name in SHELL_KEYWORDS or name in EXTERNAL_CMDS:
            continue
        if name.startswith(OUR_PREFIXES):
            issues.append(Issue("(跨文件)", 0, "错误", "调用了未定义的函数 %s" % name))

    for path in sh_files:
        rel = os.path.relpath(path, root).replace("\\", "/")
        with io.open(path, "r", encoding="utf-8", errors="replace") as fh:
            body = fh.read()
        for no, line in enumerate(mask(blank_heredocs(body), keep_strings=False).split("\n"), 1):
            for m in re.finditer(r"(?:^|\s)(?:source|\.)\s+([^\s;]+)", line):
                target = m.group(1)
                if target.startswith("$") or target.startswith("/"):
                    continue
                if target.endswith(".sh") and not os.path.isfile(os.path.join(os.path.dirname(path), target)):
                    issues.append(Issue(rel, no, "警告", "source 的文件不存在: %s" % target))

    bash = None
    for cand in ("bash", "/bin/bash", "/usr/bin/bash"):
        try:
            p = subprocess.Popen([cand, "-c", "true"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            p.communicate()
            if p.returncode == 0:
                bash = cand
                break
        except Exception:
            continue
    if bash:
        for path in sh_files:
            rel = os.path.relpath(path, root).replace("\\", "/")
            p = subprocess.Popen([bash, "-n", path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            out, err = p.communicate()
            if p.returncode != 0:
                msg = (err or out).decode("utf-8", "replace").strip().replace("\n", " | ")
                issues.append(Issue(rel, 0, "错误", "bash -n 失败: %s" % msg))
    else:
        print("提示: 未找到 bash, 跳过 bash -n(其余检查仍然有效)")

    errors = [i for i in issues if i.level == "错误"]
    warns = [i for i in issues if i.level == "警告"]

    print("=" * 74)
    print("vpnx shell 静态检查: %d 个脚本" % len(sh_files))
    print("  " + ", ".join(sorted(os.path.relpath(p, root).replace("\\", "/") for p in sh_files)))
    print("=" * 74)
    for i in issues:
        print(i)
    print("-" * 74)
    print("结果: %d 个错误, %d 个警告" % (len(errors), len(warns)))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
