# 跨 App 操作手册（Operation Playbook）设计

*设计文档，不涉及代码改动。2026-10-19。配套调研见 [control-speed-accuracy.md](control-speed-accuracy.md)。*

> **一句话定位**：playbook 是每个 App 的「可执行的操作知识」。它告诉 Agent：
> - 我现在在哪一屏；
> - 目标控件怎么找，找不到时怎么退；
> - 这件事有没有现成的、可参数化的流程；
> - 哪里有 deep link 可以跳过 UI；
> - 会冒出什么弹窗，怎么处理；
> - 哪些坑不能踩；
> - 每一步大概要等多久。
>
> 已知路径上，执行器**照着 playbook 走，不调用模型**；只在偏离时才请模型出场，并把学到的东西写回去。
>
> 设计依据见调研文档第 4.2 节：MobileGPT、AutoDroid、Mobile-Agent-E、EchoPath、GraphPilot、MAS-Bench。

> **许可证说明**：leeguooooo/iphone-use 的 flow 格式采用 PolyForm Shield 许可证，禁止竞品使用。本格式**独立设计**，没有沿用它的字段表或结构，只借鉴了公开的通用思想，比如「前置/后置条件」「兼容状态」。这些思想在 Maestro、Mobilewright 和学术文献里都有。

---

## 1. 设计原则

1. **保存契约，不保存点击流水账。** 一个步骤要说清四件事：
   - 从什么状态开始（前置条件）；
   - 用什么找到目标（多级选择器）；
   - 做什么动作；
   - 怎样算成功（后置条件）。

   坐标只做最后的兜底，并且必须绑定屏幕特征。
2. **选择器直接对齐 LoopCtrl 的能力。** 每一级都能一一翻译成现有 RPC：`find_element`、`page_source{filter}`、`screen_text`、`tap{x,y}`。将来服务端增加 `within` 等能力时，作为可选的增强级加入，旧执行器忽略这一级即可。
3. **确定性优先，模型兜底。** 执行器是普通程序。模型只在三个时刻出现：
   - 选流程，即意图匹配；
   - 处理未知分支；
   - 修复坏掉的步骤。
4. **默认不重放。** 带副作用的步骤（发送、发布、支付、删除）出现「结果未知」时，一律先观察再决定。重试只用在 LoopCtrl 保证「没执行」的错误上。按 SKILL.md 规则 5，ref 动作报错就意味着什么都没点。
5. **知识要带条件，不下结论。** 这一点和 SKILL.md 规则 7「记条件，不记结论」一致。
   - 每条陷阱和时间提示都要写明：在什么 App 版本、什么页面、观察到了什么。
   - 每条都带 `observed_on` 证据。
6. **数据和隐私：**
   - playbook 里不出现联系人名、消息原文、金额、账号。
   - 这些全部作为运行时输入（`inputs`）传入。
   - 运行日志回传云端前要脱敏。

---

## 2. 文件格式（YAML，一个 App 一个包）

```
playbooks/
  com.tencent.xin/                 # 按 bundle_id 分目录
    app.yaml                       # 身份、版本范围、全局弹窗、全局陷阱
    screens.yaml                   # 屏幕及其识别锚点
    elements.yaml                  # 具名选择器（可被流程引用）
    flows/
      send_text_message.yaml
      search_contact.yaml
    deeplinks.yaml
    evidence/                      # 验证记录（自动生成）
```

### 2.1 App 身份与版本范围：`app.yaml`

```yaml
schema: loopctrl.playbook/v0
app:
  bundle_id: com.tencent.xin
  names: ["微信", "WeChat"]           # 喂给 resolve_app{text: "微信|WeChat"}
  store_country: cn
  locale: [zh-Hans]                   # 标签都按语言写，换语言就是另一套变体
versions:
  supported: ">=8.0.50 <8.1"          # 本包承诺的范围
  verified:                           # 机器生成，每次验证都追加
    - {app: "8.0.79", ios: "26.1", device: "iPhone 16 Pro", points: [402, 874], date: 2026-10-11, result: pass}
  status: verified                    # verified | untested_newer | degraded | broken
global_popups: [wechat_update_sheet, system_notifications_alert]   # 每次进入 App、每个流程开头都检查
global_traps: [return_sends, long_list_slow_read]
```

