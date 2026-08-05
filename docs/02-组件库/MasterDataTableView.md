# MasterDataTableView（Excel 风格数据表格 —— 全局唯一数据展示组件）

> 🚨 **本组件是全项目「数据展示」的唯一标准表格。** 所有报表 / 主档 / 单据列表 / 任何"行×列"的数据展示
> **必须**复用本组件，**禁止**另行手写 `ListView`/`Row`/`DataTable` 表格。详见
> [00-项目准则/09-组件库使用规范.md §十一](../00-项目准则/09-组件库使用规范.md)。
>
> 位置：`lib/features/basic_data/widgets/master_data_table_view.dart`
> （虽位于 basic_data 下，实为跨模块共享组件，6 大报表族 + 6 主档 + 各单据列表共用）。

---

## 一、用途 / 边界

| 场景 | 用什么 |
|---|---|
| **行×列数据展示**（报表 / 主档 / 单据列表 / 明细） | **`MasterDataTableView`（本组件，强制）** |
| 卡片瀑布流列表（工资条/报销/通知/建议） | `UtenResponsiveGrid`（见 [09-组件库使用规范.md §十](../00-项目准则/09-组件库使用规范.md)） |
| 设置项 / 纯菜单 | `ListView` |

**为什么必须统一用它**：一处改、全屏生效（排序/筛选/分页/导出/视觉）；杜绝每页各画各的表格、10 个页面 10 种交互。后续「导出加密 Excel」「行点击跳源头单据」等能力都只在本组件 + 共享层加一次，所有页面自动获得。

---

## 二、Excel 风格特性（开箱即用）

- **横排 autofilter 列头**：每列表头一个「标签 ▼」单元格，点开下拉筛选项（facet 桶 + 空值档），选中高亮。
- **列头排序**：可排序列（日期/金额/数量）点表头出排序菜单（从远到近 / 从近到远 / 取消，数值列用 从小到大/从大到小），当前排序列显 ▲/▼。**日期列只显排序菜单、不列日期值 facet**（日期值各不相同，列成筛选桶无意义）。
- **表头/表体横滚同步**：拖底部滚动条表头跟随，列始终对齐。
- **列宽自动适配**（默认）：每列默认宽度 = 该列最宽数据（表头 + 单元格 TextPainter 测量，取样前 100 行 + 内边距/图标富余），进表即撑满、不被截断；超长文本（如备注）封顶 480px + 省略号，可再拖宽。
- **列宽手动拖拽**：拖任一列右边界 8px 命中区改宽/改窄（桌面悬停显 resize 光标）；已手动拖过的列在数据刷新时保留用户宽度，其余列按新数据重新适配。
- **单击行高亮**：点哪行哪行高亮（淡主色），横向/竖向滚动时常驻，方便回头确认是哪一行；翻页/重查换对象后自然失效。可选 `onSelectionChanged(item)` 上抛选中项（与 `onRowTap` 同时触发，语义是"当前选中"）——BOM 组装页签据此定「添加组件」默认父级。可选 `isSelected(item)` 谓词走外部受控选中（按业务键比较）——item 每次 build 重建的场景（如 BOM `_BomRow`）用 `isSelected` 才能保持高亮，默认内部 `_selectedItem` 走引用相等只适合稳定对象（如 `GoodsListItem`）。
- **分页**：上一页/下一页 + 跳页输入框；翻页后表体竖向回顶。
- **空/错/加载态**：内置 `UtenEmpty` / loading / 重试。

---

## 三、API

