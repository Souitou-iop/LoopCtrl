//! What the CLI prints for people: Simplified Chinese when the locale says
//! so (LANG / LC_ALL / LC_MESSAGES starting with "zh"), English otherwise.

use std::path::Path;

use pair_core::{DeviceView, EnvReport, ErrorCode, Phase};

pub struct Text {
    pub no_devices: &'static str,
    pub unsupported: &'static str,
    pub verified: &'static str,
    pub written: &'static str,
    pub using: &'static str,
    pub waiting: &'static str,
    pub timed_out: &'static str,
    pub usbmux_down: &'static str,
    zh: bool,
}

const ZH: Text = Text {
    no_devices: "没有通过 USB 连接的 iPhone。",
    unsupported: "iOS 版本过低（需要 16+）",
    verified: "✓ 校验通过：",
    written: "✓ 已写入 LoopCtrl：",
    using: "usbmuxd：",
    waiting: "请用数据线连接 iPhone…",
    timed_out: "超时，已停止。",
    usbmux_down: "usbmuxd 不可用：",
    zh: true,
};

const EN: Text = Text {
    no_devices: "No iPhone connected over USB.",
    unsupported: "iOS too old (16+ needed)",
    verified: "✓ Verified:",
    written: "✓ Written into LoopCtrl:",
    using: "usbmuxd:",
    waiting: "Connect the iPhone with a cable…",
    timed_out: "Timed out; stopped.",
    usbmux_down: "usbmuxd unavailable:",
    zh: false,
};

pub fn pick() -> &'static Text {
    let zh = ["LC_ALL", "LC_MESSAGES", "LANG"]
        .iter()
        .filter_map(|k| std::env::var(k).ok())
        .find(|v| !v.is_empty())
        .is_some_and(|v| v.starts_with("zh"));
    if zh {
        &ZH
    } else {
        &EN
    }
}

impl Text {
    fn s(&self, zh: &'static str, en: &'static str) -> &'static str {
        if self.zh {
            zh
        } else {
            en
        }
    }

    pub fn error_title(&self, code: ErrorCode) -> &'static str {
        use ErrorCode::*;
        match code {
            NoDriver => self.s("未安装 Apple Devices", "Apple Devices is not installed"),
            NoUsbmux => self.s("无法连接 usbmuxd", "Can't reach usbmuxd"),
            Untrusted => self.s("iPhone 没有信任这台电脑", "The iPhone did not trust this computer"),
            DevModeCancelled => self.s("开发者模式没有打开", "Developer Mode was not turned on"),
            RebootTimeout => self.s("iPhone 重启后没有重新连接", "The iPhone did not come back after restarting"),
            Unsupported => self.s("iOS 版本过低", "iOS version not supported"),
            RecordFailed => self.s("生成配对文件失败", "Could not make the pairing file"),
            AppNotFound => self.s("没有找到 LoopCtrl", "LoopCtrl is not installed"),
            WriteFailed => self.s("写入 LoopCtrl 失败", "Writing into LoopCtrl failed"),
            VerifyFailed => self.s("校验失败", "Verification failed"),
            Disconnected => self.s("iPhone 已断开", "The iPhone is disconnected"),
            Internal => self.s("出错了", "Error"),
        }
    }

    pub fn error_hint(&self, code: ErrorCode) -> Option<&'static str> {
        use ErrorCode::*;
        Some(match code {
            NoUsbmux => self.s(
                "Linux：安装 usbmuxd，或安装 udev 规则后用内置模式（loopctrl-pair env 查看详情）。",
                "Linux: install usbmuxd, or install the udev rule and use built-in mode (see `loopctrl-pair env`).",
            ),
            Untrusted => self.s("拔掉重插，在 iPhone 上点「信任」。", "Replug and tap Trust on the iPhone."),
            AppNotFound => self.s("先在这台 iPhone 上安装 LoopCtrl。", "Install LoopCtrl on this iPhone first."),
            Disconnected => self.s("用数据线直接连接 iPhone 后重试。", "Connect the iPhone directly and try again."),
            _ => return None,
        })
    }

    fn phase(&self, d: &DeviceView) -> &'static str {
        match d.phase {
            Phase::Detected => self.s("已识别", "detected"),
            Phase::Trusting if d.locked => self.s("iPhone 已锁定，请先解锁", "the iPhone is locked: unlock it"),
            Phase::Trusting => self.s(
                "等待信任：在 iPhone 上点「信任」并输入锁屏密码",
                "waiting for Trust: tap Trust on the iPhone and enter the passcode",
            ),
            Phase::CheckingDevMode => self.s("检查开发者模式", "checking Developer Mode"),
            Phase::RevealingDevMode => self.s("显示开发者模式开关", "revealing the Developer Mode switch"),
            Phase::DevModeGuide => self.s(
                "请在 iPhone 上打开「设置 › 隐私与安全性 › 开发者模式」，打开后点「重新启动」",
                "on the iPhone: Settings › Privacy & Security › Developer Mode → on → Restart",
            ),
            Phase::Rebooting => self.s("等待 iPhone 重启", "waiting for the iPhone to restart"),
            Phase::ConfirmingDevMode => {
                self.s("重启后解锁 iPhone，在弹窗里点「打开」", "after the restart, unlock the iPhone and tap Turn On")
            }
            Phase::Generating => self.s("生成配对文件", "making the pairing file"),
            Phase::FindingApp => self.s("查找 LoopCtrl", "looking for LoopCtrl"),
            Phase::Writing => self.s("写入 LoopCtrl", "writing into LoopCtrl"),
            Phase::Verifying => self.s("校验", "verifying"),
            Phase::Done => self.s("✓ 完成", "✓ done"),
            Phase::Failed => self.s("✗ 失败", "✗ failed"),
        }
    }
}