`status` 的语义：

| status | 含义 | 执行器行为 |
|---|---|---|
| `verified` | 当前版本在范围内并已验证 | 直接跑 |
| `untested_newer` | App 版本比最新验证还新 | 跑；每个后置条件都严格检查；成功后上报新增的 `verified` 记录 |
| `degraded` | 云端统计到回退级选择器的使用率在上升 | 跑；遥测上报加密采样 |
| `broken` | 夜间回归失败，或有线上失败报告 | 不自动跑，转自由探索，playbook 只作为提示 |

### 2.2 屏幕与识别锚点：`screens.yaml`

一个屏幕用一组**锚点**识别，规则是：`all` 全部存在，并且 `none` 全不存在。锚点就是选择器（见 2.3）。识别时用 **一次** `page_source{visible_only:true, max_children:50}`，在客户端对整棵树做匹配，不要为每个锚点单独发一次 `find_element`。

```yaml
screens:
  chat_list:
    desc: 首页「微信」会话列表
    all:
      - {label: "微信", type: button, region: tab_bar, selected: true}   # 底部 tab
      - {label: "搜索"}
    none:
      - {type: keyboard}
    read_hint:                        # 时间提示（见 2.8）
      page_source: {visible_only: true, max_children: 50}
      note: "会话行多时 visible-cells 会生效，不要去掉 visible_only"
  search_page:
    all:
      - {type: textfield, contains: "搜索"}
      - {label: "取消", type: button}
  chat_room:
    all:
      - {type: textview}              # 底部输入框
      - {nav_title: "{{contact}}"}    # 导航栏标题等于输入的联系人
```

`region` 和 `nav_title` 是客户端谓词，用 `page_source` 返回的 frame 和 `NavigationBar`、`TabBar` 节点判断。LoopCtrl 自己判断「屏幕边框区」时也是这么做的，见 `ActionHandler.swift:4440-4460`。

### 2.3 元素选择器与回退：`elements.yaml`

**选择器原语和 LoopCtrl RPC 的对应**（v0 只用现有能力）：

| 选择器字段 | 翻译成 | 说明 |
|---|---|---|
| `id: X` | `find_element{element_id:X}` | 按 identifier 匹配，最稳，不受语言影响 |
| `label: X` | `find_element{element_id:X}` | 精确匹配标签 |
| `contains: X` | `find_element{element_id:X, match:"contains"}` | 子串匹配 |
| `type: T` | 加 `element_type:T` | button、textfield、cell 等 |
| `app: B` | 加 `bundle_id:B` | 系统弹窗用 `com.apple.springboard` |
| `pick: in_view` 等 | 客户端读结果里的 `visibility`、`alternatives[]` 后决定 | 也支持 `pick: {below: <selector>}`：在锚点下方的候选里选最上面的 |
| `require: {is_text_input: true}` | 检查结果字段 | 防假搜索栏 |
| `act_via: point` | 选择器只用来取 frame，动作走 `tap{x,y}` 或 `type{x,y}` | 没有标签的控件；某些自绘按钮对元素点按不响应 |
| `ocr: X` | `screen_text{element_id:X}` → `tap{x,y}` | 没有无障碍树的 WebView、自绘界面 |
| `filter: {...}` | `page_source{filter:{...}}` | 批量采集，比如价格 |
| `point: {rel:[fx,fy], guard: <screen>}` | `tap{x: fx*W, y: fy*H}` | **最后兜底**：只在 guard 屏幕识别通过、并且 `points` 宽高与记录一致时允许 |
| `within: <selector>`（v1，需要服务端支持） | 未来的 `find_element{within:…}` | 容器内查找；没有服务端支持时退化为 `pick: {below}` |

**多级回退**：按顺序尝试，命中即停。执行器记下用的是第几级，作为退化预警（见 3.3）。

