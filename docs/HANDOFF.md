# NodeForge 交接快照

**M1 COMPLETE；M2 COMPLETE。正式版本 v0.3.0，VERSION 为唯一版本来源。**

M2 Phase 1 版本/state 基础、Phase 2 本地 CLI（含 dual-stack 修复）、Phase 3 Signed Release Bundle、Phase 4 One-line Bootstrap、Phase 5 NodeForge Self-Update、Xray Independent Update 均 COMPLETE。本轮仅版本及文档收尾，不进入 M3。

官方仓库：https://github.com/shenzhenshes248-hash/NodeForge；主分支 master；正式 annotated tag：v0.3.0。Release assets：manifest.json、manifest.sig、nodeforge-v0.3.0.tar.gz。固定 Ed25519 公钥位于 trust/release-ed25519.pub，私钥保存在仓库之外，不提交或打包。

协议仍为 VLESS + TCP/RAW + REALITY + XTLS Vision。state 仅支持 schema 1，无 schema 2 迁移。NodeForge update 只更新 runtime/CLI；Xray update 从官方 Releases（含 pre-release）按数字 CalVer 选择较新版本，不改变节点配置和凭据。

## 验证记录与边界

- Debian 12 amd64：CLI、dual-stack listener/PID、一行 bootstrap、外部 v2rayN HTTPS 已验收。
- NodeForge Self-Update：v0.2.1-dev → v0.2.2-dev、link 不变及重复无需更新已验收。
- Xray Independent Update：用户已验收；实机 v26.9.9 被正确识别为最新版本，正常退出且 status healthy。未人为降级；真实新版替换及故障回滚由本地 fixture 覆盖，未实机执行。
- Ubuntu/arm64 尚未实机验证；不宣称断电、强制终止或真实故障回滚已验证。
- 已知旧 runtime 的 pycache 未知文件可能保留并产生清理警告，本轮未处理。
- 完整回归入口为 bash tests/run.sh（Shell、Python、ShellCheck、Bash syntax），另运行 git diff --check。

各阶段记录见 M2_PHASE1.md 至 M2_PHASE5.md、M2_XRAY_UPDATE.md。历史阶段中的范围限制不代表当前缺少后续已完成能力。

## 关键基线

- M1：6a6edad262c0909900e31e3a6a65853a9b1316ef，tag v0.1.0。
- Phase 2：0ff8dcfd1f67614eeed4f588521438696ee5ce4d；dual-stack：e22e9016801e3931e53dbd83019929625ca2fa88。
- Phase 3：69457873abe53f013f57a6eee13ea437b8cf489f。
- Phase 4：8259383b97f241de0485906145ee8c663c6755e9。
- Phase 5：560e1cb4b97f19f82a9490a563a427c5ea1203ad。
- v0.2.2-dev：69d5d5e632c711dfdc7954c475b5fa0d394292c0。
- Xray update：ad4b6c413b164d4d7a4f5ede39aca1d1f8a4f390。
- v0.2.3-dev：518007bb95b515ec22b0e3e6329a097212a8d009。
- Xray pre-release fix：1b2975e82d80bbcd18dcb8b142ade5bfcad4ed09。

后续等待用户指令，不自动进入 M3。.tools 为忽略的本地工具/证据，不进入仓库或 bundle。
