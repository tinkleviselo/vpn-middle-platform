#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""centralctl —— VPN 节点中台管理员命令行工具（零依赖）。

两种工作模式：

* HTTP 模式（默认）：通过 HTTP 调用 ``server.py`` 的管理接口，需要 ``--server`` /
  ``--admin-token``；
* 直连模式：给出 ``--data-dir`` 时直接读写数据文件（复用 ``server.py`` 的
  :class:`server.Store` / :class:`server.Central`），适合中台未启动或本地运维。

用法示例::

    python3 centralctl.py node add --id n1 --name "HK-1" --ip 1.2.3.4
    python3 centralctl.py node list
    python3 centralctl.py node token --id n1
    python3 centralctl.py node rm --id n1
    python3 centralctl.py policy new --id n1 --from policy.example.json
    python3 centralctl.py policy push --id n1 --file policy.json
    python3 centralctl.py policy show --id n1
    python3 centralctl.py user list --node n1
    python3 centralctl.py sub url --token <sub_token>
    python3 centralctl.py serve --host 0.0.0.0 --port 8787 --data-dir ./data

直连模式示例::

    python3 centralctl.py --data-dir ./data node list
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import server  # noqa: E402  # 复用 Store/Central/Config，保持单点实现

DEFAULT_SERVER = "http://127.0.0.1:8787"
DEFAULT_DATA_DIR = os.path.join(HERE, "data")
DEFAULT_TIMEOUT = 10.0


class CliError(Exception):
    """命令行可预期的错误（打印后以退出码 1 结束）。"""

    pass


def parse_json(raw):
    """尝试把响应体解析成 dict；失败则原样返回字符串。

    参数:
        raw: 响应体文本
    返回:
        dict/list 或原始字符串
    """
    try:
        return json.loads(raw)
    except (ValueError, TypeError):
        return raw


def human_bytes(value):
    """把字节数格式化成易读字符串。

    参数:
        value: 字节数（int）
    返回:
        str，如 ``1.5 GiB``
    """
    try:
        number = float(value or 0)
    except (TypeError, ValueError):
        return "-"
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(number) < 1024.0 or unit == "TiB":
            if unit == "B":
                return "%d B" % int(number)
            return "%.2f %s" % (number, unit)
        number /= 1024.0
    return "%.2f TiB" % number


def format_time(timestamp):
    """把 Unix 时间戳格式化成 ``YYYY-mm-dd HH:MM:SS``（本地时区）；0 显示 ``-``。

    参数:
        timestamp: Unix 秒
    返回:
        str
    """
    seconds = server.as_int(timestamp, 0)
    if seconds <= 0:
        return "-"
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(seconds))


def format_table(headers, rows):
    """把二维数据渲染成等宽文本表格。

    参数:
        headers: 表头列表
        rows: 行列表（元素为与表头等长的列表）
    返回:
        str（含换行，末尾无多余空行）
    """
    if not rows:
        return "（空）"
    cells = [[("" if cell is None else str(cell)) for cell in row] for row in rows]
    widths = [len(str(head)) for head in headers]
    for row in cells:
        for index, cell in enumerate(row):
            if index < len(widths):
                widths[index] = max(widths[index], len(cell))
    lines = ["  ".join(str(head).ljust(widths[index]) for index, head in enumerate(headers))]
    lines.append("  ".join("-" * widths[index] for index in range(len(headers))))
    for row in cells:
        lines.append("  ".join(cell.ljust(widths[index]) for index, cell in enumerate(row)))
    return "\n".join(lines)


def resolve_input_file(path):
    """解析输入文件路径：先按当前目录，再按脚本目录。

    参数:
        path: 用户给出的路径
    返回:
        存在的绝对路径
    异常:
        CliError: 文件不存在
    """
    candidates = [path, os.path.join(os.getcwd(), path), os.path.join(HERE, path)]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate):
            return os.path.abspath(candidate)
    raise CliError("文件不存在: %s" % path)