```yaml
elements:
  chat_list.search_entry:
    tiers:
      - {label: "搜索", type: button}
      - {contains: "搜索", pick: in_view}
      - {ocr: "搜索"}
      - {point: {rel: [0.5, 0.135]}, guard: chat_list}
    expect_after_tap: {screen: search_page}
    note: "首页的搜索是按钮，is_text_input=false；输入框在下一页"
  search_page.field:
    tiers:
      - {type: textfield, contains: "搜索", require: {is_text_input: true}}
  search_page.contact_cell:           # 参数化选择器
    params: [contact]
    tiers:
      - {contains: "{{contact}}", type: cell, pick: {below: {label: "联系人"}}}
      - {contains: "{{contact}}", type: cell, pick: in_view}
  chat_room.input:                    # 没有标签的输入框：element_id 是必填的，所以按类型取 frame
    tiers:
      - {filter: {type: textview}, pick: lowest_in_view, act_via: point}   # page_source filter → 中心点 → type{x,y}
      - {point: {rel: [0.45, 0.93]}, guard: chat_room}                      # 键盘未弹出时的位置
```

### 2.4 已知流程：参数化宏，带前置和后置条件

```yaml
flow: send_text_message
version: 1.2.0
intent: ["给{{contact}}发微信说{{text}}", "微信发消息"]   # 用于检索（3.1）
risk: side_effect                     # read_only | navigation | side_effect | irreversible
confirm: required                     # side_effect 及以上，必须经用户确认目标和内容
inputs:
  contact: {type: string, desc: "联系人备注或昵称，按搜索结果里显示的写"}
  text:    {type: string, max_len: 2000, single_line: true}
pre:                                  # 任一满足即可开始；都不满足就先执行 enter
  any: [{screen: chat_list}, {screen: chat_room, nav_title: "{{contact}}"}]
enter:                                # 怎么到达前置状态
  - {op: launch_app, bundle_id: com.tencent.xin}
  - {op: handle_popups}
  - {op: tap, el: tab.wechat, if_not: {screen: chat_list}}
steps:
  - id: open_search
    op: tap
    el: chat_list.search_entry
    post: {screen: search_page}
    on_post_fail: observe_and_repair
  - id: type_name
    op: type
    el: search_page.field             # 执行器先 tap 它，再 type
    text: "{{contact}}"
    clear: true
    post: {present: {label: "联系人"}, timeout_ms: 3000}
  - id: open_chat
    op: tap
    el: search_page.contact_cell
    ambiguity: stop                   # 候选多于一个且位置无法区分 → 停下问用户
    post: {screen: chat_room}
  - id: type_text
    op: type
    el: chat_room.input
    text: "{{text}}"
    post: {value_contains: {el: chat_room.input, text: "{{text}}"}}
  - id: send                          # 唯一的副作用步骤
    op: type
    text: ""
    submit: true                      # 微信输入框 Return = 发送（见陷阱 return_sends）
    side_effect: true
    retry: never
    on_unknown: observe               # 超时：logs 查 ⏱ ✓ type，再读屏
    post:
      all:
        - {present: {contains: "{{text}}", pick: in_view}}
        - {value_empty: {el: chat_room.input}}
outputs:
  sent: {from: post.send}
```

**语义约定：**

- **`op` 和 RPC 一一对应：**

  | op | RPC |
  |---|---|
  | `tap` | `find_element` → `tap{ref}` |
  | `type` | 可选 `tap` 后 `type{text, clear, submit}` |
  | `page` | `page{direction}` |
  | `collect` | `collect{pages}` |
  | `open_url` | `open_url{url}` |
  | `launch_app` | `launch_app{bundle_id}` |
  | `read` | `page_source{visible_only:true, ...}` |
  | `wait_for` | v0：客户端有上限的循环读；v1：服务端 `wait_for` |
  | `handle_popups` | 见 2.6 |

- **`post` 的时机**：在动作的 `settle.stable` 之后检查。`stable:false` 时按 `timing.read_retry` 再读，有上限，不 sleep。
- **重试矩阵**：

  | 情况 | 处理 |
  |---|---|
  | `not_sent`：ref 报错、`find_element` 失败、断路器拒绝 | 可重试（换下一级选择器或 reset） |
  | 超时，或结果未知 | 先 `logs` 查 `⏱ ✓ <method>` 再读屏，然后才决定 |
  | `retry: never` 的步骤 | 永不自动重试 |

