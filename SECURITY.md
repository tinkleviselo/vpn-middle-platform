# 安全说明

## 报告问题

如果发现安全问题，请**不要**公开提交 issue，而是通过仓库的 Private vulnerability reporting
或维护者邮箱私下联系。请在报告中包含：影响范围、复现步骤、以及（如适用）修复建议。

## 设计上的安全边界

- 节点 → 中台：HMAC-SHA256 签名（方法 / 路径 / 时间戳 / nonce / 正文哈希）+ 时间窗 + nonce 防重放
- 中台 → 节点：仅通过节点主动轮询下发（pull），中台不主动连接节点
- 脚本升级：sha256 校验 + 包结构检查 + 备份；任一校验失败即放弃并上报
- 订阅显示名：不含节点 ID / 主机名 / 端口 / 账号明文
- `central/data/`、`central/dist/*.zip` 含密钥与构建产物，已通过 `.gitignore` 排除

## 部署注意

- 中台首次部署后请立即修改管理员口令，并删除 `central/data/install-info.txt`
- 生产环境不要把 `central/data/` 暴露在 Web 可访问路径（默认已在站点目录内，但请确认 Nginx/Apache 不提供静态访问）
- 请为管理后台启用 HTTPS