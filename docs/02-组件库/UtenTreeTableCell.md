# UtenTreeTableCell（表格树形层级单元格）

> 路径：`lib/shared/widgets/uten_tree_table_cell.dart` · 测试：`test/shared/widgets/uten_tree_table_cell_test.dart`
> 已接入：货品资料-组件信息（`goods_bom_tab.dart`，懒加载不传 `childCount`）/ 生产物料分析统一物料表（`material_analysis_material_table.dart`，2026-09-10 起传 `childCount` = 当前投影可见的直接子件数：产品行 = 直挂子件数、物料行 = `childCountByParent`；「只看缺料」/表头筛选下是可见数而非 BOM 全量；汇总行副标题已有「N 来源」不传）。**凡在 MasterDataTableView/UtenEditableGrid 类表格里展示「父子层级行」，层级标识一律用本单元格，不得各页自写缩进**（2026-09-04 起）。

## 一、解决什么

树形数据（BOM 组件树、物料分析 BOM 树）塞进表格后，「哪行是哪级的子件」看不清：
纯缩进在宽表里被其他列淹没，缩进±1 级肉眼难辨。旧实现各页自写，深浅口径不一。

UtenTreeTableCell 把层级表达收敛为**四重冗余标识**（颜色只是强化，永远不是唯一信号）：

1. **缩进**：每级 16px，`maxVisualDepth`（默认 8）封顶——超深旧 BOM 不至于把单元格拉爆；
2. **连续参考线**：`_TreeGuidePainter` 画祖先竖线 + 分支拐角线，`ancestorContinuations` 精确控制「下边还有兄弟」的断线，`isLastChild` 收尾；
3. **级联序号徽标**：`P1.1.2` 式，tabular 数字、按 depth%4 轮换取色（primary/secondary/tertiary/onSurfaceVariant）；
4. **显式层级标签**：`levelLabel`（如「组件 2 级」「产品」「物料汇总」），默认 `层级 N`。

## 二、交互

| 元素 | 行为 |
|---|---|
| 展开箭头（48×48 命中区） | 有子级（`hasChildren`）才显示；独立命中区，**与行选择/双击打开互不抢手势**；`Semantics(button, expanded)` 带中文朗读。**2026-09-10 起为 28px 层级色实心圆底 + 反相箭头**（用户口径「有子层级的行一眼要看到」），选中行（`foregroundColor` 白）自动反相为白底主色箭头；宿主传 `childCount` 时未展开态在圆底右下角叠「N」徽章（展开后消失），懒加载宿主（展开前不知数量，如货品 BOM）不传即无徽章 |
| 叶子节点圆点 | 无子级时 8px 圆点占位（alpha 0.45，与实心圆底拉开对比），与箭头同列对齐 |
| 路径行 | `pathLabel` 非空时追加「路径：A/B/C」（Tooltip 全文，超长省略）；`sequenceInline` 紧凑模式下同样支持 |
| 无障碍 | 整格 `Semantics(container)` 朗读 `标题，级联号 X，层级 N，副标题，路径 …`（`sequenceInline` 下不朗读默认层级标签） |

## 三、用法

```dart
MasterColumnDef<Row>(
  key: 'name',
  label: '货品 / 组件',
  width: 320,
  cellBuilder: (_, row) => UtenTreeTableCell(
    depth: row.depth,                      // 0 起；徽标/标签显示为 1 起
    sequence: row.sequence,                // '1' / '1.2' / '1.2.3'
    title: row.goodsName,
    subtitle: row.goodsCode,
    levelLabel: row.depth == 0 ? '产品' : '组件 ${row.depth} 级',
    hasChildren: row.hasChildren,
    expanded: row.expanded,
    onToggle: () => toggle(row),           // null=只读不展开
    toggleKey: ValueKey('toggle-${row.id}'),
    ancestorContinuations: row.ancestorContinuations, // 每级祖先是否还有后续兄弟
    isLastChild: row.isLastChild,
  ),
),
```

参数要点：

- `sequenceInline`（2026-09-04）：紧凑身份行——序号徽标与标题同排（「P1 外壳」），副标题（如编号）另起一行；不再渲染默认层级标签行。适合列多、以编号辅助识别的工作台表格（物料分析统一物料表）。默认 false 保持三层结构（徽标行 / 标题 / 副标题）；
- `foregroundColor`：需要按行语义染色（如物料分析的路线徽标色）时覆盖默认轮换色；
- `childCount`（2026-09-10）：可选下级数量；未展开时在圆底右下角叠「N」徽章，Tooltip「展开 N 个下级」、Semantics「展开 X 的 N 个下级」，展开后不显示。宿主按**当前可见投影**传（筛选/视图切换后重算），懒加载宿主（展开前不知数量）不传即无徽章；

- `ancestorContinuations[i] == false` 时第 i 级竖线断开（该祖先已无后续兄弟）；
  缺省保守连画；构造见调用方的行拍平逻辑（`material_analysis_material_table.dart`）；
- `maxVisualDepth` 只封缩进宽度，真实深度仍由序号与标签表达。

## 四、边界与口径

- 单元格不自持状态：展开/折叠状态与行数据由宿主页管理，本组件纯投影；
- 折叠行由宿主页跳过渲染（不是组件隐藏），分页/虚拟化口径也由宿主页定；
- 触屏长按与右键菜单由表格层（MasterDataTableView/UtenEditableGrid）提供，本组件不参与。