### 2.5 Deep link：`deeplinks.yaml`

```yaml
deeplinks:
  - id: search_notes
    app: com.xingin.discover
    url: "xhsdiscover://search/result?keyword={{q|urlencode}}"
    lands_on: search_results          # 落地屏的锚点，必须验证
    replaces_flow: search_notes_ui    # 失败时退回 UI 流程
    source: "pages.xiaohongshu.com/activity/deeplink（官方页面，2026-10-19 查看）"
    verified: []                      # 需要真机验证后填写
  - id: wechat_open
    app: com.tencent.xin
    url: "weixin://"
    lands_on: any                     # 只能打开 App，没有已知的直达聊天 scheme
```

规则：
- deep link 永远是**优化**，不是唯一路径。每条都要有 `lands_on` 验证和 `replaces_flow` 回退。
- 有些 scheme 第一次打开会触发系统确认框（「在『小红书』中打开？」），这个确认框要登记在 `popups` 里。

### 2.6 弹窗、权限框及处理器

```yaml
popups:
  system_notifications_alert:
    match: {app: com.apple.springboard, contains: "想给你发送通知"}
    handle: {tap: {label: "不允许", app: com.apple.springboard}}
    policy: auto                      # auto | ask_user | stop
  wechat_update_sheet:
    match: {any: [{contains: "发现新版本"}, {contains: "立即更新"}]}
    handle: {tap: {any: [{label: "以后再说"}, {label: "取消"}]}}
    policy: auto
  login_expired:
    match: {contains: "登录已失效"}
    policy: stop                      # 登录、验证码、支付一律交还用户
  captcha:
    match: {signal: blocked_by_captcha}   # 直接用 LoopCtrl 的 blocked_by 字段
    policy: stop
  promo:
    match: {signal: promo_popup}          # LoopCtrl 的 promo_popup 加 close_candidates
    handle: {tap: close_candidates[0]}
    policy: auto
```

`handle_popups` 什么时候跑：
- 进入 App 时；
- 每个流程开始时；
- 任何 `post` 失败时（先看是不是被弹窗挡住了，再判定失败）。

弹窗按 `match` 依次检查。全部检查只基于**一次** `page_source` 和 LoopCtrl 已有的 `system_alert`、`blocked_by`、`promo_popup` 信号，不额外读树。**未登记的弹窗**要停下，交给模型判断。模型处理成功后，把这个弹窗写回成候选条目（见 3.4）。

### 2.7 已知陷阱

```yaml
traps:
  return_sends:
    where: {screen: chat_room}
    what: "输入框里的 \\n 和 Return 都会直接发送"
    rule: "text 必须 single_line；多行内容只能用编辑菜单里的『换行』插入（未在 LoopCtrl 上验证）"
    observed_on: [{app: "8.0.79", source: "zhongerxin/iPhone-use references/wechat.md（MIT），2026-10-11"}]
  long_list_slow_read:
    where: {screen: [chat_list, contacts]}
    what: "会话列表、通讯录的完整树非常大（实测约 1,500 个 Cell），完整读取要 4–7s"
    rule: "只用 visible_only；找人走搜索，不要翻页找"
    observed_on:
      - {source: "zhongerxin wechat.md：深度 50 时 5–7s，深度 13 时约 1s"}
      - {source: "LoopCtrl ActionHandler.swift:4416：最大容器直接子节点 392 个"}
  mid_transition_read:
    where: any
    what: "页面切换动画中途读树，单次快照 5–6.5s，几何也是动画中的"
    rule: "动作之后等 settle.stable，或用 post 锚点轮询，不要立刻 find_element"
    observed_on: [{source: "LoopCtrl LoopCtrlUITests.swift:1383"}]
  long_press_needs_hold_samples:
    where: {screen: chat_room}
    what: "没有中间采样的长按会被当成单击"
    rule: "用 long_press RPC（已修），不要用 swipe 模拟"
    observed_on: [{source: "LoopCtrl FastActionHandler.swift:78"}]
  same_name_contacts:
    where: {screen: search_page}
    what: "搜索结果会同时出现联系人、群聊、聊天记录、公众号里的同名项"
    rule: "只在『联系人』分组标题下面选；仍有多个候选就 ambiguity: stop"
```

