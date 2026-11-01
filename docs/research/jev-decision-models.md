# 决策模型（Jev 类）能不能让 LoopCtrl 更快

*调研文档，不涉及代码改动。2026-10-20。*

> **证据标注**
> - 【论文】：论文摘要或正文给出的数字，作者自报。
> - 【官方】：厂商文档或博客。
> - 【第三方】：非厂商来源的报道或榜单，可能过期或有立场。
> - 【推断】：本文的估算或判断，没有测量支撑。
>
> 本文没有在真机上做测量。速度相关的 LoopCtrl 数据全部引用
> [control-speed-accuracy.md](control-speed-accuracy.md)，那份文档标注了原始出处。

---

## 0. 结论

1. **能帮上，但它不是第一优先级的提速手段。** Jev 类模型省的是「每一步都调用大模型」的时间，
   不省手机侧读树、settle、点按的时间。我们那份速度文档估算，一个 12–16 步的任务里
   模型轮次占 40–160s，手机侧只占 15–25s。所以决策模型的上限就是把模型时间压到接近 0，
   仍然要付手机侧的十几秒。
2. **先做 `run_steps` 批量，再考虑决策模型。** 已知流程批量执行完全不调用模型，
   收益和决策模型同源（都来自「少调用大模型」），但没有 5 个百分点的成功率代价，
   也不引入外部依赖。决策模型的价值在于**批量跑不下去的那部分**：分支、弹窗、
   A/B 文案、看不出下一步的情况。
3. **LoopCtrl 用这一类模型的条件，比别的项目好。** Jev-Mobile 的关键前提是
   「无障碍树能枚举出可执行候选」，而这正是 `find_element` 返回的 `ref`、`alternatives`
   和 `element_id` 已经具备的东西。候选空间是现成的，不需要新造。
4. **Jev-Mobile 的代价是准确率。** AndroidWorld 全量 79% 对逐步大模型的 84%，
   差 5 个百分点；换来端到端时间 −32.7%、API 成本 −73.4%【论文】。
5. **隐私是选型的硬约束。** Jev 的托管 API 意味着把屏幕文本发出去。LoopCtrl 的卖点是
   数据留在手机上。对「操控手机」这个场景，屏幕里是聊天记录、验证码、账单。
   如果要上生产，**优先自托管的开源权重**，别把屏幕内容发给第三方。

---

## 1. Jev 到底是什么

TypeSafe AI 的 **System One** 模型。名字取自 Kahneman 的快慢思考：语言模型是 System Two
（逐 token 推理），决策模型是 System One（一次前向，不生成文本）【官方】。

- **它不产出文本。** 你给一个 `state`（字符串、JSON 或数组）和若干**类型化问题**，
  它返回结构化答案加校准过的概率。
- **问题类型**【官方】：
  - `noul`：是/否，返回为真的概率；
  - `choice`：从最多 255 个带说明的选项里选一个，返回每个选项的概率和 confidence；
  - `score`：按有序量表打分；
  - `box`：在图片里找目标位置，返回归一化边界框（Jev 1.14 起）。
- **模型与价格**【官方】：`jev-1.13.0`（别名 `jev-latest`）和 `jev-1.14.0`（`jev-preview`，2026-10-14 发布）。
  $0.042 / 百万输入 token，输出不收费；单请求 64k、单问题 32k 上下文。
- **延迟**【官方】：宣称 70–500ms。
- **端点**：`POST /v1/systemone`（`api.typesafe.ai`）。
- **不能做的事**【官方】：不生成文本、不写代码、不做算术、不读图（1.13）、不走多步链路。

### Jev-Mobile 怎么用它做 GUI 执行器

