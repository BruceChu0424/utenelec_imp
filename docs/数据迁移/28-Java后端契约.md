# 28 - 业务四模块 Java 后端契约（普通业务单据通用基线）

> 本档是销售/委外/生产/钱流四模块 **Spring Boot Java 后端** 的跨模块一致性约束，配合 [27-DDL一致性契约]（表结构）+ 各 design doc（业务规则）。Java agent 写每模块前必读本文 + 自己的 DDL(V50-V59) + design doc + **采购模块 Java（`features/purchase/`，最接近的范本）**。
> 现有库存契约：`features/stock/StockService.recordMovement(MovementRequest)`（已扩 movement_type 15-20 常量）。
>
> **2026-08-01 现行覆盖规则**：本文是 V50–V68 普通业务单据的通用实现基线，不再是所有状态机的单一事实源。销售出货和销售退货必须服从 V187–V189 专用生命周期；V190 负责新增业务表后的审计覆盖。专用状态机与通用模板冲突时，以后置迁移、当前 Service、最新 SOP 和契约测试为准。

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
| 资产与待摊 | `features/finance/asset/` | application/api/domain/infrastructure 分层：类别、工作流、查询、月度批次、期间、总账端口；现行契约见 [51](51-资产与待摊专业化全链路.md) |

资产子账不是普通“Entity + CRUD + approve/reverse”单据模板：金额内部使用 `BigDecimal`、响应以
decimal string 交付；更新/删除/动作带 `expectedVersion`；页面动作只消费服务端
`allowedActions`；月度批次使用输入指纹、期间锁和正常反向批次。核心落账另受默认 false 的
Feature Gate 保护。当前没有客户端幂等键、行级数据范围、计划修订、资产导出或完整终态事件反冲，
不得从通用模板擅自补成“已实现”。

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
只有单据专用状态机明确允许时，红冲 1→-1 才反方向追加流水；所有 `SHIPPED` 销售出货均禁止普通红冲。

**type/dir 速查**：
| 单据审核 | type | dir |
|---|---|---|
| 销售出货 S_Out | TYPE_SALES_OUT(3) | DIR_OUT |
| 销售退 S_Withdraw | TYPE_SALES_RETURN(4) | 仅 V189 `GOOD_RELEASE` 或迁移前历史兼容使用 DIR_IN；新退货审核不直接入可售库存 |
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
  doc = repo.findById(id)
  em.lock(doc, PESSIMISTIC_WRITE)               // 并发互斥：多账号同单审核/红冲序列化（2026-07-28 加固）
  assert doc.status == 0 (草稿)
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
  doc = repo.findById(id)
  em.lock(doc, PESSIMISTIC_WRITE)               // 并发互斥：同上
  assert doc.status == 1
  assert 没有仍有效的下游累计量                   // 先红冲下游，禁止破坏来源链
  arApService.reverseArAp(docId, srcType)     // 先校验无核销，否则抛错
  反向 stockService.recordMovement(...)        // direction/type 取反
  按稳定 UUID 顺序锁上游来源明细，再反向回写累计量
  doc.status = -1; doc.arPosted = false
