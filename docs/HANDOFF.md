# NodeForge 交接快照

**2026-09-12 更新：M2 Phase 2 本地 CLI 已完成 B1/B2 blocker remediation，并在完整测试后进行只读 pre-commit audit，结论 READY FOR COMMIT，等待用户审核；尚未 commit。18 个隔离 Shell 套件、18 个 Python 测试、ShellCheck/Bash 语法检查及 diff 检查均 PASS。当前 VERSION 仍为 `v0.2.0-dev`，只支持 schema 1；没有操作 VPS、没有进入 Phase 3。当前设计、恢复边界和验证记录以 [M2_PHASE2.md](M2_PHASE2.md) 为准。Linux 原生权限、symlink、flock 和 systemd 行为仍需实机验证。以下保留 Phase 1 accepted handoff 历史快照，所列“尚未实现 CLI”描述属于该历史时点。后续先等待用户审核/指令。**

当前停在 **M2 Phase 1 完成并提交**。下一步是 **M2 Phase 2 Local Management CLI**；本次交接没有开始 Phase 2，没有连接或操作 VPS。新会话先阅读本文、[Phase 1 约束](M2_PHASE1.md)及相关源码，再按用户确认的阶段边界推进。

## 目标与基线

NodeForge 是安全、模块化、可测试的安装/配置工具，协议由官方 Xray-core 实现。唯一协议栈为 VLESS + TCP/RAW + REALITY + XTLS Vision。M2 将其扩展为一行安装、统一管理、版本化发行和安全更新工具，不能破坏 M1 行为。

- M1 baseline commit：`6a6edad262c0909900e31e3a6a65853a9b1316ef`。
- Annotated tag：`v0.1.0`，accepted M1 baseline。
- 这是验收完成后建立的 snapshot；测试时为 SFTP 源码副本、没有 Git 历史。没有伪造历史 commit。37 项源文件摘要与保存的实机验收清单、baseline Git blobs 均核对一致。
- M2 Phase 1 commit：`cff8006b8bb27f82dc0fcfcfdbc3c86fd6a3ddac`，标题 `M2 Phase 1: baseline, version and state compatibility`。
- Git 作者为明确标注的 NodeForge Automation；未发布到远程仓库。

## M1 验收范围

**仅 Debian 12 amd64 完成实机验收**：preflight、首次安装、配置测试、systemd、监听、外部客户端、整机重启、幂等、pre-commit fail-closed、卸载、重装、最终服务回归与重装后人工客户端 smoke test 均 PASS。最后客户端结论由用户确认；未提供精确客户端版本或原始客户端日志。

实机 post-commit rollback 和 interrupted/pending recovery 未执行，只有模拟测试覆盖。Ubuntu/arm64 是实现支持范围，不能写成实机已验证。详见 [脱敏验收记录](VALIDATION_M1_REAL.md)与 [源码摘要](M1_SOURCE_SHA256.json)。原始受保护 evidence 不收入 Git。

## Phase 1 现状

- `VERSION` 为单一 NodeForge 版本来源：`v0.2.0-dev`；读取到 `NF_NODEFORGE_VERSION`。
- Xray 默认 `v26.9.9`，变量为 `NF_DEFAULT_XRAY_VERSION`、`NF_XRAY_VERSION`；对外 `NODEFORGE_XRAY_VERSION` 不变。
- `lib/state.sh` 抽取原 schema-1 归属检查，增加只读 schema 支持探测。正式读取仍由 `load_existing` 验证受管文件摘要。
- 正式 state 仍写 **schema 1**，`.version` 仍指 Xray；字段和序列化保持不变。schema 2/未知 schema 拒绝，无迁移函数或启用开关，无新增私钥副本。
- README 和验收说明已补录。安装/卸载入口、配置与服务模板保持不变；VERSION 缺失/格式错误会拒绝加载不完整源码。
- 交接前重跑 `bash tests/run.sh`：退出码 0，ShellCheck、Bash 语法、12 个隔离 Shell 套件、6 个 Python 测试全部 PASS；diff 检查及 baseline 摘要复核 PASS。

## M2 架构决策与强制安全边界

