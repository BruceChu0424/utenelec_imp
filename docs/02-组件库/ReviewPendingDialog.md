# ReviewPendingDialog —— 可操作待办居中弹窗

> 位置：`lib/features/notice/widgets/review_pending_dialog.dart` · 新增于 2026-09-02
> （V459 / [ADR-063](../99-决策记录-ADR/ADR-063-部门定向审核待办弹窗与通知办结撤回.md) 第二轮）
> 文档同步：本文件 + [UtenNotify.md](UtenNotify.md) §七 + [工作台首页](../03-页面/工作台首页.md)。
> 2026-09-07：收件台退役，主职/兼职部门与真实动作资格由服务端实时校验；
> 登出或切换身份取消待执行检查与旧对话框，迟到状态响应不得再弹旧账号待办。
> 2026-09-10：登录弹窗口径改为「未办结 且（未确认弹窗 或 稍后到期）」——已读/去工作台即确认，
> 未办结也不再每次登录重弹；「稍后再看」到期恒重弹；车间任务 normal 卡也弹；人事域 8 事件落点。

## 一、定位与形态

一个可操作待办事件的**三种提醒形态并存**（同一份 notices 数据，不重复落库；
既可用于审核，也可用于无需排他认领的车间执行任务）：

| 形态 | 载体 | 时机 | 交互 |
|---|---|---|---|
| 通知中心条目 | `/notice` 列表 | 落库即有 | 点开详情；已办结灰显 |
| 顶部通知条 | `AppNotification`（纯显示，无按钮/状态行） | 在线到达 | 20s 自然收起 |
| **居中待办弹窗（本组件）** | `showReviewPendingDialog` | 在线到达 + **每次登录检查** | 主交互（下述） |

## 二、API

```dart
// 弹出(pending 非空；已有弹窗时合并新条目)
await showReviewPendingDialog(context, pending: [notice, ...]);
// 仅测试用：重置单例守卫
resetReviewPendingDialogForTest();
```

数据：`List<Notice>`（`interactive=true` 的未办结待审）；状态刷新复用
`GET /notices/pending-review-status`（30s 心跳）；登录检查数据源
`GET /notices/pending-reviews`（未办结 且（未确认弹窗 或 稍后已到期），重要度+时间序，
上限 20；2026-09-10 起不再按 priority 过滤，车间任务 normal 卡也进）。

## 三、交互契约

- **单条=大卡 / 多条=紧凑列表**：域图标（按 source_event 映射）+标题+摘要+相对信息。
- **认领状态 chip（「对应的人是否操作」）**：他人认领 →「XX 正在审核」（tertiary 容器色）；
  无人处理 →「待处理」+schedule 图标（primary 容器色）。30s 心跳刷新。
- **办结自动退出**：心跳发现条目 `resolved` → 移除该条目；全部办结 → 弹窗自关
  （不打扰已无需处理的人）。
- **【去工作台处理】（主按钮，2026-09-03 第四轮口径）**：不再直达单据详情——
  全部待办同域 → 该域任务工作台（`workbenchRouteFor`：销售财务确认→
  `/finance/sales-order-confirmations`、采购财务审批→`/finance/procurement-approvals`、
  IQC 待检→`/quality/task-center`、完工可发货→`/sales/progress`、生产车间任务→
  `/production/workshop-tasks`；人事域：信息变更→`/hr/profile-changes`、访客审批→
  `/visitor-approval`、接待确认→`/my-visitors`、报销审批/打款→`/expense/approval`、
  工资审核/发布→`/payroll/review`、建议待回复→`/suggestion`）；跨域混合 →
  工作台首页 `/dashboard`。**单条也去工作台**(行为统一)；弹窗内全部条目
  markRead（服务端同时置 popup_acknowledged_at）——**去过工作台 = 已确认，该条未办结
  也不再每次登录重弹**（2026-09-10 口径，取代旧「已读不吞待办」）；办结前通知中心/
  工作台徽章仍可见。
- **点列表行/大卡**：跳该条所属域的工作台（混合列表的精确快捷通道），仅该条 markRead。
  单据详情直达仍可从通知中心条目走 actionRoute。
- 扩展事件同样有明确落点：销售改量复审到销售订单修改，计划排产到物料分析，仓库到货/领料/
  品质放行分别到入库任务/领料任务/品质结果，IQC退回与贷项到其任务页。旧目录事件无聚合只保留历史。
