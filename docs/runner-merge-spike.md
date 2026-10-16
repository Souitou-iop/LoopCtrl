# 可行性验证：把 XCUITest Runner 合并进 LoopCtrl App

> 分支 `claude/runner-merge-spike-65b04f`。结论基于对 Xcode 27.1（XCTest-25228）以及
> 本机 iOS 27 Developer Disk Image 中二进制的反汇编和字符串分析，外加一次能编译通过的原型。
> **没有在真机上运行过。** 下文标注 ✅ 的是在 Mac 上已经验证过的，标注 ⚠️ 的是推断、尚未上机验证的。

## 结论：可行，但有几点需要注意

可以把 Runner 合并进 LoopCtrl，做成**一个**安装的 App。这样免费 Apple ID 的 3 个侧载名额里，
LoopCtrl 只占 1 个（SideStore + LoopCtrl，空出一个），每 7 天也少注册一个 App ID。

做法如下：主可执行文件用 LoopCtrl 自己的 SwiftUI App，**不链接 XCTest**，所以即使没挂载 DDI
（比如重启之后）也能正常启动。`LoopCtrlUITests.xctest` 放进 `LoopCtrl.app/PlugIns/`；DDI 挂载之后，
由 App 自己 `dlopen` XCTest，再执行 Runner 存根原本做的那两步，在当前进程里启动测试。

需要注意的几点（后面分别展开）：

1. **XCTest 每个进程只能启动一次**，而测试结束时 XCTest 会调用 `exit()`。所以「停止服务器」
   会把整个 LoopCtrl 一起关掉，要再启动只能重新打开 App。如果想要「停止后在 App 内再启动」，
   需要另外改造（让测试不退出，只重启 `JSONRPCServer`）。
2. **UI 和测试共用主线程。** 测试方法在主线程上跑 `distantFuture` 嵌套 run loop，SwiftUI 界面
   就在这个嵌套 run loop 里继续响应。理论上可行，但 XCTest 做快照之类的慢操作时，界面会跟着卡。⚠️
3. **后台存活**依赖 testmanagerd 按 pid 发放的后台断言，加上从 XCTRunner 模板抄来的
   `UIBackgroundModes = continuous`。现在的 Runner 也是同一套机制，但用在普通 App 上还没验证过。⚠️
4. **数据不会自动迁移。** Runner 和 LoopCtrl 现在是两个沙盒、两个钥匙串。合并后，已配对客户端的密钥、
   Runner 的日志和设置都留在旧 Runner 里，用户需要重新配对一次。
5. **iOS 16**：设备上的 XCTest 没有 `XCTCommandLineToolHelper`，原型改为手工构造
   `XCTestConfiguration`（照抄 XCTest 自己的做法）。这条路径完全没验证过。⚠️

## 1. 现在的 Runner 在没有 Mac 时是怎么自启动的（✅ 反汇编确认）

`LoopCtrlUITests-Runner` 的主程序是 Xcode 自带的 `XCTRunner.app/XCTRunner` 存根（约 270 KB）。
它的全部逻辑如下：

```
main()
  └ UIApplicationMain(…, @"_XCTRunnerAppDelegate")
      └ application:didFinishLaunchingWithOptions:
          └ runTestsInBackground:
              ├ BKSProcessAssertion("XCTRunner Initialization")   // 启动期间防止被挂起
              ├ XCTestObservationCenter addTestObserver:self      // testBundleWillStart 时释放断言
              └ CFRunLoopPerformBlock(main, commonModes, ^{ _XCTRunnerRunTests(); })

_XCTRunnerRunTests()
  if ([XCTestDriver environmentSpecifiesTestConfiguration])   // 有 Xcode 时走这里
      _XCTestMain(nil);
  else
      config = [XCTCommandLineToolHelper configurationFromCommandLineArguments:argv
                                                              userDefaults:…
                                                     requiresTestBundleURL:NO
                                                                  outError:&e];
      _XCTestMain(config);        // 不会返回：XCTestDriver.run 之后直接 exit()
```

从主屏幕点击图标启动时没有任何环境变量，XCTestCore 里的
`XCTestConfigurationLoader -loadTestConfiguration` 会：

- `_mostRecentTestBundle`：取 **`[NSBundle mainBundle].builtInPlugInsURL`** 下最新的 `*.xctest`；
- `_synthesizedConfigurationForTestBundle:`：新建一个 `XCTestConfiguration`，设置
  `testBundleURL`，再根据 `.xctest` 的 `Info.plist` 里的 `XCTContainsUITests` 设置
  `initializeForUITesting` / `reportActivities`。

