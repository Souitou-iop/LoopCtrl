# LoopCtrl 配对助手（LoopCtrl Pair）

iOS 27 以下的 iPhone 不能自己完成配对。用数据线把 iPhone 连一次电脑（或一台支持 OTG 的安卓手机），助手会生成 LoopCtrl 需要的配对文件，写进 LoopCtrl 并校验。之后 LoopCtrl 只用手机。

支持 Windows 10/11、macOS 12+、Linux（x86_64 / aarch64，桌面版和命令行）和 Android 8+（需要 USB 主机 / OTG），iPhone 需要 iOS 16 或更高版本。Android 版见 [android/README.md](android/README.md)。

## 做什么

1. **环境检查**：Windows 上检查 Apple Mobile Device Service（127.0.0.1:27015），没有就引导从 Microsoft Store 安装 Apple Devices；macOS 用系统自带的 usbmuxd；Linux 优先用系统 usbmuxd，没有就用内置的（见下文「Linux」）。
2. **识别 iPhone**：只认 USB 连接，显示设备名和 iOS 版本。
3. **信任**：等待用户在 iPhone 上点「信任」，识别「不信任」和锁屏，配对记录保存到 usbmuxd。
4. **开发者模式**：读取状态；未开启时自动显示隐藏的开关，引导打开、等重启、确认「打开」。
5. **生成记录**：iOS 17.4+ 生成 RemotePairing 记录（`remotepairingdeviced.lockdown`，不行再走 CoreDeviceProxy），并合并 lockdown 记录；iOS 16 和 17.0–17.3 用 lockdown 记录。同时打开 `EnableWifiDebugging`。记录按 UDID 缓存在本机（0600），不上传。
6. **找到 LoopCtrl** 并**写入** `Documents/.pairing-dropbox/pairingFile.plist`（约定见 [docs/handoff.md](docs/handoff.md)）。
7. **校验**：17.4+ 做 RP pair-verify，iOS 16 建立一次 lockdown 会话。
8. **批量**：带供电的集线器上多台 iPhone 各自独立进行。

界面默认简体中文，可切换英文；外观为 miuix / HyperOS 风格，跟随系统深浅色。

## Linux

Linux 上有两种方式连接 iPhone，助手自动选择（`LOOPCTRL_PAIR_MUX=auto|system|builtin` 或命令行 `--mux` 可以指定）：

| 方式 | 什么时候用 | 需要 |
|---|---|---|
| **系统 usbmuxd** | 装了 `usbmuxd` 包（正在运行，或插上 iPhone 时由 udev 启动）就优先用它 | 自己用包管理器安装，例如 `sudo apt install usbmuxd`。助手不附带它（GPL） |
| **内置 usbmuxd** | 没装系统 usbmuxd 时 | 直接通过 usbfs 访问 `/dev/bus/usb`，需要安装 udev 规则 |

udev 规则（`packaging/linux/70-loopctrl-pair.rules`，Apple 厂商号 05ac、usbmux 设备）让当前登录用户（`uaccess`）和 `plugdev` 组可以读写 iPhone。`.deb` 安装时会自动装好；只用命令行时，在助手的环境检查里点「安装」（通过 pkexec 要系统密码），或者手动安装：

```bash
loopctrl-pair udev-rule | sudo tee /etc/udev/rules.d/70-loopctrl-pair.rules
```

```bash
sudo udevadm control --reload-rules && sudo udevadm trigger
```

装好后拔掉 iPhone 再插上。没有权限时，环境检查会显示「USB 访问：被拒绝」并弹出说明；系统 usbmuxd 抢占了 iPhone 时会提示冲突，点「重新检测」就改用系统 usbmuxd。

Linux 用 `.deb`（桌面版，Debian / Ubuntu 22.04+ 等）或命令行压缩包安装，不提供 AppImage（它会把 LGPL 的 GTK / WebKitGTK 打包进去）。桌面版需要 WebKitGTK 4.1，`.deb` 会自动安装依赖：

```bash
sudo apt install ./LoopCtrl-Pair-0.1.1-linux-amd64.deb
```

## 命令行（无界面）

`loopctrl-pair` 用同一个 pair-core，适合自助机、树莓派和外接硬件。Linux、macOS、Windows 都有，发布页的 `loopctrl-pair-cli-*` 压缩包里。

```bash
loopctrl-pair devices                # 列出 USB 连接的 iPhone
loopctrl-pair pair                   # 完整流程：信任、开发者模式、生成、写入 LoopCtrl、校验
loopctrl-pair pair --all             # 批量：现在和之后插上的每台 iPhone，直到 Ctrl-C
loopctrl-pair pair --udid <UDID> --out pairingFile.plist   # 指定手机，另存一份配对文件
loopctrl-pair write --udid <UDID>    # 把缓存的配对文件重新写入 LoopCtrl（或 --file 指定）
loopctrl-pair verify --udid <UDID>   # 校验手机是否接受配对文件
loopctrl-pair env                    # 环境检查（usbmuxd、内置模式、udev 规则、USB 访问）
loopctrl-pair udev-rule              # 输出 udev 规则
```

- `--json`：机器可读输出（`pair` 每行一个事件，最后一行是结果）。
- `--mock`：模拟 iPhone，不需要硬件，例如 `loopctrl-pair pair --mock`。
- `--mux auto|system|builtin`、`--bridge-listen 0.0.0.0:27100`（接受外接 USB 桥，见 [docs/hardware-helpers.md](docs/hardware-helpers.md)）。
- 退出码：0 成功，1 失败，2 参数错误，3 没有 usbmuxd / 没有 USB 权限，4 超时。
- 数据目录和桌面版相同（Linux：`~/.local/share/app.loopctrl.pair`），可用 `--data-dir` 指定。中文环境（`LANG=zh_*`）输出中文。

