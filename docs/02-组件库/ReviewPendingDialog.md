# ReviewPendingDialog —— 可操作待办居中弹窗

> 位置：`lib/features/notice/widgets/review_pending_dialog.dart` · 新增于 2026-09-02
> （V459 / [ADR-063](../99-决策记录-ADR/ADR-063-部门定向审核待办弹窗与通知办结撤回.md) 第二轮）
> 文档三处同步：本文件 + [UtenNotify.md](UtenNotify.md) §七 + [待审收件台.md](../03-页面/待审收件台.md)

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
// 弹出（pending 非空；弹窗单例：已打开时空操作，新待办由心跳/收件台兜底）
await showReviewPendingDialog(context, pending: [notice, ...]);
// 仅测试用：重置单例守卫
resetReviewPendingDialogForTest();
```

数据：`List<Notice>`（`interactive=true` 的未办结待审）；状态刷新复用
`GET /notices/pending-review-status`（30s 心跳）；登录检查数据源
`GET /notices/pending-reviews`（未办结+未稍后，重要度+时间序，上限 20）。

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
  `/production/workshop-tasks`）；跨域混合 →
  待审收件台 `/reviews/inbox`。**单条也去工作台**（行为统一）；弹窗内全部条目
  标已读（提醒已响应；已读不吞待办——未办结下次登录仍会弹）。
- **点列表行/大卡**：跳该条所属域的工作台（混合列表的精确快捷通道），仅该条标已读。
  单据详情直达仍可从通知中心条目走 actionRoute。
- **【稍后再看】（次按钮）**：全部条目标已读 + 服务端 snooze 15 分钟（跨设备一致）→
  关弹窗。**snooze 是唯一静默途径**：到点未办结下次登录/到达再提醒。
- **右上 X**：仅本次关闭，**不 snooze**——「每次登录检查、有待办就弹」的产品口径；
  下次登录仍会提醒（未办结就还该提醒）。
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
- 拉 `pending-reviews` → 非空则弹（弹窗单例：在线到达链已弹时不重复）。
- 登出解除标记，下次登录重新检查；检查失败静默（在线链与收件台兜底）。

## 六、边界与守卫

- 弹窗单例（`_reviewPendingDialogOpen`）：已打开时**新待办并入当前弹窗**
  （`addPendingItems` 按 id 去重，副标题计数随之更新）——在线多事件同到合成
  「一共有 N 项」一个弹窗；登录检查与到达链竞争只保一层。
- 跨 async gap 的 context：到达链用根 Navigator context（提前捕获+mounted 检查）。
- 心跳失败可容忍（条目保持上次状态）；`resetReviewPendingDialogForTest` 供测试隔离。

## 七、接入新业务线

`ReviewNoticeCatalog` 注册事件（后端）后，该事件的 interactive 通知自动进入三形态；
同时须在 `workbenchRouteFor` 和 `_eventIcon` 登记对应工作台与图标。无排他认领的任务可把
`claimTargetType` 设为 null，但必须实现可验证的办结条件，防止弹窗永久悬挂。
