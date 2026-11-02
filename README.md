# vpnx

> 一条命令把 VPS 变成多协议代理节点；用 PHP + JSON 的中台纳管多台机器、下发账号与订阅。
> **节点侧纯 Bash（兼容 3.2+），中台侧纯 PHP（5.6+），无数据库、无需 jq/python。**

## 特性

**节点（`vpnx`）**

- 四种协议档位：`VLESS + REALITY(Vision)`、`Shadowsocks-2022`、`VMess-WS`、`VLESS + XHTTP + REALITY`
- 账号：配额 / 到期 / 设备数上限 / 协议白名单，均由节点按内核统计强制执行
- 订阅：base64 链接、Clash/mihomo、XHTTP 专用、兼容旧 Clash（只含 VMess）
- 运维：逐协议自测、健康检查与自愈、`status` 端口一致性检查
- 兼容：systemd 太老时退化为 cron；与常见建站面板共存（只追加自己的防火墙规则，不动别人的）

**中台（`central/`）**

- 多节点纳管、策略版本下发（节点每 60 秒轮询）、账号与订阅集中管理
- 节点注册即生成**一条安装命令**；节点包由中台分发，节点可一键安装
- 支持向节点**推送脚本升级**（节点自行下载 → 校验 sha256 → 备份 → 覆盖）
- 无数据库：全部状态放在 `central/data/` 下的 JSON 文件里，备份=拷目录

## 架构

```
         ┌──────────── 中台 (PHP + JSON) ────────────┐
         │ 节点注册 / 账号 / 策略 / 订阅 / 安装包分发 │
         └───────────────▲───────────────┬───────────┘
                心跳+拉策略 │               │ 下发账号/参数/升级指令
                   (60s)  │               ▼
   ┌──────────────────────┴────┐   ┌──────────────────────┐
   │  节点 A  (vpnx)           │   │  节点 B  (vpnx)      │
   │  Xray: REALITY/SS/VMess/  │   │  ...                 │
   │        XHTTP              │   │                      │
   └────────────▲──────────────┘   └──────────────────────┘
                │ 订阅链接 / 分享链接
          客户端（Clash / v2rayN / sing-box / 小火箭 …）
```

节点**主动**连中台（pull 模型），中台不反向连接节点。

## 快速开始

### 1) 部署中台

把 `central/` 整个目录放到你的站点目录（示例：`/www/panel`），确保 `central/data/` 可写：

```bash
curl -s "https://panel.example.com/api.php?__vpnx=/admin/health"   # 期望 {"ok":true,...}
```

首次访问会生成管理员口令，写入 `data/install-info.txt` —— **登录后改口令并删除该文件**。

> 中台的 URL 支持两种形态：以 `.php` 结尾（如 `.../api.php`，零 rewrite）或干净基址（需按 `central/nginx.conf.example` 配 rewrite）。

### 2) 添加节点

中台「节点」页注册一台机器 → 复制它给出的**一条命令**，到 VPS 上以 root 执行即可（自动装内核、生成密钥、挑端口、放行防火墙、接入中台）。

### 3) 建账号、发订阅

中台「设置」勾选允许的协议 → 「账号」新建并勾选协议 → 节点 60 秒内自动创建账号并回推订阅。
客户端用「账号」页的链接：`base64`（Xray 系）/ `clash`（mihomo 系）/ `XHTTP`（仅 XHTTP 节点）/ `兼容(旧Clash)`（仅 VMess）。

## 目录结构

```
vpnx.sh              节点入口（子命令分发）
lib/                 节点实现（config/xray/users/sub/agent/health/install/os）
tools/               辅助脚本
tests/               静默回归测试（Bash + Python，见下）
docs/                运维文档（QUICKSTART / ARCHITECTURE / CENTRAL-API / OPERATIONS …）
references/          早期 Python 版中台参考实现（保留作设计参考）
central/
  index.php          中台后台（单入口）
  api.php            节点/管理 API（HMAC 签名 + 防重放）
  dist.php           节点安装包下载端点
  lib/               中台实现（store/policy/sub/auth/views/dist …）
  data/              运行时数据（JSON，不入库；含密钥，勿提交）
  dist/              内置节点包（构建产物，勿提交）
scripts/build-dist.sh  构建发布包（vpn.zip / central.zip）
```

## 环境要求

| 部分 | 要求 |
|---|---|
| 节点 | Linux（CentOS 7+/Alma/Rocky/Debian/Ubuntu），Bash 3.2+，root；`curl`/`tar`/`unzip` 可选（缺失时自动降级） |
| 中台 | PHP 5.6+（推荐 7.x/8.x），扩展：`json`、`hash`；Web 根指向 `central/` |
| 中台（可选） | 能让节点下载 `dist.php`（用于分发安装包与推送升级） |

## 测试

```bash
python3 tests/lint_shell.py .        # Bash 静态检查
python3 tests/lint_php.py .          # PHP 静态检查
python3 tests/render_check.py        # 配置渲染结构校验(不需要 bash/xray)
sudo bash tests/server-smoke.sh      # 节点侧冒烟测试(70 项断言, 会在临时目录跑假内核)
bash <站点>/central/tests/php_check.sh   # 中台侧自测
```

CI（`.github/workflows/ci.yml`）会在每次 push 时跑前三个检查。

## 构建发布包

```bash
./scripts/build-dist.sh        # 需要 bash + zip, 产物落在 dist-out/
#   dist-out/vpn.zip       节点包(脚本 + 测试 + QUICKSTART)
#   dist-out/central.zip   中台包(内含 dist/vpn.zip, 上传即可用)
```
## 发布

打 tag 即自动发布（CI 先跑静态检查，通过后构建 `vpn.zip` / `central.zip` 并挂到 Release）：

```bash
git tag -a v1.0.0 -m "vpnx v1.0.0"
git push origin v1.0.0
```

也可以在 GitHub 的 **Actions → release → Run workflow** 手动触发（填版本号）。
发布流程见 [`.github/workflows/release.yml`](.github/workflows/release.yml)。
## 安全模型

- 节点 → 中台接口使用 **HMAC-SHA256 签名**（方法/路径/时间戳/nonce/正文），带时间窗与 nonce 防重放
- 中台下发的脚本升级会**校验 sha256**、检查包结构、备份旧版本，任何一步不符即放弃并上报
- 订阅链接只含客户端可用参数；节点 ID / 主机名 / 端口不会出现在**订阅显示名**里
- `central/data/` 与 `central/dist/*.zip` 含密钥与构建产物，已在 `.gitignore` 中排除

## 许可证

[MIT](LICENSE)

## 免责声明

本项目仅供学习与研究使用。请在你所在的司法辖区法律与服务商条款允许的范围内使用；
作者不对任何滥用行为及由此产生的后果承担责任。