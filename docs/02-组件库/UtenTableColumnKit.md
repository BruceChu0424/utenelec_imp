# UtenTableColumnKit（表格表头列管理共用套件）

> 源码：[`lib/components/layout/uten_table_column_kit.dart`](../../lib/components/layout/uten_table_column_kit.dart)
> 接入方：[`MasterDataTableView`](../../lib/features/basic_data/widgets/master_data_table_view.dart)（货品资料等主数据表）、
> [`UtenEditableGrid`](../../lib/components/layout/uten_editable_grid.dart)（单据编辑明细表）
> 最后核对：2026-09-11（换位改「按下即拖」、新增行首多选列横滚冻结 `UtenFrozenLeadingColumn`）

## 一、为什么有它

2026-09-05 前主数据表与编辑明细表各养了一套「表头设置 + 拖出隐藏」：入口观感、弹层形态
（底部大弹窗 vs 按钮处浮层）、拖拽跟手效果（原地位移 vs 最顶层跟手浮层）渐行渐远。本套件
把两套交互收敛为**唯一实现**——全站表格（无论只读列表还是可编辑明细）的表头行为完全一致。

## 二、UtenColumnChooserButton（表头设置按钮 + 锚定浮层）

深绿实心大按钮「表头设置 x/y」+ 点击在**按钮处锚定**的浮层勾选列表（与货品资料筛选下拉
同款范式：`CompositedTransformTarget/Follower`、点弹层外/TapRegion 关闭）。

