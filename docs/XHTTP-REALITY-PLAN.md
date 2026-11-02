# VLESS + XHTTP + REALITY 实施计划（已实现, build 20261010.5）

目标: 新增一档"直连即可用"的传输, 不需要域名/证书/CDN (REALITY 负责伪装, XHTTP 只负责传输层)。

## 两个硬约束
1. flow 必须为空: xtls-rprx-vision 只支持 RAW/TCP, XHTTP+Vision 不能同用。档位/渲染/订阅三处强制 flow=""。
2. 客户端支持度不一 -> 订阅必须安全降级: 老客户端遇到不认识的 transport 会拒绝加载整份订阅
   (Clash for Android 的教训)。所以 clash 订阅默认不输出 xhttp 节点, 另给 .../clash-xhttp 独立链接;
   base64/raw 订阅照常包含 xhttp 链接。

## 待办(按顺序, 每步可验证)
1. 档位(lib/profile.sh 内置): xhttp-reality -> type=vless-xhttp, network=xhttp, path=/vpnx-xhttp, mode=auto, flow=""
2. cfg_init(lib/config.sh): XHTTP_ENABLED=0 / XHTTP_PORT= / XHTTP_PATH=/vpnx-xhttp / XHTTP_MODE=auto / XHTTP_HOST=
3. 端口选择(lib/install.sh 步骤7): --profiles 支持 xhttp|vless-xhttp, 自动挑空闲端口并放行
4. 渲染(lib/config.sh): 新增入站 in-xhttp
   - network="xhttp" + security="reality"(复用 REALITY_PRIVATE_KEY/SHORT_IDS/SERVER_NAMES)
   - 字段名按内核版本: v25+ 用 xhttpSettings; 若 xray -test 报未知字段 -> splithttpSettings
   - clients 的 flow 留空; decryption="none"; 复用 config_user_valid 与 user_email name x
5. 协议模型: user_proto_active 支持 xhttp; proto_tag xhttp -> in-xhttp; user_email xhttp -> name@x;
   user_hot_add(lib/users.sh) 加 xhttp 分支(adu)
6. 策略映射(lib/agent.sh): allow_protocols 加 vless-xhttp; _policy_set_port 支持 xhttp; 协议映射 vless-xhttp -> xhttp
7. 订阅(lib/sub.sh): sub_links 输出 vless://...&type=xhttp&path=...&mode=auto (无 flow);
   clash 条目 network: xhttp(仅 target=clash-xhttp 时输出); 中台 lib/sub.php 加 clash-xhttp 目标, views 加 xhttp_url
8. 自测(lib/health.sh): _selftest_write_config 加 xhttp 分支; 逐协议循环加 xhttp
9. 防火墙: install.sh 与 _agent_refresh_firewall 放行 xhttp 端口 tcp
10. 中台: 白名单加 vless-xhttp; 账号协议复选框加一项; 节点页加 XHTTP 端口字段(ports_xhttp)
11. 文档: docs/QUICKSTART.md 客户端表格加一行; docs/ROADMAP.md 勾掉该项
12. 测试: tests/server-smoke.sh 断言(含 "network": "xhttp" 且该入站 flow 为空、clients 字段名正确);
    central/tests/php_smoke.php 断言(clash-xhttp 只含 xhttp; 默认 clash 不含 xhttp)
13. 静态检查 0 错误 + 重新打包 vpn.zip/central.zip (build +1)

## 验证顺序
    vpnx install --profiles reality,ss2022,vmess-ws,xhttp --yes
    xray -test -config /etc/vpnx/xray/config.json     # 报未知字段就换 splithttpSettings
    vpnx selftest my                                  # 应出现 xhttp: 通过
    # 客户端: Xray 系用 base64 链接; clash 系用 /clash-xhttp 链接

## 风险
| 风险 | 处理 |
|---|---|
| xhttpSettings/splithttpSettings 字段名随版本变 | 以节点 xray -test 为准, 渲染按版本判断 |
| mihomo 老版本不认 network: xhttp | clash 订阅默认不输出 xhttp, 独立链接隔离 |
| 小火箭等对 XHTTP 支持不完整 | 文档注明"视版本", 提供 raw 链接兜底 |
## 不依赖 bash/xray 的渲染校验

    python3 tests/render_check.py      # 退出码 0 = 通过

它从 `lib/config.sh` 机械还原 in-xhttp 的 printf 渲染结果并交给 json 解析,
逐项断言(protocol/network/security/xhttpSettings/clients 无 flow/复用私钥/shortIds),
另附源码级回归断言(SS 入站的 clients 字段名)。任何机器都能跑, 无需 bash 与内核。