在树莓派上无人值守运行时，把运行用户加入 `plugdev` 组（udev 规则对没有登录会话的进程用这个组授权）。

## 外接硬件

ESP32-S3 之类的单片机当 iPhone 的 USB 主机、通过 Wi-Fi 把 usbmux 转给运行 pair-core 的电脑：设计和协议见 [docs/hardware-helpers.md](docs/hardware-helpers.md)。电脑端已实现并测试，固件尚未编写。

## 开发

需要 Rust 1.85+、bun（或 pnpm）。Windows 还需要 WebView2 和 Apple Devices；Linux 需要 `libwebkit2gtk-4.1-dev` 等 Tauri 依赖（见 [.github/workflows/ci.yml](.github/workflows/ci.yml) 里的 `LINUX_DEPS`）。

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

```bash
cargo run -p loopctrl-pair-cli -- pair --mock
```

发布由 CI 完成：推送 `v*` 标签后，GitHub Actions 构建 Linux（x86_64、aarch64）、macOS、Windows、Android 安装包和命令行压缩包，附到 Release 上。

结构见 [docs/architecture.md](docs/architecture.md)。核心在 `crates/pair-core`，不依赖 Tauri，桌面版、命令行和 Android 版共用；`crates/pair-host` 决定用哪个 usbmuxd。

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。第三方组件见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。底层用的是 [idevice](https://github.com/jkcoxson/idevice)（MIT）。不包含 usbmuxd、libusb、libimobiledevice 等 GPL/LGPL 代码；Linux 上的系统 usbmuxd 只在用户自己安装后使用。内置 usbmuxd（`crates/usbmux`，Android 和 Linux 使用）和 Android 的 USB 主机代码来自 [iloader](https://github.com/nab138/iloader) 的 Android 移植（MIT）。桌面界面参照 [miuix](https://github.com/compose-miuix-ui/miuix)（Apache-2.0）的设计取值用 CSS 重做，Android 版直接使用 miuix；不含小米的字体、图标或标志。与 Apple、小米无关。

---

## English

LoopCtrl Pair is the one-time USB pairing tool for LoopCtrl on iPhones below iOS 27, which cannot start pairing by themselves. Plug the iPhone into a Windows, macOS or Linux computer, or an Android phone with USB OTG (see [android/README.md](android/README.md)), once: the tool pairs (Trust), checks and guides Developer Mode, creates the pairing record (RemotePairing + lockdown on iOS 17.4+, lockdown only on iOS 16 and 17.0–17.3), writes it into LoopCtrl (`Documents/.pairing-dropbox/pairingFile.plist`, see [docs/handoff.md](docs/handoff.md)) and verifies it. Batch mode pairs several iPhones on a powered hub in parallel.

**Linux.** The app uses the system usbmuxd when it runs or is installed (`sudo apt install usbmuxd`; it is GPL and never bundled), and otherwise its own built-in usbmuxd over usbfs, which needs the udev rule `packaging/linux/70-loopctrl-pair.rules` (Apple VID 05ac; `uaccess` for the desktop user, `plugdev` for headless use). Linux ships as a .deb (desktop app) or the CLI tarball; there is no AppImage, which would bundle LGPL GTK/WebKitGTK. The .deb installs the rule; otherwise click Install in the environment check (pkexec) or run `loopctrl-pair udev-rule | sudo tee /etc/udev/rules.d/70-loopctrl-pair.rules` and `sudo udevadm control --reload-rules && sudo udevadm trigger`, then replug. Denied USB access and a usbmuxd that holds the iPhone are explained on screen. Force a mode with `LOOPCTRL_PAIR_MUX=system|builtin`.

**CLI.** `loopctrl-pair devices | pair [--all] | write | verify | env | udev-rule`, with `--json`, `--udid`, `--file`, `--out`, `--mock`, `--mux`, `--bridge-listen`. Exit codes: 0 ok, 1 failed, 2 usage, 3 no usbmuxd / USB access, 4 timed out. Same data folder as the desktop app. For kiosks and Raspberry Pi; external USB helpers such as an ESP32-S3: [docs/hardware-helpers.md](docs/hardware-helpers.md) (design; host side implemented).

Development: `bun install`, then `bun tauri dev`. Set `LOOPCTRL_PAIR_MOCK=1` to run the whole flow against simulated iPhones. Tests: `cargo test --workspace`. License checks: `cargo deny check licenses bans sources` and `bun run licenses:check`. Local build: `bun tauri build`; releases come from CI on `v*` tags (Linux x86_64/aarch64 .deb and CLI, macOS universal, Windows, Android). Architecture: [docs/architecture.md](docs/architecture.md).

Apache-2.0. Built on [idevice](https://github.com/jkcoxson/idevice) (MIT). No GPL/LGPL code is bundled. The built-in usbmuxd (`crates/usbmux`, Android and Linux) and the Android USB host code come from [iloader](https://github.com/nab138/iloader)'s Android port (MIT). The desktop UI recreates the miuix design language in CSS; the Android app uses miuix itself. No Xiaomi fonts or logos are included. Not affiliated with Apple or Xiaomi.
