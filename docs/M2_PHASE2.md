# M2 Phase 2 — Local Management CLI

**状态：COMPLETE；M2 正式版本 v0.2.0。以下为本阶段范围记录；当前总览见 [HANDOFF.md](HANDOFF.md)。**

## 范围与基线

本阶段实现本地 installer 安装的 `nodeforge` 管理入口，等待用户审核；不代表整个 M2 COMPLETE。本次没有连接或修改 VPS。

- M1 accepted baseline：`6a6edad262c0909900e31e3a6a65853a9b1316ef`，annotated tag `v0.1.0`。
- Phase 1：`cff8006b8bb27f82dc0fcfcfdbc3c86fd6a3ddac`。
- 开始工作时 HEAD：`de754512bc3aa4d8cd96e9f80ffa745c3b73322c`，working tree clean。
- `VERSION` 保持 `v0.2.0-dev`；state 保持 schema 1，`.version` 仍为 Xray 版本。
- 不实现 bootstrap、远程安装、Release/manifest 下载、签名发行、update、Xray update、schema 2 或 migration；不扩展协议、UI、subscription、Docker 或多实例。

## 命令、权限与退出码

| 命令 | 权限 | 行为 |
| --- | --- | --- |
| 无参数、`help`、`--help` | 普通用户 | 简洁帮助，成功返回 |
| `version` | 普通用户 | 复用 `load_nodeforge_version`，输出 `NodeForge v0.2.0-dev` |
| `status` | root | 校验可信安装及服务/监听；全部通过才输出 `Status: healthy` |
| `info` | root | 脱敏版本、schema、固定 service/protocol、监听地址/端口及文件路径；服务检查失败时返回非 0 |
| `link` | root | 输出一行现有 VLESS URL；公私钥关系不一致时拒绝，不猜测、不重新生成身份 |
| `restart` | root | 正式配置测试成功后重启固定 service，再检查 active/running、MainPID、可执行文件及 TCP listener |
| `uninstall` | root | 调用现有 `uninstall_nodeforge`，包括受管文件、备份、账户和新增 CLI 的清理 |

成功为 0；未知命令、多余参数、权限不足、锁冲突、无效 state、未知 schema、配置或服务异常均非 0。错误不回显用户输入或原始敏感诊断。权限不足提示 `NodeForge: this command must be run as root`，不自动 sudo，不改变 state/config 的权限。

## 架构与复用

- `nodeforge.sh` 处理 strict shell、固定 PATH、版本/模块加载，然后调用 `cli_main`。`lib/cli.sh` 提供小型固定分派和各命令函数。
- 继续通过 `lib/version.sh` 读取唯一 VERSION，不硬编码 CLI 版本，不调用 Git。
- `cli_load_state` 先调用 Phase 1 的 `state_schema_supported`，再进行严格 JSON/身份检查，最后调用现有 `load_existing` 核对 config/binary/unit/license 摘要并读取现有参数。
- `lib/management.py` 只用 Python 标准库及系统 OpenSSL：拒绝重复 JSON key、缺失/未知 state 字段、错误类型、非 M1 配置结构和无效参数。通过 stdin 向 OpenSSL 传入内存中的 PKCS#8 X25519 私钥，推导公钥与 state 比较；不将私钥放入命令参数或新增文件。
- 从原 `print_node` 提取 `node_link`，installer 输出格式保留；CLI 只调用同一个链接生成函数。
- `lib/service.sh` 新增管理端的严格健康检查，不改变 M1 原有 activation 检查语义。
- CLI 卸载直接调用同一个 `uninstall_nodeforge`，没有复制第二套卸载实现。全部模块先加载到 Bash，再删除入口和模块文件，当前调用可以正常完成。

## 可信状态、服务与隐私

管理命令在同一个稳定锁内读取 state/config，拒绝 pending 安装事务；只读命令不触发 recovery。schema 2 和未知 schema 一律拒绝，没有转换函数、writer 或启用开关。

除完整摘要核对外，CLI 将配置结构与现有固定模板核对，验证 UUID、shortId、端口、IP、SNI、target、私钥/公钥格式和公私钥关系。正式 unit 必须与受管模板一致。systemd 必须报告正确 FragmentPath、loaded、无 drop-in、无需 daemon reload；健康还要求 active/running、正整数 MainPID、`/proc/<pid>/exe` 对应受管 Xray，以及所查地址族、地址、端口的 TCP listener 全部归属该 MainPID。检查后再次确认 PID/active，减少中途进程变化造成的误判。

