# M4 最终回归

2026-09-19；开发版本 `v0.4.1-dev`；验收时正式基线/HEAD：
`0308f3200918f2e2b5cdac1aa24ce76751070dfd`（v0.3.0）。该记录对应正式发布前的开发版本验收。

## 自动化

- Windows Git Bash 与 Debian 12 amd64：23 个 Shell 套件全部通过；7 个 Python 套件、47 个测试全部通过。
- 全量 ShellCheck、Bash 语法检查通过；`git diff --check` 通过。
- 首轮发现 `test_cli_lock.sh` 的 installer main 测试未 mock 新增安装阶段；仅补齐 Argo/Subscription 的锁断言 stub，重跑失败及尚未运行的测试后全部通过。
- Windows 无法执行的原生符号链接分支由 Linux 完整套件覆盖。

## 真实 VPS

- 原实例卸载、全新安装、幂等再次安装通过；重复安装配置摘要、链接及五个服务实例 ID 不变。
- Reality TCP 443、HY2 UDP 443 的进程归属正确；HY2 20000–50000 跳跃端口配置及 IPv4/IPv6 原生 nft redirect 规则正常。
- Argo 独立 Xray 仅监听 127.0.0.1；官方 cloudflared Quick Tunnel、TLS 证书验证及公网 WS 101 握手通过。
- `status/info/link/restart/uninstall` 通过；systemd unit 校验及两个 Xray 正式配置校验通过。
- Argo 停止时清除运行状态，订阅返回 503 而不提供旧链接；重新连接后同一 URL 返回当前域名，Reality/HY2 服务实例不变。
- edge address 仅替换 Argo 链接 address，Host/SNI 不变；已恢复默认空值。
- 实际 VPS reboot 后五个服务自动启动，三节点及订阅恢复，Argo 重新获取新域名；公网读取订阅为 HTTP 200、正确三条节点。
- 配置摘要不符时 `status/info/link/restart` fail-closed；真实安装事务注入一次 systemd restart 失败后，配置、服务和链接成功回滚。
- `nodeforge update`、`nodeforge xray-update` 在线检查均为 current/no-op，配置及服务不变；版本替换、签名验证和失败回滚由自动化套件覆盖，未创建远端版本进行升级演练。
- 验收结束已恢复原 Reality/HY2/Argo 身份及原订阅 URL；原配置摘要一致。客户端联网由用户此前手工验收通过，本轮没有 GUI/客户端自动化。

## 结论

技术验收通过；正式发布版本收口为 `v0.4.0`，本记录保留 `v0.4.1-dev` 验收结果。发布仅更新版本、生成 bootstrap 与签名资产，不重复完整回归；未进入 M5。
VPS 原始日志与恢复快照位于 `/root/nodeforge-m4-final/`；本机验收脚本/日志位于 Git 忽略的 `.tools/`，不属于发布内容。
