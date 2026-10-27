<p align="right"><a href="README.md">English</a> · <b>简体中文</b></p>

# LoopCtrl-Server

[LoopCtrl](https://github.com/Souitou-iop/LoopCtrl) 的网络连接层：提供让操作员（Operator）从跨网络环境安全访问手机端 LoopCtrl 服务的服务端组件。本仓库包含的所有内容均可完全私有化自建部署。

LoopCtrl 在 iPhone 上运行长期驻留的 XCUITest runner，对外提供加密的 JSON-RPC API（协议 v1，默认端口 8300）。如果在同一 Wi-Fi 局域网内，操作员可直接直连；如果处于公网或跨网络环境，则需要一条通往手机的网络通路。本仓库提供两种可相互替换的方案：

| | App 内置中继 (`connect/relay/`) | Headscale 虚拟专网 (`connect/headscale/`) |
|---|---|---|
| **手机端配置** | 在 LoopCtrl 内直接扫码邀请二维码即可，零额外配置。 | 通过 Shadowrocket（或其他 Tailscale 兼容客户端）填入 pre-auth key 加入 tailnet。 |
| **服务端** | 单个 Go 二进制，置于 HTTPS 反向代理后。 | Headscale + 内置 DERP 中继，HTTPS 代理，UDP 3478 STUN。 |
| **传输机制** | 手机与中继保持一条 WebSocket，中继把完整的 HTTP 请求转发给手机。 | WireGuard；NAT 允许时点对点直连，否则经由自建 DERP 中转。 |
| **操作员连入** | 手机自己的公网地址 `https://<slug>.<中继域名>/`：浏览器打开控制页面，智能体调用 `/rpc`。 | 从具有 `tag:operator` 标签的节点直接访问 `100.64.x.y:8300`。 |
| **适用场景** | 默认首选。客户 iPhone 端无需繁琐网络配置。 | 备用方案，或适合团队自身已有 Tailnet 基础设施的场景。 |

无论采用哪种连接方式，操作员与手机之间均建立端到端配对（X25519），每次请求都使用 LoopCtrl v1 信封在端侧封装与加密。**无论是中继服务器还是 Headscale 节点，均无法解密或伪造请求内容。** 邀请链接指明了手机预先信任的操作员公钥。浏览器打开的控制页面由中继转发，所以请使用自己部署或信任的中继（[原因](https://github.com/Souitou-iop/LoopCtrl/blob/main/docs/remote-control.md#trust)）。

## 目录结构

```
connect/relay/        中继（Go）实现、测试、操作员工具、Dockerfile、
                      compose 配置、nginx 与 systemd 模板
connect/headscale/    Headscale + 内置 DERP：compose 文件、配置、ACL 策略、nginx
cli/                  `loopctrl` 操作员命令行工具（支持直连或通过中继连接）
docs/                 自建部署指南与协议架构规范
```

## 快速上手

使用 Docker 并在自己的 HTTPS 反向代理后部署中继：

```sh
cd connect/relay
cp relay.env.example relay.env && $EDITOR relay.env
install -d -m 0700 -o 65532 -g 65532 state
docker compose up -d
curl -s http://127.0.0.1:8787/healthz
```

生成邀请凭证并开始操作手机：

```sh
export LOOPCTRL_RELAY_URL=https://relay.example.com
export LOOPCTRL_RELAY_OPERATOR_TOKEN=...      # 来自 relay.env
cli/loopctrl relay enroll --name "Alex"       # 输出 loopctrl://connect 链接；可将其转为二维码展示
cli/loopctrl relay devices                    # 列出每台手机的公网地址
cli/loopctrl relay pair --device-id dev_...   # 自动通过审批：邀请中已包含你的公钥
cli/loopctrl relay call --device-id dev_... device_info
```

也可以直接用浏览器打开手机的公网地址并在页面上配对（手机上会请用户确认），即可看到实时画面，进行触控、键盘输入并查看视图树。

完整指南：

- [docs/self-host-relay.md](docs/self-host-relay.md)：中继部署（Docker 或 systemd）。
- [docs/self-host-headscale.md](docs/self-host-headscale.md)：Headscale + DERP 部署，以及手机端通过 Shadowrocket 连入。
- [docs/protocol.md](docs/protocol.md)：各组件工作流及各层通信契约定义。

## 容器镜像

发布 Release 标签后会自动构建并发布 `ghcr.io/souitou-iop/loopctrl-relay:<version>`（以及 `:latest`）。Headscale 直接使用官方上游镜像 `headscale/headscale`。

## 开发与自测

```sh
cd connect/relay && go test -race ./...   # 用模拟手机测试中继；无需真机
ruff check .                              # Python 命令行工具
```

中继需要 Go 1.23+，只依赖 `github.com/coder/websocket`。命令行工具要求 Python 3.10+，仅依赖标准库（若已安装 `cryptography` 则用它做 X25519 配对，否则回退到纯 Python 实现）。

## 许可证

Apache-2.0，与 LoopCtrl 保持一致。
