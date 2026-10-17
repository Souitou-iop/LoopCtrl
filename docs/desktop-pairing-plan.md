# 电脑端一次性配对工具：调研与设计（iOS 16–26）

状态：设计稿，尚未实现。调研日期 2026-10-17，基于 idevice v0.1.68 源码、Impactor（claration/Impactor，MIT）源码、libimobiledevice 源码和社区资料。标 ⚠️ 的结论还没有在真机上验证。

## 结论

- **可行，而且有现成的参考实现。** idevice 已经能在 USB 下完成两件事：lockdown 配对，以及生成 LoopCtrl 需要的 RPPairing 文件。生成后可以通过 house_arrest/AFC 直接写进 App 的容器。Impactor 就是用 idevice 做的跨平台侧载工具（Win/macOS/Linux），它已经把「签名安装 App → 生成 RP 配对文件 → 写进 App 的 Documents」串成了一步（见 `crates/plume_utils/src/device.rs` 的 `install_remote_pairing_record` / `get_rsd_pairing_file`）。我们的工具基本可以照这个思路实现。
- **实际支持下限是 iOS 17.4，不是 17.0。** USB 上生成 RP 记录要用 lockdown 服务 `CoreDeviceProxy`，这个服务 17.4 才有（pymobiledevice3 文档：17.4+ 用 `lockdown start-tunnel`，更早的版本要走 USB 网卡加 QUIC 隧道，需要管理员权限，Windows 上也没有官方支持）。StikDebug 标注的完整支持范围同样是 17.4–18.x 和 26.x。这和 LoopCtrl 现在的提示「iLoader 需要 17.4+」一致。
- **iOS 27 以下不能纯手机配对（基本确定，⚠️ 未在真机验证）。** 理由见第 3 节。
- **保留 iOS 16，用 lockdown 记录走旧版挂载。** 重启后要重新挂载是所有版本都有的事，不是放弃 iOS 16 的理由。App 已经加上了 iOS 16 的设备内挂载路径，助手在 iOS 16 上写入 lockdown 记录即可。见第 7 节。
- **最大的风险其实是签名分发，而不是配对。** 见第 6 节。

## 1. 目标流程（客户视角）

1. 下载并打开「LoopCtrl 配对助手」（Windows / macOS 各一个可执行程序）。
2. 用数据线连接 iPhone，解锁。手机上弹出「要信任此电脑吗？」，点「信任」并输入锁屏密码。
3. 助手自动完成：安装或更新 LoopCtrl（可选）→ 生成配对文件 → 写进 LoopCtrl → 校验。界面上只显示一个进度条，最后是「完成，可以拔线」。
4. 之后只用手机：LocalDevVPN 或 Shadowrocket 加 LoopCtrl。每次重启后在 App 内点一下「挂载」。

客户全程不接触任何文件，也不需要另装 iLoader 或 StikPair。

## 2. 技术链路和用到的组件

全部基于 idevice（Rust，MIT）。LoopCtrl 的 App 内已经在用它的 FFI，电脑端可以直接用 Rust crate。

| 步骤 | idevice API | 说明 |
|---|---|---|
| 找设备 | `usbmuxd::UsbmuxdConnection::get_devices()` | macOS 用系统自带的 usbmuxd；Windows 用 Apple Mobile Device Service（TCP `127.0.0.1:27015`，即 `UsbmuxdAddr::DEFAULT_PORT`） |
| lockdown 配对 | `LockdownClient::pair(host_id, buid, name)`，然后 `start_session` 校验，`usbmuxd.save_pair_record` | 触发手机上的「信任」弹窗；库在 `PairingDialogResponsePending` 时每秒重试一次，等待用户点击。参考 `tools/src/pair.rs` |
| 生成 RP 记录 | `CoreDeviceProxy::connect` → `create_software_tunnel`（用户态 TCP 栈，不需要管理员权限或 TUN 网卡）→ `RsdHandshake` → 服务 `com.apple.internal.dt.coredevice.untrusted.tunnelservice` → `RemotePairingClient::connect`（PIN 固定 `"000000"`）→ `RpPairingFile` | 参考 `tools/src/rppairing.rs` 的 `pair_via_usb`。Impactor 在 pair-setup 之后再连一次做 pair-verify，确认记录确实可用，我们也照做 |
| 安装 App | `utils::installation` 的辅助函数（AFC 上传到 `PublicStaging` → `InstallationProxyClient::install/upgrade`） | IPA 必须已经为这台设备签好名，见第 6 节 |
| 写入配对文件 | `HouseArrestClient::vend_documents(bundle_id)` → AFC 写文件 | 见下文 |

