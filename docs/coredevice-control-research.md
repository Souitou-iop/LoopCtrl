# CoreDevice 控制通道调研与 Phase 0 验证（open-screen-sharing 路线）

状态：Phase 0、Phase 1 完成，全链路真机验证通过。日期 2026-11-07 / 2026-11-08。
参考项目 [nekohasekai/open-screen-sharing](https://github.com/nekohasekai/open-screen-sharing)（GPL-3.0，只作可行性参照，代码不可引入）。

## 0. 结论

1. **CoreDevice 通道在 LoopCtrl 的设备与工具链上完全可用**：同一台 iPhone 17（iOS 27.3）、同一份 idevice v0.1.68 源码，USB 连接下 display 流（HEVC 硬编 + 音频）、HID 按键、HID 触摸全部真机落地。
2. **触摸坐标是 0.0–1.0 归一化 double**，不是 0–65535。idevice v0.1.68 自带 tools 按 0–65535 传参，作者自己标注 swipe "doesn't seem to work"——根因即此。这要修（上游 PR 或我们的补丁）。
3. `com.apple.internal.devicecompute.CoreDeviceProxy` lockdown 服务**仅 USB 暴露**；跨网/无线必须走 remotepairing → TLS-PSK 隧道（idevice 的 `remote_pairing` + `tunnel` 已有全部组件，open-screen-sharing 的 `connect.go` 是同款流程）。
4. 输入必须走 **Indigo**（`com.apple.coredevice.hid.indigo`）：UniversalHIDServiceClient 的 digitizer tap 发送成功但不落地；indigo button/digitizer 均落地。
5. **HID 事件需要一条活跃的 displayservice 媒体流作"认证门"**（RTP 载荷可弃）。hid 与 display 两条通道在架构上耦合，不能只搬输入。

## 1. Phase 0 实验记录

设备：iPhone 17（iPhone18,3），iOS 27.3，DDI cryptex 已挂载。工具：idevice v0.1.68 `tools`（`cargo build -p idevice-tools`）。

| 步骤 | 命令 | 结果 |
|---|---|---|
| USB 配对 | `idevice-tools pair --name LoopCtrl-Phase0` | 一次成功，无信任弹窗，记录含 HostID/RootCertificate/WiFiMAC |
| 显示流 | `screencapture out.h265` | 9 秒 1.28MB Annex-B HEVC，音视频会话均建立，ffmpeg 抽帧清晰 |
| HID 按键 | `hid button home` | 小红书 → 主屏，落地 ✅ |
| HID 触摸（Universal） | `hid tap 57800 60950` | 发送成功但不落地 ❌ |
| HID 触摸（Indigo 归一化） | `hid swipe none 0.5 0.5 0.5 0.5` | 主屏中心 TiebaPure 图标被打开 ✅ |
| WiFi lockdown | `--host … --pairing-file … ideviceinfo` | 会话成功，设备信息完整返回 ✅ |
| WiFi CoreDeviceProxy | 同上 + `hid` | `peer closed connection without TLS close_notify`——服务仅 USB，符合预期 |

期间 d32c818（open-screen-sharing 引用的提交）与 v0.1.68 代码 diff 为空，仅版本号不同——排除版本差异。

## 2. 对 LoopCtrl 的接入设计

### FFI 缺口（0003 补丁的形状）

现状：`ffi/src/core_device/` 只有 app/configuration/diagnostics/file/icon 五个服务 + `core_device_proxy.rs`（隧道已暴露）。

需要新增（仿照现有 ffi 模块的 C ABI 风格）：

- `ffi/src/core_device/hid.rs`
  - `idevice_indigo_connect(tunnel_handle) → client`（RSD 握手 + indigo 服务）
  - `idevice_indigo_send_digitizer(client, x, y, event_type, edge, target)`——坐标 f64 归一化
  - `idevice_indigo_send_button(client, usage_page, usage, state)`、`idevice_indigo_send_key(client, usage, state)`
  - `idevice_indigo_close(client)`
- `ffi/src/core_device/display_stream.rs`
  - `idevice_display_start(tunnel_handle, offer_config) → session`（zlib 协商 + UDP 接收 socket，复用 `coredevice_stream.rs` 的 offer 构造）
  - `idevice_display_stop(session)`；解包后 Annex-B 回调或轮询
- 连同上游修复：digitizer 坐标归一化（建议先提 idevice 上游 PR，同时进本地补丁）

LoopCtrl 侧：
- `TunnelFrame` 已产出隧道 → 应用进程直接驱动上述 FFI；display stream 以"门簾模式"常驻（弃载荷）或直接接现有 MSE 管线（Phase 2 决定）
- RPC 层加后端开关：`tap/gesture/home` 优先 CoreDevice HID，XCTest 兜底

### 已知边界

- iOS 版本耦合：dtuhidd/displayservice 属 DDI 组件，iOS 大版本要跟
- 无线：手机侧已走本机 LocalDevVPN 的 RP 隧道；宿主跨网访问仍依赖局域网 RPC 或中继
- 许可证：idevice 仓库单一 MIT（core_device 全路径无冲突头）；依赖链注意 **aws-lc-rs**（默认特性，Apache-2.0/ISC/OpenSSL 声明）或 ring（含 BSD 成分）——NOTICE.md 补条目
- open-screen-sharing 为 GPL-3.0 + 名称条款：协议行为可参照，代码零引入

## 3. Phase 1 落地与实测（2026-11-08）

- FFI：`Patches/idevice/0003-coredevice-hid-display-ffi.patch` 暴露 `hid_indigo_*` 与 `display_gate_*`，xcframework 由 `Scripts/build-idevice.sh` 带补丁构建。
- App 侧：`LoopCtrlKit/CoreDeviceInput.swift` 走本机 LocalDevVPN 隧道（`10.7.0.1:49152`）→ RSD → Indigo HID；配对记录用 `Application Support/Pairing/pairingFile.plist`（设置 → 磁盘镜像向导 → “在这台 iPhone 上配对”）。HID 期间保持一条 displayservice 媒体流作认证门，空闲 30s 关闭；失败整体拆除并冷却 60s。
- RPC：`tap` / `double_tap` / `long_press` / `swipe` / `drag` / `home` 先走 CoreDevice，失败回退 XCTest；power / action / volume 仍走 XCTest（HID 用法未验证）。`/remote` 页的手动点按与长按也走 CoreDevice。
- 状态：`device_info` 增加 `coredevice {state, input, reason}`（active/idle/cooldown/unavailable）；手势回复带 `backend: coredevice|xctest`。`/remote` 状态行在连接方式后显示 CoreDevice / XCTest，回退时悬停显示原因。

iPhone 17（iOS 27.3）局域网 RPC 端到端耗时，客户端实测（含一次网络往返）：

| 动作 | CoreDevice | 对照（XCTest） |
|---|---|---|
| tap（首击，建隧道） | 1621 ms | — |
| tap（热） | 918–1281 ms（1 次 1947 ms） | ~1180 ms |
| double_tap | 1057 / 1073 ms | — |
| swipe 200 pt | 1167 ms | — |
| long_press 1.0 s | 1579 ms | — |
| home | 125–308 ms | ~1700 ms |

**新发现：触摸事件必须带位移采样。** 同一点的 down → up（哪怕中间保持 50 ms）在 SwiftUI 控件上不触发，加一个 1 pt 的 `.position` 采样就落地；0.6 pt 的微位移 drag 同样有效。这也解释了 idevice-tools 的 `hid tap` 无效而 `hid swipe` 有效——前者零位移，后者有轨迹。Long press 无需位移。

## 4. 待办

- [x] Phase 1：0003 FFI 补丁 + RPC 后端开关 + 真机延迟对比
- [ ] 无线路径：宿主侧 RP 隧道打通（当前手机侧已通，RPC 走局域网/中继）
- [ ] Phase 2：display 流接浏览器（WebCodecs；Safari HEVC 原生，Chrome 待确认协商是否支持 H264）
- [ ] digitizer 坐标修复上游 PR
