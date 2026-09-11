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
- **表头设置 + 拖出隐藏 + 长按排序（共用 UtenTableColumnKit，2026-09-05 起）**：「表头设置 x/y」深绿
  实心按钮点开**按钮处锚定的浮层勾选列表**（全选行/勾选显隐/拖拽排序把手，点弹层外关闭）；按住表头纵向
  拖出隐藏 = root Overlay 最顶层**跟手浮层**（原格变淡、过阈值红底红×、拖回取消、末列不隐）；**长按
  ~500ms 拎起横拖 = 直接排序列**（跟手浮层 + 插入位指示线 + 松手落位，会话内列序）。实现与编辑明细表
  `UtenEditableGrid` 同一份（`UtenColumnChooserButton` / `UtenColumnHeaderDragHost`），见
  [UtenTableColumnKit.md](UtenTableColumnKit.md)。
- **工具条控件统一高度 48（2026-09-05 起）**：表头上方工具条内的全部组件级控件——「表头设置」「全屏」
  「已选 N 项」摘要条——统一为 `UtenTableToolbar.controlHeight = 48`，与调用方挂进
  `toolbarActions` 的筛选 chip（如物料分析「全部 BOM」minHeight:48）等高对齐；`UtenButton`
  新增可选 `height:` 覆盖最小高度参与对齐（全站默认 44/52 不变，弹窗/页面主按钮不受影响）。
  调用方往工具条放按钮时也应传 `height: UtenTableToolbar.controlHeight` 保持同条等高。
- **单击选中、双击打开（全 App 列表页统一交互契约，2026-08-12）**：单击行 = 只选中
  （该行高亮淡主色/rowColor 加深，滚动时常驻，翻页/重查换对象后自然失效），**绝不打开**；
  双击行 = 触发 `onRowTap`（报表→跳源头单据；主档→详情：货品为整页路由 `/basicinfo/goods/:id`，
  其余主档为详情弹窗）。可选 `onSelectionChanged(item)`
  上抛单击选中项——BOM 组装页签据此定「添加组件」默认父级。可选 `isSelected(item)` 谓词走
  外部受控选中（按业务键比较）——item 每次 build 重建的场景（如 BOM `_BomRow`）用 `isSelected`
  才能保持高亮。**例外：`embedded:true`（picker/滑窗内明细表）保留单击直达**——picker 行的
  单击语义本来就是「选中这条」，不是「打开页面」，双击反而碍事。个别受限或没有详情的行
  通过 `canOpenRow(item)` 返回 false，不得暴露伪双击、伪鼠标可点状态或“打开详情”读屏动作。
- **双击判定是手动时间窗比对，不用 `DoubleTapGestureRecognizer`**：后者会在首次点击后
  hold 手势竞技场（~300ms），既让单击高亮延迟，又会拖住 `SelectionArea` 文本拖选手势的
  竞技场解析，大表拖选+自动滚动时触发 selection 子树访问已销毁行（FM2 defunct 崩溃）。
  手动判定（350ms 窗口内同行再点即打开，行键优先 `idOf`、无 idOf 回落全列可见文本）下单击
  **立即**生效、双击可靠打开、文本拖选零影响。
- **行右键/长按菜单**：传 `rowMenuBuilder(item)` 后，数据行右击（桌面/Web）或长按（触屏）
  弹出 [UtenContextMenu](UtenContextMenu.md) 自绘小框；弹出前组件自动把该行置为选中态
  （多选模式下该行未勾选则选择集替换为仅该行）。条目在手势触发那一刻构建，可按行数据/
  权限/剪贴板实时决定可用性；受限或无菜单的行用 `canShowRowMenu(item)` 返回 false，不能只靠
  builder 返回空数组，否则页面级菜单配置仍会给该行留下伪手势。选择可用条目后会等待其
  同步/异步动作完成再清空单选或受控多选；只点外部取消菜单时保留选择。
- **不占布局的无障碍打开入口**：非 embedded 且该行允许打开时，组件除双击外还提供读屏
  自定义动作“打开详情”；业务工作台可再用 `rowMenuBuilder` 提供右键/长按“打开关联单据”。
