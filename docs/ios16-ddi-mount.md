# iOS 16 设备内挂载 DDI：实现说明与验证状态

日期 2026-10-17。基于 idevice v0.1.68（`Scripts/build-idevice.sh` + `Patches/idevice`）。

## 流程

iOS 16 没有 `remoted` / RSD，所以走 lockdownd，隧道还是同一个 LocalDevVPN / Shadowrocket 回环：

1. `idevice_pairing_file_read`：读取 lockdown 配对记录。
2. `idevice_tcp_provider_new`：建立指向 `10.7.0.1` 的 TCP provider，lockdownd 端口固定为 62078。
3. `image_mounter_connect`：lockdownd `StartSession`（TLS）→ `StartService com.apple.mobile.mobile_image_mounter` → 连接服务端口，需要时再开 TLS。
4. `image_mounter_lookup_image("Developer")`：如果已经有签名，说明已挂载，直接返回成功。
5. `image_mounter_mount_developer`：先 `ReceiveBytes`，再 `MountImage`，`ImageType = Developer`，带上 `.signature`。

代码在 `DDIMounter.performLegacyMount`。系统版本低于 17 时，`DeveloperDiskImageStore.mountMethod` 返回 `.legacy`，iOS 17+ 的路径没有改动。

## idevice FFI 检查结果

需要的接口都有，不用改补丁。有两处要注意：

- **`image_mounter_connect` 和 `lockdownd_connect` 失败时会自己释放 provider**（`ffi/src/mobile_image_mounter.rs`、`ffi/src/lockdown.rs` 的 `Err` 分支里有 `Box::from_raw(provider)`）。所以调用方在失败后不能再调 `idevice_provider_free`，代码里在失败时把 provider 置空。这是上游的问题，同一模式在 ffi 里出现了 9 处。
- `image_mounter_mount_developer` 没有进度回调，上传期间进度条停在 0。镜像大约 7–8 MB，走回环很快。如果需要进度，可以给 ffi 加一个包装 `upload_image_with_progress` 的补丁。
- `idevice_tcp_provider_new` 成功时会接管配对文件句柄，失败时不会。

## 配对记录

iOS 16 上 `PairingFileStore` 接受 lockdown 记录。idevice 的 `PairingFile` 要求这些键：`DeviceCertificate`、`HostCertificate`、`HostPrivateKey`、`RootCertificate`、`RootPrivateKey`、`SystemBUID`、`HostID`、`WiFiMACAddress`；`EscrowBag` 和 `UDID` 是可选的。导入时会先检查这些键，给出可读的错误信息，再用 `idevice_pairing_file_from_bytes` 实际解析一遍。合并记录（iLoader）也能用。iOS 17+ 仍然只接受 RP 记录，逻辑没变。

## 镜像

从 doronz88/DeveloperDiskImage 的 `DeveloperDiskImages/<major.minor>/` 下载，16.0–16.7 都有。16.7.x 统一用 `16.7`。每个小版本单独放一个目录（`DDI/Legacy-16.x`），升级小版本后会重新下载。也可以手动从 Xcode 14 的 `DeviceSupport/16.x/` 里取。

## 已验证 / 未验证

已验证：
- `LoopCtrlAllInOne` scheme 可以编译通过（generic iOS，Debug，不签名）。
- 镜像地址可以访问（16.4 的 `.signature` 返回 HTTP 200）；16.0–16.7 的目录都存在。
- 对照 idevice v0.1.68 源码确认了上面这些 FFI 调用的行为。

需要 iOS 16 真机：
- lockdownd 能否通过 `10.7.0.1:62078` 回环访问，以及隧道探测（`QueryType` 应答里应该有 `com.apple.mobile.lockdown`）。
- 用 jitterbugpair / idevicepair 生成的记录能否完成 `StartSession`，`StartService` 是否返回 `EnableServiceSSL`，以及 TLS（`legacy` 标志）能否握手。
- 挂载本身能否成功，挂载后 `/Developer/Library/Frameworks/XCTest.framework` 是否出现（`DeveloperDiskImage.status()` 的 `.legacy` 布局）。
- 进程内 XCTest 启动（`docs/runner-merge-spike.md` 第 9 项）。这一项不通过，挂载成功了也没用。

17.0–17.3 的调研结论见 `docs/desktop-pairing-plan.md` 第 7 节：lockdown 路径加个性化镜像很可能可行，但这次没有实现。
