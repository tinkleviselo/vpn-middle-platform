# VPN 节点中台（central）参考实现

一套 **零依赖**（仅 Python 3.6+ 标准库，禁止 pip install）的私有自建 VPN 管理后台参考实现。
节点侧是自研 bash 脚本 `vpnx.sh`，中台负责：节点注册与密钥签发、HMAC 签名鉴权、心跳与状态采集、
策略下发（带 revision 版本控制）、用量/事件上报落库、订阅发布与 `/sub/<token>` 分发。

## 特性

* 单文件 HTTP 服务：`http.server.ThreadingHTTPServer` + `BaseHTTPRequestHandler`，无任何第三方包。
* JSON 文件存储，无数据库；所有写操作「写临时文件 + `os.replace`」原子替换，并发用 `threading.RLock`。
* 节点侧 HMAC-SHA256 签名鉴权（时间戳 ±300s、nonce 300s 去重、签名比对，失败统一 401 不泄露节点是否存在）。
* 策略 `revision` 自动递增 + 幂等更新；节点回执（ack）记录 `applied_policy_revision` / `last_ack_result` / `last_error`。
* 节点接口除 JSON 外，支持 `?format=lines` 或 `Accept: text/plain` 返回 `key=value` 逐行格式（老服务器无 jq/python 时使用）。
* 订阅发布：默认 base64 标准订阅，支持 `raw` / `clash` / `singbox`，并返回 `Subscription-Userinfo`、`Profile-Update-Interval` 头。
* 目录穿越防护（节点 ID / 订阅 token 白名单 + 路径归属校验）、管理接口 token 鉴权、精简访问日志。
* `centralctl.py` 管理员命令行：既可通过 HTTP 调用中台，也可 `--data-dir` 直连数据文件（中台未启动时可用）。

## 目录结构

```
central/
├── server.py              # 单文件 HTTP 服务 + 全部业务逻辑（也可作为库被 centralctl 复用）
├── centralctl.py          # 管理员命令行（HTTP 模式 / --data-dir 直连模式）
├── nodes.example.json     # 示例：数据目录里 nodes.json 的结构
├── policy.example.json    # 示例：策略文档（policy new/push 的输入）
├── README.md              # 本文档
└── tests/
    └── test_central.py    # unittest 端到端测试（真实起服务 + urllib.request）
```

运行时数据目录（`--data-dir`，默认 `./data`）：

```
<data-dir>/
├── nodes.json                      # 节点清单：name/ip/secret/最近心跳/applied_policy_revision/last_ack_result
├── policies/<node_id>.json         # 每节点策略文档（含 revision / issued_at / expires_at）
├── usage/<node_id>.jsonl           # 用量明细（追加写，一行一条）
├── usage/<node_id>.summary.json    # 用量聚合视图（按用户累计 up/down/total）
├── subscriptions.json              # 订阅内容（按 sub_token 索引，节点发布后写入）
├── events/<node_id>.jsonl          # 节点事件（追加写）
└── admin.token                     # 未显式提供 --admin-token 时首次生成并落盘（权限 600）
```

## 部署

### 1. 启动中台

```bash
cd /opt/vpnx-central
python3 server.py --data-dir ./data --admin-token "$(head -c 32 /dev/urandom | xxd -p -c 64)"
```

常用参数：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `--data-dir` | `./data` | 数据目录，不存在会自动创建 |
| `--host` | `0.0.0.0` | 监听地址（生产建议只监听 `127.0.0.1`，由反代对外） |
| `--port` | `8787` | 监听端口 |
| `--admin-token` | 环境变量 `VPNX_ADMIN_TOKEN` | 管理员 token；两者都没有时自动生成、写入 `<data-dir>/admin.token` 并在启动日志中打印一次 |
| `--public-base` | 空 | 订阅对外基址，如 `https://vpn.example.com/sub/`；为空时按请求 `Host` 头推导 |
| `--sub-scheme` | `https` | 推导订阅基址时使用的协议 |
| `--log-level` | `INFO` | 日志级别 |

生产建议用 systemd 托管：

