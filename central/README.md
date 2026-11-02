# vpnx 中台（PHP + JSON，无数据库）

节点侧是纯脚本的 `vpnx.sh`；这里是它的**管理中台**：注册节点、分发账号、集中控配额与到期、
聚合订阅。**全部状态用 JSON 文件保存，不使用任何数据库**，因此可以直接挂在 建站面板
已有的 PHP 站点上运行（要求 PHP 5.6+，代码里已带 `hash_equals`/`password_hash`/`random_bytes` 垫片）。

```
central/
├── index.php                管理后台(登录/概览/节点/账号/订阅/设置/审计)
├── api.php                  机器接口入口(节点 API + 管理 API + 订阅)
├── lib/
│   ├── util.php             兼容垫片 / JSON 原子读写 / 锁 / 扁平化 / 响应
│   ├── config.php           配置与首次初始化
│   ├── store.php            数据层(节点/账号/策略状态/用量/订阅/nonce/审计)
│   ├── auth.php             节点 HMAC 验签 / 管理令牌 / 会话与 CSRF
│   ├── policy.php           每节点策略生成(revision 指纹 + 删除墓碑)
│   └── sub.php              订阅聚合(Base64 / raw / Clash / sing-box)
├── data/                    运行时 JSON(权限 0700/0600, 不要放进版本库)
├── nginx.conf.example       Nginx / 面板 站点配置参考
└── tests/
    ├── php_check.sh         php -l + 端到端自测(在服务器上跑)
    └── php_smoke.php        完整流程自测(临时目录 + PHP 内置服务器)
```

---

## 1. 五步部署

```bash
# 1) 把 central/ 放到面板站点目录(示例用 面板 的站点根)
mkdir -p /home/wwwroot/vpnx-central
cp -r central/* /home/wwwroot/vpnx-central/
chown -R www:www /home/wwwroot/vpnx-central      # 用户组按面板实际(面板常见 www 或 nginx)

# 2) 给数据目录写权限(中台需要写 JSON)
mkdir -p /home/wwwroot/vpnx-central/data
chmod 700 /home/wwwroot/vpnx-central/data

# 3) 在面板里建站点并指向该目录(或用 nginx.conf.example 里的 rewrite 片段)

# 4) 先自检(强烈建议, 不碰生产数据)
bash /home/wwwroot/vpnx-central/tests/php_check.sh

# 5) 浏览器打开站点, 用 data/install-info.txt 里的初始口令登录, 然后立刻改口令并删除该文件
cat /home/wwwroot/vpnx-central/data/install-info.txt
```

### base_url 的两种填法（决定 URL 长相，都能用）

| 方式 | 站点基址(base_url) | 节点请求 | 订阅地址 | 是否需要 rewrite |
|---|---|---|---|---|
| **A 零 rewrite** | `https://panel.example.com/vpnx/api.php` | `.../api.php/api/v1/node/heartbeat` | `.../api.php/sub/<token>` | **不需要** |
| B 干净 URL | `https://panel.example.com/vpnx` | `.../api/v1/node/heartbeat` | `.../sub/<token>` | 需要 `nginx.conf.example` 里那段 |

`api.php` 会自己从 `PATH_INFO` / `REQUEST_URI` / `SCRIPT_NAME` 推断应用相对路径，
两种方式都能正确路由并校验节点签名，**不需要你手工拼 PATH_INFO**。

> 数据目录一定要放在 web 根**之内但被拒绝访问**或**之外**；`nginx.conf.example` 里给了
> `location ~ ^/vpnx/(data|lib)/ { deny all; }` 的写法。仓库里 `lib/*.php` 被直接下载也只是
> 源码泄露（不含密钥），但 `data/` 泄露等于泄露全部账号与节点密钥。

---

## 2. 多服务器是怎么编排的（核心）

```
                     ┌──────────────── 中台(PHP + JSON) ────────────────┐
 管理员              │  nodes.json   节点注册表 + 密钥 + 运行时状态       │
  │  建账号           │  users.json   账号表(唯一事实来源)                │
  │  选"同步到哪些服务器"                                              │
  └─────────────────▶│  policy_state/<节点>.json  修订号/指纹/删除墓碑   │
                     └───────┬───────────────────────────┬──────────────┘
                             │ 节点每 60s 轮询            │ 节点上报
                             ▼                            ▲
              GET  /api/v1/node/policy             POST /api/v1/node/heartbeat
              POST /api/v1/node/report             POST /api/v1/node/subscription
                             │                            │
        ┌────────────────────┴───────────┬────────────────┴───────────────┐
        ▼                                ▼                                ▼
   VPS hk1 (vpnx agent)            VPS us1 (vpnx agent)            VPS sg1 (vpnx agent)
   本机创建/停用/删除账号            同左                            同左
```

