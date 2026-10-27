# LoopCtrl 配对助手 · Android

用 OTG 数据线把 iPhone 连到安卓手机，完成和电脑版一样的配对：信任、开发者模式、生成记录、写入 LoopCtrl、校验。一台或多台走同一个流程：插上的 iPhone 自动列出，点「开始配对」后一起开始。

原生 Jetpack Compose + [miuix](https://github.com/compose-miuix-ui/miuix) 界面（`app/`），通过 UniFFI 桥（`bridge/`）调用和桌面版同一个 `pair-core`。安卓上没有 usbmuxd，所以 App 里自带一个（`../crates/usbmux`，来自 iloader 的 Android 移植，MIT）：

```
UsbHost.kt ──fd──▶ bridge: attach_usb_device ──▶ usbmux::Hub (usbfs 批量传输)
                                                     │
pair-core RealBackend ──usbmuxd 协议──▶ 私有 unix socket (files/usbmuxd.sock, 0600)
```

pair-core 完全不知道自己在安卓上：它连的是这个内置 usbmuxd，配对记录由内置 usbmuxd 存在 `files/lockdown/`，生成的记录缓存在 `files/pair/`，都在 App 私有目录里，不上传。

## 构建

需要 JDK 21、Android SDK 和 NDK `28.2.13676358`（`local.properties` 或 `ANDROID_HOME`）、Rust 及 `aarch64-linux-android`、`armv7-linux-androideabi`、`x86_64-linux-android` 三个 target。`CARGO_HOME` 若是符号链接，要设成真实路径（uniffi 的绑定生成器按路径找模板）。

```bash
cd android && ./gradlew :app:assembleDebug
```

- `-PrustAbis=arm64-v8a`：只编一个 ABI，本地调试快很多。
- `-Pmock=true`：启动即进入模拟设备模式（pair-core 的 MockBackend），模拟器上可以走完整流程。调试版的「设置 › 开发者选项」也能切换。

```bash
cd android && ./gradlew :app:testDebugUnitTest
```

Gradle 自己完成 Rust 部分：`buildRustLibs<Variant>` 按 ABI 用 NDK clang 编译 `loopctrl-pair-bridge`，`generateBindings<Variant>` 用桥里的 `uniffi-bindgen` 从 `.so` 生成 Kotlin 绑定（不入库）。

## 目录

- `bridge/`：`PairBridge`（UniFFI 对象）。启动内置 usbmuxd 和 pair-core 管理器；设备视图、事件、环境检查以 pair-core 的 JSON 形状传给 Kotlin。
- `app/.../core/`：`PairCore`（桥的 Kotlin 包装）和 JSON 模型。
- `app/.../platform/UsbHost.kt`：`UsbManager` 广播、USB 权限、选择带 usbmux 接口的配置、认领接口、把 fd 交给桥（来自 iloader，MIT）。
- `app/.../ui/`：和桌面版同样的单页流程（`PairScreen`：设备列表、每台的操作提示和五步进度、底部开始/停止/完成按钮；另有设置页），状态规则同 `ui/src/lib/store.svelte.ts`。

## 已验证 / 未验证

- ✅ arm64 / armv7 / x86_64 三个 ABI 编译、打包；Kotlin 单元测试；`usbmux` 97 个测试。
- ✅ arm64 模拟器（Android 13）上：内置 usbmuxd 启动正常；无 OTG 时的环境提示；模拟设备 1 台和 5 台走完开始、信任、开发者模式、重启、出错重试、停止、完成；中英文。
- ⚠️ 真机未验证：没有用安卓手机 + 真 iPhone 跑过。USB 权限、配置切换、usbfs 传输、信任弹窗、写入 LoopCtrl 都要在真机上确认。内置 usbmuxd 本身在 iloader 里用真机跑通过。
- ⚠️ 发布签名、商店上架未做。