```ini
# /etc/systemd/system/vpnx-central.service
[Unit]
Description=VPNX central
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/vpnx-central
Environment=VPNX_ADMIN_TOKEN=请替换为随机字符串
ExecStart=/usr/bin/python3 /opt/vpnx-central/server.py --data-dir /var/lib/vpnx-central --host 127.0.0.1 --port 8787
Restart=on-failure
User=vpnx

[Install]
WantedBy=multi-user.target
```

### 2. 创建节点、下发策略

```bash
python3 centralctl.py --server http://127.0.0.1:8787 --admin-token "$VPNX_ADMIN_TOKEN" \
    node add --id n1 --name "HK-1" --ip 1.2.3.4
# 输出一次性 node_secret，写入节点侧 /etc/vpnx/agent.conf

python3 centralctl.py --admin-token "$VPNX_ADMIN_TOKEN" \
    policy new --id n1 --from policy.example.json
```

### 3. 验证

```bash
curl -s http://127.0.0.1:8787/api/v1/admin/health
# {"ok": true, "nodes": 1, "subs": 0, "version": "1.0.0"}
```

## 接口清单

### 节点接口（HMAC 签名鉴权，统一 JSON）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/api/v1/node/heartbeat` | 心跳上报，返回 `policy_revision` / `policy_pending` / `next_interval_sec` |
| GET | `/api/v1/node/policy?node_id=<id>&current_revision=<n>` | 拉取策略；revision 相同且无待应用标记时返回 `{"ok":true,"unchanged":true,"revision":n}` |
| POST | `/api/v1/node/report` | 上报 usage / events / ack，返回 `{"ok":true}` |
| POST | `/api/v1/node/subscription` | 发布用户订阅内容，返回 `{"ok":true,"published":<count>,"sub_base":"https://<host>/sub/"}` |
| POST | `/api/v1/node/script/update` | （可选）脚本自更新查询，返回 `{"ok":true,"update_available":false,"script_version":"1.0.0","url":"","sha256":""}` |

`POST /api/v1/node/report` 与 `GET /api/v1/node/policy` 额外支持：

* `?format=lines`，或请求头 `Accept: text/plain` → 返回 `key=value` 逐行文本（点号扁平化、数组下标从 0 开始），例如：

```
ok=true
revision=2
node.ports.vless-reality=8443
node.bbr=true
users.0.action=upsert
users.0.name=alice
```

JSON 是主格式，lines 只是给「极老服务器、没有 jq/python」的节点兜底。

### 订阅接口（无需鉴权）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/sub/<sub_token>` | 默认：所有 `links` 按行拼接后整体 Base64（标准编码、带 `=` 填充）、`text/plain; charset=utf-8` |
| GET | `/sub/<sub_token>?target=base64\|raw\|clash\|singbox` | 指定格式；`?format=` 同义；未知值忽略并回落到 base64 |
| GET | `/sub/<sub_token>/clash`、`/sub/<sub_token>/singbox` | 等价于 `?target=clash` / `?target=singbox` |

响应头固定带：

```
Subscription-Userinfo: upload=0; download=<used_bytes>; total=<quota_bytes>; expire=<expire_at>
Profile-Update-Interval: 12
```

未知 token → `404`。

### 管理接口