### 2.8 时间提示

时间提示让执行器**知道该等多久**，模型不必再猜。

```yaml
timing:
  defaults: {settle_timeout: 2, read_retry: {max: 6}}     # 每次读 0.3–0.7s，不 sleep
  per_step:
    open_search:  {expect_ms: [300, 900]}                  # 估计值，待基准测量
    type_name:    {expect_ms: [400, 1500], loading: "搜索结果是本地加网络两段，第二段晚到"}
    open_chat:    {expect_ms: [500, 1200], settle_timeout: 3}
  per_screen:
    chat_list:    {read: {visible_only: true, max_children: 50}}
```

规则：
- `expect_ms` 用基准测出来的 p50 到 p90。超过 p90 的 3 倍，就当作「卡住」，转观察。
- 所有数字都要带来源（基准运行 id）。没测过的写 `estimate`。

---

## 3. 生命周期：录制、验证、版本化

### 3.1 录制（从轨迹到草稿）

1. **数据源**：LoopCtrl 已经在日志里记了 `→ method params` 和 `⏱ ✓/✗ method ms`（`LoopCtrlUITests.swift:1479`）。
   - 不足之处：缺少 ref 背后的匹配信息（`ElementRef.match/elementType/index`，`ActionHandler.swift:36`），也缺每步前后的屏幕摘要。
   - **开源侧要补一个「轨迹导出」**：每步输出 `{method, params, ref_match, settle, screen_fingerprint_before/after}`，文本照常脱敏。
2. **生成草稿**（云端，商业）：
   - ref 匹配信息变成第 1 级选择器；
   - 再从当时的 `page_source` 里，按 identifier → 唯一标签 → contains → OCR → 坐标，自动补出后几级；
   - 输入的文字变成 `inputs`，原文丢弃；
   - 前后屏幕的锚点差异变成 `post`；
   - 发送、发布类步骤自动标为 `side_effect`。
3. **人工或模型审核**：命名、意图示例、风险等级、隐私清理（去掉标签里的人名和金额），然后定稿。

### 3.2 验证

| 层级 | 方法 | 频率 |
|---|---|---|
| 静态 | schema 校验；每个 `el` 引用都存在；每个 input 都被用到；`side_effect` 步骤 `retry: never`；坐标级必须带 guard | 每次提交 |
| 回放 | 设备农场，用测试账号在目标 App 的多个版本上跑；**连续跑 N 次（建议 20）**，正常路径不调用模型；要覆盖人为插入弹窗、打乱列表顺序 | 每晚；每次 App 更新 |
| 输出形状 | 带 `outputs` 的读取类流程记录结果形状（类型、非空）。形状变了，说明「步骤都过了但读错了」 | 每次回放 |
| 线上遥测 | 每次运行上报：步骤 id、命中第几级选择器、耗时、失败类别、App 版本。**不传屏幕内容** | 实时 |

### 3.3 版本化与 App 更新

- **playbook 自己用 semver。**
  - patch：补回退级、调时间；
  - minor：加步骤或分支；
  - major：输入或输出变了。
- **App 版本监控**：轮询 App Store 的 iTunes Lookup API，取各 App 的最新版本号。发现新版本时：
  1. 把 `status` 置为 `untested_newer`；
  2. 触发设备农场回放；
  3. 通过就追加 `verified`，失败就置为 `broken` 并开修复任务。
- **退化预警（比失败更早）**：某步第 1 级选择器的命中率下降、开始落到第 2、3 级，通常意味着 App 改了文案或结构。这时把 `status` 置为 `degraded`，并安排修复。
- **A/B 和灰度**：同一版本里可能同时存在两种界面。处理方式：
  - 用屏幕锚点区分变体：`screens.chat_list@variantB`；
  - 流程里用 `branch: {if: {screen: X@B}, steps: [...]}`；
  - **有限的分支，不写通用的自愈逻辑。**
- **语言和地区**：标签按语言分变体。读取类流程可以自动换语言变体重试一次；副作用类流程不允许自动重试。

