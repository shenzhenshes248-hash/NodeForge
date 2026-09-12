# Milestone 1 验收记录

## 已执行与未执行

本地环境为 Windows + Git Bash。已执行 ShellCheck、Bash 语法、fixture 安装/回滚/卸载测试以及 Python 本地 socket/参数测试。已从官方 Release 下载 Windows amd64 Xray v26.9.9 并核对官方 SHA-256，使用实际 CLI 生成 UUID/X25519 密钥并验证生成的 VLESS/RAW/REALITY/Vision 配置。

以上不能证明 Linux ELF 二进制、systemd sandbox、Linux 文件属主或外部连接正确。Linux 集成脚本与 CI 已提供，尚未在本次本地环境执行。以下实机矩阵均**待执行**：

默认 target 的官方 `xray tls ping` 本地诊断观察到 TLS 1.3 握手成功，但本地 DNS 返回了测试保留地址（代理环境），不能计为 VPS 上的公网地址、证书和 HTTP/2 完整验收；安装器会拒绝此类非公网 target 解析结果。

| 系统 | 架构 | 首次安装 / 重装 / 重启 / 卸载 | 外部客户端连接 |
| --- | --- | --- | --- |
| Debian 12 | amd64 | 待执行 | 待执行 |
| Debian 12 | arm64 | 待执行 | 待执行 |
| Ubuntu 24.04 | amd64 | 待执行 | 待执行 |
| Ubuntu 24.04 | arm64 | 待执行 | 待执行 |
| Ubuntu 22.04 | amd64 / arm64 | 待执行 | 待执行 |

## 一次性 VPS/VM 上的操作

1. 使用新建、可销毁的目标系统；记录系统版本、架构、Xray 标签。不要在含有重要业务的服务器上进行故障注入。
2. 在仓库根目录运行 `sudo bash install.sh --dry-run`，确认未创建 NodeForge 路径或服务；随后运行正式安装。
3. 检查输出包含全部连接参数及完整链接，不含私钥；分享链接不要上传 CI 日志、issue 或公开验收记录。
4. 检查 `systemctl is-enabled nodeforge-xray.service` 和 `systemctl is-active nodeforge-xray.service`；用 `ss -ltnp` 确认输出端口属于该 Xray 进程。
5. 使用 `stat` 检查配置为 0600、父目录为 0750、状态和备份父目录只有 root 可访问；确认服务 UID 不是 0。
6. 使用 `sudo -u nodeforge /usr/local/nodeforge/bin/xray run -test -config /etc/nodeforge/xray.json` 验证正式配置；不要将原始诊断输出公开。
7. 在云安全组和主机防火墙允许输出端口。从另一台机器导入链接，验证 VLESS/REALITY/Vision 握手、HTTPS 请求和出口 IP。记录客户端名称/版本及 `type=tcp`、`pbk` 的兼容性，避免记录实际凭据。
8. 记录配置和二进制 SHA-256，再次运行安装；摘要、UUID、密钥、shortId、端口不变，并产生备份；健康服务不应被重启。
9. 显式更换端口并允许新端口，重复外部测试；尝试占用端口和不可用 target，确认安装失败且旧配置、旧服务保持。
10. 重启 VPS，确认服务自启，再做一次客户端请求。
11. 在 NodeForge 目录内建立无关测试文件，运行卸载；确认服务停止/禁用、管理文件及已知备份删除、无关文件和系统依赖仍存在。

## 隔离测试的故障模型

默认测试覆盖配置校验失败、target 失败、占用端口、首次启动失败、已有安装启动失败、持久事务中断恢复和外部修改过的配置。模拟命令替代系统管理命令，真实测试只运行 JSON/CLI 检查和本地临时 socket，不启用测试机服务。

硬断电、磁盘写入中途故障及真实 systemd 权限错误需要额外的一次性 VM 验收。持久日志帮助恢复已就绪的事务，但当前没有 fsync 协议，不能保证断电时每次写入已落盘。若 `pending/` 不完整，保留目录并停止，检查备份后人工恢复。
