# UtenTotalsSummaryBar（明细表下方合计条）

> 源码：`lib/components/data_display/uten_totals_summary_bar.dart`（2026-09-09 引入，2026-09-11 推广到全部单据详情/编辑页 + 报表/列表表格表尾）
> 关联：[MasterDataTableView](MasterDataTableView.md)、[UtenEditableGrid 单元规格](组件总览.md)

## 一、用途

单据审核/详情/编辑页「明细 → 汇总」的全站统一口径：与表体同宽、顶部分隔线、右对齐的「标签: 值」序列；
关键金额（本单金额/合计金额）传 `danger: true` 标红，与审核详情页头部「本单金额」同色规则。
财务订货审批审核详情、销售订单财务审核详情、采购/委外/销售/钱流单据详情与编辑页全部已接；
各页原先手写的「合计 ¥…」文本已按同一组件替换（币种取表头币种名，**不硬编码 ¥**）。

## 二、API

| 参数 | 说明 |
|---|---|
| `entries: List<UtenTotalEntry>` | 按展示顺序的合计项；`UtenTotalEntry(label, value, {danger})` |
| `density` | 紧凑模式（嵌入卡片内字号略小） |
| `showDivider` | 顶部分隔线（默认 true）；嵌在已自带上边框的容器（编辑页底部操作条）传 false，避免双线 |
| `compact` | 收紧纵向内边距（默认 false）。表格表尾槽位（`MasterDataTableView.summaryBar`）传 true：下方紧接翻页条（自带 8px 内边距），且 375px × 1.5 倍字号下这 8px 会把表体挤到溢出 |

规则：
- 值为空串或「—」（金额格式化的空值占位）的项**整体隐藏**，不会出现「折合本币: —」；
- 每一项是不可拆的 `Row`（标签 + 值），窄屏换行只发生在项与项之间；标签用半角冒号；
  值包 `Flexible`，窄屏/大字号在数值内部换行，绝不把 Row 撑溢出；
- **合计数量不得跨单位相加**：调用方按单位分组（`groupMeasurementTotals` / `measurementTotalsText`），多单位显示「12 个 · 3 箱」。

## 三、用法

```dart
UtenTotalsSummaryBar(
  density: true,
  entries: [
    UtenTotalEntry('合计数量', measurementTotalsText(...)),
    UtenTotalEntry('合计金额(人民币)', money(totalOriginal), danger: true),
    UtenTotalEntry('折合本币', money(totalLocal)),
  ],
)
```

## 四、辅助构造（同文件）

| 名称 | 用途 |
|---|---|
| `utenQuantityTotalEntry(amounts, {label})` | 「合计数量」项的唯一口径：内部走 `measurementTotalsText`，按 `unitId` 分组；明细为空返回「—」，由合计条整体隐藏 |
| `utenAmountTotalLabel(currencyLabel, {base})` | 金额项标签：币种名取自单据表头（配 `financeCurrencyDisplayLabel` 过滤 `001/002` 类内部编号）；无币种退回纯「合计金额」 |

编辑页另有 `EditableGridTotalsBar`（`lib/shared/widgets/editable_grid_totals_bar.dart`）：
包住本组件并订阅「增删行 + 金额合计 + 逐行数量控制器」三个刷新信号——单价为 0 时金额不变，
只订阅金额合计会漏刷数量。

## 五、服务端分页表格：合计必须由服务端算（铁律）

报表与列表表格**一律服务端分页**（一页 50 行）。前端对「当前页」求和会得出一个
看着像总计、其实只覆盖一页的数——**比不显示合计更糟**。因此：

1. 服务端用与列表**完全相同**的过滤条件（日期/facet/关键字 + **对象级授权谓词**）在
   整个结果集上聚合，与翻到第几页无关；实现见
   `server/.../common/report/ReportTotalsCalculator.java`：把列表查询原样包成派生表再
   `SUM`，派生表内不带 ORDER BY/LIMIT/OFFSET。
2. **绝不跨单位/跨币种相加**：服务端按分组列（单位名/币种名）`GROUP BY` 后分组下发，
   前端只负责拼成「12 个 · 3 箱」，前端侧不做任何加法——跨单位相加在结构上就不可能发生。
