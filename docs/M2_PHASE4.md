# M2 Phase 4 — One-line Bootstrap Installer

**状态：COMPLETE；M2 正式版本 v0.2.0。以下为本阶段范围记录；当前总览见 [HANDOFF.md](HANDOFF.md)。**

仅实现 Debian 12 amd64 的 bootstrap，不新增安装器、更新或版本切换。正式入口：

```bash
curl -fsSL https://raw.githubusercontent.com/shenzhenshes248-hash/NodeForge/master/bootstrap.sh | sudo bash
```

外层命令需要 curl/sudo 可用。bootstrap 检查 root 和 Debian 12 amd64，必要时安装 ca-certificates、curl、python3、openssl。它在 root 私有临时目录中下载以下固定版本资产：

```text
https://github.com/shenzhenshes248-hash/NodeForge/releases/download/<VERSION>/manifest.json
https://github.com/shenzhenshes248-hash/NodeForge/releases/download/<VERSION>/manifest.sig
https://github.com/shenzhenshes248-hash/NodeForge/releases/download/<VERSION>/nodeforge-<VERSION>.tar.gz
```

当前 VERSION 为 `v0.2.0`；不使用 latest 或从 manifest 选择 URL。bootstrap 内嵌 Phase 3 verifier 与固定公钥；先验 manifest 原始字节签名，再验 bundle 文件名、SHA256、归档路径/成员类型和 VERSION。安全解压只写普通文件，不应用归档 ownership/modes；确认现有 bundle 清单完整后才调用其中的 `install.sh`。下载/验证/解压失败不调用 installer，成功或失败均清理临时目录。已进入 installer 后的行为仍由既有安装事务负责。SIGKILL/掉电无法运行 shell 清理 trap。

`bootstrap.sh` 由 `python3 tools/build_bootstrap.py` 从 `tools/bootstrap.sh.in`、已有 VERSION loader/runtime 清单、`tools/release.py` 和固定公钥生成。验签逻辑只维护 Phase 3 那一份；测试检查生成入口与来源一致。改动这些来源后须重新生成。首次 bootstrap 自身的信任仍依赖用户认可的 GitHub HTTPS 来源；签名不认证尚未取得的 bootstrap 本身。

本地测试用模拟下载、临时测试公钥和仅写标记的 fixture installer，验证成功、安装器失败、三个下载失败、三类篡改、已签名的越界/链接/缺项 bundle 拒绝及临时目录清理，不连接 GitHub/VPS。已完成正式发布及 Debian 12 amd64 一行安装、外部 v2rayN HTTPS 验收。