`_XCTestMain` 做的事是：`[XCTestDriver initializeSharedTestDriverWithRunConfiguration:]`
→ `[[XCTestDriver sharedTestDriver] run]` → `exit()`。

**关键点：这条链上只看 `Bundle.main`，不看主程序叫什么，也不检查 bundle id 是不是 `.xctrunner`。**
只要 App 自己的 `PlugIns/` 里有这个 `.xctest`，同样的两步在 LoopCtrl 进程里也能做。

另外，Apple 自己就有「把 XCTest 注入普通 App 进程」的先例：
`/System/Developer/usr/lib/libXCTestBundleInject.dylib`（App 托管的单元测试，`TEST_HOST`）。
它在 `UIApplicationDidFinishLaunchingNotification` 之后加载测试包，然后调用 `_XCTestMain`。

## 2. 原型（✅ 能编译）

| 文件 | 内容 |
|---|---|
| `LoopCtrlApp/Runner/InProcessRunner.swift` | 新增。检查 DDI → `dlopen` XCTest → 构造配置 → `CFRunLoopPerformBlock` 里调用 `_XCTestMain`。另外负责转发 `loopctrl://` URL |
| `project.yml` | 新增 `LoopCtrlAllInOne` target（原来的 `LoopCtrl` / Runner 构建不受影响）：把 `LoopCtrlUITests.xctest` 嵌进 `PlugIns/`；`SWIFT_ACTIVE_COMPILATION_CONDITIONS += LOOPCTRL_ALL_IN_ONE`；复制 XCTRunner 的 `LC_RPATH` |
| `LoopCtrlApp/AllInOne-Info.plist` | 在 LoopCtrl 原有 Info.plist 基础上，加了 `loopctrl://` scheme 和 `UIBackgroundModes: continuous` |
| `LoopCtrlUITests/EarlyURLHook.m` | 环境变量 `LOOPCTRL_IN_PROCESS` 存在时：不 swizzle `setDelegate:`，不 hook `_XCTRunnerAppDelegate`，也不在启动早期自动挂起到后台；新增 `+deliverURL:`，让宿主 App 投递 URL |
| `LoopCtrlUITests/LoopCtrlUITests.swift` | 同进程模式下跳过 `backgroundSelfNow()`（否则会把用户刚点「启动」的界面切走） |
| `LoopCtrlApp/Views/SettingsView.swift`、`LoopCtrlApp.swift` | `#if LOOPCTRL_ALL_IN_ONE`：「启动」改为调用 `InProcessRunner.start()`；`loopctrl://` 交给 `InProcessRunner.handle` |
| `Makefile` | `make ipa-allinone` → `LoopCtrl-AllInOne.ipa`（对齐 `.xctest` 的 id，从内到外重签名） |

几个关键实现：

- **加载顺序**：先试 `/System/Developer/...`，再试 `/Developer/...`，最后试 cryptex 路径。
  DDI 里 XCTest 的 install name 和依赖都是 `/System/Developer/...` 开头的绝对路径（✅ `otool`），
  所以 `dlopen(XCTest)` 会自动带上 XCTestCore、XCUIAutomation、XCTAutomationSupport。
  测试包本身链接的是 `@rpath/XCTest.framework` 和 `@rpath/libXCTestSwiftSupport.dylib`，
  这两个靠 App 的 rpath 解析。
- **配置**：首选和存根完全一样的 `XCTCommandLineToolHelper`。参数里传 `.xctest` 的路径，
  把要用的测试包固定下来，而不是依赖「PlugIns 里最新的那个」。没有这个类时（iOS 16），
  用 KVC 构造同样字段的 `XCTestConfiguration`。
- **交接方式**：和 `runTestsInBackground:` 一样用 `CFRunLoopPerformBlock`，而不是
  `DispatchQueue.main.async`。原因是测试永远不返回，而主队列不会重入执行：如果在主队列 block
  里启动测试，服务器的 `DispatchQueue.main.sync` 会永久卡死。用 run loop block 的话，无论从哪个
  上下文调用 `start()`，测试都在一个独立的 run loop 回合里开始。
- **只启动一次**：`bootstrapped` 标志。再调一次 `_XCTestMain` 会因
  "shared symbolication service already set" 而 abort（`EarlyURLHook.m` 里记录过同样的崩溃）。

