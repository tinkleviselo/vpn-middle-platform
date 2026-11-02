#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""VPN 节点中台（central）零依赖参考实现。

本模块同时承担两个角色：

1. HTTP 服务入口::

       python3 server.py --data-dir ./data --admin-token xxx --host 0.0.0.0 --port 8787

2. 业务逻辑库：``centralctl.py`` 以 ``--data-dir`` 直连模式复用
   :class:`Store` / :class:`Central`，无需经过 HTTP。

依赖：仅 Python 3.6+ 标准库（禁止第三方包）。

数据目录结构::

    <data-dir>/nodes.json                    节点清单（含 secret、最近心跳、ack 结果）
    <data-dir>/policies/<node_id>.json       节点策略文档
    <data-dir>/usage/<node_id>.jsonl         用量明细（追加写）
    <data-dir>/usage/<node_id>.summary.json  用量聚合视图
    <data-dir>/subscriptions.json            订阅发布内容（按 sub_token 索引）
    <data-dir>/events/<node_id>.jsonl        节点事件（追加写）
    <data-dir>/admin.token                   未显式提供 --admin-token 时首次生成并落盘
"""

import argparse
import base64
import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, unquote, urlparse

try:  # Python 3.7+
    from http.server import ThreadingHTTPServer
except ImportError:  # pragma: no cover - Python 3.6 兼容分支
    import socketserver

    class ThreadingHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
        """Python 3.6 没有 http.server.ThreadingHTTPServer，这里手工组合。"""

        daemon_threads = True


log = logging.getLogger("vpnx.central")

VERSION = "1.0.0"
DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8787
DEFAULT_DATA_DIR = "./data"
CLOCK_SKEW_SEC = 300
NONCE_WINDOW_SEC = 300
HEARTBEAT_INTERVAL_SEC = 60
ONLINE_THRESHOLD_SEC = 180
POLICY_TTL_SEC = 7 * 24 * 3600
MAX_BODY_BYTES = 4 * 1024 * 1024
JSON_CONTENT_TYPE = "application/json; charset=utf-8"
TEXT_CONTENT_TYPE = "text/plain; charset=utf-8"

#: 节点 ID 白名单：首字符必须是字母或数字，杜绝 "." / ".." / 分隔符穿越
NODE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
#: 订阅 token 白名单
SUB_TOKEN_RE = re.compile(r"^[A-Za-z0-9_.-]{4,128}$")
#: /api/v1/admin/nodes/<id>[/<action>]
ADMIN_NODE_RE = re.compile(r"^/api/v1/admin/nodes/([^/]+)(?:/(rotate|policy|usage))?$")


# ---------------------------------------------------------------------------
# 通用小工具
# ---------------------------------------------------------------------------
def as_int(value, default=0):
    """把任意值尽量转成 int。

    参数:
        value: 待转换的值（bool/int/float/str 均可）
        default: 转换失败时的返回值
    返回:
        int
    """
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        try:
            return int(value)
        except (ValueError, OverflowError):
            return default
    if isinstance(value, str):
        text = value.strip()
        try:
            return int(text)
        except ValueError:
            try:
                return int(float(text))
            except ValueError:
                return default
    return default


def now_ts():
    """返回当前 Unix 时间戳（整数秒）。"""
    return int(time.time())


def validate_node_id(node_id):
    """校验节点 ID 合法性，防止目录穿越。

    参数:
        node_id: 待校验的节点 ID
    返回:
        规范化后的节点 ID
    异常:
        ValueError: 类型不对或不符合白名单
    """
    if not isinstance(node_id, str):
        raise ValueError("node_id 必须是字符串")
    node_id = node_id.strip()
    if not NODE_ID_RE.match(node_id) or ".." in node_id:
        raise ValueError("非法的 node_id: %r" % (node_id,))
    return node_id


def validate_sub_token(token):
    """校验订阅 token 合法性（同时用于防目录穿越）。"""
    if not isinstance(token, str):
        raise ValueError("sub_token 必须是字符串")
    token = token.strip()
    if not SUB_TOKEN_RE.match(token) or ".." in token:
        raise ValueError("非法的 sub_token")
    return token

def atomic_write_text(path, text):
    """原子写入文本文件：先写同目录临时文件，再 ``os.replace`` 覆盖。

    参数:
        path: 目标文件绝对/相对路径
        text: 要写入的文本（UTF-8）
    返回:
        None
    """
    directory = os.path.dirname(os.path.abspath(path))
    if directory and not os.path.isdir(directory):
        os.makedirs(directory)
    tmp = "%s.tmp.%d.%d" % (path, os.getpid(), threading.current_thread().ident or 0)
    with open(tmp, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
        handle.flush()
        try:
            os.fsync(handle.fileno())
        except OSError:  # 某些文件系统不支持 fsync
            pass
    os.replace(tmp, path)


def flatten(obj, prefix=""):
    """把嵌套结构扁平化成 ``[(点号路径, 标量)]``。

    参数:
        obj: 任意 JSON 兼容对象
        prefix: 递归时累积的前缀
    返回:
        list，元素为 (key, value)，key 使用点号扁平化，如 ``users.0.action``
    """
    items = []
    if isinstance(obj, dict):
        for key in obj:
            child = "%s.%s" % (prefix, key) if prefix else str(key)
            items.extend(flatten(obj[key], child))
    elif isinstance(obj, (list, tuple)):
        for index, value in enumerate(obj):
            child = "%s.%d" % (prefix, index) if prefix else str(index)
            items.extend(flatten(value, child))
    else:
        items.append((prefix, obj))
    return items


def to_lines(obj):
    """把对象渲染成 ``key=value`` 逐行文本（供无 jq/python 的老节点使用）。

    参数:
        obj: 任意 JSON 兼容对象
    返回:
        str，每行一个 ``key=value``，末尾带换行；空对象返回空串
    """
    lines = []
    for key, value in flatten(obj):
        if value is True:
            text = "true"
        elif value is False:
            text = "false"
        elif value is None:
            text = ""
        else:
            text = str(value)
        lines.append("%s=%s" % (key, text))
    return "\n".join(lines) + ("\n" if lines else "")


def default_policy(node_id):
    """构造节点的默认（空）策略文档。

    参数:
        node_id: 节点 ID
    返回:
        dict 策略文档，revision 固定为 0
    """
    issued = now_ts()
    return {
        "revision": 0,
        "node_id": node_id,
        "issued_at": issued,
        "expires_at": issued + POLICY_TTL_SEC,
        "node": {
            "reality_target": "",
            "reality_server_names": [],
            "ports": {},
            "inbounds": [],
            "log_level": "warning",
            "bbr": True,
            "allow_protocols": ["vless-reality", "ss2022", "vmess-ws"],
        },
        "users": [],
        "profiles": {},
        "maintenance": {
            "window": "03:00-04:00",
            "auto_update": True,
            "max_xray_version": "",
        },
    }


def normalize_policy(node_id, body):
    """补齐策略文档缺省字段（保留调用方给的值）。

    参数:
        node_id: 节点 ID
        body: 调用方提交的策略片段
    返回:
        归一化后的完整策略文档
    """
    base = default_policy(node_id)
    doc = dict(body or {})
    for key, value in base.items():
        if key not in doc or doc[key] is None:
            doc[key] = value
    if not isinstance(doc.get("node"), dict):
        doc["node"] = base["node"]
    else:
        merged = dict(base["node"])
        merged.update(doc["node"])
        doc["node"] = merged
    if not isinstance(doc.get("users"), list):
        doc["users"] = []
    if not isinstance(doc.get("profiles"), dict):
        doc["profiles"] = {}
    if not isinstance(doc.get("maintenance"), dict):
        doc["maintenance"] = {}
    else:
        merged = dict(base["maintenance"])
        merged.update(doc["maintenance"])
        doc["maintenance"] = merged
    return doc


class Result(object):
    """统一的业务返回结构。

    参数:
        status: HTTP 状态码
        payload: dict（按 JSON 编码）或 str（按文本编码）
        content_type: 覆盖默认 Content-Type
        headers: 额外响应头 dict
    """

    __slots__ = ("status", "payload", "content_type", "headers")

    def __init__(self, status, payload, content_type=None, headers=None):
        self.status = status
        self.payload = payload
        self.content_type = content_type
        self.headers = headers or {}


def json_result(status, payload, headers=None):
    """构造 JSON 结果。"""
    return Result(status, payload, JSON_CONTENT_TYPE, headers)


def error_result(status, message):
    """构造错误结果：``{"ok": false, "error": ...}``。"""
    return json_result(status, {"ok": False, "error": message})


class RequestError(Exception):
    """HTTP 层请求解析错误（携带状态码）。"""

    def __init__(self, status, message):
        Exception.__init__(self, message)
        self.status = status
        self.message = message


class Config(object):
    """运行配置。

    参数:
        data_dir: 数据目录
        admin_token: 管理员 token（None/"" 时由 main 生成）
        host: 监听地址
        port: 监听端口
        public_base: 订阅对外基址（如 https://vpn.example.com/sub/），空则按 Host 头推导
        sub_scheme: 推导 sub_base 时使用的协议，默认 https
        heartbeat_interval: 心跳建议间隔（秒）
        clock_skew: 允许的时钟偏差（秒）
        nonce_window: nonce 去重窗口（秒）
    """

    def __init__(self, data_dir=DEFAULT_DATA_DIR, admin_token=None, host=DEFAULT_HOST,
                 port=DEFAULT_PORT, public_base="", sub_scheme="https",
                 heartbeat_interval=HEARTBEAT_INTERVAL_SEC, clock_skew=CLOCK_SKEW_SEC,
                 nonce_window=NONCE_WINDOW_SEC, script_version=VERSION,
                 script_url="", script_sha256=""):
        self.data_dir = data_dir
        self.admin_token = admin_token or ""
        self.host = host
        self.port = int(port)
        self.public_base = (public_base or "").rstrip("/") + "/" if public_base else ""
        self.sub_scheme = sub_scheme or "https"
        self.heartbeat_interval = int(heartbeat_interval)
        self.clock_skew = int(clock_skew)
        self.nonce_window = int(nonce_window)
        self.script_version = script_version
        self.script_url = script_url
        self.script_sha256 = script_sha256


# ---------------------------------------------------------------------------
# 存储层
# ---------------------------------------------------------------------------
class Store(object):
    """JSON 文件存储层：原子写 + ``threading.RLock`` 并发保护。

    参数:
        data_dir: 数据根目录（不存在会自动创建）
    属性:
        base: 数据根目录绝对路径
        lock: 可重入锁，所有读写都应持有它
    """

    def __init__(self, data_dir):
        self.base = os.path.abspath(data_dir)
        self.policies_dir = os.path.join(self.base, "policies")
        self.usage_dir = os.path.join(self.base, "usage")
        self.events_dir = os.path.join(self.base, "events")
        self.lock = threading.RLock()
        for path in (self.base, self.policies_dir, self.usage_dir, self.events_dir):
            if not os.path.isdir(path):
                os.makedirs(path)

    # -- 路径安全 ----------------------------------------------------------
    def safe_path(self, *parts):
        """拼接数据目录下的路径，并确保不越出数据目录。

        参数:
            *parts: 相对数据目录的路径片段（必须是可信字面量，节点 ID 先过白名单）
        返回:
            绝对路径
        异常:
            ValueError: 发生目录穿越
        """
        joined = os.path.abspath(os.path.join(self.base, *parts))
        if joined != self.base and not joined.startswith(self.base + os.sep):
            raise ValueError("path escapes data dir: %r" % (parts,))
        return joined

    def nodes_path(self):
        """nodes.json 路径。"""
        return self.safe_path("nodes.json")

    def policy_path(self, node_id):
        """策略文件路径。"""
        return self.safe_path("policies", validate_node_id(node_id) + ".json")

    def usage_path(self, node_id):
        """用量明细 jsonl 路径。"""
        return self.safe_path("usage", validate_node_id(node_id) + ".jsonl")

    def summary_path(self, node_id):
        """用量聚合视图路径。"""
        return self.safe_path("usage", validate_node_id(node_id) + ".summary.json")

    def events_path(self, node_id):
        """事件 jsonl 路径。"""
        return self.safe_path("events", validate_node_id(node_id) + ".jsonl")

    def subscriptions_path(self):
        """subscriptions.json 路径。"""
        return self.safe_path("subscriptions.json")

    # -- 基础读写 ----------------------------------------------------------
    def read_json(self, path, default=None):
        """读取 JSON 文件；不存在或损坏时返回 ``default``。"""
        if not os.path.isfile(path):
            return default
        try:
            with open(path, "r", encoding="utf-8") as handle:
                return json.load(handle)
        except (ValueError, OSError) as exc:
            log.error("读取 JSON 失败 path=%s err=%s", path, exc)
            return default

    def write_json(self, path, obj):
        """原子写入 JSON 文件（UTF-8、缩进 2、不转义中文）。"""
        atomic_write_text(path, json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=False) + "\n")

    def append_jsonl(self, path, records):
        """追加写入 jsonl（每条一行；追加写不做整体替换）。

        参数:
            path: jsonl 文件路径
            records: 可迭代的 dict 序列
        返回:
            实际写入条数
        """
        records = list(records)
        if not records:
            return 0
        directory = os.path.dirname(os.path.abspath(path))
        if directory and not os.path.isdir(directory):
            os.makedirs(directory)
        with open(path, "a", encoding="utf-8", newline="\n") as handle:
            for record in records:
                handle.write(json.dumps(record, ensure_ascii=False) + "\n")
            handle.flush()
        return len(records)

    def remove_file(self, path):
        """删除文件（不存在则忽略），返回是否真的删除了。"""
        try:
            os.remove(path)
            return True
        except OSError:
            return False

    # -- 业务视图 ----------------------------------------------------------
    def load_nodes(self):
        """读取 nodes.json，返回 ``{"version":1,"nodes":{...}}``（缺失时给空结构）。"""
        data = self.read_json(self.nodes_path(), None)
        if not isinstance(data, dict):
            return {"version": 1, "nodes": {}}
        if not isinstance(data.get("nodes"), dict):
            data["nodes"] = {}
        data.setdefault("version", 1)
        return data

    def save_nodes(self, data):
        """原子写入 nodes.json。"""
        self.write_json(self.nodes_path(), data)

    def load_policy(self, node_id):
        """读取节点策略；不存在返回 None。"""
        data = self.read_json(self.policy_path(node_id), None)
        return data if isinstance(data, dict) else None

    def save_policy(self, node_id, policy):
        """原子写入节点策略。"""
        self.write_json(self.policy_path(node_id), policy)

    def load_summary(self, node_id):
        """读取用量聚合视图；不存在返回空结构。"""
        data = self.read_json(self.summary_path(node_id), None)
        if not isinstance(data, dict):
            return {"node_id": node_id, "users": {}, "totals": {"up": 0, "down": 0, "total": 0}}
        if not isinstance(data.get("users"), dict):
            data["users"] = {}
        if not isinstance(data.get("totals"), dict):
            data["totals"] = {"up": 0, "down": 0, "total": 0}
        return data

    def save_summary(self, node_id, summary):
        """原子写入用量聚合视图。"""
        self.write_json(self.summary_path(node_id), summary)

    def load_subscriptions(self):
        """读取 subscriptions.json，返回 ``{"version":1,"subs":{...}}``。"""
        data = self.read_json(self.subscriptions_path(), None)
        if not isinstance(data, dict):
            return {"version": 1, "subs": {}}
        if not isinstance(data.get("subs"), dict):
            data["subs"] = {}
        data.setdefault("version", 1)
        return data

    def save_subscriptions(self, data):
        """原子写入 subscriptions.json。"""
        self.write_json(self.subscriptions_path(), data)


class NonceCache(object):
    """内存 nonce 去重缓存（滑动窗口，进程内即可）。

    参数:
        window_sec: 窗口长度（秒），窗口外的记录会被回收
    """

    def __init__(self, window_sec=NONCE_WINDOW_SEC):
        self._window = int(window_sec)
        self._items = {}
        self._lock = threading.Lock()

    def check_and_store(self, key, now=None):
        """检查并登记 nonce。

        参数:
            key: 去重键（通常为 node_id + ":" + nonce）
            now: 当前时间戳，默认取系统时间
        返回:
            True 表示首次出现，False 表示窗口内重复（重放）
        """
        current = now_ts() if now is None else int(now)
        with self._lock:
            self._prune(current)
            if key in self._items:
                return False
            self._items[key] = current
            return True

    def _prune(self, current):
        """回收窗口外的 nonce，避免内存无限增长。"""
        if len(self._items) < 4096:
            return
        deadline = current - self._window
        stale = [key for key, ts in self._items.items() if ts < deadline]
        for key in stale:
            self._items.pop(key, None)

    def size(self):
        """当前缓存条目数（观测用）。"""
        with self._lock:
            return len(self._items)


# ---------------------------------------------------------------------------
# 业务逻辑
# ---------------------------------------------------------------------------
class Central(object):
    """中台业务逻辑：节点鉴权、心跳、策略、上报、订阅、管理接口。

    参数:
        config: :class:`Config` 实例

    约定：所有 public 方法返回 :class:`Result`（status + payload）；
    payload 为 dict 时由 HTTP 层编码为 JSON，为 str 时按文本输出。
    """

    def __init__(self, config):
        self.config = config
        self.store = Store(config.data_dir)
        self.nonces = NonceCache(config.nonce_window)

    # -- 鉴权 --------------------------------------------------------------
    def verify_node_request(self, method, path, headers, body):
        """校验节点请求的 HMAC-SHA256 签名。

        签名串::

            METHOD + "\\n" + PATH + "\\n" + TIMESTAMP + "\\n" + NONCE + "\\n" + SHA256_HEX(body)

        参数:
            method: HTTP 方法（内部转大写）
            path: 不含 query 的请求路径
            headers: 大小写不敏感的请求头（``http.client.HTTPMessage`` 即可）
            body: 原始请求体 bytes
        返回:
            ``(node_id, None)`` 表示通过；``(None, Result)`` 表示失败
            （统一 401，不区分“节点不存在/签名错误”，避免节点枚举）
        """
        unauthorized = error_result(401, "unauthorized")
        current = now_ts()
        node_id = (headers.get("X-VPNX-Node") or "").strip()
        ts_raw = (headers.get("X-VPNX-Timestamp") or "").strip()
        nonce = (headers.get("X-VPNX-Nonce") or "").strip()
        signature = (headers.get("X-VPNX-Signature") or "").strip().lower()
        if not node_id or not ts_raw or not nonce or not signature:
            return None, unauthorized
        try:
            timestamp = int(ts_raw)
        except (TypeError, ValueError):
            return None, unauthorized
        if abs(current - timestamp) > self.config.clock_skew:
            return None, unauthorized
        try:
            node_id = validate_node_id(node_id)
        except ValueError:
            return None, unauthorized
        with self.store.lock:
            node = self.store.load_nodes()["nodes"].get(node_id)
        secret = ""
        if isinstance(node, dict):
            secret = node.get("secret") or ""
        if not secret:
            # 节点不存在或未签发 secret：仍按占位密钥计算 HMAC，保证响应不泄露节点是否存在
            secret = "0" * 64
        body_hash = hashlib.sha256(body or b"").hexdigest()
        message = "\n".join([method.upper(), path, str(timestamp), nonce, body_hash])
        expected = hmac.new(secret.encode("utf-8"), message.encode("utf-8"), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, signature):
            return None, unauthorized
        if node is None:
            return None, unauthorized
        if not self.nonces.check_and_store("%s:%s" % (node_id, nonce), current):
            return None, unauthorized
        return node_id, None

    def check_admin_token(self, authorization, header_token):
        """校验管理员 token。

        参数:
            authorization: ``Authorization`` 头（``Bearer xxx`` 或裸 token）
            header_token: ``X-Admin-Token`` 头
        返回:
            bool，是否通过鉴权
        """
        expected = self.config.admin_token or ""
        provided = ""
        if authorization:
            parts = authorization.split(None, 1)
            if len(parts) == 2 and parts[0].lower() == "bearer":
                provided = parts[1].strip()
            elif len(parts) == 1:
                provided = parts[0].strip()
        if not provided and header_token:
            provided = header_token.strip()
        if not expected or not provided:
            return False
        return hmac.compare_digest(expected, provided)

    # -- 节点接口 ----------------------------------------------------------
    def node_heartbeat(self, node_id, body):
        """处理节点心跳：更新 nodes.json 并返回策略版本与建议间隔。

        参数:
            node_id: 已鉴权的节点 ID
            body: 心跳请求体 dict
        返回:
            Result，payload 为 ``{ok, server_time, policy_revision, policy_pending, next_interval_sec}``
        """
        current = now_ts()
        keys = ("hostname", "agent_version", "xray_version", "os", "kernel", "arch",
                "public_ip", "uptime_sec", "load1", "mem_used_pct", "disk_used_pct",
                "inbounds", "users_total", "users_active", "traffic_total_bytes", "health")
        with self.store.lock:
            data = self.store.load_nodes()
            node = data["nodes"].get(node_id)
            if node is None:
                return error_result(401, "unauthorized")
            for key in keys:
                if key in body:
                    node[key] = body[key]
            if "applied_policy_revision" in body:
                # 单调不减：忽略乱序/重复心跳带来的旧版本，避免覆盖 ack 已确认的 revision
                reported = as_int(body.get("applied_policy_revision"), 0)
                applied_before = as_int(node.get("applied_policy_revision"), 0)
                node["applied_policy_revision"] = max(applied_before, reported)
            node["last_heartbeat"] = current
            node["online"] = True
            self.store.save_nodes(data)
            policy = self.store.load_policy(node_id)
            revision = as_int((policy or {}).get("revision"), 0)
            pending = self._policy_pending(node, revision, policy)
        return json_result(200, {
            "ok": True,
            "server_time": current,
            "policy_revision": revision,
            "policy_pending": pending,
            "next_interval_sec": self.config.heartbeat_interval,
        })

    def _policy_pending(self, node, revision, policy=None):
        """判断是否存在待应用策略。

        参数:
            node: 节点记录 dict
            revision: 中台当前策略 revision
            policy: 策略文档（可省略）
        返回:
            bool；节点未回执到最新版本或上次应用失败时为 True
        """
        if policy is None and revision <= 0:
            return False
        applied = as_int((node or {}).get("applied_policy_revision"), 0)
        if applied < revision:
            return True
        return ((node or {}).get("last_ack_result") or "") == "failed"

    def node_policy(self, node_id, current_revision=None):
        """下发策略：revision 未变且无待应用标记时返回 unchanged。

        参数:
            node_id: 已鉴权的节点 ID
            current_revision: 节点当前持有的 revision（None 表示强制全量拉取）
        返回:
            Result，payload 为 ``{ok, unchanged, revision}`` 或完整策略文档
        """
        with self.store.lock:
            node = self.store.load_nodes()["nodes"].get(node_id) or {}
            policy = self.store.load_policy(node_id)
        if policy is None:
            policy = default_policy(node_id)
        revision = as_int(policy.get("revision"), 0)
        pending = self._policy_pending(node, revision, policy)
        if current_revision is not None and not pending and current_revision == revision:
            return json_result(200, {"ok": True, "unchanged": True, "revision": revision})
        payload = dict(policy)
        payload["ok"] = True
        payload["revision"] = revision
        payload["policy_pending"] = pending
        return json_result(200, payload)

    def node_report(self, node_id, body):
        """处理节点上报：usage 落 jsonl + 聚合，events 落 jsonl，ack 写回节点状态。

        参数:
            node_id: 已鉴权的节点 ID
            body: 上报体 dict（report_type 为 usage|event|ack 或组合）
        返回:
            Result，payload 为 ``{ok: true}``
        """
        current = now_ts()
        usage = body.get("usage") or []
        events = body.get("events") or []
        ack = body.get("ack") or {}
        usage_count = 0
        event_count = 0
        with self.store.lock:
            if isinstance(usage, list) and usage:
                usage_count = self._apply_usage(node_id, usage, current)
            if isinstance(events, list) and events:
                records = []
                for item in events:
                    if not isinstance(item, dict):
                        continue
                    records.append({
                        "ts": as_int(item.get("ts"), current),
                        "node_id": node_id,
                        "received_at": current,
                        "level": item.get("level") or "info",
                        "code": item.get("code") or "",
                        "message": item.get("message") or "",
                        "detail": item.get("detail") or "",
                    })
                event_count = self.store.append_jsonl(self.store.events_path(node_id), records)
            if isinstance(ack, dict) and ack:
                data = self.store.load_nodes()
                node = data["nodes"].get(node_id)
                if node is None:
                    return error_result(401, "unauthorized")
                if "policy_revision" in ack:
                    node["applied_policy_revision"] = as_int(ack.get("policy_revision"), 0)
                result = str(ack.get("result") or "").lower()
                node["last_ack_result"] = result
                node["last_ack_at"] = current
                node["last_error"] = str(ack.get("error") or "") if result == "failed" else ""
                self.store.save_nodes(data)
        log.info("节点上报 node=%s usage=%d events=%d ack=%s", node_id, usage_count, event_count,
                 ack.get("result") if isinstance(ack, dict) else "")
        return json_result(200, {"ok": True})

    def _apply_usage(self, node_id, usage, current):
        """把 usage 明细追加到 jsonl 并更新聚合视图。

        参数:
            node_id: 节点 ID
            usage: ``[{name,email,up,down,online_ips,last_seen}, ...]``
            current: 接收时间戳
        返回:
            写入的明细条数
        """
        records = []
        summary = self.store.load_summary(node_id)
        users = summary.setdefault("users", {})
        totals = summary.setdefault("totals", {"up": 0, "down": 0, "total": 0})
        for item in usage:
            if not isinstance(item, dict):
                continue
            name = str(item.get("name") or item.get("email") or "unknown")
            up = as_int(item.get("up"), 0)
            down = as_int(item.get("down"), 0)
            record = {
                "ts": current,
                "node_id": node_id,
                "name": name,
                "email": item.get("email") or "",
                "up": up,
                "down": down,
                "online_ips": as_int(item.get("online_ips"), 0),
                "last_seen": as_int(item.get("last_seen"), current),
            }
            records.append(record)
            entry = users.get(name)
            if not isinstance(entry, dict):
                entry = {"name": name, "email": record["email"], "up": 0, "down": 0,
                         "total": 0, "samples": 0, "online_ips": 0, "last_seen": 0}
            entry["email"] = record["email"] or entry.get("email", "")
            entry["up"] = as_int(entry.get("up"), 0) + up
            entry["down"] = as_int(entry.get("down"), 0) + down
            entry["total"] = entry["up"] + entry["down"]
            entry["samples"] = as_int(entry.get("samples"), 0) + 1
            entry["online_ips"] = record["online_ips"]
            entry["last_seen"] = record["last_seen"]
            users[name] = entry
            totals["up"] = as_int(totals.get("up"), 0) + up
            totals["down"] = as_int(totals.get("down"), 0) + down
            totals["total"] = totals["up"] + totals["down"]
        written = self.store.append_jsonl(self.store.usage_path(node_id), records)
        summary["node_id"] = node_id
        summary["updated_at"] = current
        summary["samples"] = as_int(summary.get("samples"), 0) + written
        self.store.save_summary(node_id, summary)
        return written

    def node_subscription(self, node_id, body, host_header=None):
        """接收节点发布的订阅内容并落库。

        参数:
            node_id: 已鉴权的节点 ID
            body: ``{"users":[{name,email,sub_token,expire_at,quota_bytes,used_bytes,links,extra}]}``
            host_header: 请求的 Host 头，用于推导 sub_base
        返回:
            Result，payload 为 ``{ok, published, sub_base}``
        """
        users = body.get("users") or []
        current = now_ts()
        published = 0
        with self.store.lock:
            subs = self.store.load_subscriptions()
            summary = self.store.load_summary(node_id)
            for item in users:
                if not isinstance(item, dict):
                    continue
                token = item.get("sub_token")
                if not token:
                    # 节点没给 token 时，用 node_id+email 派生稳定 token
                    seed = "%s:%s" % (node_id, item.get("email") or item.get("name") or "")
                    token = hashlib.sha256(seed.encode("utf-8")).hexdigest()[:32]
                try:
                    token = validate_sub_token(token)
                except ValueError:
                    log.warning("忽略非法 sub_token node=%s", node_id)
                    continue
                used = item.get("used_bytes")
                if used is None:
                    name = str(item.get("name") or item.get("email") or "unknown")
                    entry = summary.get("users", {}).get(name) or {}
                    used = as_int(entry.get("total"), 0)
                extra = item.get("extra") if isinstance(item.get("extra"), dict) else {}
                links = [str(link) for link in (item.get("links") or []) if link]
                subs["subs"][token] = {
                    "sub_token": token,
                    "node_id": node_id,
                    "name": item.get("name") or "",
                    "email": item.get("email") or "",
                    "links": links,
                    "extra": extra,
                    "expire_at": as_int(item.get("expire_at"), 0),
                    "quota_bytes": as_int(item.get("quota_bytes"), 0),
                    "used_bytes": as_int(used, 0),
                    "updated_at": current,
                }
                published += 1
            self.store.save_subscriptions(subs)
        base = self.sub_base(host_header)
        log.info("节点发布订阅 node=%s published=%d", node_id, published)
        return json_result(200, {"ok": True, "published": published, "sub_base": base})

    def node_script_update(self, node_id, body):
        """处理脚本自更新查询（可选接口）。

        参数:
            node_id: 已鉴权的节点 ID
            body: ``{"script_version","channel"}``
        返回:
            Result，payload 为 ``{ok, update_available, script_version, url, sha256}``
        """
        report_version = str(body.get("script_version") or "").strip()
        available = bool(self.config.script_url) and report_version != self.config.script_version
        return json_result(200, {
            "ok": True,
            "update_available": available,
            "script_version": self.config.script_version,
            "url": self.config.script_url if available else "",
            "sha256": self.config.script_sha256 if available else "",
        })

    def sub_base(self, host_header=None):
        """推导订阅基址（以 ``/`` 结尾）。

        参数:
            host_header: 请求 Host 头，可为 None
        返回:
            str，如 ``https://vpn.example.com/sub/``
        """
        if self.config.public_base:
            return self.config.public_base
        host = (host_header or "").strip() or "%s:%d" % (self.config.host, self.config.port)
        return "%s://%s/sub/" % (self.config.sub_scheme, host)

    # -- 订阅接口 ----------------------------------------------------------
    def get_subscription(self, token, target=None):
        """按 sub_token 生成订阅内容（无需鉴权）。

        参数:
            token: 订阅 token
            target: base64|raw|clash|singbox（未知值忽略，回落到 base64）
        返回:
            Result；未知 token 返回 404
        """
        try:
            token = validate_sub_token(token)
        except ValueError:
            return error_result(404, "not found")
        with self.store.lock:
            entry = self.store.load_subscriptions()["subs"].get(token)
        if not isinstance(entry, dict):
            return error_result(404, "not found")
        links = [str(link) for link in (entry.get("links") or []) if link]
        extra = entry.get("extra") if isinstance(entry.get("extra"), dict) else {}
        mode = (target or "base64").strip().lower()
        if mode in ("clash", "yaml", "clashmeta", "mihomo"):
            body = extra.get("clash_yaml") or self._build_clash(entry)
            content_type = "text/yaml; charset=utf-8"
        elif mode in ("singbox", "sing-box", "sing_box", "json"):
            body = extra.get("singbox_json") or self._build_singbox(entry)
            content_type = "application/json; charset=utf-8"
        elif mode in ("raw", "text", "plain", "links"):
            body = "\n".join(links)
            content_type = TEXT_CONTENT_TYPE
        else:
            raw = "\n".join(links).encode("utf-8")
            body = base64.b64encode(raw).decode("ascii")
            content_type = TEXT_CONTENT_TYPE
        quota = as_int(entry.get("quota_bytes"), 0)
        used = as_int(entry.get("used_bytes"), 0)
        expire = as_int(entry.get("expire_at"), 0)
        headers = {
            "Subscription-Userinfo": "upload=0; download=%d; total=%d; expire=%d" % (used, quota, expire),
            "Profile-Update-Interval": "12",
            "Cache-Control": "no-store",
        }
        return Result(200, body, content_type, headers)

    def _build_clash(self, entry):
        """节点未提供 clash_yaml 时生成一份最小可用配置。"""
        lines = [
            "# vpnx central generated subscription",
            "# user: %s" % (entry.get("email") or entry.get("name") or "-"),
            "mixed-port: 7890",
            "allow-lan: false",
            "mode: rule",
            "log-level: warning",
            "proxies: []",
            "proxy-groups:",
            "  - name: PROXY",
            "    type: select",
            "    proxies:",
            "      - DIRECT",
            "rules:",
            "  - MATCH,PROXY",
        ]
        return "\n".join(lines) + "\n"

    def _build_singbox(self, entry):
        """节点未提供 singbox_json 时生成一份最小可用配置。"""
        config = {
            "log": {"level": "warn"},
            "inbounds": [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080}],
            "outbounds": [
                {"type": "selector", "tag": "proxy", "outbounds": ["direct"], "default": "direct"},
                {"type": "direct", "tag": "direct"},
            ],
            "remarks": entry.get("email") or entry.get("name") or "",
        }
        return json.dumps(config, ensure_ascii=False, indent=2) + "\n"

    # -- 管理接口 ----------------------------------------------------------
    def admin_health(self):
        """健康检查（无需鉴权）。

        返回:
            Result，payload 为 ``{ok, nodes, subs, version}``
        """
        with self.store.lock:
            nodes = self.store.load_nodes()["nodes"]
            subs = self.store.load_subscriptions()["subs"]
        return json_result(200, {"ok": True, "nodes": len(nodes), "subs": len(subs), "version": VERSION})

    def admin_create_node(self, body):
        """创建节点并返回一次性 node_secret。

        参数:
            body: ``{"node_id","name","ip","remark"}``
        返回:
            Result；重复创建返回 409
        """
        if not isinstance(body, dict):
            return error_result(400, "body must be a json object")
        try:
            node_id = validate_node_id(body.get("node_id"))
        except ValueError as exc:
            return error_result(400, str(exc))
        current = now_ts()
        secret = secrets.token_hex(32)
        with self.store.lock:
            data = self.store.load_nodes()
            if node_id in data["nodes"]:
                return error_result(409, "node already exists: %s" % node_id)
            node = {
                "node_id": node_id,
                "name": body.get("name") or node_id,
                "ip": body.get("ip") or "",
                "remark": body.get("remark") or "",
                "secret": secret,
                "created_at": current,
                "last_heartbeat": 0,
                "applied_policy_revision": 0,
                "last_ack_result": "",
                "last_error": "",
                "online": False,
            }
            data["nodes"][node_id] = node
            self.store.save_nodes(data)
        log.info("创建节点 node=%s", node_id)
        return json_result(200, {
            "ok": True,
            "node_id": node_id,
            "node_secret": secret,
            "node": self.node_view(node),
        })

    def node_view(self, node):
        """把节点记录转成对外（管理接口）视图。

        参数:
            node: nodes.json 里的节点记录
        返回:
            dict，包含 secret 以外的状态字段与用量汇总
        """
        node_id = node.get("node_id")
        with self.store.lock:
            summary = self.store.load_summary(node_id)
            policy = self.store.load_policy(node_id)
        totals = summary.get("totals") or {}
        policy_revision = as_int((policy or {}).get("revision"), 0)
        applied = as_int(node.get("applied_policy_revision"), 0)
        last_heartbeat = as_int(node.get("last_heartbeat"), 0)
        online = bool(last_heartbeat) and (now_ts() - last_heartbeat) <= ONLINE_THRESHOLD_SEC
        return {
            "node_id": node_id,
            "name": node.get("name") or node_id,
            "ip": node.get("ip") or "",
            "remark": node.get("remark") or "",
            "created_at": as_int(node.get("created_at"), 0),
            "last_heartbeat": last_heartbeat,
            "online": online,
            "hostname": node.get("hostname") or "",
            "public_ip": node.get("public_ip") or "",
            "agent_version": node.get("agent_version") or "",
            "xray_version": node.get("xray_version") or "",
            "os": node.get("os") or "",
            "kernel": node.get("kernel") or "",
            "arch": node.get("arch") or "",
            "uptime_sec": as_int(node.get("uptime_sec"), 0),
            "load1": node.get("load1") or 0,
            "users_total": as_int(node.get("users_total"), 0),
            "users_active": as_int(node.get("users_active"), 0),
            "traffic_total_bytes": as_int(node.get("traffic_total_bytes"), 0),
            "used_bytes": as_int(totals.get("total"), 0),
            "used_bytes_up": as_int(totals.get("up"), 0),
            "used_bytes_down": as_int(totals.get("down"), 0),
            "applied_policy_revision": applied,
            "policy_revision": policy_revision,
            "policy_pending": applied < policy_revision or (node.get("last_ack_result") or "") == "failed",
            "last_ack_result": node.get("last_ack_result") or "",
            "last_error": node.get("last_error") or "",
            "health": node.get("health") or {},
            "inbounds": node.get("inbounds") or [],
        }

    def admin_list_nodes(self):
        """列出全部节点（含心跳、用量汇总、策略版本、在线状态）。

        返回:
            Result，payload 为 ``{ok, count, nodes:[...]}``
        """
        with self.store.lock:
            nodes = self.store.load_nodes()["nodes"]
            views = [self.node_view(nodes[key]) for key in sorted(nodes.keys())]
        return json_result(200, {"ok": True, "count": len(views), "nodes": views})

    def _get_node(self, node_id):
        """读取节点记录（调用方需自行持有 store.lock）。

        参数:
            node_id: 节点 ID
        返回:
            dict 或 None
        """
        node = self.store.load_nodes()["nodes"].get(node_id)
        return node if isinstance(node, dict) else None

    def admin_rotate_node(self, node_id):
        """重新签发节点 secret（旧 secret 立即失效）。

        参数:
            node_id: 节点 ID
        返回:
            Result，payload 为 ``{ok, node_id, node_secret}``
        """
        with self.store.lock:
            data = self.store.load_nodes()
            node = data["nodes"].get(node_id)
            if node is None:
                return error_result(404, "node not found: %s" % node_id)
            secret = secrets.token_hex(32)
            node["secret"] = secret
            node["rotated_at"] = now_ts()
            self.store.save_nodes(data)
        log.info("轮换节点密钥 node=%s", node_id)
        return json_result(200, {"ok": True, "node_id": node_id, "node_secret": secret})

    def admin_delete_node(self, node_id):
        """删除节点及其策略/用量/事件文件。

        参数:
            node_id: 节点 ID
        返回:
            Result，payload 为 ``{ok, deleted}``
        """
        with self.store.lock:
            data = self.store.load_nodes()
            if node_id not in data["nodes"]:
                return error_result(404, "node not found: %s" % node_id)
            data["nodes"].pop(node_id, None)
            self.store.save_nodes(data)
            for path in (self.store.policy_path(node_id), self.store.usage_path(node_id),
                         self.store.summary_path(node_id), self.store.events_path(node_id)):
                self.store.remove_file(path)
        log.info("删除节点 node=%s", node_id)
        return json_result(200, {"ok": True, "deleted": node_id})

    def admin_put_policy(self, node_id, body):
        """写入节点策略：自动维护 revision 与 issued_at。

        规则：
          * body 显式给出与当前相同的 revision → 视为幂等更新，revision 不递增；
          * 其余情况 → ``revision = 上一次 + 1``。

        参数:
            node_id: 节点 ID
            body: 策略文档片段
        返回:
            Result，payload 为 ``{ok, revision}``
        """
        if not isinstance(body, dict):
            return error_result(400, "body must be a json object")
        current = now_ts()
        with self.store.lock:
            if self._get_node(node_id) is None:
                return error_result(404, "node not found: %s" % node_id)
            existing = self.store.load_policy(node_id)
            current_revision = as_int((existing or {}).get("revision"), 0)
            explicit = body.get("revision")
            if explicit is not None and as_int(explicit, -1) == current_revision:
                revision = current_revision
            else:
                revision = current_revision + 1
            policy = normalize_policy(node_id, body)
            policy["node_id"] = node_id
            policy["revision"] = revision
            policy["issued_at"] = body.get("issued_at") or current
            if not policy.get("expires_at"):
                policy["expires_at"] = current + POLICY_TTL_SEC
            self.store.save_policy(node_id, policy)
        log.info("写入策略 node=%s revision=%d", node_id, revision)
        return json_result(200, {"ok": True, "revision": revision})

    def admin_get_policy(self, node_id):
        """读取节点当前策略。

        参数:
            node_id: 节点 ID
        返回:
            Result，payload 为 ``{ok, node_id, revision, policy}``；未配置时 policy 为 null
        """
        with self.store.lock:
            if self._get_node(node_id) is None:
                return error_result(404, "node not found: %s" % node_id)
            policy = self.store.load_policy(node_id)
        revision = as_int((policy or {}).get("revision"), 0)
        return json_result(200, {"ok": True, "node_id": node_id, "revision": revision, "policy": policy})

    def admin_get_usage(self, node_id):
        """读取节点聚合用量。

        参数:
            node_id: 节点 ID
        返回:
            Result，payload 为 ``{ok, node_id, totals, users, samples, updated_at}``
        """
        with self.store.lock:
            if self._get_node(node_id) is None:
                return error_result(404, "node not found: %s" % node_id)
            summary = self.store.load_summary(node_id)
        users = []
        for name in sorted(summary.get("users", {}).keys()):
            entry = summary["users"][name]
            if isinstance(entry, dict):
                users.append(entry)
        return json_result(200, {
            "ok": True,
            "node_id": node_id,
            "totals": summary.get("totals") or {"up": 0, "down": 0, "total": 0},
            "users": users,
            "samples": as_int(summary.get("samples"), 0),
            "updated_at": as_int(summary.get("updated_at"), 0),
        })


# ---------------------------------------------------------------------------
# HTTP 层
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    """HTTP 请求处理器：仅做路由与编解码，业务逻辑全部在 :class:`Central`。"""

    server_version = "vpnx-central/" + VERSION
    protocol_version = "HTTP/1.1"

    # -- 基础工具 ----------------------------------------------------------
    @property
    def central(self):
        """当前服务实例绑定的 Central 对象。"""
        return self.server.central

    def log_message(self, fmt, *args):
        """访问日志走 DEBUG（精简 INFO 日志由各路由显式打印）。"""
        log.debug("%s %s", self.address_string(), fmt % args)

    def _read_body(self):
        """读取并校验请求体（限制大小、不支持 chunked）。

        返回:
            bytes 请求体
        异常:
            RequestError: 长度非法或超过上限
        """
        length = self.headers.get("Content-Length")
        if length is None:
            if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
                raise RequestError(411, "chunked transfer-encoding is not supported")
            return b""
        try:
            size = int(length)
        except (TypeError, ValueError):
            raise RequestError(400, "invalid Content-Length")
        if size < 0:
            raise RequestError(400, "invalid Content-Length")
        if size > MAX_BODY_BYTES:
            raise RequestError(413, "request body too large")
        return self.rfile.read(size) if size else b""

    def _json_body(self, raw):
        """解析 JSON 请求体，空体按空 dict 处理。"""
        if not raw:
            return {}
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise RequestError(400, "invalid json body")
        if not isinstance(payload, dict):
            raise RequestError(400, "body must be a json object")
        return payload

    def _send(self, result):
        """按 :class:`Result` 输出响应（dict → JSON，str → 文本）。"""
        if isinstance(result.payload, dict):
            data = json.dumps(result.payload, ensure_ascii=False).encode("utf-8")
            content_type = result.content_type or JSON_CONTENT_TYPE
        else:
            data = ("" if result.payload is None else str(result.payload)).encode("utf-8")
            content_type = result.content_type or TEXT_CONTENT_TYPE
        try:
            self.send_response(result.status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            for key in result.headers:
                self.send_header(key, result.headers[key])
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):  # pragma: no cover - 客户端提前断开
            log.debug("客户端提前断开连接")

    # -- 请求分发 ----------------------------------------------------------
    def do_GET(self):
        """处理 GET。"""
        self._dispatch("GET")

    def do_POST(self):
        """处理 POST。"""
        self._dispatch("POST")

    def do_PUT(self):
        """处理 PUT。"""
        self._dispatch("PUT")

    def do_DELETE(self):
        """处理 DELETE。"""
        self._dispatch("DELETE")

    def do_HEAD(self):
        """处理 HEAD（等价 GET，不写 body）。"""
        self._dispatch("HEAD")

    def _dispatch(self, method):
        """解析请求、路由到 Central 并输出响应。"""
        try:
            parsed = urlparse(self.path)
            path = unquote(parsed.path or "/")
            if "\x00" in path or ".." in path.split("/"):
                self._send(error_result(400, "bad path"))
                return
            query = parse_qs(parsed.query, keep_blank_values=True)
            body = self._read_body()
            result = self._route(method, path, query, body)
            self._send(result)
        except RequestError as exc:
            self._send(error_result(exc.status, exc.message))
        except ValueError as exc:
            self._send(error_result(400, str(exc)))
        except Exception as exc:  # pragma: no cover - 兜底，避免线程静默死亡
            log.exception("处理请求异常 method=%s path=%s err=%s", method, self.path, exc)
            self._send(error_result(500, "internal error"))

    def _route(self, method, path, query, body):
        """按路径前缀分发到节点接口 / 订阅 / 管理接口。

        参数:
            method: HTTP 方法
            path: 已解码、已去掉 query 的路径
            query: ``parse_qs`` 结果
            body: 原始请求体 bytes
        返回:
            Result
        """
        if path.startswith("/api/v1/node/"):
            if method == "HEAD":
                method = "GET"
            return self._route_node(method, path, query, body)
        if path == "/sub" or path.startswith("/sub/"):
            return self._route_sub(path, query)
        if path == "/api/v1/admin/health" and method in ("GET", "HEAD"):
            return self.central.admin_health()
        if path.startswith("/api/v1/admin/"):
            return self._route_admin(method, path, body)
        if path in ("/", "/index.html") and method in ("GET", "HEAD"):
            return json_result(200, {"ok": True, "service": "vpnx-central", "version": VERSION,
                                     "sub_base": self.central.sub_base(self.headers.get("Host"))})
        return error_result(404, "not found")

    def _wants_lines(self, query):
        """判断节点接口是否要求 ``key=value`` 逐行格式。

        参数:
            query: parse_qs 结果
        返回:
            bool；``?format=lines`` 或 ``Accept: text/plain`` 时为 True
        """
        fmt = (query.get("format") or [""])[0].strip().lower()
        if fmt in ("lines", "line", "text", "plain", "kv"):
            return True
        accept = (self.headers.get("Accept") or "").lower()
        return "text/plain" in accept

    def _route_node(self, method, path, query, body):
        """节点接口路由（全部需要 HMAC 鉴权）。"""
        if method not in ("GET", "POST"):
            return error_result(405, "method not allowed")
        node_id, failure = self.central.verify_node_request(method, path, self.headers, body)
        if failure is not None:
            log.warning("节点鉴权失败 method=%s path=%s node=%s ip=%s", method, path,
                        self.headers.get("X-VPNX-Node") or "-", self.address_string())
            return failure
        log.info("节点请求 node=%s %s %s", node_id, method, path)
        try:
            payload = self._json_body(body)
        except RequestError as exc:
            return error_result(exc.status, exc.message)
        if path == "/api/v1/node/heartbeat" and method == "POST":
            result = self.central.node_heartbeat(node_id, payload)
        elif path == "/api/v1/node/policy" and method == "GET":
            raw_revision = (query.get("current_revision") or [None])[0]
            current_revision = None if raw_revision in (None, "", "None") else as_int(raw_revision, -1)
            result = self.central.node_policy(node_id, current_revision)
        elif path == "/api/v1/node/report" and method == "POST":
            result = self.central.node_report(node_id, payload)
        elif path == "/api/v1/node/subscription" and method == "POST":
            result = self.central.node_subscription(node_id, payload, self.headers.get("Host"))
        elif path == "/api/v1/node/script/update" and method == "POST":
            result = self.central.node_script_update(node_id, payload)
        else:
            return error_result(404, "not found")
        if self._wants_lines(query) and isinstance(result.payload, dict) and path in (
                "/api/v1/node/report", "/api/v1/node/policy"):
            return Result(result.status, to_lines(result.payload), TEXT_CONTENT_TYPE, result.headers)
        return result

    def _route_sub(self, path, query):
        """订阅路由：``/sub/<token>``、``/sub/<token>/clash``、``/sub/<token>/singbox``。"""
        rest = path[len("/sub/"):] if path.startswith("/sub/") else ""
        parts = [part for part in rest.split("/") if part]
        if not parts:
            return error_result(404, "not found")
        token = parts[0]
        target = None
        for key in ("target", "format"):
            values = query.get(key)
            if values and values[0]:
                target = values[0]
                break
        if len(parts) > 1 and parts[1]:
            target = parts[1]
        log.info("订阅请求 token=%s*** target=%s ip=%s", token[:8], target or "base64",
                 self.address_string())
        return self.central.get_subscription(token, target)

    def _route_admin(self, method, path, body):
        """管理接口路由（除 health 外都需要管理员 token）。"""
        if method not in ("GET", "POST", "PUT", "DELETE"):
            return error_result(405, "method not allowed")
        if not self.central.check_admin_token(self.headers.get("Authorization"),
                                              self.headers.get("X-Admin-Token")):
            log.warning("管理接口鉴权失败 method=%s path=%s ip=%s", method, path, self.address_string())
            return error_result(401, "unauthorized")
        if path == "/api/v1/admin/nodes":
            if method == "GET":
                return self.central.admin_list_nodes()
            if method == "POST":
                return self.central.admin_create_node(self._json_body(body))
            return error_result(405, "method not allowed")
        matched = ADMIN_NODE_RE.match(path)
        if not matched:
            return error_result(404, "not found")
        try:
            node_id = validate_node_id(matched.group(1))
        except ValueError as exc:
            return error_result(400, str(exc))
        action = matched.group(2) or ""
        if not action:
            if method == "DELETE":
                return self.central.admin_delete_node(node_id)
            if method == "GET":
                with self.central.store.lock:
                    node = self.central._get_node(node_id)
                if node is None:
                    return error_result(404, "node not found: %s" % node_id)
                return json_result(200, {"ok": True, "node": self.central.node_view(node)})
            return error_result(405, "method not allowed")
        if action == "rotate":
            if method != "POST":
                return error_result(405, "method not allowed")
            return self.central.admin_rotate_node(node_id)
        if action == "policy":
            if method == "PUT":
                return self.central.admin_put_policy(node_id, self._json_body(body))
            if method == "GET":
                return self.central.admin_get_policy(node_id)
            return error_result(405, "method not allowed")
        if action == "usage":
            if method != "GET":
                return error_result(405, "method not allowed")
            return self.central.admin_get_usage(node_id)
        return error_result(404, "not found")


# ---------------------------------------------------------------------------
# 启动
# ---------------------------------------------------------------------------
def load_or_create_admin_token(data_dir):
    """读取 ``<data-dir>/admin.token``；不存在则生成并落盘。

    参数:
        data_dir: 数据目录
    返回:
        ``(token, generated)``，generated 表示本次是否新生成
    """
    path = os.path.abspath(os.path.join(data_dir, "admin.token"))
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as handle:
                token = handle.read().strip()
            if token:
                return token, False
        except OSError:
            pass
    token = secrets.token_hex(32)
    atomic_write_text(path, token + "\n")
    try:
        os.chmod(path, 0o600)
    except OSError:  # Windows 不支持则忽略
        pass
    return token, True


def build_server(config):
    """构建（尚未启动的）HTTP 服务实例。

    参数:
        config: :class:`Config`
    返回:
        ``(httpd, central)``；端口传 0 时可由 ``httpd.server_address[1]`` 取真实端口
    """
    central = Central(config)
    httpd = ThreadingHTTPServer((config.host, config.port), Handler)
    httpd.daemon_threads = True
    httpd.central = central
    return httpd, central


def parse_args(argv=None):
    """解析命令行参数。

    参数:
        argv: 参数列表，默认 ``sys.argv[1:]``
    返回:
        argparse.Namespace
    """
    parser = argparse.ArgumentParser(description="VPN 节点中台（零依赖参考实现）")
    parser.add_argument("--data-dir", default=DEFAULT_DATA_DIR, help="数据目录，默认 ./data")
    parser.add_argument("--host", default=DEFAULT_HOST, help="监听地址，默认 0.0.0.0")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="监听端口，默认 8787")
    parser.add_argument("--admin-token", default=None, help="管理员 token（默认读环境变量 VPNX_ADMIN_TOKEN）")
    parser.add_argument("--public-base", default="", help="订阅对外基址，如 https://vpn.example.com/sub/")
    parser.add_argument("--sub-scheme", default="https", help="推导订阅基址时使用的协议，默认 https")
    parser.add_argument("--log-level", default="INFO", help="日志级别，默认 INFO")
    return parser.parse_args(argv)


def main(argv=None):
    """服务入口。

    参数:
        argv: 参数列表（默认 sys.argv[1:]）
    返回:
        进程退出码（0 正常）
    """
    args = parse_args(argv)
    logging.basicConfig(level=getattr(logging, str(args.log_level).upper(), logging.INFO),
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    admin_token = args.admin_token or os.environ.get("VPNX_ADMIN_TOKEN") or ""
    generated = False
    if not admin_token:
        admin_token, generated = load_or_create_admin_token(args.data_dir)
    config = Config(data_dir=args.data_dir, admin_token=admin_token, host=args.host, port=args.port,
                    public_base=args.public_base, sub_scheme=args.sub_scheme)
    httpd, central = build_server(config)
    host, port = httpd.server_address[0], httpd.server_address[1]
    log.info("vpnx-central %s 启动 data_dir=%s listen=%s:%s", VERSION, central.store.base, host, port)
    if generated:
        # 仅在“自动生成”时打印一次，便于管理员首次获取 token
        print("=" * 72)
        print("vpnx-central 已生成管理员 token（同时也写入 %s/admin.token）:" % central.store.base)
        print("    %s" % admin_token)
        print("请妥善保存：后续请求使用 Authorization: Bearer <token> 或 X-Admin-Token: <token>")
        print("=" * 72)
        sys.stdout.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:  # pragma: no cover - 交互式中断
        log.info("收到中断信号，正在退出")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
