# ReviewPendingDialog —— 可操作待办居中弹窗

> 位置：`lib/features/notice/widgets/review_pending_dialog.dart` · 新增于 2026-09-02
> （V459 / [ADR-063](../99-决策记录-ADR/ADR-063-部门定向审核待办弹窗与通知办结撤回.md) 第二轮）
> 文档同步：本文件 + [UtenNotify.md](UtenNotify.md) §七 + [工作台首页](../03-页面/工作台首页.md)。
> 2026-09-07：收件台退役，主职/兼职部门与真实动作资格由服务端实时校验；
> 登出或切换身份取消待执行检查与旧对话框，迟到状态响应不得再弹旧账号待办。
> 2026-09-10：登录弹窗口径改为「未办结 且（未确认弹窗 或 稍后到期）」——已读/去工作台即确认，
> 未办结也不再每次登录重弹；「稍后再看」到期恒重弹；车间任务 normal 卡也弹；人事域 8 事件落点。
> 2026-10-06（[ADR-163](../99-决策记录-ADR/ADR-163-中央提醒弹窗分级体系.md)）：
> 条目按 (type, priority, interactive/manual) 归入**四档视觉级别**（紧急/行动/进度/广播），
> 颜色+图标+徽章三重编码；弹窗排序 紧急 > 行动 > 进度 > 广播；
> interactive 的 urgent 恢复进中央弹窗（红卡），非 interactive urgent 维持只弹顶部红条。
> 修订(2026-10-06)：审批/工作流类(type=approval/workflow)一律行动级，priority=normal 不降进度级。

## 一、定位与形态

一个可操作待办事件的**三种提醒形态并存**（同一份 notices 数据，不重复落库；
既可用于审核，也可用于无需排他认领的车间执行任务）：

| 形态 | 载体 | 时机 | 交互 |
|---|---|---|---|
| 通知中心条目 | `/notice` 列表 | 落库即有 | 点开详情；已办结灰显 |
| 顶部通知条 | `AppNotification`（纯显示，无按钮/状态行） | 在线到达 | 8s 自然收起（urgent=error 红条） |
| **居中待办弹窗（本组件）** | `showReviewPendingDialog` | 在线到达 + **每次登录检查** | 主交互（下述） |

## 二、API

```dart
// 弹出(pending 非空；已有弹窗时合并新条目)
await showReviewPendingDialog(context, pending: [notice, ...]);
// 仅测试用：重置单例守卫
resetReviewPendingDialogForTest();

// 条目 → 视觉级别（公开，供测试/扩展复用）
reviewNoticeLevelOf(notice); // → ReviewNoticeLevel.urgent / action / progress / broadcast
// 分级排序（稳定：同级保持到达序）
sortByReviewLevel(items);
```

数据：`List<Notice>`（`interactive=true` 的未办结待审）；状态刷新复用
`GET /notices/pending-review-status`（30s 心跳）；登录检查数据源
`GET /notices/pending-reviews`（未办结 且（未确认弹窗 或 稍后已到期），重要度+时间序，
上限 20；2026-09-10 起不再按 priority 过滤，车间任务 normal 卡也进）。

## 三、交互契约（ADR-163 未改动项）

以下行为在分级体系落地时**全部保持不变**：单例守卫与多事件合并（「一共有 N 项」）、
30s 认领状态心跳（他人认领→「XX 正在审核」、办结自动撤卡清空自关）、
【去工作台处理】域工作台落点（`workbenchRouteFor`）、点列表行去该行所属域工作台、
【稍后再看】只调 snooze 15 分钟（不并发 markRead）、右上 X 仅本次关闭、
人工通知【打卡确认】/【知道了】/【查看详情】与「全部稍后再看」两组一起 snooze、
人工条目不参与心跳。报销补正接力等业务落点约定见 ADR-063 / 相关 ADR。

- **单条=大卡 / 多条=紧凑列表**：域图标（按 source_event 映射）+标题+摘要+相对信息。
- **【去工作台处理】（主按钮，2026-09-03 第四轮口径）**：不再直达单据详情——
  全部待办同域 → 该域任务工作台；跨域混合 → 工作台首页 `/dashboard`。**单条也去工作台**
  （行为统一）；弹窗内全部条目 markRead（服务端同时置 popup_acknowledged_at）——
  **去过工作台 = 已确认**，该条未办结也不再每次登录重弹；办结前通知中心/工作台徽章仍可见。
- **点列表行/大卡**：跳该条所属域的工作台，仅该条 markRead。
- 心跳单飞，每批最多 50 个 ID；成功响应缺少的旧条目视为失去资格或已删除/稍后，从弹窗移除；
  网络失败保留已展示状态，但新弹窗必须通过服务端真态校验后才可展示。
- **【稍后再看】**：只调服务端 snooze 15 分钟 → 关弹窗。到点未办结**下次登录/到达恒重弹**。
- 弹窗不可点遮罩关闭（待办必须被显式处理：去工作台/稍后/X 三选一）。桌面 Web 无
  系统返回键；移动端系统返回亦可关闭（showDialog 默认行为，与 ADR-063 非阻塞定位相容）。

