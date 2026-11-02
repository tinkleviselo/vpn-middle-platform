# vpnx 安装部署（最简单的用法）

只讲**怎么装**，不讲原理。装完之后所有日常操作（建账号、改端口、停用、删号、续期）**都在中台点鼠标完成**，节点会自动同步。

---

## 0. 需要准备什么

| 角色 | 数量 | 说明 |
|---|---|---|
| 中台服务器 | 1 台 | 有 PHP 的机器即可（**可以直接用你现在跑 建站面板的那台**） |
| VPN 节点 | 1 台起 | 海外 VPS，CentOS / AlmaLinux / Rocky / Debian / Ubuntu 都行 |
| 客户端 | 任意 | 小火箭（Shadowrocket）/ Clash / v2rayN / sing-box |

> 节点服务器**不需要**域名、不需要证书、不需要安装任何面板。中台和节点可以是同一台，也可以分开。

---

## 1. 装中台（约 5 分钟）

### 1.1 上传文件并设权限

把仓库里的 `central/` 整个目录上传到中台服务器，例如：

```bash
# 在本地打包(可选, 方便上传)
tar czf central.tgz central

# 上传到面板服务器后解压到站点目录
mkdir -p /home/wwwroot/vpnx-central
tar xzf central.tgz -C /tmp
cp -r /tmp/central/* /home/wwwroot/vpnx-central/

# 数据目录必须可写(用户组按你的面板实际, 面板常见 www 或 nginx)
mkdir -p /home/wwwroot/vpnx-central/data
chown -R www:www /home/wwwroot/vpnx-central
chmod 700 /home/wwwroot/vpnx-central/data
```

### 1.2 在面板里建一个站点

建站面板：**网站 → 建站** → 填域名或直接用服务器 IP → 选一个 PHP 版本（5.6 以上都行，推荐 7.4/8.x）→ **网站根目录指向 `/home/wwwroot/vpnx-central`**。

建好后浏览器打开：

```
http://你的面板IP或域名/
```

能看到登录页就说明中台跑起来了。

### 1.3 拿到初始口令并登录

```bash
cat /home/wwwroot/vpnx-central/data/install-info.txt
```

用里面的**管理员**和**初始口令**登录，然后：

1. 进入 **设置** 页 → **修改口令**（保存后 API 令牌会自动换新）
2. **删除** `data/install-info.txt`
3. **设置** 页里的「站点基址」**留空即可**（中台会自动推算成 `http://你的地址/api.php`）
   - 留空时走**查询参数模式**（`?__vpnx=/api/v1/...`）：**不需要配任何 rewrite**，
     兼容会拦截 `.php` 后面附加路径（返回 403）的面板与虚拟主机。
   - 想让订阅地址更好看（`https://域名/sub/xxx`），才需要按 `central/nginx.conf.example`
     配 rewrite，并把基址填成不带 `.php` 的干净地址。
4. 可选：在面板里给这个站点开 HTTPS（开了之后节点与订阅都会走 https）

> 想省事就到此为止。只有在你想让 URL 更干净（`https://域名/sub/xxx` 而不是 `https://域名/api.php/sub/xxx`）时，才需要按 `central/nginx.conf.example` 配一段 rewrite。

---

## 2. 添加节点（在中台点几下）

1. 中台 → **节点** → 填「节点 ID」（如 `hk1`）、显示名、公网 IP、标签（如 `hk`，可留空）→ **注册节点**
2. 注册后页面会给出**两条命令**，复制**第一条**（全新服务器装节点用）：

```
bash vpnx.sh install --profiles reality,ss2022 --central-url http://你的中台地址/api.php --node-id hk1 --token xxxxxxxx...
```

> 密钥只在中台显示，请直接复制命令，不要手抄。

---

## 3. 装节点（在 VPS 上执行，约 3 分钟）

### 3.1 先把脚本传上去（一次性）

```bash
# 在本地打包(可选)
tar czf vpnx.tgz vpnx.sh lib tools

# 上传并解压到 VPS
scp vpnx.tgz root@节点IP:/root/
ssh root@节点IP
cd /root && tar xzf vpnx.tgz && chmod +x vpnx.sh
```

### 3.2 粘贴中台给的那条命令

```bash
cd /root
bash vpnx.sh install --profiles reality,ss2022 \
  --central-url http://你的中台地址/api.php \
  --node-id hk1 --token 中台给你的密钥
```

安装过程会自动完成：装内核、生成密钥、挑一个没被占用的端口、建服务、放行防火墙。

**装完会打印节点用的端口，例如：**

```
REALITY    : 启用  端口 8443
SS2022     : 启用  端口 8388
```