**账号 → 服务器的分配规则**（在后台"账号"页勾选，或 `POST /api/v1/admin/users/<name>/nodes`）：

| 指派方式 | 含义 |
|---|---|
| 勾选具体节点 | 只在这些服务器上创建该账号 |
| 填标签(如 `hk`/`premium`) | 所有带该标签的服务器都创建；新增同标签节点会自动纳入 |
| 两者都不填 | **全部节点**（适合"一个账号全网可用"） |

中台与节点的职责分工：

| 事项 | 中台 | 节点(vpnx.sh) |
|---|---|---|
| 账号事实来源 | ✅ users.json | 按策略落地到本机 users.db |
| 到期 / 配额判定 | ✅ 集中判定并下发 `disable` | ✅ 本地也兜底判定(双保险) |
| 设备数限制 | 只展示 | ✅ 靠内核在线 IP 列表踢线 |
| 热加载/踢线 | — | ✅ `xray api adu/rmu`，不断开其他用户 |
| 订阅聚合 | ✅ 按账号 token 合并多节点 | 上报 links/clash/meta |
| 端口/伪装/档位 | ✅ 下发节点参数与档位 | 渲染配置并平滑重启 |

### 修订号(revision)怎么来的

中台为每个节点算一个**内容指纹**：`sha256(node参数 + 该节点账号集合 + 档位 + maintenance)`，
不包含 revision 本身。指纹变化 → `revision = 上次 + 1`；不变 → revision 保持不变，
节点带 `current_revision` 轮询时直接收到 `unchanged=true` 并跳过应用。
所以你**不需要手工点"发布"**：改账号、改端口、改档位、停用账号，都会自动让相关节点重新拉取。

被移出某节点或整体删除的账号会进**删除墓碑**（`policy_state/<节点>.json` 的 `pending_deletes`），
以 `action=delete` 下发给节点，节点 ack 后清除；节点离线多久都不会漏删。

---

## 3. 节点接入（在对应 VPS 上执行）

中台"节点"页每个节点都会给出两条命令，直接复制执行：

```bash
# 全新服务器：装节点 + 接入中台一步到位
bash vpnx.sh install --profiles reality,ss2022 \
  --central-url https://panel.example.com/vpnx \
  --node-id hk1 --token <节点密钥>

# 脚本已装好，只接入中台
vpnx agent set --url https://panel.example.com/vpnx --node-id hk1 --token <节点密钥>
vpnx agent install      # 装定时任务(每分钟触发, 实际间隔由 agent.conf 的 INTERVAL 控制)
vpnx agent test         # 立刻验证鉴权与连通性
```

节点注册流程：后台"节点 → 注册新节点"（或 `POST /api/v1/admin/nodes`）→ 中台生成
`node_id` + 32 字节 `secret` → **secret 只在响应/接口里给出，请立刻拷到节点上**；
`nodes.json` 里以明文保存（HMAC 校验需要），所以该文件权限必须是 0600。

---

## 4. 接口清单

### 节点接口（HMAC-SHA256 签名）

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/v1/node/heartbeat` | 心跳；返回 `policy_revision` / `policy_pending` |
| GET | `/api/v1/node/policy` | 拉策略；`?current_revision=N`、`?format=lines` |
| POST | `/api/v1/node/report` | 上报 `usage` / `events` / `ack` |
| POST | `/api/v1/node/subscription` | 推送各账号订阅内容 |
| POST | `/api/v1/node/script/update` | 脚本版本查询 |

签名串：`METHOD \n PATH \n TIMESTAMP \n NONCE \n SHA256_HEX(body)`
（**PATH 不含 query**；时间窗 300 秒；nonce 300 秒内不可重复；节点不存在与签名错误都返回 401）

### 管理接口（`X-Admin-Token` 或 `Authorization: Bearer`）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/admin/health` | 健康检查（**免鉴权**） |
| GET | `/api/v1/admin/stats` | 汇总统计 |
| GET/POST | `/api/v1/admin/nodes` | 节点列表 / 注册节点 |
| GET/PUT/DELETE | `/api/v1/admin/nodes/<id>` | 查/改/删节点 |
| POST | `/api/v1/admin/nodes/<id>/rotate` | 轮换密钥 |
| GET | `/api/v1/admin/nodes/<id>/policy` | 查看该节点将收到的策略（`?format=lines`） |
| PUT | `/api/v1/admin/nodes/<id>/policy` | **声明式下发**：`node.*` 改节点参数、`profiles.*` 改档位、`users[]` 建/停/删账号 |
| GET | `/api/v1/admin/nodes/<id>/usage` | 该节点用量与事件 |
| GET | `/api/v1/admin/nodes/<id>/commands` | 安装/接入命令 |
| GET/POST | `/api/v1/admin/users` | 账号列表（`?node=<id>` 过滤）/ 新建账号 |
| GET/PUT/DELETE | `/api/v1/admin/users/<name>` | 查/改/删账号 |
| POST | `/api/v1/admin/users/<name>/reset\|enable\|disable\|nodes` | 重置 / 启停 / 改同步范围 |
| GET | `/api/v1/admin/subscriptions` | 订阅清单 |
| POST | `/api/v1/admin/enforce` | 立即执行到期/配额检查 |
| GET | `/api/v1/admin/audit` | 审计日志 |

