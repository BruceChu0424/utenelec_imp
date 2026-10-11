# WeightGridColumn(仓库采集表格「实称重量」列)

> 源码：`lib/shared/measurement/widgets/weight_grid_column.dart`(2026-09-28 引入，[ADR-135](../99-决策记录-ADR/ADR-135-仓库重量账与单重自学习.md) §3.4)
> 配套：`lib/shared/measurement/` 的 `weight_unit.dart`(单位与换算)、`weight_prefs.dart`(账号级单位偏好)、`weight_params.dart`(单重参数、核对、仓储)、
> `weight_predictor.dart`(与服务端 `ApwPredictor` 对拍的纯 Dart 预测)、`weight_mass_units.dart`(按重量计的单位)
> 关联：[称重计数弹窗](WeighCountDialog.md)、[WeightText 与重量合计](WeightText.md)、[UtenTotalsSummaryBar](UtenTotalsSummaryBar.md)

## 一、用途

仓库执行页面凡是库管录入或确认数量的明细行，都在数量组(数量后紧跟单位时即单位)之后加一列重量，全仓一个长相一个口径：
到货登记、产成品登记、仓库单据与盘点、领料出库 / 批量领料、生产退料收仓、销售出库、委外出仓。
重量只进仓库重量账与单重学习，**永不拦截数量过账**，也不改计划 / 成本 / 预留口径。

> 2026-10-04([ADR-151](../99-决策记录-ADR/ADR-151-表单草稿回到初始值单重参数结构化契约与入库登记单批合一.md) §3)：页内 `WeightParamsCache` 按结构化身份取参(单重按货品+供应商，库存均重参考按仓库+货品+颜色，不再拼字符串 key)。取参失败不再静默：页面在表格上方放 `WeightParamsLoadNotice(cache: ...)`(`lib/shared/measurement/widgets/weight_params_load_notice.dart`)，显示「单重参数读取失败：原因」并提供只重取失败行的「重试」；格子仍退回「可选」占位，数量照常登记。

## 二、口径

- **单位**：固定六种 克 / 千克 / 吨 / 斤 / 磅 / 盎司(G/KG/T/JIN/LB/OZ，1 斤 = 0.5 kg，1 lb = 0.45359237 kg)，存储一律千克、HALF_UP 4 位小数。
  表头「实称重量(kg)」随录入单位变化；录入单位是账号级偏好(`warehouseWeightUnitsPrefsProvider`，key `warehouse.weightUnits`，
  `{entry: 'KG', display: 'AUTO', sample: 'G'}`)，工具条 `WeightEntryUnitButton`「称重单位: 千克▾」切换，所有采集表格同步。不做逐行单位下拉。
- **输入**：格子接受带后缀的写法 850g / 1.2t / 3斤 / 2lb / 1,200 g / 全角数字，也接受纯数字(按列单位)；失焦后规范成列单位。
  0 或空 = 没称。看不懂时红框提示「看不懂这个重量, 例: 850g、1.2t、3斤、12」。表头 ⓘ：「填净重(扣除箱/袋); 可直接输 850g、1.2t、3斤; 空着=没称」。
- **占位**：入库「约 12.5」、出库「应称 12.5」、单重未学准「可选」。
- **预填建议**（2026-10-10 口径）：系统预填的建议重量不再用「≈」前缀与格下「预估 · 请填实称」小字，改走全站预填黄框 + ⓘ
  （`applyAutofillHint` + `UtenInputDecoration(info:)`，与数量格黄框同款）；ⓘ 内容即来源与预估说明。
- **格内 ⚖ 按钮**（2026-10-10 口径）：16px 图标 + 24×24 命中槽（与全站表格内输入格高度统一口径一致，
  此前 44×44 触控槽会把整格撑高、与同行输入格不齐）；输入框 `suffixIconConstraints` 同步 24。
- **焦点保持**（2026-10-10 修复）：格子外层 Tooltip 恒定包裹，空闲时给固定短提示
  `weightCellIdleTooltip`。若按「有/无说明」切换 Tooltip 包裹，首个字符击键会让 Flutter 废弃重建
  TextField 元素、光标丢失（用户得再点一次才能继续输）；恒定结构下只有文本在变。