pub fn print_view(t: &Text, d: &DeviceView) {
    let name = d.info.as_ref().map(|i| format!("{} · iOS {}", i.name, i.ios)).unwrap_or_default();
    let unplugged = if d.connected { "" } else { t.s("（已断开）", " (unplugged)") };
    println!("[{}] {}{} {}", short(&d.udid), t.phase(d), unplugged, name);
    if d.phase == Phase::Failed {
        if let Some(e) = &d.error {
            println!("    {}: {}", t.error_title(e.code), e.detail);
            if let Some(h) = t.error_hint(e.code) {
                println!("    {h}");
            }
        }
    }
    if d.phase == Phase::Done {
        let app = d.app.as_ref().map(|a| a.bundle_id.as_str()).unwrap_or("?");
        let json = |v: &dyn erased::Json| v.json();
        let kind = d.record_kind.map(|k| json(&k)).unwrap_or_default();
        let via = d.rp_via.map(|v| format!(" ({})", json(&v))).unwrap_or_default();
        let write = d.write_via.map(|w| json(&w)).unwrap_or_default();
        println!("    {kind}{via} → {app} [{write}]");
    }
}

fn short(udid: &str) -> &str {
    &udid[udid.len().saturating_sub(8)..]
}

pub fn print_env(t: &Text, r: &EnvReport, data_dir: &Path) {
    let yes = |b: bool| if b { t.s("是", "yes") } else { t.s("否", "no") };
    println!("{} {} {}", t.s("系统：", "OS:"), r.os, r.os_version);
    println!(
        "usbmuxd: {} ({}, {})",
        if r.usbmux_ok { t.s("正常", "ok") } else { t.s("不可用", "unavailable") },
        r.transport,
        r.usbmux_addr
    );
    if let Some(d) = &r.detail {
        println!("  {d}");
    }
    if let Some(l) = &r.linux {
        println!("{} {}", t.s("系统 usbmuxd 已安装：", "System usbmuxd installed:"), yes(l.usbmuxd_installed));
        println!("{} {}", t.s("系统 usbmuxd 运行中：", "System usbmuxd running:"), yes(l.usbmuxd_running));
        println!("{} {}", t.s("内置 usbmuxd：", "Built-in usbmuxd:"), yes(l.built_in));
        println!("{} {}", t.s("udev 规则已安装：", "udev rule installed:"), yes(l.udev_rule));
        if l.built_in {
            let access = match l.usb_access {
                None => t.s("（没有连接 iPhone）", "(no iPhone connected)"),
                Some(true) => t.s("正常", "ok"),
                Some(false) => t.s(
                    "被拒绝：安装 udev 规则（loopctrl-pair udev-rule），然后重插 iPhone",
                    "denied: install the udev rule (loopctrl-pair udev-rule), then replug the iPhone",
                ),
            };
            println!("{} {access}", t.s("USB 访问：", "USB access:"));
        }
        match l.conflict.as_deref() {
            Some("systemTookDevice") => println!(
                "{}",
                t.s(
                    "冲突：系统 usbmuxd 占用了 iPhone。改用 --mux system，或停止 usbmuxd。",
                    "Conflict: the system usbmuxd holds the iPhone. Use --mux system, or stop usbmuxd."
                )
            ),
            Some(_) => println!(
                "{}",
                t.s(
                    "冲突：另一个程序占用了 iPhone 的 USB 接口。",
                    "Conflict: another program holds the iPhone's USB interface."
                )
            ),
            None => {}
        }
    }
    println!("{} {}", t.s("数据目录：", "Data folder:"), data_dir.display());
}

mod erased {
    /// serde's camelCase name of a unit enum value ("remotePairing").
    pub trait Json {
        fn json(&self) -> String;
    }
    impl<T: serde::Serialize> Json for T {
        fn json(&self) -> String {
            serde_json::to_value(self).ok().and_then(|v| v.as_str().map(str::to_owned)).unwrap_or_default()
        }
    }
}
