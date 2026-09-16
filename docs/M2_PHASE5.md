# M2 Phase 5 — NodeForge Self-Update

**状态：COMPLETE；M2 正式版本 v0.2.0。以下为本阶段范围记录；当前总览见 [HANDOFF.md](HANDOFF.md)。**

新增 root 命令 `nodeforge update`，全程使用既有排他锁。仅更新 NodeForge runtime/CLI，不调用 install.sh、不修改 Xray binary/config/unit/state/credentials，也不重启 Xray。

流程：验证当前安装 → 从当前受管 runtime 的公钥建立 `/etc/nodeforge/trust/release-ed25519.pub`（已存在则只核对，更新不替换）→ 查询固定 GitHub repository Releases API 并分页选择较新版本 → 下载该 tag 的三个 Phase 3 assets → 使用当前安装的 verifier 和独立固定公钥验签、校验 SHA256、解压 → 用旧 runtime 引擎的文件清单、staging、rename 和原子 launcher 发布逻辑更新。

版本顺序为数字 major/minor/patch，同一数字版本正式版高于 `-dev`。稳定版本不跟随 prerelease；开发版本允许开发发布。不支持的 tag 和 draft 不参与选择。已是当前版本或远端只有更旧版本时提示无需更新并返回 0。Release API/download URL 固定为 `shenzhenshes248-hash/NodeForge`，不使用 API 返回的任意下载地址。API/下载/验签失败返回非零。

新 runtime 必须保留同一公钥。新 runtime 在切换前执行现有 CLI status 函数；切换后执行实际 launcher 的 version 以及新 runtime 的同一 status 函数。status 在父进程持有排他锁时执行，不二次申请锁。旧代码完成更新与 rollback，不委托新 installer 操作系统。

失败时恢复旧 launcher，复用 transaction-owned runtime 清理，旧 runtime 保留可用；成功且通过后检后仅清理旧 inventory 中的文件，未知文件保留。没有多版本选择/管理命令。恢复或清理遇到存储错误会明确失败并保留证据；SIGKILL/掉电不能保证执行 trap，保留的 stage/旧 runtime 不自动删除，目标冲突时拒绝继续，未实现新的崩溃恢复系统。

本地测试使用模拟 GitHub 下载及临时 Ed25519 密钥验证发现/验签；Shell fixtures 验证 no-op、复制/发布/入口切换/前后健康检查失败回退、成功后版本和 Xray 文件摘要不变。真实 GitHub/VPS 自更新已验收。

已发布的 Phase 4 `v0.2.0-dev` 不含 update 命令或 verifier runtime 资源，不能追溯获得此功能。含此功能的正式发行版本为 v0.2.0。