**写入位置。** `vend_documents` 只能访问 `Documents/`，而且 App 的 Info.plist 里要有 `UIFileSharingEnabled = YES`。LoopCtrl 目前没有这个键（Impactor 签名时会自动加上）。`vend_container` 能访问整个容器，但只对带 `get-task-allow` 的开发签名 App 开放。LoopCtrl 依赖 XCTest，本来就必须是开发签名，所以两条路都可行。建议如下：

- 把文件写到一个投递位置，比如 `Documents/.pairing-dropbox/pairingFile.plist`，**不要**直接写到 `Application Support/Pairing/`。
- App 启动或回到前台时检查投递位置：用现有的 `PairingFileStore.store(_:)` 校验并移到正式位置（这样文件会带上 `completeFileProtection` 和 0600 权限），然后删除投递文件。AFC 写入的文件没有数据保护等级，不能长期放着。
- 首选 `vend_container`，不需要改 Info.plist。如果失败（比如某些签名方式没有 `get-task-allow`），退回到 `vend_documents`；这条路要求在 project.yml 里加上 `UIFileSharingEnabled`。加了之后用户会在「文件」App 里看到 LoopCtrl 的 Documents 目录，所以投递文件要即取即删。

**同步写入 lockdown 记录。** 同一次连接里还可以把 lockdown 记录合并进去，做成 iLoader 那样的合并 plist。iOS 17+ 上 LoopCtrl 只读 RP 那一半，合并后对以后的功能（比如通过 lockdown 安装更新）更有利。**iOS 16 上只写 lockdown 记录**：没有 RemotePairing，App 用 lockdown 记录挂载（见第 7 节），这一步也不需要 CoreDeviceProxy。

## 3. 能不能纯手机配对（iOS 17–26）

结论：不能，这次一次性 USB 配对绕不开。

1. **lockdown 配对必须走 USB。** lockdownd 有一个专门的错误 `PairingProhibitedOverThisConnection`（libimobiledevice `src/lockdown.c` 映射为 `LOCKDOWN_E_PAIRING_PROHIBITED_OVER_THIS_CONNECTION`），通过非 USB 连接发 `Pair` 请求时会返回它。LocalDevVPN 的 `10.7.0.1` 回环在 lockdownd 看来是网络连接。libimobiledevice 还写明：无线配对需要 CU pairing，而「目前只有 Apple TV 支持」。
2. **RemotePairing 的 pair-setup 同样不对陌生主机开放。** 网络上的 `_remotepairing._tcp`（LoopCtrl 挂载时连的 `10.7.0.1:49152`）对已信任的主机做 pair-verify，iPhone 在 iOS 27 之前不提供手动 PIN 配对。pymobiledevice3 的文档也说「remote pair 只用于 Apple TV、Corellium 等，普通 iOS 设备不需要」，因为普通设备都是通过 USB 建立信任的。USB 上的 `untrusted.tunnelservice` 也是先经过 lockdown 信任（CoreDeviceProxy 需要已配对的 lockdown 会话）才能访问。
3. **旁证：所有同类工具都要求先连一次电脑。** SideStore、StikDebug 都要求用 iLoader 或 jitterbugpair 生成配对文件；StikPair 和 LoopCtrl 自己的设备内配对都写明只支持 iOS 27 及以上。

⚠️ **真机验证方法（建议在实现前做，大约半小时）：**

- 在 LoopCtrl 内通过 LocalDevVPN 隧道向 `10.7.0.1:62078` 发送 lockdown `Pair`，预期返回 `PairingProhibitedOverThisConnection`。
- 用一台从未信任过任何电脑的 iOS 17/18/26 设备，运行 idevice 的 `pair_rsd_ios --wifi-pair`，预期被拒绝或根本搜不到服务。

## 4. 配对文件在什么情况下失效

| 事件 | RP / lockdown 配对文件 | 说明 |
|---|---|---|
| 重启 | ✅ 仍然有效 | 只有 DDI 挂载需要重做，在 App 内完成 |
| 关闭再打开开发者模式 | ✅ 一般仍然有效 | 关闭期间不能挂载 |
| iOS 小版本更新 | ⚠️ 通常有效，**偶尔失效** | Impactor 文档写的是 "sometimes"；社区建议升级后如果挂载失败就重新生成 |
| iOS 大版本更新 | ⚠️ 同上，概率更高 | 而且 26.4 起 DDI 改成了 cryptex，挂载方式本身也变了（LoopCtrl 已处理） |
| 设置 › 通用 › 传输或还原 › 还原位置与隐私 | ❌ 失效 | 会清除所有已信任的电脑 |
| 开发者设置 › 清除受信任的电脑 | ❌ 失效 | |
| 抹掉所有内容、恢复固件 | ❌ 失效 | |
| 删除 LoopCtrl 后重装 | ❌ 文件随 App 容器一起删除 | 手机上的信任还在，但电脑端得重新写一次。可以在电脑端缓存 RP 文件（Impactor 就这样做），重写时不用再点信任 |