def read_json_file(path):
    """读取并解析 JSON 文件。

    参数:
        path: 文件路径（可相对当前目录或脚本目录）
    返回:
        dict
    异常:
        CliError: 文件不存在、JSON 非法或顶层不是对象
    """
    resolved = resolve_input_file(path)
    try:
        with open(resolved, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (ValueError, OSError) as exc:
        raise CliError("解析 JSON 失败 %s: %s" % (resolved, exc))
    if not isinstance(data, dict):
        raise CliError("JSON 顶层必须是对象: %s" % resolved)
    return data


def emit_json(payload):
    """以 JSON 打印结果（``--json`` 使用）。"""
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False))


class HttpBackend(object):
    """HTTP 后端：通过管理接口操作中台。

    参数:
        base_url: 中台地址，如 ``http://127.0.0.1:8787``
        admin_token: 管理员 token（对应 server 的 --admin-token）
        timeout: 请求超时（秒）
    """

    def __init__(self, base_url, admin_token, timeout=DEFAULT_TIMEOUT):
        self.base_url = (base_url or DEFAULT_SERVER).rstrip("/")
        self.admin_token = admin_token or ""
        self.timeout = float(timeout)

    def request(self, method, path, payload=None):
        """发起一次管理请求。

        参数:
            method: HTTP 方法（GET/POST/PUT/DELETE）
            path: 以 ``/`` 开头的路径（可带 query）
            payload: dict（JSON body）或 None
        返回:
            ``(status, data)``，data 为解析后的 dict 或原始文本
        异常:
            CliError: 网络层失败
        """
        url = self.base_url + path
        headers = {"Accept": "application/json"}
        if self.admin_token:
            headers["Authorization"] = "Bearer " + self.admin_token
        body = None
        if payload is not None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read().decode("utf-8", "replace")
                status = response.getcode()
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", "replace")
            status = exc.code
        except (urllib.error.URLError, OSError) as exc:
            raise CliError("无法连接中台 %s: %s" % (url, exc))
        return status, parse_json(raw)

    def call(self, method, path, payload=None):
        """请求并断言成功（2xx），返回 payload dict。

        参数:
            method/path/payload: 同 :meth:`request`
        返回:
            dict
        异常:
            CliError: 状态码非 2xx
        """
        status, data = self.request(method, path, payload)
        if status >= 400 or not isinstance(data, dict):
            message = data.get("error") if isinstance(data, dict) else data
            raise CliError("中台返回 %s: %s" % (status, message))
        return data

    # -- 后端接口 ----------------------------------------------------------
    def create_node(self, body):
        """创建节点，返回含一次性 node_secret 的 payload。"""
        return self.call("POST", "/api/v1/admin/nodes", body)

    def list_nodes(self):
        """列出节点。"""
        return self.call("GET", "/api/v1/admin/nodes")

    def rotate_node(self, node_id):
        """轮换节点 secret。"""
        return self.call("POST", "/api/v1/admin/nodes/%s/rotate" % node_id)

    def delete_node(self, node_id):
        """删除节点。"""
        return self.call("DELETE", "/api/v1/admin/nodes/%s" % node_id)

    def put_policy(self, node_id, policy):
        """写入节点策略。"""
        return self.call("PUT", "/api/v1/admin/nodes/%s/policy" % node_id, policy)

    def get_policy(self, node_id):
        """读取节点策略。"""
        return self.call("GET", "/api/v1/admin/nodes/%s/policy" % node_id)

    def get_usage(self, node_id):
        """读取节点聚合用量。"""
        return self.call("GET", "/api/v1/admin/nodes/%s/usage" % node_id)

    def health(self):
        """中台健康信息。"""
        return self.call("GET", "/api/v1/admin/health")

    def sub_url(self, token, target=None, public_base=""):
        """拼接订阅 URL。

        参数:
            token: 订阅 token
            target: 可选 ``base64|raw|clash|singbox``
            public_base: 覆盖基址（一般不用）
        返回:
            str
        """
        base = (public_base or self.base_url).rstrip("/")
        base = base.replace("0.0.0.0", "127.0.0.1")
        url = "%s/sub/%s" % (base, token)
        if target:
            url += "?target=" + target
        return url

    def describe(self):
        """后端描述（打印用）。"""
        return self.base_url