| 参数 | 说明 |
|---|---|
| `entries` | 全部列（key/label/**required**）；required=必填锁定 |
| `hiddenKeys` | 当前隐藏列集合（宿主持有，组件只读展示） |
| `onToggle` / `onToggleAll` | 单列切换 / 全选(true=全显，false=仅留首列+必填列) |
| `order` + `onReorder` | 提供后弹层行尾显拖拽把手、支持排序（onReorderItem 口径：newIndex 为 removeAt 后最终插入位） |
| `onReset` | 提供后弹层末尾显「恢复默认」行 |

弹层内容：`全选` 行（加粗）→ 各列行（勾选图标+名称；必填列标 `*` 并禁用，副标题
「必填列，不可隐藏」；最后一列兜底「至少保留一列」）→（可选）恢复默认行。限宽 260、
限高 clamp(240,520)、超 8 列显滚动条。宿主 setState 后 props 迟到一帧的浮层同步由
`didUpdateWidget` 的 post-frame `markNeedsBuild` 兜底。

测试锚点 key：`uten-column-chooser`（浮层）、`uten-column-chooser-scroll`（列表）、
`uten-column-option-<key>`（列行）。

## 三、UtenColumnHeaderDragHost（表头列手势宿主 mixin）

挂在表格 State 上（`with UtenColumnHeaderDragHost<YourWidget>`），提供**两类**表头手势
的完整机械：

### 3.1 竖滑拖出隐藏

- **跟手浮层**挂 root Overlay **最顶层**：拖出表头范围也始终可见、压在整表之上、不被表头/
  表体裁切；`CompositedTransformFollower` 锚定被拖列表头，`offset=(0, dy)` 跟手纵移
  （clamp ±120，原格不动仅浮层跟随）。
- **arm 阈值 10px**：累计纵向位移过阈值 → 浮层红底红×徽标（松开即隐藏）；拖回阈值内取消。
- **原格变淡**（Opacity 0.35 留原位）；`CompositedTransformTarget` 始终挂上。
- **单指契约**：并发第二指 no-op。

### 3.2 横拖换位（**按下即拖**，2026-09-11 改）

- **不再需要长按**。用户反馈「长按等太久」，改为与「竖拖移除」同级的即时拖拽：同一个
  `GestureDetector` 上挂横/竖两个 drag 识别器，**先往哪个方向越过 slop 就由哪个赢下
  竞技场**——主轴判定交给框架，不用自己算。
- 跟手浮层（与移除浮层同一视觉语言、中性色）横移跟随，原格变淡；拖动中表头行上渲染
  **插入位指示线**（2.5px 主色竖线）。松手按浮层中心落点计算槽位提交
  `onColumnsReordered(from, slot)`；横移 clamp 在表头列区内。弹窗拖拽排序与表头横拖
  是**同一份顺序状态的两个入口**。
- **代价（明说）**：表头本身不再能横拖滚动表格——该手势被换位吃掉。表体横拖与底部
  横滚条都还在，滚动能力没丢。
- 右边界 8px 的列宽手柄是 Stack 兄弟且在上层，其横拖优先命中，与换位不打架；
  列头 ⓘ 是 opaque 且吞长按，按在 ⓘ 上只开说明、不起拖拽。
- ⚠️ **必须 `DragStartBehavior.down`**：识别器「接受竞技场那一拍」的位移默认被吞——
  竖拖出去又拖回原位会误判 armed；start=down 让首拍 delta 从按下点起算，往返精确归零
  （kit 内已内置，手势区统一走 `columnHeaderGestureArea`）。

宿主实现抽象成员：`columnDragLink` / `columnDragWidth` / `columnDragLabel`（浮层锚点与
视觉）、`columnCanDragHide`（可隐判定）、`onColumnDragHide`（松手隐藏）、
`reorderVisibleColumns`（可见列有序布局）、`onColumnsReordered`（排序落位）；开关
`columnHeaderHideEnabled` / `columnHeaderReorderEnabled`（默认开，编辑明细表随
`showColumnSettings`）。

表头格用法（一行搞定全部手势）：

```dart
columnHeaderGestureArea(            // 横拖换位 + 竖拖移除识别器（外层，拖拽中不重建）
  i,
  columnHeaderCell(i, headerCell),  // 原格变淡 + 两类浮层共用的锚点 target
)
```

表头行外再包 `columnHeaderIndicatorOverlay(leadingInset: 前导选择列宽, child: 行)` 渲染
排序指示线。列集合变化/全屏切换调 `columnHeaderDragReset()`；dispose 经 super 链自动清理。
浮层视觉（`UtenColumnDragGhostCell`：列宽对齐、boxShadow 浮起、armed 红底红×）同文件。

## 四、已接入

| 表格 | 表头设置 | 竖拖移除 | 横拖换位 | 行首列冻结 | 备注 |
|---|---|---|---|---|---|
| MasterDataTableView（货品资料等主数据表） | ✅（含弹窗拖拽排序） | ✅（末列不隐） | ✅（会话内列序） | ✅（selectable 时） | — |
| UtenEditableGrid（单据编辑明细表） | ✅（+恢复默认+必填锁定） | ✅（+必填列不 arm） | ✅（走账号持久化回调） | ✅（有选择列时） | 三手势随 `showColumnSettings` 开关 |

## 四之二、UtenFrozenLeadingColumn（行首多选列横滚冻结，2026-09-11）

用户诉求：左右拖表格时勾选框列不能被滚走，一直看得见。

**做法**：勾选格照常留在 Row 里（列位与行高天然对齐、原交互不变）；同一行外包一层 Stack，
上面常挂一份跟手副本，按横滚偏移 `Transform.translate(dx)` 贴在视口左缘、盖住底下的数据格。
表头用表头那只 `ScrollController`，表体用表体那只（两者本就双向同步）。

**两条踩过的坑，改之前先读**：

1. **未横滚时副本必须 `IgnorePointer` + `Visibility(false)`**。一个 48×行高的 `Positioned`
   即使内容为空也会把落在首列的点击吃掉——实测把 BOM 树的展开箭头点不动了。
2. **不能靠宿主 `setState` 去增删这份挂载**。滚动回调里重建整行会让 `ensureVisible` 之后的
   点击落空（实测 4 个用例炸在这上面）。所以只切 `IgnorePointer`/`Visibility`、不动挂载，
   重建全部收敛在 `AnimatedBuilder` 内部。

**为什么不拆「左固定窗格 + 右滚动窗格」**：两张表的行高由内容决定（备注列会换行、多选态用
`IntrinsicHeight` 拉齐），两个窗格各自布局必然对不齐行高，还要再做一套竖向滚动同步。

**测试注意**：横滚后同一行会出现**两个** `Checkbox`（行内原位 + 冻结副本），按行定位勾选框
要用 `.first`；按 `find.ancestor(..., matching: find.byType(Row))` 取整行的老写法在冻结表上
应改取 `UtenFrozenLeadingColumn`。

## 五、测试

- [`test/master_data_table_view_drag_hide_test.dart`](../../test/master_data_table_view_drag_hide_test.dart)
  （拖出隐藏全套行为 + 浮层最顶层/原格大小回归 + 长按排序）
- [`test/master_data_table_view_column_chooser_test.dart`](../../test/master_data_table_view_column_chooser_test.dart)
- [`test/components/uten_editable_grid_column_settings_test.dart`](../../test/components/uten_editable_grid_column_settings_test.dart)
  （锚定弹窗 + 排序 + 必填锁定 + 跟手浮层统一性 + **长按排序直接落位与持久化**）
- [`test/components/uten_editable_grid_column_prefs_test.dart`](../../test/components/uten_editable_grid_column_prefs_test.dart)
  （持久化重放/迟到偏好/恢复默认）
- [`test/components/uten_editable_grid_perf_test.dart`](../../test/components/uten_editable_grid_perf_test.dart)
  （300 行构建计数契约：初建 ≤2 次/敲字零蔓延）

## 七、UtenColumnHintIcon（列头说明图标，2026-09-11）

`UtenColumnHeaderInfo` = 文案 + ⓘ；`UtenColumnHintIcon` = 只要 ⓘ（列头已自行渲染文案时用，
如 `MasterDataTableView` 的列头 Row）。两者行为同源：内部都是 `UtenFieldHintIcon`
（悬停 Tooltip + 点按/键盘弹说明），外面包一层 `GestureDetector(behavior: opaque, onLongPress: (){})`
把长按吞掉——否则触屏长按会 arm 列头的「拖拽隐藏列 / 排序」手势。

2026-09-11 起 `MasterDataTableView` 原先的私有 `_ColumnHeaderInfo`（Material `Tooltip` +
`showDialog`，长按触发、无键盘入口）已删除并改用本组件：全站列头 ⓘ 只有一份实现。
契约测试：`test/components/uten_editable_grid_chrome_width_test.dart`
（点按弹说明、长按不弹且不进入列头手势）。

## 六、列头说明 `UtenColumnHeaderInfo`（2026-09-10）

`UtenColumnHeaderInfo({required Widget label, required String message})`：列头「文案 + ⓘ」的唯一实现，
`MasterDataTableView`（`MasterColumnDef.info`）与 `UtenEditableGrid`（`EditableGridColumn.headerInfo`）共用。
内部复用输入框内的 [UtenFieldHintIcon](UtenFieldMessage.md)：悬停、点按、键盘聚焦同一行为（Tooltip
`triggerMode: tap`、maxWidth 480、44×44 命中区），外层 `GestureDetector(onLongPress: () {})` 吞掉长按——
触屏长按列头已让给「拎起排序」，说明图标不再与之打架。此前两张表各用一份 Material `Tooltip`（默认
长按触发、无点按入口）、输入框又是第三份实现，本轮收敛为一份。口径：列级通用说明放列头 ⓘ，
行特有说明留格内（[09-组件库使用规范](../00-项目准则/09-组件库使用规范.md)）。
