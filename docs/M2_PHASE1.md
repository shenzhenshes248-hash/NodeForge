# M2 Phase 1：版本与兼容边界

**状态：COMPLETE；M2 正式版本 v0.2.0。以下为本阶段范围记录；当前总览见 [HANDOFF.md](HANDOFF.md)。**

## 本阶段实现

`VERSION` 是 NodeForge 源码版本的单一来源，当前 `v0.2.0-dev`。模块读取为 `NF_NODEFORGE_VERSION`；Xray 默认标签单独为 `NF_DEFAULT_XRAY_VERSION`，选择/已安装版本使用 `NF_XRAY_VERSION`。`NODEFORGE_XRAY_VERSION` 对外覆盖变量保持不变。

`lib/state.sh` 提供 schema-1 原有归属检查，以及只读的 schema 支持探测。探测成功只表示 schema 可识别，不等于文件摘要、身份或归属验证完成；正式读取仍走 `load_existing` 原有完整检查。未知 schema 和 schema 2 均拒绝。没有 schema-2 writer、转换函数、自动迁移或隐藏启用开关。

正式 state 仍为 schema 1，`.version` 仍表示 Xray。NodeForge 源码版本不会写入 M1 state；相同安装产生相同 state 字节。版本文件缺失/格式错误会拒绝加载不完整源码。安装路径、配置模板、服务模板、身份、端口、备份及事务行为保持 M1 设计。

## 已批准、尚未实施的 M2 强制约束

- Trust anchor 与 versioned runtime 分离：bootstrap 内置固定公钥；安装后的公钥拟放 `/etc/nodeforge/trust/release-ed25519.pub`，root 所有且只读给普通用户，不能通过 `app/current` 间接读取。update 不替换此公钥；M2 不提供 rotation。该目录本阶段不创建。
- 先对 manifest 原始字节验证 Ed25519，再用签名内 SHA256 校验 archive。严格 JSON verifier 拒绝 duplicate keys、错误类型、不兼容 schema。归档如带 manifest/sig，必须与外部已验证副本逐字节一致。
- 所有系统变更操作共用稳定 `/run/lock/nodeforge.lock`；未来 install/update/restart/uninstall 全程互斥。只读 CLI 在同一锁上取共享锁，commit 期间等待或明确报告 busy，不读混合状态。本阶段不新增 CLI，也不调整 M1 锁的覆盖范围。
- Schema 2 只记录 NodeForge/Xray 版本、归属、完整性及时间元数据，不新增私钥字段或副本。私钥继续位于受保护配置（事务配置备份按安全设计保留），不复制到 state。未来 link 在锁内核验正式 config/state 摘要及身份一致性，公钥与配置私钥推导关系也须验证；不一致 fail-closed。
- M1 → M2 迁移必须是显式受控事务，备份原 schema-1 字节、验证摘要，不重生成身份、不更换端口；失败恢复原 state。本阶段禁止启用迁移。
- Runtime/Xray/备份保留有界：current + previous known-good，进行中的唯一 pending 另计；健康确认前禁止回收旧 working version。只清理由 manifest/state 确认归属的旧文件，未知文件保留并报错/告警。M1 现有备份暂不轮转，不能把未来 retention 描述为已实现。
- NodeForge 自身更新与 Xray 更新为不同事务；完整性验证、staging、config test、commit、健康检查、失败恢复和中断恢复均必须覆盖；默认不改变节点身份和端口。

## 测试与后续实机门

Phase 1 运行原 M1 全套隔离测试，增加版本独立性、VERSION 缺失/格式错误、schema-1 字节稳定、schema-2/未知格式拒绝且不迁移测试。测试不操作开发机 systemd，不连接 VPS。

M2 尚未实现 CLI、bootstrap、update、签名发行、retention 或 migration。后续实机 Completion Gate 必须分别包含：M1 → M2 migration、NodeForge self-update、Xray update、post-commit failure rollback、interrupted/pending recovery、reboot persistence、最终外部 v2rayN smoke test。M1 pre-commit fail-closed 不能代替 post-commit rollback。所有自动测试/ShellCheck 及 M1 行为回归也须通过；不能以实现支持范围代替实机覆盖记录。

本阶段到此停止，审核通过后才开始下一阶段。

## Phase 1 执行结果

2026-09-11，本机 Windows + Git Bash：`bash tests/run.sh` 退出码 0；ShellCheck、Bash 语法、12 个隔离 Shell 套件（原 10 个加版本/state 2 个）以及 6 个 Python 测试全部 PASS。本阶段未重新执行联网 Xray 集成测试或 Linux 实机验收，未连接/修改 VPS。
