# 让 AI Agent 通过 LoopCtrl 更快、更准地操作 iPhone

*调研文档，不涉及代码改动。2026-10-19，基于 LoopCtrl `574ad33`（server 1.98.12）。*

> **证据标注**
> - 【实测·代码】：LoopCtrl 源码注释里记录的作者真机实测。本次没有复测。
> - 【实测·他方】：其他项目在自己的仓库里公布的真机测量。
> - 【论文】：论文摘要或正文给出的数字，属于作者自报。
> - 【推断】：本文的估算或判断，没有测量支撑。
>
> 本次没有在真机上做任何测量，原因是其他会话正在用这台手机测试。第 6 节给出一套需要主人同意后才能跑的基准方案。

---

## 0. 结论先行

1. **LoopCtrl 的手机侧已经很快，瓶颈在 Agent 的轮次。** 屏幕读取 p50 约 0.42s，find_element + tap 在稳定页面上约 1s 以内，每次动作还会自动等待画面稳定。真正慢的有两处：
   - **每一步都要大模型想一轮。** 一轮通常 3–15 秒【推断】，比手机侧耗时大一个数量级。
   - **少数「病态页面」。** 页面切换动画中途读树，单次快照要 5–6.5s；长列表、长时间滚动过的信息流要 6–10s 以上【实测·代码】。
2. **最大的提速来自少调用模型，而不是让单次 RPC 更快。** 三件事最关键：
   - 批量执行和确定性回放。已知流程在执行时完全不调用模型。
   - deep link 直达，跳过 UI 步骤。
   - 小模型执行、大模型规划。

   相关论文自报的效果：
   - MobileGPT：延迟降低 62.5%，成本降低 68.8%。
   - EchoPath：执行时间中位数降低约 60%，token 成本降低 90% 以上。
   - Jev-Mobile：耗时降低 32.7%，API 成本降低 73.4%。
   - MAS-Bench：混合捷径后执行效率提升 39%。
3. **准确率主要靠三样东西：**
   - 先读无障碍树（accessibility tree），截图兜底。iOSWorld 测得给前沿模型加 XML 最多提升 26 个百分点。
   - 每步都有可机检的前置条件和后置条件。
   - 「不确定就先看，不要重放」的纪律。

   LoopCtrl 在第一和第三点上已经做得很好。缺的是**跨步骤的契约**，也就是 playbook 里的 pre/post 条件、弹窗分支和已知陷阱。
4. **建议的分工：**
   - **LoopCtrl（开源）** 补齐执行原语：`batch`/`run_steps`、服务端 `wait_for`、动作后返回增量观察、更强的选择器、run 级计时。
   - **云端（商业）** 提供 playbook 数据（屏幕锚点、选择器及其回退、流程宏、deep link、弹窗库、陷阱、时间提示），以及执行器、验证器和回写管线。

---

## 1. LoopCtrl 今天的时间花在哪里

### 1.1 一次调用的链路

```
Agent 规划（大模型一轮）
  → CLI/Python 客户端：X25519 + HMAC 加密信封
  → HTTP :8300
  → JSONRPCServer
  → 串行 rpcQueue（UI 方法一次一个）
  → 主线程 XCUITest / AX 快照 / 合成事件
  → ScreenSettle 等画面稳定（低分辨率帧比较，默认最长 2s）
  → 回复
```

UI 方法共用一个串行队列，见 `LoopCtrlUITests/LoopCtrlUITests.swift:1281`。看门狗超时：
- 普通动作 6s；
- `page_source`、`collect`、`screen_text`、`tap_element`、`find_and_tap` 是 15s（`:1388-1394`）。

UI 通道断路器（breaker）：**连续 2 次超时**就跳闸，之后 UI 调用立即被拒（`:1311`）。只有 `logs`、`config`、`reset` 走非 UI 通道，跳闸期间仍会应答。

### 1.2 手机侧耗时【实测·代码】