class DirectBackend(object):
    """直连后端：``--data-dir`` 模式下直接读写数据文件。

    参数:
        data_dir: 数据目录
        admin_token: 仅用于构造 Config，直连模式不做鉴权
        public_base: 拼接订阅 URL 时使用的基址
    """

    def __init__(self, data_dir, admin_token="", public_base=""):
        self.data_dir = os.path.abspath(data_dir)
        self.public_base = public_base or ""
        self.central = server.Central(server.Config(data_dir=self.data_dir,
                                                    admin_token=admin_token or "direct"))

    def _payload(self, result):
        """把 :class:`server.Result` 转成 payload dict 或抛出 CliError。"""
        if not isinstance(result.payload, dict):
            raise CliError("非预期的返回类型")
        if result.status >= 400:
            raise CliError("操作失败 %s: %s" % (result.status, result.payload.get("error")))
        return result.payload

    # -- 后端接口 ----------------------------------------------------------
    def create_node(self, body):
        """创建节点（直连）。"""
        return self._payload(self.central.admin_create_node(body))

    def list_nodes(self):
        """列出节点（直连）。"""
        return self._payload(self.central.admin_list_nodes())

    def rotate_node(self, node_id):
        """轮换节点 secret（直连）。"""
        return self._payload(self.central.admin_rotate_node(node_id))

    def delete_node(self, node_id):
        """删除节点（直连）。"""
        return self._payload(self.central.admin_delete_node(node_id))

    def put_policy(self, node_id, policy):
        """写入节点策略（直连）。"""
        return self._payload(self.central.admin_put_policy(node_id, policy))

    def get_policy(self, node_id):
        """读取节点策略（直连）。"""
        return self._payload(self.central.admin_get_policy(node_id))

    def get_usage(self, node_id):
        """读取节点聚合用量（直连）。"""
        return self._payload(self.central.admin_get_usage(node_id))

    def health(self):
        """中台健康信息（直连）。"""
        return self._payload(self.central.admin_health())

    def sub_url(self, token, target=None, public_base=""):
        """拼接订阅 URL（直连模式基址取自 --public-base 或默认本地地址）。"""
        base = (public_base or self.public_base or "http://127.0.0.1:8787").rstrip("/")
        base = base.replace("0.0.0.0", "127.0.0.1")
        url = "%s/sub/%s" % (base, token)
        if target:
            url += "?target=" + target
        return url

    def has_subscription(self, token):
        """判断该 token 是否已发布订阅（直连模式用于提前报错）。"""
        with self.central.store.lock:
            subs = self.central.store.load_subscriptions()["subs"]
        return isinstance(subs.get(token), dict)

    def describe(self):
        """后端描述（打印用）。"""
        return "data-dir %s" % self.data_dir


def make_backend(args):
    """按参数选择后端。

    参数:
        args: argparse 解析结果（需要 server/admin_token/data_dir/timeout/public_base）
    返回:
        HttpBackend 或 DirectBackend；显式 ``--server`` 优先，其次 ``--data-dir``
    """
    if args.data_dir and not args.server:
        return DirectBackend(args.data_dir, args.admin_token, args.public_base)
    return HttpBackend(args.server or DEFAULT_SERVER, args.admin_token, args.timeout)