`status/info` 不输出 UUID、private key、public key、shortId 或链接。`link` 标准输出仅一行当前 URL，没有 installer 的说明输出；该 URL 是用户显式请求的连接凭据。解析和配置测试错误仅报告失败类型，不输出原始 JSON、密钥、命令内容或 Xray stderr。

CLI 没有新增 persistent log writer：自身诊断写 stderr，restart 的原始配置测试/systemctl 错误被丢弃。测试中捕获的 stdout/stderr 和 `systemctl.calls` 是 fixture 证据，不是产品日志。现有 installer 的受保护临时诊断和配置备份仍属于 M1 行为，不能概括为“系统上所有日志绝不会有 credential”。`node_link` 复用的 `uri_encode` 仍将客户端公钥通过 `jq --arg` 传递，存在进程 argv 的继承边界；私钥推导只使用内存和 stdin，CLI link 不主动写链接文件。

`restart` 先由 `runuser -u nodeforge` 以 service 用户测试正式配置（20 秒上限）；失败不发出 restart。重启调用上限 30 秒。健康检查最多尝试 10 次，并设 15 秒重试窗口，每个 systemd/ss 调用上限 3 秒；已开始的一次检查可能越过重试窗口。失败不改配置、不升级、不重装；systemd job 超时后可能仍继续，CLI 不据此宣称成功。

## 锁与路径边界

`status/info/link` 使用 `/run/lock/nodeforge.lock` 的非阻塞共享锁；install/restart/uninstall 使用非阻塞排他锁。installer 的锁已前移至依赖安装之前。重复打开不截断锁文件；拒绝符号链接、非普通文件、非 root 所有或可被组/其他人写入的既有锁。锁文件保留，不因卸载删除，避免 inode 竞争。

沿用 M1 路径检查；runtime 额外检查安装目录、固定入口及清单内文件的类型、root 所有权和写权限。state 数据不决定 shell target 或删除路径；service 名和路径来自固定 defaults，运行参数以独立且引用的参数传递，无 eval。

模块加载发生在取得操作锁之前，help/version 不加锁；与卸载并发的新调用可能因 runtime 已删除而失败，不能宣称完全无 race。该锁约束协作的 NodeForge 操作，不约束外部写 config 的进程。真实内核 flock/FD 生命周期仍需 Linux 验证。本轮 staging、publish、rollback 均留在既有 installer/uninstall 的排他锁调用链内。

## Installer、runtime 与卸载

本地 installer 创建：

- `/usr/local/bin/nodeforge`：0755，root 所有的小型 Bash 分派入口。
- `/usr/local/nodeforge/app/releases/<VERSION>/`：0755 目录，固定的运行模块/模板/VERSION 为 0644，root 所有。
- runtime 内 `.inventory`：固定代码文件列表及 SHA256，用于本地归属和意外变更检测；不包含节点配置或凭据，不是签名发行 manifest。

入口从 VERSION 生成并固定指向该 runtime。对 Phase 1 规划的小范围收敛：本阶段暂不建立 `app/current` 切换点；直接固定模块路径即可满足本地 CLI，无需提前引入版本切换/更新协议。没有第二份版本来源。

重复安装会验证已有 runtime/入口及源码内容相同，不重写 runtime、不产生重复版本。相同 VERSION 内容不同则在节点配置/服务变更前拒绝（本地入口仍先安装发行版依赖）；本阶段不能作为 update 使用。尚未安装 CLI 的 M1 schema-1 节点可沿用本地 installer 安装 CLI，保持已有身份/端口及 schema-1 state 表示。

runtime staging 改为 `/usr/local/nodeforge/app/releases/.pending-<VERSION>`，与 final runtime 是同一受控父目录下的 sibling。先写入受保护 pending 的 `cli-created` 记录，再创建目录/复制文件；完成文件类型、root 所有权/写权限、VERSION、固定 inventory 和源文件 SHA256 比较后，调用 Python `os.rename`。helper 要求同一 parent、相同设备以及 final 不存在；EXDEV 直接失败，不使用 GNU mv 的 copy fallback。因此程序不会通过跨文件系统复制逐步构建 final runtime。PATH 入口仍使用目标目录内临时文件加 rename。

`cli-created` 记录版本、受控 parent、stage、final、launcher 和创建意图。rollback 将其与代码生成的固定记录逐字比较，不从记录解析任意路径。`runtime_rollback_cleanup` 专门清理本次事务产物：允许 inventory/内容不完整，但仍拒绝 symlink、非预期文件类型和路径；只删除固定文件表，未知内容保留并使恢复失败。正式卸载的 `runtime_remove` 仍要求完整 inventory，不因 rollback 需求而放宽。