### 3.3 去云厂商安全组放行这些端口

登录你的 VPS 服务商控制台，在**安全组/云防火墙**里放行上面看到的端口（协议选 TCP；SS2022 建议同时放行 UDP）。

> ⚠️ **这是最常见的“客户端连不上”原因**：云防火墙默认通常只放行 `22 / 80 / 443`，
> 而节点用的是高位端口（如 2053 / 8388）。**云防火墙和节点本机防火墙是两回事**，
> 本机放行了不代表云防火墙放行了（反之亦然）。
> 例：Linode → 控制台 → Firewalls → 绑定到该实例的防火墙 → Inbound Rules 加 `2053`、`8388`(TCP)、`8388`(UDP)。
>
> 忘了端口也不用回去翻记录：中台 **节点** 页每个节点都会显示「监听端口」。

### 3.4 确认节点已上线

回到中台 **节点** 页，1 分钟内该节点会变成 **在线**，并显示内核版本、系统、端口。

如果一直离线，看本文最后一节「出问题了怎么办」。

---

## 4. 建账号（以后都在中台做）

中台 → **账号** → 填：

| 字段 | 例子 | 说明 |
|---|---|---|
| 账号名 | `alice` | 字母数字 |
| 到期 | `90d` 或 `2026-01-31` | 留空 = 永久 |
| 流量配额 | `100G` | 留空 = 不限 |
| 设备数上限 | `3` | 0 = 不限 |
| 协议 | 勾选 REALITY、SS2022 | 默认已勾好 |
| **同步到哪些服务器** | 勾节点 / 填标签 / 都不填 | **都不填 = 所有节点** |

点「创建并下发」。节点会在 **1 分钟内**自动建好这个账号，无需登录节点服务器。

创建后该行会显示**订阅地址**，直接复制给用户。

---

## 5. 客户端导入订阅

中台 → **账号** 页，点该账号的 `base64`（或 `clash`）链接，复制地址，然后在客户端：

| 客户端 | 操作 |
|---|---|
| 小火箭 Shadowrocket（iOS） | 首页 → 右上 `+` → 类型选 **Subscribe** → 粘贴 **base64** 链接 → 保存 |
| v2rayNG（Android） | 订阅 → 订阅设置 → 添加 → 粘贴 **base64** 链接 → 更新订阅 |
| **Clash Verge / Clash Meta（mihomo）** | 订阅 → 新建 → 粘贴 **clash** 链接（`.../sub/<token>/clash`）<br>⚠️ **Clash 不认 base64 链接列表**，填 base64 那个会提示解析失败/全是乱码 |
| **Clash for Android（Kr328 旧版，Clash 内核）** | ❌ **不支持 VLESS，也不支持 SS2022 加密** → 报"不支持类型 vless"（它遇到不认识的节点类型会**拒绝加载整份订阅**，所以往同一个订阅里加 VMess 节点也没用） | ① 节点上启用 VMess：`vpnx install --profiles reality,ss2022,vmess-ws --yes`<br>② 中台给账号勾选 `vmess-ws` 协议<br>③ 手机上**改用账号行里的「兼容(旧Clash)」链接**（这条只含 VMess 节点，老内核能加载）<br>④ 或直接换 **Clash Meta for Android / FlClash**（粘 clash 链接即可） |
| Clash Meta for Android / FlClash / Hiddify（Android） | ✅ | 用 **clash** 链接（mihomo 内核，支持 VLESS+REALITY） |
| **XHTTP 专用链接**（`.../sub/<token>/clash-xhttp`） | — | 只含 **VLESS+XHTTP+REALITY** 节点。⚠️ 需要**较新**的客户端（Xray 系用 base64/raw 链接；mihomo 需支持 `network: xhttp`）。**默认 clash 链接不含 XHTTP 节点**，就是为了避免老客户端整份订阅加载失败 |
| Stash / Loon（iOS） | 用 **clash** 链接（较新版本才支持 REALITY） |
| sing-box | 用 `/sub/<token>/singbox` 链接 |

> 三个链接在中台「账号」页每行的**订阅**列里都有：`base64` / `clash` / `raw`，按客户端选对应的那个。

