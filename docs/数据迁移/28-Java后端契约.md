# 28 - 业务四模块 Java 后端契约（普通业务单据通用基线）

> 本档是销售/委外/生产/钱流四模块 **Spring Boot Java 后端** 的跨模块一致性约束，配合 [27-DDL一致性契约]（表结构）+ 各 design doc（业务规则）。Java agent 写每模块前必读本文 + 自己的 DDL(V50-V59) + design doc + **采购模块 Java（`features/purchase/`，最接近的范本）**。
> 现有库存契约：`features/stock/StockService.recordMovement(MovementRequest)`（已扩 movement_type 15-20 常量）。
>
> **2026-08-01 现行覆盖规则**：本文是 V50–V68 普通业务单据的通用实现基线，不再是所有状态机的单一事实源。销售出货和销售退货必须服从 V187–V189 专用生命周期；V190 负责新增业务表后的审计覆盖。专用状态机与通用模板冲突时，以后置迁移、当前 Service、最新 SOP 和契约测试为准。
> **2026-08-02 采购/委外专用覆盖规则**：计划申请分解、订货财务审批、预计到货与超量控制服从 V196–V202、当前 `features/finance/procurement`、`features/warehouse/inbound`、订单/收货 Service 和 ADR-019。订货不再由通用 `approve()` 直接生效；只有订货财务审批事务可以把原生订货从 `status=0` 改为 `status=1`，超量收货还须有绑定本收货单的财务追加批准。


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

## 十、计划需求分解、订货财务审批与超量到货专用契约（V196–V202）

### 10.1 应用层边界

- `PurchaseRequestController` 与 `SubcontractApplicationController` 只允许 list、detail、decomposition-preview；计划下达申请不是采购/委外 CRUD 资源。
- 采购/委外分解只读预览接受多个申请明细 ID，保持输入顺序、去重并 fail-closed；选择项必须已下达、未关闭、有可靠单位且剩余量大于零。不同仓库返回 409。
- 原生采购/委外订单每行必须有申请明细 FK。订单创建接口即使被直接调用，提交财务时也必须重新锁定并验证全部来源，不能靠 Flutter 路由守卫保证完整性。

### 10.2 端点

| 用途 | 端点 | 权限/对象约束 |
|---|---|---|
| 采购申请只读 | `GET /api/purchase/requests`、`GET /api/purchase/requests/{id}` | `purchase_request:view`；没有申请 create/update/approve/delete 端点 |
| 委外申请只读 | `GET /api/subcontract/applications`、`GET /api/subcontract/applications/{id}` | `subcontract_application:view`；没有申请 create/update/approve/reverse/delete 端点 |
| 采购分解预览 | `POST /api/purchase/requests/decomposition-preview` | `purchase_request:view` + `purchase_order:edit` |
| 委外分解预览 | `POST /api/subcontract/applications/decomposition-preview` | `subcontract_application:view` + `subcontract_order:edit` |
| 提交财务 | `POST /api/purchase/orders/{id}/submit-finance`、`POST /api/subcontract/orders/{id}/submit-finance` | 分别要求 `purchase_order:submit_finance` / `subcontract_order:submit_finance`；订单草稿和来源重验 |
| 财务任务 | `GET /api/finance/procurement-approvals/tasks`、`GET /api/finance/procurement-approvals/count` | `finance_order_approval:view`；列出全部 `PENDING` 待审（V229 起不再按 assignee 过滤），`APPROVE/REJECT` 由合格审核人资格实时判定 |
| 通过 | `POST /api/purchase/orders/{id}/approve`、`POST /api/subcontract/orders/{id}/approve` | `finance_order_approval:review` + 合格审核人资格（`WorkflowReviewerEligibility` 实时查库）+ `expectedVersion` |
| 驳回 | `POST /api/purchase/orders/{id}/reject`、`POST /api/subcontract/orders/{id}/reject` | `finance_order_approval:review` + 合格审核人资格（实时查库）+ `expectedVersion` + `reason` |
| ~~负责人列表/保存~~ | `GET/PUT /api/admin/workflow-responsibilities*` | **V229 已删除**（`workflow_assignment:manage` 同步退役）；审批人改由 `finance_order_approval:review` + 财务部门资格决定，见 ADR-027 |
| 仓库预计到货 | `GET /api/warehouse/inbound/expectations`、`GET /api/warehouse/inbound/expectations/count` | `warehouse_inbound:view`；只返回财务已批订单投影 |
| 仓库到货异常 | `GET /api/warehouse/inbound/arrival-exceptions`、`GET /api/warehouse/inbound/arrival-exceptions/count` | `warehouse_inbound:view`；只读，不能决定入库量 |
| 财务超量任务 | `GET /api/finance/procurement-arrival-exceptions/tasks`、`GET /api/finance/procurement-arrival-exceptions/count`、`GET /api/finance/procurement-arrival-exceptions/{id}` | `finance_order_approval:view`；V229 起列出全部 `PENDING_FINANCE`，决定动作由合格审核人资格实时判定 |
| 财务超量决定 | `POST /api/finance/procurement-arrival-exceptions/{id}/decision` | 同时要求 `finance_order_approval:view` + `finance_order_approval:review`、合格审核人资格（实时查库）与 `expectedVersion`；full/custom 必填说明 |
| 本人退货任务 | `GET /api/procurement/arrival-exceptions/tasks?orderType={orderType}`、`GET /api/procurement/arrival-exceptions/count?orderType={orderType}`、`GET /api/procurement/arrival-exceptions/{id}` | `orderType` 可省略，值仅为 `PURCHASE` / `SUBCONTRACT`；`supplier_return_task:handle` + 精确任务 owner；只投影 PENDING_RETURN |
| 完成供应商退回 | `POST /api/procurement/arrival-exceptions/return-tasks/{id}/complete` | `supplier_return_task:handle` + 精确任务 owner + `expectedVersion` |