| 鉴权 | 说明 |
| --- | --- |
| `Authorization: Bearer <admin_token>` 或 `X-Admin-Token: <admin_token>` | 除 `GET /api/v1/admin/health` 外都需要 |

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/api/v1/admin/nodes` | 创建节点，body `{"node_id","name","ip","remark"}`，返回**一次性** `node_secret`（`secrets.token_hex(32)`） |
| GET | `/api/v1/admin/nodes` | 节点列表：`last_heartbeat`、`online`、`used_bytes`（用量汇总）、`applied_policy_revision`、`policy_pending`、`last_ack_result`、`last_error`、`health`、`inbounds` 等 |
| GET | `/api/v1/admin/nodes/<id>` | 单节点视图 |
| POST | `/api/v1/admin/nodes/<id>/rotate` | 轮换 secret（旧 secret 立即失效），返回新的 `node_secret` |
| DELETE | `/api/v1/admin/nodes/<id>` | 删除节点及其策略/用量/事件文件 |
| PUT | `/api/v1/admin/nodes/<id>/policy` | 直接写入策略文档；中台自动 `revision = 上一次 + 1` 并填 `issued_at`；body 显式给出**同一** revision 时视为幂等更新不递增 |
| GET | `/api/v1/admin/nodes/<id>/policy` | 读取当前策略 |
| GET | `/api/v1/admin/nodes/<id>/usage` | 该节点聚合用量（totals + 按用户明细） |
| GET | `/api/v1/admin/health` | `{"ok":true,"nodes":<n>,"subs":<n>,"version":"1.0.0"}`，**无需鉴权** |

成功响应统一 `200`（`ok: true`）；参数错误 `400`、鉴权失败 `401`、重复创建 `409`、资源不存在 `404`。

## 节点侧鉴权（必须精确实现）

节点每次请求携带 4 个请求头：

```
X-VPNX-Node:      <node_id>
X-VPNX-Timestamp: <unix 秒>
X-VPNX-Nonce:     <16 位 hex，每次请求必须唯一>
X-VPNX-Signature: <hex>
```

签名算法：

```
signature = HMAC_SHA256(
    key = node_secret,
    msg = METHOD + "\n" + PATH + "\n" + TIMESTAMP + "\n" + NONCE + "\n" + SHA256_HEX(raw_body_bytes)
)
```

* `METHOD` 大写；`PATH` 是**不含 query** 的路径（如 `/api/v1/node/policy`）。
* `SHA256_HEX` 是对原始 body 字节的 SHA-256 十六进制小写摘要；无 body 时对空字节串求摘要。
* 中台校验：时间戳偏差 > 300 秒 → 401；nonce 在 300 秒窗口内重复 → 401（进程内字典）；
  签名不匹配 → 401；节点不存在 → 401（不区分原因，避免节点枚举）。
* 校验通过后才会登记 nonce，避免攻击者用错误签名挤占 nonce 空间。

节点侧 bash 参考实现（仅需 `openssl`）：

```bash
METHOD="POST"
NODE_ID="n1"; NODE_SECRET="<node_secret>"
API="https://vpn.example.com"
PATH_ONLY="/api/v1/node/heartbeat"
BODY='{"node_id":"n1","hostname":"'$(hostname)'","agent_version":"1.0.0"}'
TS=$(date +%s); NONCE=$(openssl rand -hex 8)
BODY_HASH=$(printf '%s' "$BODY" | openssl dgst -sha256 -hex | awk '{print $NF}')
SIG=$(printf '%s\n%s\n%s\n%s\n%s' "$METHOD" "$PATH_ONLY" "$TS" "$NONCE" "$BODY_HASH" \
        | openssl dgst -sha256 -hmac "$NODE_SECRET" -hex | awk '{print $NF}')
curl -sS -X "$METHOD" "$API$PATH_ONLY" \
  -H "X-VPNX-Node: $NODE_ID" -H "X-VPNX-Timestamp: $TS" \
  -H "X-VPNX-Nonce: $NONCE" -H "X-VPNX-Signature: $SIG" \
  -H 'Content-Type: application/json' -d "$BODY"
```

> 有 python3 的节点建议直接用 `hmac`/`hashlib` 计算，避免 shell 拼接换行时出错。

## 节点侧配置示例（/etc/vpnx/agent.conf）

`vpnx.sh` 读取的配置文件（INI 风格 `key=value`，`#` 开头为注释，分节便于脚本解析）：

```ini
# /etc/vpnx/agent.conf  —— 节点侧 agent 配置
[central]
# 中台地址：生产环境务必使用 HTTPS
api_base=https://vpn.example.com
# 节点身份（由 centralctl.py node add 创建时生成）
node_id=n1
node_secret=<64 位 hex，仅创建/轮换时返回一次>
# 中台地址白名单校验（可选，防止 DNS 劫持把上报数据送错地方）
tls_verify=true
ca_file=/etc/ssl/certs/ca-certificates.crt

[agent]
# 心跳间隔（秒）；中台会在心跳响应里给出建议值 next_interval_sec
heartbeat_interval=60
# 策略轮询间隔（先看心跳响应里的 policy_pending，为 true 才拉策略）
policy_poll_interval=300
# 上报间隔（秒）与批量大小
report_interval=120
report_batch=200
# 无 jq/python 的老服务器可打开 lines 模式，中台返回 key=value 逐行文本
prefer_lines_format=false
# 订阅下游地址（中台侧 /sub/<token>）
sub_base=https://vpn.example.com/sub/

[xray]
config_path=/usr/local/etc/xray/config.json
# 由节点自行生成并回报的字段（策略里 uuid/ss_password 为空时）
auto_generate_uuid=true
auto_generate_ss_password=true
reload_command=systemctl reload xray

[log]
level=info
path=/var/log/vpnx/agent.log
```