- **受控多选 + 表头三态全选 + 右下悬浮批量动作**：列表页可设 `selectable:true`，组件在首列显示
  复选框。表头 `false/true/null` 分别表示当前页全未选/全选/部分选；点击表头全选/取消当前页。
  选中集合由调用方的 `selectedIds` 持有（跨页保留）；组件只增加/移除当前页 ID，不擅自清空。
  多选模式下**单击行 = 切换勾选（与点勾选框等价），双击行 = 打开详情**。有 `batchActionsBuilder`
  时，「已选 N 项 + 清除选择」摘要与业务动作（批量审核/禁用/删除等）**同框悬浮在表格右下角**
  （2026-09-05 全站统一口径：选择数与按钮零距离；无悬浮动作的表格摘要仍驻表头上方）。
  **未选中时不再整组降透明**（2026-09-11 去掉 `Opacity(0.4)`）：叠在本就发灰的禁用按钮上会
  淡到「看不出这里能点」（物料分析、下达采购/委外/自制的用户反馈）。未选态的可辨识度改由
  控件自身承担——`UtenButton` 禁用态是实底 + 描边 + 可读灰字，`UtenSelectionSummaryPill`
  未选态是实底 + 描边。悬浮组里的「全选全部/全选筛选结果」类动作本来就必须在 0 选中时可点
  （业务按钮自身 `onPressed=null` 已不可提交），所以也从不加 `AbsorbPointer`；表体同时预留
  底部滚动空间，末行不会被遮挡。
- **行首勾选列横滚冻结**（2026-09-11）：`selectable` 表的勾选列在左右拖动表格时钉在视口左缘，
  始终可见。实现与两条踩坑见
  [UtenTableColumnKit §四之二 `UtenFrozenLeadingColumn`](UtenTableColumnKit.md)。
  **测试注意**：横滚后同一行有两个 `Checkbox`（行内原位 + 冻结副本），按行定位要用 `.first`。
  多选表体整体 `SelectionContainer.disabled`——勾选场景不需要文本复制，也挡住页面级
  SelectionArea（UtenContentContainer 默认包裹）渗入（2026-09-03，准则 §3.4）。
- **成功空态保留业务工具条**：主数据与前导分组都为空时仍渲染调用方的 `toolbarActions`
  (例如空 BOM 的“添加组件”)与 `toolbarLeadingActions`（视图切换 chip），再显示空态说明；初始加载
  和错误态不开放这组写动作，先完成数据确认或重试。**2026-09-11 起空态不再提供「进全屏」**
  ——放大一张没有行的表毫无意义，用户反而以为数据被按钮挡住了（销售订单财务确认「待确认」
  空态反馈）；**已在全屏中时按钮保留**（`退出全屏`，与工具条共用 `_fullscreenToggleButton`，
  key `master-table-fullscreen-toggle`）——0 行时不能被困在全屏路由。且当 `filters` 里有任何激活值
  （非 null/非空串，含「筛空值」哨兵）时在动作首位追加 **「清除筛选」**（key
  `master-table-clear-filters`，逐列回调 `onFilterChanged(key, null)`），空态说明补一行
  「当前有 N 个表头筛选生效」——列头筛选控件随表头一起不渲染，这是撤掉「看不见的筛选」的唯一出口
  （物料分析「路线待确认」筛选后确认路线 → 0 行 → 表头消失的死锁根因）。测试：
  `test/features/basic_data/widgets/master_data_table_view_empty_state_test.dart`。
- **文字框选(2026-09-03 全站口径，准则 §3.4)**：只读表体默认自带局部
  `SelectionArea`(跨格框选 + 复制，页面 region 嵌套时各管各的)；**表头整体
  `SelectionContainer.disabled`**——表头有「按住拖拽隐藏列/拖拽调宽」手势，与拖选隔离，
  且挡住页面级 SelectionArea 渗入。自动刷新或同时具有横向同步、纵向滚动、分页、行手势的
  重交互大表应传 `enableTextSelection:false`，显式隔离整个表格；这不改变行多选语义。
- **分页**：上一页/下一页 + 跳页输入框；翻页后表体竖向回顶。窄屏叠大字号（375px × 1.5×）
  放不下文案时翻页按钮自动收成纯图标，**恒为一行**（改折行会把表体挤到纵向溢出）。
