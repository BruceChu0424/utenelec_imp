# UtenTableColumnKit（表格表头列管理共用套件）

> 源码：[`lib/components/layout/uten_table_column_kit.dart`](../../lib/components/layout/uten_table_column_kit.dart)
> 接入方：[`MasterDataTableView`](../../lib/features/basic_data/widgets/master_data_table_view.dart)（货品资料等主数据表）、
> [`UtenEditableGrid`](../../lib/components/layout/uten_editable_grid.dart)（单据编辑明细表）
> 最后核对：2026-09-05(抽取成立 + 同日二扩：表头长按拎起横拖排序、DragStartBehavior.down 修首拍位移)

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

### 3.2 长按拎起横拖排序（2026-09-05）

- **长按 ~500ms 拎起**：跟手浮层（与隐藏浮层同一视觉语言、中性色）横移跟随，原格变淡；
  拖动中表头行上渲染**插入位指示线**（2.5px 主色竖线）。
- **松手落位**：按浮层中心落点计算槽位提交 `onColumnsReordered(from, slot)`；横移 clamp
  在表头列区内。弹窗拖拽排序与表头长按排序是**同一份顺序状态的两个入口**。
- 手势消歧：快速竖滑→隐藏；按住不动拎起→排序；横滑未按住→表头横向滚动。
- ⚠️ **必须 `DragStartBehavior.down`**：长按识别器在指针移动时不提前退出竞技场，竖拖
  「接受竞技场那一拍」的位移默认被吞——拖出去又拖回原位会误判 armed；start=down 让
  首拍 delta 从按下点起算，往返精确归零（kit 内已内置，手势区统一走
  `columnHeaderGestureArea`）。

宿主实现抽象成员：`columnDragLink` / `columnDragWidth` / `columnDragLabel`（浮层锚点与
视觉）、`columnCanDragHide`（可隐判定）、`onColumnDragHide`（松手隐藏）、
`reorderVisibleColumns`（可见列有序布局）、`onColumnsReordered`（排序落位）；开关
`columnHeaderHideEnabled` / `columnHeaderReorderEnabled`（默认开，编辑明细表随
`showColumnSettings`）。

表头格用法（一行搞定全部手势）：

```dart
columnHeaderGestureArea(            // 竖滑隐藏 + 长按排序识别器（外层，拖拽中不重建）
  i,
  columnHeaderCell(i, headerCell),  // 原格变淡 + 两类浮层共用的锚点 target
)
```

表头行外再包 `columnHeaderIndicatorOverlay(leadingInset: 前导选择列宽, child: 行)` 渲染
排序指示线。列集合变化/全屏切换调 `columnHeaderDragReset()`；dispose 经 super 链自动清理。
浮层视觉（`UtenColumnDragGhostCell`：列宽对齐、boxShadow 浮起、armed 红底红×）同文件。

## 四、已接入

| 表格 | 表头设置 | 拖出隐藏 | 长按排序 | 备注 |
|---|---|---|---|---|
| MasterDataTableView（货品资料等主数据表） | ✅（含弹窗拖拽排序） | ✅（末列不隐） | ✅（会话内列序） | 行为与 2026-09-05 前完全一致（测试零改行为断言） |
| UtenEditableGrid（单据编辑明细表） | ✅（+恢复默认+必填锁定） | ✅（+必填列不 arm） | ✅（走账号持久化回调） | 三手势随 `showColumnSettings` 开关 |

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
