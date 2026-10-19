# 跨平台配对工具：技术选型与可行性调研（iOS 16–26）

状态：调研稿，不含实现。调研日期 2026-10-17。依据：idevice v0.1.68（commit `3854a5d`）、iLoader v2.3.9、Impactor v2.7.0、idevice_pair v1.1.0 的源码（浅克隆后逐个文件阅读），GitHub API 查到的许可证与活跃度，以及下文列出的社区资料。标 ⚠️ 的结论没有在真机上验证。

前置文档：`docs/desktop-pairing-plan.md`（整体设计、签名分发风险）、`docs/ios16-ddi-mount.md`（iOS 16 用 lockdown 记录）。本文只回答「工具怎么做、基于什么做、有线/无线能做到哪一步」，不重复那两篇已有的结论。

## 0. 结论

1. **技术栈：Rust（idevice）核心 + Tauri 2 界面，fork iLoader（nab138/iloader，MIT）。** iLoader 已经实现了我们要的几乎全部流程：找设备 → lockdown 配对（信任弹窗）→ 通过 `RemotePairingLockdownService` 生成 RP 记录 → 按 UDID 缓存 → 用 house_arrest 写进指定 App 的 `Documents/`。它还自带 Tauri 签名更新、Windows 安装包（MSI 8 MB / NSIS 5 MB）、macOS 通用包（17 MB），并且已经有简体中文翻译。我们要做的主要是删减（侧载、Apple ID 登录）和换品牌。
2. **v1 平台：Windows 10/11 x64 + macOS（Universal）。** Linux 可以顺带出包，但不作为正式支持平台。Android OTG 技术上可行、不需要 root，但要自己实现 USB 层的 usbmux 协议，放到 v2 单独评估（第 2.3 节）。
3. **有线是唯一的首次配对方式（iOS 16–26）。** 苹果官方安全白皮书写明：通过 Wi-Fi 连接的主机「必须先经过物理连接配对」。iOS 27+ 才有设备发起的无线配对（idevice 的 `pair_host`），而那时 LoopCtrl 已经能在手机上自己配对。
4. **无线只能用于「之后刷新」，⚠️ 需要真机验证。** 首次 USB 配对时顺便打开无线调试（`EnableWifiDebugging`），之后同一局域网内，工具可以用缓存的 lockdown 记录通过 Wi-Fi 重新生成 RP 记录并写回 App。这是 v1.1 的候选功能，不是 v1 的承诺。
5. **不要 fork idevice_pair。** 它是功能上最贴近的项目（jkcoxson 本人写的，USB/Wi-Fi、lockdown/RP、写入 App、校验都有），但**仓库里没有许可证文件**，默认保留所有权利，只能作为参考。可以写信问作者能否加上 MIT（见第 7 节）。
6. **工作量：v1（Win + macOS，有线，配对 + 写入 + 校验，不含安装 App）约 4–6 人周。** 无线刷新 +1–2 周，Android OTG +4–6 周，签名安装服务端另算（见第 8 节）。

## 1. 许可证与候选项目

只有 MIT / Apache-2.0 / BSD 可以直接拿来用。MPL-2.0 是文件级 copyleft：可以商用、可以和闭源代码链接，但被改过的 MPL 文件要公开源码。