- **`summaryBar`（2026-09-11 新增，表格下方合计条）**：挂在**表体（内部滚动）与翻页条之间**，
  所以表体滚到哪一行它都在；全屏表格与嵌入式明细表同样跟随。位置/间距只在组件里定义一处，
  接入页不自己摆位，全站因此一致。通常传 `UtenTotalsSummaryBar(compact: true, ...)`。
  **服务端分页的表格必须传服务端合计**——对当前页求和会得出一个看着像总计、其实只覆盖
  一页的数；拿不到服务端合计就别传，或把标签明写成「本页合计」。
  详见 [UtenTotalsSummaryBar](UtenTotalsSummaryBar.md) §五。
- **`onLoadMore`（2026-09-10 新增，滚动自动加载）**：表体竖向滚动临近底部（距底约 200px
  预取窗）时回调，配合 `loadingMore:true`（末尾追加转圈行，组件内同时防重入）实现
  「滑到底自动加载下一页」。组件不判断是否还有更多页——增量加载式页面不传
  `currentPage/totalPages`（传了会渲染翻页条），由调用方在回调里守卫（`page >= totalPages`
  即 no-op）；典型接入见员工列表页。
- **空/错/加载态**：内置 `UtenEmpty` / loading / 重试。`isLoading` 仅在 `items` 为空时显示
  整表转圈——刷新时仍持旧数据的页面表格原地保留（工具条/搜索框不卸载、焦点不丢）。
- **`toolbarActions`、`toolbarLeadingActions`、批量悬浮动作与全屏**：`toolbarActions` 的按钮排在工具条
  **右侧贴边**（全站口径：刷新等页面动作放表格右上角，多个动作间 s8 间距、宽度不足自动换行——
  2026-09-06 起），**全屏路由里同位置同样渲染**（全屏由 `showGeneralDialog` 整屏路由 +
  `_fsTick` 驱动重建，按钮闭包仍指向调用方 State 的方法，选中/数据变化经
  `didUpdateWidget → _fsTick` 实时刷新按钮可用态）。`toolbarLeadingActions`（2026-09-06 新增）
  的按钮渲染在「表头设置 / 全屏」同一左簇内、紧挨全屏按钮之后（吃 Wrap 的 s8 间距）——
  适合视图切换类 chip（如物料分析「全部 BOM / 只看缺料 / 待确认路线 / 按产品看 / 按物料汇总」），
  避免塞右侧贴边动作区后与全屏按钮相距过远且多按钮零间距粘连；窄屏（<720）与左簇并成一条
  Wrap 流式换行。右下批量动作属于表格内部 Stack，全屏
  路由同样渲染。调用方需要「全屏里也能操作」的非批量按钮（如 BOM 页签的编辑/删除/添加组件/
  审计模式）应挂 `toolbarActions`，勿放在表格外层工具条
  （外层工具条在全屏时被整屏路由遮盖）。`onFullscreenChanged`（2026-09-05）在进入/退出
  全屏各回调一次——宿主页可借此把搜索框等控件「常态放页面头部卡片、全屏时放回表格工具条」
  （两处共享同一控制器，物料分析页即此用法）。
- **`showSelectionSummary`（2026-09-06 新增，默认 true）**：控制「已选 N 项 + 清除」摘要
  是否驻留表头上方工具条。页面把批量动作放自己的 Scaffold 悬浮组、并在组内自摆
  `UtenSelectionSummaryPill` 时传 false，避免同一选择数在工具条与悬浮组重复出现
  （生产调度台待排产段即此用法）。

---

## 三、API