runtime/launcher 关键 unlink、runtime 子目录删除、snapshot/file/service 恢复均显式传播失败，不依赖条件调用中可能被抑制的 `set -e`。失败报告 `Recovery incomplete` 并保留 pending。只有全部恢复成功，才写入 `rollback-complete` 完成标记并开始逐个退役 snapshot/reference 文件；退役失败保留完成标记，下一次可只重试退役而不使用已删除的快照。pending 目录 rmdir 失败会尝试恢复该标记并返回失败；未知 pending 内容直接保留并拒绝退役。

这不是 fsync/断电持久性协议：若存储无法继续写入标记或在最后退役步骤断电，下一次可能只能 fail-closed 并要求人工检查，而不是保证自动恢复。事务 stage/final、app 容器及入口的删除都传播失败；仅 M1 在恢复完成后的空安装父目录收尾保留既有 best-effort 行为。M1 schema-1 state 无新增字段，原有备份不轮转。

卸载在停止服务之前验证 CLI 归属和完整性，然后复用既有卸载流程。只删除固定且已验证的代码文件及入口；未知 runtime/config/backup 内容保留并告警，不递归清空未知目录。卸载后继续调用共享函数可完成退出。重复卸载在 state/CLI 均不存在时成功，不认领残留未知文件。部分卸载失败仍按 M1 语义处理，不承诺卸载事务回滚。

CLI/source 卸载在 pending 场景有明确差异：`nodeforge uninstall` 拒绝 pending，要求使用可信本地源码 installer 的既有恢复路径；源码 `uninstall.sh` 仍可进入共享 rollback。CLI 不在可能删除自身模块之后继续运行 Python recovery helper。

## 自动验证

新增 Shell 套件覆盖：

- `test_cli.sh`：dispatch、root gate、schema/字段/损坏/身份不一致、status/info 隐私、M1 link 一致性、只读摘要稳定、服务缺失/错误 unit/drop-in/stale unit、无效 PID/exe/listener、配置失败拒绝重启、重启/后检失败。
- `test_cli_lock.sh`：root 所有权/写权限判断、生产锁代码重定位到 fixture，验证共享/排他参数、busy 失败、非普通锁拒绝、不截断和 installer 加锁边界。此 Windows 环境使用 fixture stat/flock，不冒充 Linux 内核权限/并发锁验收。
- `test_cli_runtime.sh`：真实安装入口的 help/version、PATH 查找、重复安装、外来入口拒绝、runtime/入口损坏拒绝卸载、通过实际安装 launcher/nodeforge.sh 在独立进程完成自删除、重复卸载及未知文件保留。自删除测试只在临时 runtime 注入系统操作 mocks 和 fixture 路径，不调用开发机 systemd。
- `test_cli_transaction.sh`：PATH 入口发布失败后的 rollback，以及 M1 状态下 CLI publication 的 pending recovery，验证原 state/config 摘要保持。
- `test_cli_security.sh`：独立捕获 stdout/stderr，扫描成功 status/info、损坏 state/config、公私钥不一致、restart 配置/core/service/listener 失败及 uninstall 失败；注入 raw secret 验证输出抑制；直接注入恶意 service/path 字段，验证 systemctl 调用清单未变且外部 sentinel 摘要不变。断言自检故意产生 sentinel，必须返回非零且不改变 capture。
- `test_runtime_recovery.sh`：复制中断、final rename 失败、记录不匹配拒绝、不完整 transaction-owned runtime 清理、严格正常卸载拒绝 partial runtime；在 OR-list 下注入 runtime unlink/rmdir、launcher unlink、snapshot/service restore、证据退役删除失败，验证非零、pending/evidence 保留及重试成功。

管理 Python 测试共 12 个：原 9 个覆盖严格 schema/类型/字段、重复 JSON key、损坏 JSON、配置结构、公私钥关系、IPv6 身份、IPv4/IPv6 wildcard 与监听 PID/地址/端口拒绝；新增 3 个验证实际 sibling rename、模拟 EXDEV 后不复制、既有 final/不同 parent 冲突拒绝。

完整测试入口仍为 `bash tests/run.sh`，包含 ShellCheck、所有 Bash 语法检查、原 12 个加 Phase 2 的 6 个 Shell 套件、原 6 个加 12 个 Python 管理测试。最终结果见本文件末尾执行记录。

## 仍需后续授权验证

本次仅 Windows + Git Bash 本地/fixture 验证。未连接 VPS，未在真实 Linux systemd 上验证安装后 PATH、所有权/权限、`/proc`、ss 输出、内核 flock 并发与重启时序；也未运行联网 Xray 集成或外部客户端测试。这些不能用 mocks 代替，需另行授权后进行 Debian 12 实机验收。