3. 拿不到服务端合计时**整条不渲染**（`reportTotalsBar` 返回 null），不伪造 0；
   实在要用当页数据，标签必须写成「本页合计」，不许出现无限定词的「合计」。
4. 报表按列**显式声明**才有合计：`ReportColumn.money("amount","金额").totaled("合计金额","currencyCode")`。
   默认不合计——单价、库存快照、单据表头总额（明细行上逐行重复，相加会翻倍）这类列
   相加无意义，**必须**保持不声明。
5. 客户端一次拉全、前端切页的表（如待检处置页）合计的是**当前筛选下的全部行**而非当页，
   目的与上面一致：合计数必须覆盖用户以为的范围。

位置：表格统一把合计条挂在**表体（内部滚动）与翻页条之间**
（`MasterDataTableView.summaryBar`），所以表体滚到哪一行合计条都在；
全屏表格与嵌入式明细表同样跟随。各页不自己摆位置，全站间距/字号因此一致。

## 六、接入表（2026-09-11）

| 页面 | 位置 | 合计项 | 门控 |
|---|---|---|---|
| 订货审批审核详情 `finance_procurement_approval_review_page.dart` | 明细表下 | 合计数量 / 合计金额(币种)🔴 / 折合本币 | — |
| 销售订单财务审核详情 `finance_sales_order_review_page.dart` | 明细表下 | 合计数量 / 合计金额(币种)🔴 | 销售阶段无本币事实，不出折合本币 |
| 采购单据详情 `purchase_doc_detail_page.dart` | 明细表下（`purchase-detail-totals`） | 合计数量 / 合计金额(币种)🔴 / 合计(本币) | `canViewCommercialAmounts`（含服务端 `priceMasked`）；申请单无金额口径 |
| 委外单据详情 `subcontract_doc_detail_page.dart` | 明细表下（`subcontract-detail-totals`） | 同上 | `canViewCommercialAmounts` + `_cfg.hasAmount` |
| 销售单据详情 `sales_doc_detail_page.dart` | 明细表下（`sales-detail-totals`） | 合计数量 / 合计金额(币种)🔴 / 合计(本币) | `priceMasked` 时金额项整体不渲染；订单阶段不出本币项 |
| 钱流单据详情 `finance_doc_detail_page.dart` | 明细表下（`finance-detail-totals`） | 合计金额(币种)🔴 / 合计(本币) | 无单位口径故不出数量；明细币种不唯一时不合计原币（跨币种与跨单位同理，绝不相加）；精确文本缺失则整项隐藏，不伪造 0 |
| 采购单据编辑 `purchase_doc_edit_page.dart` | 底部操作条（`purchase-edit-totals`） | 合计数量 / 合计金额(币种)🔴 | `_cfg.hasCurrency` |
| 采购订货编辑 `purchase_order_edit_page.dart` | 底部操作条 | 同上 | 行级条款：全单币种唯一才标注币种 |
| 委外单据编辑 `subcontract_doc_edit_page.dart` | 底部操作条 | 同上 | `_cfg.hasAmount`（无金额单据走总重文案） |
| 委外订货编辑 `subcontract_order_edit_page.dart` | 底部操作条 | 同上 | 行级条款：全单币种唯一才标注币种 |
| 销售单据编辑 `sales_doc_edit_page.dart` | `UtenEditableGrid.footer`（`sales-edit-totals`） | 数量 / 总金额(币种)🔴 | 免费客户出货显示「不收费（货款 0）」 |
| 钱流单据编辑 `finance_doc_edit_page.dart` | 底部操作条（`finance-edit-totals`） | 合计金额(币种)🔴 | 费用/收入/转账/分摊；收付款另有专用汇总卡 |

🔴 = `danger: true`（error 色 + 加粗）。

### 报表 / 列表表格表尾（2026-09-11，服务端合计）

统一经 `MasterDataTableView.summaryBar` + `reportTotalsBar(data.totals)` 接入
（`lib/features/report/shared/report_total.dart`）；合计项由**后端按列声明**，
前端不决定合计什么，因此下表「合计项」随后端声明自动生效。