- **按重量计的行**：货品基本单位或行单位登记了「等于哪种重量单位」时只读灰字「=25 kg」(按数量精确换算)，提交不带重量，也不学习。
- **偏差**：学到单重且可以核对时，WARN 琥珀框 + 琥珀 ⓘ、ALERT 红框 + 红 ⓘ，悬停给件数说明(按件计的单位取整，如「偏少约 238个 (-4.8%)」)；
  单重未学准不核对，只提示「单重还没学准, 暂不核对 - 可点「称样校准」」。只有依据是人工单重，或按独立点数学到的单重时才报警。
- **按称重推算数量**：数量空着(盘点实盘、其它入库、领料「本次出库」清空后等)且单重不是未学准时，填重量自动推算数量：
  数量格黄框预填，ⓘ「按称重推算 5,373~5,449个」，行打上 `qtyFromWeight`(不参与单重学习)。改重量才清除该标记；改数量只清黄框。
- **永不批量生效**：勾选多行后改一行的重量只改这一行(一次称重是一个物理事实)；页面级的只有工具条上的录入单位。有 widget 测试锁定。

## 三、API

| 名称 | 说明 |
|---|---|
| `WeightEntryController({kg, unit, qtyFromWeight})` | 一行的重量状态，放在行 model 里随行创建 / 释放。事实源是 `kg`(千克 4 位)；`text` 是它在当前单位下的样子。`setKg`、`switchUnit`、`normalize` 程序写值不重新解析(lb/oz 来回切不漂)；`hasError` / `errorText`；`qtyFromWeight`；`qtyEstimateNote`；`markQtyDerived(qtyText, note:)`；`canonicalKeyPart`(`千克\|0/1`，幂等键用) |
| `WeightEntryRowMixin on EditableGridRow` | 行上挂一个 `weightEntry` 并随行 dispose |
| `WeightQtyAutofill<T>({qtyControllerOf, unitRateOf, enabledOf})` | 「数量空着时按称重推算数量」接线；数量格须是 `UtenAutofillTextController` |
| `weightGridColumn<T>({controllerOf, entryUnit, key, label, width, mode, paramsOf, paramsListenable, qtyBaseOf, qtyListenableOf, exactKgOf, baseUnitNameOf, enabledOf, required, requiredOf, qtyAutofill, onWeighCount, onChanged, headerInfo})` | 生成 `UtenEditableGrid` 列。`mode` = `WeightCaptureMode.inbound / outbound / count`；`paramsOf` 通常取页面级 `WeightParamsCache`；`exactKgOf` 给行单位是重量单位时的精确重量；`onWeighCount` 给了就在格内挂 ⚖ |
| `WeightEntryUnitButton` | 工具条「称重单位: 千克▾」 |
| `weightRowMenuEntries({onWeighCount, onSample, sampleEnabled})` | 行右键菜单「称重计数...」「称样校准...」 |
| `weightDeviationRowCount(rows, ...)` | 表尾「称重偏差 N 行」计数(按称重改过数量的行不算) |
| `warehouseUnitMassUnitsProvider` / `warehouseExactLineKg(...)` | (`weight_mass_units.dart`) 单位 → 重量单位字典(会话级单位字典的 `massUnitCode`)；行精确重量 |

单重参数：`WeightParamsCache`(`weightParamsCacheProvider`，页面级 autoDispose)按 `goodsId|supplierId` 缓存
`POST /api/stock/weight/params` 的结果(一次最多 500 行，自动分批)；`WeightParams.check(qtyBase:, weightKg:, mode:)` 给出 `WeightCheck`(应称、偏差%、件数差、档位)。

## 四、接入步骤(UtenEditableGrid 采集表格)

