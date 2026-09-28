# 称重计数弹窗 / 面板 与 称样校准弹窗

> 源码：`lib/shared/measurement/widgets/weigh_count_dialog.dart`(`showWeighCountDialog` / `WeighCountPanel` / `applyWeighCountResult`)、
> `lib/shared/measurement/widgets/weight_sample_dialog.dart`(`showWeightSampleDialog`)。2026-09-28 引入，[ADR-135](../99-决策记录-ADR/ADR-135-仓库重量账与单重自学习.md) §3.3 / §3.4
> 关联：[WeightGridColumn](WeightGridColumn.md)(格内 ⚖ 与行菜单入口)、[称重计数页](../03-页面/称重计数页.md)(独立页嵌同一面板)、[GoodsStockLedgerPanel](GoodsStockLedgerPanel.md)(单重学习分段)

## 一、称重计数(`showWeighCountDialog` / `WeighCountPanel`)

用秤数个数：毛重(可「再称一次」多次相加) − 皮重(每件箱/袋) × 件数 = 净重，再按学到的单重折算件数。

- **结果**：件数 + 95% 区间(如「5,373~5,449个」)、可靠度徽标(可靠 / 可参考 / 未学准)、依据一行(称重学习 N 次 / 人工设定 / 按过往领料推算 / 设计单重)，
  以及「超过 N 个时称重计数只是估算」(批间差异决定的精确上限)。按件计的基本单位(计量维度为数量或未设)折算后取整(HALF_EVEN)。
- **本批抽样(可选)**：数一小把放秤录入数量 + 重量(抽样单位默认克，账号偏好 `sample`)，与已有单重融合收窄区间；
  单重未学准(红)时「填入数量」类按钮禁用，直到录入 ≥ 10 件的同批抽样。抽样在确认时保存为一条 SAMPLE 称重观测(到货场景自动带本单供应商)。
- **皮重**：预填货品默认皮重，否则取最近一次称重的皮重；「记住为本货品皮重」只对持有 `stock:weight:manage` 的账号显示(写货品称重设置)。
- **场景与按钮**(`WeighCountContext`)：

| 场景 | 用在 | 按钮 |
|---|---|---|
| `receipt` | 到货登记 | 主「只记重量」；次「按称重改数量」并红字提示「按称重改数量: 将按估算数量入账, 影响对账」(改的是业务数量，必须显式点) |
| `count` | 盘点、其它入库 / 产成品进仓 | 次「只记重量」；主「填入数量和重量」 |
| `outbound` | 其它出库 / 调拨 / 领料 / 销售 / 委外出库、退料收仓 | 反推：「需要 N 个 → 净重约 X kg (区间) + 皮重 → 秤上应显示约 Y kg」；「填入重量」只回填重量，不改数量 |
| `standalone` | [称重计数页](../03-页面/称重计数页.md) | 「清空重来」「保存抽样」(有抽样且有称样权限) |

- **不过账**：弹窗不调用任何库存过账接口，只返回 `WeighCountResult` 让页面回填；唯一的写是本批抽样(`POST /api/stock/weight/goods/{goodsId}/samples`)
  与「记住为本货品皮重」(`PUT /api/stock/weight/goods/{goodsId}/profile`)。保存失败给出原因并允许清空抽样 / 取消记住皮重后继续。
- **API**：
  - `WeighCountRequest({mode, goodsId, goodsTitle, params, supplierId, warehouseId, baseUnitName, lineUnitName, unitRate, currentQty, initialNetKg, integerQty, sampleRemark, canSaveSample})`，
    `currentQty` 为行单位数量(出库反推用)，`unitRate` 把行单位换成基本单位。
  - `WeighCountResult { netKg, grossKg, tareKg, qty(行单位；null = 只记重量), qtyBase, qtyFromWeight, sample(qty, weightKg, saved, detail), qtyEstimateNote }`。
  - `applyWeighCountResult(result, weight: WeightEntryController, qty: UtenAutofillTextController?)`：写重量；带数量时数量格黄框预填、行标记 `qtyFromWeight`、ⓘ 写推算区间。
  - `WeighCountPanel({request, onSubmit, onCancel, embedded})`：同一份面板，给独立页嵌入。
  - 仓库页封装：入库表格 `warehouseWeighCount(...)`、出库明细 `weighOutboundEntry(...)`(见 [WeightGridColumn](WeightGridColumn.md) §五)。
- **预测算法**：`weight_predictor.dart` 是服务端 `ApwPredictor` 的纯 Dart 镜像(t 分位、抽样融合、件数区间、应称重量与告警、请求级可靠度、建议抽样数)，
  两端用同一份金样逐条对拍；`gamma`、`scaleResKg` 取自服务端单重参数。

## 二、称样校准(`showWeightSampleDialog`)

数一小把放上秤，记一条 SAMPLE，服务端同步重算后回传最新单重详情(`GoodsWeightDetail`)。

- 字段：供应商(可不选；默认带入到货供应商，名称按权限可能打码)、数量 *(提示「建议至少 N 个」)、重量 *(+ 抽样重量单位，默认克，单独记忆)、
  皮重(可选，托盘 / 容器)、备注。
- 实时一行「本次单重 2.310 g; 当前 2.298 g (+0.5%)」；与当前单重差异超过 3 倍标准差时提示「差异较大: 换了供应商/批次?」，
  并给勾选「从本次起作为新批次(旧数据降权)」(`newRegime`)。
- 请求 `POST /api/stock/weight/goods/{goodsId}/samples {qty(基本单位), weight(已扣皮重的净重，按 weightUnit), weightUnit, tareKg?, supplierId?, warehouseId?, newRegime, remark, idempotencyKey}`；
  `tareKg` 只作留痕(毛重 = 净重 + 皮重)，服务端不再重复扣减。按重量计的货品、关闭了学习的货品、同键不同内容返回 409。
- 权限：`warehouse_inbound:stock_in` 或 `stock_doc:edit` 或 `stock:weight:manage`(前端 `weightSampleAllowedProvider`，服务端 `@PreAuthorize` 同口径)；
  无权时弹窗顶部提示「没有称样权限 (需要到货入库、仓库单据编辑或单重管理权限)」。
- 入口：仓库单据编辑页行菜单「称样校准...」、库存详情 / 货品详情「单重学习」分段按钮、库存分析「单重学习」行菜单「称样校准…」。
  到货登记等批量采集表格不挂行菜单(那里勾选集是提交集，行菜单会清选择)，改用称重计数弹窗里的「本批抽样」。
- 签名：`showWeightSampleDialog(context, {goodsId, goodsTitle, baseUnitName, supplierId, supplierName, supplierOptions, warehouseId, params, remark}) → Future<GoodsWeightDetail?>`。

## 三、测试

- `test/shared/measurement/weigh_count_dialog_test.dart`(未学准时禁用填入、抽样后可填、到货场景按钮与警示、出库反推)、
  `weight_sample_dialog_test.dart`(实时单重对比、差异大时的新批次勾选、权限提示)、`weight_predictor_golden_test.dart`。
- 服务端对拍：`ApwPredictorGoldenTest`、`ApwEstimatorTest`。