`allowedActions` 是动作事实源：草稿/驳回后且有提交权限才返回 `SUBMIT_FINANCE`；只有待审实例的合格审核人（财务部门资格 + `review`，含个人加授，由 `WorkflowReviewerEligibility` 实时查库）才返回订单 `APPROVE/REJECT` 或超量 `APPROVE_ALL/APPROVE_CUSTOM/REJECT_EXCESS`；只有精确任务 owner 才返回 `COMPLETE_RETURN`。超管不可绕过、已知 UUID 都不得追加对象级动作。V201 为财务任务详情最小授予财务部门 `purchase_order:view` / `subcontract_order:view`，绝不授相应 edit。

V229 起「负责人设置」已删除（见 ADR-027）：不再有固定行为码与单点默认负责人。审批人资格完全由 `finance_order_approval:review` + 财务部门（`DEPT_FIN` 及子树）在职、账号启用决定，或在权限管理里个人加授（`user_permission_overrides effect='grant'`）该权限；`WorkflowReviewerEligibility` 每次审批实时查库，超管不可绕过，取消权限即时生效，无任何合格审核人则提交/异常生成失败。`procurement_order_approval_cases.assignee_*` 与 `procurement_arrival_exceptions.finance_assignee_*` 列保留为历史快照，V229 起改为可空、新行为 NULL。

### 10.3 事务、并发和快照

提交事务必须：

1. 锁订单并验证 `status=0`、供应商、商业字段和全部来源；
2. 拒绝同订单已有 `PENDING`；
3. 复查合格审核人组非空（财务部门在职、账号启用、持 `review` 权限，或个人加授；由 `WorkflowReviewerEligibility` 实时查库），无任何合格审核人则提交失败；
4. 保存头行 canonical JSON 快照、hash 和提交人快照（V229 起 assignee 列留空，仅保留历史快照语义）；
5. 追加 `SUBMITTED` 事件并写 Outbox。

审批事务必须锁订单和待审 case，验证 `expectedVersion`、合格审核人资格（实时查库）及当前订单快照 hash 未变化。通过时在同一事务调用端口的 `applyFinanceApproval`，使订单 `status=1`、回写申请累计/生产供给，再写 case、事件和未来入库；任一步失败整体回滚。驳回只结束 case 并记录原因，不让订单生效。

来源容量必须同时计算 `ordered_qty + 其它 PENDING qty + 本次 qty`，并按稳定 ID 顺序锁来源。申请余量不能因并发提交被透支。

超量收货事务另须满足：

1. `PurchaseReceiptService.approve` / `SubcontractReceiptService.approve` 使用 `noRollbackFor = ProcurementArrivalBlockedException.class`，但仅该专用异常可提交异常任务；其它校验、库存或 AP 失败仍整体回滚。
2. 审核前重新锁收货、订单及来源，确认每行都链接财务已批订单，并按“原批准量 + 已退量 + 已成功过账超量额度 - 已收量”算余量。
3. 超量时创建或重检 `PENDING_FINANCE` 异常，冻结订单/收货/货品/数量/金额快照（V229 起 finance_assignee 列写 NULL，仅保留历史快照语义），追加事件后抛 `ARRIVAL_EXCEPTION_PENDING` 409；此路径不得改变收货状态、库存、AP 或订单累计。
4. 财务决定锁异常并校验 `expectedVersion`、合格审核人资格（实时查库）、账号/员工/权限仍有效。`APPROVE_ALL` 批全部超量，`APPROVE_CUSTOM` 必须满足 `0 < approvedExcess < requestedExcess`，`REJECT_EXCESS` 批 0；full/custom 必填有界财务说明。
5. 决定事务由服务端计算接受/未接受量。采购草稿受控调整 `qty`、重量、原币/本币金额和单头合计；委外还按接受比例缩放 `girth_qty`，并令 `check_qty=min(原 check_qty, acceptedQty)`；原订货 `order_qty` 不改。未接受量 upsert 唯一 `PENDING_RETURN`，不得让客户端金额成为权威。
6. 仓库再审只允许使用当前收货单处于 `RECEIPT_ADJUSTED` 的 `approved_excess_qty`。成功过账后才把该额度累加到订单行 `arrival_overage_posted_qty`；数据库累计触发器同时计入已过账额度和当前收货额度，防并发串用。
7. 退货 owner 优先取订单 maker 对应的有效账号，其次订单 `created_by`，最后回退到采购员/委外经办人对应的有效账号。完成时锁 `supplier_return_tasks`，校验该精确 owner 与 `expectedVersion`，只做 `PENDING_RETURN → COMPLETED`、完成说明和追加事件，不能回改财务决定。

