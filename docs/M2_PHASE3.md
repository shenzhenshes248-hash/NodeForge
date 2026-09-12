# M2 Phase 3 — Local Release Bundle + Signed Manifest

本阶段只提供 `tools/release.py` 的本地 build / sign / verify。依赖 Python 3.9+、Bash 和支持 Ed25519 的 OpenSSL（验证环境使用 OpenSSL 3）。不连接网络，不安装、提取或执行 bundle，不增加 bootstrap/update、state schema 2 或版本切换。

## 格式与用法

输出目录必须不存在，包含 `nodeforge-<VERSION>.tar.gz`、`manifest.json`，签名后增加 `manifest.sig`（64 字节 detached Ed25519 签名）。归档内为单一 `nodeforge-<VERSION>/` 根目录；复用 `runtime_files` 清单，附带 install/uninstall、LICENSE、README、release 工具和本文。没有 Xray 二进制、节点配置、测试、`.tools`、Git 元数据或签名私钥。它是完整的 NodeForge 源码发行包，不是含系统依赖/Xray 的离线安装包。

`VERSION` 通过已有 `load_nodeforge_version` 读取，没有版本参数或另一份版本常量。manifest 示例（SHA256 按实际产物填写）：

```json
{
  "schema": 1,
  "version": "v0.2.0-dev",
  "artifact": "nodeforge-v0.2.0-dev.tar.gz",
  "sha256": "<64 lowercase hex characters>"
}
```

这里的 schema 是 release manifest 格式，与 NodeForge state schema 无关。

```bash
python3 tools/release.py build --output-dir /tmp/nodeforge-release
python3 tools/release.py sign --manifest /tmp/nodeforge-release/manifest.json \
  --private-key /secure/outside-repository/release-ed25519.key \
  --signature /tmp/nodeforge-release/manifest.sig
python3 tools/release.py verify --artifact /tmp/nodeforge-release/nodeforge-v0.2.0-dev.tar.gz \
  --manifest /tmp/nodeforge-release/manifest.json --signature /tmp/nodeforge-release/manifest.sig
```

私钥必须在仓库及产物目录之外，工具拒绝这些目录内的签名私钥；打包采用固定文件清单而非扫描目录。签名支持外部未加密 PEM Ed25519 key；私钥不通过 argv 内容、输出或 bundle 传递。

正式 trust anchor 为仓库中的 `trust/release-ed25519.pub`（PEM Ed25519 公钥），随现有格式的源码 bundle 一起打包。生产 `verify()` 和 CLI 固定使用可信 verifier 所在源码目录下的该文件，不接受 `--public-key`、环境变量或 manifest 指定的公钥，也不读取待验证归档中的公钥。必须使用已可信的 verifier/公钥副本验证产物，不能先执行未验证 bundle 内的 verifier 来建立信任。测试公钥仅可通过内部 `_verify_with_key` 注入，CLI 不暴露此接口。

对应正式私钥保存在本机仓库外 `C:\Users\Brown\.nodeforge-signing\release-ed25519.key`，目录访问权限限制为当前用户；不提交、不打包。测试仍在仓库外生成临时密钥并在结束后删除。此前示例公钥不再被生产路径接受。

验证顺序：检查 Ed25519 公钥 → 验证 manifest 原始字节签名 → 严格 JSON（拒绝重复字段、未知字段、错误类型/格式/schema）→ 文件名与 SHA256 → 只读检查归档成员及内置 VERSION。manifest/signature 不嵌入归档。任何失败均非零退出，不输出成功标记，不提取、不执行、不改变安装状态。

本地发行文件在验证期间必须保持不变；工具不是并发发布或部署事务。后续 bootstrap/self-update 不在本阶段实现。

## 测试

`tests/test_release.py` 覆盖实际打包、Ed25519 签名/验证、三类文件篡改、错误公钥、严格 manifest、内置 VERSION 一致性、私钥位置拒绝和 bundle 清单；固定信任根测试通过隔离替换 anchor 验证正确签名成功、另一把私钥签名失败，附带其公钥参数也不能绕过生产 CLI。正式私钥不作为自动测试依赖。`bash tests/run.sh` 纳入该测试并保留完整既有回归。