## 四、视觉分级规范（ADR-163，2026-10-06）

用户诉求：此前几十种事件**全部同一个 teal 样式**，无法一眼识别类型与轻重。
分级按 `(priority, interactive/manual)` 归档，**每级「颜色 + 图标 + 徽章文字」三重编码**——
色弱/色盲下徽章文字与图标形状（双感叹号/勾/趋势/喇叭）仍可区分级别。

| 级别 | 判定 | 色彩槽 | 图标底 | 徽章（`_LevelBadge`） | 卡片强化 | 排序 |
|---|---|---|---|---|---|---|
| **紧急 urgent** | priority=urgent（含人工紧急） | error 红 | `errorContainer` | `dangerStrong` 红底白字 + `priority_high`「紧急」 | 1.5px error 描边 + 左侧竖红条（宽 4/3）+ 标题 error w700 + `errorContainer@45%` 底 | **1 置顶** |
| **行动待办 action** | type=approval/workflow（无论 priority），或 interactive && important | teal 品牌 | `primaryContainer` | `primaryContainer` teal 底 + `task_alt`「待办」 | 现有 teal 风格（secondaryContainer@35% + outlineVariant 描边） | **2** |
| **进度跟踪 progress** | task/其余 interactive && normal（物料到货进展、短交检知会等） | info 蓝 | `infoContainer`（暗色 `infoContainerDark`） | 蓝底 + `trending_up`「进度」 | `surfaceContainerLow` 底 + **更紧凑行高**（dense：内距 12→8、图标 40/30→36/30），视觉权重低于行动卡 | **3** |
| **人事广播 broadcast** | 人工通知组（非 urgent） | amber 暖色 | `broadcastContainer`（暗色 `broadcastContainerDark`，见 UtenColors） | 琥珀底 + `campaign`「公告」 | 卡片底色 = 琥珀容器色；amber 偏黄与 error 偏红拉开色相，徽章文字亦不同 | **4 垫底** |

- **审批/工作流类一律行动级（2026-10-06 修订）**：`type=approval/workflow` 的条目无论
  priority normal/important 都归行动级——`SALES_ORDER_PENDING_FINANCE_CONFIRM`、
  `PROCUREMENT_FINANCE_SUBMITTED` 等审批事件后端多标 priority=normal，但语义是
  「待我决定」的强待办，不应落最低权重的进度级（场景示例：财务登录弹窗里
  「待财务确认：SO-001」(approval+normal) 与「物料到货进展」(task+normal) 同屏时，
  前者带「待办」teal 徽章排序在前，后者「进度」蓝徽章垫后）。`type=task` 维持
  important→行动 / normal→进度的区分（后端以此区分可开工行动 vs 到货进展）。
- **同一 sourceEvent 可落不同级别**：如「可开工行动卡」priority=important → 行动，
  「物料到货进展」priority=normal → 进度——轻重由数据说话，不靠事件目录硬编码。
- **短交检出的接收人分化（有意设计，非缺陷）**：`SUBCONTRACT_SHORT_DELIVERY_DETECTED`
  仅 owner（订货单制单人）收 urgent 红卡；purchaser/follower 由后端发送时显式传
  `normal` 降级（防噪：避免整组持判定权限的人都被升级为持久强提醒），前端呈现为
  进度级蓝行——同一案件多接收人视觉分化是既定口径（ADR-163 §三），处理入口不受影响。
- **大卡 `_LargeItemCard` 与紧凑卡 `_CompactItemCard` 都吃这套分级**：大卡是行动/紧急的
  主力形态；进度类多条时进紧凑形态并压缩行高。人工卡 `_ManualNoticeCard` 保留类型色图标，
  卡片底/描边按级别改造（广播=琥珀底；人工紧急=红系强化并置组首）。
- **弹窗排序**：`sortByReviewLevel` 稳定排序（同级保持到达序）；分组顺序为
  待办审核组在前、人事/公司通知组在后（broadcast 垫底），组内 urgent 人工条目仍置组首。
- **头部摘要行**：按级别带色点计数（「● 紧急 1 · ● 待办 2 · ● 进度 1 · ● 公告 1」，
  `noticeLevelSummary`），取代旧事件域分组 chips；条目总数 ≤1 时不显示。
- 级别徽章/计数文案走 l10n：`noticeLevelUrgent/Action/Progress/Broadcast`、
  `noticeLevelSummary`（zh「紧急/待办/进度/公告」）。

其余视觉基线不变：`Dialog` 圆角 24 / elevation 12 / maxWidth 480；高度自适应封顶
min(60% 屏高, 560)；chip 固定高 26（级别徽章 22）；按钮高 46。
（坑：大卡内部 Column 忘写 `mainAxisSize.min` 会在 loose 约束下占满剩余高度——测试已锁定；
列表项高度不定，左竖红条需要 `IntrinsicHeight` 包裹才能 stretch 到整卡高。）

## 五、到达分派与顶部条的对应（两级口径统一）

