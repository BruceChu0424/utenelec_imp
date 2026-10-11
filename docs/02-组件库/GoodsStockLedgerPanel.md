# GoodsStockLedgerPanel(单货品库存面板)

> 源码：`lib/shared/stock_ledger/`(2026-09-28 引入，[ADR-135](../99-决策记录-ADR/ADR-135-仓库重量账与单重自学习.md) §3.4)
> - `goods_stock_ledger_panel.dart`：`GoodsStockLedgerPanel` / `GoodsStockLedgerPanelState`
> - `stock_ledger_models.dart`：`GoodsStockLedgerSegment`、`StockLedgerQuery`、`StockLedgerPage`、`GoodsStockInsight`、`stockSourceDocPath` / `stockLedgerSourcePath`
> - `stock_ledger_repository.dart`：`goodsStockLedgerRepositoryProvider`
> - `widgets/goods_stock_kpi_strip.dart`、`goods_stock_balance_view.dart`、`goods_stock_ledger_view.dart`、`goods_weight_learning_view.dart`
> 宿主：[库存详情页](../03-页面/库存详情页.md)(`/stock/item/:goodsId?tab=`)与[货品详情「库存与出入库」页签](../03-页面/基础资料页.md)——两处完全同一套。

## 一、结构

```
GoodsStockKpiStrip            库存 · 重量 | 单重 (±%) | 最后入库 · 最后出库 | 90天日均出库 · 约可用 N 天 | ABC | 库龄
UtenFilterToolbar             [库存余额] [出入库流水] [单重学习]            重量单位: 自动▾
Expanded(当前分段)            GoodsStockBalanceView / GoodsStockLedgerView / GoodsWeightLearningView
```

- 放在 `lib/shared`：基础资料(货品详情)与库存两个 feature 都从这里取，不新增 feature 之间的依赖边。
  余额分段仍借用 `lib/features/stock` 的 `BalanceRow`、`StockQueryRepository.balances / adjustBalance` 与 `stock_balance_detail_sheet`
  (仓库单据编辑页的盘点账面读取也用 `balances()`)；架构棘轮只扫 `lib/features`，没有新增边。
- KPI 条取 `GET /api/stock/insights/goods/{goodsId}`(`stock:view`)，只给货品级数字；请求失败时整条隐藏。

## 二、API

| 名称 | 说明 |
|---|---|
| `GoodsStockLedgerPanel({goodsId, initialSegment, onSegmentChanged})` | `initialSegment` 默认库存余额；`onSegmentChanged` 给宿主同步地址栏等 |
| `GoodsStockLedgerPanelState.reload()` | 整个面板重取(页面刷新按钮 / 返回即刷新)，各分段保留自己的筛选与分页 |
| `GoodsStockLedgerPanelState.showLedger({warehouseId, colorId})` | 切到流水分段并筛到某个仓库 + 颜色(`colorId` 为 null 且给了仓库 = 无颜色维度，查询带 `colorNull=true`) |
| `GoodsStockLedgerPanelState.selectSegment(segment)` | 切分段 |
| `GoodsStockLedgerSegment.parse(String?)` | 路由 `?tab=` → 分段：`balance` / `ledger` / `weight`，认不出回落库存余额 |
| `stockSourceDocPath({sourceDocType, sourceDocId, sourceDocCode})` / `stockLedgerSourcePath(row)` | 流水行回源单路径：只认服务端 `sourceDocType` + `sourceDocCode`(仓库单据 doc_type)，不再按流水类型猜 |

宿主用 `GlobalKey<GoodsStockLedgerPanelState>` 调 `reload()`；货品详情基本信息的「出入库流水」按钮切到库存页签后让面板停在流水分段。

## 三、三个分段

- **库存余额**：列 仓库 | 颜色 | 库存数量(单位内联) | 库存重量 | 最后变动 | 操作（2026-10-10 起独立「单位」列删除）；重量「≈」/「未称」。行操作 查看流水 / 调整(`stock:balance:adjust`) /
  核重(`stock:weight:manage`，按重量计的货品隐藏，按 `/stock/weight/params` 的 EXACT 判断)。调整与核重打开 `showStockBalanceDetailSheet`：
  - 返回 `Future<bool?>`(true = 有改动)；模式 `StockBalanceSheetMode.details / adjust / weigh`(`initialMode`)；
  - `onAdjust(targetQty, targetWeightKg, reason, key)`：调整后数量 + 可选调整后重量(按盘点定重)；
  - `onSetWeight(targetKg, reason, key)`：核重，`POST /api/stock/weight/balances/set`，带打开时的当前重量做乐观核对；
  - 幂等键由「打开表单的时刻 + 提交内容」生成：同内容重试复用、改了内容换新键；重量输入接受 850g、1.2t、3斤。
- **出入库流水**：存货明细账(`GET /api/stock/goods/{goodsId}/ledger`)。日期(默认近 90 天) / 仓库(含下级) / 表头筛选 类型、颜色、仓库(服务端 facet，一次一个值) /
  「显示重量调整」；列 日期 | 类型 | 单号 | 往来方 | 仓库 | 颜色 | 收入数量 | 发出数量 | 结存数量 | 单位 | 收入重量 | 发出重量 | 结存重量 | 操作人 | 备注；
  汇总条 期初结存 · 本期收入 · 本期发出 · 期末结存(+ 范围内调拨、重量尾差调整)。结存与汇总全部来自服务端，前端不做加减。
  往来方无权时显示「已隐藏」。重量调整行标签按 `adjustmentKind` 给(重量起算 / 重量尾差调整 / 盘点定重 / 人工核重 / 撤销盘点重量)，服务端 `typeLabel` 兜底。
- **单重学习**：当前单重卡片(可靠度徽标、依据、领料偏差、换批 / 矛盾提醒) + 按钮 称样校准 / 设定单重 / 从今天起重新学习；
  子分段 称重记录(服务端分页、来源 / 状态筛选、排除 / 恢复) / 各供应商(`stock_report:view` 或 `stock:weight:manage`) / 学习设置(`stock:weight:manage`，按版本保存)。
  权限走 `weightSampleAllowedProvider` / `weightManageAllowedProvider`(超管放行)。

## 四、测试

- `test/shared/stock_ledger/goods_stock_ledger_panel_test.dart`(分段切换、余额行查看流水带仓库颜色、核重显隐、流水列与汇总、来源跳转)、
  `stock_ledger_models_test.dart`(JSON 解析、分段解析、来源路径)。
- 宿主：`test/features/basic_data/widgets/goods_detail_stock_tab_test.dart`、`test/features/stock/stock_balance_weight_test.dart`。
