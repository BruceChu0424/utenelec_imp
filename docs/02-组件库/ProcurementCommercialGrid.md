# ProcurementCommercialGrid 采购/委外订货明细行级商业条款组件

> 源码：[`lib/shared/widgets/procurement_commercial_grid.dart`](../../lib/shared/widgets/procurement_commercial_grid.dart)
> 引入：2026-09-03（ADR-068 行级商业条款改造）；最后核对：2026-09-04。

## 一、职责与边界

采购订货单与委外订货单共用的**行级商业条款**能力层：结账(结算)方式/币种/汇率/税率
与行备注的状态、单元格与列定义。单头不再录商业字段；保存由页面组装行级值，
后端 `createBatch` 按「供应商+条款组合」拆单归集（表结构零迁移）。

- 只管**行状态与单元格/列**；批量交互面板在
  [CommercialTermsBatchSheet](CommercialTermsBatchSheet.md)，记忆预填契约 `/last-terms`
  （模型 `lib/shared/models/procurement_commercial_terms.dart`）由页面接线。
- 不依赖具体业务仓库；字典（币种/结算方式 entries）与落值回调全部由页面注入。

## 二、对外契约

### 2.1 行状态（混入明细行模型）

| 成员 | 说明 |
|---|---|
| `mixin CommercialTermsRowMixin on EditableGridRow implements CommercialTermsGridRow` | 币种/结账方式 `ValueNotifier`（批量赋值与预填即时刷新）+ 汇率/税率 `TextEditingController`；`copyCommercialFrom` 供行克隆（**不拷预填黄标**，克隆行是用户显式复制） |
| `termsAutofilledNotifier` / `markTermsAutofilled(key, value)` / `clearTermsAutofilled(key)` | **学习预填黄标**（2026-09-04）：`/last-terms` 学习带入即标记（key：`supplier/currency/rate/tax/settlement`），单元格黄框提醒核对；下拉经页面落值回调清除，汇率/税率文本控制器由内置监听按「改动≠带入值」清除。黄框样式复用 `required_field_decoration.dart` 的 `applyAutofillHint`，优先级：错误(红) > 必填空(红) > 预填(黄) |
| `mixin RemarkRowMixin on EditableGridRow implements RemarkGridRow` | 行备注控制器（随行提交 `remark`） |
| `CommercialTermsGridRow` / `RemarkGridRow` | 抽象契约（Dart 无交集类型，列构建泛型约束走契约类） |

### 2.2 单元格与列

| 成员 | 说明 |
|---|---|
| `ProcurementTermDropdownCell` | grid 内紧凑下拉选择格（outlined+弹菜单）；`requiredEmpty` 红字提示；`autofilled` 黄框提醒核对（学习预填值） |
| `procurementCommercialColumns<R>` | 币种(必填)/汇率(必填>0)/税率(0-100)/结账方式(必填) 四列，全部接入预填黄标；`settlementLabel` 采购「结账方式」/委外「结算方式」；`onPickCurrency/onPickSettlement` 由页面按多选范围落值（页面负责对全部落值行清黄标） |
| `procurementRemarkColumn<R>` | 明细末列备注（textOf+listenableOf 自动加宽） |

## 三、已接入页面

- 采购订货单专属编辑页（`lib/features/purchase/pages/purchase_order_edit_page.dart`，
  列定义经 `purchaseGridColumns(showCommercial: true, showRemark: true)` 装配）。
- 委外订货单专属编辑页（`subcontract_order_edit_page.dart`，
  `subcontractGridColumns(showCommercial: true, settlementLabel: '结算方式', showRemark: true)`）。
- 采购/委外共享单据编辑页的备注列（`showRemark`）。
- 行级供应商列的 `ProcurementSupplierCell` 同步支持 `autofilled` 黄标
  （学习预填供应商时提醒核对）。

## 四、验证

- [`purchase_grid_row_clone_test.dart`](../../test/features/purchase/purchase_grid_row_clone_test.dart)
  （克隆保留条款/备注、控制器独立）
- [`purchase_order_row_supplier_batch_test.dart`](../../test/features/purchase/purchase_order_row_supplier_batch_test.dart)
  （专属页行级联动）
- [`subcontract_order_settlement_method_test.dart`](../../test/features/subcontract/subcontract_order_settlement_method_test.dart)
  （行级结算必填/阻断）