- 心跳单飞，每批最多50个ID，超量分批合并后处理；成功响应缺少的旧条目视为失去资格或已删除/稍后，
  从当前弹窗移除。网络失败保留已展示状态，但新弹窗必须通过服务端真态校验后才可展示。
- **【稍后再看】（次按钮）**：只调服务端 snooze 15 分钟（服务端顺带置已读；前端**不再**
  并发调 markRead——两次写竞争会把 snoozed_until 冲掉）→ 关弹窗。到点未办结**下次登录/
  到达恒重弹，即使期间已读或已确认**——「稍后」是用户明确要求的再提醒。
- **右上 X**：仅本次关闭，**不 snooze、不确认**——未确认的待办下次登录仍会弹。
- 登录弹窗口径汇总（2026-09-10）：**弹 = 未办结 且（未确认弹窗 或 稍后已到期）**；
  确认 = markRead / 去工作台；办结 = 业务落点按聚合 resolve。
- 弹窗不可点遮罩关闭（待办必须被显式处理：去工作台/稍后/X 三选一）。

## 四、视觉规范

- `Dialog` 圆角 24 / elevation 12 / maxWidth 480；UtenTokens 间距体系。
- **高度完全随内容自适应，封顶 min(60% 屏高, 560px)**（2026-09-03 修订）：
  1 条≈300、多条随行数增长，列表内部滚动，弹窗保持正常卡片比例不再接近全屏。
  （坑：大卡内部 Column 忘写 `mainAxisSize.min` 会在 Flexible 的 loose 约束下
  占满剩余高度——单条曾被顶到 560 上限、下方一片空白，测试已锁定。）
- 头部：52×52 圆角图标容器（primaryContainer + 事件域图标）+「待办提醒」
  titleLarge w700 + 条数副标题。
- 单条大卡：secondaryContainer 35% 底 + outlineVariant 描边 + 圆角 16；
  多条紧凑卡：surfaceContainerLow + 圆角 12。
- chip 固定高 26；按钮高 46（FilledButton.icon 主 + OutlinedButton 次，等宽展开）。

## 五、登录检查（`ReviewPendingLoginGate`）

- 挂 app.dart 外壳（不渲染）：登录会话（authenticated + `notice:read`）从无到有时
  触发一次；延迟 3s 等首屏稳定。
- 拉 `pending-reviews` → 非空则弹（弹窗单例：在线到达链已弹时不重复）。服务端口径
  （2026-09-10）：未办结 且（`popup_acknowledged_at` 为空 或 `snoozed_until` 已到期）；
  去过工作台/已读的条目未办结也不再重弹，「稍后」到期的条目即使已读也重弹。
- 登出解除标记，下次登录重新检查；检查失败静默（在线链与工作台徽章兜底）。

## 六、边界与守卫

- 弹窗单例（`_reviewPendingDialogOpen`）：已打开时**新待办并入当前弹窗**
  （`addPendingItems` 按 id 去重，副标题计数随之更新）——在线多事件同到合成
  「一共有 N 项」一个弹窗；登录检查与到达链竞争只保一层。
- 跨 async gap 的 context：到达链用根 Navigator context（提前捕获+mounted 检查）。
- 心跳失败可容忍（条目保持上次状态）；`resetReviewPendingDialogForTest` 供测试隔离。

## 七、接入新业务线

`ReviewNoticeCatalog` 注册事件（后端）后，该事件的 interactive 通知自动进入三形态；
同时须在 `workbenchRouteFor`、`_eventGroupLabel`（副标题分组 chip 的中文名）和 `_eventIcon`
登记对应工作台、分组名与图标，并在 `test/features/notice/widgets/review_pending_dialog_test.dart`
补 `workbenchRouteFor` 断言。无排他认领的任务可把 `claimTargetType` 设为 null，但必须实现
可验证的办结条件，防止弹窗永久悬挂。人事域事件由 `HrNoticeService` 发布（接收池按职能权限、
不限部门，ADR-063 2026-09-10 修订 §4 明示例外），事件清单见 ADR-063 附录「人事域事件目录」。

## 八、人工通知登录弹窗 + 打卡（2026-09-10，ADR-063 §8）