# ---------------------------------------------------------------------------
# 子命令实现
# ---------------------------------------------------------------------------
def cmd_node_add(args):
    """``node add``：创建节点并打印一次性 node_secret。"""
    backend = make_backend(args)
    payload = backend.create_node({
        "node_id": args.id,
        "name": args.name,
        "ip": args.ip or "",
        "remark": args.remark or "",
    })
    if args.json:
        emit_json(payload)
        return 0
    print("节点已创建")
    print("  node_id     : %s" % payload.get("node_id"))
    print("  name        : %s" % args.name)
    print("  node_secret : %s" % payload.get("node_secret"))
    print("提示: node_secret 只在创建/轮换时返回一次，请立即写入节点侧 /etc/vpnx/agent.conf；")
    print("      遗失可用 `centralctl.py node token --id %s` 重新签发（旧密钥立即失效）。" % payload.get("node_id"))
    return 0


def cmd_node_list(args):
    """``node list``：列出全部节点状态。"""
    backend = make_backend(args)
    payload = backend.list_nodes()
    if args.json:
        emit_json(payload)
        return 0
    nodes = payload.get("nodes") or []
    headers = ["NODE_ID", "NAME", "IP", "ONLINE", "LAST_HEARTBEAT", "APPLIED", "POLICY",
               "PENDING", "USED", "USERS", "ACK"]
    rows = []
    for node in nodes:
        rows.append([
            node.get("node_id"),
            node.get("name"),
            node.get("ip") or "-",
            "yes" if node.get("online") else "no",
            format_time(node.get("last_heartbeat")),
            node.get("applied_policy_revision"),
            node.get("policy_revision"),
            "yes" if node.get("policy_pending") else "no",
            human_bytes(node.get("used_bytes")),
            "%s/%s" % (node.get("users_active", 0), node.get("users_total", 0)),
            node.get("last_ack_result") or "-",
        ])
    print(format_table(headers, rows))
    print("共 %d 个节点（后端: %s）" % (len(nodes), backend.describe()))
    return 0


def cmd_node_token(args):
    """``node token``：重新签发节点 secret。"""
    backend = make_backend(args)
    payload = backend.rotate_node(args.id)
    if args.json:
        emit_json(payload)
        return 0
    print("节点 %s 的 secret 已重新签发（旧 secret 立即失效）：" % payload.get("node_id"))
    print("  node_secret : %s" % payload.get("node_secret"))
    return 0


def cmd_node_rm(args):
    """``node rm``：删除节点及其策略/用量/事件文件。"""
    backend = make_backend(args)
    payload = backend.delete_node(args.id)
    if args.json:
        emit_json(payload)
        return 0
    print("节点已删除: %s" % payload.get("deleted"))
    return 0


def cmd_policy_new(args):
    """``policy new``：从文件创建（首次下发）节点策略。"""
    policy = read_json_file(args.from_file)
    backend = make_backend(args)
    payload = backend.put_policy(args.id, policy)
    if args.json:
        emit_json(payload)
        return 0
    print("策略已写入 node=%s revision=%s" % (args.id, payload.get("revision")))
    return 0


def cmd_policy_push(args):
    """``policy push``：推送新策略（revision 自动 +1）。"""
    policy = read_json_file(args.file)
    backend = make_backend(args)
    payload = backend.put_policy(args.id, policy)
    if args.json:
        emit_json(payload)
        return 0
    print("策略已推送 node=%s revision=%s（节点将在下次心跳/策略拉取时获取）"
          % (args.id, payload.get("revision")))
    return 0


def cmd_policy_show(args):
    """``policy show``：查看节点当前策略。"""
    backend = make_backend(args)
    payload = backend.get_policy(args.id)
    if args.json:
        emit_json(payload)
        return 0
    policy = payload.get("policy")
    print("node=%s revision=%s issued_at=%s" % (args.id, payload.get("revision"),
                                               format_time((policy or {}).get("issued_at"))))
    if not policy:
        print("（该节点还没有策略，可用 policy new/push 写入）")
        return 0
    print(json.dumps(policy, ensure_ascii=False, indent=2, sort_keys=False))
    return 0