健康结果是本地时间点观察，不是持续监控或外部连通保证。运行时清单只依赖 root 受保护的本地归属记录，不提供发布者签名认证。保留 M1 已记录的多文件事务无 fsync、备份不轮转和卸载不可回滚限制。Phase 2 审核结束前不进入下一阶段，不宣称整个 M2 COMPLETE。

## 执行记录

首次实现的历史记录：2026-09-12，Windows + Git Bash，`bash tests/run.sh` 退出码 0。该结果未覆盖随后 audit 发现的 B1/B2 和无效日志断言，不能作为整改后的结论。

- ShellCheck：PASS；全部 Bash 语法检查：PASS。
- **16 个隔离 Shell 套件**全部 PASS（原有 12 个 + 新增 4 个）。
- **15 个 Python 测试**全部 PASS（原网络测试 6 个 + 管理验证测试 9 个）。
- `git diff --check`：PASS。VERSION、两个正式模板、Phase 1 的 version/state 模块均保持原样。
- `v0.1.0` 仍为 annotated tag；37 个 M1 baseline Git blobs 与 accepted 摘要清单全部一致。
- 没有运行联网 Xray 集成、Linux/VPS、外部客户端验收，没有修改开发机 systemd。

## 审核文件清单与 Git 状态

新增 13 个文件：

- `nodeforge.sh`：源码 CLI 入口，同时复制进入安装 runtime。
- `lib/cli.sh`：命令分派及操作。
- `lib/runtime.sh`：本地 CLI 安装、归属验证及删除。
- `lib/management.py`：严格状态、身份及 socket 验证。
- `tests/helpers/cli_mocks.sh`：CLI 系统操作 fixtures。
- `tests/test_cli.sh`：命令与安全测试。
- `tests/test_cli_lock.sh`：权限/锁与入口边界测试。
- `tests/test_cli_runtime.sh`：安装入口与自删除测试。
- `tests/test_cli_transaction.sh`：CLI 发布失败和中断恢复测试。
- `tests/test_management.py`：12 个管理/目录 rename 验证测试。
- `tests/test_cli_security.sh`：分通道 secret 断言、自检和恶意 state/path/service。
- `tests/test_runtime_recovery.sh`：B1/B2 故障注入和重试。
- `docs/M2_PHASE2.md`：本阶段审核记录。

修改 17 个文件：

- `install.sh`、`uninstall.sh`：锁边界和重复卸载预检。
- `lib/common.sh`、`lib/defaults.sh`：加载新模块及固定 CLI 路径。
- `lib/config.sh`：正式读取补充调用已有 schema 支持探测。
- `lib/service.sh`：新增 CLI 专用的服务/监听验证。
- `lib/share.sh`：提取共用 link 生成函数，保留 M1 输出格式。
- `lib/system.sh`：共享/排他稳定锁、锁路径权限、卸载预检模式。
- `lib/transaction.sh`：CLI 发布/rollback/recovery/卸载集成。
- `tests/helpers/setup.sh`、`tests/helpers/mocks.sh`：fixture CLI 路径和权限检查 mocks。
- `tests/helpers/assertions.sh`：不覆盖 capture 的否定断言和 stdout/stderr 分离捕获。
- `tests/fixtures/xray/xray`：使用与既有测试私钥确实配对的公开测试公钥。
- `tests/run.sh`：纳入新入口的 lint/语法检查和 Python 管理测试。
- `.gitattributes`：固定无扩展名 Xray fixture 脚本为 LF。
- `README.md`、`docs/HANDOFF.md`：CLI 使用说明和当前交接状态。

审核时 HEAD 仍为 `de754512bc3aa4d8cd96e9f80ffa745c3b73322c`；未创建 commit 或 tag。Working tree **非 clean**：上述 17 个修改文件、13 个未跟踪新增文件，均未暂存。工具和测试日志留在已忽略的本地 `.tools`，不作为发行文件。

Git 统计：30 个变更文件（包含未跟踪新增文件）；最终增删行数在交付报告中列出。常规 `git diff --stat` 仅显示已跟踪文件，新增文件应结合上述清单审核。

## Blocker remediation 最终验证与只读复核

2026-09-12，在源码与测试冻结后重新运行完整 `bash tests/run.sh`，退出码 0：18 个隔离 Shell 套件、18 个 Python 测试（网络 6 + management 12）、ShellCheck 和全部 Bash 语法检查 PASS。`git diff --check` PASS。先前运行曾因测试执行期间编辑测试文件产生读取版本漂移；该次失败不作为验证证据，以上结论来自后续冻结后的完整重跑。

