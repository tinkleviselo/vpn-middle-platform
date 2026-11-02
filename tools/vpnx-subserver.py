#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
vpnx-subserver.py - vpnx 可选的内置订阅服务

特点:
  * 同时兼容 python2.7 与 python3 (老系统无需装 python3)
  * 零第三方依赖, 只用标准库
  * 只读 /etc/vpnx/sub 目录下的订阅文件, 路径严格校验, 防目录穿越
  * 高位端口监听, 不占用 80/443, 不与 建站面板的 nginx/apache 冲突
  * 支持 /sub/<token>、/sub/<token>/clash、/sub/<token>/singbox 与 ?target=

用法:
  python vpnx-subserver.py --dir /etc/vpnx/sub --host 0.0.0.0 --port 18080
"""

from __future__ import print_function

import io
import os
import re
import sys
import base64

try:
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from socketserver import ThreadingMixIn
    from urllib.parse import urlparse, parse_qs
    PY3 = True
except ImportError:  # python2
    from BaseHTTPServer import BaseHTTPRequestHandler, HTTPServer
    from SocketServer import ThreadingMixIn
    from urlparse import urlparse, parse_qs
    PY3 = False

VERSION = "1.0.0"
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
DEFAULT_INTERVAL = "12"


def log(msg):
    sys.stderr.write("[vpnx-sub] %s\n" % msg)
    sys.stderr.flush()


def read_text(path):
    """读取文本文件, 兼容 py2/py3 与小文件场景。"""
    try:
        with io.open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except Exception:
        return ""


def parse_meta(path):
    """解析 <token>.meta -> dict(upload/download/total/expire)"""
    meta = {}
    text = read_text(path)
    for line in text.splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        meta[k.strip()] = v.strip()
    return meta


def userinfo_header(meta):
    """生成 Subscription-Userinfo 头。"""
    def num(key):
        v = meta.get(key, "0")
        try:
            return int(float(v))
        except Exception:
            return 0
    upload = num("upload")
    download = num("download")
    total = num("total")
    expire = num("expire")
    return "upload=%d; download=%d; total=%d; expire=%d" % (upload, download, total, expire)


class Handler(BaseHTTPRequestHandler):
    server_version = "vpnx-sub/" + VERSION
    protocol_version = "HTTP/1.1"

    # ---- 工具 ----
    def _send(self, code, body, ctype="text/plain; charset=utf-8", extra=None):
        if not isinstance(body, bytes):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def _notfound(self, why="not found"):
        self._send(404, "not found\n")

    # ---- 路由 ----
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path or "/"
        query = parse_qs(parsed.query or "")

        if path in ("/", "/health", "/healthz"):
            self._send(200, "vpnx-subserver %s ok\n" % VERSION)
            return

        parts = [p for p in path.split("/") if p]
        if len(parts) < 2 or parts[0] != "sub":
            self._notfound()
            return

        token = parts[1]
        if not TOKEN_RE.match(token):
            self._notfound()
            return

        # ?target= / ?format= 与路径后缀等价
        target = ""
        if "target" in query and query["target"]:
            target = query["target"][0].lower()
        elif "format" in query and query["format"]:
            target = query["format"][0].lower()
        if len(parts) >= 3:
            target = parts[2].lower()

        base = os.path.join(self.server.sub_dir, token)
        meta = parse_meta(base + ".meta")
        headers = {
            "Subscription-Userinfo": userinfo_header(meta),
            "Profile-Update-Interval": DEFAULT_INTERVAL,
        }

        if target in ("clash", "clashmeta", "mihomo"):
            body = read_text(base + ".clash")
            if not body:
                self._notfound()
                return
            self._send(200, body, "text/yaml; charset=utf-8", headers)
            return

        if target in ("singbox", "sing-box"):
            # 未内置 sing-box 模板时, 回退为 base64 链接列表
            body = read_text(base + ".txt")
            if not body:
                self._notfound()
                return
            self._send(200, body, "text/plain; charset=utf-8", headers)
            return

        body = read_text(base + ".txt")
        if not body:
            self._notfound()
            return

        if target in ("raw", "plain", "base64decode"):
            raw = read_text(base + ".raw")
            if not raw:
                try:
                    if PY3:
                        raw = base64.b64decode(body.encode("utf-8")).decode("utf-8", "replace")
                    else:
                        raw = base64.b64decode(body)
                except Exception:
                    raw = body
            self._send(200, raw, "text/plain; charset=utf-8", headers)
            return

        self._send(200, body, "text/plain; charset=utf-8", headers)

    def do_HEAD(self):
        self.do_GET()

    def log_message(self, fmt, *args):
        # 精简访问日志: 只记录路径与状态
        log("%s - %s" % (self.address_string(), fmt % args))


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def usage():
    print(__doc__)
    print("参数:")
    print("  --dir <订阅目录>   默认 /etc/vpnx/sub")
    print("  --host <监听地址>  默认 0.0.0.0")
    print("  --port <端口>      默认 18080")


def main(argv):
    sub_dir = "/etc/vpnx/sub"
    host = "0.0.0.0"
    port = 18080

    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--dir" and i + 1 < len(argv):
            sub_dir = argv[i + 1]; i += 2; continue
        if a == "--host" and i + 1 < len(argv):
            host = argv[i + 1]; i += 2; continue
        if a == "--port" and i + 1 < len(argv):
            try:
                port = int(argv[i + 1])
            except Exception:
                pass
            i += 2; continue
        if a in ("-h", "--help"):
            usage(); return 0
        if a in ("-v", "--version"):
            print(VERSION); return 0
        log("忽略未知参数: %s" % a)
        i += 1

    if not os.path.isdir(sub_dir):
        log("订阅目录不存在: %s" % sub_dir)
        return 2

    try:
        httpd = ThreadingHTTPServer((host, port), Handler)
    except Exception as exc:
        log("监听 %s:%s 失败: %s" % (host, port, exc))
        return 1

    httpd.sub_dir = sub_dir
    log("启动: http://%s:%d/sub/<token>  目录=%s" % (host, port, sub_dir))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("收到中断, 退出")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