`node_secret` 只在中台 `node add` / `node token` 时返回一次；写入后请 `chmod 600 /etc/vpnx/agent.conf`。

## 数据文件

`nodes.json`（示例见 `nodes.example.json`）：

```json
{
  "version": 1,
  "nodes": {
    "n1": {
      "node_id": "n1", "name": "HK-1", "ip": "1.2.3.4", "remark": "香港 CN2",
      "secret": "<64 位 hex>", "created_at": 1700000000, "last_heartbeat": 1700000100,
      "applied_policy_revision": 2, "last_ack_result": "applied", "last_error": "",
      "hostname": "hk1", "public_ip": "1.2.3.4", "agent_version": "1.0.0",
      "xray_version": "1.8.24", "os": "Ubuntu 22.04", "kernel": "5.15.0", "arch": "amd64",
      "uptime_sec": 864000, "load1": 0.15, "mem_used_pct": 32.5, "disk_used_pct": 41.0,
      "traffic_total_bytes": 123456789, "users_total": 12, "users_active": 5,
      "inbounds": [{"tag": "vless-reality", "protocol": "vless", "port": 8443, "network": "tcp", "enabled": true}],
      "health": {"service_ok": true, "config_ok": true, "ports_ok": true, "last_error": ""}
    }
  }
}
```

`policies/<node_id>.json`：`revision` / `issued_at` / `expires_at` / `node`（reality_target、reality_server_names、ports、
inbounds、log_level、bbr、allow_protocols）/ `users`（action=upsert|delete|disable、name、email、uuid、ss_password、
expire_at、quota_bytes、enabled、speed_mbps、max_devices、protocols、sub_token；`uuid`/`ss_password` 为空表示由节点自行
生成并回报）/ `profiles` / `maintenance`。示例见 `policy.example.json`。

`usage/<node_id>.jsonl`：一行一条 `{ts,node_id,name,email,up,down,online_ips,last_seen}`（追加写）。
`usage/<node_id>.summary.json`：按用户聚合的 `up/down/total/samples/online_ips/last_seen` 与节点 totals。
`events/<node_id>.jsonl`：一行一条 `{ts,node_id,received_at,level,code,message,detail}`。
`subscriptions.json`：`{"version":1,"subs":{"<sub_token>":{node_id,name,email,links,extra,expire_at,quota_bytes,used_bytes,updated_at}}}`。

## 管理员命令行 centralctl.py

两种模式：

* **HTTP 模式**（默认）：`--server http://127.0.0.1:8787 --admin-token <token>`；token 也可用环境变量 `VPNX_ADMIN_TOKEN`。
* **直连模式**：给出 `--data-dir ./data`（且不给 `--server`）时，直接读写数据文件（复用 `server.py` 的 `Store`/`Central`），
  适合中台未启动、或在中台本机做运维排障。

```bash
python3 centralctl.py --admin-token "$TOKEN" node add --id n1 --name "HK-1" [--ip 1.2.3.4] [--remark 备注]
python3 centralctl.py --admin-token "$TOKEN" node list
python3 centralctl.py --admin-token "$TOKEN" node token --id n1        # 重新签发（轮换）secret
python3 centralctl.py --admin-token "$TOKEN" node rm --id n1
python3 centralctl.py --admin-token "$TOKEN" policy new --id n1 --from policy.example.json
python3 centralctl.py --admin-token "$TOKEN" policy push --id n1 --file policy.json
python3 centralctl.py --admin-token "$TOKEN" policy show --id n1
python3 centralctl.py --admin-token "$TOKEN" user list --node n1
python3 centralctl.py --admin-token "$TOKEN" sub url --token <sub_token> [--target clash]
python3 centralctl.py serve --host 0.0.0.0 --port 8787            # 等价于 python3 server.py ...

# 直连模式（全局参数需写在子命令之前）
python3 centralctl.py --data-dir ./data node list
python3 centralctl.py --data-dir ./data policy show --id n1
```