```

专用例外：

- 销售出货进入 `SHIPPED` 后普通 reverse 一律拒绝，包括缺少历史交接时间的行；
- 新销售退货 approve 只建立质量冻结；`GOOD_RELEASE` 才写可售库存；
- 退货发生任一质量处置后，整单 reverse 拒绝；
- 财务已审出货必须先走财务反审，但进入 `SHIPPED` 后财务反审同样不可用。

- `TxSessionVars tx` 审计绑定（照采购：`tx.bind()`）。
- 金额双口径：amount_local = amount_original × exchange_rate（录单时算）。
- **并发（2026-07-28 全量加固）**：所有单据 approve/reverse 入口先 `em.lock(doc, PESSIMISTIC_WRITE)`
  再查状态——状态机迁移附带库存/立帐/回写副作用，行锁让并发者拿到「状态已变」明确拒绝，
  避免副作用重跑（与 SAP 单据锁/用友审核锁同思路）。已覆盖 25 个 Service / 40 个入口，
  详见 [37-业务联动-MRP与并发加固](37-业务联动-MRP与并发加固.md) §三。
- **反向来源链（2026-07-30）**：父单仍有有效下游累计时禁止红冲。采购覆盖申请→订货、
  订货→收货/退货、收货→退货；委外覆盖申请→订货、订货→进仓/退货/发料/退料、
  进仓→退货、发料→退料/损耗。采购/委外订货红冲还须先按稳定 UUID 顺序锁申请来源行，再回减
  `ordered_qty`，避免与另一笔订货审核并发产生丢失更新或负累计。

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
6. **原生 SQL 可空参数必须 CAST**：`em.createNativeQuery` 写 `WHERE (:param IS NULL OR col = :param)` 时，当 `:param` 绑定为 null，Hibernate `ObjectNullResolvingJdbcType` 会调 `getParameterMetaData()`，PG 对「裸 `? IS NULL`（无类型上下文）」报 `could not determine data type of parameter $N` → 500。**所有可空 param 的 IS NULL 侧一律 `CAST(:param AS <type>) IS NULL`**（type 取 `text`/`uuid`/`date`/`timestamptz`/`smallint`/`boolean`；CAST 只服务于 null 判定，真实比较仍用原 param，类型安全）。排查：后端堆栈见 `PSQLException: could not determine data type` + `ObjectNullResolvingJdbcType.doBindNull` 即此坑。
7. 资产已过账批次、日志、审批、事件和正式凭证不得原地更新/删除；通用总账生成不得拥有资产来源，
   月度错误走正常反向批次，资本化/处置/终止必须等待各自专用事件反冲。

---

## 八、Java agent 任务边界（避免并行冲突）

| agent | 拥有的包 | 可改的共享文件 |
|---|---|---|
| 钱流 | features/finance/* + features/master/account + paymentstyle | **定义 ArApLedgerService 接口与实现**；改 asset 子包前先读 ADR-018/51，不能套旧 CRUD/删除重建范式 |
| 销售 | features/sales/* | 只注入 ArApLedgerService/StockService，不改它们 |
| 委外 | features/subcontract/* | 同上 |
| 生产 | features/production/* | 不涉 AR/AP（计划单不立帐）；只注入 StockService（日报/工序未来） |
| 采购增强 | features/purchase/receipt/ret(PurchaseReceiptService/ReturnService) | 仅补 postArAp/reverseArAp 调用（钱流就绪后） |

> StockService 常量已由我统一加好（15-20），Java agent 勿再改 StockService.java。

---

**最后更新**：2026-08-01 · 普通业务单据 Java 通用基线。资产子账使用独立的 application/api/domain/infrastructure 契约；销售发运/退货使用 V187–V189 专用状态机。续作必须同时读取对应后置迁移、当前 Service、最新 SOP 和契约测试，不能仅套本文模板。钱流 22 报表已重写为 `ReportTableResponse` 范式（`features/finance/report/`，含 `execute`/`WhereBuilder`/`FacetSpec`，镜像销售/采购；详见 [26] §十一·财务口径校准）。§九登记 `common/docnumber` 包。

---

## 实施后修订（2026-07-26，落地后回填）

- **ArApLedgerService 契约确认**：接口 `postArAp(ArApPostingRequest)→void` / `reverseArAp(UUID,String)→void`（void 返回、自包含），实现 `ArApLedgerServiceImpl`（@Transactional MANDATORY）。销售/委外/采购审核注入调用。**销售 [20] 早期称 `AccountReceivableService.postReceivable`，已统一为 `postArAp`**。
- **Flyway 增量**：V50-V68（V50 账户+收付款类别主档 / V51-52 销售 / V53-54 委外 / V55-56 生产含 F_PlanCostItem 按年分区 / V57-58 钱流 ar_ap_ledger / V59 库存字典 / **V60 明细表补 created_by/updated_by**（契约 §二订正：明细也需审计列，BaseEntity 要求）/ V61 钱流明细 remark / V62 销售 cost_items UNIQUE+return 列 / V63 清 finance_check_register 悬空权限 / V64 删 analytics 权限 / **V65-V68 各模块报表补列**：V65 采购（人员 *_legacy_id + settlement_style_legacy + 明细交叉引用列）、V66 委外（人员 *_legacy_id+*_name + settlement_style_legacy + 围数/工序/胶箱/退货金额/交叉引用单号，详见 [22] §十一）、V67 仓库（stock_documents 人员 *_legacy_id + ass_team）、V68 销售（成本价/围数/进仓/in_no/out_no 等明细列 + 4 主表 *_legacy_id + client_director_v 视图））。
- **核验后修复的 bug**（见 [29] §接手清单 + 各 Service）：① 库存金额方向（reverse 不取反 amountLocal，7 处，e2e 实测红冲金额净归 0）② 月报 SQL（GROUP BY 漏 ym + **Hibernate 原生 SQL null 参数类型坑**：`(:param IS NULL OR col=:param)` 当 param=null 时 PG 报 `could not determine data type of parameter $N` → 报表页"加载失败"；**已对全部可空 param 加 `CAST(:param AS 类型) IS NULL`，6 处全修**——`FinanceReportService` / `SubcontractReportService` / `ProductionReportService` / `ProductionPlanCostService` / `PurchaseReportService` / `SalesReportService`，全仓 grep `:[A-Za-z_]+\s+IS\s+(NOT\s+)?NULL` 零残留；铁律见 §七-6）③ 核销超核/负应收同号校验 ④ 委外进仓 supplier 非空校验 ⑤ legacy_bstyle=30。
- **来源感知导航**：前端跨页用 `goFrom`/`backTo`（`lib/core/router/nav_helpers.dart`），主 Tab 用 go（push 失效）+ KeepAlive 保滚动；列表→详情用 push/pop。见记忆 go-router-origin-aware-nav + [30]。
- **StockService 常量** 15-20 已加（agent 勿改 StockService.java）。

---

## 九、单据号统一生成 · `common/docnumber` 包（2026-07-27 跨模块重构落地）

> 配套 DDL：[27] V76 `doc_number_sequences` 表。全部 25 个 create-单据 Service 已接入（含 2026-07-28 补接的 3 个，见本节末「2026-07-28 修订」）。

**包结构**（`server/.../common/docnumber/`，跨模块共享，非任何单模块独占）：
```
common/docnumber/
  ├─ DocNumberService.java       序列生成（原子）
  └─ DocNumberPrefix.java        enum，25 单据类型各一前缀
  （DocNumberController 的 GET /api/doc-number/peek **已删除**——见本节末「2026-07-28 修订」）