> ⚠️ **报错"不支持类型 vless / unsupported proxy type: vless"**：这是**客户端内核**不支持 VLESS，不是订阅的问题。
> 老版 **Clash / Clash Premium / Clash for Android(Kr328 旧版)** 内核只支持 SS/VMess/Trojan，遇到 `type: vless` 就会报这个错；
> **SS2022 的加密算法（`2022-blake3-*`）老内核同样不支持**。
> 两种处理：
> 1. **换客户端**（推荐）：Android 用 v2rayNG / NekoBox / FlClash / Clash Meta for Android；iOS 用小火箭 / Stash / sing-box；
> 2. **给这个客户端加兼容协议 VMess-WS**：
>    - 中台「设置」→ 允许的协议 → 勾上 `vmess-ws`；「节点」页给该节点填 **VMess 端口**（如 `8081`）→ 保存（节点下次同步会自动启用该协议）；
>    - 或在节点上直接执行 `vpnx install --profiles reality,ss2022,vmess-ws --yes`；
>    - 然后中台「账号」→ 编辑该账号 → 协议勾上 `vmess-ws` → 保存；
>    - 客户端更新订阅，改用订阅里的 **VMess** 节点即可。

---

## 6. 日常管理速查（全部在中台）

| 想做什么 | 在中台怎么做 | 节点侧 |
|---|---|---|
| 加账号 | 账号 → 新建 | 1 分钟内自动创建 |
| 停用/恢复 | 账号列表 → 停用 / 启用 | 立即踢线 / 立即恢复 |
| 给账号续期、改配额 | 账号行下方 → 改到期/配额 → 保存 | 自动同步 |
| 改账号能上哪些服务器 | 账号行下方 → 勾选节点/标签 → 保存 | 自动同步到新增节点，并从移除的节点删除 |
| 删账号 | 账号 → 删除 | 所有相关节点自动删除（节点离线也不漏删） |
| 重置密钥（客户端被分享出去） | 账号 → 重置 | 换 UUID 与密钥，需重新导入订阅 |
| 改端口 / 改伪装站点 / 换加密档位 | 节点页逐个改，或 设置页改默认值 | 自动下发并平滑重启 |
| 换节点密钥 | 节点 → 轮换密钥 | 需把新 token 更新到节点（命令会给出） |
| 看谁用了多少流量 | 概览 / 账号列表 | 节点每 60 秒自动上报 |
| 到期或超配额自动停用 | 自动发生（也可在概览页手动点「立即执行检查」） | 自动踢线 |

**节点侧平时不用登录。** 只用这几条排查命令：

```bash
vpnx status            # 看内核/端口/账号数
vpnx health check      # 看健康状态
vpnx agent status      # 看和中台的同步状态
vpnx agent test        # 测一下中台能不能连上
```

---

## 7. 加第二台、第三台节点

重复 **第 2、3 步** 即可（换个节点 ID，比如 `us1`，标签填 `us`）。

之后建账号时可以：

- 只勾 `hk1` → 只在这台上生效
- 填标签 `hk` → 所有标签为 `hk` 的节点都生效（以后再买同标签的机器会自动包含）
- 都不填 → 全部节点

---

## 8. 出问题了怎么办

