# LoopCtrl 配对助手（LoopCtrl Pair）

iOS 27 以下的 iPhone 不能自己完成配对。用数据线把 iPhone 连一次电脑，助手会生成 LoopCtrl 需要的配对文件，写进 LoopCtrl 并校验。之后 LoopCtrl 只用手机。

支持 Windows 10/11 和 macOS 12+，iPhone 需要 iOS 16 或更高版本。

## 做什么

1. **环境检查**：Windows 上检查 Apple Mobile Device Service（127.0.0.1:27015），没有就引导从 Microsoft Store 安装 Apple Devices；macOS 用系统自带的 usbmuxd。
2. **识别 iPhone**：只认 USB 连接，显示设备名和 iOS 版本。
3. **信任**：等待用户在 iPhone 上点「信任」，识别「不信任」和锁屏，配对记录保存到 usbmuxd。
4. **开发者模式**：读取状态；未开启时自动显示隐藏的开关，引导打开、等重启、确认「打开」。
5. **生成记录**：iOS 17.4+ 生成 RemotePairing 记录（`remotepairingdeviced.lockdown`，不行再走 CoreDeviceProxy），并合并 lockdown 记录；iOS 16 和 17.0–17.3 用 lockdown 记录。同时打开 `EnableWifiDebugging`。记录按 UDID 缓存在本机（0600），不上传。
6. **找到 LoopCtrl** 并**写入** `Documents/.pairing-dropbox/pairingFile.plist`（约定见 [docs/handoff.md](docs/handoff.md)）。
7. **校验**：17.4+ 做 RP pair-verify，iOS 16 建立一次 lockdown 会话。
8. **批量**：带供电的集线器上多台 iPhone 各自独立进行。

界面默认简体中文，可切换英文；外观为 miuix / HyperOS 风格，跟随系统深浅色。

## 开发

需要 Rust 1.85+、bun（或 pnpm）。Windows 还需要 WebView2 和 Apple Devices。

```bash
bun install
```

```bash
bun tauri dev
```

不接 iPhone 演示完整流程（模拟设备）：

```bash
LOOPCTRL_PAIR_MOCK=1 bun tauri dev
```

调试版的「设置 › 开发者选项」里也能随时切换模拟设备。

```bash
cargo test --workspace
```

```bash
cargo clippy --workspace --all-targets
```

```bash
cargo deny check licenses bans sources
```

```bash
bun run licenses:check
```

```bash
bun tauri build
```

结构见 [docs/architecture.md](docs/architecture.md)。核心在 `crates/pair-core`，不依赖 Tauri，以后的命令行版和 Android（OTG）版复用它。

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。第三方组件见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。底层用的是 [idevice](https://github.com/jkcoxson/idevice)（MIT）。界面参照 [miuix](https://github.com/compose-miuix-ui/miuix)（Apache-2.0）的设计取值用 CSS 重做，不含小米的字体、图标或标志。与 Apple、小米无关。

---

## English

LoopCtrl Pair is the one-time USB pairing tool for LoopCtrl on iPhones below iOS 27, which cannot start pairing by themselves. Plug the iPhone into a Windows or macOS computer once: the tool pairs (Trust), checks and guides Developer Mode, creates the pairing record (RemotePairing + lockdown on iOS 17.4+, lockdown only on iOS 16 and 17.0–17.3), writes it into LoopCtrl (`Documents/.pairing-dropbox/pairingFile.plist`, see [docs/handoff.md](docs/handoff.md)) and verifies it. Batch mode pairs several iPhones on a powered hub in parallel.

Development: `bun install`, then `bun tauri dev`. Set `LOOPCTRL_PAIR_MOCK=1` to run the whole flow against simulated iPhones. Tests: `cargo test --workspace`. License checks: `cargo deny check licenses bans sources` and `bun run licenses:check`. Release: `bun tauri build`. Architecture: [docs/architecture.md](docs/architecture.md).

Apache-2.0. Built on [idevice](https://github.com/jkcoxson/idevice) (MIT). The UI recreates the miuix design language in CSS; no Xiaomi fonts or logos are included. Not affiliated with Apple or Xiaomi.
