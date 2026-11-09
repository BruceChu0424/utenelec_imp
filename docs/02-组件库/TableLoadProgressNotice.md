# TableLoadProgressNotice（顶部加载进度通知）

> **本项目自建组件**（2026-11-09）。
> 表格完整读取（进入页面/刷新的分批渐进加载）的顶部悬浮进度通知：
> **整张卡片背景就是进度条**，已加载区从卡片最左向右铺满全高，文字/图标/
> 关闭按钮恒浮在进度背景之上。视觉与普通顶部通知（[AppNotification](AppNotification.md)）
> 同语言：顶部居中悬浮、圆角 `UtenRadius.card`、elevation 4 柔影、
> 右侧**红色圆形关闭按钮（UtenCloseButton，白×）**。
>
> - Dart：`lib/core/ui/table_load_progress_notice.dart`
> - 上游事件：`lib/shared/paging/complete_read_progress.dart`
> - 测试：`test/core/ui/table_load_progress_notice_test.dart`、
>   `test/shared/paging/complete_read_progress_test.dart`

---

## 一、它显示什么

| 阶段 | 文字 | 左侧图标 | 背景 |
|---|---|---|---|
| 加载中（总量已知） | `正在加载数据：NN%`（NN% 加粗含百分号） | 细线旋转环 | 已加载区 = `已验证累计行数 ÷ 服务端 total` |
| 加载中（总量未知） | `正在加载数据…` | 细线旋转环 | 不定进度扫动光带，**不编造百分比** |
| 完成 | `数据加载完成：100%`（100% 加粗） | 对勾 | 铺满整卡，停留 ~1.4s 后上滑淡出 |
| 失败/取消/退休 | —（卡片直接退场） | — | 错误提示沿用页面既有 `appError` 链路 |

配色（`UtenColors.loadNotice*`，薄荷青绿系，浅/深主题配对）：
未加载底 `#F4F9F7`、已加载渐变 `#CEEDE3→#A9D8C8`、正文 `#25463E`、
加粗百分比 `#176D59`、边框 `#DCE9E3`；关闭按钮保持项目红底白×不变。

## 二、进度从哪来（业务页零接入）

进度不在组件里编：`loadCompletePagedResult`（完整读取唯一维护入口）对
**发布渐进批次的主表读取**经 `CompleteReadProgressReporter` 上报
「已验证累计行数 + 服务端精确 total」；批次计划 50→50→100→200 是**每批新增
行数**，进度分子分母同口径（同一查询范围、去重后的已验证行数 ÷ 首批带回的
稳定 total）。因此货品资料、即时库存、财务表格、各任务中心等所有走
`ScopedPagedRead` / `PagedListController` / 直连 `loadCompletePagedResult`
并带 `onProgressiveBatch` 的页面**自动获得**该通知，无需逐页接线。

不上报的读取：无渐进槽的辅助读取（facets 等）、已接受结果的静默重读、
后台（silent）刷新、游标历史（无总量语义）。

## 三、展示决策（TableLoadProgressNoticeController）

- **延迟 600ms 出现**：更快的完整读取（缓存命中、单批小表）不闪卡；
- **加载中封顶 99%**：`100%` 与对勾只属于真正返回的完整结果（数据源更新后）；
- **填充宽度 = 显示百分比**：加载中同样按 99% 封顶取整，图文永不打架；
- **进度动画续走**：批次连续到达时从当前显示位置向新目标推进，不重排、
  不排队、不回弹；同轮始终更新同一张卡，不销毁重建；
- **红色关闭只隐藏本轮提示**：后台读取继续；同轮后续批次/完成不再唤出；
  用户刷新/改筛选/切页产生的新任务按正常规则重新显示；
- **任务隔离**：切页/改筛选退休旧读取（`ScopedPagedRead.invalidate` 立即
  收尾其进度任务，不等迟到的网络返回）；旧任务迟到返回不更新新任务百分比、
  不误关/误完成新任务的卡片；
- **同轮最新主读取**：同一时刻只展示最近开始且仍在进行的一张卡；同页
  并发的其余主读取在后台完成，不叠加多卡；
- **空结果**正常结束（完成前通常已低于出现延迟，不弹卡、无除零）；
- **悬停暂停完成收起**（读完再走，移出重新计时）；
- **减少动态效果**（`MediaQuery.disableAnimations`）：入场/退场直接切换、
  进度瞬移、光带停驻、细环不旋转。

## 四、层级与清理

- 宿主 `TableLoadProgressNoticeHost` 挂在 `app.dart` 顶部 Stack 内，与
  `AppNotificationHost` 同 Column 堆叠（通知在上、加载进度在下），互不遮挡；
  卡片像素之外不拦截页面点击。
- 关闭按钮 tooltip/语义名「关闭加载提示」，键盘可达；卡片 Semantics 为静态
  标签（`正在加载数据，NN%` / `数据加载完成`），不做逐批 live region 播报。
- 控制器/卡片销毁时取消全部计时器、动画与扫动控制器；上报层在无监听者时
  零开销（读取链路不创建任务句柄）。

## 五、与既有等待件的边界

- 按钮动作等待（保存/提交/删除等）仍用 `UtenBusyOverlay`；
- 可感知进度的长等待（导出/下载/批量审批）仍用 `UtenProgressDialog`
  （`showUtenProgress`）；
- 本组件只覆盖**页面表格数据的被动完整读取**，同一动作不叠加第二种等待件。
