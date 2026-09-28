# WeightText 与重量合计(只读重量显示件)

> 源码：`lib/shared/measurement/widgets/weight_text.dart`、`lib/shared/measurement/widgets/weight_totals.dart`、
> `lib/features/report/shared/report_total.dart` / `report_cell.dart` / `report_sort.dart`(`weight` 与 `count` 类型)。2026-09-28 引入，[ADR-135](../99-决策记录-ADR/ADR-135-仓库重量账与单重自学习.md)
> 关联：[WeightGridColumn](WeightGridColumn.md)(录入)、[UtenTotalsSummaryBar](UtenTotalsSummaryBar.md)(合计条)、[MasterDataTableView](MasterDataTableView.md)

## 一、口径(全仓统一)

- 数据一律千克；页面只按用户显示偏好换算，**不在前端做重量加法**(服务端分页表的合计由服务端算)。
- 显示偏好 `WeightDisplay`：自动 / 克 / 千克 / 吨 / 斤 / 磅 / 盎司；自动档不足 1 kg 显示克、不足 1000 kg 显示千克、其余显示吨，去尾零。
  偏好是账号级(`warehouseWeightUnitsPrefsProvider` 的 `display`)，工具条 `WeightDisplayUnitButton`「重量单位: 自动▾」切换，
  即时库存 / 库存详情 / 货品详情库存页签 / 库存分析 / 仓库报表 / 单据历史详情同步。
- 估算值前缀「≈」；未知显示「未称」(灰)，**永远不显示成 0**；没有库存时显示「—」。
- 重量来源悬停说明：MEASURED 实称 / EXACT 按数量(精确) / SLICE 按比例分摊 / AVERAGE ≈按库存均重 / ESTIMATE ≈按单重估算
  (`weightSourceLabel`、`isEstimatedWeightSource`)。
- 偏差文案按件数表达(按件计的单位取整)：入库「偏少约238个 (-4.8%)」、出库「比应发多约35个 (+1.5%)」；单重未学准不核对。

## 二、API

| 名称 | 说明 |
|---|---|
| `WeightText({kg, estimated, source, display, unknownText, style, textAlign})` | 只读重量文本；`display` 为 null 时跟用户偏好；给了 `source` 就悬停显示来源说明，`AVERAGE` / `ESTIMATE` 自动带「≈」 |
| `formatWeightValue(kg, {display, estimated, unknownText})` | 纯文本版(表格格式化、打印) |
| `formatWeight(kg, {display, withSymbol})` / `WeightUnit` / `WeightDisplay` | (`weight_unit.dart`) 单位换算与格式化；`WeightDisplay.exportUnit`(自动 → 千克) |
| `formatUnitWeight(kgPerBase, {unitName})` | 单重显示，小于 1 kg 按克(如 `2.312 g`) |
| `formatWeighQty` / `formatWeighQtyWithUnit` / `formatWeighQtyRange` / `formatSignedPct` | 件数、件数区间、带符号百分比 |
| `weightBasisText(params)` / `weightCheckShortText(check, ...)` / `weightCheckTooltip(...)` | 依据一行、核对短句、核对悬停说明 |
| `WeightTierBadge({tier})` | 可靠度徽标：可靠(绿) / 可参考(黄) / 未学准(红) |
| `WeightDeviationChip({check, mode, unitName, text, tooltip, showWhenNone})` | 「称重核对」标签(WARN 琥珀 / ALERT 红) |
| `WeightDisplayUnitButton` / `WeightUnitMenuButton<V>` | 只读表工具条「重量单位: 自动▾」；通用单位菜单按钮 |
| `weightAlertColor(theme, level)` | 偏差档位颜色 |
| `WeightTotalsSummary.of(weightsKg, {deviationRows})` | 采集表格(尚未保存的输入)在客户端汇总：`rows` / `weighedRows` / `unweighedRows` / `totalKg` / `deviationRows` |
| `weightTotalEntry` / `weightDeviationEntry` / `weightTotalEntries(summary, {label, display})` | 表尾「实称 125.3 kg (未称 3 行)」与「称重偏差 2 行」(无偏差行时整项隐藏)，接在明细 / 数量合计项之后 |

## 三、报表类型 `weight` / `count`

- `ReportColumn.type` / `ReportTotal.type` 新增 `weight`(值是千克)与 `count`(整数)。服务端 `ReportTotalsCalculator.TYPE_WEIGHT` / `TYPE_COUNT` 同口径。
- `formatReportCell(column, row, {weightDisplay})`：`weight` 列按显示单位换算，行里 `<列key>Estimated == true` 时加「≈」，null 显示「未称」；`count` 按整数。
- `reportTotalEntry(total, {weightDisplay, weightEstimated, weightUnknownRows})` / `reportTotalEntries(totals, {weightDisplay})` / `reportTotalsBar(totals, {weightDisplay})`：
  同一报表里 `<重量key>_unknown_rows` 与 `<重量key>_estimated_rows` 两个 `count` 合计自动并进重量项，显示「≈3.52 t (另有 12 项未称)」，全部未称时「N 项未称」；
  其余 `count` 项为 0 时整项隐藏。
- `isSortableReportType` 把 `weight` / `count` 纳入可排序；`MasterDataTableView` 本地排序对 `weight` 先换回千克再比较，「未称」排最后。
- 服务端导出：`weight` 列写数字单元格，列头带「(千克)」(即时库存导出按 `weightUnit` 参数换算并在列头写单位)。

## 四、使用处

即时库存(重量列与合计)、库存详情 / 货品详情库存页签(余额、流水、KPI)、库存分析(各分段与合计)、仓库报表页(`warehouse_report_table_page`)、
仓库单据详情与单据历史详情(重量列在数量组之后，历史里存的 0 视为没称)、出库批量明细(`warehouse_stock_outbound_detail_table`)、
各采集表格表尾(`weightTotalEntries`)。

## 五、测试

`test/shared/measurement/weight_unit_test.dart`(换算、解析、自动档)、`test/features/report/report_total_test.dart`(重量伴随计数折叠)、
`test/features/stock/instant_inventory_totals_bar_test.dart`、`test/shared/measurement/measurement_totals_test.dart`。