| 现象 | 处理 |
|---|---|
| 节点一直显示离线 | 在节点上执行 `vpnx agent test`：<br>① 报 403 “Access denied” → 站点拦了 `.php` 后的附加路径；中台地址保持 `.../api.php` 即可（节点会自动改用查询参数模式 `?__vpnx=...`，无需改面板配置）<br>② 报 404 → 地址写错，未配 rewrite 时必须以 `/api.php` 结尾<br>③ 报 401 → 节点未注册 / token 不一致 / 两侧时间差 > 5 分钟<br>④ 报 000 → 网络、端口、DNS 或证书问题 |
| 节点在线但账号没建出来 | ① 先在中台「节点」页看是否显示 **待应用**（若一直不显示，说明中台版本旧，需更新 `central/`）<br>② 在节点上立刻手动同步一次：`vpnx agent run-once --force`（不加 `--force` 会被 60 秒间隔节流跳过）<br>③ 还不行就 `vpnx policy pull` 看具体报错 |
| 客户端连不上（超时） | **先在你自己电脑上测端口**：`curl.exe -vk --connect-timeout 8 https://节点IP:端口/`（PowerShell 5.1 里必须写 `curl.exe`，`curl` 是别名；若 `Test-NetConnection` 报 `Write-Progress 索引超出数组界限` 是它的渲染 bug，先 `$ProgressPreference='SilentlyContinue'`）<br>· **看到伪装站点的响应就是正常的**：例如 `Server: AkamaiGHost` 的 400 页、或证书是伪装域名 —— 这说明端口在监听且 REALITY 伪装生效<br>· `Connection refused`（RST）→ 服务器上没有进程监听该端口（不是防火墙问题！防火墙拦截会是 timeout）：看 `ss -lntp \| grep xray`，再 `vpnx health fix`<br>· `timed out`（丢包）→ 云防火墙/安全组没放行，或你的网络封了该端口（换端口）<br>节点侧确认：`vpnx status`（第 4 行"实际监听"）、`vpnx fw status`、`iptables -L INPUT -n --line-numbers \| head -5`（首条应为 `-j VPNX`） |
| 订阅打开是空的 | 节点首次推送后才有内容；看中台「订阅」页有没有该账号；节点上执行 `vpnx agent run-once --force` 再看 |
| Clash 订阅提示解析失败 / 打开全是 base64 | ① 你在 Clash 里填的是 **base64** 链接 —— 请改用 **clash** 链接（`.../sub/<token>/clash`）<br>② 若 clash 链接也返回 base64，说明订阅数据是旧的：更新中台与节点后执行 `vpnx agent run-once --force` 重推一次 |
| 想确认"是节点问题还是客户端问题" | 在节点上执行 `vpnx selftest`（自动挑一个启用账号，用本机 xray 以客户端身份连自己的 REALITY 端口做真实握手）：<br>· **通过** → 节点侧 UUID / 公钥 / shortId / SNI / flow 全部匹配，认证链路正常 → 问题在客户端或其网络<br>· **失败** → 会打印客户端与服务端日志，直接指出不匹配的地方<br>另外：mihomo 的延迟测试默认访问 `www.gstatic.com/generate_204`，**若节点到该地址不通，延迟测试会一直超时但隧道其实是好的** —— 打开系统代理/TUN 实际访问网站即可区分 |
| **参数全对但客户端就是超时**（REALITY 认证失败） | 服务端日志（loglevel 调 debug）出现 `REALITY: processed invalid connection ... handshake did not complete successfully` 时，先怀疑**伪装站点选得不好**：<br>· **`www.microsoft.com` 已知不可用**：微软证书链约 8KB，REALITY 握手无法完成；`xray tls ping` 也测不出来（[来源](https://linux.do/t/topic/2571392)）<br>· 修复：`sed -i "s#microsoft\.com#bing.com#g" /etc/vpnx/vpnx.conf && vpnx health fix && vpnx agent run-once --force`，**并把中台「设置 → 节点默认」的 `reality_target` / `reality_server_names` 一起改**（否则下次策略下发会改回来）<br>· 客户端记得更新订阅（SNI 变了） |
| 选了节点但 IP 没变（流量没走代理） | **在 Clash Verge 里双击节点只是"选中"，不等于让系统走代理**。必须打开：<br>· **系统代理**（设置 → 系统代理，或主界面那个开关），或<br>· **TUN 模式**（全局接管，需管理员/服务）<br>然后刷新 IP 查询页再看。<br>确认方法：Clash Verge 的**「连接」页**在你浏览网页时应有连接记录；空的就说明系统流量没进内核。<br>注意 Firefox 等浏览器有自己的代理设置（设成"不使用代理"会绕过）；Chrome/Edge 默认跟随系统代理。<br>本方案生成的订阅规则是 `MATCH,PROXY`（全部走代理），**不存在"国内站点直连"导致 IP 不变** |
| 某个协议超时、另一个正常（例如 SS 超时但 VLESS 通） | 在节点上执行 `vpnx selftest`（**逐协议**自测，走 `127.0.0.1`，因此**天然排除云防火墙**）：<br>· 该协议**本机自测也失败** → 节点侧配置/账号/密钥问题（自测会打印该协议的客户端日志）<br>· 该协议**本机自测通过、外部客户端不通** → 云防火墙没放行该端口（去控制台加规则）<br>手查账号密钥：`awk -F'\|' '$1=="账号名"{printf "protocols=%s sspsk_len=%d\n", $10, length($11)}' /etc/vpnx/users.db`（`sspsk_len` 应为 0 以外的正值） |
| 想加 XHTTP 档位（直连即可用，不需要域名/证书/CDN） | `vpnx install --profiles reality,ss2022,vmess-ws,xhttp --yes` → 自动挑端口并放行 → `xray -test -config /etc/vpnx/xray/config.json` 校验 → 中台给账号勾选 `vless-xhttp` → 客户端用 **base64/raw** 链接，或 clash 系用 `.../sub/<token>/clash-xhttp`。<br>⚠️ `flow` 必须为空（XHTTP 与 Vision 互斥，脚本已强制）；⚠️ 默认 clash 订阅不含 XHTTP 节点（老客户端会拒绝整份订阅） |
| 升级 Xray 内核后 REALITY 突然连不上 | 26.7.11 起 REALITY 新增 `minClientVer` 客户端版本校验，**旧客户端会被拒**（症状同样是 timeout / 连接被转发到真站，且日志几乎无提示）。处理：在 REALITY 配置里显式写 `"minClientVer": "1.0.0"`，或把内核降回旧版本（`vpnx upgrade --version v26.6.27`） |
| 节点名称太长/不好看 | 节点上是 `NODE_NAME`（默认取主机名）决定的：编辑 `/etc/vpnx/vpnx.conf` 的 `NODE_NAME=HK-1`，再 `vpnx agent run-once --force`，客户端里的节点名就会刷新 |
| 中台打不开 / 500 | 确认站点根目录指到了 `central`，且 `data/` 对 PHP 运行用户可写；在面板服务器上执行 `bash central/tests/php_check.sh` 自检 |
| 想重装中台 | 保留 `data/` 目录（账号与节点都在里面），只覆盖 `*.php` 与 `lib/` 即可 |
| 想卸载节点 | 在 VPS 上 `vpnx uninstall`（加 `--purge` 连账号库一起删） |

---

## 9. 三条命令速查表

```bash
# 中台（面板服务器）
cp -r central/* /home/wwwroot/vpnx-central/ && chmod 700 /home/wwwroot/vpnx-central/data
cat /home/wwwroot/vpnx-central/data/install-info.txt     # 取初始口令, 登录后改口令并删除该文件

# 节点（VPS, 命令由中台"节点"页给出）
bash vpnx.sh install --profiles reality,ss2022 --central-url http://中台/api.php --node-id hk1 --token 密钥

# 节点日常排查
vpnx status && vpnx health check && vpnx agent test
```

装完就把节点服务器放一边，**以后只管中台**。

## 中台分发安装（推荐：只需上传中台）

中台「节点安装」页可以托管节点安装包，节点侧**一条命令**即可下载并装好。
以后你只要上传 `central.zip` 到面板即可 —— `central.zip` 里已附带最新的 `dist/vpn.zip`，
节点上**不需要再手工传任何文件**（也可以在该页直接上传新的 zip 覆盖）。

1. 中台「节点安装」页确认已有节点包（显示大小/sha256/下载地址）；
2. 「节点」页注册一台节点（填名称即可），回到「节点安装」页复制它专属的命令；
3. 到新服务器（root）粘贴执行：

```bash
curl -fsSL "https://面板/dist.php?f=vpn.zip" -o /tmp/vpn.zip \
  && rm -rf /tmp/vpnnew && mkdir -p /tmp/vpnnew && unzip -oq /tmp/vpn.zip -d /tmp/vpnnew \
  && cd /tmp/vpnnew && bash vpnx.sh install --profiles reality,ss2022,vmess-ws,xhttp \
       --central-url https://面板/api.php --node-id <节点ID> --token <节点密钥>
```

4. 已装过的节点升级脚本（幂等、不断线）用同一页的「已装过的节点」命令：

```bash
curl -fsSL "https://面板/dist.php?f=vpn.zip" -o /tmp/vpn.zip \
  && rm -rf /tmp/vpnnew && mkdir -p /tmp/vpnnew && unzip -oq /tmp/vpn.zip -d /tmp/vpnnew \
  && \cp -f /tmp/vpnnew/vpnx.sh /usr/local/vpnx/ \
  && \cp -rf /tmp/vpnnew/lib /tmp/vpnnew/tools /tmp/vpnnew/tests /usr/local/vpnx/ \
  && vpnx version
```

5. 装完自检：

```bash
vpnx agent test && vpnx selftest && vpnx health check
sudo bash /usr/local/vpnx/tests/server-smoke.sh     # 可选但强烈建议(70 项断言)
```

> 包里只有脚本，不含任何密钥；节点 token 由安装命令传入，等于节点凭证，别外泄。

### 批量升级节点脚本（中台发起，节点自动执行）

换了新的节点包（`vpn.zip`）之后，不必逐台粘贴命令：

1. 中台「节点安装」页上传新的 `vpn.zip`（或直接上传新的 `central.zip`，里面带的 `dist/vpn.zip` 就是新版）；
2. 在「节点安装」页点某台节点的「推送升级」，或点「推送升级到全部节点」；
3. 节点在 60 秒内自动：下载新包 → **校验 sha256** → 备份旧脚本到 `/usr/local/vpnx.bak.<时间>` → 覆盖 `vpnx.sh` 与 `lib/tools/tests`；
4. 升级**不断线、不重启内核**（只换脚本），失败会放弃并上报（中台「节点」页可见），可用「取消升级」撤回指令。

节点侧开关：`/etc/vpnx/vpnx.conf` 里 `UPGRADE_ENABLED=1`（默认开）；设 `0` 可让该节点忽略中台的升级指令。