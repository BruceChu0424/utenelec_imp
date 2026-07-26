# 28 - 业务四模块 Java 后端契约（Entity/Service/Controller 单一事实源）

> 本档是销售/委外/生产/钱流四模块 **Spring Boot Java 后端** 的跨模块一致性约束，配合 [27-DDL一致性契约]（表结构）+ 各 design doc（业务规则）。Java agent 写每模块前必读本文 + 自己的 DDL(V50-V59) + design doc + **采购模块 Java（`features/purchase/`，最接近的范本）**。
> 现有库存契约：`features/stock/StockService.recordMovement(MovementRequest)`（已扩 movement_type 15-20 常量）。

---

## 一、包结构（照采购 `features/purchase/<doctype>/`）

每模块 `features/<module>/`，每单据类型一个子包，含：
```
features/<module>/<doctype>/
  ├─ <Entity>.java                 JPA @Entity（主表），映射 DDL 列
  ├─ <Entity>Item.java             明细 Entity
  ├─ <Entity>Repository.java       JpaRepository（主表）
  ├─ <Entity>ItemRepository.java   明细
  ├─ <Entity>Service.java          业务（CRUD + 审核 + 联动 + 结案）
  ├─ <Entity>Controller.java       REST
  └─ dto/
     ├─ <X>Detail.java             详情响应
     ├─ <X>ListItem.java           列表行
     ├─ <X>ItemDto.java / <X>ItemLine.java
     ├─ <X>QueryFilter.java        查询过滤（分页+条件）
     └─ <X>SaveRequest.java        新建/编辑请求
```
报表：`features/<module>/report/<Module>ReportService.java + Controller`（查物化视图/明细）。

| 模块 | 包 | 子包(docotype) |
|---|---|---|
| 销售 | `features/sales/` | quote/order(order+cost_item)/shipment/other_shipment/return/report |
| 委外 | `features/subcontract/` | inquiry/application/order(order+cost_item)/receipt/material_issue/return/material_return/waste/report |
| 生产 | `features/production/` | plan(plan+item+cost)/daily_report/report |
| 钱流 | `features/finance/` | ar_ap_ledger(共享 Service)/receipt(+line)/payment(+line)/expense(+item)/other_income(+item)/bank_transfer/reconciliation/report + `features/master/account/`、`paymentstyle/`（主档） |

---

## 二、Entity 约定（照 `purchase/receipt/PurchaseReceipt.java`）

- `@Entity @Table(name="<ddl表名>")`，字段 `@Column(name="<ddl列名>")` 与 DDL 逐列对齐。
- 主键 `UUID id`（`@GeneratedValue` 不用——DDL `gen_random_uuid()` 默认值，Hibernate 生成或 DB 生成；照采购写法）。
- `legacy_id Integer`、`status Short`、`isClosed boolean`、金额 `BigDecimal`、`LocalDate billDate`/`OffsetDateTime createdAt` 等，类型对齐 DDL。
- 审计字段 createdAt/updatedAt/createdBy/updatedBy + 软删 isDeleted/deletedAt（若 DDL 有）。
- 明细 `@ManyToOne` 或仅留 FK `UUID orderItemId`（照采购 PurchaseReceiptItem 写法，避免懒加载坑——见 memory go-router-nested / LazyInitialization）。
- **不建跨模块关联**（如 sales 不 @ManyToOne ar_ap_ledger）；联动走 Service。

---

## 三、库存联动：`StockService.recordMovement`（已就绪，直接调）

审核状态 0→1 时，**同事务**内对每条明细调一次：
```java
stockService.recordMovement(new StockService.MovementRequest(
    OffsetDateTime.now(),                       // 或 billDate
    StockService.TYPE_SALES_OUT,                // 见常量 3/4/15-20
    StockService.SRC_SALES_SHIPMENT,            // source_doc_type
    shipmentId, shipmentItemId,
    goodsId, colorId, warehouseId,
    StockService.DIR_OUT,                       // +1 入 / -1 出
    baseQty,                                    // 已乘 unit_rate 的基本量
    unitId, unitRate,
    amountLocal,
    remark));
```
红冲 1→-1：反方向再调一次（direction 取反 / 或 type 用退货型）。