| 页面 | 数据源 | 合计项 |
|---|---|---|
| 销售报表 `sales_report_page.dart`（含客户汇总下钻弹窗） | 服务端合计 | 订货明细：合计金额(按币别分组)；订货汇总：合计单据数 / 合计订货总额(按币别) |
| 采购报表 `purchase_report_table_page.dart` | 服务端合计 | 申请明细：合计数量(按单位) |
| 委外报表 `subcontract_report_table_page.dart` | 服务端合计 | 进仓/退货明细：合计重量 / 合计数量(按单位) / 合计金额 / 合计退货数量(按单位) / 合计退货金额；材料出仓/材料退货明细：合计重量 / 合计胶箱数量 / 合计数量(按单位) / 合计退货数量(按单位) |
| 仓库报表 `warehouse_report_table_page.dart` | 服务端合计 | **7 张明细表**：合计重量（调拨/其它入仓/领料/清退/产成品出仓）、合计净重（产成品进仓）、合计实际重量（盘点）、合计数量(按单位)，领料另出合计领料数量/合计已出库(均按单位)，盘点另出合计帐面数量/合计实际数量(按单位)。**7 张汇总表整张没有数量/金额列**，合计条不渲染 |
| 生产报表 `production_report_page.dart` | 服务端合计 | 计划明细：合计排产数量 / 合计完工数量（**按隐藏列 `__unitName` 分组**——本表不展示单位列，靠隐藏分组列也绝不跨单位相加）。计划汇总无数值列 |
| 钱流报表 `finance_report_table_page.dart` | 服务端合计 | 17 张表逐列判定，明细见[财务报表页](../03-页面/财务报表页.md#钱流各报表的声明口径2026-09-11-补齐) |
| 钱流账户流水 `finance_account_flow_page.dart` | 服务端合计 | 合计收款金额 / 合计支出金额（**窗口聚合 `SUM(...) OVER()` 顺带算出，零额外查询**）；余额是滚动值不合计 |
| 钱流对账单 `finance_statement_page.dart` | 服务端合计 | 往来流水/明细：合计立账金额(外，按币别)/(本) + 合计收付款金额(外，按币别)/(本)；年度对帐单：合计发货(收货)金额 / 合计回款(付款)金额。余额列一律不合计（逐行滚动值） |
| 即时库存 `instant_inventory_page.dart` | 服务端合计（**非报表服务页**，`/stock/instant-inventory` 返回 `TotaledPageResponse`） | 合计库存重量 / 合计库存数量 / 合计待检量 / 合计合格待入库（数量按单位分组）。合计跑在与表格同一段 core 上（分类子树 / 仓库范围 / 含不良品仓开关 / 关键字），见[即时库存页](../03-页面/即时库存页.md) |
| 待检处置 `quality_pending_disposal_page.dart` | **客户端全量**（本页一次拉全再前端切页） | 共 N 单 / 合计待检行数（合计的是当前筛选下全部行，非当页）；「待检数量」是各行自带单位的预格式化文本，无可靠数值+单位结构，故不做数量合计 |

前端零改动即可点亮任意一列：在对应 `*ReportService` 的列定义上加 `.totaled(...)` 即可，
**前提是该列真的可加**（见上「铁律」第 4 条）。

### 明确「不出合计」的列（口径清单，2026-09-11）

下面这些列**看着像能加、其实一加就错**，是全站统一的拒绝理由；新加报表列时先对照本表：

| 拒绝类别 | 典型列 | 为什么一加就错 |
|---|---|---|
| 单据表头金额逐行重复 | 费用/收入明细的「付款总额」「实付金额」、收款明细的「应收款金额」 | 一张单有 N 行明细就把同一个数算 N 遍 |
| 时点快照 | 「收款前未收」「本次后未收」「冲销前/后未收」 | 快照相加没有任何账务含义 |
| 累计状态快照 | 付款汇总的「已付金额」「未付金额」「本次余额」 | 取自立账台账的截至今日累计，不是本单发生额 |
| 逐行滚动余额 | 对帐单/账户流水的「余额」「应收余额(外/本)」 | 窗口滚动值，一行行相加是无意义的数 |
| 比率 / 单价 | 「汇率」「单价」「加工单价」 | 比率相加无意义 |
| 正负会互相抵销 | 应收汇总的「超出铺底额」 | 超限客户被未用满额度的客户抵销成「看着没风险」 |
| 主档政策属性 | 应收汇总的「铺底额」 | 授信上限不是发生额也不是余额 |
| 重复投影列 | 应付汇总「应付合计」、付款明细「付款总额」、付款汇总「本次付款」 | 与另一列是同一个 SQL 表达式，合计会把同一个数显示两遍 |
| 没有随行单位列的数量 | 费用明细「数量」、质检记录「本次合格/不合格」 | 跨行相加拼出一个无量纲的数 |
| 单位口径与行上「单位」列不一致 | 领料明细「实发数量」(base_qty)、即时库存「多排数量」(计划行单位) | 按「单位」列分组会贴错单位标签 |
| 受权限脱敏的金额 | 即时库存「库存台账金额」 | 合计绕过列脱敏 = 把总额漏给没权限的人 |
| 投影为字面量 NULL / 恒 0 | 盘点「帐面重量」、应收汇总「物料金额」、年度对帐「退货金额」 | 只会显示一个误导性的空/0 |
| 每行货品的快照/费率 | 「库存量」「安全库存」「人工费」 | 同一货品出现在多行就重复计数 |
| 行号 | 费用明细「序号」 | 是序号不是量 |

## 七、回归

- [`finance_review_totals_bar_test.dart`](../../test/features/finance/finance_review_totals_bar_test.dart)（两张审核详情：分组不相加、标红、销售无本币项、缺单位落桶）
- [`purchase_doc_detail_totals_bar_test.dart`](../../test/features/purchase/purchase_doc_detail_totals_bar_test.dart)
- [`sales_doc_detail_totals_bar_test.dart`](../../test/features/sales/pages/sales_doc_detail_totals_bar_test.dart)
- [`sales_doc_edit_v187_test.dart`](../../test/features/sales/pages/sales_doc_edit_v187_test.dart)（编辑页表尾合计条无 `¥`）
- [`report_total_test.dart`](../../test/features/report/report_total_test.dart)（服务端合计模型：多单位/多币种只拼不加、无分组维度不显示「单位未维护」、无数据整项隐藏不伪造 0）
- [`purchase_report_totals_bar_test.dart`](../../test/features/purchase/purchase_report_totals_bar_test.dart)（**当前页 2 行合计 12、服务端合计 900 个 · 20 箱**：改成对当页求和立刻变红；后端不下发 totals 时整条不渲染；375/834/1500 三视口 + 1.5× 字号不溢出）
- [`instant_inventory_totals_bar_test.dart`](../../test/features/stock/instant_inventory_totals_bar_test.dart)（即时库存同款：当页 2 行合计 12 vs 服务端 900 个 · 20 箱；不下发 totals 整条不渲染；375px × 1.5 倍字号不溢出）

服务端侧（`server/src/test/java/...`，全部盯死「覆盖整集 + 不跨单位/币种 + 拒绝列」）：

- `common/report/ReportTotalsCalculatorTest`：派生表里**不得出现 LIMIT/OFFSET**、列表参数原样绑定到聚合查询、
  一个分组维度一条聚合查询（与列数无关、无 N+1）、非法列名直接丢弃不拼 SQL；内存版覆盖 50 行而非当页 2 行、
  「单位未维护」排最后、全空则整项不出不伪造 0。
- `features/stock/report/StockReportTotalsTest`：领料明细合计领料数量/已出库按单位分组、**实发数量(base_qty) 不合计**、
  盘点「帐面重量」不合计、汇总表一条聚合查询都不跑。
- `features/production/report/ProductionReportTotalsTest`：按隐藏列 `__unitName` 分组、**订货数量不合计**、
  隐藏分组列不泄漏进前端 columns。
- `features/finance/report/FinanceReportTotalsTest`：原币按币别分组、**合计带上对象级授权谓词**
  （否则会把别人的单据算进总额）、单头金额/时点快照/累计快照/汇率一律拒绝。
- `features/stock/InstantInventoryTotalsTest`：合计与表格同一批行（关键字 / 含不良品仓开关 / 参与核算仓都在派生表里）、
  **脱敏的金额列与计划行单位的多排数量绝不合计**。
