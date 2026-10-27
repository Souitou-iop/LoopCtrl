# 交接约定：配对文件投递位置（LoopCtrl Pair → LoopCtrl）

版本 1（`FormatVersion = 1`）。LoopCtrl App 侧的导入单独实现，本文是两边共同遵守的约定。代码：`crates/pair-core/src/record.rs`、`crates/pair-core/src/backend/real.rs`（`write_with`）。

## 位置

```
<App 容器>/Documents/.pairing-dropbox/pairingFile.plist
```

- 助手先试 `house_arrest` 的 `VendContainer`（需要 App 带 `get-task-allow`，LoopCtrl 是开发签名，通常可用），失败再试 `VendDocuments`（需要 Info.plist 里 `UIFileSharingEnabled = YES`）。两条路径写到的是同一个文件。
- 写入是原子的：先写 `pairingFile.plist.partial`，删掉旧的 `pairingFile.plist`，再改名。App 只读 `pairingFile.plist`，看到 `.partial` 直接忽略。
- 写完助手会读回比较一次。

## 文件格式

一个 XML plist 字典，顶层就是 idevice 和现有 `PairingFileStore` 能直接解析的键，额外的键都会被忽略：

| 键 | 何时有 | 说明 |
|---|---|---|
| `HostID`、`SystemBUID`、`HostCertificate`、`HostPrivateKey`、`RootCertificate`、`RootPrivateKey`、`DeviceCertificate`、`WiFiMACAddress` | 总是 | lockdown 配对记录（idevice `PairingFile`） |
| `EscrowBag` | 通常 | 同上 |
| `UDID` | 总是 | 这台手机的 UDID |
| `public_key`、`private_key`（各 32 字节）、`identifier` | iOS 17.4+ | RemotePairing 记录（idevice `RpPairingFile`） |
| `alt_irk` | 有时 | 同上 |
| `LoopCtrlPair` | 总是 | 元数据字典，见下 |

`LoopCtrlPair` 字典：

| 键 | 类型 | 说明 |
|---|---|---|
| `FormatVersion` | 整数 | 现在是 `1`。只有旧版 App 会读错的改动才加一 |
| `Kind` | 字符串 | `remotePairing+lockdown`（17.4+）或 `lockdown`（16、17.0–17.3） |
| `HostName` | 字符串 | 助手的 RemotePairing 主机名（`LoopCtrl-Pair-XXXXXX`），`identifier` 由它派生 |
| `ProductVersion` | 字符串 | 生成时手机的 iOS 版本 |
| `RemotePairingVia` | 字符串 | `remotepairingdeviced.lockdown`、`coreDeviceProxy` 或 `cached` |
| `CreatedAt` | 日期 | 生成时间 |
| `Tool` | 字符串 | `LoopCtrl Pair 0.1.0` |

## App 侧应该做的事

1. 启动和回到前台时检查投递位置。
2. 有 `pairingFile.plist` 就交给 `PairingFileStore.store(_:)`：17+ 校验 RP 键，16 校验 lockdown 键（现有逻辑不用改，合并文件两边都能过）。
3. 成功后删除投递文件（AFC 写入的文件没有数据保护等级，打开文件共享时还会在「文件」App 里露出来）。失败也删除，并提示「重新连接电脑运行配对助手」。
4. `FormatVersion` 比 App 认识的大：照常按顶层键导入（顶层格式不变是这个约定的一部分），只是不信任元数据。
5. 识别：助手现在按 bundle ID 后缀 `.loopctrl` 或显示名 `LoopCtrl` 找 App。预留了 Info.plist 键 `LoopCtrlPairingDropbox`（布尔 `YES`），App 加上后助手会优先按它识别，签名者改了 bundle ID 也能找到。

## 版本规则

- 只增加键：`FormatVersion` 不变。
- 顶层键的含义改变、或者文件位置改变：`FormatVersion` 加一，助手同时写旧位置一段时间。