```

**核心契约**：
- `String nextNumber(DocNumberPrefix prefix, YearMonth ym)`：
  - SQL：`INSERT INTO doc_number_sequences(prefix, period, last_seq) VALUES(?, ?, 1) ON CONFLICT(prefix, period) DO UPDATE SET last_seq = doc_number_sequences.last_seq + 1 RETURNING last_seq` —— **单语句原子**（PG 行锁，无并发撞号）。
  - 格式：`[prefix][YYMM][4位月内顺序号零填充]`，例 `CD26070001`。
- **接入规则（铁律）**：全部 25 个单据 Service 的 `create()` 内，`billNo` 为空 → 调 `nextNumber` 生成；**忽略客户端传入的 billNo**（防伪造/撞号/绕过序列）；`update()` **永不重新生成**（保留原号）。`StockDocService` 走 `doc_type → DocNumberPrefix` 映射表。
- **撞号处理**：CJ 既有"采购收货"又有"仓库产成品进仓"，V76 分配时仓库让步改用 `CR`；其余前缀按单据类型一一映射。
- **历史 backfill**：迁移完成后扫描各表现有 `bill_no`，按 `(prefix, period)` 回填 `last_seq = MAX(解析出的序号)`，保证新生成的号不撞已迁入的老号。
- **前端协作**：单据号保存后在详情页展示；新建页 billNo 字段只读占位"保存后自动生成"。（peek 端点曾实现预览后回退，**2026-07-28 已删除**——见本节末「2026-07-28 修订」；前端用 save-then-show，最安全。）

> Java agent 写新单据类型时：① 在 `DocNumberPrefix` 枚举加前缀；② create() 调 `nextNumber`；③ 勿在 controller/DTO 暴露"客户端自传 billNo"路径（SaveRequest 可保留 billNo 字段但 Service 忽略其值）。

---

### 2026-07-28 修订（单据号系统生成落地后的安全/正确性修复）

> 上述 §九 落地后，经实测验证追加下列修复（均已实现 + 验证 2026-07-28）：

1. **DTO `@NotBlank billNo` 全量移除**：全部 25 个 `*SaveRequest*` DTO 不再要求/校验 `billNo`（单据号由 `DocNumberService` 服务端生成，DTO 不应再约束）。此前若带 `@NotBlank`，请求在到达 `DocNumberService` 前就被 400 拒绝，单据号生成逻辑根本跑不到。
2. **peek 端点删除（最小攻击面）**：`DocNumberController` 的 `GET /api/doc-number/peek` 删除；`DocNumberService.peekNumber` 与 `DocNumberPrefix.fromCode` 同步删除。前端用 save-then-show，peek 端点本就未用，删除以收敛接口面、降攻击面。
3. **3 个此前休眠/未接的 Service 接入 DocNumberService**（纵深防御，不再信任客户端 billNo）：
   - `ProductionDailyReportService` → 新前缀 `SR`（`DocNumberPrefix.PROD_DAILY_REPORT`）
   - `SubcontractInquiryService` → `EA`（`DocNumberPrefix.SUB_INQUIRY`）
   - `SubcontractApplicationService` → `EB`（`DocNumberPrefix.SUB_APPLICATION`）
   - `DocNumberPrefix` 同步新增上述 3 个枚举常量。**至此全部 25 个 create-单据 Service 均由服务端权威生成 billNo，客户端传入的 billNo 零信任。**
4. **`is_stopped` 实体默认值修复（潜在 bug，因 #1 修复而暴露）**：
   - 现象：`PurchaseOrder.isStopped` / `PurchaseRequest.isStopped` 原为 `private Boolean isStopped;`（包装类型，默认 `null`），DDL 列为 `NOT NULL DEFAULT FALSE` —— Hibernate insert 仍发 `null`（实体字段值优先于 DDL DEFAULT），触发 NOT NULL 约束违反、create 失败。
   - 修复：改为 `private Boolean isStopped = false;`（create 显式发 `false`；legacy `NULL` 历史数据读取不受影响）。
   - 关联：此 bug 此前被 #1 修复前的 `@NotBlank` 400 拦截挡在前面，**未到达 DB**，故一直潜伏；#1 移除 `@NotBlank` 后才暴露。
   - 不受影响：`SalesOrder.isStopped` / `ProductionPlan.isStopped` 用原始 `boolean`（JVM 默认 `false`，Hibernate 视为已赋值），不会发 null。

> 教训：DDL `NOT NULL DEFAULT X` 列在 Java 实体里**不能用包装类型无默认值**（`Boolean xxx;`）—— Hibernate insert 会以字段值 `null` 覆盖 DDL DEFAULT；要么用原始类型（`boolean xxx;`），要么显式赋默认（`Boolean xxx = false;`）。详见 [27] §二「NOT NULL DEFAULT 列契约」。