### 3.4 写回

模型在自由探索中**成功**完成的任务，会产生一份轨迹草稿。写回分三种：

1. **新流程候选**：同一个意图被成功探索过 2 次以上，就合并成流程。
2. **补丁**：既有流程的某步失败了，模型修好之后：
   - 新选择器插到原第 1 级之前；
   - 原第 1 级降为第 2 级；
   - 发补丁版本。
3. **新弹窗或新陷阱**：未登记的弹窗被成功处理了，就生成 `popups` 候选条目；如果因为某个条件失败，就生成 `traps` 候选。

所有写回都**先进候选区**，经过回放验证才进主干。用户自己的私有 playbook（比如公司内部 App）只留在本地或租户空间，不进公共库。

---

## 4. 运行时：Agent 怎么用

```
用户意图 ──► ① 查找 ──► ② 执行 ──► ③ 验证 ──► 完成
               │          │ 偏离       │ 失败
               │ 没找到   ▼            ▼
               └────► ④ 自由探索（playbook 作为提示）──► ⑤ 写回
```

1. **查找**：
   - 先确定 App。用 `resolve_app` 和 `AppMemory`，结合 `device_info.system.foreground_app`。
   - 拉取 `app.yaml` 和 `flows/*` 的意图示例，做意图匹配。可以用检索加小模型，**这里是唯一需要模型的环节**。
   - 抽取 `inputs`，检查 `risk`。`side_effect` 及以上必须向用户确认目标和内容，例如「给 张三 发：xxx，确认？」。
   - 检查 `status`。`broken` 时直接走 ④。
2. **执行**：确定性执行器逐步跑。
   - 先检查 `pre`，不满足就跑 `enter`。
   - 每步依次：`handle_popups`（只在需要时）→ 按选择器级别定位 → 动作 → 等 `settle` → 检查 `post`。
   - v0 在客户端逐条发 RPC。v1 把连续的、没有分支的步骤打包成一次 `run_steps` 服务端调用。
   - 整个过程**不调用模型**。
3. **验证**：
   - 每步的 `post` 必须通过，流程结尾的 `post` 是业务验收。
   - 失败时先跑 `handle_popups`，再判断是否偏离。
4. **偏离，转自由探索**：执行器把这些交给模型，作为上下文的「修复包」：
   - 当前屏幕：一次 `visible_only` 读取，必要时加截图；
   - 卡住的步骤 id、它的意图、`post` 期望；
   - 已完成的步骤，以及其中有没有副作用；
   - 相关的 `traps`。

   模型按 LoopCtrl SKILL.md 的规则完成剩下的部分。有副作用的步骤已经执行过时，**绝不从头重跑**。
5. **写回**：上报这次轨迹和修复结果（见 3.4）。

**Agent 侧的提示约束**：
- playbook 很长，**每次只把当前流程和相关屏幕、陷阱的切片**放进上下文，不要整个包都塞进去。
- 这与综述总结的「只读需要的部分」一致。

---

## 5. 开源和商业的边界

| 层 | 内容 | 归属 | 理由 |
|---|---|---|---|
| 执行原语 | 现有 RPC 加上 `run_steps`、`wait_for`、动作附带观察、`within` 等更强的选择器、幂等键、run 级计时、轨迹导出 | **LoopCtrl（开源）** | 通用能力，越多人用越稳；与 iCTRL 当年「开源层保持通用」的方向一致 |
| 格式规范 | `loopctrl.playbook` schema 和 JSON Schema 文件 | **开源** | 开放格式有利于生态和用户自写私有 playbook，壁垒不在格式 |
| 参考执行器 | 能跑单个 playbook 文件的最小执行器（CLI 或 Python） | **开源** | 降低门槛；高级调度、遥测、修复不放进来 |
| Playbook 数据 | 各个 App 的屏幕、选择器、流程、deep link、弹窗库、陷阱、时间提示 | **商业（云端）** | 核心资产，靠持续验证和更新维护 |
| 验证设施 | 设备农场、多版本回放、App 版本监控、退化预警 | **商业** | 成本在这里，价值也在这里 |
| 意图匹配和修复 | 意图检索、修复用的模型、写回管线、候选审核 | **商业** | |
| 用户私有 playbook | 用户或企业自己录的流程 | 用户所有（本地或租户空间） | 不进公共库 |