构建产物检查（`xcodebuild build -scheme LoopCtrlAllInOne -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO`，✅ BUILD SUCCEEDED。原来的 `build-for-testing -scheme LoopCtrl` 也 ✅ 通过）：

```
LoopCtrlAllInOne.app/LoopCtrlAllInOne            链接：只有 @rpath/LoopCtrlAllInOne.debug.dylib
LoopCtrlAllInOne.app/LoopCtrlAllInOne.debug.dylib  不链接 XCTest，也没有未定义的 XCT 符号
LC_RPATH: @executable_path/Frameworks, /System/Developer/Library/Frameworks,
          /System/Developer/usr/lib, /Developer/Library/Frameworks, /Developer/usr/lib
PlugIns/LoopCtrlUITests.xctest                XCTContainsUITests = true
                                           链接 @rpath/XCTest.framework, @rpath/libXCTestSwiftSupport.dylib
Info.plist                                 CFBundleURLSchemes loopctrl / loopctrl-app, UIBackgroundModes continuous
```

## 3. testmanagerd 对客户端进程的要求（✅ 字符串分析 / ⚠️ 未实测）

分析对象：本机 iOS 27 DDI（`022-20886-114.dmg`）中的 `usr/libexec/testmanagerd`。

- **没有 bundle id 约定**：`xctrunner`、`-Runner` 等字符串一个都没出现。它按 pid / audit token
  识别进程（`_XCTD_requestBundleIDForPID:`、`Computed effective bundle ID …`）。
- **权限（entitlement）**：只看到 `get-task-allow` 和 `com.apple.private.dt.xctest.internal-client`。
  后者只是用于特权接口（"permitting connection with restricted functionality" 那一档），
  现在的 Runner 也没有它，照样能用。所以 LoopCtrl 只要带 `get-task-allow` 就和 Runner 处于同一档：
  SideStore 免费账号签出来的是开发证书，`Scripts/sign-ipa.sh` 也会写入它。
- **"Enable UI Automation" 密码弹窗**：由 `-[XCUIDevice enableAutomationMode:]` →
  `_XCT_enableAutomationModeWithReply:` 触发，是设备级的状态，跟 bundle id 无关。
  合并后，用户在 LoopCtrl 里点「启动」时 App 在前台，弹窗会盖在 LoopCtrl 上面。原来的早期自动挂起
  （会在弹窗出现时把启动打断）在同进程模式下已经关掉。
- **后台**：testmanagerd 有 `_XCTD_requestBackgroundAssertionForPID:`，测试进程按 pid 申请后台断言。⚠️

## 4. 副作用

**进程保活与 UI**：`testStartServer` 在主线程上 `while keepRunning { runLoop.run(mode: .default, before: .distantFuture) }`。
SwiftUI 的事件、定时器、主队列都会在这个嵌套 run loop 里继续执行。⚠️ 要实测的是：滚动
（`UITrackingRunLoopMode` 会再嵌套一层，一般没问题）、XCTest 做快照时界面会不会明显卡顿。

**通知**：测试会设置 `UNUserNotificationCenter.current().delegate = self`。LoopCtrl 现在没有自己的
delegate，所以不冲突；但以后如果 App 要处理通知，需要统一由测试一侧来处理。

**停止**：现在的「停止」（通知按钮、`loopctrl://stop`、RPC `stop_server`）都会让
`keepRunning = false` → 测试返回 → XCTest `exit()`。合并后这会**关闭整个 LoopCtrl**。
原型保持了这个行为（最简单，也最可预测）。如果想保留界面，可以让同进程模式下的测试不退出循环，
只停掉服务器，之后通过同一个测试实例重新 `start`。这需要改 `LoopCtrlUITests.swift` 里三处设置
`keepRunning = false` 的地方，并补上「服务器已停但测试仍在」时的重启路径。原型没有做这部分。

**重启之后**：DDI 消失。主程序不链接 XCTest，rpath 指向不存在的目录也没关系（启动时不会经过它们），
所以 App 能正常启动 ✅（这是链接层面的推断，⚠️ 要上机确认）。`DeveloperDiskImage.status()`
会显示「未挂载」→ 用户在 App 内重新挂载 → 点「启动」。`.xctest` 不是 appex，系统不会自动加载它。

**同一个 UserDefaults / 钥匙串**：`serverPort` 等设置变成一份（App 和测试原本就用同名 key，这是好事）；
旧 Runner 里的令牌和日志不会迁移过来。