```dart
MasterDataTableView<T>(
  columns: <MasterColumnDef<T>>,        // 列定义(含可选 cellBuilder)
  items: <T>,                           // 行数据
  facets: {colKey: [MasterFacetBucket]},// 列头 autofilter 桶（后端 facets）
  nullCounts: {colKey: int},            // 各列空值档计数
  filters: {colKey: String?},           // 当前激活的列筛选
  onFilterChanged: (key, value) {},     // 列筛选回调
  sortColumn: String?,                  // 当前排序列 key（null=不排序）
  sortAscending: bool,                  // 排序方向
  onSortChange: (colKey?, ascending) {},// 排序回调（colKey=null 取消排序）
  onRowTap: (item) {},                  // 行「打开」操作（列表页=双击触发；embedded=单击）
  onSelectionChanged: (item)?,         // 可选：单击选中行上抛（BOM 据此定"添加组件"默认父级）
  onSelectionCleared: () {},           // 可选：菜单动作完成后同步清理页面外部单选状态
  isSelected: (item)?,                 // 可选：外部受控选中判定（item 重建场景用，按业务键比较）
  rowMenuBuilder: (item) => [...],     // 可选：行右键/长按菜单条目（UtenContextMenuEntry）
  batchActionsBuilder: (ctx, ids) => [...], // 可选：右下悬浮批量动作；选择摘要仍在表头上方
  selectable: true,                    // 列表页受控多选；embedded/picker/明细表禁止开启
  enableTextSelection: true,           // 只读表体文字框选；重交互/自动刷新大表可显式 false
  idOf: (item) => item.id,             // 多选业务键；无单一 id 时传稳定复合键
  selectedIds: selectedIds,            // 调用方持有的唯一选中真值
  onSelectedIdsChanged: (next) {},     // 行勾选与表头三态全选统一回交新 Set
  rowColor: (item) => Color?,           // 行底色（如货品按状态：使用=浅蓝/禁用=浅红）；
                                        // null=透明。单击选中自动加深加亮（提高不透明度），
                                        // 无底色行维持 primary 0.10 高亮
  isLoading / error / onRetry / emptyMessage,
  loadingMore: false,        // true 时表体末尾追加转圈行（配合 onLoadMore 自动加载）
  onLoadMore: () {},         // 竖向滚动临近底部回调；更多页判断在调用方
  currentPage / totalPages / onPageChange,
  summaryBar: UtenTotalsSummaryBar(compact: true, entries: [...]),  // 表体与翻页条之间的合计条
  primary: false,            // 联动折叠：包在 UtenCollapsingHeaderScrollView 的 body 里时传 true，
                             // 表体拾取注入的 PrimaryScrollController 参与「顶部折叠 → 表格内滚」联动；
                             // 不能与 embedded 同用。详见 UtenCollapsingHeaderScrollView.md
)
```

`MasterColumnDef<T>`：`key`(与后端 query/排序参数对齐)、`label`(列头)、`width`(**仅作初始参考**；默认按内容自动适配，见 §二，已不直接用于布局)、`value`(文本真值，继续用于列宽测算/排序/稳定行键/无障碍标签回退)、`cellBuilder`(可选自定义单元格；外层仍管列宽、内边距、网格线和选中底色，builder 只管内部内容)、`type`(`text`/`date`/`number`/`money`/`bool`，对齐后端 `ReportColumn.type`)、`sortable`(日期/金额/数量列置 true)、`cellColor`(单元格语义底色，列级；**底色与文字双向保证对比度**——`ThemeData.estimateBrightnessForColor` 判定，深色底自动切白字、**浅色底强制深字**（2026-09-05 修订：暗色主题下 `colorScheme.error/primary/tertiary` 是浅色，作底色时原先保留默认前景=白字不可读），缺口列传 `colorScheme.error` 即得红底白字，浅色底如 `errorContainer` 半透明保持默认前景色)。