1. CLI `/usr/local/bin/nodeforge` 为小型分派入口，调用共享模块；运行时拟安装于 `/usr/local/nodeforge/app/releases/<version>/`，`app/current` 指向当前版本。每次调用固定模块版本，保留现有 Xray/config/unit 路径。
2. Bootstrap 内置固定发行公钥；安装后的 trust anchor 独立于 versioned runtime，拟放 `/etc/nodeforge/trust/release-ed25519.pub`。update 不得替换公钥，M2 不做 signing key rotation。首次 raw bootstrap 的信任依赖用户认可的官方来源/固定引用；不能声称脚本能自我认证。
3. Signed manifest 是发行信任对象：先验原始字节 Ed25519，再校验 archive SHA256。JSON 拒绝 duplicate keys、类型错误及不兼容 schema；内外 manifest/sig 如同时存在必须字节一致。安全提取拒绝越界、链接、特殊文件及缺项；校验完成才执行 installer。
4. 所有 mutating operations 共用稳定 `/run/lock/nodeforge.lock`，install/update/restart/uninstall 互斥；只读 CLI 共享锁避免读到 commit 中间状态。当前 M1 锁覆盖范围尚未扩展。
5. Schema 2 不复制私钥，未来 link 在锁内验证 state/config 摘要和身份一致性，包含公钥与配置密钥关系；不一致 fail-closed。显式 migration 保留原身份/端口，可恢复原 schema-1 字节，尚未实现。
6. NodeForge self-update 与 Xray binary update 分层，默认不隐式升级另一层。官方来源校验 → staging → config test → snapshot → commit → health → finalize；失败恢复旧 working version。运行中的旧可信事务引擎完成提交/恢复，不在切换时混用模块。节点身份/端口默认不变。
7. Runtime、Xray、backups 有界保留 current + previous known-good，另有单个进行中 pending；只清理 manifest/state 确认归属的旧文件。健康确认前保留旧版本，未知文件不删。尚未实现。
8. 保持 strict shell、root 权限检查、受保护临时目录与清理、敏感配置 0600、不泄露凭据、不执行 eval 或未验证远程 shell。日志不打印分享链接；仅显式 `link` 向授权调用者输出当前链接。

## 下一步：Phase 2 Local Management CLI（尚未实现）

- 实现本地 CLI 安装/分派及 `status`、`info`、`link`、`version`、`restart`、`uninstall`，复用 service/state/share 和现有卸载实现。
- 无参数显示帮助；权限不足明确失败，不放宽配置权限。status/info 不泄露连接凭据；link 标准输出仅当前有效链接。
- restart 先以正式配置执行 Xray config test，失败不重启；成功后受控重启并限时验证 active/running、MainPID/可执行文件和监听恢复，失败非 0。
- 测试 CLI 输出/权限/隐私、锁一致性、失效配置拒绝重启、监听 PID 关联、卸载委托和 M1 回归。测试必须 mock 系统操作，不能修改开发机 systemd。
- 本阶段不实现 bootstrap、release signing、update 或实际 schema migration；它们留待后续独立阶段。实机操作需另按用户阶段授权。

## 限制与后续 Completion Gate

- 本地自动测试环境为 Windows + Git Bash，完整自动套件未在 Linux 上运行；CI 配置存在不代表 GitHub CI 已执行。本次没有重跑联网 Xray 集成检查。
- M1 多文件事务尚无 fsync 协议，备份不轮转；不能提前宣称 M2 的中断恢复/retention 已实现。
- systemd journal 只反映服务生命周期，Xray stdout/stderr 被丢弃。Debian systemd 252 时间使用 `YYYY-MM-DD HH:MM:SS UTC`；监听 wildcard 需语义判断，不能单纯比较字符串。
- 官方 NodeForge GitHub owner/repo、生产发行签名公钥与私钥保管方案待落实；不生成或提交生产私钥，不使用测试密钥作为生产 trust anchor。
- M2 实机门必须分别验证 M1→M2 migration、self-update、Xray update、post-commit rollback、pending recovery、reboot persistence、最终外部 v2rayN smoke test，加完整自动测试/ShellCheck/M1 回归及无已知 Critical/High 缺陷。M1 pre-commit PASS 不能替代这些门。
- 禁止扩大范围：新协议、Trojan、Shadowsocks、VMess、Hysteria2、TUIC、WebSocket、gRPC、XHTTP、多实例、多用户面板、subscription server、Web UI、Docker、Cloudflare Argo、WARP、nginx、CDN；不新增无关重构。

本地测试命令为 `bash tests/run.sh`，依赖 ShellCheck、jq、Python 等。Windows 可用 Git Bash，并把本机已忽略的 `.tools` 加入测试 PATH、通过 `PYTHON` 指定 Python；`.tools` 是本地工具/历史证据区，禁止整目录提交或公开。本交接文件不包含任何节点凭据或服务器访问密钥。
