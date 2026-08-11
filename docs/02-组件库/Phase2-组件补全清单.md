# Phase 2 组件提案状态核对

> 本文原为早期设计施工图。2026-07-30 已按当前源码改为历史提案与落地状态对照；当前可调用 API 以[组件总览](组件总览.md)为准。

---

## 一、主题提案

早期方案曾计划使用 `#0F3D2E` 和占位色阶。当前实现已经收敛为 teal 品牌色阶：

- 浅色 primary：`UtenColors.teal500`（`#14B8A6`）；
- 深色 primary：`UtenColors.teal400`（`#2DD4BF`）；
- slate 中性色和 success/warning/error/info 语义色已集中在 `uten_colors.dart`；
- 业务层裸 `Color(0x...)` 已清理。

不再执行旧的 `kUtenGreen`/green50–900 替换步骤。现行规则见[主题与配色规范](../00-项目准则/08-主题与配色.md)。

---

## 二、原提案与当前实现

| 早期名称 | 当前状态 | 当前入口/决策 |
|---|---|---|
| `UtenDropdown` | 已用更明确名称实现 | `UtenDropdownField` |
| `UtenDatePicker` | 已用更明确名称实现 | `UtenDateField` |
| `UtenAvatar` | 已实现 | `UtenUserAvatar` |
| `UtenConfirmDialog` | 已实现 | `UtenDialog` |
| `UtenMasterDetail` / `UtenTwoPaneLayout` | 已实现等价布局 | `UtenListTwoPane`；业务详情卡另有 `MasterDetailCard` |
| `UtenContentWidth` | 已实现等价布局 | `UtenContentContainer` |
| `UtenForm` | 已实现组合布局 | `UtenFormGrid`、`UtenSectionHeader`、`UtenBottomActionBar` |
| `UtenTreeView` | 在基础资料模块落地 | `UtenCategoryTreeView` |
| `UtenDataTable` | 在业务表格层落地 | `MasterDataTableView`；编辑明细用 `UtenEditableGrid` |
| `UtenTag` | 已有语义化替代 | `UtenStatusBadge` 或 Material `Chip` |
| `UtenLoading` | 未建独立包装 | 按场景用 `UtenSkeleton` 或主题化 `CircularProgressIndicator` |
| `UtenSwitch` / `UtenSlider` / `UtenIconButton` | 未建无意义薄包装 | 使用主题化 Material 组件 |
| `UtenWizard` | 未形成稳定跨模块 API | 各模块按业务状态机实现；复用明确后再抽取 |
| `UtenTimeline` | 未实现 | 各模块展示自己的审计/状态记录；统一事件模型后再评估 |
| `UtenViewContextSelector` | 未采用 | 当前权限模型不使用旧“全局视角”设计 |
| `UtenChartPlaceholder` | 不应实现占位公共件 | 有真实图表需求时直接选正式图表方案 |

---

## 三、已经补出的公共能力

原提案之外，实际项目还形成了：

- `UtenActionButton` 和 `ClickGuard`：异步动作与防连点；
- `UtenEmployeePicker`、`UtenLocationField`、`showUtenGoodsPicker`：常见业务选择；
- `UtenPagedGrid`：服务端分页卡片；
- `UtenFilterPane`、`UtenSegmentedFilter`、`UtenCollapsibleSection`：复杂筛选与区块；
- `UtenPrintPreviewButton`：统一打印预览；
- `UtenNotify`、全局通知队列和 `UtenCenterAlert`：分级反馈；
- `utenMakerAuditCells`、`validateLinkQuantity`、`LatestLinkRequestGuard`：单据公共校验与审计字段。

完整源码链接见[组件总览](组件总览.md)。

---

## 四、已删除的无调用组件

静态 import 可达性检查确认没有有效调用后，2026-07-30 删除：

- `UtenListItem`
- `UtenStatCard`
- `UtenAnimatedNumber`
- `UtenSelect`

同时删除旧主题包装/barrel、未使用的 `AppLogger` 和下拉辅助文件。页面需要 KPI 时使用模块业务卡或 `DocKpiBar`；数字默认直接显示，避免为装饰动画增加维护成本。

---

## 五、后续新增门槛

规划名称不能直接恢复为公共 API。新增前必须同时满足：

1. 已有至少两个真实调用场景，或安全/可访问性要求必须集中处理；
2. API 可以脱离单一页面模型；
3. 响应式、主题、loading/disabled/error 和测试方案明确；
4. 不与当前组件重复；
5. 实现、测试、组件总览和页面文档在同一变更中同步。

待需求确认而非当前缺陷的候选项只有：正式图表、统一审计时间线、跨模块向导。它们不计入当前生产能力。