异常状态机：

```text
PENDING_FINANCE
  ├─ accepted > 0 → RECEIPT_ADJUSTED → 仓库再审
  │                   ├─ return pending → RECEIPT_POSTED → return complete → CLOSED
  │                   └─ no return / already completed → CLOSED
  └─ accepted = 0 → RETURN_REQUIRED → return complete → CLOSED（收货行已删除）
```

标准 10→100 场景（无历史收货/退货/超量过账）：财务已批订单量 10 吨、收货草稿申报 100 吨，检测结果为批准余量 10、`requestedExcessQty=90`，先返回 `ARRIVAL_EXCEPTION_PENDING` 409，库存/AP/订单累计不变。`APPROVE_ALL` 得 accepted/return=`100/0`；`APPROVE_CUSTOM(customApprovedExcessQty=5)` 得 `15/85`；`REJECT_EXCESS` 得 `10/90`。接受量仍须仓库再审才过账；若决定时并发使批准余量变为 0，不批会删除该草稿行并直接形成 100 吨退回任务。

### 10.4 数据与通知

- `workflow_responsibility_assignments`：**V229 已删除**（见 ADR-027）；审批人改由 `finance_order_approval:review` + 财务部门资格决定。`procurement_order_approval_cases.assignee_*`/`procurement_arrival_exceptions.finance_assignee_*` 保留为历史快照，V229 起可空、新行为 NULL。
- `procurement_order_approval_cases`：每次提交一个 attempt，保存不可变提交快照和乐观锁版本。
- `procurement_order_approval_events`：append-only；禁止更新/删除。
- `inbound_expectations/items`：财务通过后唯一未来到货任务；不是实际到货、库存、IQC 或应付。
- 业务事务只写可靠 Outbox；通知只作提醒，不作为任务或权限事实源。
- 到货通知最小投递：`DETECTED` 通知全体合格审核人（V229 起，不再单发 `finance_assignee_user_id`）；`FINANCE_DECIDED` 发仓储部，接受量大于 0 提醒按调整草稿再审、接受量为 0 告知该行已移除；`RETURN_REQUIRED/RETURN_COMPLETED` 只发精确退货任务 owner。

- `procurement_arrival_exceptions`：一收货行一异常，保存数量/金额快照、决定、批准追加量、接受/未接受量和乐观锁版本（V229 起 finance_assignee 列可空、新行为 NULL，保留历史快照）。
- `supplier_return_tasks`：只承载未批准数量及精确任务 owner 的 `PENDING_RETURN/COMPLETED/CANCELED` 责任事实。
- `procurement_arrival_exception_events`：append-only；禁止更新/删除。
- `purchase_order_items/subcontract_order_items.arrival_overage_posted_qty`：只累计已经由仓库成功过账的财务追加额度。

- V201 收货行/单头守卫禁止开放异常绕过；V202 在 V196/V201 新业务表之后重新全量扫描全部 `public` 业务表，缺失时补唯一 `trg_audit*`，并 fail-closed 校验启用、AFTER ROW、I/U/D 与批准脱敏函数。V202 只覆盖以后操作，不补历史审计。

### 10.5 发布边界

目标公司库只确认到 V190。V196–V202 尚未完成目标库迁移验证、真实多账号对象范围、财务负责人、仓库收货/再审、供应商退回实物 UAT、完整 IQC 和发布签字，因此生产 **NO-GO**。源码候选的超量控制不得被表述为专业质量隔离：待检、合格、不良、特采及质量反向仍须后续实现。

Flyway 已执行迁移不可修改、改名或重排；任何共享环境一旦执行 V196–V202，修正只能新增 V203+，并在新增公开业务表后追加审计覆盖刷新。版本事实以目标库 `flyway_schema_history` 为准，SQL 顺序回放不能代替 Flyway 校验。详见 [ADR-019](../99-决策记录-ADR/ADR-019-计划需求分解与采购委外财务审批.md)。
