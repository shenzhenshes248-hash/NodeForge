# M4 Phase 1：Argo Quick Tunnel

开发版本 `v0.4.0-dev`，正式基线仍为 `v0.3.0` / `0308f3200918f2e2b5cdac1aa24ce76751070dfd`。本阶段没有 Release/tag、订阅或固定 Tunnel。

## 结构

- `nodeforge-argo-xray.service`：独立 Xray 副本、UUID、配置和本地端口，VLESS + WS，仅监听 `127.0.0.1`。不改写 Reality/HY2 配置，不监听公网 80/443。
- `nodeforge-argo.service`：Python 小型进程包装器启动官方 cloudflared Quick Tunnel；显式空配置绕过已有 Cloudflare 账号/隧道配置，禁用 cloudflared 自更新。两个 Argo 服务默认 enable，异常或退出后自动重启。
- `/usr/local/nodeforge/argo/`：`xray`、`xray.json`、`cloudflared`、`cloudflared.yml`、`runner.py`、`state.json`。`state.json` 记录 cloudflared 版本及管理文件校验和，不记录域名。
- cloudflared 从 `cloudflare/cloudflared` 官方最新稳定 Release 下载 amd64/arm64 文件，对照官方 GitHub API asset SHA-256 后执行版本检查。重跑安装保留已有二进制和身份。
- 包装器只读取本次 cloudflared 输出中的 `https://*.trycloudflare.com`，等连接注册后原子写入 `/run/nodeforge-argo/current.json`，内容包含域名与 systemd `InvocationID`。启动、退出或新域名出现时清除旧值；systemd 停止服务时删除运行时目录。
- `nodeforge link` 保留前两条链接，域名可用且对应当前服务实例时追加 `vless://UUID@域名:443?encryption=none&type=ws&security=tls&sni=域名&host=域名&path=%2Fnodeforge-argo#NodeForge-Argo`。未就绪时仅向 stderr 提示，不输出旧 Argo 链接。
- `status/info` 单独报告 Argo；其未就绪不改变原有 Reality/HY2 健康判断。`restart` 同时处理已安装 Argo，`uninstall` 删除 Argo 管理文件和服务。Reality 的 `xray-update` 不替换 Argo 的独立副本。

## VPS 人工验收

将本次源码放到 VPS 的 `/root/NodeForge`（或替换为实际目录）。已安装 v0.3.0 使用 `--argo`；全新 VPS 使用 `sudo bash install.sh`，默认安装三个节点。不要在已有 v0.3.0 上执行全新安装入口。

```bash
cd /root/NodeForge
sudo sha256sum /etc/nodeforge/xray.json /etc/nodeforge/hysteria.yaml \
  /var/lib/nodeforge/state.json /var/lib/nodeforge/hysteria.json \
  | sudo tee /tmp/nodeforge-before-argo.sha256
sudo bash install.sh --argo
sudo sha256sum -c /tmp/nodeforge-before-argo.sha256
sudo nodeforge version
sudo systemctl is-enabled nodeforge-argo-xray nodeforge-argo
sudo systemctl status nodeforge-argo-xray nodeforge-argo --no-pager
sudo /usr/local/nodeforge/argo/xray run -test \
  -config /usr/local/nodeforge/argo/xray.json
sudo ss -lntup
sudo nodeforge status
sudo nodeforge link
```

确认 Argo 端口只出现在 `127.0.0.1`，原 Reality TCP/HY2 UDP 监听不变。连接可能需要稍等，查看日志：

```bash
sudo journalctl -u nodeforge-argo -n 50 --no-pager
sudo cat /run/nodeforge-argo/current.json
sudo systemctl show nodeforge-argo -p InvocationID
sudo systemctl restart nodeforge-argo
# 等待日志再次出现 Registered tunnel connection，再检查：
sudo cat /run/nodeforge-argo/current.json
sudo nodeforge link
```

重新建立 Quick Tunnel 后，以新输出为准重新导入客户端。停止 Argo 后前两个节点仍应可用：

```bash
sudo systemctl stop nodeforge-argo nodeforge-argo-xray
sudo nodeforge link
sudo systemctl is-active nodeforge-xray nodeforge-hysteria
sudo systemctl start nodeforge-argo-xray nodeforge-argo
```

将 Argo 链接导入支持 VLESS WS+TLS 的客户端，确认目标端口为 443、TLS 开启且证书验证正常，测试外部 HTTPS 访问，再分别测试 Reality/HY2。最后在适合重启的时间执行 `sudo reboot`，重新运行 status/link，验证开机启动和域名更新。

本地 v0.3.0 → dev 加装会保留旧 CLI runtime，失败时恢复旧 launcher；不会创建远端发布。Quick Tunnel 外网连通与 Linux systemd 开机行为需要上述 VPS 实测，不能由本地 mock 测试代替。