**合规底线**（写进规范）：
- playbook 不提供绕过验证码、风控或限流的能力。`blocked_by` 一律 `stop`。
- 支付和最终确认类步骤只到确认页为止，与 SKILL.md 规则 9 一致。
- 每个 App 设频率上限。

---

## 6. 完整示例：微信给联系人发一条文字消息

**选择器只用 LoopCtrl `find_element` 现在支持的写法**：`element_id`、`match`、`element_type`、`bundle_id`，再加上对 `visibility` 和 `alternatives` 的客户端判断。

**标签来源说明**：
- 「微信」「搜索」「快捷操作」「标签页栏」「通讯录」「发现」，来自 LoopCtrl 源码注释里记录的、对滚动后微信列表的实测（`ActionHandler.swift:4441`）。
- 「联系人」分组、「取消」、Return 即发送，来自 zhongerxin 的微信说明（MIT）和常识，**需要在 LoopCtrl 上真机核对**。
- 所有时间都是估算。

### 6.1 Playbook 片段（完整版本见上文第 2 节的示例）

```yaml
# flows/send_text_message.yaml — 渲染后执行器会发出的调用见 6.2
flow: send_text_message
version: 0.1.0
risk: side_effect
confirm: required
inputs: {contact: string, text: string(single_line)}
pre: {any: [{screen: chat_list}]}
enter:
  - {op: launch_app, bundle_id: com.tencent.xin}
  - {op: handle_popups}
steps: [open_search, type_name, open_chat, type_text, send]
```

### 6.2 执行器实际发出的 LoopCtrl 调用

客户端是 `sh ~/.loopctrl/bin/loopctrl.sh call …`，下面只写方法和参数。

```text
# 0) 用户已确认：给「张三」发「今晚 7 点见」
launch_app {"bundle_id":"com.tencent.xin"}
  → settle.stable = true
page_source {"visible_only":true,"max_children":50}
  → 客户端匹配 screens.chat_list：
      TabBar 里有 "微信"，并有 label "搜索"
  → 匹配 popups：没有 system_alert、promo_popup、blocked_by，跳过
  → 断言 pre 成立

# 1) open_search
find_element {"element_id":"搜索","element_type":"button"}
  → ref=el_12, visibility=in_view, is_text_input=false     # 第 1 级命中
tap {"ref":"el_12"}
  → settle.stable = true, screen_changed = true
# post：screen = search_page。
# 这里用 find_element 检查锚点，不读整棵树（单个锚点比 page_source 便宜）
find_element {"element_id":"搜索","element_type":"textfield","match":"contains"}
  → ref=el_13, is_text_input=true

# 2) type_name（el_13 就是输入框，直接用）
tap {"ref":"el_13"}
type {"text":"张三","clear":true}
  → 没有 append_warning
# post：出现 "联系人" 分组；最多读 6 次，不 sleep
find_element {"element_id":"联系人"}
  → visibility=in_view, y=168

# 3) open_chat：pick below "联系人"
find_element {"element_id":"张三","element_type":"cell","match":"contains"}
  → ref=el_15, y=212, alternatives=[{y:410,...}]
  # 客户端从 主命中 + alternatives 里，
  # 选 y 大于 168 中最小的一个，即 el_15
  # 如果两个候选都在「联系人」下面（同名联系人）→ ambiguity: stop，问用户
tap {"ref":"el_15"}
  → settle.stable = true
# post：screen = chat_room
page_source {"visible_only":true,"max_children":50,"filter":{"type":"navigationbar"}}
  → 导航栏 label 含 "张三" ✓
# 输入框通常没有可用的标签，而 find_element 的 element_id 是必填的（ActionHandler.swift:7516），
# 所以用 filter 按类型取它的 frame：
page_source {"visible_only":true,"max_children":50,"filter":{"type":"textview"}}
  → TextView {{x,y},{w,h}}，取中心点 (cx, cy)
  # 如果真机上它有 identifier 或 placeholder，playbook 第 1 级改用 find_element

# 4) type_text：type 自带 x/y，会先点一下聚焦再输入
type {"text":"今晚 7 点见","x":cx,"y":cy}
  → keyboard.visible = true，没有 append_warning
# post：value_contains。用 find_element 读输入框的 value
find_element {"element_id":"今晚 7 点见","match":"contains","element_type":"textview"}
  → exists = true

# 5) send：唯一的副作用步骤，retry=never
type {"text":"","submit":true}
  → 正常返回；如果超时：
      logs {"text":"type"} 找 "⏱ ✓ type"，再读屏决定，绝不重发
# post（结尾验收）：
#   - 消息气泡出现：在 visible_only 读取里找 label 含 "今晚 7 点见"、y 在输入框之上的节点
#   - 输入框已清空
page_source {"visible_only":true,"max_children":50,"filter":{"text":"今晚 7 点见"}}
```

