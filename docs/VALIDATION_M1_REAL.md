# M1 实机验收记录（脱敏补录）

M1 COMPLETE。此记录在验收完成后补录，依据已保存的 SSH 脱敏摘要、最终回归校验记录和用户人工确认；本次补录未连接 VPS，也未重新执行验收。

## 基线与覆盖

- 实机：Debian GNU/Linux 12 (bookworm)，amd64 / x86_64。
- Kernel：6.12.95+deb12-amd64；Xray：官方 v26.9.9。
- 测试时源码：SFTP 上传，UNCOMMITTED，当时不存在 Git commit。
- 验收后 baseline snapshot：`6a6edad262c0909900e31e3a6a65853a9b1316ef`。
- Annotated tag：`v0.1.0`，明确标注 accepted M1 baseline，非历史发行记录。
- Git 作者/标记者使用 `NodeForge Automation <automation@nodeforge.invalid>`，不冒用用户身份，不回填历史时间。
- 37 个源码/模板/测试文件与实机最终回归曾核对的 SHA256 一致；清单见 [M1_SOURCE_SHA256.json](M1_SOURCE_SHA256.json)。该清单是来源追溯记录，不是发行签名。README、文档和 CI 不在这 37 项实机摘要覆盖中。
- Baseline 共 44 个文件；未包含原始 VPS evidence、节点凭据、SSH 密钥或本机 `.tools/`。
- 自动测试：Windows + Git Bash，ShellCheck、Bash 语法、10 个隔离 Shell 测试套件、6 个 Python 测试通过。另有真实 Windows Xray CLI 配置验证。
- 完整自动测试套件未在 Linux 上执行；真实 Linux 安装与服务验收单独完成。CI 配置存在不等于 GitHub CI 已运行。
- Ubuntu 22.04/24.04、arm64 只有实现支持/测试配置，尚无本次实机验收结论。

## 阶段结果与证据索引

以下目录均位于原验收 VPS，目录 0700、文件 0600，仅 root 可读。这里只保存索引，不把原始日志收入 Git。

| 阶段 | 结果 | 证据目录或来源 |
| --- | --- | --- |
| Clean Debian 12 Preflight | PASS | 用户确认及 First Install 前只读检查摘要 |
| First Install | PASS，installer exit 0 | `/var/tmp/nodeforge-first-install-KCipZY/` |
| Config Validation | PASS，config test exit 0 | `/var/tmp/nodeforge-config-validation-ibUA8W/` |
| Systemd | PASS，active/running + enabled | `/var/tmp/nodeforge-systemd-validation-aB8rDb/`；诊断修正见下一项 |
| Journal Diagnostic | PASS | `/var/tmp/nodeforge-journal-diagnostic-ze52YF/` |
| Listener | PASS，进程关联及 IPv4 TCP probe 通过 | `/var/tmp/nodeforge-listener-validation-FFLTLr/`；`/var/tmp/nodeforge-bind-diagnostic-s2YK2g/` |
| External Client | PASS | 用户人工确认；未提供客户端原始日志及精确版本 |
| Reboot Persistence | PASS | `/var/tmp/nodeforge-reboot-validation-9et8wg3k/` |
| Idempotency | PASS，身份/端口/文件保持一致 | `/var/tmp/nodeforge-idempotency-validation-B7urmT/` |
| Fail-Closed / Rollback | PASS，实测 pre-commit target 拒绝 | `/var/tmp/nodeforge-failclosed-validation-Vld9Rr/` |
| Uninstall | PASS，源码/evidence/SSH 保留 | `/var/tmp/nodeforge-uninstall-validation-0eSqWw/` |
| Reinstall | PASS，新身份允许变化 | `/var/tmp/nodeforge-reinstall-validation-oj9yNS/` |
| Final Regression | PASS，服务/配置/监听/权限/分享结构通过 | `/var/tmp/nodeforge-final-regression-OCdxmS/` |
| Final External Client Smoke Test | PASS | 重装后新身份，用户随后明确回复“全部通过。” |

最终服务 enabled、active/running，MainPID 有效、NRestarts=0，配置测试退出码 0；未发现第二实例、端口冲突或真实服务生命周期错误。最后远程摘要写于人工 smoke test 前，仍显示等待；本记录以随后的用户确认补充最终结论，不改写原始证据。

## 问题、修复及限制

1. Windows SSH 外层脚本 CRLF 导致包装退出码 2；安装器自身为 0。仅修正本机 SSH 输入为 LF、可靠传回远程退出码，未修改产品代码。
2. systemd 252 不接受原 `journalctl --since` 时间写法；改用 `YYYY-MM-DD HH:MM:SS UTC`，重新采集成功，非服务错误。
3. `ss` wildcard 展示不能直接与配置字符串比较；通过 socket family、bindv6only 及本机 IPv4 TCP 建连确认等价监听，非服务错误。
4. 实机失败注入使用安全环境变量指定回环 target，使公开目标校验在 commit 前拒绝。真实 VPS **未验证 post-commit rollback 或 interrupted/pending recovery**；这些只有隔离模拟测试覆盖，必须纳入 M2 实机门。
5. systemd unit 丢弃 Xray stdout/stderr；journal 结论限定为可见的服务生命周期/退出证据，不宣称完整流量日志无错误。
6. M1 实机验收未发现需要产品代码修复的缺陷。依据现有证据无已知 Critical/High 缺陷；不等于独立安全审计。

Phase 1 后续源码变更不自动继承这个实机结论；`v0.1.0` 固定的是验收后的原始 M1 snapshot。