def cmd_user_list(args):
    """``user list``：查看某节点的用户聚合用量。"""
    backend = make_backend(args)
    payload = backend.get_usage(args.node)
    if args.json:
        emit_json(payload)
        return 0
    totals = payload.get("totals") or {}
    users = payload.get("users") or []
    headers = ["NAME", "EMAIL", "UP", "DOWN", "TOTAL", "ONLINE_IPS", "LAST_SEEN", "SAMPLES"]
    rows = []
    for user in users:
        rows.append([
            user.get("name"),
            user.get("email") or "-",
            human_bytes(user.get("up")),
            human_bytes(user.get("down")),
            human_bytes(user.get("total")),
            user.get("online_ips", 0),
            format_time(user.get("last_seen")),
            user.get("samples", 0),
        ])
    print(format_table(headers, rows))
    print("节点 %s 合计: up=%s down=%s total=%s（采样 %s 次，更新于 %s）"
          % (args.node, human_bytes(totals.get("up")), human_bytes(totals.get("down")),
             human_bytes(totals.get("total")), payload.get("samples", 0),
             format_time(payload.get("updated_at"))))
    return 0


def cmd_sub_url(args):
    """``sub url``：输出订阅 URL。"""
    backend = make_backend(args)
    if isinstance(backend, DirectBackend) and not backend.has_subscription(args.token):
        raise CliError("订阅不存在（该 token 尚未由节点发布）: %s" % args.token)
    print(backend.sub_url(args.token, args.target, args.public_base))
    return 0


def cmd_serve(args):
    """``serve``：启动 HTTP 服务（等价 ``python3 server.py ...``）。"""
    argv = ["--data-dir", args.data_dir or DEFAULT_DATA_DIR,
            "--host", args.host,
            "--port", str(args.port)]
    if args.admin_token:
        argv += ["--admin-token", args.admin_token]
    if args.public_base:
        argv += ["--public-base", args.public_base]
    if args.log_level:
        argv += ["--log-level", args.log_level]
    return server.main(argv)


