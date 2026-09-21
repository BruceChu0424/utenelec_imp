# UtenBusyOverlay

「点了按钮在跑长任务」的全屏居中加载遮罩（2026-09-12 新组件，同日按用户口径修订视觉）。

## 用法

```dart
// 挂哪都行（body Stack、AbsorbPointer 内、Positioned.fill 包着都无害）：
if (_saving)
  const UtenBusyOverlay(title: '正在批量入库', description: '按收货单分组织整批同事务提交'),
```

- `title` 必填一句话；`description` 可选（讲清在做什么、别做什么）；
- `semanticsKey` 供宿主测试锁定（如物料分析的 `material-analysis-plan-submission-progress`）。

## 行为契约

| 语义 | 约定 |
|---|---|
| 全屏蒙版 | 组件把画面送进 **root Overlay**：宿主 Stack 只覆盖内容区（宽屏右半）也照样铺满整屏、卡片居中**屏幕**正中；本体在宿主树里渲染 `SizedBox.shrink` |
| 蒙版色 | 页面背景色向中灰轻掺（浅色 12%/深色 16%）再 82% 不透明——「和背景差不多但偏灰点」，不用半透明黑 scrim |
| 标题热更 | 已挂载状态下 title/description 变化改为**帧后**重建浮层卡片（2026-09-15）：`didUpdateWidget` 里直接 `markNeedsBuild` 一个 root Overlay 的 entry 会踩「构建期改树」断言——物料分析级联页跑批期间逐段换标题时炸过；帧后标脏实际渲染只晚一帧，无感 |
| 挂载时机 | 帧后插浮层（构建期插会 markNeedsBuild during build）；宿主被路由压栈（TickerMode=false）不挂，回前台（didChangeDependencies）再评估——避免宿主页+分桶页各挂一张同 key 卡片；**注意**：宿主被 opaque 整页（如 `MaterialPageRoute`）盖住时其子树整体不 build，宿主挂的遮罩不会出现——被压栈页面自己跑批时要**自挂**（级联页教训，2026-09-15） |
| 撤下时机 | **只跟随网络调用本身**：结果弹层展示期间必须已撤下，否则弹层背后转圈、widget test 的 pumpAndSettle 永不落定（物料分析 `planSubmissionProgress` 同款教训；挂载点必须在数量确认弹窗收口后的纯网络段） |
| 拦截 | `ModalBarrier(dismissible: false)` 吃掉蒙版层点击，不可关闭 |
| 不许跨跳转 | **遮罩亮着不许 `context.push`**：Flutter 3.44 的 `Navigator` 推完路由走的是 `overlay.rearrange(_allRouteOverlayEntries)`，不带 `above`/`below`，`rearrange` 会把「不属于路由的旧 entry」整组塞回列表末尾——也就是**每次路由历史变动都主动把这条裸 entry 重新抬到最顶**。所以不是「新路由恰好排在下面」，而是目标页必然被盖住且一个按钮都点不动；先 push 再开遮罩、改用 rootNavigator 推都绕不开。正例：`production_execution_segments_card.dart` 把包 push 的 `_busy` 和驱动遮罩的 `_commanding` 拆成两个标志；`material_transfer_launcher.dart` 的 `_busy` 包「开滑窗等它关」，明确不挂遮罩。要在同一个动作里先跑网络再跳页，就在 `finally` 撤下遮罩后 `await WidgetsBinding.instance.endOfFrame` 再 push(`setState` 只排了一帧，`OverlayEntry` 要等本体 dispose 才真的摘掉) |
| 兜底复位 | 忙标志必须在 `finally` 里**无条件**清——这是唯一的保证。漏清一次不是「一个按钮变灰」而是**整屏被不可关闭的蒙版盖死**：蒙版自己盖住了页面上的刷新按钮和左侧导航，人工自愈路径全都够不着，只能刷浏览器。页面的 `onPageResume`「返回即刷新」与刷新按钮里顺手清一把是第二、第三层兜底，别把它们当成主保证 |
| 卡片单用 | `UtenBusyOverlayCard` 是公开的卡片本体(无蒙版)，用于画**首屏加载**这类「不该拦住返回键」的场景；这时传 `showDoNotLeaveHint: false` 去掉「请勿重复点击或关闭页面」那句尾巴——首屏没有可重复点的按钮，劝人别关页面自相矛盾(领料汇总页首屏，2026-09-21) |

