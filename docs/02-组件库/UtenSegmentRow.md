# UtenSegmentRow - 按内容自适应宽度的分段行

> 创建：2026-10-04（替代 SDK `SegmentedButton` 的等宽分段；分类工具条
> `UtenFilterToolbar` 与页面内直用分段行统一换用本组件）

## 一、为什么存在

SDK `SegmentedButton` 的渲染对象把**每个分段强制铺成同一宽度**（取最宽分段的
固有宽度，或可用宽度均分；`segmented_button.dart` 的 `_calculateHorizontalChildSize`，
无任何开关）。两个字的小格被撑到和最长格一样宽，整条显得空（2026-10-04
用户口径：每格宽度跟随自身内容，字多/带徽章自动变长）。

`UtenSegmentRow`复用M3交互和三态语义，视觉统一价格分析页的圆角矩形分段风格，每格宽度自适应：

- `UtenFilterRow.borderRadius`圆角矩形描边（control10，enabled=`outline`，整条禁用=`onSurface@12%`）；
- 选中格 `secondaryContainer` 填充、文字 `onSecondaryContainer`；未选透明、
  `onSurface`；禁用文字 `onSurface@38%`、不填充；
- 格间1px分隔线；桌面高度下限36、触控实际目标宽高至少48窗口像素（`minCellHeight`默认
  `UtenFilterRow.minHeight`，与 UtenSearchBar 前后缀图标约束同源——InputDecorator
  描边只按内容高绘制，两侧共用同一角色）。每格内容padding水平8/垂直4，图标18、图文间距4；
- 悬停/按压水波按 M3（选中 onSecondaryContainer@8%/10%，未选 onSurface 同比）。

## 二、API（与 SegmentedButton 同形，迁移只改组件名）

```dart
UtenSegmentRow<String>(
  showSelectedIcon: false,          // 选中不出 ✓（默认 true 出对勾，同 SDK）
  segments: const [
    ButtonSegment(value: 'a', label: Text('全部')),
    ButtonSegment(value: 'b', enabled: false, label: Text('待办')), // 逐格置灰
  ],
  selected: const {'a'},
  onSelectionChanged: (selection) { ... }, // null = 只读不响应点击
  // emptySelectionAllowed: true,   // 点已选段取消回空集
  // multiSelectionEnabled: true,   // 多选
  // minCellWidth: 132, minCellHeight: 48,  // 个别要等宽观感的调用方（对账弹窗）
)
```

- 点选语义照抄 SDK `_handleOnPressed`：单选点已选段不回调；集合无变化不回调。
- 本 SDK 版本 `ButtonSegment.label`/`icon` 是 **Widget? 可空**（组件已按可空处理，
  纯图标分段也成立）。
- 计数徽章走 label 槽位（`UtenSegmentBadgeLabel`），文字颜色经
  `DefaultTextStyle` 自动继承本组件三态前景色。
- 浏览型括号计数完整继承宿主前景色，不再次降低透明度；红黄实底、零值、未知值、99+与完整语义计数保持原规则。
- 迁移先核对原重复点击语义：需要重新执行当前选择回调的消费者可启用
  `emptySelectionAllowed`，将空集映射回当前值，保留原回调且不清空业务选择。
  BOM条件与布局分段采用这一适配，原计数与表头筛选修剪不变，见
  [material_analysis_bom_tree.dart](../../lib/features/production/pages/material_analysis_bom_tree.dart)。

## 三、真实宽度与完整分类面板

`UtenFitOrCompact`按完整分段的实际intrinsic宽度选择呈现，兼容工具条的IntrinsicHeight。
直接使用本组件也会适配，不需要调用方包装横向滚动条或缩字。
超宽时显示当前分类（未选“选择分类”），点开纵向面板；长名称可换行。
`compactSummary`可保留分类总量，面板中`UtenSegmentBadgeLabel`会把名称和计数分开排布。
紧凑入口同样使用control10、36/48高度角色和8×4内容padding；触屏缩小档补偿后每项命中范围仍至少48窗口像素。
36与48均为下限，系统文字、图标和徽章参与内容测量并可撑高；应用整体倍率由根缩放树处理，组件不重复乘倍率。

隐藏分支排除焦点、语义和文本选择；选择面板返回时检查当前element仍挂载、当前值仍启用、
当前回调仍有效。多选、空选、只读、逐项disabled和nullable值保留原契约。

## 四、测试

`test/components/layout/uten_filter_toolbar_autoselect_test.dart`、`test/components/layout/uten_adaptive_category_layout_test.dart`、`test/components/uten_filter_toolbar_count_form_test.dart`。覆盖宽屏长分段、160逻辑宽及200%文字、双徽章、nullable分类、面板打开后撤销权限。