[arXiv 2609.30186](https://arxiv.org/abs/2609.30186)，2026-09【论文】：

```
大模型读任务 + 当前屏幕/树 → 给出一个局部目标（local goal）+ 要输入的确切文本
  → 程序从当前无障碍树枚举候选动作（ID + 描述）
  → Jev 选一个 ID，或返回 DONE / BLOCKED
  → 执行 → 重新观察 → 重建候选 → 再问 Jev
  → DONE 才把控制权交回大模型
```

也就是说：**一次大模型调用底下可以跑好几个决策模型动作**。

| 指标（AndroidWorld 全量） | 逐步大模型 | SeeAct-V | Jev-Mobile |
|---|---|---|---|
| 成功率 | 0.84 | 0.78 | 0.79 |
| 成功轨迹的平均总时长 | 197.21s | 162.63s | **132.67s** |
| 其中执行模型耗时 | 94.30s | 12.37s | **5.16s** |
| 每条成功轨迹的模型 API 成本 | $0.2737 | $0.1932 | **$0.0727** |

注意「执行模型耗时」从 94.30s 掉到 5.16s 是 94.5% 的降幅，但端到端只降了 32.7%——
剩下的时间是设备侧观察和执行，决策模型碰不到。**这正是对我们最重要的一列。**

### 已有的移动端实现

[droidrun/mobile-jev](https://github.com/droidrun/mobile-jev) 是 Android 上的参考实现，
用的是 Mobilerun 的 API，不是 ADB。它值得读的地方是工程约束，不是模型本身【官方】：

- 操作问题和「目标候选」问题**合并进一次请求**，未被选中的目标答案不能执行；
- 执行前校验概率分布、拒绝过期目标；
- 传输失败后**绝不重试**设备写操作；
- 文本从目标里的原文片段选，由代码拷贝，不让模型生成；密码框和追加输入走另一种完成模式；
- **明确写了「Jev 返回 DONE 不等于任务成功」**，要自己核对设备状态。
- demo：Uber 上 9 个动作约 21 秒。

最后一条尤其要记住：我们速度文档里的 E1（超时重发）和 E12（跨步骤失误）不会因为换了模型就消失。

---

## 2. 放到 LoopCtrl 上算一笔账

### 2.1 决策模型能省的部分

按速度文档的估算，一个「给微信联系人发消息」的路径约 12–16 次 RPC，等于 12–16 轮大模型，
每轮 3–10s，模型时间 40–160s；手机侧 15–25s。

如果按 Jev-Mobile 的分工改造：

- 大模型只做 2 次：开场给局部目标，收尾验收。
- 中间十几个动作由客户端里的执行循环完成，每步一次决策调用。
- 决策调用按 70–500ms【官方】算，走局域网时再加几十毫秒 RTT。

**模型时间从 40–160s 降到大约 2–10s**，总时间大致落在 20–35s，也就是快 3–6 倍【推断】。

但有两个折扣：

1. **DONE / BLOCKED 的交接可能变多。** 弹窗、登录墙、A/B 文案都要交回大模型，
   每交接一次就是一轮 3–10s。交接频率完全取决于 App，只有在基准任务集上测才知道。
2. **病态页面不受影响。** 页面切换中途读树 5–6.5s、滚动过的信息流 6.7–9.6s，
   这些是手机侧耗时。决策模型选得再快，也得等树取回来。

### 2.2 和 `run_steps` 的关系

两者都省大模型轮次，但不是替代关系：

| | `run_steps` 批量 | 决策模型执行器 |
|---|---|---|
| 已知流程 | **最优**：一次调用跑 N 步，零模型调用 | 也能跑，但每步多一次决策调用，没必要 |
| 分支/未知页面 | 跑不下去，首错即停交回大模型 | **正好补这一块** |
| 准确率 | 不变（确定性） | −5pp【论文】 |
| 外部依赖 | 无 | API key 或自托管权重 |
| 隐私 | 数据不出设备 | 托管 API 会把屏幕文本发出去 |

合理的架构是三层：**playbook/deep link 直达 → `run_steps` 批量跑已知段 → 决策模型跑剩下的分支段 → 大模型兜底**。
决策模型是第三层，不是第一层。

### 2.3 LoopCtrl 的现成优势

Jev-Mobile 最麻烦的一步是「从树里枚举可执行候选」。LoopCtrl 不需要新造：

- `page_source` 本来就带 `ref` / `element_id` / `element_type` / `is_text_input`；
- `find_element` 已经会返回 `alternatives`、`match_count`、`visibility`，视口内优先；
- `tap_element` / `find_and_tap` 接受 `element_id`，`ref` 动作有归属校验（后台 App 的 ref 直接拒绝）。

所以候选构造器可以非常薄：把一次 `page_source` 的可点元素拍平成
`{"id": "<ref>", "desc": "<label> · <type> · <已选?> · <位置>"}`，加上 `DONE` 和 `BLOCKED`，
交给 `choice` 问题。模型输出只能是这些 ID 之一——类型安全，代码可校验，不会点到不存在的元素。

**已有的护栏正好覆盖决策模型最危险的失效模式**：ref 过期、跨 App 归属、遮罩层、
系统弹窗。这些在 LoopCtrl 里都是服务端拒绝，不是靠模型自律。

### 2.4 三个必须提前想清楚的问题

1. **WebView 和自绘界面没有树。** Jev-Mobile 自己也把这条列为局限：
   「视觉可见但不在树里的目标无法变成可执行候选」。LoopCtrl 在这些界面上走
   OCR / `screen_text`。要么把 OCR 行也拍平成候选（它们没有稳定的 ref，得用坐标），
   要么直接交回大模型。Jev 1.14 的 `box` 问题理论上能做视觉定位，但它是 preview，
   而且要把截图发出去。
2. **托管 API 的隐私边界。** 决策请求里是完整屏幕文本。如果 LoopCtrl 的定位是
   「数据在手机上」，默认路径就不能是托管 API。至少要可选、默认关闭、在配对确认页写明。
3. **手机上的额外一跳。** 如果 Agent 跑在手机里（Minis），每次决策调用都要出网。
   自托管在 Agent 宿主机（局域网）会好很多，但宿主机就得承担模型推理。

---

## 3. 厂商和免费试用

所有 Jev 类模型共用同一套 API 形状（`noul` / `choice` / `score`），所以**换供应商基本只改
endpoint 和 model 名**。这一点在设计时就要利用：把供应商做成配置项，不要让代码绑死一家。

| 供应商 | 模型 | 形状 | 价格（每百万输入 token） | 免费/试用 | 权重 |
|---|---|---|---|---|---|
| **TypeSafe AI** | Jev 1.13 / 1.14 | `POST /v1/systemone`，原生 | $0.042，输出免费 | 早期访问。2026-09-22 暂停注册，09-27 重开；据第三方报道，**新账号不再送 $5 额度**【第三方】。注册 console.typesafe.ai，充值即可 | 闭源 |
| **Cloudflare** | `clef` 27B / `clef-flash` 9B / `clef-omni` / `clairic` | **Jev 兼容**，64K 上下文，单请求最多 64 个问题 | clef $0.240；**clef-flash $0.038**；clef-omni $0.150；clairic $0.100 | **Workers AI 每天 10,000 Neurons 免费**，Free 和 Paid 计划都有。clef-flash 约 3455 Neurons/M token，折算**每天约 290 万输入 token**，做试点绰绰有余【官方】 | **Apache-2.0**，Hugging Face 可下 |
| **Quyet**（Chinh Nguyen） | Large 31.3B / Medium 4.7B / Small 330M / Small-EN 150M / **Tiny 180M** | `pip install quyet`，自己的 Python API | 自托管免费 | **完全免费**，Apache-2.0。Tiny 号称 CPU 上 6ms【官方】 | **Apache-2.0** |
| **Decision Models**（productivity-boost.com） | `s1-pro`（vLLM-SR d3 26B）、`s1-pro-2`（Perplexity Decider v1.1 27B）、`s1-fast`（Blink v0.3）、`s1-vision`、`quyet-1-large` | **Jev 兼容**，有 EU 托管层 | **s1-fast $0.019**；s1-pro $0.080；s1-vision 纯文本 $0.031 / 带图 $0.217；quyet-1-large $0.035 | 「免费额度靠邀请」；**最低充值 €1** 就能开跑【官方】 | 底层模型均 Apache-2.0 |
| **Google** | DiffusionGemma 26B-A4B（约 4B 激活） | 用 `djev-run` 包成同样的 `/v1/systemone` | 自付 GPU | 权重免费；官方 codelab 用一张 L4（24GB）的 `g2-standard-4` | **Apache-2.0** |
| Mapika | `decider-4b` / `decider-35b-a3b` | Jev 类 | 约 $0.015 / $0.154 每千次决策【第三方】 | 未见明确免费额度 | 开源 |

### 榜单参考（JevBench v1.6.0，1,624 条决策，独立运行）【第三方】

| 系统 | 官方分 | Capability | 每千次决策成本 | 权重 |
|---|---|---|---|---|
| Quyet-1.0-Large | 71.39 | **81.7** | $0.045 | 开源 |
| Jev 1.13（TypeSafe） | 71.09 | 76.5 | $0.032 | 闭源 API |
| Clef（Cloudflare） | 16.75（#43） | 75.3 | $0.249 | 开源 |
| decider-4b（Mapika） | 41.24（#17） | 64.9 | $0.015 | 开源 |

两个提醒：

- Cloudflare 自己的博客说 Clef「在 Jev Decision Index 上领先」【官方】，JevBench 上 Clef 官方分只有 16.75。
  **两个榜单口径不同，不要拿一家的一句话当结论。** 用自己的任务集测。
- 榜单测的是一般决策，不是 GUI 动作选择。GUI 场景下候选描述的质量、
  屏上文字的长尾分布都不同，**榜单分数不能替代我们自己的基准**。

### 建议的试用顺序

1. **Cloudflare clef-flash**：零成本、无需信用卡、Jev 兼容、有免费日额度。用它验证
   「候选选择」这个用法在我们的树上灵不灵。最快出结论。
2. **Quyet-Tiny / Small**：`pip install quyet`，Apache-2.0，CPU 就能跑。
   验证「自托管够不够用」，顺便解决隐私问题（屏幕文本不出局域网）。
3. **TypeSafe Jev 直连**：如果前两步表现不错，再花几美元买一次官方基线。
   $5 约等于 1.19 亿输入 token，按每次决策 1k token 算能做十万次以上，试点用不完。
4. **Decision Models**：最低 €1，一次 API 就能横向比 s1-fast / s1-pro / quyet-1-large。
   EU 托管层对海外用户有意义。
5. **DiffusionGemma 自托管**：只有在前几家都不满足、并且确定要完全离线时才值得付 GPU 成本。

---

## 4. 如果要做，怎么做才算数

不要直接改主路径。先做一个能证伪的实验：

1. **固定基准任务集。** 参照速度文档第 6 节的建议：设置页读 10 屏、搜索框输入长中英混排
   再清空、截一次图、回主屏。再加 3 个只读的真实 App 任务（微信搜索、小红书搜索、淘宝搜索）。
   **上机前征得主人同意。**
2. **三个对照组**：现状（每步一轮大模型）/ 仅 `run_steps` 批量 / `run_steps` + 决策模型执行器。
3. **记录四件事**：墙钟时间、大模型轮次、决策调用次数与 p50/p90、成功率。
   这正好是速度文档里 #9（run 级计时）要补的字段，顺手就做了。
4. **判定标准**：成功率下降不超过 2 个百分点、墙钟时间下降超过 25%，才算值得合并。
   低于这个不要合——−5pp 换 −30% 在演示里好看，在真实任务里是事故。

**先做 `run_steps`。** 它不依赖任何外部服务，能独立交付，而且无论决策模型最终用不用，
批量都是必须补的能力。决策模型的实验可以并行跑，但不该阻塞它。

---

## 附：来源（访问日期 2026-10-20）

**官方**
- TypeSafe：<https://docs.typesafe.ai/models>、<https://docs.typesafe.ai/primitives/box>、
  <https://typesafe.ai/blog/introducing-system-one-models-and-jev>
- Cloudflare：<https://developers.cloudflare.com/changelog/post/2026-10-01-clef-workers-ai/>、
  <https://blog.cloudflare.com/clef-decision-models/>、
  <https://developers.cloudflare.com/workers-ai/platform/pricing/>
- Quyet：<https://quyet.ai/>
- Decision Models：<https://decisionmodels.io/pricing>、<https://decisionmodels.io/models>
- Google：<https://codelabs.developers.google.com/codelabs/discriminative-models>（含中文版）
- droidrun：<https://github.com/droidrun/mobile-jev>

**论文**
- Jev-Mobile：<https://arxiv.org/abs/2609.30186>

**第三方**
- JevBench：<https://benchmarkheaven.com/jev-models>
- TypeSafe 注册状态：<https://jevainews.com/news/typesafe-signups-paused/>

**本仓库**
- [control-speed-accuracy.md](control-speed-accuracy.md)（耗时分布、错误分类、改进清单）
- [operation-playbook-design.md](operation-playbook-design.md)
- `LoopCtrlKit/RPCMethod.swift`、`LoopCtrlUITests/ActionHandler.swift`、`SKILL.md`