| 环节 | 数值 | 出处 |
|---|---|---|
| `page_source{visible_only}` 首轮（max_children=50） | p50 416ms，p90 593ms（8 个 App） | `ActionHandler.swift:3801` |
| 设置页 173 节点的普通 page_source | 652ms | `ForegroundApp.m:1662` |
| `max_elements` 20 和 2000 的取树耗时 | 都是约 90ms，说明它不限制取树本身 | `ActionHandler.swift:3703` |
| AX 侧没有缓存：mc=400 的重取耗时 | 约 600ms，与刚取过 mc=800 无关 | `ActionHandler.swift:4423` |
| 滚动过的微信列表放宽到 mc=500 | 约 1.2s，结果仍是 0 行，现已跳过 | `ActionHandler.swift:3887` |
| OCR（Vision）内联 | 约 260ms，另加取帧约 106ms；`screen_text` 整体约 700ms | `ActionHandler.swift:3869-3884, 4191` |
| 页面切换动画中途读树（微信，30 节点） | **每次快照 5–6.5s**；稳定后 120 节点只要 169ms | `LoopCtrlUITests.swift:1383` |
| 长时间滚动过的 X 时间线，page_source | 6.7–9.6s，每次都在手机上完成了。6s 看门狗曾导致 **51% 的 page_source「失败」** | `LoopCtrlUITests.swift:1373-1377` |
| find_element 走 live XCUIElementQuery | 微信搜索框 5245ms，滚动过的 X 时间线 69865ms，现限 2.5s | `ActionHandler.swift:6683, 6880` |
| find_element 走快照 + 内存遍历 | 同一微信页约 4100ms（未限子节点数）；遍历本身约 20ms。现在先用有界快照 | `ActionHandler.swift:6685, 6898` |
| 原生 `XCUIElement.tap()`，含 quiescence 等待 | 约 7.6s，现改为合成 tap | `ActionHandler.swift:7617` |
| 原生 doubleTap | 6230ms，曾导致断路器跳闸 | `ActionHandler.swift:1801` |
| type 之前逐类型探测焦点框（修复前） | 每次 type 多花 1–2s | `ActionHandler.swift:2271` |
| `scroll_to_element` | 约 1.3s/步；扫描加拖动 0.7–1.5s | `SKILL.md`，`ActionHandler.swift:6233` |
| `collect` | 约 1.5s/屏 | `SKILL.md` |
| ScreenSettle 单次取帧 | 0.1–0.25s，间隔 150ms | `ScreenSettle.swift:342` |
| ScreenSettle 静默窗口 | 0.6s；点按控件为 1.2s；判定新屏后再看 0.5s | `ScreenSettle.swift:38-47` |

**解读：**
- **稳定页面上**，一个「读、找、点」循环在手机侧约 1–2s，其中 settle 的固定静默窗口占 0.6–1.2s。
- **页面切换中途**读树或找元素，代价是稳定时的 **30 倍**以上。这也是 SKILL.md 规定「动作自带 settle，不要 sleep，稳定后立即读」的原因。
- **长列表和信息流**是另一类病态。LoopCtrl 用 `max_children` 阶梯、`visible_cells` 和 OCR 回退把大多数情况压到 1s 以内。zhongerxin 实测的微信通讯录也属于这一类：深度 50 时 5–7s，深度 13 时约 1s。

### 1.3 模型侧耗时【推断】

LoopCtrl 没有批量 RPC，**每个动作都占一轮模型**。按主路径估算「给微信联系人发一句话」：

1. `resolve_app`（可缓存跳过）
2. `launch_app`
3. `page_source`
4. `find_element("搜索")` → `tap`
5. `find_element(textfield)` → `tap`
6. `type`
7. 读搜索结果
8. `find_element(联系人)` → `tap`
9. 读聊天页
10. `type`
11. `find_element("发送")` → `tap`
12. 验证

估算结果：
- 合计约 **12–16 次 RPC**，等于 12–16 轮模型。
- 每轮按 3–10s 算，**模型时间是 40–160s**。
- 手机侧合计只有 15–25s。

所以把模型轮次从 14 压到 2–3（读一次，批量执行，最后验证一次），收益远大于把单次 RPC 从 1s 压到 0.5s。leeguooooo/iphone-use 的 SKILL 也这么说：每次调用都花掉 Agent 完整一轮，而手机只需约 0.5s（`skills/iphone-use/SKILL.md`，2026-10-17）。

### 1.4 已有的计时手段，以及缺口

现有手段：
- `LogBuffer.recordTiming` 按方法累计 count、avg、min、max，通过 `config` 结果里的 `timing` 字段和 `/logs` 尾部的摘要暴露（`LogBuffer.swift:41-101`，`LoopCtrlUITests.swift:1840`）。
- 每次调用写一行 `⏱ ✓/✗ <method> <ms>`。
- page_source 内部记录 `ladderSteps`、`fetchMs`，find_element 记录 phases，但这些只进日志。

缺口：
- 没有 p50/p90，也没有按 App、按屏幕的分布。
- 没有「一个任务」级别的 run 计数（调用数、模型轮次、墙钟）。leeguooooo 有 `/agent/run` 和 `/agent/metrics`，zhongerxin 有 `pua_metrics`。
- 没有排队时间和执行时间的拆分，排队只在超时文本里出现。

---

## 2. 错误从哪里来

按出现频率和后果排序，来源有三类：SKILL.md 里「Agent 最常犯」的规则、代码注释里的事故记录、hint 和 flag 设计。