所有子命令都支持 `--json` 以原始 JSON 输出，便于脚本处理。
`serve` 子命令还接受 `--data-dir/--admin-token/--public-base/--log-level`。

## 安全建议

1. **只用 HTTPS 对外**：中台默认监听 `127.0.0.1:8787`，由 Nginx/Caddy 终止 TLS。示例：

```nginx
server {
    listen 443 ssl http2;
    server_name vpn.example.com;

    ssl_certificate     /etc/letsencrypt/live/vpn.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/vpn.example.com/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    # 管理接口只允许运维网段访问
    location /api/v1/admin/ {
        allow 203.0.113.0/24;      # 运维出口 IP 段
        deny all;
        proxy_pass http://127.0.0.1:8787;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
    }

    # 节点接口与订阅接口对公网开放
    location / {
        proxy_pass http://127.0.0.1:8787;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 30s;
    }
}
```

   `Host` 头必须透传：`sub_base` 与订阅链接默认按 `Host` 推导；也可固定 `--public-base https://vpn.example.com/sub/`。

2. **IP 白名单**：节点接口建议在反代或防火墙层限制来源 IP（`allow <节点IP>; deny all;`）；
   订阅接口面向终端用户，可以只做限速与日志，不要开放管理接口。

3. **token 轮换**：
   * 管理员 token 泄露 → 立即更换 `--admin-token` / `VPNX_ADMIN_TOKEN` 并重启中台；不要提交到 Git，不要写进镜像。
   * 节点 secret 泄露或节点重装 → `node token --id <id>` 轮换，旧 secret 立即失效；节点侧同步更新 `agent.conf` 并重启 agent。
   * 订阅 token 泄露 → 让节点重新发布该用户（生成新 `sub_token`），旧 token 不会再被更新。

4. **最小权限与备份**：`--data-dir` 目录 `chmod 700`，属主为中台运行用户（`nodes.json`、`admin.token` 内含敏感凭据）；
   定期备份 `nodes.json`、`policies/`、`subscriptions.json`。中台不要以 root 运行。

5. **审计**：中台日志会记录节点 ID、订阅 token 前缀（不打印完整 token）与管理接口鉴权失败；接入日志采集并告警。
   建议在反代层记录来源 IP，便于排查异常签名尝试。

6. **时钟同步**：签名校验允许 ±300 秒偏差，节点与中台都要开启 NTP，否则会出现批量 401。

## 测试

```bash
# 在仓库根目录执行；测试会真实起服务（随机端口）并做端到端断言
python -m unittest discover -s central/tests -v
```

覆盖：HMAC 签名校验失败必须 401（缺头、错签名、时间戳偏移、nonce 重放、节点不存在且不泄露）、心跳入库、
策略 revision 递增与 `unchanged`、ack 回执、usage 落 jsonl 并维护聚合、订阅发布后 `GET /sub/<token>` 可取回
（base64/raw/clash/singbox）、管理接口鉴权、目录穿越防护、`centralctl.py` 的 HTTP 与直连两种模式。

测试临时目录默认使用系统 temp；受限环境（不允许在临时目录下创建子目录）会自动回退到 `central/tests/_tmp`，
也可用环境变量 `VPNX_TEST_TMPDIR` 指定。

## 兼容性与约束

* Python **3.6+** 标准库；不使用 walrus（`:=`）、`dict | dict`、`capture_output` 等 3.7/3.8+ 语法。
  （`http.server.ThreadingHTTPServer` 在 3.6 不存在，`server.py` 已内置 3.6 兼容回退。）
* 无数据库：并发规模是「几十~几百节点 + 分钟级上报」，JSON + RLock 足够；更大规模请换成真正的数据库与队列。
* 所有写操作原子替换（`tmp` + `os.replace`），进程崩溃不会写出半个 JSON；
  但多进程同时写同一 `--data-dir` 不受支持（锁只在进程内）。
* 完整策略文档、订阅内容均由管理接口/节点上报写入，中台不解析具体协议参数，保持对 `vpnx.sh` 演进的兼容。