| 到达场景 | 顶部条 | 中央弹窗 |
|---|---|---|
| interactive 待办（normal/important） | info/warning 纯显示 8s | ✅ 进（进度/行动卡） |
| **interactive urgent**（ADR-163 修订 ADR-059） | **error 红条 8s（并行保留）** | ✅ **进（紧急红卡）**；弹前真态校验对 urgent 同样生效（办结不弹） |
| 非 interactive urgent（驳回类纯告知） | error 红条 8s +「紧急 ·」前缀 | ❌ 不进（纯告知不打断工作） |
| 非 interactive important/normal | warning/info 4-6s（打卡类内联【打卡确认】12s） | ❌ 不进（登录弹窗兜底） |

顶部条分级（error 红 8s / warning 橙 6s / info 蓝 4s）不动；中央弹窗的四级与顶部条的
三级语义色同槽位（error/warning→action 的 teal 例外：action 是品牌「轮到我动手」色）。

## 六、登录检查（`ReviewPendingLoginGate`）

- 挂 app.dart 外壳（不渲染）：登录会话（authenticated + `notice:read`）从无到有时
  触发一次；延迟 300ms 等首屏稳定（`review_pending_login_gate.dart` 的 300ms 定时器）。
- 拉 `pending-reviews` + `pending-popups` → 非空则弹（弹窗单例：在线到达链已弹时不重复）。
  服务端口径（2026-09-10）：未办结 且（`popup_acknowledged_at` 为空 或 `snoozed_until`
  已到期）；去过工作台/已读的条目未办结也不再重弹，「稍后」到期的条目即使已读也重弹。
- 登出解除标记，下次登录重新检查；检查失败**有界退避重试**（指数退避 500ms→8s，
  身份切换/销毁守卫取消过期重试；在线链与工作台徽章兜底）。

## 七、人工通知分组 + 打卡（2026-09-10，ADR-063 §8）

- **弹窗形态**：与审核待办**同一弹窗**，独立分组「人事/公司通知 · N」在待办审核组**之后**
  （ADR-163 排序：广播垫底）；只有人工通知时标题改为**「登录提醒」**（图标 campaign）、
  副标题「有 N 条通知需要你确认」、底部只留「全部稍后再看」。
- **人工条目卡**（`_ManualNoticeCard`）：类型图标色块 + 标题（2 行）+「类型 · 发布人 ·
  相对时间」+ 级别徽章（ADR-163：紧急=红底白字「紧急」+ 红描边强化；其余=琥珀底「公告」）
  + 正文 2 行预览 + 操作区（Wrap，375px 自动换行）：
  - 打卡类型：**【打卡确认】**（幂等）→ 成功后原位「已打卡」chip 0.6s 再移除条目；失败可重试。
  - 只提醒类型：**【知道了】**（markRead）→ 移除条目。
  - 两者均有 **【查看详情】**：标已读 → 关弹窗 → `push('/notice/{id}')`。
  - 全部处理完弹窗自关。
- **稍后 / X**：「全部稍后再看」对两组一起 `snooze`；右上 X 仅本次关闭。人工条目
  **不参与** `pending-review-status` 心跳。
- **在线到达**：人工打卡类通知到达时顶部条内联【打卡确认】（`manualAckPending` 判定：
  无 source_event + acknowledge + 未打卡；停留 12s）。

## 八、接入新业务线

`ReviewNoticeCatalog` 注册事件（后端）后，该事件的 interactive 通知自动进入三形态；
同时须在 `workbenchRouteFor` 和 `_eventIcon` 登记对应工作台与图标，并在
`test/features/notice/widgets/review_pending_dialog_test.dart` 补 `workbenchRouteFor` 断言。
级别由服务端 `type`/`priority` 驱动（urgent→紧急红卡；type=approval/workflow 或
important→行动；task/其余 normal→进度），前端不再逐事件硬编码样式。无排他认领的任务可把 `claimTargetType` 设为 null，但必须实现可验证的
办结条件，防止弹窗永久悬挂。人事域事件由 `HrNoticeService` 发布（接收池按职能权限、
不限部门，ADR-063 2026-09-10 修订 §4 明示例外），事件清单见 ADR-063 附录。

## 九、测试

`test/features/notice/widgets/review_pending_dialog_test.dart`（路由落点 / 打卡 / 知道了 /
失败重试 / 混合分组 / 375px / 高度封顶滚动 / **分级：urgent 红卡+紧急徽章+置顶排序、
同 sourceEvent 按 priority 分行动/进度、审批(approval)/流程(workflow) 类 normal 也行动级、
同级保持到达序（排序稳定性）、人工广播琥珀+人工紧急红描边、分级计数行**）、
`celebration_mascot_test.dart`（庆典美术缺失回落 logo 不崩溃）、
`providers/review_pending_login_gate_test.dart`（仅人工通知也弹）、
`providers/notice_arrival_test.dart`（**interactive urgent 弹中央红卡 + 顶部条并行；
非 interactive urgent 不弹中央；办结真态校验对 urgent 生效**）、
`providers/notice_review_arrival_reliability_test.dart`（弹前校验失败重试不误确认送达）。