**type/dir 速查**：
| 单据审核 | type | dir |
|---|---|---|
| 销售出货 S_Out | TYPE_SALES_OUT(3) | DIR_OUT |
| 销售退 S_Withdraw | TYPE_SALES_RETURN(4) | DIR_IN |
| 销售其它出 S_OtherOut | TYPE_SALES_OTHER_OUT(20) | DIR_OUT（不回写订单/不立应收） |
| 委外材料出 E_SOut | TYPE_SUBCONTRACT_MATERIAL_ISSUE(15) | DIR_OUT |
| 委外材料退 E_SWithDraw | TYPE_SUBCONTRACT_MATERIAL_RETURN(16) | DIR_IN |
| 委外成品进 E_In | TYPE_SUBCONTRACT_RECEIPT(17) | **DIR_IN**（正向，不照搬老库反向） |
| 委外成品退 E_WithDraw | TYPE_SUBCONTRACT_RETURN(18) | DIR_OUT |
| 委外损耗 E_SWaste | TYPE_SUBCONTRACT_WASTE(19) | DIR_OUT + 回写 material_issue_item.wasted_qty |

---

## 四、应收应付联动：`ArApLedgerService`（钱流实现，销售/委外/采购调）

**接口定义**（钱流模块 `features/finance/arap/ArApLedgerService.java`，其余模块注入调用）：
```java
public interface ArApLedgerService {
    /** 立应收/应付（审核 0→1 同事务调）。direction=AR/AP，amountOriginalLocal 退货为负。 */
    ArApLedger postArAp(ArApPostingRequest req);

    /** 反立帐（红冲 1→-1 调）。若有核销 amount_settled<>0 抛 IllegalStateException("此单已经存在收/付款，请先反审")。 */
    void reverseArAp(UUID sourceDocId, String sourceDocType);
}
public record ArApPostingRequest(
    String direction,         // "AR" / "AP"
    String sourceDocType,     // SALES_SHIPMENT / SALES_RETURN / SUBCONTRACT_RECEIPT / PURCHASE_RECEIPT ...
    UUID sourceDocId, String sourceDocNo, LocalDate billDate,
    UUID clientId, UUID supplierId,   // AR 落 client，AP 落 supplier
    UUID currencyId, BigDecimal exchangeRate,
    BigDecimal amountOriginalLocal,
    Short legacyBstyle, String remark) {}
```
- `@Transactional(propagation = MANDATORY)`（必须由调用方事务包裹）。
- 调用方审核 Service 加 `ar_posted=true`（DDL 已加该列的表：sales_shipments/returns、subcontract_receipts/returns、purchase 侧待补）。
- source_doc_type 枚举与 DDL `ar_ap_ledger.source_doc_type` 注释一致。

> **采购反向联动补遗**：老库 P_In 审核→M_Out(应付)。采购既有 Java（PurchaseReceiptService）目前**未**立应付（V44 时期 ar_ap_ledger 不存在）。本期钱流落地后，应在 PurchaseReceiptService.approve 末尾补 `arApService.postArAp(AP, PURCHASE_RECEIPT, ...)`、退货补 reverse。属增强项。

---

## 五、审核状态机模式（照 `purchase/receipt/PurchaseReceiptService.java` 286 行范本）

```
approve(id):
  @Transactional
  doc = repo.findById(id); assert doc.status == 0 (草稿)
  doc.status = 1
  for item in items:
      stockService.recordMovement(...)        // 库存
      回写上游明细累计量（如 sales_order_item.shipped_qty += item.qty）  // 取代触发器
      [委外损耗] material_issue_item.wasted_qty += item.qty
  arApService.postArAp(...)                   // 应收/应付立帐（销售/委外/采购）
  doc.arPosted = true
  recomputeIsClosed(受影响上游单据)            // is_closed = 所有明细 qty-累计 <=0

reverse/approveToDraft(id)（红冲 1→-1）:
  @Transactional
  assert doc.status == 1
  arApService.reverseArAp(docId, srcType)     // 先校验无核销，否则抛错
  反向 stockService.recordMovement(...)        // direction/type 取反
  反向回写累计量
  doc.status = -1; doc.arPosted = false
```
- `TxSessionVars tx` 审计绑定（照采购：`tx.bind()`）。
- 金额双口径：amount_local = amount_original × exchange_rate（录单时算）。