## 接入方

- 物料分析：`_planSubmissionOverlay`（下达车间，delegate 到本组件，语义 key 保留）、`bucketActionBusyMessage`（下达采购/委外**与确认路线**——2026-09-15 起路线确认并入，挂 `_notifyRoute`/`_saveRoutes` 分块段）、级联整页「一键下单」跑批遮罩（2026-09-15：本页 opaque 自挂，标题逐段跟随上述两条通道）
- 品质：批量审批页、FQC 检查单办理页、IQC 单张处置页（提交报告）、品质检查结果详情页（2026-09-16：单张确认入库/登记退回）
- 仓库：IQC 批量入库页、产成品批量全量点收页、普通出库审核（stock_doc 详情）、到货登记（单张/批量）、超量到货财务审批详情、供应商退回详情、批量出库详情、销售出库详情流转、成品仓登记（单张/批量）、库存单据编辑页
- 我的车间任务页(2026-09-21 用户口径「批量开工/批量领料/批量设路线要和别的页面一样有中间的加载弹窗」)：批量设路线、批量开工、重新核对备料收成 `_busy` **一条通道**，按动作换文案与语义 key(`workshop-route-confirm-busy` / `workshop-batch-start-busy` / `workshop-recheck-busy`)，且**遮罩盖到随后的整页重拉完成**再撤(中途换成「正在刷新任务列表」；表格在已有数据时刷新是零画面的，撤早了就是「提示已弹出、表格还是旧行」。刷新段文案不说「已提交」，整批全失败时这一段照样跑)。跳页的批量领料/分批领料/批量报工一律不进这条通道，点「批量领料」之后的加载卡片落在领料汇总页首屏(`UtenBusyOverlayCard`，`production-draw-request-loading`；用卡片本体不用遮罩，首屏加载时返回按钮不能被蒙版吃掉)
- 生产日报详情页（2026-09-16 补漏：审核/红冲/删除）；同日 `_busy` 命名漏网清扫——客户预收应用面板、批量发货面板、客户收货地址侧滑、清理测试附件弹窗、登记实际用料侧滑、计划详情执行段卡（段级流转另立 `_commanding`：`_busy` 其余用法是 push 跳转不能盖）、IQC 拒收办理/确认贷项弹窗（贷项预览与确认共用 `_busy`，另立 `_applying`）、稀缺让单页。**反例存档：物料调拨启动器 `_busy` 包「打开滑窗并等它关闭」，挂遮罩会盖住整个滑窗（测试 pumpAndSettle 实锤）——遮罩只许挂在纯网络段，跨弹窗生命周期的 busy 标志禁止复用**
- **2026-09-16 全站收口**：其余提交类长操作统一补挂——销售/采购/委外/财务四族单据编辑页、生产日报/计划编辑/计划详情、领料汇总、跨批复用与优先补供弹窗、未来调拨撤销、退仓申请侧滑、库存余额调整侧滑、员工入职/编辑/离职/调动/开户、系统设置（密码确认后的 `_applying` 段）、页面/部门/个人权限设置、数据交接、数据范围、客户可见人、货品主档/BOM/成本、工资生成、个人资料修改（同 `_applying` 段）、访客申请、清空业务数据弹窗。纪律：**遮罩只挂纯网络段**——先弹密码/确认弹窗再提交的流程用独立 `_applying` 类标志，避免遮罩盖住弹窗（系统设置与个人资料两处踩过）