```dart
MasterDataTableView<T>(
  columns: <MasterColumnDef<T>>,        // 列定义（key/label/width/value/type/sortable）
  items: <T>,                           // 行数据
  facets: {colKey: [MasterFacetBucket]},// 列头 autofilter 桶（后端 facets）
  nullCounts: {colKey: int},            // 各列空值档计数
  filters: {colKey: String?},           // 当前激活的列筛选
  onFilterChanged: (key, value) {},     // 列筛选回调
  sortColumn: String?,                  // 当前排序列 key（null=不排序）
  sortAscending: bool,                  // 排序方向
  onSortChange: (colKey?, ascending) {},// 排序回调（colKey=null 取消排序）
  onRowTap: (item) {},                  // 行点击（报表→跳源头单据；主档→详情弹窗）
  onSelectionChanged: (item)?,         // 可选：单击选中行上抛（BOM 据此定"添加组件"默认父级）
  isSelected: (item)?,                 // 可选：外部受控选中判定（item 重建场景用，按业务键比较）
  rowColor: (item) => Color?,           // 行底色（如货品按状态：使用=浅蓝/禁用=浅红）；
                                        // null=透明。单击选中自动加深加亮（提高不透明度），
                                        // 无底色行维持 primary 0.10 高亮
  isLoading / error / onRetry / emptyMessage,
  currentPage / totalPages / onPageChange,
)
```

`MasterColumnDef<T>`：`key`（与后端 query/排序参数对齐）、`label`（列头）、`width`（**仅作初始参考**；默认按内容自动适配，见 §二，已不直接用于布局）、`value`（单元格取值）、`type`（`text`/`date`/`number`/`money`/`bool`，对齐后端 `ReportColumn.type`）、`sortable`（日期/金额/数量列置 true）。

---

## 四、报表页接入范式（共享层，不写重复代码）

报表页**不要**自己定义 `_Col`/`_cell`/解析逻辑——一律用 `lib/features/report/shared/`：

| 共享件 | 用途 |
|---|---|
| `ReportColumn` / `ReportData` | 列定义 + 结果集 model（取代各页 private `_Col`/`_ReportData`） |
| `parseReportResponse(json, page)` | 解析后端 `ReportTableResponse`（列/行/facets/分页） |
| `formatReportCell(col, row)` | 按 type 格式化单元格（money/number→2位、bool→是/否、date→yyyy-MM-dd） |
| `isSortableReportType(type)` | 该列是否可排序（date/money/number） |
| `sortQueryParams(sortKey, asc)` | 生成 `{sort, order}` query 参数 |
| `defaultReportFrom()` | 报表默认起始日（今天往前一个日历月） |

报表页只需：声明 `_sortKey/_sortAsc` → `_load()` 里 `...sortQueryParams(...)` + `parseReportResponse(...)` → `_buildTable()` 里 `MasterColumnDef(type: c.type, sortable: isSortableReportType(c.type), value: (r) => formatReportCell(c, r))` + 传 `sortColumn/sortAscending/onSortChange`。**全部报表页范式一致，零重复。**

后端：6 个 `*ReportService.execute()` 调共享 `common/report/ReportSort.java`（sort 必须命中列 key 白名单 → 按投影别名 `ORDER BY`，防 SQL 注入）。

---

## 五、响应式 / 性能档 / 主题 i18n

- **响应式**：表格区随容器宽度横滚（列固定宽，不随断点变列数）；窄屏靠左筛选侧栏（`UtenListTwoPane`）折到顶部。
- **性能档**：表体 `ListView.builder` 按行懒加载；每行数据外包 `RepaintBoundary`，选中 / 列宽拖拽 / 刷新时只重绘本行、不蔓延整表与外层页面；超大结果集走服务端分页（默认 size 50，上限 500）。
- **主题**：取色全走 `colorScheme`（表头 `surfaceContainerHigh`、筛选/排序高亮 `primaryContainer`/`primary`）。
- **i18n**：列头菜单文案（从远到近/取消排序/所有/空值 等）当前为中文，**待补 arb**（组件内有 `TODO(l10n)` 标记）。

---

## 六、示例代码