| # | 错误来源 | 后果 | LoopCtrl 现状 |
|---|---|---|---|
| E1 | **超时后重发**（「为保险再点一次」） | 动作执行两次：重复发送、重复点赞 | 规则 4 加上 `logs` 里的 `⏱ ✓` 核对；断路器提示「NOT run yet, do not resend」。靠 Agent 自律，没有服务端幂等键 |
| E2 | **画面上的文字和无障碍标签不一致**；同名元素（日历里有三个「25」） | 找不到或点错 | `visibility`、`alternatives`、`match_count`，视口内优先；失败消息列出屏上已有的元素 |
| E3 | **假搜索栏**（看着像输入框，其实是按钮） | type 打到空处 | `is_text_input` 和 `note` |
| E4 | **追加输入**（搜索框里还留着上次的词） | 搜错 | `append_warning`、`clear:true` |
| E5 | **页面切换中途读树** | 慢 30 倍，拿到动画中的几何，点错 | 动作自带 settle；`page_check.same_page` |
| E6 | **系统弹窗或 App 弹层盖住目标** | ref 动作被拒或点到遮罩 | `system_alert`、`covering_layer`、`promo_popup`、`close_candidates`；验证码和限流用 `blocked_by` |
| E7 | **前台被抢**（通知、登录跳转、支付页） | 动作落到别的 App | ref 归属检查，后台 App 的 ref 拒绝点按；`overlay_text` 单独给出系统层文字 |
| E8 | **WebView 或自绘界面没有无障碍树** | 读不到 | `channel.recommended=ocr`、`screen_text`、`foreground_is_browser` |
| E9 | **长列表、信息流读取超时，触发断路器** | 整个会话卡住 15–45s | `max_children` 阶梯、`visible_only`、`tree_growth`、`collect` 自动切 OCR、扩展看门狗、`reset` |
| E10 | **截图坐标换算错**（像素和点混用，scale 取错） | 点偏 | 用截图响应里的 `scale` |
| E11 | **文档和实现不一致** | Agent 按不存在的字段推理 | SKILL.md 仍写着 `app_note`。这个字段在 iCTRL `6b48b72`（2026-07-06）引入，**现在代码里已经没有**（`grep app_note` 没有结果）。这是本周就能修的问题 |
| E12 | **跨步骤失误**：漏掉中间状态、走错分支（青少年模式弹窗、A/B 文案） | 任务失败，或在错误的页面继续操作 | **没有。** 没有流程契约，全靠模型每步重新推理。这正是 playbook 要补的 |

E1–E10 是**单步层面**的问题，LoopCtrl 已经有相当成熟的护栏。E12 是**流程层面**的问题，它也是商业 playbook 的价值所在。

---

## 3. 四个项目对比

调研对象和许可证：