def build_parser():
    """构造 argparse 解析器（含 node/policy/user/sub/serve 子命令）。

    返回:
        argparse.ArgumentParser
    """
    parser = argparse.ArgumentParser(
        prog="centralctl.py",
        description="VPN 节点中台管理员命令行（HTTP 模式默认，--data-dir 可直连数据文件）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例:\n"
               "  centralctl.py node add --id n1 --name HK-1 --ip 1.2.3.4\n"
               "  centralctl.py --data-dir ./data node list\n"
               "  centralctl.py policy push --id n1 --file policy.json\n"
               "  centralctl.py serve --host 0.0.0.0 --port 8787\n")
    parser.add_argument("--server", default=None,
                        help="中台地址，如 http://127.0.0.1:8787（显式给出即走 HTTP 模式）")
    parser.add_argument("--admin-token", default=os.environ.get("VPNX_ADMIN_TOKEN") or "",
                        help="管理员 token（默认读环境变量 VPNX_ADMIN_TOKEN）")
    parser.add_argument("--data-dir", default=None,
                        help="数据目录；给出且未给 --server 时走直连模式，直接读写数据文件")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help="HTTP 超时秒数，默认 10")
    parser.add_argument("--public-base", default="", help="拼接订阅 URL 的基址，如 https://vpn.example.com")
    parser.add_argument("--json", action="store_true", help="以原始 JSON 输出结果")
    subparsers = parser.add_subparsers(dest="command")

    # node ---------------------------------------------------------------
    node = subparsers.add_parser("node", help="节点管理")
    node_sub = node.add_subparsers(dest="node_command")
    add = node_sub.add_parser("add", help="创建节点，返回一次性 node_secret")
    add.add_argument("--id", required=True, help="节点 ID，如 n1")
    add.add_argument("--name", required=True, help="节点名称，如 HK-1")
    add.add_argument("--ip", default="", help="节点公网 IP")
    add.add_argument("--remark", default="", help="备注")
    add.set_defaults(func=cmd_node_add)

    listing = node_sub.add_parser("list", help="列出节点")
    listing.set_defaults(func=cmd_node_list)

    token = node_sub.add_parser("token", help="重新签发节点 secret")
    token.add_argument("--id", required=True, help="节点 ID")
    token.set_defaults(func=cmd_node_token)

    remove = node_sub.add_parser("rm", help="删除节点")
    remove.add_argument("--id", required=True, help="节点 ID")
    remove.set_defaults(func=cmd_node_rm)

    # policy -------------------------------------------------------------
    policy = subparsers.add_parser("policy", help="策略管理")
    policy_sub = policy.add_subparsers(dest="policy_command")
    new = policy_sub.add_parser("new", help="从文件创建节点策略")
    new.add_argument("--id", required=True, help="节点 ID")
    new.add_argument("--from", dest="from_file", required=True, help="策略 JSON 文件，如 policy.example.json")
    new.set_defaults(func=cmd_policy_new)

    push = policy_sub.add_parser("push", help="推送节点策略（revision 自动 +1）")
    push.add_argument("--id", required=True, help="节点 ID")
    push.add_argument("--file", required=True, help="策略 JSON 文件，如 policy.json")
    push.set_defaults(func=cmd_policy_push)

    show = policy_sub.add_parser("show", help="查看节点当前策略")
    show.add_argument("--id", required=True, help="节点 ID")
    show.set_defaults(func=cmd_policy_show)

    # user ---------------------------------------------------------------
    user = subparsers.add_parser("user", help="用户用量")
    user_sub = user.add_subparsers(dest="user_command")
    user_list = user_sub.add_parser("list", help="查看节点用户聚合用量")
    user_list.add_argument("--node", required=True, help="节点 ID")
    user_list.set_defaults(func=cmd_user_list)

    # sub ----------------------------------------------------------------
    sub = subparsers.add_parser("sub", help="订阅")
    sub_sub = sub.add_subparsers(dest="sub_command")
    sub_url = sub_sub.add_parser("url", help="输出订阅 URL")
    sub_url.add_argument("--token", required=True, help="订阅 token")
    sub_url.add_argument("--target", default=None,
                         choices=["base64", "raw", "clash", "singbox"], help="订阅格式")
    sub_url.set_defaults(func=cmd_sub_url)

    # serve --------------------------------------------------------------
    serve = subparsers.add_parser("serve", help="启动 HTTP 服务")
    serve.add_argument("--host", default=server.DEFAULT_HOST, help="监听地址，默认 0.0.0.0")
    serve.add_argument("--port", type=int, default=server.DEFAULT_PORT, help="监听端口，默认 8787")
    # default=SUPPRESS 表示“未显式给出就不覆盖全局同名参数”
    serve.add_argument("--data-dir", default=argparse.SUPPRESS, help="数据目录，默认 ./data")
    serve.add_argument("--admin-token", default=argparse.SUPPRESS, help="管理员 token")
    serve.add_argument("--public-base", default=argparse.SUPPRESS, help="订阅对外基址")
    serve.add_argument("--log-level", default=argparse.SUPPRESS, help="日志级别")
    serve.set_defaults(func=cmd_serve)

    return parser


def main(argv=None):
    """命令行入口。

    参数:
        argv: 参数列表，默认 ``sys.argv[1:]``
    返回:
        进程退出码（0 成功，1 业务/网络错误，2 用法错误）
    """
    parser = build_parser()
    args = parser.parse_args(argv)
    handler = getattr(args, "func", None)
    if handler is None:
        parser.print_help()
        return 2
    if not hasattr(args, "log_level"):
        args.log_level = None
    try:
        return handler(args)
    except CliError as exc:
        sys.stderr.write("错误: %s\n" % exc)
        return 1
    except KeyboardInterrupt:  # pragma: no cover - 交互式中断
        sys.stderr.write("已中断\n")
        return 130


if __name__ == "__main__":
    sys.exit(main())