```dart
// 报表页 _buildTable()（最简，完整范式见 sales_report_page.dart）
final columns = data.columns
    .map((c) => MasterColumnDef<Map<String, dynamic>>(
          key: c.key, label: c.label, width: (c.width ?? 120).toDouble(),
          type: c.type,
          sortable: isSortableReportType(c.type),
          value: (row) => formatReportCell(c, row),
        ))
    .toList();
return MasterDataTableView<Map<String, dynamic>>(
  columns: columns,
  items: data.rows,
  facets: data.facets,
  nullCounts: const {},
  filters: {for (final e in _filters.entries) e.key: e.value},
  onFilterChanged: _onFilterChanged,
  sortColumn: _sortKey,
  sortAscending: _sortAsc,
  onSortChange: _onSortChange,
  onRowTap: _onRowTap,       // 行点击跳源头单据编辑页（见 §八）
  currentPage: data.page, totalPages: data.totalPages, onPageChange: (p) {_page=p; _load();},
);
```

---

## 七、实现要点 / 避坑

- **横滚同步**：表头/表体各一个横向 `ScrollController` + 互听 + `_syncing` 防回环（Flutter 3.44 移除了 `LinkedScrollControllerGroup`）。
- **列头 overlay**：`CompositedTransformFollower` 锚定列头下方、限高 360、`TapRegion` 点外关闭；不全屏。
- **排序菜单 vs 筛选菜单**：可排序列 overlay 顶部是「排序」段、下方保留 facet 桶（Excel autofilter 范式）；纯日期列无 facet → 只显排序段。
- **服务端排序（非前端）**：报表分页，排序必须回后端（前端只发 `sort`/`order`，后端白名单 ORDER BY）；前端排序只用于极小结果集。
- **`shrinkWrap: true` 是刻意保留，勿动**：表体 `ListView` 用 `shrinkWrap: true` + 外层 `Flexible(loose)` + `ConstrainedBox(maxHeight)`，目的是「行少时表随内容收缩、不全屏撑满」。**不要**为省冷构建的全量 extent 布局改成 `false` / `widget.embedded`——会让短表撑满高度、留大片空白（一度试过并已回退）。行少收缩是产品要的行为；冷构建成本后续用 `TextPainter` 宽度缓存 / 降采样消除，不靠动 `shrinkWrap`。
- **后续能力落点**：导出按钮放 `UtenAppBar.actions`（Phase4）、行点击跳源头单据靠 `onRowTap` + 后端行带 `__srcId`（Phase5）——都在本组件/共享层加一次，全表生效。

---

## 八、行点击跳源头单据（Phase 5）

报表的明细/汇总行点击 → 跳对应单据编辑页（push → pop 回报表，保活筛选/分页状态）。机制（命名约定，非组件改动）：

- **后端**：明细/汇总报表的 `dataSelect` 末尾加 `, <头表别名>.id AS "__srcId"`，`cols` 末尾加 `ReportColumn.text("__srcId", "")`（**两处列数必须相等**，`execute()` 按位置 `r[i]` 取值）。`execute()` 末尾把 `columns` 过滤掉 `__` 前缀再返回 → 前端 `columns`、导出 Excel 都不含 `__srcId`，但 row Map 携带（`norm` 把 UUID 转 `toString`）。
- **前端**：报表页 `onRowTap(row)` 读 `row['__srcId']`，空则 return（汇总/对帐聚合行无单一源头），非空 `context.push(RoutePath.<doc>Edit(seg, srcId))`。
- **覆盖判断**：基于单据头的明细/汇总 → 加；跨客户/供应商/货品/月度聚合（MV/视图/`executeGrouped`）→ 不加。详见 [ADR-012](../99-决策记录-ADR/ADR-012-报表加密导出与列排序与行跳源头.md)。

---

**最后更新**：2026-07-27 · Phase 1 日期默认 + Phase 2 列排序（全模块）+ 组件级列宽自动适配/拖拽/单击行高亮 + Phase 3-4 加密 Excel 导出（[UtenExportButton.md](UtenExportButton.md)，独立 `*_report:export` 权限 V71）+ Phase 5 行点击跳源头单据（全 6 报表族）**均已完成**，集中编译/分析 0 错；运行时冒烟待用户重启后端后进行，见 `plans/unified-roaming-balloon.md`。