本轮整改涉及 `lib/runtime.sh`、`lib/management.py`、`lib/transaction.sh`、`lib/cli.sh`、`tests/helpers/assertions.sh`、`tests/helpers/mocks.sh`、`tests/helpers/cli_mocks.sh`、`tests/test_cli.sh`、`tests/test_management.py`、README、本文及 HANDOFF，并新增 `tests/test_cli_security.sh`、`tests/test_runtime_recovery.sh`。整个 Phase 2 working tree 为 30 个文件，不再是首次 audit 时的 27 个。

完整测试后只读复核当前源码、测试和 diff，结果如下；随后仅同步报告文档，没有再改源码或测试。

| 复核问题 | 证据与结论 |
| --- | --- |
| 1. B1 是否消除 | 针对原故障机制已消除：不再从 state filesystem 使用可能退化成复制的 mv 发布 runtime。 |
| 2. staging/final 是否同 filesystem | 两者为 `app/releases` 下的固定同级目录；Python 检查 parent 和 st_dev，拒绝 symlink、已存在 final 和不同 parent。 |
| 3. final 是否通过 copy 形成 partial | 不会走 copy fallback；完整复制、权限/类型/VERSION/inventory 验证只发生在 staging，最终使用 os.rename。EXDEV 测试确认失败后不复制。该保证不是多文件事务或掉电持久化保证。 |
| 4. partial runtime 的 rollback | 创建前写入受保护的固定 intent；rollback 必须精确匹配当前 canonical intent，仅删除列举的已知文件，再用 rmdir 清理空目录。未知内容或错误保留并返回失败。 |
| 5. 正式 uninstall ownership | 仍要求完整 runtime inventory 和精确 launcher 内容；不接受 transaction partial cleanup 的宽松完整性语义。恶意 state 不决定删除目标。 |
| 6. runtime/launcher 删除错误 | 关键 rm/rmdir 和恢复操作显式传播非零；故障测试特意在 rollback 的 OR-list 调用上下文执行，避免只依赖 errexit。 |
| 7. 不完整 rollback 的 pending | 恢复失败保留 pending 和原证据；全部恢复后才写 rollback-complete 并退役证据。退役失败保留 completion marker 以重试；最终 marker/rmdir 窗口或存储故障不承诺自动恢复，可能需要人工处理。 |
| 8. secret assertion 有效性 | 新断言只读 capture，stdout/stderr 分离；自检向每个通道注入 sentinel，断言必须非零，并核对 capture SHA256 未变。正式错误路径还注入秘密输出验证抑制，没有把生产泄漏 mutation 留在代码中。 |
| 9. 恶意 state/path/service 证据 | 通过 CLI restart/uninstall 注入恶意字段，要求命令失败、systemctl 调用清单摘要不变、外部 sentinel 摘要不变；这是 fixture 端到端证据。Windows 原生 symlink 不可用时明确报告 limitation，没有冒充 Linux symlink 验证。 |
| 10. Phase 3 scope | 未新增 bootstrap、远程安装/发行下载/签名、NodeForge/Xray updater、schema 2、current symlink 或版本切换。publish/release 仅指当前源码 CLI runtime 在本机固定目录中的安装发布；既有 M1 Xray 下载路径未扩展为 updater。 |

测试冻结前后，所有非 Markdown 的受版本控制/未跟踪源码与测试文件清单及 SHA256 的聚合值一致：`302DD9F683CF9B49ABECD1327353AB40A3387FE625C9D8F9F31C661C57C4F210`。本地执行日志位于忽略的 `.tools/phase2-remediation-final.log`，不纳入发行物。

### BLOCKER

本次修复后只读复核未发现剩余 blocker。

### SHOULD FIX

本轮未发现额外必须在 Phase 2 commit 前处理的建议修复项。

### ACCEPTABLE / VPS VALIDATION

本地故障注入与回归证据可接受；真实 Debian 12 的 systemd、ss/proc ownership、文件权限、原生 symlink、内核 flock 竞争、重启/自删除时序及实际 filesystem rename 仍需后续授权验证。jq --arg/process argv 继承边界、锁前模块加载、CLI/source pending 卸载差异及无 fsync 的恢复持久化边界如本文前述，不宣称完全无 race、所有日志绝不泄漏或任何故障均自动恢复。

最终 verdict：**READY FOR COMMIT**。该结论是本地 pre-commit 审核结果，不等于 VPS 验收或整个 M2 完成。没有 commit、tag、VPS 操作或 Phase 3 实施；等待用户审核。