## 5. 签名

- **`Scripts/sign-ipa.sh`：不用改。** 它本来就是通用的：把 `PlugIns/*.xctest` 的
  `CFBundleIdentifier` 改成宿主的 id → 签 dylib → 签 framework → 签 `PlugIns/*` → 最后带
  `get-task-allow` 签 App。对 `LoopCtrl-AllInOne.ipa` 直接用 `-i` 即可。
  我用同样的顺序对构建产物做了一次 ad-hoc 模拟签名：`codesign --verify --deep --strict` ✅ 通过。
- **`Scripts/package-release.sh`**：逻辑通用，只是输入的 IPA 列表写死了，发布时需要把
  `LoopCtrl-AllInOne.ipa` 加进去（或者用它替换掉那两个）。
- **`Makefile`**：原型加了 `ipa-allinone`。不再需要 `XCTCompatShim` 那一套
  （insert-dylib / retarget-bind-ordinal），因为那是专门修补 XCTRunner 存根的绑定问题，
  而合并后的主程序根本不链接 XCTest。
- **SideStore**：IPA 的结构和现在的 Runner IPA 一样（App + `PlugIns/*.xctest`，两者 bundle id 相同），
  NOTICE.md 里写着当前版本的 SideStore 能正确签这种结构。区别只在于宿主现在是 LoopCtrl。⚠️ 需要实测：
  SideStore 改写 bundle id（加 team 后缀）时，`.xctest` 会不会跟着改。

## 6. 请在真机上做的测试（按顺序）

前提：先用 `make ipa-allinone` 生成 `LoopCtrl-AllInOne.ipa`（会替换已安装的 LoopCtrl，bundle id 相同），
旧的 `LoopCtrlUITests-Runner` 先保留，用来对照。

1. **没挂 DDI 也能启动**：重启手机 → 打开 LoopCtrl。预期：正常显示界面，状态为「未挂载」，不闪退。
2. **安装与签名**：分别用 SideStore（免费账号）和 `Scripts/sign-ipa.sh`（付费账号）安装。
   预期：都能安装并启动。SideStore 安装后，在 Mac 上检查 `.xctest` 的 bundle id 是否和 App 一致
   （或者看第 4 步的结果）。
3. **挂载后加载 XCTest**：在 App 内挂载 DDI → 点「启动服务器」。看 LoopCtrl 日志里有没有
   `In-process start failed: …`；有的话记下 `dlopen` 报的错误。
4. **自举与密码弹窗**：第一次启动时应该弹出 "Enable UI Automation" 并要求输入密码。输完后，
   日志（`Library/Logs/LoopCtrl/loopctrl-*.log`）里应该依次出现
   `🟩 +load reached in-process`、`🧩 setUpWithError begin`、`✅ testStartServer began`。
5. **服务器**：用另一台设备或手机上的客户端访问 `127.0.0.1:8200` / 局域网地址，执行截图和点击。
   同时确认 LoopCtrl 界面没有被自动切走，并且能正常滚动和点击。
6. **后台**：按 Home 键离开 LoopCtrl，等 5 分钟以上，再从另一台机器调用 RPC。预期：仍然能响应。
   **这是风险最大的一项。**
7. **URL**：在 Safari 里打开 `loopctrl://start?callback=…`（服务器已在运行和尚未启动两种情况各试一次）。
8. **停止**：点「停止」或通知里的 🛑。预期（原型的行为）：LoopCtrl 退出；再次打开后可以重新启动。
9. **iOS 16 设备（如果有）**：重复第 3–5 步，验证 KVC 构造配置那条路径。

只要第 1、3、4、5 步通过，合并就成立。第 6 步决定能不能完全替代独立的 Runner。

## 7. 如果要正式采用，还需要做的

- 让「停止」不关闭 App（见第 4 节），或者在界面上明确提示「停止会关闭 LoopCtrl」。
- 在 `start()` 到 `testBundleWillStart` 之间申请 `beginBackgroundTask`，代替存根里的
  `BKSProcessAssertion("XCTRunner Initialization")`。
- 把 LoopCtrl 原来「打开另一个 App」的提示文案、`LSApplicationQueriesSchemes` 中的 `loopctrl`、
  README 的安装步骤（两个 IPA 改成一个）都改掉。
- 旧 Runner 的配对数据要么放弃（重新配对），要么做一次性导出导入。
- 决定是否保留两套产物（独立 Runner 仍然适合配合 Xcode / Mac 使用）。
