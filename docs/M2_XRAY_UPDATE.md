# Xray Independent Update

`nodeforge xray-update` 要求 root，全程持有现有 NodeForge 排他锁。读取并验证 schema-1 state、当前二进制版本和节点健康，然后查询官方 `XTLS/Xray-core/releases/latest`。同版本或更旧版本正常提示无需更新；不选择 prerelease 或不支持的 tag。

新版本复用 `fetch_xray`：原有 GitHub 官方 asset、`.dgst` SHA2-256 校验、指定文件解包、二进制版本检查。用现有 config 检查候选核心，通过后调用已有事务快照，原子替换 binary/LICENSE，以服务用户再次检查 config，更新现有 schema-1 的 Xray 版本/摘要，重启服务并验证 MainPID/listener 和现有 status 路径，再完成事务。

失败由现有 rollback 恢复原 binary/LICENSE/state 及原节点状态，并检查恢复后的 service/listener；恢复失败明确报错，未完成的原事务证据保留。不生成配置或凭据，不改变 NodeForge VERSION/runtime/CLI、unit 或客户端 link。快照包含既有受保护配置备份，属于原事务机制，不新增 schema。没有自动更新或多版本选择。

本地 fixture 覆盖无需更新、查询/下载/摘要/config/服务用户检查/restart/后检失败恢复，以及成功后的 runtime/config/link 不变；真实官方下载校验由已有下载测试覆盖。未操作 VPS、未提交、未发布；真实新 Xray 兼容性需后续单独验收。