用户口径：「人事手动发消息/通知，所有对应的人登录都要显示通知弹窗；需要打卡的点击打卡。」

- **数据源**：登录门 `ReviewPendingLoginGate` 与 `pending-reviews` **并行**拉
  `GET /notices/pending-popups`（`NoticeService.pendingPopups` →
  `NoticeRepository.findVisiblePendingManualNotices`，上限 20）。任一请求失败整体重试，
  两者皆空才算登录检查完成。人工通知 = `source_event IS NULL` 且非庆典（庆典有自己的
  每日登录弹窗 `CelebrationPopupGate`）；可见性同通知列表（全员 / 指定范围快照 / 定向本人），
  已删除不弹。
- **待处理判定（服务端）**：
  - **打卡类型**（`interaction_mode=acknowledge`：公告/制度/系统/紧急/福利）：本人无
    `notice_acknowledgments` 行 且（未稍后 或 稍后已到期）。**无时间上限**——不打卡每次登录都弹；
    已读 / `popup_acknowledged_at` 都不能停它，只有打卡能。
  - **只提醒类型**（`none`：任务/审批/流程等）：`popup_acknowledged_at` 为空 且
    （从未读且未稍后 或 稍后已到期）且 **发布 14 天内**（`NoticeService.NONE_MODE_POPUP_WINDOW`）。
    「知道了」/ 打开详情 = markRead → 静默；「稍后」到期重弹一次，再点「知道了」即止。
  - 排序：打卡类型优先 → 紧急/重要 → 置顶 → 发布时间倒序。
- **弹窗形态**：与审核待办**同一弹窗**，独立分组「人事/公司通知 · N」在上、「待办审核 · N」在下；
  只有人工通知时标题改为**「登录提醒」**（图标 campaign）、副标题「有 N 条通知需要你确认」、
  底部只留「全部稍后再看」（无「去工作台处理」）；有审核待办时标题/主按钮/副标题计数（两组之和）
  不变，头部分组 chip 多一枚「人事/公司通知 N」。
- **人工条目卡**（`_ManualNoticeCard`）：类型图标色块 + 标题（2 行）+「类型 · 发布人 · 相对时间」
  + 重要度徽章（`UtenStatusBadge`：重要=warning / 紧急=danger，紧急另加红色描边）+ 正文 2 行预览
  + 操作区（Wrap，375px 自动换行）：
  - 打卡类型：**【打卡确认】**（FilledButton，`POST /notices/{id}/acknowledge`，幂等）→ 成功后原位
    显示「已打卡」chip 0.6s 再移除条目；失败顶部报错、条目保留可重试。打卡**不代行已读**。
  - 只提醒类型：**【知道了】**（OutlinedButton，`markRead`）→ 移除条目。
  - 两者均有 **【查看详情】**：标已读 → 关弹窗 → `push('/notice/{id}')`（打卡类型在详情页仍可打卡，
    下次登录仍弹直到打卡）。
  - 全部处理完弹窗自关。
- **稍后 / X**：「全部稍后再看」对两组一起 `snooze`（15 分钟，到期重弹，打卡类型直到打卡为止）；
  右上 X 仅本次关闭。人工条目**不参与** `pending-review-status` 心跳（无办结/认领语义）。
- **在线到达**：人工打卡类通知到达时顶部条（`dispatchNoticeArrival`）内联【打卡确认】按钮
  （`manualAckPending` 判定：无 source_event + acknowledge + 未打卡；停留 12s），点击即回执并
  顶部提示「已打卡」；失败报错，登录弹窗兜底。
- **发布侧提示**：通知发布页类型选择器下一行「公告/制度/系统/紧急/福利 类型要求接收人登录打卡确认
  （未打卡每次登录都会弹窗提醒）；任务/审批/流程类只提醒」，类型→互动模式派生不变。
- 测试：`test/features/notice/widgets/review_pending_dialog_test.dart`（打卡 / 知道了 / 失败重试 /
  混合分组 + 全部稍后 / 375px）、`providers/review_pending_login_gate_test.dart`（仅人工通知也弹）、
  `providers/notice_arrival_test.dart`（顶部条内联打卡）、后端 `NoticeServiceTest`、
  `NoticeControllerContractTest`、`ManualNoticePopupPostgresTest`（真实 PG 口径）。
