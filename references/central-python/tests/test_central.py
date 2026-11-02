#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""central 端到端测试（unittest + urllib.request，零第三方依赖）。

覆盖范围：
  * HMAC 签名校验失败一律 401（缺头、错签名、时间戳偏移、nonce 重放、节点不存在）
  * 心跳入库、策略 revision 递增与 unchanged 语义、ack 回执
  * usage 上报落 jsonl 并维护聚合视图、events 落库
  * 订阅发布后 GET /sub/<token> 可取回（base64/raw/clash/singbox）
  * 管理接口鉴权、节点创建/列出/轮换/删除
  * 目录穿越防护、centralctl.py 的 HTTP 与直连两种模式

运行方式（在本仓库根目录）::

    python -m unittest discover -s central/tests
"""

import base64
import hashlib
import hmac
import io
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CENTRAL_DIR = os.path.dirname(HERE)
if CENTRAL_DIR not in sys.path:
    sys.path.insert(0, CENTRAL_DIR)

import centralctl  # noqa: E402
import server  # noqa: E402

ADMIN_TOKEN = "test-admin-token-0123456789abcdef"
EXAMPLE_POLICY = os.path.join(CENTRAL_DIR, "policy.example.json")


def new_nonce():
    """生成 16 位十六进制 nonce。"""
    return os.urandom(8).hex()


def sign(secret, method, path, timestamp, nonce, body):
    """按中台约定计算 HMAC-SHA256 签名。

    参数:
        secret: 节点 secret
        method: HTTP 方法
        path: 不含 query 的路径
        timestamp: Unix 秒（int 或 str）
        nonce: 16 位 hex
        body: 原始请求体 bytes（无体传 b""）
    返回:
        hex 签名字符串
    """
    body_hash = hashlib.sha256(body or b"").hexdigest()
    message = "\n".join([method.upper(), path, str(timestamp), nonce, body_hash])
    return hmac.new(secret.encode("utf-8"), message.encode("utf-8"), hashlib.sha256).hexdigest()


def run_cli(argv):
    """执行 centralctl.main 并捕获标准输出/错误。

    参数:
        argv: 命令行参数列表（不含程序名）
    返回:
        ``(exit_code, stdout, stderr)``
    """
    out = io.StringIO()
    err = io.StringIO()
    old_out, old_err = sys.stdout, sys.stderr
    sys.stdout, sys.stderr = out, err
    try:
        code = centralctl.main(argv)
    finally:
        sys.stdout, sys.stderr = old_out, old_err
    return code, out.getvalue(), err.getvalue()


def make_temp_dir(prefix):
    """创建“确实可写”的测试临时目录。

    优先使用系统临时目录；若当前环境（例如受限沙箱、只读临时盘）不允
    许在其中创建子目录，则回退到仓库内的 ``central/tests/_tmp``。
    也可用环境变量 ``VPNX_TEST_TMPDIR`` 指定。

    参数:
        prefix: 目录名前缀
    返回:
        新建目录的绝对路径
    异常:
        RuntimeError: 所有候选位置都不可写
    """
    candidates = []
    override = os.environ.get("VPNX_TEST_TMPDIR")
    if override:
        candidates.append(override)
    candidates.append(None)
    candidates.append(os.path.join(HERE, "_tmp"))
    for base in candidates:
        path = None
        try:
            if base and not os.path.isdir(base):
                os.makedirs(base)
            path = tempfile.mkdtemp(prefix=prefix, dir=base)
            probe = os.path.join(path, "probe")
            os.makedirs(probe)
            os.rmdir(probe)
            return path
        except OSError:
            if path:
                shutil.rmtree(path, ignore_errors=True)
    raise RuntimeError("找不到可写的测试临时目录，请设置 VPNX_TEST_TMPDIR")


class ServerTestCase(unittest.TestCase):
    """测试基类：每个用例启动一个真实 HTTP 服务（127.0.0.1 + 随机端口）。"""

    def setUp(self):
        """启动服务并准备请求辅助方法。"""
        self.tmpdir = make_temp_dir("vpnx-central-test-")
        self.config = server.Config(data_dir=os.path.join(self.tmpdir, "data"),
                                    admin_token=ADMIN_TOKEN, host="127.0.0.1", port=0)
        self.httpd, self.central = server.build_server(self.config)
        self.port = self.httpd.server_address[1]
        self.base = "http://127.0.0.1:%d" % self.port
        self.thread = threading.Thread(target=self.httpd.serve_forever)
        self.thread.daemon = True
        self.thread.start()
        self.addCleanup(self._shutdown)

    def _shutdown(self):
        """关闭服务并清理临时目录。"""
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=10)
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    # -- HTTP 辅助 ---------------------------------------------------------
    def request(self, method, path, headers=None, raw_body=None):
        """发送 HTTP 请求。

        参数:
            method: HTTP 方法
            path: 路径（可带 query）
            headers: 额外请求头 dict
            raw_body: 原始请求体 bytes，None 表示无 body
        返回:
            ``(status, headers_dict, body_bytes)``
        """
        request = urllib.request.Request(self.base + path, data=raw_body, method=method)
        for key in (headers or {}):
            request.add_header(key, headers[key])
        if raw_body is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                return response.getcode(), dict(response.headers.items()), response.read()
        except urllib.error.HTTPError as exc:
            return exc.code, dict(exc.headers.items()), exc.read()

    def json_request(self, method, path, headers=None, raw_body=None):
        """发送请求并把 JSON 响应解析成对象。"""
        status, hdrs, raw = self.request(method, path, headers, raw_body)
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            parsed = None
        return status, parsed, raw, hdrs

    def admin(self, method, path, body=None, token=ADMIN_TOKEN, use_header=False):
        """管理接口请求（默认 Authorization: Bearer，可选 X-Admin-Token）。"""
        headers = {}
        if token is not None:
            if use_header:
                headers["X-Admin-Token"] = token
            else:
                headers["Authorization"] = "Bearer " + token
        raw = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
        return self.json_request(method, path, headers, raw)

    def create_node(self, node_id, name="HK-1", ip="1.2.3.4"):
        """创建节点并返回 node_secret。"""
        status, payload, _raw, _hdrs = self.admin("POST", "/api/v1/admin/nodes",
                                                  {"node_id": node_id, "name": name, "ip": ip})
        self.assertEqual(200, status, payload)
        self.assertTrue(payload.get("ok"))
        self.assertEqual(64, len(payload.get("node_secret") or ""))
        return payload["node_secret"]

    def node_request(self, method, path, body=None, secret=None, node_id="n1",
                     timestamp=None, nonce_value=None, signature=None, accept=None,
                     raw_body=None):
        """构造带签名的节点请求。

        参数:
            method: HTTP 方法
            path: 可带 query 的路径（签名只覆盖 query 之前的部分）
            body: dict，将序列化为 JSON body
            secret: 节点 secret，默认无（需显式传入）
            node_id: 节点 ID
            timestamp: 覆盖时间戳
            nonce_value: 覆盖 nonce
            signature: 覆盖签名（用于伪造场景）
            accept: Accept 头
            raw_body: 直接指定的请求体 bytes
        返回:
            ``(status, parsed_json, raw_bytes, headers)``
        """
        body_bytes = raw_body
        if body_bytes is None and body is not None:
            body_bytes = json.dumps(body, ensure_ascii=False).encode("utf-8")
        path_only = path.split("?")[0]
        ts = int(time.time()) if timestamp is None else int(timestamp)
        nc = nonce_value or new_nonce()
        sig = signature if signature is not None else sign(secret or "", method, path_only, ts, nc,
                                                          body_bytes or b"")
        headers = {
            "X-VPNX-Node": node_id,
            "X-VPNX-Timestamp": str(ts),
            "X-VPNX-Nonce": nc,
            "X-VPNX-Signature": sig,
        }
        if accept:
            headers["Accept"] = accept
        return self.json_request(method, path, headers, body_bytes)

    def heartbeat_body(self, **overrides):
        """构造一份完整的心跳请求体。"""
        body = {
            "node_id": "n1",
            "hostname": "hk1.example.com",
            "agent_version": "1.0.0",
            "xray_version": "1.8.24",
            "os": "Ubuntu 22.04",
            "kernel": "5.15.0",
            "arch": "amd64",
            "public_ip": "1.2.3.4",
            "uptime_sec": 86400,
            "load1": 0.15,
            "mem_used_pct": 32.5,
            "disk_used_pct": 41.0,
            "inbounds": [{"tag": "vless-reality", "protocol": "vless", "port": 8443,
                          "network": "tcp", "enabled": True}],
            "users_total": 12,
            "users_active": 5,
            "traffic_total_bytes": 123456789,
            "applied_policy_revision": 0,
            "health": {"service_ok": True, "config_ok": True, "ports_ok": True, "last_error": ""},
        }
        body.update(overrides)
        return body

class AdminApiTest(ServerTestCase):
    """管理接口鉴权与节点生命周期。"""

    def test_health_needs_no_auth(self):
        """GET /api/v1/admin/health 无需鉴权。"""
        status, payload, _raw, _hdrs = self.json_request("GET", "/api/v1/admin/health")
        self.assertEqual(200, status)
        self.assertEqual({"ok": True, "nodes": 0, "subs": 0, "version": "1.0.0"}, payload)

    def test_admin_endpoints_require_token(self):
        """管理接口缺 token / 错 token 一律 401，正确 token 两种写法都可用。"""
        status, payload, _raw, _hdrs = self.json_request("GET", "/api/v1/admin/nodes")
        self.assertEqual(401, status)
        self.assertFalse(payload.get("ok"))
        status, _payload, _raw, _hdrs = self.admin("GET", "/api/v1/admin/nodes", token="wrong-token")
        self.assertEqual(401, status)
        self.create_node("n1")
        status, payload, _raw, _hdrs = self.admin("GET", "/api/v1/admin/nodes")
        self.assertEqual(200, status)
        self.assertEqual(1, payload["count"])
        status, payload, _raw, _hdrs = self.admin("GET", "/api/v1/admin/nodes", use_header=True)
        self.assertEqual(200, status)
        self.assertEqual(1, payload["count"])

    def test_node_lifecycle(self):
        """创建 → 列出 → 单查 → 轮换 → 删除。"""
        secret = self.create_node("n1", "HK-1", "1.2.3.4")
        status, _payload, _raw, _hdrs = self.admin("POST", "/api/v1/admin/nodes",
                                                   {"node_id": "n1", "name": "dup"})
        self.assertEqual(409, status)
        status, listing, _raw, _hdrs = self.admin("GET", "/api/v1/admin/nodes")
        node = listing["nodes"][0]
        self.assertEqual("n1", node["node_id"])
        self.assertEqual("HK-1", node["name"])
        self.assertFalse(node["online"])
        self.assertEqual(0, node["used_bytes"])
        self.assertEqual(0, node["applied_policy_revision"])
        status, payload, _raw, _hdrs = self.admin("GET", "/api/v1/admin/nodes/n1")
        self.assertEqual(200, status)
        self.assertEqual("1.2.3.4", payload["node"]["ip"])
        # 轮换后旧 secret 失效
        status, payload, _raw, _hdrs = self.admin("POST", "/api/v1/admin/nodes/n1/rotate")
        self.assertEqual(200, status)
        new_secret = payload["node_secret"]
        self.assertNotEqual(secret, new_secret)
        status, _payload, _raw, _hdrs = self.node_request("GET", "/api/v1/node/policy?node_id=n1",
                                                         secret=secret)
        self.assertEqual(401, status)
        status, _payload, _raw, _hdrs = self.node_request("GET", "/api/v1/node/policy?node_id=n1",
                                                         secret=new_secret)
        self.assertEqual(200, status)
        # 删除
        status, payload, _raw, _hdrs = self.admin("DELETE", "/api/v1/admin/nodes/n1")
        self.assertEqual(200, status)
        self.assertEqual("n1", payload["deleted"])
        status, _payload, _raw, _hdrs = self.admin("GET", "/api/v1/admin/nodes/n1/policy")
        self.assertEqual(404, status)
        status, listing, _raw, _hdrs = self.admin("GET", "/api/v1/admin/nodes")
        self.assertEqual(0, listing["count"])


class NodeAuthTest(ServerTestCase):
    """节点 HMAC 鉴权：所有失败都必须 401。"""

    def test_missing_headers_rejected(self):
        """完全不带签名头 → 401。"""
        raw = json.dumps(self.heartbeat_body()).encode("utf-8")
        status, payload, _raw, _hdrs = self.json_request("POST", "/api/v1/node/heartbeat", {}, raw)
        self.assertEqual(401, status)
        self.assertFalse(payload.get("ok"))

    def test_bad_signature_rejected(self):
        """secret 错误导致签名不匹配 → 401。"""
        self.create_node("n1")
        status, _payload, _raw, _hdrs = self.node_request("POST", "/api/v1/node/heartbeat",
                                                         body=self.heartbeat_body(),
                                                         secret="0" * 64)
        self.assertEqual(401, status)

    def test_timestamp_skew_rejected(self):
        """时间戳偏差超过 300 秒 → 401。"""
        secret = self.create_node("n1")
        for offset in (-400, 400):
            status, _payload, _raw, _hdrs = self.node_request(
                "POST", "/api/v1/node/heartbeat", body=self.heartbeat_body(), secret=secret,
                timestamp=int(time.time()) + offset)
            self.assertEqual(401, status)

    def test_nonce_replay_rejected(self):
        """同一 nonce 在窗口内重复使用 → 第二次 401。"""
        secret = self.create_node("n1")
        shared = new_nonce()
        status, payload, _raw, _hdrs = self.node_request("POST", "/api/v1/node/heartbeat",
                                                        body=self.heartbeat_body(), secret=secret,
                                                        nonce_value=shared)
        self.assertEqual(200, status)
        self.assertTrue(payload["ok"])
        status, _payload, _raw, _hdrs = self.node_request("POST", "/api/v1/node/heartbeat",
                                                         body=self.heartbeat_body(), secret=secret,
                                                         nonce_value=shared)
        self.assertEqual(401, status)

    def test_unknown_node_not_leaked(self):
        """节点不存在同样是 401，且响应体不泄露原因。"""
        status, payload, raw, _hdrs = self.node_request("POST", "/api/v1/node/heartbeat",
                                                       body=self.heartbeat_body(node_id="ghost"),
                                                       secret="a" * 64, node_id="ghost")
        self.assertEqual(401, status)
        self.assertFalse(payload.get("ok"))
        lowered = raw.decode("utf-8").lower()
        self.assertNotIn("not found", lowered)
        self.assertNotIn("ghost", lowered)

    def test_valid_request_accepted(self):
        """正确签名可通过。"""
        secret = self.create_node("n1")
        status, payload, _raw, _hdrs = self.node_request("POST", "/api/v1/node/heartbeat",
                                                        body=self.heartbeat_body(), secret=secret)
        self.assertEqual(200, status)
        self.assertTrue(payload["ok"])


class HeartbeatAndPolicyTest(ServerTestCase):
    """心跳入库、策略 revision 语义与 ack。"""

    def test_heartbeat_recorded(self):
        """心跳落 nodes.json，并在管理接口可见。"""
        secret = self.create_node("n1")
        status, payload, _raw, _hdrs = self.node_request("POST", "/api/v1/node/heartbeat",
                                                        body=self.heartbeat_body(), secret=secret)
        self.assertEqual(200, status)
        self.assertTrue(payload["ok"])
        self.assertIsInstance(payload["server_time"], int)
        self.assertEqual(0, payload["policy_revision"])
        self.assertFalse(payload["policy_pending"])
        self.assertEqual(60, payload["next_interval_sec"])
        status, listing, _raw, _hdrs = self.admin("GET", "/api/v1/admin/nodes")
        node = listing["nodes"][0]
        self.assertTrue(node["online"])
        self.assertGreater(node["last_heartbeat"], 0)
        self.assertEqual("hk1.example.com", node["hostname"])
        self.assertEqual("1.8.24", node["xray_version"])
        self.assertEqual(12, node["users_total"])
        nodes_file = os.path.join(self.central.store.base, "nodes.json")
        with open(nodes_file, "r", encoding="utf-8") as handle:
            stored = json.load(handle)
        self.assertEqual("hk1.example.com", stored["nodes"]["n1"]["hostname"])
        self.assertEqual("Ubuntu 22.04", stored["nodes"]["n1"]["os"])

    def test_default_policy_when_missing(self):
        """未配置策略时按 revision=0 处理：同版本返回 unchanged，强制拉取返回空策略。"""
        secret = self.create_node("n1")
        status, payload, _raw, _hdrs = self.node_request(
            "GET", "/api/v1/node/policy?node_id=n1&current_revision=0", secret=secret)
        self.assertEqual(200, status)
        self.assertEqual(0, payload["revision"])
        self.assertTrue(payload.get("unchanged"))
        # 不带 current_revision（强制全量）时返回完整默认策略
        status, payload, _raw, _hdrs = self.node_request(
            "GET", "/api/v1/node/policy?node_id=n1", secret=secret)
        self.assertEqual(200, status)
        self.assertEqual(0, payload["revision"])
        self.assertEqual([], payload["users"])
        self.assertIn("maintenance", payload)
        self.assertEqual(["vless-reality", "ss2022", "vmess-ws"],
                         payload["node"]["allow_protocols"])

    def test_policy_revision_unchanged_and_ack(self):
        """revision 递增、幂等、unchanged、ack 回执与 lines 格式。"""
        secret = self.create_node("n1")
        policy = {
            "node": {"inbounds": [{"tag": "vless-reality", "protocol": "vless", "port": 8443}],
                     "ports": {"vless-reality": 8443}, "log_level": "info", "bbr": True},
            "users": [{"action": "upsert", "name": "alice", "email": "alice@example.com",
                       "uuid": "", "ss_password": None, "expire_at": 0, "quota_bytes": 0,
                       "enabled": True, "speed_mbps": 0, "max_devices": 2,
                       "protocols": ["vless-reality"], "sub_token": "alice-token-0001"}],
            "profiles": {"std": {"type": "vless-reality", "params": {"flow": "xtls-rprx-vision"}}},
        }
        status, payload, _raw, _hdrs = self.admin("PUT", "/api/v1/admin/nodes/n1/policy", policy)
        self.assertEqual(200, status)
        self.assertEqual(1, payload["revision"])
        # 显式给出同一 revision → 幂等，不递增
        same = dict(policy)
        same["revision"] = 1
        status, payload, _raw, _hdrs = self.admin("PUT", "/api/v1/admin/nodes/n1/policy", same)
        self.assertEqual(200, status)
        self.assertEqual(1, payload["revision"])
        # 不给出 revision → 递增
        status, payload, _raw, _hdrs = self.admin("PUT", "/api/v1/admin/nodes/n1/policy", policy)
        self.assertEqual(2, payload["revision"])
        # 心跳提示待应用
        status, hb, _raw, _hdrs = self.node_request("POST", "/api/v1/node/heartbeat",
                                                   body=self.heartbeat_body(), secret=secret)
        self.assertEqual(2, hb["policy_revision"])
        self.assertTrue(hb["policy_pending"])
        # 未 ack 时即使 revision 相同也返回全量
        status, pol, _raw, _hdrs = self.node_request(
            "GET", "/api/v1/node/policy?node_id=n1&current_revision=2", secret=secret)
        self.assertEqual(200, status)
        self.assertFalse(pol.get("unchanged"))
        self.assertEqual(2, pol["revision"])
        self.assertEqual(8443, pol["node"]["ports"]["vless-reality"])
        self.assertEqual("alice", pol["users"][0]["name"])
        self.assertEqual("xtls-rprx-vision", pol["profiles"]["std"]["params"]["flow"])
        self.assertGreaterEqual(pol["issued_at"], 1)
        self.assertGreater(pol["expires_at"], pol["issued_at"])
        # 旧版本同样返回全量
        status, pol, _raw, _hdrs = self.node_request(
            "GET", "/api/v1/node/policy?node_id=n1&current_revision=1", secret=secret)
        self.assertEqual(2, pol["revision"])
        # ack applied
        status, payload, _raw, _hdrs = self.node_request(
            "POST", "/api/v1/node/report",
            body={"node_id": "n1", "report_type": "ack", "revision": 2,
                  "ack": {"policy_revision": 2, "result": "applied", "error": ""}},
            secret=secret)
        self.assertEqual(200, status)
        self.assertTrue(payload["ok"])
        # revision 相同且已应用 → unchanged
        status, pol, _raw, _hdrs = self.node_request(
            "GET", "/api/v1/node/policy?node_id=n1&current_revision=2", secret=secret)
        self.assertEqual(200, status)
        self.assertTrue(pol.get("unchanged"))
        self.assertEqual(2, pol["revision"])
        # 心跳里的 applied_policy_revision 单调不减：
        # 这里 heartbeats 夹具仍报 0（乱序/重复心跳的模拟），但不得覆盖 ack 已确认的 2
        status, hb, _raw, _hdrs = self.node_request("POST", "/api/v1/node/heartbeat",
                                                   body=self.heartbeat_body(), secret=secret)
        self.assertFalse(hb["policy_pending"])
        self.assertEqual(2, hb["policy_revision"])
        # 节点如实回报 applied=2 时同样不待应用
        status, hb, _raw, _hdrs = self.node_request(
            "POST", "/api/v1/node/heartbeat",
            body=self.heartbeat_body(applied_policy_revision=2), secret=secret)
        self.assertFalse(hb["policy_pending"])
        # ?format=lines
        status, _payload, raw, hdrs = self.node_request(
            "GET", "/api/v1/node/policy?node_id=n1&current_revision=2&format=lines", secret=secret)
        text = raw.decode("utf-8")
        self.assertIn("text/plain", hdrs.get("Content-Type", ""))
        self.assertIn("ok=true", text)
        self.assertIn("revision=2", text)
        self.assertIn("unchanged=true", text)
        # Accept: text/plain 且需要全量策略时同样返回 lines
        status, _payload, raw, hdrs = self.node_request(
            "GET", "/api/v1/node/policy?node_id=n1&current_revision=1", secret=secret,
            accept="text/plain")
        text = raw.decode("utf-8")
        self.assertIn("revision=2", text)
        self.assertIn("node.ports.vless-reality=8443", text)
        self.assertIn("users.0.name=alice", text)
        self.assertIn("node.bbr=true", text)
        status, payload, _raw, _hdrs = self.admin("GET", "/api/v1/admin/nodes/n1/policy")
        self.assertEqual(200, status)
        self.assertEqual(2, payload["revision"])
        self.assertEqual("alice", payload["policy"]["users"][0]["name"])


class ReportTest(ServerTestCase):
    """usage / events / ack 上报落库。"""

    def test_usage_persisted_and_aggregated(self):
        """usage 写入 jsonl，同时维护聚合视图，管理接口可读。"""
        secret = self.create_node("n1")
        report = {"node_id": "n1", "report_type": "usage", "revision": 0,
                  "usage": [
                      {"name": "alice", "email": "alice@example.com", "up": 1024, "down": 2048,
                       "online_ips": 2, "last_seen": int(time.time())},
                      {"name": "bob", "email": "bob@example.com", "up": 10, "down": 20,
                       "online_ips": 1, "last_seen": int(time.time())},
                  ]}
        status, payload, _raw, _hdrs = self.node_request("POST", "/api/v1/node/report",
                                                        body=report, secret=secret)
        self.assertEqual(200, status)
        self.assertEqual({"ok": True}, payload)
        status, usage, _raw, _hdrs = self.admin("GET", "/api/v1/admin/nodes/n1/usage")
        self.assertEqual(200, status)
        self.assertEqual(1034, usage["totals"]["up"])
        self.assertEqual(2068, usage["totals"]["down"])
        self.assertEqual(3102, usage["totals"]["total"])
        names = sorted(user["name"] for user in usage["users"])
        self.assertEqual(["alice", "bob"], names)
        jsonl = os.path.join(self.central.store.base, "usage", "n1.jsonl")
        with open(jsonl, "r", encoding="utf-8") as handle:
            lines = [json.loads(line) for line in handle if line.strip()]
        self.assertEqual(2, len(lines))
        self.assertEqual("alice", lines[0]["name"])
        self.assertEqual(2048, lines[0]["down"])
        # 再次上报为追加写
        self.node_request("POST", "/api/v1/node/report", body=report, secret=secret)
        with open(jsonl, "r", encoding="utf-8") as handle:
            self.assertEqual(4, len([line for line in handle if line.strip()]))
        status, usage, _raw, _hdrs = self.admin("GET", "/api/v1/admin/nodes/n1/usage")
        self.assertEqual(2068, usage["totals"]["up"])
        # 汇总同步到节点列表
        status, listing, _raw, _hdrs = self.admin("GET", "/api/v1/admin/nodes")
        self.assertEqual(6204, listing["nodes"][0]["used_bytes"])

    def test_events_persisted(self):
        """events 写入 events/<node_id>.jsonl。"""
        secret = self.create_node("n1")
        report = {"node_id": "n1", "report_type": "event", "revision": 0,
                  "events": [{"ts": int(time.time()), "level": "error", "code": "XRAY_EXIT",
                              "message": "xray 进程退出", "detail": "exit=1"}]}
        status, payload, _raw, _hdrs = self.node_request("POST", "/api/v1/node/report",
                                                        body=report, secret=secret)
        self.assertEqual(200, status)
        self.assertTrue(payload["ok"])
        events_file = os.path.join(self.central.store.base, "events", "n1.jsonl")
        with open(events_file, "r", encoding="utf-8") as handle:
            lines = [json.loads(line) for line in handle if line.strip()]
        self.assertEqual(1, len(lines))
        self.assertEqual("XRAY_EXIT", lines[0]["code"])
        self.assertEqual("error", lines[0]["level"])
        self.assertEqual("n1", lines[0]["node_id"])

    def test_ack_failed_then_applied(self):
        """ack 结果写回节点状态；失败时保留待应用标记。"""
        secret = self.create_node("n1")
        status, _payload, _raw, _hdrs = self.node_request(
            "POST", "/api/v1/node/report",
            body={"node_id": "n1", "report_type": "ack", "revision": 5,
                  "ack": {"policy_revision": 5, "result": "failed", "error": "配置校验失败"}},
            secret=secret)
        self.assertEqual(200, status)
        status, listing, _raw, _hdrs = self.admin("GET", "/api/v1/admin/nodes")
        node = listing["nodes"][0]
        self.assertEqual(5, node["applied_policy_revision"])
        self.assertEqual("failed", node["last_ack_result"])
        self.assertEqual("配置校验失败", node["last_error"])
        self.assertTrue(node["policy_pending"])
        # 失败后拉取策略仍是全量
        status, pol, _raw, _hdrs = self.node_request(
            "GET", "/api/v1/node/policy?node_id=n1&current_revision=5", secret=secret)
        self.assertFalse(pol.get("unchanged"))
        # 应用成功后清除错误并解除待应用标记
        status, _payload, _raw, _hdrs = self.node_request(
            "POST", "/api/v1/node/report",
            body={"node_id": "n1", "report_type": "ack", "revision": 5,
                  "ack": {"policy_revision": 5, "result": "applied", "error": ""}},
            secret=secret)
        self.assertEqual(200, status)
        status, listing, _raw, _hdrs = self.admin("GET", "/api/v1/admin/nodes")
        node = listing["nodes"][0]
        self.assertEqual("applied", node["last_ack_result"])
        self.assertEqual("", node["last_error"])
        self.assertFalse(node["policy_pending"])

    def test_report_lines_format(self):
        """POST /api/v1/node/report 支持 ?format=lines 与 Accept: text/plain。"""
        secret = self.create_node("n1")
        report = {"node_id": "n1", "report_type": "usage",
                  "usage": [{"name": "alice", "up": 1, "down": 2}]}
        status, _payload, raw, hdrs = self.node_request(
            "POST", "/api/v1/node/report?format=lines", body=report, secret=secret,
            accept="text/plain")
        self.assertEqual(200, status)
        self.assertIn("text/plain", hdrs.get("Content-Type", ""))
        self.assertEqual("ok=true", raw.decode("utf-8").strip())
        status, _payload, raw, _hdrs = self.node_request(
            "POST", "/api/v1/node/report", body=report, secret=secret, accept="text/plain")
        self.assertEqual("ok=true", raw.decode("utf-8").strip())


class SubscriptionTest(ServerTestCase):
    """订阅发布与 /sub/<token> 取回。"""

    links = [
        "vless://uuid-1@1.2.3.4:8443?type=tcp&security=reality#HK-1",
        "ss://YWVzLTI1Ni1nY206cGFzcw@1.2.3.4:8444#HK-1-SS",
    ]

    def publish(self, secret):
        """发布两个用户的订阅内容。"""
        body = {"node_id": "n1", "users": [
            {"name": "alice", "email": "alice@example.com", "sub_token": "alice-token-0001",
             "expire_at": 1767225600, "quota_bytes": 107374182400, "used_bytes": 123456,
             "links": self.links,
             "extra": {"clash_yaml": "proxies:\n  - name: HK-1\n    type: vless\n",
                       "singbox_json": "{\"outbounds\": []}"}},
            {"name": "bob", "email": "bob@example.com", "sub_token": "bob-token-0002",
             "expire_at": 0, "quota_bytes": 0, "used_bytes": 0,
             "links": ["vless://uuid-2@1.2.3.4:8443#HK-1-B"]},
        ]}
        return self.node_request("POST", "/api/v1/node/subscription", body=body, secret=secret)

    def test_publish_and_fetch(self):
        """发布后 base64/raw/clash/singbox 四种取回方式都可用，响应头齐全。"""
        secret = self.create_node("n1")
        status, payload, _raw, _hdrs = self.publish(secret)
        self.assertEqual(200, status)
        self.assertTrue(payload["ok"])
        self.assertEqual(2, payload["published"])
        self.assertTrue(payload["sub_base"].endswith("/sub/"))
        # 默认 base64（无需鉴权）
        status, hdrs, raw = self.request("GET", "/sub/alice-token-0001")
        self.assertEqual(200, status)
        self.assertIn("text/plain", hdrs["Content-Type"])
        decoded = base64.b64decode(raw.decode("ascii")).decode("utf-8")
        self.assertEqual("\n".join(self.links), decoded)
        self.assertEqual("12", hdrs["Profile-Update-Interval"])
        self.assertEqual("upload=0; download=123456; total=107374182400; expire=1767225600",
                         hdrs["Subscription-Userinfo"])
        # raw
        status, _hdrs, raw = self.request("GET", "/sub/alice-token-0001?target=raw")
        self.assertEqual(200, status)
        self.assertEqual("\n".join(self.links), raw.decode("utf-8"))
        # format 与 target 同义
        status, _hdrs, raw = self.request("GET", "/sub/alice-token-0001?format=raw")
        self.assertEqual("\n".join(self.links), raw.decode("utf-8"))
        # clash（节点自带 yaml）
        status, _hdrs, raw = self.request("GET", "/sub/alice-token-0001/clash")
        self.assertEqual(200, status)
        self.assertIn("proxies:", raw.decode("utf-8"))
        # singbox（节点自带 json）
        status, _hdrs, raw = self.request("GET", "/sub/alice-token-0001/singbox")
        self.assertEqual(200, status)
        self.assertEqual([], json.loads(raw.decode("utf-8"))["outbounds"])
        # 未知 target 忽略，回落 base64
        status, _hdrs, raw = self.request("GET", "/sub/bob-token-0002?target=nonsense")
        self.assertEqual(200, status)
        self.assertEqual("vless://uuid-2@1.2.3.4:8443#HK-1-B",
                         base64.b64decode(raw.decode("ascii")).decode("utf-8"))
        # quota=0 → total=0
        self.assertEqual("upload=0; download=0; total=0; expire=0", _hdrs["Subscription-Userinfo"])
        # 节点没给 extra 时由中台生成最小 clash / singbox 配置
        status, _hdrs, raw = self.request("GET", "/sub/bob-token-0002/clash")
        self.assertEqual(200, status)
        self.assertIn("proxy-groups:", raw.decode("utf-8"))
        status, _hdrs, raw = self.request("GET", "/sub/bob-token-0002/singbox")
        self.assertEqual(200, status)
        self.assertIn("outbounds", json.loads(raw.decode("utf-8")))

    def test_unknown_token_404(self):
        """未知 token → 404。"""
        self.create_node("n1")
        status, _hdrs, raw = self.request("GET", "/sub/not-exist-token")
        self.assertEqual(404, status)
        self.assertFalse(json.loads(raw.decode("utf-8"))["ok"])

    def test_publish_without_token_derives_one(self):
        """节点未给 sub_token 时中台派生稳定 token。"""
        secret = self.create_node("n1")
        body = {"node_id": "n1", "users": [{"name": "carol", "email": "carol@example.com",
                                            "links": ["vless://uuid-3@1.2.3.4:8443#HK-1-C"]}]}
        status, payload, _raw, _hdrs = self.node_request("POST", "/api/v1/node/subscription",
                                                        body=body, secret=secret)
        self.assertEqual(200, status)
        self.assertEqual(1, payload["published"])
        with open(os.path.join(self.central.store.base, "subscriptions.json"),
                  "r", encoding="utf-8") as handle:
            subs = json.load(handle)["subs"]
        self.assertEqual(1, len(subs))
        token = list(subs.keys())[0]
        self.assertEqual("carol@example.com", subs[token]["email"])
        status, _hdrs, raw = self.request("GET", "/sub/" + token)
        self.assertEqual(200, status)
        self.assertEqual("vless://uuid-3@1.2.3.4:8443#HK-1-C",
                         base64.b64decode(raw.decode("ascii")).decode("utf-8"))


class MiscApiTest(ServerTestCase):
    """脚本自更新接口与目录穿越防护。"""

    def test_script_update(self):
        """POST /api/v1/node/script/update 返回当前脚本版本。"""
        secret = self.create_node("n1")
        status, payload, _raw, _hdrs = self.node_request(
            "POST", "/api/v1/node/script/update",
            body={"node_id": "n1", "script_version": "1.0.0", "channel": "stable"},
            secret=secret)
        self.assertEqual(200, status)
        self.assertTrue(payload["ok"])
        self.assertFalse(payload["update_available"])
        self.assertEqual("1.0.0", payload["script_version"])

    def test_path_traversal_blocked(self):
        """目录穿越在 HTTP 层与存储层都被拦截。"""
        self.create_node("n1")
        status, _payload, _raw, _hdrs = self.json_request(
            "GET", "/api/v1/admin/nodes/..%2F..%2Fnodes.json/usage",
            {"Authorization": "Bearer " + ADMIN_TOKEN})
        self.assertIn(status, (400, 404))
        status, _payload, _raw, _hdrs = self.admin("POST", "/api/v1/admin/nodes",
                                                   {"node_id": "../../evil", "name": "evil"})
        self.assertEqual(400, status)
        status, _payload, _raw, _hdrs = self.admin("GET", "/api/v1/admin/nodes/n1%2F..%2Fn1/usage")
        self.assertIn(status, (400, 404))
        for bad in ("../etc/passwd", "a/b", "..", "a\\b"):
            with self.assertRaises(ValueError):
                server.validate_node_id(bad)
        with self.assertRaises(ValueError):
            server.validate_sub_token("../../x")
        with self.assertRaises(ValueError):
            self.central.store.policy_path("..")
        good = self.central.store.usage_path("n1")
        self.assertTrue(good.startswith(self.central.store.base + os.sep))
        self.assertFalse(os.path.exists(os.path.join(self.tmpdir, "nodes.json")))


class CentralCtlHttpTest(ServerTestCase):
    """centralctl.py 通过 HTTP 调用管理接口。"""

    def run_ctl(self, extra):
        """执行 centralctl（自动补齐 --server/--admin-token）。"""
        argv = ["--server", self.base, "--admin-token", ADMIN_TOKEN] + extra
        return run_cli(argv)

    def test_cli_full_flow(self):
        """node add/list、policy new/show、user list、sub url 全流程。"""
        code, out, err = self.run_ctl(["node", "add", "--id", "c1", "--name", "HK-C1",
                                       "--ip", "5.6.7.8"])
        self.assertEqual(0, code, err)
        self.assertIn("node_secret", out)
        code, out, err = self.run_ctl(["node", "list"])
        self.assertEqual(0, code, err)
        self.assertIn("c1", out)
        code, out, err = self.run_ctl(["policy", "new", "--id", "c1", "--from", EXAMPLE_POLICY])
        self.assertEqual(0, code, err)
        self.assertIn("revision=1", out)
        code, out, err = self.run_ctl(["policy", "show", "--id", "c1"])
        self.assertEqual(0, code, err)
        self.assertIn("alice@example.com", out)
        code, out, err = self.run_ctl(["policy", "push", "--id", "c1", "--file", EXAMPLE_POLICY])
        self.assertEqual(0, code, err)
        self.assertIn("revision=2", out)
        code, out, err = self.run_ctl(["user", "list", "--node", "c1"])
        self.assertEqual(0, code, err)
        code, out, err = self.run_ctl(["sub", "url", "--token", "alice0123456789abcdef0123456789ab",
                                       "--target", "clash"])
        self.assertEqual(0, code, err)
        self.assertIn("/sub/alice0123456789abcdef0123456789ab?target=clash", out)
        code, out, err = self.run_ctl(["node", "token", "--id", "c1"])
        self.assertEqual(0, code, err)
        self.assertIn("node_secret", out)
        code, out, err = self.run_ctl(["node", "rm", "--id", "c1"])
        self.assertEqual(0, code, err)
        code, out, err = self.run_ctl(["node", "list"])
        self.assertEqual(0, code, err)
        self.assertIn("（空）", out)
        # JSON 输出模式
        code, out, err = self.run_ctl(["--json", "node", "list"])
        self.assertEqual(0, code, err)
        self.assertEqual([], json.loads(out)["nodes"])

    def test_cli_reports_errors(self):
        """错误 token → 退出码 1；缺子命令 → 退出码 2。"""
        code, _out, err = run_cli(["--server", self.base, "--admin-token", "bad", "node", "list"])
        self.assertEqual(1, code)
        self.assertIn("401", err)
        code, _out, _err = run_cli(["--server", self.base, "--admin-token", ADMIN_TOKEN, "node"])
        self.assertEqual(2, code)
        code, _out, err = run_cli(["--server", self.base, "--admin-token", ADMIN_TOKEN,
                                   "node", "add", "--id", "dup", "--name", "A"])
        self.assertEqual(0, code, err)
        code, _out, err = run_cli(["--server", self.base, "--admin-token", ADMIN_TOKEN,
                                   "node", "add", "--id", "dup", "--name", "A"])
        self.assertEqual(1, code)
        self.assertIn("409", err)


class CentralCtlDirectTest(unittest.TestCase):
    """centralctl.py 以 --data-dir 直连数据文件（不启动服务）。"""

    def setUp(self):
        """准备独立的数据目录。"""
        self.tmpdir = make_temp_dir("vpnx-central-ctl-")
        self.addCleanup(shutil.rmtree, self.tmpdir, ignore_errors=True)
        self.data_dir = os.path.join(self.tmpdir, "data")

    def test_direct_mode_full_flow(self):
        """直连模式下 node/policy/user/sub 子命令都可用。"""
        base = ["--data-dir", self.data_dir]
        code, out, err = run_cli(base + ["node", "add", "--id", "d1", "--name", "DIR-1"])
        self.assertEqual(0, code, err)
        self.assertIn("node_secret", out)
        self.assertTrue(os.path.isfile(os.path.join(self.data_dir, "nodes.json")))
        code, out, err = run_cli(base + ["node", "list"])
        self.assertEqual(0, code, err)
        self.assertIn("d1", out)
        code, out, err = run_cli(base + ["policy", "new", "--id", "d1", "--from", EXAMPLE_POLICY])
        self.assertEqual(0, code, err)
        self.assertIn("revision=1", out)
        self.assertTrue(os.path.isfile(os.path.join(self.data_dir, "policies", "d1.json")))
        code, out, err = run_cli(base + ["policy", "show", "--id", "d1"])
        self.assertEqual(0, code, err)
        self.assertIn("alice@example.com", out)
        code, out, err = run_cli(base + ["policy", "push", "--id", "d1", "--file", EXAMPLE_POLICY])
        self.assertEqual(0, code, err)
        self.assertIn("revision=2", out)
        code, out, err = run_cli(base + ["user", "list", "--node", "d1"])
        self.assertEqual(0, code, err)
        self.assertIn("（空）", out)
        # 未发布的订阅 token → 报错
        code, _out, err = run_cli(base + ["sub", "url", "--token", "unknown-token-1234"])
        self.assertEqual(1, code)
        self.assertIn("订阅不存在", err)
        # 直接写入订阅内容后可以生成 URL
        central = server.Central(server.Config(data_dir=self.data_dir, admin_token="direct-test"))
        result = central.node_subscription("d1", {"users": [
            {"name": "alice", "email": "alice@example.com", "sub_token": "alice-token-0001",
             "expire_at": 0, "quota_bytes": 0, "used_bytes": 0,
             "links": ["vless://uuid-9@1.2.3.4:8443#x"]}]})
        self.assertEqual(200, result.status)
        code, out, err = run_cli(base + ["sub", "url", "--token", "alice-token-0001",
                                         "--target", "clash"])
        self.assertEqual(0, code, err)
        self.assertIn("/sub/alice-token-0001?target=clash", out)
        # 轮换与删除
        code, out, err = run_cli(base + ["node", "token", "--id", "d1"])
        self.assertEqual(0, code, err)
        self.assertIn("node_secret", out)
        code, out, err = run_cli(base + ["node", "rm", "--id", "d1"])
        self.assertEqual(0, code, err)
        self.assertFalse(os.path.isfile(os.path.join(self.data_dir, "policies", "d1.json")))
        code, _out, err = run_cli(base + ["node", "rm", "--id", "d1"])
        self.assertEqual(1, code)
        self.assertIn("404", err)


if __name__ == "__main__":
    unittest.main()
