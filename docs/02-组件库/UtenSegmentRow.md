# UtenSegmentRow - 按内容自适应宽度的分段行

> 创建：2026-10-04（替代 SDK `SegmentedButton` 的等宽分段；分类工具条
> `UtenFilterToolbar` 与页面内直用分段行统一换用本组件）

## 一、为什么存在

SDK `SegmentedButton` 的渲染对象把**每个分段强制铺成同一宽度**（取最宽分段的
固有宽度，或可用宽度均分；`segmented_button.dart` 的 `_calculateHorizontalChildSize`，
无任何开关）。两个字的小格被撑到和最长格一样宽，整条显得空（2026-10-04
用户口径：每格宽度跟随自身内容，字多/带徽章自动变长）。

`UtenSegmentRow` 逐格复刻 M3 默认样式，但每格宽度自适应：

- StadiumBorder 描边（enabled=`outline`，整条禁用=`onSurface@12%`）；
- 选中格 `secondaryContainer` 填充、文字 `onSecondaryContainer`；未选透明、
  `onSurface`；禁用文字 `onSurface@38%`、不填充；
- 格间 1px 分隔线（与描边同色）；高度下限 36（`minCellHeight` 默认
  `UtenFilterRow.minHeight`，与 UtenSearchBar 前后缀图标约束同源——InputDecorator
  药丸描边只按内容高绘制，两侧共用同一枚下限才能恒同高）；图标 18、图标与文字间距 8；
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

## 三、测试

`test/components/layout/uten_filter_toolbar_autoselect_test.dart`（宽度自适应两组）。