**对比**：

| 方式 | RPC 次数 | 模型轮次 | 估算总时间 |
|---|---|---|---|
| 执行器 v0（客户端逐条） | 约 14 次 | **1–2 轮**（只有意图匹配和最终汇报） | 手机侧约 10–15s |
| 自由探索 | 同样约 14 次 | 14 轮 | 1–3 分钟 |
| 服务端 `run_steps`（v1） | 可合并成 3–4 次 | 1–2 轮 | 网络往返更少 |

### 6.3 这个流程会碰到的分支（全部在 playbook 里登记）

| 情况 | 识别方式 | 处理 |
|---|---|---|
| 启动后出现「发现新版本」 | `popups.wechat_update_sheet` | 点「以后再说」 |
| 通知权限系统框 | `system_alert` 加 springboard 里的文案 | 点「不允许」。也可以设为 `ask_user`，由产品策略决定 |
| 搜不到联系人 | `type_name` 的 post 超时，并且没有「联系人」分组 | 停下，报告「没找到联系人 张三」。**不要转去通讯录翻列表**（陷阱 `long_list_slow_read`） |
| 同名的多个联系人 | `alternatives` 里有多于 1 个在分组下方 | 停下，把候选（只有名字和备注）列给用户选 |
| 消息里有换行 | `inputs.text` 校验 `single_line` 不通过 | 执行前拒绝，并提示用户（陷阱 `return_sends`） |
| 发送超时 | `type` 超时 | `logs` 查 `⏱ ✓ type`，再读聊天页，确认气泡数量，不重发 |
| 登录失效 | `popups.login_expired` | `stop`，交还用户 |

### 6.4 小例子：小红书搜索（deep link 优先）

```yaml
flow: search_notes
app: com.xingin.discover
risk: read_only
inputs: {q: string}
steps:
  - id: via_deeplink
    op: open_url
    url: "xhsdiscover://search/result?keyword={{q|urlencode}}"
    post: {any: [{contains: "{{q}}", type: textfield}, {label: "综合"}], timeout_ms: 4000}   # 落地锚点待真机核对
    on_post_fail: {goto: via_ui}
  - id: via_ui                        # 回退：首页搜索按钮 → 搜索页输入框 → type{submit:true}
    op: flow
    ref: search_notes_ui
outputs:
  titles:
    from: {collect: {pages: 2, min_length: 4}}
```

- 正常情况下是 **1 次 `open_url` 加 1 次 `collect`**。
- deep link 失效时自动退回 UI 流程，并把这条 deep link 的 `verified` 标记为失败。

---

## 7. 下一步（建议顺序）

1. **定下 v0 schema**：写出 JSON Schema，加上静态校验器。
2. **在真机上核对第 6 节的标签和锚点**，需要主人同意上机。然后用客户端执行器把第 6 节的流程跑通 20 次，正常路径不调用模型。
3. **开源侧补「轨迹导出」和 run 级计时**，作为录制和基准的基础。
4. **扩到 10 个高频国内 App**：微信、小红书、淘宝、京东、拼多多、美团、支付宝（只读）、抖音、B 站、高德。每个 App 3–5 个流程，加 deep link 表和弹窗库。
5. **服务端 `run_steps` 和 `wait_for`**，把执行器 v0 的多次往返合并。
