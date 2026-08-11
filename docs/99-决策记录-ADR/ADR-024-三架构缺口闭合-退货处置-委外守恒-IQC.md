# ADR-024：闭合三个 🔴 架构缺口——销售退货客户处置 / 委外物料守恒 / 采购委外 IQC

> 状态：源码候选（已实现 + 单测过 + 架构/审计守卫通过）｜ 日期：2026-08-06
> 依据：审计 §五、SOP 01 §七-273/275/276、SOP 06 §五、迁移 22 §十-13/§十二.5
> 关联：[ADR-017 模块化单体与异步旁路](ADR-017-模块化单体与异步旁路.md)（本 ADR 追加 `warehouse->stock` 合法依赖边）

## 背景

三个上线阻断缺口（均记为 🔴 P0）：

1. **销售退货客户处置**：退货审核统一按"重开替换需求"重算 outstanding + 立红字应收，但缺"退款结案/换货/补发/维修后返还"的客户结论权威字段与审批；且审核从不建预留（BUG-S1 退货不重预留），替换发货无法兑现。
2. **委外物料守恒**：发料是公司物料转供应商处保管，不是销售出库或立即消耗；缺冻结 BOM 版本与子件发料权威台账，新发料审核 fail-closed（409）。
3. **采购/委外 IQC**：收货直接进可用库存并立即唤醒生产，把未检品当现货，是生产放行的 P0 缺口。

## 决策

### 1. 销售退货客户处置（V220）

- `sales_returns` 落地 `customer_disposition`（REFUND_CLOSED/EXCHANGE/RESHIP/REPAIR_RETURN）+ `disposition_status` + 决策人/时间/原因 + `fulfilment_reopened`；追加式 `sales_return_disposition_events`（禁 UPDATE/DELETE，误判须补偿事件）。
- **确定影响（SOP：不自动补产、默认不自动加预留）**：
  - RESHIP/EXCHANGE → 重开替换履约：对订单行未满足 outstanding 重新软预留（**修 BUG-S1**）；仅让需求可见，不自动排产。
  - REFUND_CLOSED/REPAIR_RETURN → 以休眠列 `flag_qty` 关闭替换需求（outstanding 回落/可能结案），不补产、不发替换。
  - 任一处置确认后 `disposition_status=DECIDED`，禁止整单普通红冲（须受控补偿）。
- **取舍**：EXCHANGE 当前按"同品补发"处理（预留同品）；跨品换货需另建订单行，本期不做。处置为 one-time 决策（无在线改判）。

### 2. 委外物料守恒（V221）—— GENERATED 列 + CHECK

- `subcontract_material_issue_items` 加 `at_supplier_qty`（=发料量，审核置）/ `consumed_qty`（回厂按 BOM 累加）/ `frozen_unit_qty`（审核时从 `goods_bom_items` 冻结的每单位父件耗用量=BOM 版本快照）/ `supplier_ending`。
- **`supplier_ending = at_supplier_qty − consumed_qty − returned_qty − wasted_qty` 为 GENERATED STORED 列 + `CHECK (supplier_ending ≥ 0)`**：回厂消费、材料退、损耗三条途径共用同一守恒口径，DB 强制，无需各自手工同步；且能拦下 V132 触发器漏掉的 consumed 维度（returned+wasted≤qty 但 consumed 致负）。
- 历史回填 `at_supplier_qty = qty`，使既有 returned/wasted 行满足新约束；原 409 发料审核门禁放开（要求明细挂 `order_item_id` 以便回厂按父件消费）。

### 3. 采购/委外 IQC（V222）—— sidecar 而非列

- **选 sidecar（`procurement_inspection_items`，镜像 V189），不选"给 stock_balances 加 inspection_status 列"**：收货入冻结、**不写 stock_balances**，故三个可用量口径（`warehouseAvailableBase` / `globalAvailableBase` / `v_stock_available`）自然不含待检品——零改动、零口径漂移；列方案要同时改这三处 + upsert 路由，爆炸半径大。
- PASS 才 `recordMovement(DIR_IN)` 进可用 + 唤醒生产（`onPurchaseReceiptApproved`/`onSubcontractReceiptApproved` 推迟到整单结案后调用一次）；FAIL 只记事实，不入可用。红冲前须全部明细 RESOLVED，由 inspection 服务按已放行量精确反向。
- 跨模块经 `application/port/ProcurementInspectionPort`（仿 `ProcurementArrivalControlPort`），避免 purchase/subcontract→warehouse 直连。

## 架构影响（ADR-017 修订）

新增合法依赖边 `warehouse -> stock`（IQC PASS 放行需写库存；与 purchase/subcontract/sales/production→stock 同构）。purchase/subcontract 经 Port 调 IQC，**不**新增 purchase/subcontract→warehouse 边。

## 迁移版本

V220（退货处置）/ V221（委外守恒）/ V222（IQC）/ V223（审计触发器覆盖刷新）。**注意：并行流已占 V219（finance_object_scope）；本批 V220+ 与之版本号不冲突。** V223 是 V218 审计全表 sweep 的重复，覆盖本批新业务表。

## 验证

- mvn compile + test-compile 过；全量单测 849 通过（本域全净）。
- 各项新增 PostgresTest（@EnabledIfEnvironmentVariable `UTEN_RUN_DB_TESTS`）：退货处置约束/append-only、委外守恒恒等/CHECK（含 V132 漏掉的 consumed 维度）、IQC 待检不入 stock_balances/CHECK/append-only。
- 架构边界测试、审计覆盖契约测试已随本批更新（warehouse→stock 入白名单；LATEST_FULL_AUDIT_SWEEP_VERSION 推进到 223）。

## 未完成 / 风险（上线前）

- 公司目标库迁移、多账号、仓库回厂/质检/退货实物 **真实岗位 UAT** 与发布签字未完成；隔离迁移/单测不等于生产可上线。
- IQC：AP 在收货时立帐（FAIL 后供应商贷项另走流程，本期不自动冲）；生产唤醒按 received 量触发（FAIL 部分由库存可用量门控；精确按 passed 量分配为后续）。
- 委外：回厂消费假设收货父件单位与 BOM 父件单位一致；跨品 EXCHANGE 不支持。
- 并行流（SEC-MED-4 财务对象范围 + GL 增量）同在工作树：文件域不交叠，仅 Flyway 版本号需协调（本批已让出 V219）。