---

## 六、Controller / DTO 约定（照采购 `dto/`）

- REST：`GET /<module>/<doctype>`（列表分页+filter）、`GET /{id}`（详情）、`POST`（新建）、`PUT /{id}`（编辑）、`POST /{id}/approve`（审核）、`POST /{id}/reverse`（红冲）、`DELETE /{id}`（草稿删除）。
- 权限：Controller 方法 `@PreAuthorize("hasAuthority('xxx:view')")` / `'xxx:edit'`（权限点见 DDL seed）。
- DTO：列表用投影（ListItem），详情带明细（Detail+ItemDto），保存用 SaveRequest（含明细行 ItemLine）。

---

## 七、跨模块铁律

1. 不直接 FK / @ManyToOne 跨模块；联动全走 Service（StockService / ArApLedgerService）。
2. 审核事务内完成：库存 + 回写 + 立帐 + 结案，任一失败全回滚。
3. movement_type 用 StockService 常量（勿硬编码数字）。
4. 金额 BigDecimal，禁 double/float。
5. 命名/包结构与采购一致，便于前端统一调用。

---

## 八、Java agent 任务边界（避免并行冲突）

| agent | 拥有的包 | 可改的共享文件 |
|---|---|---|
| 钱流 | features/finance/* + features/master/account + paymentstyle | **定义 ArApLedgerService 接口与实现** |
| 销售 | features/sales/* | 只注入 ArApLedgerService/StockService，不改它们 |
| 委外 | features/subcontract/* | 同上 |
| 生产 | features/production/* | 不涉 AR/AP（计划单不立帐）；只注入 StockService（日报/工序未来） |
| 采购增强 | features/purchase/receipt/ret(PurchaseReceiptService/ReturnService) | 仅补 postArAp/reverseArAp 调用（钱流就绪后） |

> StockService 常量已由我统一加好（15-20），Java agent 勿再改 StockService.java。

---

**最后更新**：2026-07-26 · Java 后端单一事实源。续作先读本文 + [27] + 各 design doc + DDL(V50-V63) + 采购 Java 范本。

---

## 实施后修订（2026-07-26，落地后回填）

- **ArApLedgerService 契约确认**：接口 `postArAp(ArApPostingRequest)→void` / `reverseArAp(UUID,String)→void`（void 返回、自包含），实现 `ArApLedgerServiceImpl`（@Transactional MANDATORY）。销售/委外/采购审核注入调用。**销售 [20] 早期称 `AccountReceivableService.postReceivable`，已统一为 `postArAp`**。
- **Flyway 增量**：V50-V63（V50 账户+收付款类别主档 / V51-52 销售 / V53-54 委外 / V55-56 生产含 F_PlanCostItem 按年分区 / V57-58 钱流 ar_ap_ledger / V59 库存字典 / **V60 明细表补 created_by/updated_by**（契约 §二订正：明细也需审计列，BaseEntity 要求）/ V61 钱流明细 remark / V62 销售 cost_items UNIQUE+return 列 / V63 清 finance_check_register 悬空权限）。
- **核验后修复的 bug**（见 [29] §接手清单 + 各 Service）：① 库存金额方向（reverse 不取反 amountLocal，7 处，e2e 实测红冲金额净归 0）② 月报 SQL（GROUP BY 漏 ym + Hibernate 命名参数类型推断，5 report service）③ 核销超核/负应收同号校验 ④ 委外进仓 supplier 非空校验 ⑤ legacy_bstyle=30。
- **来源感知导航**：前端跨页用 `goFrom`/`backTo`（`lib/core/router/nav_helpers.dart`），主 Tab 用 go（push 失效）+ KeepAlive 保滚动；列表→详情用 push/pop。见记忆 go-router-origin-aware-nav + [30]。
- **StockService 常量** 15-20 已加（agent 勿改 StockService.java）。