| 项目 | 版本 | 许可证 | 备注 |
|---|---|---|---|
| iCTRL | `/Volumes/SanDisk/Projects/iCTRL` `0ddbb9d` | 与 LoopCtrl 同源 | 只读 |
| [leeguooooo/iphone-use](https://github.com/leeguooooo/iphone-use) | `ad228a2`，2026-10-17 | **PolyForm Shield 1.0.0**，source-available，**非开源，禁止竞品使用** | 本文只做功能层面的描述，**没有复制它的任何代码、文本或格式定义** |
| [zhongerxin/iPhone-use](https://github.com/zhongerxin/iPhone-use) | `8000688`，2026-10-16 | **MIT** | 可以参考，引用时保留版权声明 |

| 维度 | LoopCtrl | iCTRL | leeguooooo/iphone-use | zhongerxin/iPhone-use |
|---|---|---|---|---|
| 运行位置 | 手机上的 XCUITest runner，与 App 合一；Agent 可在手机上（Minis）或在电脑上 | 同 LoopCtrl（端口 8200） | Mac 上的 Rust 守护进程，加手机上自研的 XCTest runner（替代 WDA，兼容 WDA 接口）；HTTP 和 MCP | Mac 上的 Python MCP，加 USB 连接的 WDA |
| 感知 | 无障碍树优先（有界快照、`visible_only`、`filter`）；树太稀疏时**自动 OCR**（Vision），按每屏的 `channel.recommended` 决定；截图是第二选择 | 同 LoopCtrl | 无障碍树优先；`?ocr=auto` OCR 行；**带编号的截图**（`overlay=elements`，set-of-marks）；`ax_stats` 判断是否走视觉；大树（>1000 节点）跳过逐节点可见性检查 | 精简树（默认 200 节点，深度 50）；**按 App 和页面选深度**（微信列表用 13）；截图是界面异常时的通用兜底 |
| 定位 | `find_element`：精确标签 → identifier → value → contains，视口内优先；返回 `ref`，按 bundle、匹配、类型、序号重新解析 | 同 LoopCtrl | 快照令牌加元素序号（临时）；`tap_locator`（label、identifier、kind、value 的严格唯一匹配，持久）；重名零动作 | selector（label、name、value、type、`label_contains`）；重名返回 candidates 和 index |
| 执行 | 合成事件（不等 quiescence）；SwiftUI 场景回退原生 | 同 LoopCtrl | 单步动作；**批量 `/agent/actions` 最多 24 步**，同一把控制锁，首错即停 | **`pua_batch` 最多 20 步** |
| 等待与验证 | 每个动作自带 settle（帧比较），返回 `stable`、`screen_changed`；`page_check` | 同 LoopCtrl | `?return=delta` 返回动作后的增量树；`wait_for{present,absent,application}`；`no_progress`、`no_scroll_progress` | 默认乐观执行，下一次观察时顺带验收；`expect`、`verify` 只用于关键结果 |
| 弹窗 | `system_alert`（springboard 按钮）、`promo_popup`、`close_candidates`、`blocked_by: captcha/rate_limit` | 同 LoopCtrl | `alert` 动作；`alert_blocking` 快速失败；**`if_present` 可选步骤** | 遮挡时附截图，交给模型判断 |
| 流程与记忆 | `AppMemory`：只记名称到 bundle_id 的映射；**没有流程，没有 App 笔记** | 无 | **公共流程仓库**（iphone-use-flows），带 `compat`（verified、untested-newer、broken…）、`risk`、`locale`、`outputs`、`verified_on`；从轨迹**自动起草**流程（`flow_suggestion`、`flow draft`）；**每个 App 的 markdown 笔记**，进入 App 时随响应下发 | 在 skill references 里写每个 App 的说明（wechat.md、weibo.md），带实测深度和耗时 |
| 跳过 UI | `open_url`（任意 scheme 或通用链接） | 历史上曾有淘宝搜索 deep link 提示（2026-07-06 被 `99bd16b` 和 `52b7b34` 删除，目的是保持通用） | `open_url` 加 scheme 白名单；**快捷指令桥**（`/agent/intent` → inbox） | — |
| 小模型执行 | — | — | **Jev**：每步约 1–2s，不调用大模型，返回 done 或 blocked | — |
| 失败处理 | 超时语义清楚（还在跑，还是在排队）；`logs` 核对；断路器加 `reset`；ref 动作报错就保证没点 | 同 LoopCtrl | `outcome_unknown`、`retry_safe`、`not_sent` 三态；批量返回 `failed_step`，从断点续；修复包 | `action_executed`、`uncertain`、`continue_token`（长文本续传） |
| 计时 | 每个方法的 count、avg、min、max | 同 LoopCtrl | run 级 `/agent/metrics`（调用数、p50/p95、模型轮次） | `pua_metrics`（每个工具的耗时、字节数、调用间隔）；`scripts/benchmark.py` 固定任务基准 |

**iCTRL 有、LoopCtrl 没有的 App 知识**：基本没有。两边 SKILL.md 除了品牌名完全一致，都是 1.98.12。iCTRL 的 git 历史里删过一批 App 专属提示，可以作为 playbook 的种子：
- 淘宝搜索 deep link `taobao://s.taobao.com/search?q=…`，原文称「一个 open_url 顶约 4 次调用」；
- 用 `filter:{text:'¥'}` 收集价格；
- 用 `filter:{label:'待收货'}` 找订单；
- 「搜索」按钮作为提交兜底。

删除的动机是「开源层保持通用」，与本文建议的开源和商业分层一致。

**从对比得出的判断：**
1. **单步执行和感知上，LoopCtrl 不输另外两家**：
   - 它在手机上直连，没有 Mac 中转。
   - 有界快照加 OCR 自动切换，比固定深度更通用。
   - 超时和断路器的语义最细。
2. **流程层上，LoopCtrl 落后 leeguooooo 一整代**：缺批量、wait_for、增量观察、持久流程、App 笔记、流程起草和 compat。这一层正是商业 playbook 要占的位置。leeguooooo 用的是不允许竞品使用的许可证，**只能借鉴思路，必须独立设计格式和实现**。
3. zhongerxin 最值得借鉴的是**每个 App、每个页面的读取参数和实测记录**，比如微信列表深度 13 和十个国内 App 的读树耗时表。这类知识天然属于 playbook 的「时间提示」。

---

## 4. 外部研究：哪些技术真正有用

数字都来自论文摘要或作者自报，属于【论文】。访问日期统一为 2026-10-19。

### 4.1 感知：无障碍树优先，截图兜底

- **iOSWorld**（2026-06-08，[arXiv 2606.09764](https://arxiv.org/abs/2606.09764)）：首个原生 iOS 模拟器基准，26 个 App，133 个任务。
  - 最佳配置整体成功率 52%，多 App 任务只有 37%。
  - **给前沿模型加 XML（无障碍树）最多提升 26 个百分点，小模型加了没有收益。**
  - 结论：大模型规划时应该看树，小模型做 grounding 时给它更精简的输入。
- **Do GUI Agents Believe Their Eyes?**（2026-07-05，[arXiv 2607.04334](https://arxiv.org/abs/2607.04334)）：结构信息和像素冲突时，模型倾向相信结构。面对过期快照，最多 0.88 的探针会跟着旧结构走。第一步认错，后面的自我恢复率不超过 0.03。
  - **对 LoopCtrl 的启示**：动作之后必须用新读的树做验证，不能拿旧 `page_source` 推断；`page_check.same_page` 的方向是对的。
- **Set-of-Mark**（2023-10-17，[arXiv 2310.11441](https://arxiv.org/abs/2310.11441)）：在截图上叠加编号标记，能显著提升视觉 grounding。
  - 适合 LoopCtrl 的 OCR 和截图回退通道：截图上直接画 ref 编号。leeguooooo 的 `overlay=elements` 是同一思路。
- **LUMOS**（2026-06-29，[arXiv 2606.30697](https://arxiv.org/abs/2606.30697)）：把无障碍元数据整理成「语义蓝图」，包括稳定 id、角色、值、边界和可执行动作。这与 LoopCtrl 的 ref、element_type、is_text_input 方向一致。摘要没有给出定量结果。

### 4.2 少调用模型：记忆、捷径、回放

| 工作 | 日期 | 做法 | 自报效果 |
|---|---|---|---|
| [MobileGPT](https://arxiv.org/abs/2312.03003) | 2023-12 | 人类式 App 记忆：探索、选择、推导、回忆，子任务可复用 | 准确率 82.7%，迁移 98.75%；**延迟 −62.5%，成本 −68.8%** |
| [AutoDroid](https://arxiv.org/abs/2308.15272) | 2023-08（MobiCom'24） | 离线探索出 UI 转移图，注入 App 知识 | 动作准确率 90.9%，任务成功率 71.3%，比 GPT-4 基线高 36.4% 和 39.7% |
| [AutoDroid-V2](https://arxiv.org/abs/2412.18116) | 2024-12 | 每个 App 自动生成 API 文档，小模型直接写脚本 | 成功率更高，延迟和 token 更低（摘要没给数） |
| [AppAgent](https://arxiv.org/abs/2312.13771) / [v2](https://arxiv.org/abs/2408.11824) | 2023-12 / 2024-08 | 探索或人类演示 → 每个元素的功能文档 → 执行时用 RAG 检索 | 50 个任务、10 个 App 上定性有效 |
| [Agent Workflow Memory](https://arxiv.org/abs/2409.07429) | 2024-09（Web） | 从轨迹归纳可复用的 workflow，按需提供给模型 | Mind2Web 和 WebArena 相对提升 24.6% 和 51.1%，步数减少 |
| [Mobile-Agent-E](https://arxiv.org/abs/2501.11733) | 2025-01 | 长期记忆分两种：Tips（经验）和 Shortcuts（可执行的原子操作序列） | 比之前的最好结果高 22 个百分点（绝对值） |
| [AppAgentX](https://arxiv.org/abs/2503.02268) | 2025-03 | 从历史里找出重复的动作序列，进化成高层动作 | 效率和准确率都更好（摘要没给数） |
| [LearnAct](https://arxiv.org/abs/2504.13805) | 2025-04 | 一次人类演示 → 抽取知识 → 执行 | Gemini-1.5-Pro 19.3% → 51.7%（离线）；UI-TARS-7B 18.1% → 32.8%（在线） |
| [MAS-Bench](https://arxiv.org/abs/2509.06477) | 2025-09 | GUI 加捷径（API、**deep link**、RPA 脚本）的混合 Agent，88 个预定义捷径 | 成功率最高 68.3%；**执行效率比纯 GUI 高 39%** |
| [GraphPilot](https://arxiv.org/abs/2601.17418) | 2026-01 | 离线构建 App 知识图谱（页面、元素功能、转移规则），在线**一次模型调用**规划出整个动作序列，再用规则校验 | DroidTask 上完成率超过 AutoDroid，延迟和调用次数大幅下降 |
| [AppAgent-Claw](https://arxiv.org/abs/2606.05171) | 2026-04 | 录一次、回放多次，**运行时不推理**；分层定位，执行时同步验证 | 系统论文，没给定量 |
| [GPA](https://arxiv.org/abs/2604.01676) | 2026-04 | 一次演示即可回放；SMC 定位；就绪校准 | 试点：成功率高于 Gemini 3 Pro + CUA，**速度快 10 倍** |
| [EchoPath](https://arxiv.org/abs/2609.16635) | 2026-09 | 把经过验证的轨迹变成**带前置条件和参数、像工具一样调用的记忆**；不确定的步骤交给修复或重新规划 | **token 中位数 −90% 以上，执行时间中位数约 −60%** |

**这些工作的共识**（[Efficient GUI Agents 综述](https://arxiv.org/abs/2609.02309)，2026-09，也归纳出同样几点）：
- 只读需要的部分，不全量读；
- 记忆要能恢复和调用，而不是回放原始历史；
- 控制流要感知验证结果；
- 运行时要能在 GUI 和非 GUI 之间切换。

这几点**几乎就是商业 playbook 的规格说明**。

### 4.3 大模型规划、小模型执行

- **Jev-Mobile**（2026-09-24，[arXiv 2609.30186](https://arxiv.org/abs/2609.30186)）：视觉大模型低频规划局部目标，无障碍树定义动作空间，快速的类型化小模型高频选择动作。
  - AndroidWorld 成功率 79%，逐步调用大模型的基线是 84%。
  - 成功轨迹的**端到端时间 −32.7%，API 成本 −73.4%**。
  - 代价是约 5 个百分点的成功率。leeguooooo 集成的 Jev 就是它（每步约 1–2s）。
- **V-Droid**（2025-03，[arXiv 2503.15937](https://arxiv.org/abs/2503.15937)）：模型不生成动作，而是给离散的候选动作打分，只做预填充（prefill）。
  - AndroidWorld 59.5%；**每步 4.3s，是当时同类的 6.1 倍快**。
  - LoopCtrl 的 find_element 和 ref 天然能提供离散候选。
- **AgentCPM-GUI**（2025-06，[arXiv 2506.01391](https://arxiv.org/abs/2506.01391)）：8B 端侧模型，紧凑的动作空间，**中文 App 基准 CAGUI** Exact-Match 91.3%。可以作为中文 App grounding 小模型的候选。

### 4.4 基准水位（2026-10）

| 基准 | 结果 | 出处 |
|---|---|---|
| AndroidWorld 首发 | 30.6% | [arXiv 2405.14573](https://arxiv.org/abs/2405.14573)，2024-05 |
| UI-TARS | 46.6 | 2025-01 |
| UI-TARS-2 | 73.3 | [arXiv 2509.02544](https://arxiv.org/abs/2509.02544)，2025-09 |
| Mobile-Agent-v3 | 73.3（GUI-Owl-7B 单模型 66.4） | [arXiv 2508.15144](https://arxiv.org/abs/2508.15144)，2025-08 |
| 第三方榜单头部 | 84–85（Qwen3.8-Max、UI-Venus-2-27B 等） | [paperswithcode.co/benchmark/androidworld](https://paperswithcode.co/benchmark/androidworld)，2026-10 查看，**聚合站，非官方，数字未核对原文** |
| AndroidLab | 开源模型微调后：LLM 4.59% → 21.50%，LMM 1.93% → 13.28% | [arXiv 2410.24024](https://arxiv.org/abs/2410.24024)，2024-10 |
| **iOS：iOSWorld** | 最佳 52%，多 App 37% | 见上 |

**解读**：
- 通用 Agent 在 Android 模拟器的「标准任务」上已经到 75–85%。
- 但 iOS、多 App、真实国内 App（有弹窗、风控、A/B）明显更低，iOSWorld 多 App 只有 37%。
- 剩下的差距主要是**流程知识和异常处理**，不是单步 grounding。这支持「playbook 是核心资产」的判断。

### 4.5 跳过 UI：deep link、快捷指令、App Intents

- **URL scheme 和通用链接**：LoopCtrl 已有 `open_url`。
  - 小红书公开了 deep link 列表（[pages.xiaohongshu.com/activity/deeplink](http://pages.xiaohongshu.com/activity/deeplink)），包括 `xhsdiscover://search/result?keyword=`（2026-10-19 查看，**是否仍有效需要真机验证**）。
  - 微信对外暴露的 scheme 很少。社区列表里的 `weixin://dl/scan` 等，多份资料注明「新版已不能从外部调用」（[xFelino/url-schemes-collecting](https://github.com/xFelino/url-schemes-collecting)）。**没有找到直达某个聊天的公开 scheme。**
- **App Intents 和快捷指令**：Apple 官方文档在 [developer.apple.com/documentation/appintents](https://developer.apple.com/documentation/appintents)。
  - 第三方 App 暴露的 Intent **无法从外部枚举或直接调用**，只能借道用户安装的快捷指令（`shortcuts://run-shortcut?name=…`），结果通过 x-callback 或 HTTP 回传。leeguooooo 的设计文档（`docs/research/2026-09-semantic-intents-channel.md`）得出了同样的结论。
  - 价值在系统 App（健康、提醒事项、设置开关），国内主流 App 几乎没有暴露 Intent【推断】。

### 4.6 并行和推测感知

- 学界有推测执行一类的工作，但 LoopCtrl 的约束很硬：XCUITest 必须在主线程跑，UI 队列是串行的。
- 代码里已有教训：并行 OCR 曾让 runner 死锁（`ActionHandler.swift:3871-3882`）。
- 所以在**手机侧并行化收益低、风险高**。可行的「推测」在客户端：
  - 动作返回后立刻用响应里自带的观察规划下一步，省掉一次单独的读取；
  - playbook 预先知道下一屏的锚点，用 `wait_for` 代替「读 → 想」。

---

## 5. 改进清单（按「收益 ÷ 成本」排序）

收益分 速度 / 准确，★ 越多越大；成本按人日估算【推断】。归属列：**OSS** 是 LoopCtrl 本体（开源）；**云** 是商业侧的云端 Agent 或 playbook。

| # | 改进 | 速度 | 准确 | 成本 | 归属 | 依据 |
|---|---|---|---|---|---|---|
| 1 | **`run_steps` 批量 RPC**：一次调用执行最多 N 步（find → tap → type → page…）；每步可带 `expect`（present、absent、foreground），首错即停；返回 `completed`、`failed_step`、`not_sent`；结尾附一次 `visible_only` 观察 | ★★★★★ 模型轮次从约 14 降到 2–4 | ★★★ 首错即停，不会在错的页面继续 | 3–5 | **OSS** | leeguooooo `/agent/actions`、zhongerxin `pua_batch` 的实践；EchoPath、MobileGPT 的回放收益 |
| 2 | **Playbook 数据加确定性执行器**：已知流程不调用模型；失败交给模型修复（见第二份文档） | ★★★★★ | ★★★★★ | 持续投入 | **云**（执行器可以开源一个参考实现，数据商业） | MobileGPT 延迟 −62.5%；EchoPath 时间 −60%、token −90%；GPA 快 10 倍；Mobile-Agent-E +22pp |
| 3 | **Deep link 表**：每个 App 的搜索、个人页、详情页直达入口；带参数模板和验证锚点 | ★★★★ 一次调用顶 3–5 步 | ★★★ 少走 UI 就少出错 | 每个 App 0.5 | **云**（数据）；OSS 已有 `open_url` | MAS-Bench 效率 +39%；iCTRL 历史上的淘宝例子 |
| 4 | **服务端 `wait_for`**：`{present:[sel], absent:[sel], foreground, timeout}`，在手机上轮询，复用有界快照 | ★★★ 去掉「读 → 判断 → 再读」的模型轮次 | ★★★ 用状态代替猜测 | 1–2 | **OSS** | leeguooooo `wait_for`；SKILL.md 现在让 Agent 自己写 for 循环 |
| 5 | **动作响应附带观察**：`observe:"visible"` 或 `"delta"`，动作 settle 后直接返回精简树或增量 | ★★★ 每个动作省一次读取 | ★★ | 2–3 | **OSS** | leeguooooo `?return=delta`；zhongerxin `observe=tree` |
| 6 | **更强的选择器**：`within`（祖先或容器）、`near`、显式 `index`、`value`、`region`（只在某个 frame 区域内找）、`identifier` 优先 | ★ | ★★★★ 信息流里「每张卡片的『更多』」 | 3–4 | **OSS** | leeguooooo 研究页列为当前缺口；Maestro 的关系型选择器 |
| 7 | **可选步骤和弹窗处理器**：`if_present` 语义；进入 App 或每个批量开始前跑一遍已知弹窗清单 | ★★ | ★★★★ | 机制 1–2；数据持续 | 机制 **OSS**，弹窗库 **云** | LoopCtrl 已有 `promo_popup`、`close_candidates`；leeguooooo `if_present` |
| 8 | **按页面的读取参数提示**：例如微信会话列表用 `filter` 或深度提示；X 时间线先 `visible_only` | ★★★ 只影响病态页面 | ★ | 每页 0.2 | **云**（时间提示） | zhongerxin 微信深度 13：5–7s → 约 1s；LoopCtrl 的 `max_children` 阶梯 |
| 9 | **run 级计时和指标**：`config{run:start/end}`，统计调用数、各方法 p50/p90、排队和执行拆分、settle 等待；写日志 | 间接，是所有优化的前提 | 间接 | 1–2 | **OSS** | leeguooooo `/agent/metrics`；zhongerxin `benchmark.py` |
| 10 | **截图打编号**（set-of-marks）：`screenshot{marks:true}` 把 find 候选或 OCR 框连同编号画在图上，回复 `marks[]` → `tap{mark}` | ★ | ★★★ 视觉回退时更准 | 2 | **OSS** | SoM；leeguooooo `overlay=elements` |
| 11 | **小模型执行 + 大模型规划**：大模型给子目标，小模型或 Jev 类执行器在 ref 候选里选 | ★★★ | −（约 −5pp） | 研发投入 | **云** | Jev-Mobile 时间 −32.7%，成功率 −5pp；V-Droid 每步 4.3s |
| 12 | **轨迹到 playbook 草稿**：从 `logs` 的 `→ method params` 加 ref 匹配信息自动生成草稿 | 间接 | 间接 | 2–3 | 导出能力 **OSS**，编辑、验证、发布 **云** | leeguooooo `flow draft`；AppAgentX、AWM |
| 13 | **幂等键**：发送类动作带 `idempotency_key`，服务端记住已完成的 key，重复请求直接返回原结果 | — | ★★★ 根治 E1 的一部分 | 1 | **OSS** | E1 |
| 14 | **快捷指令桥**：`run_shortcut{name, input}` 加结果回传 | ★★ 只对系统 App | ★ | 2–3 | **OSS** 机制，**云** 维护指令清单 | Apple App Intents 文档；leeguooooo 研究 |
| 15 | **settle 自适应**：playbook 给出 `quiet_window` 提示（例如已知没有动画的控件用 0.3s） | ★★ 每步省 0.3–0.9s | − 设得过短有风险 | 1 | 参数 **OSS**，提示 **云** | `ScreenSettle.swift` 固定 0.6 和 1.2s |

**不建议做的：**
- 手机侧并行感知：主线程和串行队列约束，已有死锁事故。
- 全局降低读取深度：zhongerxin 已证明会丢字段，只能按页面设置。
- 自动「没变化就再点一次」：会制造重复的副作用。

---

## 6. 本周可做的快速改进

1. **修正 SKILL.md 的 `app_note` 漂移**（0.5 天，OSS）：删掉这一句，或者在 `#1 run_steps` 里实现前台漂移重聚焦后再写回。
2. **计时补上 p50/p90**（0.5–1 天，OSS）：`LogBuffer` 给每个方法保留最近 200 个样本，`timingStats` 加 `p50_ms`、`p90_ms`；日志行带 `queue_ms`（入队到开始）。不改协议，只加字段。
3. **客户端先实现批量**（1–2 天，OSS 客户端）：`loopctrl_rpc.py` 和 CLI 加一个 `run <steps.json>` 子命令，在客户端逐条执行 RPC。每步检查 `expect`（用 `find_element` 判断有没有，或检查 `settle.screen_changed`），首错即停，最后读一次屏。
   - 不改服务端，**立刻把模型轮次压下来**。
   - 网络往返仍然逐步发生，但在 USB 或局域网下每次只有几十毫秒。
   - 服务端 `run_steps`（#1）以后再做。
4. **起草 playbook 规范 v0 和三个种子 playbook**（2 天，云）：
   - 微信给联系人发消息，见第二份文档的完整示例；
   - 小红书搜索，deep link 优先；
   - 淘宝搜索，deep link 加 `filter:{text:'¥'}` 收价格，种子来自 iCTRL 历史。

   只用现有 RPC，不改 App。
5. **基准任务集**（脚本 1 天，**跑之前要征得主人同意上机**）：参照 zhongerxin 的 `benchmark.py`（MIT）思路自己写。
   - 任务：设置页读 10 屏、搜索框输入长中英混排文本再清空、截一次图、回主屏，全程不改设置。
   - 加上用户授权的微信或小红书只读任务。
   - 记录每个方法的耗时、调用数和响应字节数。
   - 每次改进前后各跑一遍。
6. **Deep link 核验表**（1 天，云）：在真机上逐条验证前 20 个 App 的搜索类 scheme，记录 App 版本、是否落地到结果页、落地页锚点。

---

## 附：参考来源（访问日期 2026-10-19）

**本仓库（574ad33）**
- `SKILL.md`
- `LoopCtrlKit/RPCMethod.swift`
- `LoopCtrlUITests/ActionHandler.swift`
- `LoopCtrlUITests/LoopCtrlUITests.swift`
- `LoopCtrlUITests/ScreenSettle.swift`
- `LoopCtrlUITests/LogBuffer.swift`
- `LoopCtrlUITests/AppMemory.swift`
- `LoopCtrlUITests/ForegroundApp.m`

**iCTRL**（只读）
- `0ddbb9d`
- 提交 `52b7b34`、`99bd16b`、`6b48b72`

**leeguooooo/iphone-use**（PolyForm Shield，只引用功能事实）
- `ad228a2`
- `skills/iphone-use/SKILL.md`
- `docs/agent-reference.md`
- `docs/scripted-flows-research.html`
- `docs/research/2026-09-*.md`

**zhongerxin/iPhone-use**（MIT）
- `8000688`
- `skills/iphone-use/SKILL.md`
- `references/wechat.md`、`references/app-snapshots.md`、`references/verification.md`
- `experiments/tree_element_handles/RESULTS.md`
- `scripts/benchmark.py`

**论文**：见第 4 节各处链接，均为 arXiv 摘要页。

**其他**
- Apple App Intents 文档
- 小红书 deep link 页
- 社区 URL scheme 列表