### 订阅接口（公开，token 即凭证）

```
GET /dist.php?f=vpn.zip         节点安装包(中台托管, 节点一条命令下载安装)
GET /sub/<token>                  Base64 链接列表(小火箭/v2rayN 直接导入)
GET /sub/<token>?target=raw       明文
GET /sub/<token>/clash            Clash Meta / mihomo(合并所有节点的 proxies)
GET /sub/<token>/clash-legacy     只含 VMess 节点(给 Clash for Android 等老内核)
GET /sub/<token>/clash-xhttp      只含 VLESS+XHTTP 节点(给支持 XHTTP 的新客户端)
GET /sub/<token>/singbox          sing-box
响应头 Subscription-Userinfo: upload=0; download=<已用>; total=<配额>; expire=<到期>
      Profile-Update-Interval: 12
```

### curl 示例（注意签名剥离 query）

```bash
TOKEN='<管理令牌>'
curl -sS -H "X-Admin-Token: $TOKEN" https://panel.example.com/vpnx/api/v1/admin/nodes

# 建一个只在 hk1、us1 上生效的账号
curl -sS -X POST -H "X-Admin-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"alice","expire_at":"90d","quota_bytes":"100G","max_devices":3,
       "protocols":["vless-reality","ss2022"],"nodes":["hk1","us1"]}' \
  https://panel.example.com/vpnx/api/v1/admin/users
```

---

## 5. 数据与安全

- `data/` 目录 0700，写出的 JSON 一律 0600（代码里 `vpnx_json_write` 会 chmod）。
- 所有写操作是"临时文件 + `rename`"原子替换；跨文件读改写用 `data/.lock` 的 `flock` 串行化。
- 后台会话用 `HttpOnly` Cookie + CSRF token；连续登录失败会写审计日志。
- 改口令会**同时轮换管理令牌**（旧 token 立即失效）。
- 首次初始化生成的 `data/install-info.txt` 含明文初始口令，登录后请删除。
- 强烈建议开 HTTPS：订阅地址是客户端会长期访问的凭证 URL。

---

## 6. 故障排查

| 现象 | 排查步骤 |
|---|---|
| 节点一直 401 | ① 节点是否已在中台注册（未注册一律 401）② `agent.conf` 的 TOKEN 是否与 `nodes.json` 的 secret 一致 ③ 两侧时钟是否同步（±300s）④ base_url 是否与中台实际路径一致（方式 A 必须带 `api.php`） |
| 节点在线但账号没建出来 | ① 后台"节点"页看 `已发布/已应用` 是否 `待应用` ② 看 `已应用 < 已发布` 时的 `last_error` ③ 在节点上 `vpnx policy pull` 手动拉一次看日志 ④ 确认账号的同步范围包含该节点 |
| 订阅为空 | 节点首次成功推送后才有内容；看"订阅"页链接数；节点侧确认 `vpnx agent run-once --debug` 里 subscription 推送成功 |
| 页面 500 | 看 PHP 错误日志与 `data/central.log`；先跑 `bash tests/php_check.sh` |
| 上传/写数据失败 | `data/` 必须对 PHP 运行用户可写（面板常见 www/nginx/php-fpm 用户） |
| 删除账号后节点上还在 | 看该节点 `pending_deletes` 是否 >0（节点离线时墓碑会保留，等它上线自动删） |

---

## 7. 与 Python 参考实现的关系

仓库里的 `references/central-python/` 是同一套接口契约的 **Python 标准库参考实现**，
带着 24 项端到端单测（`python3 -m unittest discover -s references/central-python/tests`），
用途是：

- 作为**契约基准**：接口字段、签名算法、`format=lines` 形状以它和本文档为准；
- 作为**差分对照**：PHP 版行为有疑问时，可以起 Python 版对比同一请求的响应。

**线上请部署 PHP 版**（`central/`），它才是与"建站面板 + 无数据库"要求匹配的实现，并且多了
账号按节点/标签分发、Web 后台、审计、订阅聚合这些运营能力。

两者的差异只有两处，都是 PHP 版**有意**的设计：

1. `PUT /api/v1/admin/nodes/<id>/policy` 在 PHP 版是**声明式**语义（合并进节点参数/档位/账号表），
   而不是"存一份不透明的策略文档"——因为 PHP 版把账号表当作唯一事实来源，策略是**推导**出来的。
2. revision 由**内容指纹**自动推进，而不是手工指定。
