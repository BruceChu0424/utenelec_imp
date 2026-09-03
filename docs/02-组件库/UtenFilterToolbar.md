# UtenFilterToolbar

> 源码：`lib/components/layout/uten_filter_toolbar.dart`
> 创建：2026-09-01（全平台「分类筛选 + 搜索」统一范式；同日引入层级/默认不选/徽章口径）
> 更新：2026-09-03（分类行去「全部」段 + 末尾「历史记录/历史单据」时间门控段 +
> 未选引导占位 UtenFilterPlaceholder；单据列表页待处理段徽章口径修订）
> 相关：[UtenSearchBar](UtenSearchBar.md) · [UtenHistoryTimeFilter](UtenHistoryTimeFilter.md) · UtenSegmentBadgeLabel（`components/feedback/`）

## 一、定位

页面上凡有「分类/状态筛选」的地方一律用本组件，不再手写筛选按钮、Chip 行或
自成一套的分段样式：

- **分段导航**：M3 胶囊 StadiumBorder、**选中只变背景色不出 ✓ 图标**，
  与搜索框**结构化严格同高**（宽屏行内 `IntrinsicHeight + stretch`，谁高都拉齐；
  密度/字号档变化下恒成立——visualDensity 对两侧折减不一致，不能靠各自设高度）；
- **计数徽章**：分段可挂数量（`count`），红色圆数字（`UtenSegmentBadgeLabel`），
  与工作台角标同款；`count == null`（加载中/未知）与 `≤ 0` 都不显示——不把
  「未知」伪装成 0，`> 99` 显 `99+`。计数须取该分段**全量口径**（非当前页推算）；
- **搜索框**：全平台唯一组件 `UtenSearchBar`（胶囊 + 清除 + 300ms 防抖），
  `searchHint` 不传且无 controller 时不渲染（纯分类工具条）；
- **响应式**：宽屏一行 `分段 | 搜索 | 弹性 | trailing`；窄屏（默认 < 840）分段
  横向滚动 + 搜索换行。

## 二、层级与选中规则（2026-09-01 统一；2026-09-03 收紧）

1. **大类在上、小类在下**：双维度页（来源/方向=大类，状态=小类）大类行
   （含搜索框）在上，小类行在下。范本：`warehouse_quality_results_page.dart`
   （来源类型+搜索在上，作业状态在下）。
2. **进页面默认不选，未选不发请求**：`selected` 传**空集**（`const {}`），
   内容区显示引导占位 `UtenFilterPlaceholder`（本组件文件内提供）——
   **点击分段后才构建/加载内容**（2026-09-03 起从「空集=不过滤照样加载」收紧为
   「空集=不加载」；工作台类页面仅允许进页面拉一次 size=1 概览取徽章计数）。
3. **分类行不放「全部」段（2026-09-03）**：只放真实阶段/分类段；「回到全量
   翻旧账」的诉求由**末尾「历史记录/历史单据」段**承担——该段选中后渲染
   [UtenHistoryTimeFilter](UtenHistoryTimeFilter.md) 时间行（时间段/全部），
   未选时间同样不发请求（时间门控），选定后才按日期范围加载（不限状态）。
   有子类别的页面，历史段放在**小类行末尾**（如品质检查结果的状态行、
   任务工作台的异常行之前的主行末尾）。
4. **级联解锁**：小类行传 `enabled: 大类已选`（或结构上仅随选中大类出现）；
   未选大类时整行置灰不可点，回调里同样防御性兜底。
5. **视图切换例外**：切换内容区的工具条（应付工作区、报表变体、检验域等）
   必须始终有选中项，不适用「默认不选」，也不参与层级解锁。

## 三、徽章口径

`count` 只挂在**看页面的用户需要下一步操作**的分段：

- 「全部」类分段不挂徽章（2026-09-03 起多数页面已无「全部」段）；
- 终态分段不挂（已完结/终态/已决定/已取消/红冲/历史记录段）；
- **单据列表页待处理段挂计数（2026-09-03 修订）**：采购 4 单据列表、委外
  8 业务列表、仓库 8 类单据列表——申请页挂「计划已下达（待分解）」计数、
  其余挂「草稿」计数。此修订**仅限单据列表页**；任务中心/工作台的草稿段
  仍维持 2026-09-01「草稿不计入待办数」口径（仓库单据草稿尚未进入待办流）。
- 下一步是别人操作的状态不挂（如 IQC 拒收页的「已退回待财务」「财务异常」
  ——那是财务的待办，本页是采购/委外用户）；
- 例外：品质检查结果页「等待结果」保留数量——与该页统一「未完结」口径
  （等待+待入库+需退回），卡片/工作台角标同口径。

**父分类徽章 = 其子类待办之和**（2026-09-01 补充）：任务中心页的大类分段
（如入库任务中心「采购入库」）右侧徽章 = 该分类下各小类真实待办数的总和，
与 hub 卡角标、工作台模块卡同源同口径（如 采购入库 = 采购预计到货 + 到货异常）。

## 四、用法

```dart
UtenFilterToolbar<StageSeg>(
  segmentsKey: const Key('purchase-doc-segments-orders'),   // 透传测试/语义锚点
  searchKey: const Key('purchase-doc-search'),
  segments: [
    UtenFilterSegment(value: const StageSeg.stage(0), label: '草稿', count: draftCount),
    const UtenFilterSegment(value: StageSeg.stage(1), label: '已审'),
    const UtenFilterSegment(value: StageSeg.stage(-1), label: '红冲'),
    const UtenFilterSegment(value: StageSeg.history(), label: '历史记录'),  // 末尾
  ],
  selected: _seg == null ? const {} : {_seg},  // 空集=进页不选、不加载
  onSelectionChanged: _selectSeg,
  searchHint: '搜索单据号',
  onSearchChanged: _applySearch,               // 300ms 防抖（异步检索）
)
// 内容区：未选 → UtenFilterPlaceholder；历史段未选时间 → UtenHistoryTimePlaceholder；
// 否则列表/表格。
```

范本实现：`purchase_doc_list_page.dart`（阶段+末尾历史记录+待处理段徽章）、
`warehouse_quality_results_page.dart`（双维度：大类+搜索上、小类解锁下、
小类末尾历史记录段）、`operations_workbench_page.dart`（阶段行+异常小类行）。

## 五、约定

- 回调语义由调用方负责：`onSelectionChanged` 单选（首个选中值，恒非空——
  空集只能出现在初始态）；
  搜索本地即时过滤用 `onSearchInputChanged`，异步检索用 `onChanged`。
- 泛型 `T` 直接用业务枚举或私有哨兵类（`stage(x)` / `history()`），避免页面
  再维护 String 映射。
- 表单内的分段选择（弹窗里的 合格/不合格 等）不是分类筛选，不用本组件。