| 项目 | 许可证 | 最近提交 | 语言 / 形态 | 覆盖我们的流程 | 能否 fork |
|---|---|---|---|---|---|
| [jkcoxson/idevice](https://github.com/jkcoxson/idevice) | **MIT** | 2026-10-08 | Rust 库 + CLI | 全部底层：usbmuxd、lockdown 配对、`RemotePairingLockdownService`、CoreDeviceProxy、house_arrest/AFC、installation_proxy、mDNS、iOS 27 `pair_host` | ✅ 核心依赖（App 里已经在用） |
| [nab138/iloader](https://github.com/nab138/iloader) | **MIT**（代码）＋ `LICENSE-BRANDING`（名称、图标另有限制） | 2026-10-16 | Tauri 2 + React/TS + Rust | 配对、RP、缓存、写入 13 个已知 App、导出、侧载、自动更新 | ✅ **推荐基础**。必须换掉名称和图标，不能暗示官方关系 |
| [nab138/isideload](https://github.com/nab138/isideload)（iLoader 的侧载库） | MIT；依赖 apple-codesign 系列（MPL-2.0） | 2026-10-14 | Rust | 免费 Apple ID 签名 + 安装 | ✅ 但 v1 不用（7 天签名不符合产品要求） |
| [claration/Impactor](https://github.com/claration/Impactor) | **MIT**；`3rdparty/apple-codesign-0.29.0`（带补丁）和 `3rdparty/omnisette` 是 **MPL-2.0** | 2026-10-16 | Rust + iced 0.14 | 签名安装、lockdown 配对、RP 记录、写入 Documents | ✅ 可作备选或参考。只用配对部分就不会碰到 MPL 代码 |
| [jkcoxson/idevice_pair](https://github.com/jkcoxson/idevice_pair) | **无许可证文件**（GitHub 识别为空） | 2026-10-07 | Rust + egui | lockdown/RP、USB/Wi-Fi、写入 App、校验、开无线调试、iOS 27 无线配对 | ❌ 仅参考；可以联系作者 |
| [danielpaulus/go-ios](https://github.com/danielpaulus/go-ios) | **MIT** | 2026-10-09 | Go CLI | lockdown 配对、17+ 隧道（`tunnel start` 需要 sudo）；没有写入 App 的现成流程 | ✅ 但要换语言，不复用现有 Rust 代码，不推荐 |
| [alibaba/tidevice](https://github.com/alibaba/tidevice) | **MIT** | 2025-11 | Python | 只到 iOS 16 时代的 lockdown，无 RP | ⚠️ 已不活跃，不推荐 |
| [appium/appium-ios-device](https://github.com/appium/appium-ios-device) | **Apache-2.0** | 2026-09 | Node.js | lockdown/usbmux 客户端，无 RP 配对 | 参考价值低 |
| [beonoyap-code/androidloader](https://github.com/beonoyap-code/androidloader) | **MIT** | 2026-09-28（新建，0 star） | Kotlin + Termux | Android OTG 上做 lockdown 配对（依赖 Termux 里的 usbmuxd） | 仅作 Android 可行性的旁证 |
| [osy/Jitterbug](https://github.com/osy/Jitterbug)（含 jitterbugpair） | Apache-2.0，但**链接 libimobiledevice（LGPL）**，仓库已归档（2022） | 2022-09 | Swift/C | 只有 lockdown 配对 | ❌ 已停更，没有 RP |
| [doronz88/pymobiledevice3](https://github.com/doronz88/pymobiledevice3) | ⛔ **GPL-3.0** | 2026-10-17 | Python | 协议最全的参考实现 | ❌ 只看文档和行为，不抄代码 |
| [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) / [libusbmuxd](https://github.com/libimobiledevice/libusbmuxd) | ⛔ **LGPL-2.1** | 2026-06 / 2025-09 | C | lockdown 配对，无 RP | ❌ 动态链接在法律上可行，但要允许用户替换库、提供目标文件等，macOS 签名和打包都麻烦，而且 idevice 已经覆盖，没有必要 |
| [libimobiledevice/usbmuxd](https://github.com/libimobiledevice/usbmuxd) | ⛔ **GPL-2.0** | 2025-12 | C 守护进程 | USB 层 usbmux | ❌ 不能捆绑；Linux 用户自己装系统包没问题 |
| [jkcoxson/netmuxd](https://github.com/jkcoxson/netmuxd) | ⛔ **LGPL-2.1** | 2026-08 | Rust | 网络版 usbmuxd | ❌ |
| [SideStore/SideStore](https://github.com/SideStore/SideStore)、[minimuxer](https://github.com/SideStore/minimuxer)、[em_proxy](https://github.com/SideStore/em_proxy)、[SideServer-macOS](https://github.com/SideStore/SideServer-macOS) | ⛔ **AGPL-3.0** | 活跃 | Swift/Rust | 设备端侧载 | ❌ AGPL，连网络服务都要开源 |
| [altstoreio/AltStore](https://github.com/altstoreio/AltStore)、[AltServer-Linux](https://github.com/NyaMisty/AltServer-Linux) | ⛔ **AGPL-3.0** | 活跃 / 2025-03 | Swift/C | 签名安装 | ❌ |
| [StikDebug/StikDebug](https://github.com/StikDebug/StikDebug) | ⛔ **AGPL-3.0** | 活跃 | Swift | 设备端 | ❌ |
| [StikDebug/StikPair](https://github.com/StikDebug/StikPair) | ⛔ **「MIT, Non-Commercial」自定义许可证**，明确禁止商用 | 2026-08 | Swift | iOS 27+ 设备端配对 | ❌ 已排除 |
| [jkcoxson/LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) | 自定义「StosVPN License」：MIT 基础上要求显著署名、禁止以相同或相似名称整体重发 | 2026-09 | Swift | 手机端隧道（不是本工具的一部分） | 仅供了解；我们不分发它 |

**GUI 框架本身：** Tauri（Apache-2.0/MIT）、iced（MIT）、egui（MIT/Apache-2.0）都没问题。**Slint 是 GPL-3.0 / 免版税许可证 / 商业许可证三选一**，免版税许可证对桌面应用有署名等条件，用之前要读清楚，这也是本文不推荐它的原因之一。Electron（MIT）、Flutter（BSD-3）、flutter_rust_bridge（MIT）没问题。

**fork 时的合规动作：** 保留 iLoader、idevice 的 MIT 版权声明（放进「关于」页和安装包的 third-party notices）；用 `cargo-deny` 和 `license-checker`（前端 npm 依赖）在 CI 里扫一遍依赖许可证，禁止 GPL/AGPL/LGPL 进入；去掉 iLoader 的名称、图标和网站链接。

## 2. 平台与技术栈

### 2.1 各平台需要什么

| 平台 | usbmux | 额外安装 | 签名/公证 | 结论 |
|---|---|---|---|---|
| macOS 12+（Intel/Apple Silicon） | 系统自带 `/var/run/usbmuxd` | 无 | Developer ID 签名 + notarytool 公证（我们已有开发者账号）；不上 Mac App Store，不开沙盒 | ✅ v1 |
| Windows 10/11 x64 | Apple Mobile Device Service（`127.0.0.1:27015`） | Microsoft Store 的 **Apple Devices**，或旧版 iTunes。我们不能分发苹果驱动 | Authenticode 代码签名证书（OV 即可，私钥必须在 HSM/云签名里）；否则 SmartScreen 和国内杀毒软件会拦截 | ✅ v1 |
| Windows on ARM | Apple Devices 有 ARM 版 ⚠️ | 同上 | 同上 | v1 可选，Impactor 已出 ARM 包 |
| Linux | 系统包 `usbmuxd`（GPL，用户自己装） | `apt install usbmuxd` | AppImage/deb，无签名要求 | ⚪ 顺带出包，不承诺支持 |
| Android（USB OTG） | **没有**，需要我们自己在 App 里实现 USB 层 usbmux | 无（不需要 root） | 普通 APK 签名；国内要上各家应用商店 | ⚠️ v2，见 2.3 |
| HarmonyOS NEXT | 不能运行 APK | — | — | ❌ 国内华为新机越来越多是这个系统，Android 方案覆盖不到 |

Windows 7/8 不支持：Tauri 依赖 WebView2，Rust 新版本也已经不再正式支持 Win7。国内仍有少量 Win7 用户，客服话术里要写明。

### 2.2 技术栈对比

| 方案 | 安装包 | 复用 idevice | Windows 依赖 | 自动更新 | Android 复用 | 评价 |
|---|---|---|---|---|---|---|
| **Tauri 2（fork iLoader）** | Win 5–8 MB，macOS 17 MB | 直接用 Rust crate | WebView2（Win11 自带，Win10 绝大多数已装，安装包可内嵌引导程序） | 官方 `tauri-plugin-updater`，带签名校验，iLoader 已接好 | Tauri 2 能出 Android 包，前端可以复用 | ✅ **推荐**：现成流程最多，界面用 Web 技术，好改、好做中文排版 |
| Rust + iced（fork Impactor） | Win 8 MB 安装包 / 17 MB 便携版，macOS 16 MB | 直接用 | 无 | 要自己接（比如 Velopack，MIT） | 不能 | ✅ 备选：单一语言、单文件，但 iced 的中文输入、字体回退、高 DPI 要自己调，Impactor 的流程以签名为主，配对部分要重组 |
| Rust + egui（参考 idevice_pair） | 38–55 MB（含字体等） | 直接用 | 无 | 自己接 | 理论上能 | ⚪ 界面偏工具风，不适合普通客户；而且没有可 fork 的项目 |
| Rust + Slint | 小 | 直接用 | 无 | 自己接 | 能 | ⚪ 许可证条件要单独审，没有现成项目 |
| Flutter + flutter_rust_bridge | 20–40 MB | 通过 FFI | 无 | 自己接 | ✅ 最好 | ⚪ 只有在 Android 是硬需求时才值得，而 Tauri 2 也能覆盖 Android |
| Electron + napi-rs | 80–120 MB | 通过 Node 扩展 | 无 | electron-updater | 不能 | ❌ 体积大，没有任何额外好处 |

**选 iLoader 而不是 Impactor 的具体理由：**

- iLoader 的 `src-tauri/src/pairing.rs` 和我们要的流程一一对应：`generate_lockdown_plist`（取 usbmuxd 里的记录、`start_session`、打开 `EnableWifiDebugging`）→ `generate_rppairing`（`RemotePairingLockdownService` → `RemotePairingClient::connect`，PIN `"000000"`，USB 上不弹窗）→ 以 `rppairing1.1_file_<udid>` 为键缓存 → `place_file`（`HouseArrestClient::vend_documents` → AFC 写入）。2026-10-02 起它已经从 CoreDeviceProxy 隧道换成了这个更简单的 lockdown 服务。
- 17.4 以下自动跳过 RP（`is_ios_version_below(…, 17, 4)`），iOS 16 只给 lockdown 记录，正好符合 LoopCtrl 的格式要求。
- 已经有 `zh_cn.json`，以及 Windows 上「请从 Microsoft Store 安装 Apple Devices」之类的排错提示。
- Impactor 用的是更早的 idevice rev（`5171e34`），配对走 CoreDeviceProxy；以签名为核心，配对只是附属功能。

**fork 后要改的地方（概览）：** 删掉 Apple ID 登录、侧载、证书管理页面和 isideload 依赖；`PAIRING_APPS` 只留 LoopCtrl，并改成按 Info.plist 里的自定义键识别（客户签名时 bundle ID 前缀会变，见第 4 节）；写入路径改成投递位置；增加「校验」一步（参考 idevice_pair 的 `verify_remote`：RSD 上 `attempt_pair_verify` + `validate_pairing`）；更新地址改到国内 CDN；换品牌。

### 2.3 Android 通过 USB OTG 当主机

**结论：理论上可行、不需要 root，但没有现成的许可证可用的实现，⚠️ 也没有任何人在真机上验证过 iOS 17+ 的 RP 配对。建议 v2 做一个 1 周的技术验证再决定。**

- **USB 访问不需要 root。** Android 的 USB Host API（`UsbManager.requestPermission` → `openDevice`）会给 App 一个 usbfs 文件描述符。Rust 侧可以用 `nusb::Device::from_fd` 接管（nusb 0.2 的 Android 用法，`list_devices()` 在 Android 上不可用，只能走 fd）。androidloader 用 Termux:API 的 `termux-usb` 做的正是同一件事，并在 Android 上完成了 lockdown 配对。
- **缺的是 USB 层的 usbmux 协议。** idevice 只有 usbmuxd **客户端**（连桌面上的守护进程），没有直接驱动 USB 的部分；唯一成熟的实现是 libimobiledevice 的 usbmuxd（GPL-2.0，不能用）。需要按协议自己实现：选 USB configuration、认领 usbmux 接口（class 0xFF / subclass 0xFE / protocol 2）、版本握手、在 bulk 端点上跑简化 TCP 帧。估计 1500–2500 行 Rust，可以参考 GPL 代码理解协议，但要净室重写。实现后包成一个 `IdeviceProvider`，上层的 lockdown/RP/house_arrest 代码可以完全复用。
- **配对记录存在 App 自己的目录里**，不依赖系统 usbmuxd。
- **硬件风险 ⚠️：** 部分厂商内核限制 OTG；Lightning iPhone 要 Lightning–USB-A 线加 OTG 转接头，供电要够；USB-C iPhone（15 及以后）接 USB-C Android 时双方都是 DRP，谁当主机靠协商，可能需要在 Android 设置里切换 USB 角色或用 OTG 转接头强制。
- **适用场景：** 客户身边没有电脑但有一台 Android 手机。在国内这个比例不低，但还要扣掉 HarmonyOS NEXT 机型。

## 3. 有线与无线

### 3.1 「首次配对」与「之后刷新」要分开看

- **首次配对**：手机从没信任过这台主机。必须触发「信任此电脑」弹窗并输入锁屏密码，生成 lockdown 记录（iOS 16 到这一步就结束）；iOS 17.4+ 再在已信任的 lockdown 连接上生成 RP 记录，这一步 USB 上不再弹窗（pymobiledevice3 文档：USB bootstrap over the already-trusted lockdownd transport, "promptless"）。
- **刷新**：手机已经信任这台主机（工具里缓存了 lockdown 记录），只是 App 里的 RP 文件丢了（重装 LoopCtrl）或者失效了，需要重新生成或重新写入。

### 3.2 iOS 16–26 上无线到底能做什么

1. **首次配对不能走无线。** 苹果《平台安全指南》「物理配对模型」一节：主机要通过 Wi-Fi 连接，"it must have been previously paired over a physical connection (Thunderbolt or USB)"。lockdownd 对网络连接上的 `Pair` 请求返回 `PairingProhibitedOverThisConnection`（见 `desktop-pairing-plan.md` 第 3 节）。idevice_pair 的界面文案也写明「无线配对只在 iOS 27 及以上可用」，无线只对 Apple TV 和 iOS 27+ 开放。Xcode 的无线调试同样要求先用线连一次再勾选「Connect via network」。iOS 27 以下没有找到任何「手机主动发起」或「手动输入 PIN」的配对路径。
2. **有了 USB 信任之后，无线刷新很可能可行 ⚠️。**
   - 首次 USB 配对时，用 lockdown 在 `com.apple.mobile.wireless_lockdown` 域设置 `EnableWifiDebugging = true`（iLoader、idevice_pair、Impactor 都这么做；pymobiledevice3 的对应命令是 `lockdown wifi-connections on`，文档写明「必须先在 USB 上执行一次」）。之后手机在局域网里广播 `_apple-mobdev2._tcp`，桌面上的 usbmuxd（macOS 自带的、Windows 的 Apple Mobile Device Service）会把它列为 Network 类型设备。
   - 在这个网络 lockdown 连接上用缓存的记录 `StartSession`，再启动 `com.apple.dt.remotepairingdeviced.lockdown` 生成新的 RP 记录，最后用 house_arrest 写回 App。idevice_pair 的 `remote_file` 对任何 usbmuxd provider 都会这么做（不区分 USB/Network），但**没有资料确认 lockdownd 在网络连接上允许启动这个服务** ⚠️。退一步，pymobiledevice3 文档说打开 Wi-Fi 连接后 CoreDeviceProxy 隧道可以走 Wi-Fi，那条路也能生成 RP 记录 ⚠️。
   - **仅重新写入**（RP 文件还有效，只是 App 重装了）：工具缓存了 RP 文件，通过网络 lockdown 连 house_arrest 写回即可，不需要重新生成。这和 iTunes 的「无线同步文件共享」是同一条路，⚠️ 可能性最大。
   - 已有 RP 记录时，`_remotepairing._tcp`（LAN 上的 RemotePairing）只做 pair-verify，适合「校验文件是否还有效」，不能用它创建新记录。
3. **一个值得验证的「纯手机刷新」路径 ⚠️（高价值，未验证）：** LoopCtrl 自己手里如果也有 lockdown 记录（首次配对时一起写进去，就是 iLoader 的合并 plist），那么在手机上通过 LocalDevVPN/Shadowrocket 回环连 `10.7.0.1:62078` 的 lockdownd，同样可以尝试启动 `remotepairingdeviced.lockdown` 自己重新生成 RP 记录。iOS 16 的挂载已经在用回环上的 lockdownd，所以通道本身是通的；关键是这个服务是否只允许 USB。若可行，「重装 LoopCtrl 后不用再连电脑」就能实现（前提是 lockdown 记录没被系统清掉）。
4. **30 天过期 ⚠️：** 同一份安全指南写明，iOS 11 及以后「if a pairing record hasn't been used for more than 30 days, it expires」。LoopCtrl 每次重启后挂载都会用到 RP 记录，正常使用不会过期；但不清楚这条规则是否作用于 RP 记录、以及工具缓存的 lockdown 记录是否会因为长期不用而失效（那样无线刷新就会失败，要退回 USB）。需要实测。

### 3.3 可行性矩阵

| iOS | 有线首次配对 | 无线首次配对 | 无线刷新：重新写入已缓存文件 | 无线刷新：重新生成 RP | 写给 LoopCtrl 的格式 |
|---|---|---|---|---|---|
| 16.x | ✅ lockdown 配对（App 侧挂载 ⚠️ 未真机验证） | ❌ | ⚠️ 很可能可行（网络 lockdown + house_arrest） | 不适用（没有 RP） | lockdown 记录 |
| 17.0–17.3.1 | ✅ 仅 lockdown；RP 生成需要 USB 网卡 + QUIC 隧道，Windows 无官方支持，iLoader 也直接跳过 | ❌ | ⚠️ 同上 | ❌ | lockdown 记录（App 端 17.0–17.3 走 lockdown 挂载尚未实现，见 `desktop-pairing-plan.md` 第 7 节） |
| 17.4–18.x | ✅ lockdown + RP（`remotepairingdeviced.lockdown`，USB 上不弹窗） | ❌ | ⚠️ 很可能可行 | ⚠️ 未验证（网络 lockdown 上能否启动该服务） | RP 记录（可合并 lockdown 记录） |
| 26.x | ✅ 同上 | ❌ | ⚠️ 同上 | ⚠️ 同上 | 同上 |
| 27+ | 不需要（App 内配对） | ✅ 设备发起配对（idevice `pair_host`，手机上输入 PIN） | ✅ | ✅ | App 内自行生成 |

**结论：** v1 只做有线。无线刷新作为 v1.1 候选：先做第 6 节的验证，通过了再加一个「同一 Wi-Fi 下重新写入」的按钮。产品话术里不要承诺「不用数据线」。

## 4. 端到端流程（普通客户）

界面上只有一个大按钮和一条进度，每一步失败都给出中文的具体处理办法。

1. **启动自检。** Windows：连 `127.0.0.1:27015`，连不上就提示「请从 Microsoft Store 安装 Apple Devices」并给出按钮（用 `ms-windows-store://` 链接，国内 Microsoft Store 可用 ⚠️）；装了 爱思助手、iTools 等软件导致服务冲突时给出排查指引。macOS：不需要。
2. **检测设备。** 订阅 usbmuxd 的 `Listen` 事件，只认 USB 类型的设备；显示设备名、iOS 版本；检测开发者模式（未开启时引导到「设置 › 隐私与安全性 › 开发者模式」，并说明需要重启）。没有锁屏密码的设备无法配对，要提前提示。
3. **信任。** 提示「请解锁手机，点『信任』并输入锁屏密码」。`LockdownClient::pair` 在 `PairingDialogResponsePending` 时会每秒重试；客户点了「不信任」要能识别并提示重新插线。成功后 `save_pair_record`，同一台电脑以后不再弹窗。
4. **生成记录。**
   - iOS 16 / 17.0–17.3：直接用 lockdown 记录（要补上 `UDID`）。
   - iOS 17.4+：`RemotePairingLockdownService` 生成 RP 记录；如果该服务不存在，退回 CoreDeviceProxy 软件隧道（iLoader 早期版本和 Impactor 的做法）。合并 lockdown 记录，为第 3.2 节第 3 条留路。
   - 同时设置 `EnableWifiDebugging`，为无线刷新做准备。
   - RP 文件和主机名（iLoader 用 `iloader-xxxxxx`，我们用自己的前缀）按 UDID 缓存在本机，用系统钥匙串/凭据管理器或 0600 文件保存，**不上传**。
5. **找到 LoopCtrl。** 用 installation_proxy 列出用户 App。不能只按 bundle ID 找：客户自签时 `LOOPCTRL_BUNDLE_PREFIX` 会变。建议在 LoopCtrl 的 Info.plist 里加一个固定键（例如 `LoopCtrlPairingDropbox = 1`），工具按这个键识别。没装就进入第 8 步或提示先安装。
6. **写入。** 写到投递位置（`Documents/.pairing-dropbox/pairingFile.plist`），App 启动或回到前台时校验并移到 `Application Support/Pairing/`（`PairingFileStore.store(_:)`），然后删除投递文件。`vend_documents` 要求 App 有 `UIFileSharingEnabled`（iLoader、idevice_pair 都只用这条路）；`vend_container` 只对带 `get-task-allow` 的开发签名 App 开放。两条都试，细节见 `desktop-pairing-plan.md` 第 2 节。
7. **校验。** iOS 17.4+：用刚生成的 RP 文件做一次 pair-verify（RSD 上 `attempt_pair_verify` + `validate_pairing`），确认手机认这份记录。iOS 16：用 lockdown 记录 `StartSession` 一次。可选：读回投递文件比较哈希；或者请客户打开 LoopCtrl，App 导入成功后删除投递文件，工具轮询到文件消失就显示「完成」。
8. **（可选）安装或更新 LoopCtrl。** 依赖签名方案，见 `desktop-pairing-plan.md` 第 6 节。技术上是 AFC 上传到 `PublicStaging` + `InstallationProxyClient::install/upgrade`，iLoader/Impactor 都有现成代码。v1 先不做，等签名服务端定下来。
9. **完成。** 「可以拔线了。以后每次手机重启，打开 LoopCtrl 点一下『挂载』即可。」

## 5. 国内客户相关的注意事项

- **分发与更新：** GitHub Releases 在国内很慢或不可用。安装包和 Tauri 更新清单（`latest.json` + 签名）放到国内对象存储/CDN（阿里云 OSS、腾讯云 COS 等），自有域名要做 ICP 备案。更新包必须用 Tauri 的 minisign 密钥签名。
- **Windows 驱动：** Apple Devices 在 Microsoft Store 上 ⚠️（国内可访问，但部分精简版/企业版 Windows 没有商店）。备选是 apple.com.cn 的 iTunes 安装包。不要引导客户去第三方驱动下载站。
- **杀毒软件：** 360、火绒、腾讯电脑管家对未签名、会访问 USB 设备的小工具误报率高。必须做 Authenticode 签名，上线前向几家厂商提交白名单。
- **Windows 签名证书：** OV 证书私钥现在必须放在 HSM 或云签名服务里，CI 签名要选支持云签名的 CA。微软的 Artifact Signing（原 Trusted Signing）对申请主体所在地区有限制 ⚠️，要按我们公司主体的注册地确认。
- **macOS 本地网络权限：** 只有做无线功能（mDNS、局域网连接）时才会触发 macOS 15+ 的「本地网络」授权弹窗；v1 只做有线不会碰到。

## 6. 风险与待解决问题

1. ⚠️ **`remotepairingdeviced.lockdown` 的可用版本范围。** iLoader 从 2026-10-02 起对所有 17.4+ 设备都用它，说明作者认为 17.4+ 都有，但我们没有在 17.4、18.x、26.x 各一台真机上验证过。不存在时要能退回 CoreDeviceProxy 路径。
2. ⚠️ **工具生成的 RP 文件，LoopCtrl 能否直接用来挂载。** App 里的 idevice 是 v0.1.68 + 补丁；iLoader 用 crates.io 上的 0.1.68。版本一致，但还是要实测一次。
3. ⚠️ **无线刷新**（第 3.2 节）：网络 lockdown 上能否启动 `remotepairingdeviced.lockdown` / CoreDeviceProxy；house_arrest 能否走 Wi-Fi；Windows 上 Apple Mobile Device Service 对 Wi-Fi 设备的支持情况。
4. ⚠️ **纯手机刷新**（第 3.2 节第 3 条）：LoopCtrl 通过回环 lockdownd 能否自己生成 RP 记录。这一项如果可行，价值最大，建议最先验证。
5. ⚠️ **30 天未使用即过期**是否作用于 RP 记录和缓存的 lockdown 记录。
6. ⚠️ **iOS 16 和 17.0–17.3 的 App 端挂载**都还没有真机验证（见 `ios16-ddi-mount.md`），工具这一侧很简单，但 App 侧不通则这些版本整体不可用。
7. **LoopCtrl 需要改 Info.plist：** `UIFileSharingEnabled`（走 `vend_documents` 时）以及工具识别用的固定键。打开文件共享后客户会在「文件」App 里看到 LoopCtrl 的 Documents，投递文件要即取即删。
8. **iLoader 上游变化快**（几乎每天提交）。fork 之后定期合并上游的 idevice 升级和修复，否则苹果改协议时会落后。保持 fork 的改动集中在少数文件里。
9. **idevice_pair 无许可证：** 可以联系 jkcoxson 请求加上 MIT（他的 idevice 本身就是 MIT）；如果同意，它的校验和 Wi-Fi 代码可以直接拿来用。
10. **签名分发**（安装 LoopCtrl 这一步）的合规风险和设备数上限，见 `desktop-pairing-plan.md` 第 6 节，不在本工具 v1 范围内。
11. **Android 方案：** 自写 usbmux 协议、OTG 兼容性、USB-C iPhone 的角色协商，以及 HarmonyOS NEXT 覆盖不到。
12. **苹果收紧协议的风险：** 我们和 Xcode、iLoader、pymobiledevice3 走同一条路，风险和整个社区一致；fork 活跃上游可以最快拿到修复。

**建议在写代码前做的真机验证（约 2–3 天，需要 iOS 16、17.0–17.3、17.4–18.x、26.x 各一台，Windows 和 macOS 各一台电脑）：**

- 用 idevice 的 CLI（`idevice-tools` 里的 `pair`、`remotepairing_lockdown pair`、`afc`/house_arrest）在 Windows 和 macOS 上各跑一遍完整流程，把文件放进 LoopCtrl，确认 App 能挂载。
- 打开 `EnableWifiDebugging` 后拔线，在同一 Wi-Fi 下重复「生成 RP + 写入」，记录每一步是成功还是被拒（错误码）。
- 在 LoopCtrl 里通过回环 lockdownd 尝试 `StartService com.apple.dt.remotepairingdeviced.lockdown`。

## 7. 推荐方案（汇总）

- **基础项目：** fork nab138/iloader（MIT），保留 Tauri 2 + React/TS 前端和 Rust 后端，换品牌；底层依赖 jkcoxson/idevice（MIT）。Impactor 作为参考和备选。
- **技术栈：** Rust（idevice、tokio）+ Tauri 2；Windows 用 NSIS/MSI，macOS 用 dmg；`tauri-plugin-updater` + 国内 CDN。
- **v1 平台：** Windows 10/11 x64、macOS 12+ Universal。Linux 出包不支持；Windows ARM 视需求。
- **v1 功能：** 有线配对（iOS 16–26）、生成 lockdown/RP 记录、写进 LoopCtrl、校验、本机缓存、打开无线调试（为以后做准备）、中文界面和排错指引。
- **v1.1：** 同一 Wi-Fi 下重新写入/重新生成（验证通过后）。
- **v2：** Android OTG（Tauri 2 Android + Kotlin USB 权限插件 + 自写 Rust usbmux）；安装/更新 LoopCtrl（等签名服务端）。

## 8. 工作量估算（1 名熟悉 Rust 的工程师）

| 项目 | 估计 |
|---|---|
| 真机验证（第 6 节） | 2–3 天 |
| fork iLoader：删侧载/Apple ID、换品牌、只保留 LoopCtrl、投递路径、按 Info.plist 键识别 App | 4–6 天 |
| 校验步骤、错误分类与中文提示（Apple Devices 缺失、不信任、无密码、开发者模式未开等） | 3–4 天 |
| LoopCtrl App 侧：投递位置导入、`UIFileSharingEnabled`/识别键、「配对文件被拒绝」提示 | 2–3 天 |
| 打包与签名：macOS 签名公证、Windows Authenticode（含云签名接入）、更新服务器与国内 CDN | 3–5 天 |
| 测试矩阵（iOS 16/17.x/18/26 × Win10/Win11/macOS）和修 bug | 5–7 天 |
| **v1 合计** | **约 4–6 人周** |
| v1.1 无线刷新（验证通过的前提下） | +1–2 人周 |
| v2 Android OTG（usbmux 协议实现、Kotlin 插件、机型兼容） | +4–6 人周 |
| 安装/更新 LoopCtrl（不含签名服务端本身） | +1 人周；签名服务端另算 3–6 人周 |

## 参考

源码（2026-10-17 浅克隆阅读）：
- idevice：<https://github.com/jkcoxson/idevice> — `idevice/src/remote_pairing/lockdown.rs`（`com.apple.dt.remotepairingdeviced.lockdown`）、`tools/src/remotepairing_lockdown.rs`（"Pair over USB, promptlessly"）、`tools/src/pair_host.rs`（iOS 27 设备发起配对）、`tools/src/pair_rsd_ios.rs`、`idevice/src/usbmuxd/`（只有客户端和消息定义）
- iLoader：<https://github.com/nab138/iloader> — `src-tauri/src/pairing.rs`、`src-tauri/tauri.conf.json`（updater）、`LICENSE`、`LICENSE-BRANDING`、`src/locales/zh_cn.json`；提交 e1eaf81「Use new RemotePairingLockdownService」
- isideload：<https://github.com/nab138/isideload>
- Impactor：<https://github.com/claration/Impactor> — `Cargo.toml`（idevice rev、iced 0.14）、`crates/plume_utils/src/device.rs`、`3rdparty/`（MPL-2.0）
- idevice_pair：<https://github.com/jkcoxson/idevice_pair> — `src/backend/pairing.rs`、`src/backend/worker.rs`、`src/ui/mod.rs`（「无线配对只在 iOS 27 及以上可用」）
- androidloader：<https://github.com/beonoyap-code/androidloader>
- go-ios：<https://github.com/danielpaulus/go-ios>
- StikPair 许可证：<https://github.com/StikDebug/StikPair>

文档与资料：
- Apple《平台安全指南》物理配对模型（Wi-Fi 需先物理配对；30 天未用过期）：<https://support.apple.com/en-au/guide/security/secadb5b6434/web>
- Xcode 无线配对（先用线连接再勾选 Connect via network）：<https://help.apple.com/xcode/mac/current/en.lproj/devbc48d1bad.html>
- pymobiledevice3 iOS 17 隧道指南（USB 上 promptless 配对、`lockdown wifi-connections on`、Wi-Fi 隧道需要已有 RP 记录）：<https://github.com/doronz88/pymobiledevice3/blob/master/docs/guides/ios17-tunnels.md>
- pymobiledevice3 RemoteXPC 说明（LAN 上已配对主机只能 pair-verify）：<https://github.com/doronz88/pymobiledevice3/blob/master/misc/RemoteXPC.md>
- pymobiledevice3 v9.33.0 发布说明（remotepairingdeviced.lockdown 命令）：<https://newreleases.io/project/github/doronz88/pymobiledevice3/release/v9.33.0>
- nusb（Android 上通过 fd 打开设备）：<https://docs.rs/crate/nusb/latest>，用法示例 <https://docs.rs/crate/tauri-plugin-serialplugin/3.0.2/source/android/README.md>
- Apple Devices（Windows）：<https://en.wikipedia.org/wiki/Apple_Devices>
- libimobiledevice `PairingProhibitedOverThisConnection`：<https://github.com/libimobiledevice/libimobiledevice/blob/master/src/lockdown.c>
