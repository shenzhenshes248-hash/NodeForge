# NodeForge

NodeForge 是一个模块化的代理节点**安装与配置工具**。它不实现 VLESS、REALITY 或 XTLS Vision 协议；协议和流量处理由未经修改的官方 [XTLS/Xray-core](https://github.com/XTLS/Xray-core) 实现。

当前源码支持 **VLESS + TCP/RAW + REALITY + XTLS Vision**、HY2，以及独立的 **Argo Quick Tunnel VLESS + XHTTP + TLS**。首次安装自动生成节点凭据和所需本地端口。没有使用 ArgoSBX、3x-ui 或其他第三方一键脚本的实现。

**当前正式版本 `v0.4.1`；M5 源码开发版本 `v0.5.0-dev`（未发布）。** 现有 Argo 原地改为 XHTTP packet-up；从 v0.4.1 更新源码后执行 `sudo bash install.sh --argo`，保留 Argo UUID/端口/path 和订阅 URL，Reality/HY2 不变。 已加入 Argo Quick Tunnel、稳定 token 路径的三节点聚合订阅，以及可选 Argo edge address。M4 完整回归记录见 [docs/M4_ACCEPTANCE.md](docs/M4_ACCEPTANCE.md)。Argo 结构见 [docs/M4_PHASE1.md](docs/M4_PHASE1.md)；已有 v0.3.0 使用 `sudo bash install.sh --argo` 本地加装。历史交接见 [docs/HANDOFF.md](docs/HANDOFF.md)。

## 平台

| 项目 | 支持范围 |
| --- | --- |
| 系统 | Debian 12+、Ubuntu 22.04+，需运行 systemd |
| CPU | x86_64 / amd64；aarch64 / arm64 |
| 核心版本 | 默认固定 `v26.9.9`，不自动跟随 latest |
| 已完成实机验收 | Debian 12 amd64；其他系统/架构待验收 |

不支持的系统或架构在安装依赖、创建用户和写入系统文件之前停止。Windows/macOS 可以编辑源码；不能安装服务。新发行版能通过版本检查不代表已经完成实机兼容验收。

## 安装

Debian 12 amd64 官方一行安装：

```bash
curl -fsSL https://raw.githubusercontent.com/shenzhenshes248-hash/NodeForge/master/bootstrap.sh | sudo bash
```

也可获取并审阅本仓库的可信副本，在仓库根目录运行：

```bash
sudo bash install.sh --dry-run
sudo bash install.sh
```

`--dry-run` 仅做只读的平台、权限和路径预检，不下载、不安装依赖、不生成节点、不修改 systemd；不代表网络或目标站点已通过验证。不要使用 `curl ... | bash` 执行未经审阅的远程脚本。

安装流程：预检 → 安装发行版依赖 → 加锁 → 官方 Release 下载与 SHA-256 验证 → 参数生成 → JSON 和核心配置检查 → 目标 TLS 验证 → 事务备份 → 原子替换文件 → 以服务用户再次检查正式配置 → systemd 自启及监听检查 → 输出连接信息。

运行依赖为 Bash、GNU coreutils、systemd 及发行版提供的 `ca-certificates curl unzip jq openssl iproute2 python3 util-linux`。Python 仅用于标准库 IP/DNS/端口验证，不安装 pip 包。系统依赖来自 apt 的签名仓库，不使用远程 shell 安装器。

默认优先使用 TCP **443**；仅当 443 已被占用时，才从 **20000–50000** 使用安全随机源选择其他可用端口。端口选择会检查 IPv4/IPv6 TCP 绑定。完成后输出 Server IP、Port、UUID、Reality Public Key、Short ID、SNI、Flow 和完整分享链接，**不输出私钥**。

VPS 的云安全组和主机防火墙需要允许输出的 TCP 端口。NodeForge 不自动修改任何防火墙，也无法打开云平台安全组。安装成功表示本机服务检查通过；请用外部客户端完成连接验收。

## 参数覆盖

安装后的常用管理操作见下文「本地管理命令」。这里的环境变量仅用于现有本地 installer，不是 CLI 的参数覆盖接口。

明确设置的环境变量优先于已有配置；没有覆盖时沿用已有身份；仅首次安装使用默认值或随机生成。

```bash
sudo env \
  NODEFORGE_REALITY_TARGET=your-target.example:443 \
  NODEFORGE_SERVER_NAME=your-target.example \
  NODEFORGE_SERVER_IP=你的公网IP \
  NODEFORGE_PORT=23456 \
  bash install.sh
```

示例中的目标域名和 IP 是占位符，必须替换为实际值。

| 变量 | 说明 |
| --- | --- |
| `NODEFORGE_REALITY_TARGET` | `host:port` 或 `[IPv6]:port` |
| `NODEFORGE_SERVER_NAME` | 明确的 DNS SNI，不支持通配符 |
| `NODEFORGE_SERVER_IP` | 可路由公网 IPv4/IPv6 字面值；NAT 环境建议明确提供 |
| `NODEFORGE_PORT` | TCP 443 或非特权端口 1024–65535；默认优先 443，已占用时随机选择 20000–50000 |
| `NODEFORGE_UUID` | 标准 UUID 格式 |
| `NODEFORGE_SHORT_ID` | 16 位小写十六进制字符 |
| `NODEFORGE_XRAY_VERSION` | 明确的官方 `v数字.数字.数字` Release；新版本需先跑集成测试 |

空值按未设置处理。第一版不提供密钥轮换、私钥环境变量输入或安装路径覆盖；模块边界保留了以后扩展的空间。固定版本之外如果资产、checksum 或 CLI 格式不兼容，安装失败，不静默降级。

首次安装未提供公网 IP 时，通过 HTTPS 请求 `api.ipify.org`，校验其为公网 IP 字面值。这是第三方 IP 查询服务，会看到 VPS 的源地址；它的返回值不作为 shell 执行。探测失败时必须明确指定 IP。后续安装默认保留已记录的地址，地址变化时使用环境变量更新。IPv6 地址在分享链接中自动加方括号；监听地址随公布地址选择 IPv4 或 IPv6。

## REALITY target

首次安装的文档化候选默认值为 `www.microsoft.com:443`，SNI 为 `www.microsoft.com`。它只存在于 `lib/defaults.sh`，配置模板没有绑定任何网站。这个默认值不是永久可用保证，也不是对任意网络的最优推荐。

显式设置域名 target 而不指定 SNI 时，默认采用 target 的域名；IP target 必须同时指定 SNI。`validate_reality_target()` 校验格式、所有解析地址的公网属性、TLS 1.3、证书链、证书主机名和 HTTP/2 ALPN。目标不合格就停止，不自动改用其他站点。不接受内网/回环 target。

验证发生在首次安装或配置变化时；完全相同的重复安装不依赖第三方 target 暂时可达。DNS 和目标站点之后仍可能变化，安装时检测不能保证永久可用，也不能防止未来 DNS 变化。第一版不做自动选站、持续探测或额外协议。

## 文件和服务

| 路径 | 内容 / 权限 |
| --- | --- |
| `/usr/local/nodeforge/bin/xray` | 校验后的官方核心，root 所有，0755 |
| `/usr/local/nodeforge/LICENSE.xray` | 原样保留的上游许可证，0644 |
| `/etc/nodeforge/` | root:nodeforge，0750 |
| `/etc/nodeforge/xray.json` | 含私钥，nodeforge:nodeforge，0600 |
| `/var/lib/nodeforge/state.json` | 归属、版本、文件摘要和客户端公钥，root，0600 |
| `/var/lib/nodeforge/backups/` | 受保护的事务备份，父目录 root，0700 |
| `/var/lib/nodeforge/pending/` | 未完成事务的持久恢复记录 |
| `/etc/systemd/system/nodeforge-xray.service` | systemd unit，root，0644 |
| `/run/lock/nodeforge.lock` | 操作互斥锁；保留空锁文件避免并发锁 inode 竞争 |

服务以不可登录的 `nodeforge` 系统用户运行，使用正式绝对配置路径、`Restart=on-failure`、`RestartSec=5s`，开机自启。服务文件系统只读，仅授予绑定 TCP 443 所需的 `CAP_NET_BIND_SERVICE`，不访问 home，并使用 `NoNewPrivileges`。

核心 stdout/stderr 默认丢弃，防止运行错误把配置凭据写入 journal；可以通过 `systemctl status nodeforge-xray.service` 查看 systemd 生命周期和退出状态。安装器的 `INFO/WARN/ERROR` 输出与原始核心输出分离。配置错误只报告失败类型，不自动打印包含敏感值的原始错误。

不在 `/root` 保存运行参数。私钥仅持久存在于受保护的正式配置及其备份中，临时文件由 `mktemp` 创建并由 trap 清理。分享链接和 REALITY Public Key 同样应当作为连接凭据保护。

## 幂等和恢复

- 原参数重复安装保持 UUID、私钥、公钥、shortId、端口和配置内容，不升级核心，不重启健康服务；仍创建受保护备份，并确保自启与启动状态。
- 覆盖参数时先测试候选配置，再备份已有配置、二进制、许可证、unit 和状态；随后通过同文件系统重命名替换各文件。
- 替换或启动失败时恢复文件、enabled/active 状态；首次失败尽量删除已创建资源。
- 未结束事务保留在 `pending/`；下次执行先恢复。多文件事务不是数据库级原子操作，不承诺断电持久性；不完整快照或恢复失败会停止并保留资料。
- 系统依赖不回滚，避免影响其他应用。备份不自动轮转，需留意磁盘空间。
- 对符号链接、未知既有目录、同名用户/组及外部修改过的正式文件拒绝覆盖；不要手工修改受管理的配置/unit 后期待安装器覆盖它。发现摘要不一致时，应先检查变更并从自己的已知备份恢复，不能直接修改状态中的摘要绕过检查。

## 卸载

安装完成后也可以使用 `sudo nodeforge uninstall`；它复用下述卸载流程，并移除 CLI 入口及已验证归属的运行时文件。

从本仓库运行：

```bash
sudo bash uninstall.sh
```

卸载根据安装记录停止、禁用服务，删除 NodeForge 管理的文件及可识别备份，然后移除空目录。未知文件、未知备份内容、系统软件和无关数据保留。发现正式文件被外部修改会停止，避免误删。

仅当服务账户由 NodeForge 创建且检查未发现残余拥有文件时尝试删除账户；从不使用 `userdel -r`，不删除用户数据。无法证明账户闲置时保留并告警；再次安装前需要人工检查这个同名账户。卸载操作本身不是可回滚事务。

## 本地管理命令

本地 `install.sh` 同时安装 `/usr/local/bin/nodeforge`，无需进入源码目录。NodeForge 版本继续从安装运行时的 `VERSION` 读取，当前为 `v0.3.0`。

| 命令 | 权限 | 实际行为 |
| --- | --- | --- |
| `nodeforge`、`nodeforge help`、`nodeforge --help` | 普通用户 | 显示帮助，退出码 0 |
| `nodeforge version` | 普通用户 | 显示 NodeForge 版本 |
| `sudo nodeforge status` | root | 验证 schema、文件摘要、节点身份、受管 service 与 MainPID 所属 TCP listener；健康为 0，否则非 0 |
| `sudo nodeforge info` | root | 显示版本、固定协议、监听地址/端口、受管路径和服务健康情况；不显示节点凭据 |
| `sudo nodeforge link` | root | 仅向标准输出写一条当前有效的 VLESS 分享链接；不检查外部客户端连通性 |
| `sudo nodeforge restart` | root | 先校验安装和正式配置，再重启固定的受管 service，并限时验证服务与监听恢复 |
| `sudo nodeforge update` | root | 签名验证后仅更新 NodeForge runtime/CLI，见 [Phase 5](docs/M2_PHASE5.md) |
| `sudo nodeforge xray-update` | root | 独立更新官方 Xray（含 pre-release），失败回滚，见 [Xray update](docs/M2_XRAY_UPDATE.md) |
| `sudo nodeforge uninstall` | root | 复用正式卸载逻辑，清理受管 CLI、Xray、配置和 state，保留未知文件 |

`status/info/link` 共用 `/run/lock/nodeforge.lock` 的共享锁；install/restart/uninstall/update/xray-update 使用该锁的排他锁。锁冲突明确返回非 0，不自动重试、提权或修复。只读命令不写配置/state、不创建凭据副本、不恢复 pending 事务；发现 pending 时请使用本地 installer 的既有恢复路径。

所有读取节点状态的 CLI 命令仅支持 schema 1，并核对配置摘要和公私钥关系；损坏、缺字段、未知 schema、身份不一致或非预期服务均拒绝。`status/info` 不输出 UUID、私钥、公钥、shortId 或分享链接；`link` 是显式的凭据输出操作。原有敏感文件权限不放宽，root 以外调用受保护命令会明确失败，不自动 sudo。

本地运行时安装于 `/usr/local/nodeforge/app/releases/<VERSION>/`，入口固定使用这一组模块；重复安装同一份源码保持入口和 runtime 不变。同版本不同内容拒绝原地覆盖，运行时更新使用 `nodeforge update`，不提供多版本切换。卸载先验证固定文件清单及摘要，再逐个删除受管文件；未知内容保留。该清单是本地归属记录，不是签名发行 manifest。

运行时先复制到 final 同一父目录下的 `.pending-<VERSION>`，校验后使用无 copy fallback 的目录 rename。事务回滚可凭精确的创建记录清理本次不完整产物；正常卸载仍要求完整 inventory。关键恢复失败会返回非零并保留 pending，恢复完成后的证据退役失败也会保留完成标记供重试。没有新增 fsync/断电持久性保证，不能保证任何故障都能自动恢复。

CLI 不新增持久日志，诊断写 stderr；`link` 不主动写链接文件，但共用的 URI 编码仍会将公钥放入 `jq --arg`，存在进程参数可见性的继承边界。模块加载发生在锁之前，与卸载并发的新调用可能失败；锁不约束外部配置写入。`nodeforge uninstall` 拒绝 pending，源码卸载入口仍可进入原有恢复流程，详见阶段记录。

退出码统一为 `0` 成功、非 `0` 失败或不健康。`restart` 的配置测试失败时不重启；重启或恢复检查失败后返回非 0，不自动修复或回滚配置。`status` 只描述检查时的本机状态，不保证未来健康或外部网络可用。

## 测试

```bash
# 开发依赖（在 Linux 开发环境中由你安装）
sudo apt-get install shellcheck jq openssl python3 curl unzip
bash tests/run.sh

# 联网下载、校验并运行真实 Xray 配置检查，不安装服务
bash tests/integration/xray.sh
```

`tests/run.sh` 必须通过 ShellCheck、`bash -n`、隔离 Shell 测试和 Python 网络验证测试。systemctl、用户操作、安装写入及网络依赖全部由 fixture/mocks 隔离；测试路径限定为临时目录，不能修改开发机 systemd。Python 测试仅做本地 socket 绑定和模拟 DNS，不访问外网。缺少测试依赖时失败，不静默跳过。

CI 配置覆盖 Ubuntu 22.04/24.04 amd64 和 Ubuntu 24.04 arm64；真实 Debian/VPS/systemd/外部客户端验收单独记录。CI 文件已提供，不意味着已在 GitHub 执行。

## 安全边界与依据

下载只指向官方 `XTLS/Xray-core` Release，使用 HTTPS、有限重试/超时以及官方 `.dgst` 的唯一 `SHA2-256` 值。校验文件缺失、格式异常、重复条目或摘要不一致均失败；不跳过验证，不运行远程 shell，不使用 `eval`，不执行压缩包中的安装脚本。

校验和保护下载完整性；校验和与资产来自同一个官方发布渠道，不是独立签名认证，无法抵御上游账户或发布流程被攻破。默认版本固定以便重现与测试。发行包内只提取指定核心和许可证，保留上游许可；不安装不需要的 geodata、其他脚本或组件。

官方参考：

- [VLESS 入站](https://xtls.github.io/config/inbounds/vless.html)：`decryption: none`、`flow: xtls-rprx-vision`。
- [RAW](https://xtls.github.io/config/transports/raw.html)：服务端使用 `network: raw`，客户端分享链接保留兼容的 `type=tcp`。
- [REALITY](https://xtls.github.io/config/transports/reality.html)：`target`、`serverNames`、`privateKey`、`shortIds`；客户端公钥当前称为 `password`，链接使用 `pbk`。
- [v26.9.9 密钥生成源码](https://github.com/XTLS/Xray-core/blob/v26.9.9/main/commands/all/curve25519.go)：解析 `PrivateKey` 与 `Password (PublicKey)`，不把 `Hash32` 当公钥。
- [v26.9.9 run CLI](https://github.com/XTLS/Xray-core/blob/v26.9.9/main/run.go)：`xray run -test -config ...`。

## 暂未实现

Hysteria2、TUIC、Shadowsocks、VMess、Cloudflare Argo、WARP、Web UI、Docker、nginx、CDN、多用户面板均不在本阶段范围。也没有自动升级、自动选站、密钥轮换和防火墙管理。

NodeForge 自身采用 [MIT](LICENSE)；Xray-core 使用自己的上游许可证，安装时原样保存，不受 NodeForge 的 MIT 许可替代。