自绘单元格的`cellBuilder`现在接收位于实际行样式之下的context，可通过`MasterDataTableCellScope.maybeOf(context)`读取`selected`与`foregroundColor`，同时继承正确的`DefaultTextStyle`和`IconTheme`。只读列表的单行高亮与可勾选列表的业务多选统一从此域取选中态；不要用页面`selectedIds`推测只读行是否高亮。自绘数量、输入值、单位与提示文字在选中时使用该域前景色，未选中仍保留业务语义颜色。

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
  summaryBar: reportTotalsBar(data.totals),  // 服务端合计（整个结果集），不是当前页求和
  currentPage: data.page, totalPages: data.totalPages, onPageChange: (p) {_page=p; _load();},
);
```

---

## 七、实现要点 / 避坑

- **多选只用于列表页**：`selectable:true` 必须同时提供 `idOf` 和 `onSelectedIdsChanged`，且不能与 `embedded:true` 共用。`selectedIds` 是只读输入，回调收到的是复制后的新集合；调用方不得依赖 item 引用相等。表头全选只作用于当前页可勾选行，已有的其他页选择保持不变。
- **文字框选与业务多选是两个开关**：`selectable` 只控制行复选框；`enableTextSelection`
  只控制只读表体是否创建局部 `SelectionArea`，默认 true 以保留复制。设置 false 或开启
  `selectable:true` 时整表使用 `SelectionContainer.disabled`；不要为了关闭文字框选把只读表
  伪装成可勾选表。
- **纯展示表不要传空回调**：没有真实详情/源单据可打开时省略 `onRowTap`，禁止用 `onRowTap: (_) {}` 占位；空回调会制造鼠标、选中与读屏都像可操作但实际无响应的假入口。
- **仅选择也是真交互**：页面只传 `onSelectionChanged`、不传 `onRowTap` 时，整行仍可
  单击选中，但不暴露“打开详情”的无障碍动作。BOM 将展开/折叠放进树单元格后使用此模式。
- **单选和多选语义互斥**：多选开启后，`isSelected`、`onSelectionChanged` 和内部单选高亮不再参与选择；单击行 = 切换勾选（与点勾选框等价），双击行 = `onRowTap` 打开详情。已选行双击时，第一次点击虽会即时切换，第二击识别为双击后必须补回勾选，保证打开详情不会让批量/悬浮主操作意外变灰。
- **右键选择是动作上下文，不是动作完成态**：菜单条目回调结束后组件清空选择；页面另有
  外部单选动作状态时传 `onSelectionCleared` 同步清理。点外部取消不清选，避免破坏用户
  右键前已有的多选。异步条目必须返回其 Future，不能在回调里无等待地另起任务。
- **双击打开不用 `DoubleTapGestureRecognizer`（FM2 防线，勿回退）**：双击判定是 onTap 内的手动时间窗比对（350ms，行键优先 `idOf`、无 idOf 回落全列可见文本——**不能用 `identityHashCode`**：单击选中触发重建后 item 引用已换，如 BOM `_BomRow` 每次 build 重建）。系统双击识别器会在首次点击后 hold 手势竞技场（~300ms）：① 单击高亮被迫延迟；② 拖住 `SelectionArea` 的 TapAndPan 解析，大表拖选+自动滚动时 selection 子树访问已销毁行 → "Cannot get renderObject of inactive element"（FM2 defunct 崩溃，2026-08-12 实测）。手动判定单击立即生效、文本拖选零影响；widget 测试里 `package:clock` 的 fake clock 随 pump 推进，双击用「tap + pump(50ms) + tap」驱动。
- **`embedded:true` 保留单击直达**：picker/滑窗内明细表的单击语义是「选中这条」而非「打开页面」，不参与单选双开契约（utn_goods_picker 等选择器弹窗双击会严重碍事）。
- **横滚同步**：表头/表体各一个横向 `ScrollController` + 互听 + `_syncing` 防回环（Flutter 3.44 移除了 `LinkedScrollControllerGroup`）。
- **列头 overlay**：`CompositedTransformFollower` 锚定列头下方、限高 360、`TapRegion` 点外关闭；不全屏。
- **排序菜单 vs 筛选菜单**：可排序列 overlay 顶部是「排序」段、下方保留 facet 桶（Excel autofilter 范式）；纯日期列无 facet → 只显排序段。
- **服务端排序（非前端）**：报表分页，排序必须回后端（前端只发 `sort`/`order`，后端白名单 ORDER BY）；前端排序只用于极小结果集。
- **多选行 stretch 必须套 `IntrinsicHeight`，勿拆**：selectable 模式的表头/表体行用 `CrossAxisAlignment.stretch`（单元格同高、网格竖线贯通），而表头在横向滚动视口内、表体行在竖向 `ListView` 内，高度都无界——stretch 会让子级拿到 tight `h=Infinity` 直接布局崩溃，表现为「表头设置按钮还在、表头表体整片空白」（2026-08-11 采购/委外/仓库任务台空白的根因，曾误判为 SelectionArea CME）。修复是 `_boundStretchRow()`：selectable 时套 `IntrinsicHeight` 先按内容收紧高度。**不要**为省一次固有布局拆掉它，也不要把 stretch 改回 center（网格竖线会断）。
- **`shrinkWrap: true` 是刻意保留，勿动**：表体 `ListView` 用 `shrinkWrap: true` + 外层 `Flexible(loose)` + `ConstrainedBox(maxHeight)`，目的是「行少时表随内容收缩、不全屏撑满」。**不要**为省冷构建的全量 extent 布局改成 `false` / `widget.embedded`——会让短表撑满高度、留大片空白（一度试过并已回退）。行少收缩是产品要的行为；冷构建成本后续用 `TextPainter` 宽度缓存 / 降采样消除，不靠动 `shrinkWrap`。
- **`primary:true` 联动折叠模式**：包在 [`UtenCollapsingHeaderScrollView`](UtenCollapsingHeaderScrollView.md) 的 `body` 里时传 `primary:true`——表体竖向 `ListView` 改用 `primary:true`（拾取 `NestedScrollView` 注入的 inner controller）、`shrinkWrap` 关、physics 改 `AlwaysScrollableScrollPhysics`、`_BodyFlex` 改 tight，参与「顶部折叠 → 表格内滚」联动；翻页回顶经 `PrimaryScrollController.maybeOf` + post-frame。**注意：联动模式下 `shrinkWrap` 必须为 false**（短表 `maxScrollExtent=0` 会让顶部收完后滚动卡死）——这是上条 `shrinkWrap:true` 规则的**唯一例外**，仅 `primary:true` 生效；默认 / `embedded` 路径仍保持 `true`。不能与 `embedded:true` 同用（断言拦截）。
- **后续能力落点**：导出按钮放 `UtenAppBar.actions`（Phase4）、行点击跳源头单据靠 `onRowTap` + 后端行带 `__srcId`（Phase5）——都在本组件/共享层加一次，全表生效。

---

## 八、行点击跳源头单据（Phase 5）

报表的明细/汇总行**双击** → 跳对应单据编辑页（push → pop 回报表，保活筛选/分页状态；单击只选中行）。机制（命名约定，非组件改动）：

- **后端**：明细/汇总报表的 `dataSelect` 末尾加 `, <头表别名>.id AS "__srcId"`，`cols` 末尾加 `ReportColumn.text("__srcId", "")`（**两处列数必须相等**，`execute()` 按位置 `r[i]` 取值）。`execute()` 末尾把 `columns` 过滤掉 `__` 前缀再返回 → 前端 `columns`、导出 Excel 都不含 `__srcId`，但 row Map 携带（`norm` 把 UUID 转 `toString`）。
- **前端**：报表页 `onRowTap(row)` 读 `row['__srcId']`，空则 return（汇总/对帐聚合行无单一源头），非空 `context.push(RoutePath.<doc>Edit(seg, srcId))`。
- **覆盖判断**：基于单据头的明细/汇总 → 加；跨客户/供应商/货品/月度聚合（MV/视图/`executeGrouped`）→ 不加。详见 [ADR-012](../99-决策记录-ADR/ADR-012-报表加密导出与列排序与行跳源头.md)。

---

## 九、生产物料分析接入边界

- 物料分析**历史页**是普通行列列表，宽屏复用本组件完成列宽、分页、加载/错误和行打开；当前历史页不做批量写，双击行只进入同一持久化分析（单击只选中）。
- 物料分析**详情页**使用统一 BOM 树，不再把 BUY/SUBCONTRACT/MAKE 拆成三块平铺。首屏默认“只看缺料”，搜索或筛选命中子件时保留祖先路径，并允许切换“待确认路线/全部 BOM”；不要为了“统一表格”丢失父子依赖和物料路径。
- 物料分析主表的**表头筛选**（进度 / 供应方式列）走本组件的 `facets / filters / onFilterChanged`：桶是**稳定键 + `MasterFacetBucket.label` 中文标签**（`_FilterCell` 渲染 `display`，回传 `value`），过滤在页面的节点投影层完成（命中行的祖先保留为只读上下文、`hasChildren`/子件徽章/视图 chip 计数同步），组件不参与业务过滤；0 行空态依赖上文「清除筛选」出口（2026-09-10）。列表页状态列徽章口径见 [DocStatusBadge](DocStatusBadge.md)。
- 只有路线已确认且满足业务门槛的可执行节点显示真实 48×48 复选框；“先确认路线/下层未齐/仅查看”等节点显示等高文字状态，不能伪装成可点击框。可执行节点仍遵守表头三态、单行复选、选中数量、整行/整卡高亮等可访问性语义，状态不能只靠颜色。
- 多选本身只改变客户端选择；生产详情中“提交采购/委外/自制需求”和“确认并提交审批”才是业务写按钮。组件选择状态不得被误写成已经通知、已经采购或已经生成计划。

参见[生产物料分析页与逐张计划单向导](../03-页面/生产物料分析页.md)。

---

- **客户端分桶（facets）的适用边界（2026-09-11 全站表头筛选清扫）**：调用方自算 facet 桶时，
  只有「整表一次装完、分页也在前端切」的页面可以这么做（如待检处置页把三域任务全装进
  `_rows` 再前端切页），此时桶计数与过滤都必须作用于**全集**、筛选后页码回第 1 页。
  **服务端分页的列表页不得用当页行自算桶**——那只会筛出当页的一小撮、计数还是错的；
  这类页面要么走后端已有的 facet/筛选参数，要么保持列头不可筛。调用方还须在刷新 / 切段 /
  换关键字后剪掉已失效的筛选值（`_pruneMaterialTableFilters` 同款），否则列头 sanitize 回
  列名、表体仍在过滤，用户会面对一张没有出口的空表（空态「清除筛选」是最后兜底）。

**最后更新**：2026-09-11 · 补记客户端 facet 的适用边界（只限整表装完的页面；服务端分页页面
不得按当页自算桶）与失效筛选值的剪除义务。前序 2026-09-10 · 成功空态保留「全屏/退出全屏」与 `toolbarLeadingActions`，有激活 `filters` 时给「清除筛选」出口并在空态说明标注筛选生效数（新增 `master_data_table_view_empty_state_test.dart`）；物料分析表头筛选改稳定键 + 中文标签接入。前序 2026-09-04 · 行菜单动作完成后统一清选，纯取消保留选择；成功空态保留业务工具条；`MasterColumnDef.cellBuilder` 支持行内按钮等自定义内容，同时保留 `value` 的数据与无障碍语义。2026-08-17：`primary` 联动折叠模式接入范围扩大。
此前：2026-08-14 · 新增 `primary` 联动折叠模式（配合 [`UtenCollapsingHeaderScrollView`](UtenCollapsingHeaderScrollView.md)：大屏列表页顶部卡上滑收起、表格内滚；联动模式下 `shrinkWrap` 为 false，默认 / `embedded` 路径仍 true）。货品 / 模具 / 客户 / 供应商 四个分类详情页接入。

**2026-08-13**：批量操作条改为**常驻**（selectable 且配置 `batchActionsBuilder` 时固定显示，不再"选中才出现"），未选中任何行时整条灰色禁用（`AbsorbPointer` 拦截 + Opacity 变淡 + 边框/文字降级中性灰）；生产计划列表页自绘批量条废弃，统一接入 `batchActionsBuilder`，与货品资料等主档页一致。生产物料分析当前仅完成本地/隔离克隆验证，目标库与真实岗位 UAT 仍为 NO-GO。


## 业务选择与显示行分离(2026-09-05)

- `selectionSummaryCount` 可指定真正选中的业务任务数；默认仍为 `selectedIds.length`。一行聚合多个任务或筛选隐藏已选任务时，摘要与悬浮动作保持一致。
- `onClearSelection` 可清除调用方全局选择，包括当前搜索、分页不可见的任务；普通表格仍默认回交空集合。
- `preserveSelectionOnContextMenu=true` 保留显式复选，右键查看详情不再临时替换或清空任务集合；默认值保持原有表格行为。
- 搜索无匹配但存在全局选择时，空态工具条仍显示真实计数与清除入口。业务写入仍由调用方按精确任务身份、权限和当前快照校验。

- 联动模式横向滚动条同时监听竖向滚动与内容尺寸变化，每帧合并测量；表头收起、详情返回或行高改变后不能把旧滚动条位置留在数据行中部。

> **2026-09-11 列头 ⓘ 收敛**：列头说明图标改用 [`UtenColumnHintIcon`](UtenTableColumnKit.md)（与 UtenEditableGrid 同一份实现：悬停/点按/键盘同入口、长按被吞掉不触发排序或拖拽隐藏），原私有 `_ColumnHeaderInfo`（Material Tooltip + showDialog）已删除。