1. 行 model 持有一个 `WeightEntryController`(或混入 `WeightEntryRowMixin`)，随行 dispose；数量格改用 `UtenAutofillTextController`。
2. 页面 watch `warehouseWeightUnitsPrefsProvider`，把 `.entry` 传给 `weightGridColumn(entryUnit:)`；工具条 `toolbarActions` 放 `const WeightEntryUnitButton()`。
3. 行加载后 `cache.ensure(lines)`，传 `paramsListenable: cache`、`paramsOf: (r) => cache.of(goodsId, supplierId: ...)`。
4. 提交带 `weight.kg`(已是千克 4 位)与 `qtyFromWeight`(仅 true 时)；客户端幂等键 / 指纹带上 `canonicalKeyPart`(或 `weightKeyPart(kg)` + 0/1)，改重量就是另一个请求。
5. 表尾：`[...基础合计项, ...weightTotalEntries(WeightTotalsSummary.of(...), display: ...)]`(见 [WeightText](WeightText.md))。
6. 称样保存后 `cache.invalidateGoods(goodsId)` 再 `ensure`，占位与核对立刻用新单重。
7. 表单草稿用 `weightEntryDraft` / `restoreWeightEntryDraft`(`lib/features/warehouse/models/warehouse_form_draft_codec.dart`)保存重量、`qtyFromWeight` 与黄框。

## 五、各页适配件

- **入库表格**(`lib/features/warehouse/widgets/inbound_registration_widgets.dart`，到货登记与产成品登记共用)：
  `InboundGridColumns.weight(...)`(列键 `weight`) / `InboundGridColumns.weightCheck(...)`(列键 `weightCheck`，「称重核对」只读标签列)；
  `WarehouseQtyInputField`(带黄框 ⓘ 的数量格)；`warehouseWeighCount(...)`(打开称重计数并写回一行)；
  `warehouseWeightKeySuffix` / `warehouseWeightKeyPart`(幂等键重量指纹)；`warehouseWeightTotals` / `warehouseWeightCheckText`；
  `inboundTotalsBar(..., weight:, weightDisplay:)`。
- **仓库单据表格**(`lib/features/warehouse/widgets/stock_grid_columns.dart`)：`stockGridColumns(onPickGoods, isCheck:, weight: StockGridWeightWiring(...))`；
  盘点另有只读「账面重量」与可选「实盘重量」列。
- **出库明细表**(`MasterDataTableView` 只读表 + 行内输入，不是 `UtenEditableGrid`)：
  - `lib/features/warehouse/models/outbound_weight_entry.dart`：`OutboundWeightEntry`(做成 `EditableGridRow` 只为复用上面的格子；`qtyOf` 取行数量，`unitRate` 换基本单位)，
    `ensureOutboundWeightParams`、`outboundWeightTotals`、`drawIssueWeightEntry` / `drawRemainingWeightEntry`。
  - `lib/features/warehouse/widgets/outbound_weight_columns.dart`：`outboundWeightColumn<R>`(可编辑「实称重量」/「本次重量」，借用 `weightGridColumn` 的格子原样渲染)、
    `outboundWeightCheckColumn<R>`(「称重核对」，如「比应发多约35个 (+1.5%)」)、`weighOutboundEntry`(出库反推称重计数，只回填重量)、
    `OutboundWeightSummaryBar`(「明细 N 行 · 实称 X (未称 N 行) · 称重偏差 N 行」)。
  - 用于领料出库明细(`ProductionDrawDetailTable`)、批量领料、生产退料收仓、销售出库(`WarehouseSalesPickingDraft`)、委外出仓(`SubcontractOutboundLineDraft`)。
    页面只在有带货品 id 的行时创建参数缓存，首帧后一次性取全部行参数。
- 读侧只读显示不用本列，用 [WeightText](WeightText.md)。

## 六、测试

- `test/shared/measurement/weight_grid_column_test.dart`(后缀解析、EXACT 只读、不批量生效、推算数量黄框)、`weight_unit_test.dart`、`weight_predictor_golden_test.dart`。
- 页面：`warehouse_arrival_weight_capture_test.dart`、`stock_doc_edit_weight_test.dart`、`stock_doc_detail_weight_test.dart`、`warehouse_sales_outbound_batch_test.dart`、
  `subcontract_outbound_execution_test.dart`；测试替身 `test/features/warehouse/arrival_weight_test_support.dart`、`outbound_weight_fakes.dart`(带货品 id 的页面测试须覆盖 `weightRepositoryProvider`)。