所以 App 内需要：挂载失败时区分出「配对文件被拒绝」，并提示用户「重新连接电脑运行配对助手」。

## 5. Windows 需要什么

- **Apple Mobile Device Service**（usbmuxd 的 Windows 实现，加 USB 驱动）。它来自 Microsoft Store 上的 **Apple Devices** App（Windows 10/11 推荐），或者旧版 iTunes。助手启动时检测 `127.0.0.1:27015` 是否能连上，连不上就引导用户安装 Apple Devices。我们不能自带或分发苹果的驱动。
- 第一次「信任」后，Windows 会把 lockdown 记录保存在 `%ProgramData%\Apple\Lockdown\`（通过 `save_pair_record`），下次不会再弹窗。
- 不需要管理员权限：`create_software_tunnel` 是用户态 TCP 栈，不建网卡。
- macOS 不需要额外安装任何东西。Linux 需要 usbmuxd 包，如果以后要支持的话。

## 6. 签名和安装：最大的风险

配对本身是开放协议，但「同一步装好 App」要求 IPA 已经为这台设备签名。LoopCtrl 依赖 XCTest 和 testmanagerd，**必须是开发签名**（带 `get-task-allow`），因此 App Store、TestFlight、企业证书都不行（企业证书对外分发也违反苹果协议）。现实的选项有三个：

| 方案 | 有效期 | 设备数 | 代价 |
|---|---|---|---|
| A. 我方开发者账号统一签名：助手读取 UDID → 服务端用 App Store Connect API 注册设备、生成描述文件、重签 → 下发 IPA | 1 年 | 每个账号每年 100 台 iPhone | 需要一个签名服务端；设备数量受限，多个账号可以扩容但有合规风险 |
| B. 客户用自己的 Apple ID（免费账号）签名，Impactor 或 AltServer 就是这个模式 | **7 天** | 每个账号 3 个 App | 每周都要重签，「一次之后只用手机」的体验就不成立了；还要处理 Apple ID 登录和双重认证，必须用官方登录流程，不能代填密码 |
| C. 客户有付费开发者账号 | 1 年 | 100 台 | 普通客户不现实 |

建议：面向客户时用 A。助手负责完成注册、签名、安装、配对，客户只做插线和点信任。到期前 App 内提醒，再连一次电脑续签。这一部分要单独评估苹果的条款和法务风险，不在本文范围内。

## 7. iOS 16 和 17.0–17.3

**更正：** 本文早先的版本建议放弃 iOS 16，理由是「每次重启都要连电脑重新挂 DDI」。这是错的：DDI 挂载在**所有** iOS 版本上都不会跨重启保留，17+ 同样每次重启后要在 App 内重新挂载。只要 iOS 16 也能在设备内挂载，「一次之后只用手机」对 iOS 16 同样成立，所以重启不是放弃 iOS 16 的理由。

**iOS 16 真正的缺口有两个：**

1. **设备内挂载路径——已补上。** iOS 16 没有 `remoted` / RSD，挂载改走同一个 LocalDevVPN / Shadowrocket 回环上的 lockdownd（`10.7.0.1:62078`）：用 lockdown 配对记录建立会话 → 启动 `com.apple.mobile.mobile_image_mounter` → 上传并挂载旧版 `DeveloperDiskImage.dmg` 和 `.signature`（`ImageType = Developer`）。这就是 SideStore、StikDebug 当年在 iOS 16 上配合 jitterbugpair 文件的做法。实现见 `DDIMounter.performLegacyMount`、`DeveloperDiskImageStore.MountMethod.legacy`；镜像从 doronz88/DeveloperDiskImage 的 `DeveloperDiskImages/16.x/` 下载（16.0–16.7 都有），也可以从 Xcode 14 的 `DeviceSupport/16.x/` 取。`PairingFileStore` 在 iOS 16 上接受 lockdown 记录，17+ 仍然要求 RP 记录。⚠️ 还没有在 iOS 16 真机上跑过。
2. **进程内 XCTest 启动——未验证。** iOS 16 上 XCTest 走 KVC 构造配置那条路径，一直没有真机验证（见 `docs/runner-merge-spike.md` 第 9 项）。这一项不通过，挂载成功也跑不起来。

所以 iOS 16 的结论是「保留，等真机验证」，而不是放弃。电脑端助手在 iOS 16 上只需要做 lockdown 配对并写入 lockdown 记录，不需要 CoreDeviceProxy。

**17.0–17.3（调研结论，⚠️ 未实现、未验证）：** 这几个版本没有 lockdown 服务 `CoreDeviceProxy`，所以在 USB 上生成 RP 记录需要 USB 网卡加 QUIC 隧道（Windows 上没有官方支持）；设备内用 RP 记录连 `remoted` 也没有社区验证。但 lockdown 这条路很可能走得通：

- pymobiledevice3 v11.19.0 的发布说明写明，17.0–17.3.1 仍然在普通 USB lockdown 上挂载 PersonalizedDMG，不需要隧道。也就是说，image mounter 服务在 17.0–17.3 上可以通过 lockdownd 访问，个性化挂载（TSS 签名）也不依赖 RSD。
- SideStore 在 17.0–17.3 上用 lockdown 配对文件经回环访问 lockdownd 侧载，这几个版本上坏掉的只是 JIT（需要 RSD 隧道），不是 lockdown 连接。
- idevice v0.1.68 已经有对应接口：`image_mounter_connect`（TCP provider，走 lockdownd）加 `image_mounter_mount_personalized_with_callback`（基于 provider 的个性化挂载）。

因此 17.0–17.3 可以复用这次的 lockdown 连接代码，再接个性化镜像，就能和 iOS 16 一样只用 lockdown 记录。本次没有实现这一项（`mountMethod` 在 17.0–17.3 仍然走 RP），需要一台 17.0–17.3 的设备验证后再决定。

建议同步修改：README 和 App 内的系统要求说明；`PairingFileStore` 的提示不再推荐 StikPair（其许可证禁止商用），改为推荐我们自己的配对助手。

## 8. 待解决的风险

1. ⚠️ 第 3 节的两项真机验证还没做。iOS 16 的挂载和 XCTest 启动（第 7 节）也还没做。
2. ⚠️ 新版 idevice 改了 `RemotePairingClient::new` 的签名（Impactor 用的 rev 已经把 `&mut RpPairingFile` 作为参数）。电脑端工具和 App 内的 xcframework（v0.1.68 + 补丁）最好用同一个版本，避免 RP 文件格式出现差异。
3. ⚠️ iOS 大版本更新可能让配对文件失效（第 4 节），需要实测 26.x → 27 的情况。
4. 苹果可能在新版本 iOS 收紧 CoreDeviceProxy 或 untrusted tunnelservice。我们和 Xcode 走的是同一条路，风险和整个社区相同。
5. 签名分发方案（第 6 节）的合规性和设备数量上限。
6. Windows 上 Apple Devices App 的安装引导，以及与 iTunes 共存时的驱动问题。
7. 电脑端缓存的 RP 文件等同于这台手机的调试凭据，要放在用户目录下并设置 0600 权限，不能上传到服务端。

## 9. 建议的实现顺序

1. 先做第 3 节的真机验证，以及用 idevice 的 `rppairing pair` 命令行在 Windows 和 macOS 上各跑一次，确认生成的文件 LoopCtrl 能直接挂载。
2. LoopCtrl App 侧：实现投递位置的导入，以及「配对文件被拒绝」的识别和提示。
3. 电脑端 CLI：配对、写入、校验三步（不含安装）。可以参考 Impactor 的 `plume_utils/src/device.rs`（MIT，引用要保留版权声明）。
4. 套一层 GUI（Impactor 用 iced，可以参考），做好 Windows 和 macOS 的打包与签名。
5. 最后接入签名服务端（方案 A），实现「安装 + 配对」一步完成。

## 参考

- idevice v0.1.68：`tools/src/pair.rs`、`tools/src/rppairing.rs`、`tools/src/pair_rsd_ios.rs`、`idevice/src/services/house_arrest.rs`、`idevice/src/usbmuxd/mod.rs`
- Impactor（MIT）：<https://github.com/claration/Impactor>，`crates/plume_utils/src/device.rs`、`crates/plume_utils/src/signer.rs`
- Impactor 配对文件说明：<https://mintlify.wiki/claration/Impactor/concepts/pairing-files>
- libimobiledevice `src/lockdown.c`（`PairingProhibitedOverThisConnection`）：<https://github.com/libimobiledevice/libimobiledevice/blob/master/src/lockdown.c>
- libimobiledevice lockdown API 文档（CU pairing 仅 Apple TV）：<https://libimobiledevice.org/docs/libimobiledevice/latest/>
- pymobiledevice3（17.4+ lockdown tunnel）：<https://pypi.org/project/pymobiledevice3/>
- pymobiledevice3 v11.19.0 发布说明（17.0–17.3.1 在 USB lockdown 上挂载 PersonalizedDMG）：<https://newreleases.io/project/github/doronz88/pymobiledevice3/release/v11.19.0>
- 旧版 DDI 镜像（16.0–16.7）：<https://github.com/doronz88/DeveloperDiskImage/tree/main/DeveloperDiskImages>
- StikDebug README（17.4+ 支持范围）：<https://github.com/StephenDev0/StikDebug>
