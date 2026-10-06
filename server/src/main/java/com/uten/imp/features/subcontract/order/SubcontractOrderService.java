package com.uten.imp.features.subcontract.order;

import com.uten.imp.application.port.WarehouseUse;
import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.application.port.ProcurementOrderApprovalPort;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.ItemSnapshot;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.OrderSnapshot;
import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.application.port.PreplanPublicSupplyCapturePort;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.finance.ProcurementCommercialSnapshotPolicy;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery;
import com.uten.imp.security.CommercialPriceVisibility;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.SubcontractGoodsSnapshot;
import com.uten.imp.features.subcontract.SubcontractGoodsKeyword;
import com.uten.imp.features.subcontract.order.dto.OrderCostItemDto;
import com.uten.imp.features.subcontract.order.dto.OrderDetail;
import com.uten.imp.features.subcontract.order.dto.OrderItemDto;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import com.uten.imp.features.subcontract.order.dto.OrderListItem;
import com.uten.imp.features.subcontract.order.dto.OrderQueryFilter;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 委外订货单服务：CRUD（主+明细，BOM 子表只读）+ 审核状态机 + 申请明细回写。
 *
 * <p>审核（status 0→1，同事务内）：仅状态变更（无库存联动、无应收应付）；
 * 若明细挂 {@code application_item_id}，则回写 {@code application_items.ordered_qty += qty}
 * 并重算申请单 is_closed（design doc 22 §3.2 / 契约 28 §五审核状态机"回写上游明细累计量"）。
 *
 * <p>红冲（1→-1）：反向回写 ordered_qty + 重算 is_closed + 置 status=-1。
 *
 * <p>BOM 成本子表 {@code subcontract_order_cost_items} <b>只读</b>（design doc 22 §五：
 * 本期不实现自动展开，保结构 + 迁老库 67 行原样数据）；通过 {@link #listCostItems(UUID)} 查询。
 */
@Service
@RequiredArgsConstructor
public class SubcontractOrderService implements ProcurementOrderApprovalPort {
    private com.uten.imp.common.history.RetainedRecordReader retainedRecords;
    @org.springframework.beans.factory.annotation.Autowired
    public void setRetainedRecords(com.uten.imp.common.history.RetainedRecordReader reader) { retainedRecords = reader; }


    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额/单据号可排序；命中才排序，否则默认 billDate DESC）。
     *  2026-09-25 单号列统一：billNo 进白名单（价格遮蔽分支见 list）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal", "billNo", "billNo");

    private final SubcontractOrderRepository orderRepo;
    private final SubcontractOrderItemRepository itemRepo;
    private com.uten.imp.common.columns.BusinessColumnService businessColumns;

    @org.springframework.beans.factory.annotation.Autowired
    public void setBusinessColumns(com.uten.imp.common.columns.BusinessColumnService service) { this.businessColumns = service; }
    private final SubcontractOrderCostItemRepository costItemRepo;
    private final LinkedDocumentIntegrityService sourceIntegrity;
    private final TxSessionVars tx;
    private final EntityManager em;
    // V476：叶子仓落库校验。字段注入+可空——单测手工构造时缺省跳过，Spring 环境恒注入。
    @org.springframework.beans.factory.annotation.Autowired(required = false)
    private com.uten.imp.features.master.warehouse.WarehouseScopeService warehouseScopes;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final DocNumberService docNumberService;
    private final ProductionSubcontractSupplyTransitionPort productionSupply;
    private PreplanPublicSupplyCapturePort publicSupplyCapture =
            PreplanPublicSupplyCapturePort.NOOP;

    @Autowired
    void setPublicSupplyCapture(PreplanPublicSupplyCapturePort value) {
        this.publicSupplyCapture = value;
    }
    /**
     * ADR-156 委外申请物料齐套才解锁下单: 建单、改单、送审、批准、批准后加量的齐套守卫, 以及订货单
     * 变动后让共用物料的申请重算可下单提醒。setter 注入: 单测手工构造本服务时为空只跳过, Spring 环境恒注入。
     */
    private com.uten.imp.features.subcontract.kit.SubcontractKitService kit;

    @Autowired
    void setKit(com.uten.imp.features.subcontract.kit.SubcontractKitService value) {
        this.kit = value;
    }

    private void requireKit(UUID orderId, String action, String hint) {
        if (kit != null) kit.requireOrderKit(orderId, action, hint);
    }

    private void enqueueKitRecheck(UUID orderId) {
        if (kit != null) kit.enqueueRecheckForOrder(orderId);
    }

    /** 委外人员下单 / 改单时的提示。 */
    private static final String KIT_HINT_ORDER =
            "请按委外任务中心显示的「可下单」数量下单，其余等物料到了再下";
    /** 送审、批准时的提示(单子已建好, 物料后来被别的单占走或用掉了)。 */
    private static final String KIT_HINT_REVIEW =
            "物料可能已被别的委外单或生产先用掉；请委外人员把数量改成委外任务中心显示的「可下单」数量，或等物料到了再提交";
    private final ProductionSupplySourceGuard productionSourceGuard;
    private final ProcurementApprovalProjectionQuery approvalProjection;
    private final ProcurementArrivalControlPort arrivalControl;
    private final SubcontractDocumentAccessPolicy access;
    private final com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService materialPlanService;
    private final com.uten.imp.features.finance.procurement.ProcurementApprovalReconfirmationService reconfirmation;
    private final MasterReferenceValidationPort references;
    private final com.uten.imp.application.port.ProcurementReviewCancellationPort reviewCancellation;
    private final com.uten.imp.application.port.ProcurementOrderSourceRevisionPort sourceRevision;
    private final com.uten.imp.common.concurrency.ProcurementMutationLocks mutationLocks;
    private final com.uten.imp.features.purchase.common.ProcurementMasterDefaultsSyncService masterDefaultsSync;
    /** ADR-098 短交案件回调(懒取：短交服务依赖本服务做改量, 构造注入会成环)。 */
    @Autowired
    private org.springframework.beans.factory.ObjectProvider<
            com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryOrderHooks> shortDeliveryHooks;

    /** ADR-098 短交回调是可选协作方：纯单测手工 new 本服务时字段为 null，同样静默跳过。 */
    private void shortDeliveryHook(
            java.util.function.Consumer<com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryOrderHooks> action) {
        if (shortDeliveryHooks != null) shortDeliveryHooks.ifAvailable(action);
    }
    @Autowired
    private CommercialPriceVisibility commercialPriceVisibility;
    /** ADR-143 §二.3 委外件缺 BOM 转研发(研发任务模块实现)；单测手工构造时为空，只跳过登记。 */
    @Autowired(required = false)
    private com.uten.imp.application.port.RdBomGapPort rdBomGaps;

    @Transactional(readOnly = true)
    public PageResponse<OrderListItem> list(OrderQueryFilter f, int page, int size, String sort, String order) {
        boolean priceMasked = subcontractPriceMasked();
        Specification<SubcontractOrder> spec = orderSpec(f);
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"),
                        // 价格遮蔽时金额排序是侧信道：金额列不进白名单（单据号排序不泄露商业信息，保留）。
                        priceMasked
                                ? Map.of("billDate", "billDate", "billNo", "billNo")
                                : ALLOWED_SORT));
        Page<SubcontractOrder> p = orderRepo.findAll(spec, pageable);
        Map<UUID, FinanceApproval> approvals = approvalProjection.latestForOrders(
                orderType(),
                p.getContent().stream().collect(Collectors.toMap(
                        SubcontractOrder::getId,
                        row -> row.getStatus())));
        List<OrderListItem> items = p.getContent().stream()
                .map(row -> toList(row, approvals.get(row.getId()), priceMasked))
                .toList();
        PageResponse<OrderListItem> result = new PageResponse<>(
                items, p);
        return p.stream().noneMatch(SubcontractOrder::isDeleted) ? result
                : retainedRecords.page(result, "subcontract_orders", p.getContent());
    }

    /** 单据号列值筛选桶（2026-09-25 单号列统一）：与列表同一份谓词分组计数。 */
    @Transactional(readOnly = true)
    public java.util.Map<String, List<java.util.Map<String, Object>>> facets(OrderQueryFilter f) {
        return java.util.Map.of("billNo",
                com.uten.imp.common.web.TableFacets.groupCount(em, SubcontractOrder.class, orderSpec(f), "billNo"));
    }

    /** 列表/桶共用的谓词基座（2026-09-25 单号列统一抽出）：财务审批态切片 + 基础过滤。 */
    private Specification<SubcontractOrder> orderSpec(OrderQueryFilter f) {
        var readScope = access.scope();
        // 财务审批态切片（financeApproval）：与采购订货单同构——财务通过前 status
        // 保持 0，草稿段与「等待财务审核」段同为 status=0，按 PENDING case 集合区分。
        String financeApproval = normalizeFinanceApprovalSlice(f.financeApproval());
        java.util.Set<UUID> pendingFinanceIds = financeApproval == null
                ? null
                : approvalProjection.pendingOrderIds(orderType());
        // 财务退回件(最新 case=REJECTED): 「财务已退回」段圈定; 草稿段(NONE)同时排除在审与退回.
        java.util.Set<UUID> rejectedFinanceIds = financeApproval == null
                ? null
                : approvalProjection.rejectedOrderIds(orderType());
        return (Root<SubcontractOrder> root,
                jakarta.persistence.criteria.CriteriaQuery<?> q,
                CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            if (f.onlyDeleted()) ps.add(cb.isTrue(root.get("deleted")));
            else if (!f.includeDeleted()) ps.add(cb.isFalse(root.get("deleted")));
            ps.add(access.readablePredicate(root, cb, "makerId", readScope));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(SubcontractGoodsKeyword.predicate(
                        cb, q, root, SubcontractOrderItem.class, "orderId", f.keyword()));
            }
            if (f.supplierId() != null) ps.add(cb.equal(root.get("supplierId"), f.supplierId()));
            if (f.warehouseId() != null) ps.add(cb.equal(root.get("warehouseId"), f.warehouseId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            if (f.closed() != null) ps.add(cb.equal(root.get("closed"), f.closed()));
            // 2026-09-25 单号列统一：单据号表头值筛选（精确匹配）。
            if (f.billNo() != null && !f.billNo().isBlank()) {
                ps.add(cb.equal(root.get("billNo"), f.billNo().trim()));
            }
            if (financeApproval != null) {
                if ("IN_PROGRESS".equals(financeApproval)) {
                    // 进行中包含财务在审/退回待修改，以及批准后尚未结案的执行单。
                    // 聚合在数据库分页前完成，不能在前端拼接多份分页结果。
                    java.util.Set<UUID> financeIds = new java.util.HashSet<>(pendingFinanceIds);
                    financeIds.addAll(rejectedFinanceIds);
                    Predicate financePending = financeIds.isEmpty()
                            ? cb.disjunction()
                            : cb.and(cb.equal(root.get("status"), STATUS_DRAFT),
                                    root.get("id").in(financeIds));
                    Predicate executing = cb.and(
                            cb.equal(root.get("status"), STATUS_APPROVED),
                            cb.isFalse(root.get("closed")));
                    ps.add(cb.or(financePending, executing));
                } else if ("PENDING".equals(financeApproval)) {
                    // 空集时 in() 会生成非法 SQL：无在审单 → 恒假。
                    if (pendingFinanceIds.isEmpty()) {
                        ps.add(cb.disjunction());
                    } else {
                        ps.add(root.get("id").in(pendingFinanceIds));
                    }
                } else if ("REJECTED".equals(financeApproval)) {
                    // 财务已退回段: 无退回件 → 恒假.
                    if (rejectedFinanceIds.isEmpty()) {
                        ps.add(cb.disjunction());
                    } else {
                        ps.add(root.get("id").in(rejectedFinanceIds));
                    }
                } else {
                    // NONE: 排除在审单与财务退回件(2026-09-21 起退回件有自己的段); 空集无需谓词.
                    if (!pendingFinanceIds.isEmpty()) {
                        ps.add(cb.not(root.get("id").in(pendingFinanceIds)));
                    }
                    if (!rejectedFinanceIds.isEmpty()) {
                        ps.add(cb.not(root.get("id").in(rejectedFinanceIds)));
                    }
                }
            }
            f.headerFilters().apply(root, cb, ps, "totalLocal", commercialPriceVisibility != null && commercialPriceVisibility.canViewSubcontractOrder(), null, false, null, false);
            return cb.and(ps.toArray(new Predicate[0]));
        };
    }

    @Transactional(readOnly = true)
    public OrderDetail detail(UUID id) { return readDetail(id, false); }


    @Transactional(readOnly = true)
    public OrderDetail detailHistory(UUID id) { return readDetail(id, true); }

    private OrderDetail readDetail(UUID id, boolean historyRead) {
        SubcontractOrder r = requireOrder(id, historyRead);
        if (!access.canRead(r.getMakerId())
                && !approvalProjection.canCurrentActorReviewPending(orderType(), id)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "委外订货单不存在");
        }
        return finishHistory(assembleDetail(r), r, historyRead);
    }

    private OrderDetail assembleDetail(SubcontractOrder r) {
        List<SubcontractOrderItem> items = itemRepo.findByOrderIdOrderByLineNoAsc(r.getId());
        Map<UUID, List<Object[]>> sources = orderItemSources(
                items.stream().map(SubcontractOrderItem::getId).toList());
        List<OrderItemDto> itemDtos = items.stream()
                .map(it -> toItemDto(it, sourceApplicationDocs(
                        sources.getOrDefault(it.getId(), List.of()))))
                .toList();
        if (!itemDtos.isEmpty() && r.getStatus() != null && r.getStatus() == STATUS_APPROVED) {
            Map<UUID,BigDecimal> settled = new java.util.HashMap<>();
            for (Object[] row : com.uten.imp.common.util.NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT id,fn_subcontract_settled_loss_qty(id)
                    FROM subcontract_order_items WHERE order_id=:orderId AND NOT is_deleted
                    """).setParameter("orderId",r.getId()))) {
                settled.put((UUID)row[0],(BigDecimal)row[1]);
            }
            itemDtos.forEach(item -> item.setSettledLossQty(settled.getOrDefault(item.getId(),BigDecimal.ZERO)));
        }
        return toDetail(r, itemDtos, approvalProjection.latestForOrder(
                orderType(), r.getId(), r.getStatus()), shortDeliveryHold(r.getId()));
    }

    /** sources 原始行 → 结构化来源申请引用（明细 id + 申请单 id + 单号）。 */
    private static List<OrderItemDto.SourceApplicationDoc> sourceApplicationDocs(
            List<Object[]> rows) {
        return rows.stream()
                .map(row -> new OrderItemDto.SourceApplicationDoc(
                        (UUID) row[1], (UUID) row[4], row[2] == null ? null : row[2].toString()))
                .toList();
    }

    /**
     * 订货行 → 来源分配行（order_item_id → [order_item_id, 来源申请明细 id,
     * 申请单号, alloc_qty, 申请单 id]，按 line_no/id 稳定排序）。V463 多来源锚定的统一读取入口。
     */
    private Map<UUID, List<Object[]>> orderItemSources(List<UUID> orderItemIds) {
        if (orderItemIds == null || orderItemIds.isEmpty()) {
            return Map.of();
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT src.order_item_id, src.application_item_id,
                               application.bill_no, src.alloc_qty,
                               application.id AS application_id
                        FROM subcontract_order_item_sources src
                        JOIN subcontract_application_items item
                          ON item.id = src.application_item_id
                        LEFT JOIN subcontract_applications application
                          ON application.id = item.application_id
                        WHERE src.order_item_id IN (:ids)
                        ORDER BY src.order_item_id, src.line_no, src.id
                        """).setParameter("ids", orderItemIds));
        Map<UUID, List<Object[]>> out = new java.util.HashMap<>();
        for (Object[] row : rows) {
            out.computeIfAbsent((UUID) row[0], ignored -> new ArrayList<>()).add(row);
        }
        return out;
    }

    /** 查询订货单的 BOM 成本子表（只读；前端按 bom_level + parent_cost_item_id 渲染树）。 */
    @Transactional(readOnly = true)
    public List<OrderCostItemDto> listCostItems(UUID orderId) {
        SubcontractOrder o = requireOrder(orderId);
        access.requireReadable(o.getMakerId(), "委外订货单不存在");
        return costItemRepo.findByOrderIdOrderByBomLevelAsc(orderId).stream()
                .map(this::toCostItemDto).toList();
    }

    @Transactional
    @PreAuthorize("hasAuthority('subcontract_order:create')")
    public OrderDetail create(OrderSaveRequest req) {
        requireDecompositionAuthorityIfNeeded(req);
        tx.bind();
        requireRowsMatchHeaderSupplier(req);
        requireRowsMatchHeaderCommercial(req);
        var mutationGuard=lockOrderRequest(null,req);
        mutationGuard.verifyUnchanged();
        requireDrawableBomForApplicationLines(req);
        SubcontractOrder r = new SubcontractOrder();
        applyHeader(req, r);
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        r.setStatus(STATUS_DRAFT);
        mutationLocks.expectCreatedOrder(orderType(),r.getId());
        orderRepo.save(r);
        orderRepo.flush();
        mutationLocks.registerCreatedOrder(orderType(),r.getId());
        List<OrderItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        // 主档写回必须在明细落库并 flush 之后: 写回服务按订单 id 用 JDBC 读
        // subcontract_orders/subcontract_order_items 取事实, Hibernate 未 flush 的头/行它看不见
        // (此前放在 save 之后、明细之前, 新建单永远学不到货品委外商与加工单价)。
        orderRepo.flush();
        masterDefaultsSync.syncFromSubcontractOrder(r.getId());
        // ADR-156：明细落库后按本单需要核对直属物料齐套(同事务内拆出的几张单彼此可见, 不会重复占同一批库存)。
        requireKit(r.getId(), "生成委外订货单", KIT_HINT_ORDER);
        enqueueKitRecheck(r.getId());
        return toDetail(r, items);
    }

    /**
     * 按明细级「委外商+商业条款」组合拆单创建（保留「一张订货单一个委外商一套条款」
     * 归集）：每行各字段为空时回落表头，按组合分组在同一事务内生成 N 张订货单
     * （多数情况 1 张），每组条款写入该张单的头字段。返回按分组顺序的明细。
     */
    @Transactional
    @PreAuthorize("hasAuthority('subcontract_order:create')")
    public List<OrderDetail> createBatch(OrderSaveRequest req) {
        requireDecompositionAuthorityIfNeeded(req);
        tx.bind();
        Map<CommercialGroupKey, List<OrderItemLine>> groups = groupByCommercial(req);
        lockOrderRequest(null,req).verifyUnchanged();
        List<OrderDetail> created = new ArrayList<>();
        for (Map.Entry<CommercialGroupKey, List<OrderItemLine>> entry : groups.entrySet()) {
            CommercialGroupKey key = entry.getKey();
            OrderSaveRequest sub = new OrderSaveRequest();
            sub.setBillDate(req.getBillDate());
            sub.setSupplierId(key.supplierId());
            sub.setWarehouseId(req.getWarehouseId());
            sub.setCurrencyId(key.currencyId());
            sub.setExchangeRate(key.exchangeRate());
            sub.setTaxRate(key.taxRate());
            // 拆单必须携带结算方式，否则生成的订货单无法通过 applyHeader 的必填校验
            sub.setSettlementMethodId(key.settlementMethodId());
            sub.setPurchaserId(req.getPurchaserId());
            sub.setDeliverDate(req.getDeliverDate());
            sub.setRemark(req.getRemark());
            sub.setItems(entry.getValue());
            created.add(create(sub));
        }
        return created;
    }

    /** 商业拆单分组键：委外商 + 结算方式 + 币种 + 汇率 + 税率（数值按值等价，2.0 与 2 同组）。 */
    record CommercialGroupKey(
            UUID supplierId,
            UUID settlementMethodId,
            UUID currencyId,
            BigDecimal exchangeRate,
            BigDecimal taxRate) {
        CommercialGroupKey {
            exchangeRate = normalizeDecimal(exchangeRate);
            taxRate = normalizeDecimal(taxRate);
        }

        private static BigDecimal normalizeDecimal(BigDecimal value) {
            if (value == null) return null;
            BigDecimal stripped = value.stripTrailingZeros();
            if (stripped.signum() == 0) return BigDecimal.ZERO;
            // toPlainString 消除 stripTrailingZeros 产生的负 scale（如 2E+1），保证 equals 语义稳定
            return new BigDecimal(stripped.toPlainString());
        }
    }

    /**
     * 行级商业条款分组（包内可见，供单测锁定拆单口径）：每行字段为空回落表头，
     * 按「委外商+结算方式+币种+汇率+税率」组合分组（LinkedHashMap 保序）。
     * 逐行校验组合完整性：委外商/结算方式/币种必填，汇率大于 0，税率 0-100。
     * 业务上订货允许超过申请剩余量（2026-09 放开超委外），此处不做数量上限校验。
     */
    static Map<CommercialGroupKey, List<OrderItemLine>> groupByCommercial(OrderSaveRequest req) {
        if (req.getItems() == null || req.getItems().isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "订货明细不能为空");
        }
        Map<CommercialGroupKey, List<OrderItemLine>> groups = new LinkedHashMap<>();
        for (OrderItemLine item : req.getItems()) {
            UUID supplier = item.getSupplierId() != null
                    ? item.getSupplierId()
                    : req.getSupplierId();
            if (supplier == null) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "每一行都必须指定委外商(明细级或表头)");
            }
            UUID settlement = item.getSettlementMethodId() != null
                    ? item.getSettlementMethodId()
                    : req.getSettlementMethodId();
            if (settlement == null) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "每一行都必须指定结算方式(明细级或表头)");
            }
            UUID currency = item.getCurrencyId() != null
                    ? item.getCurrencyId()
                    : req.getCurrencyId();
            if (currency == null) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "每一行都必须指定币种(明细级或表头)");
            }
            BigDecimal rate = item.getExchangeRate() != null
                    ? item.getExchangeRate()
                    : req.getExchangeRate();
            if (rate == null || rate.signum() <= 0) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "每一行的汇率必须大于 0(明细级或表头)");
            }
            BigDecimal tax = item.getTaxRate() != null
                    ? item.getTaxRate()
                    : req.getTaxRate();
            if (tax == null || tax.signum() < 0 || tax.compareTo(BigDecimal.valueOf(100)) > 0) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "每一行的税率必须在 0 至 100 之间(明细级或表头)");
            }
            groups.computeIfAbsent(
                    new CommercialGroupKey(supplier, settlement, currency, rate, tax),
                    k -> new ArrayList<>()).add(item);
        }
        return groups;
    }

    /**
     * 货品 → 主档默认条款 (新建单行级预填; 端点路径沿用 /last-terms, 语义已是主档默认值)。
     *
     * <p>V593 起主档是唯一来源: goods.default_supplier_id (货品绑定的默认委外商) →
     * 该供应商主档默认条款 (结算方式/币种/税率, 每次保存订货单写回) → 货品默认委外加工
     * 单价 (goods.default_subcontract_price)。汇率取币种现行汇率。「按最近一张订货单推导」
     * 的回退路径已退役 (2026-09-16): 主档没有绑定就不预填, 不再实时扫订单表。
     *
     * <p>货品有默认供应商或默认加工单价才返回行; supplierId 只在供应商未删且非内部车间时
     * 给出 (停用供应商照给, 是否可回填由前端按字典判断), 条款随供应商一起为空。
     */
    @Transactional(readOnly = true)
    public Map<UUID, MasterDefaultTermsPerGoods> masterDefaultTermsPerGoods(
            java.util.Collection<UUID> goodsIds) {
        if (goodsIds == null || goodsIds.isEmpty()) {
            return Map.of();
        }
        boolean priceMasked = subcontractPriceMasked();
        Map<UUID, MasterDefaultTermsPerGoods> result = new LinkedHashMap<>();
        for (Object[] row : com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery(
                """
                SELECT g.id, sup.id,
                       sup.default_settlement_method_id,
                       sup.default_currency_id,
                       cur.exchange_rate,
                       sup.default_tax_rate,
                       g.default_subcontract_price,
                       g.default_subcontract_price_supplier_id,
                       g.default_subcontract_price_color_id,
                       g.default_subcontract_price_unit_id,
                       g.default_subcontract_price_currency_id,
                       g.default_subcontract_price_tax_rate,
                       g.subcontract_allowed_loss_pct
                FROM goods g
                LEFT JOIN suppliers sup
                  ON sup.id = g.default_supplier_id
                 AND sup.is_deleted = false
                 AND sup.is_internal_workshop = false
                LEFT JOIN currencies cur ON cur.id = sup.default_currency_id
                WHERE g.id IN (:ids)
                  AND g.is_deleted = false
                  AND (g.default_supplier_id IS NOT NULL
                       OR g.default_subcontract_price IS NOT NULL
                       OR g.subcontract_allowed_loss_pct IS NOT NULL)
                """).setParameter("ids", goodsIds))) {
            BigDecimal allowedLossPct = (BigDecimal) row[12];
            result.put((UUID) row[0], new MasterDefaultTermsPerGoods(
                    (UUID) row[1], priceMasked ? null : (UUID) row[2],
                    priceMasked ? null : (UUID) row[3], priceMasked ? null : (BigDecimal) row[4],
                    priceMasked ? null : (BigDecimal) row[5], priceMasked ? null : (BigDecimal) row[6],
                    priceMasked ? null : new com.uten.imp.features.purchase.common.ProcurementDefaultPriceContext(
                            (UUID) row[7], (UUID) row[8], (UUID) row[9],
                            (UUID) row[10], (BigDecimal) row[11]),
                    allowedLossPct, allowedLossPct == null ? null : "GOODS_MASTER"));
        }
        return result;
    }

    /**
     * 主档默认条款视图 (/last-terms 返回体; 字段口径见 goods / suppliers 主档列)。
     * subcontractPrice=goods.default_subcontract_price (行价预填)。
     * allowedLossPct=goods.subcontract_allowed_loss_pct (ADR-098 允许损耗记忆, 来源 GOODS_MASTER;
     * 不随加工费脱敏, 它不是价格)。
     */
    public record MasterDefaultTermsPerGoods(
            UUID supplierId,
            UUID settlementMethodId,
            UUID currencyId,
            BigDecimal exchangeRate,
            BigDecimal taxRate,
            BigDecimal subcontractPrice,
            com.uten.imp.features.purchase.common.ProcurementDefaultPriceContext priceContext,
            BigDecimal allowedLossPct,
            String allowedLossPctSource) {}

    @Transactional
    @PreAuthorize("hasAuthority('subcontract_order:edit')")
    public OrderDetail update(UUID id, OrderSaveRequest req) {
        tx.bind();
        var mutationGuard=lockOrderRequest(id,req);
        SubcontractOrder r = requireOrderForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外订货单");
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        approvalProjection.requireMutable(orderType(), id);
        mutationGuard.verifyUnchanged();
        requireRowsMatchHeaderSupplier(req);
        requireRowsMatchHeaderCommercial(req);
        var oldItems=itemRepo.findByOrderIdOrderByLineNoAsc(id);
        var previousColumns = previousColumns(req.getItems(), oldItems);
        Map<OrderItemLine,SubcontractOrderItem> retained=new java.util.IdentityHashMap<>();
        var remaining=new ArrayList<>(oldItems);
        int requestedLine=0;
        for(var line:req.getItems()){
            requestedLine++;final int sameLine=line.getLineNo()==null?requestedLine:line.getLineNo();
            if(!line.resolvedApplicationItemIds().isEmpty())continue;
            var match=remaining.stream().filter(old->old.getApplicationItemId()==null
                    && Objects.equals(old.getGoodsId(),line.getGoodsId()) && Objects.equals(old.getColorId(),line.getColorId())
                    && Objects.equals(old.getUnitId(),line.getUnitId()) && old.getQty().compareTo(line.getQty())==0
                    && old.getUnitRate().compareTo(line.getUnitRate()==null?BigDecimal.ONE:line.getUnitRate())==0)
                    .sorted(java.util.Comparator.comparingInt(old->Objects.equals(old.getLineNo(),sameLine)?0:1)).findFirst();
            if(match.isPresent()){retained.put(line,match.get());remaining.remove(match.get());}
        }
        applyHeader(req, r);
        for(var removed:remaining){removed.setDeleted(true);itemRepo.save(removed);}
        itemRepo.flush();
        List<OrderItemDto> items = saveItems(r, req.getItems(),retained, previousColumns);
        applyTotals(r, items);
        // 主档写回按订单 id 用 JDBC 读事实, 头/行改动必须先 flush (顺序即契约)。
        orderRepo.flush();
        masterDefaultsSync.syncFromSubcontractOrder(r.getId());
        requireKit(r.getId(), "保存委外订货单", KIT_HINT_ORDER);
        enqueueKitRecheck(r.getId());
        return toDetail(r, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('subcontract_order:delete')")
    public void delete(UUID id) {
        tx.bind();
        var mutationGuard=mutationLocks.order(orderType(),id);
        SubcontractOrder r = requireOrderForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外订货单");
        com.uten.imp.common.web.StandardDocumentLifecycleCapabilities.requireDraftForDelete(r.getStatus());
        approvalProjection.requireMutable(orderType(), id);
        mutationGuard.verifyUnchanged();
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        orderRepo.save(r);
        // ADR-156：草稿删掉后它占着的物料放出来, 共用物料的委外申请重算可下单。
        enqueueKitRecheck(id);
    }

    @Override
    public String orderType() {
        return "SUBCONTRACT";
    }

    /**
     * 财务审批态切片参数：null/空 = 不切片（legacy 口径，status=0 含在审单）；
     * NONE = 未提交的真草稿；PENDING = 已提交在审；REJECTED = 财务退回；
     * IN_PROGRESS = 在审/退回待修改，或批准后未结案。非法值 fail-closed。
     */
    private static String normalizeFinanceApprovalSlice(String raw) {
        String value = raw == null ? "" : raw.trim().toUpperCase(java.util.Locale.ROOT);
        return switch (value) {
            case "", "NONE", "PENDING", "REJECTED", "IN_PROGRESS" -> value.isEmpty() ? null : value;
            default -> throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "财务审批态筛选无效");
        };
    }

    private com.uten.imp.application.concurrency.FulfillmentMutationLocks.Guard lockOrderRequest(UUID id,OrderSaveRequest req) {
        List<OrderItemLine> lines=req==null||req.getItems()==null?List.of():req.getItems();
        return mutationLocks.orderInputs(orderType(),id,lines.stream().filter(Objects::nonNull)
                        .flatMap(line->line.resolvedApplicationItemIds().stream()).toList(),
                lines.stream().filter(Objects::nonNull).filter(line->line.getGoodsId()!=null)
                        .map(line->new com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension(line.getGoodsId(),line.getColorId())).toList(),
                req==null?null:req.getWarehouseId());
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireFinanceSubmitterWritable(UUID id) {
        SubcontractOrder order = requireOrderForUpdate(id);
        access.requireWritable(
                order.getMakerId(),
                "只能提交本人负责或已正式交接的委外订货单");
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public OrderSnapshot lockAndValidateFinanceSubmission(UUID id) {
        SubcontractOrder order = requireOrderForUpdate(id);
        if (order.getStatus() == null || order.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.CONFLICT, "仅草稿订货单可提交或执行财务审核");
        }
        if (order.getSupplierId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "委外订货单必须指定委外商");
        }
        List<SubcontractOrderItem> items =
                itemRepo.findByOrderIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "订货明细不能为空");
        }
        // 委外订货两条来源：①计划下达的申请分解（application_item_id 非空，走来源校验）；
        // ②委外自建手工单（application_item_id 为空，无申请来源可校）。两条都是同一张订货单。
        normalizePersistedUnits(items);
        requireActiveSettlementMethod(order.getSettlementMethodId(), "委外订货");
        ProcurementCommercialSnapshotPolicy.requireComplete(
                em,
                order.getCurrencyId(),
                order.getExchangeRate(),
                order.getTaxRate(),
                "委外订货");
        requireFinanceCommercialAuthority(order, items);
        lockAndValidateSourcesIncludingPending(order, items);
        // ADR-143 §二.3：委外件必须先有可发外的直属物料(BOM)；缺的先转研发，提交人进等待名单。
        requireDrawableBom(order, items, null);
        // ADR-156：送审时再核一次直属物料齐套(建单后物料可能已被别的单或生产用掉)。
        requireKit(id, "提交财务", KIT_HINT_REVIEW);
        return snapshot(order, items);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public boolean isFinanceApproved(UUID id) {
        SubcontractOrder order = requireOrderForUpdate(id);
        return order.getStatus() != null && order.getStatus() == STATUS_APPROVED;
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public OrderSnapshot lockFinanceReconfirmationSnapshot(UUID id) {
        SubcontractOrder order = requireOrderForUpdate(id);
        if (order.getStatus() == null || order.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.CONFLICT, "委外订货单已不在已批准状态，请刷新");
        }
        return snapshot(order, itemRepo.findByOrderIdOrderByLineNoAsc(id));
    }

    /**
     * V486 财务批准后受控改量（对齐销售 V482）：立即生效 + 自动开财务复核 case
     * + 逐行 old→new 事实账。最低量来自真实回厂与委外商处物料结存折算的套数；
     * 领料计划行按新订货量整体重算(ADR-143 §二.14)，已提交未发的领料超出新计划量时
     * 先撤回再改量。
     */
    @Transactional
    @PreAuthorize("hasAuthority('subcontract_order:change_qty')")
    public OrderDetail changeQty(
            UUID id, OrderQtyChangeRequest request) {
        requireNoPendingShortDeliveryJudgement(id);
        return changeQtyInternal(id, request, true, false);
    }

    /**
     * ADR-098 委外回厂短交「接受损耗结案」专用入口：权限点是 subcontract_short_delivery:decide
     * (由判定服务校验), 不再要求 change_qty; 业务守卫(本人订货单、财务批准后、下限=已回厂净量
     * +供应商处剩料)与普通改量完全一致。
     *
     * <p>唯一放宽的是「无在办财务复核」那一条(ADR-101)：受控改量自己就会开一条 PENDING 复核，
     * 于是同一张订货单的第二行结案必被第一行开出来的复核挡死，连它刚开的损耗单一起回滚——
     * 多货品委外单只要短交两行就永远结不掉。这道闸防的是人为叠加两次自由改量；短交结案
     * 不是自由改量，它记的是「回厂多少、损耗多少」这个既成事实，且每行只有一个开放案件把关。
     */
    @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
    public OrderDetail changeQtyForShortDelivery(UUID id, OrderQtyChangeRequest request) {
        return changeQtyInternal(id, request, false, false);
    }

    /**
     * ADR-101 容差内自动结案专用入口：与 {@link #changeQtyForShortDelivery} 的唯一差别是
     * **不走订货单属主守卫**。
     *
     * <p>为什么必须区分：自动结案跑在仓库确认入库的同一个事务里, 发起人是仓库账号。
     * 仓库账号既不是委外订货单的制单人, 通常也没有 subcontract:view:all, 走属主守卫必拿
     * FORBIDDEN; 而这段异常会把整个事务标成只能回滚 —— 货就入不了库了。自动结案是锦上添花,
     * 绝不能反过来把仓库正常的入库动作搞失败(同一条理由见 SubcontractShortDeliveryService
     * 的 autoCloseWouldSucceed 注释, 那里体检的是数量维度, 这里补的是权限维度)。
     *
     * <p>放宽的只有属主这一条, 而且它放宽的是「谁在操作」而不是「能做什么」：这条路径不是
     * 人在改别人的单, 是系统按本单自己约定的允许损耗记一笔既成事实。数量下限、财务批准态、
     * 并发互斥锁、库存维度锁、身份守卫与审计一个不动; 调用方那一侧还另有四重前提
     * (severity 在允许损耗内、案件处于 PENDING_OWNER 或 WAITING_MORE、已回厂量为正、
     * autoCloseWouldSucceed 体检通过), 人手动走判定页仍然走 {@link #changeQtyForShortDelivery}
     * 的属主守卫。
     *
     * <p>ADR-103 §2.5 实施记录：这条路**照样开财务复核 case**。V503 守卫要求批准后改量在同一
     * 事务里开出新的 PENDING 复核(缺了直接 23514 回滚), 系统结案与人为改量在这一点上没有区别;
     * 财务复核的是「按约定损耗把订货量改到实收」这笔既成事实, 短交判定本身已经结束。
     */
    @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
    public OrderDetail changeQtyForShortDeliveryBySystem(UUID id, OrderQtyChangeRequest request) {
        return changeQtyInternal(id, request, false, true);
    }

    private OrderDetail changeQtyInternal(
            UUID id, OrderQtyChangeRequest request, boolean rejectWhenReconfirmationPending,
            boolean systemInitiated) {
        tx.bind();
        var mutationGuard=mutationLocks.order(orderType(),id);
        SubcontractOrder order = requireOrderForUpdate(id);
        if (!systemInitiated) {
            access.requireWritable(order.getMakerId(), "只能操作本人负责的委外订货单");
        }
        if (order.getStatus() == null || order.getStatus() != STATUS_APPROVED) {
            throw new ApiException(
                    ErrorCode.BUSINESS, "仅财务批准后的委外订货单可改量");
        }
        mutationGuard.verifyUnchanged();
        if (rejectWhenReconfirmationPending) requireNoPendingApprovalCase(id);
        List<SubcontractOrderItem> items =
                itemRepo.findByOrderIdOrderByLineNoAsc(id);
        Map<UUID, SubcontractOrderItem> byId = items.stream()
                .collect(java.util.stream.Collectors.toMap(
                        SubcontractOrderItem::getId, it -> it, (a, b) -> a,
                        LinkedHashMap::new));
        List<Object[]> changes = new ArrayList<>();
        for (OrderQtyChangeItem change : request.items()) {
            SubcontractOrderItem item = byId.get(change.orderItemId());
            if (item == null) {
                throw new ApiException(
                        ErrorCode.NOT_FOUND,
                        "改量行不存在或已不属于本订货单：" + change.orderItemId());
            }
            BigDecimal newQty = change.newQty();
            BigDecimal oldQty = item.getQty();
            if (newQty.compareTo(oldQty) == 0) {
                continue;
            }
            var receiptBound=com.uten.imp.common.finance.ProcurementOrderQuantityBounds.receipts(em,orderType(),item.getId());
            BigDecimal unitRate=item.getUnitRate()==null ? BigDecimal.ONE : item.getUnitRate();
            BigDecimal settledLoss = (BigDecimal) em.createNativeQuery(
                    "SELECT fn_subcontract_settled_loss_qty(CAST(:item AS uuid))")
                    .setParameter("item",item.getId()).getSingleResult();
            if (settledLoss == null) settledLoss = BigDecimal.ZERO;
            BigDecimal locked = receiptBound.minimumOrderedQty(unitRate).add(settledLoss)
                    .max(materialPlanService.minimumOrderQtyFromIssued(item.getId(),unitRate));
            if (newQty.compareTo(locked) < 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "第 " + item.getLineNo() + " 行新数量不能低于已锁定数量 "
                                + locked.stripTrailingZeros().toPlainString()
                                + "(已回厂净量/已发外物料折算套数)");
            }
            changes.add(new Object[]{item, oldQty, newQty,receiptBound,UUID.randomUUID()});
        }
        if (changes.isEmpty()) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "没有任何数量变化");
        }
        BigDecimal rate = order.getExchangeRate();
        sourceRevision.prepare(orderType(),id,changes.stream().map(change -> {
            SubcontractOrderItem item=(SubcontractOrderItem)change[0];
            return new com.uten.imp.application.port.ProcurementOrderSourceRevisionPort.Line((UUID)change[4],item.getId(),
                    (BigDecimal)change[1],(BigDecimal)change[2],item.getUnitRate()==null?BigDecimal.ONE:item.getUnitRate());
        }).toList());
        Map<UUID, BigDecimal> baseDelta = new LinkedHashMap<>();
        Map<UUID, BigDecimal> unitRates = new LinkedHashMap<>();
        Map<UUID, UUID> goodsByItem = new LinkedHashMap<>();
        for (Object[] change : changes) {
            SubcontractOrderItem item = (SubcontractOrderItem) change[0];
            BigDecimal newQty = (BigDecimal) change[2];
            BigDecimal unitRate = item.getUnitRate() == null
                    ? BigDecimal.ONE : item.getUnitRate();
            baseDelta.put(item.getId(),
                    MoneyPolicy.quantity(newQty.subtract((BigDecimal) change[1]).multiply(unitRate)));
            unitRates.put(item.getId(), unitRate);
            goodsByItem.put(item.getId(), item.getGoodsId());
            item.setTotalAmountInput(MoneyPolicy.revisedTotalAmountInput(
                    item.getTotalAmountInput(), (BigDecimal) change[1], newQty));
            item.setQty(newQty);
            BigDecimal original = com.uten.imp.common.columns.ExtraColumnCalculator.apply(
                    item.getPrice() == null ? null : MoneyPolicy.orderBaseAmount(newQty, item.getPrice(), item.getTotalAmountInput()), item.getExtraColumns());
            MoneyPolicy.LineAmounts amounts = new MoneyPolicy.LineAmounts(original,
                    original == null || rate == null ? null : MoneyPolicy.local(original, rate));
            item.setAmountOriginal(amounts.original());
            item.setAmountLocal(amounts.local());
            itemRepo.save(item);
        }
        recalcOrderTotals(order, items);
        orderRepo.save(order);
        orderRepo.flush();
        sourceRevision.apply(orderType(),id,changes.stream().map(change ->(UUID)change[4]).toList());
        for(Object[] change:changes) {
            SubcontractOrderItem item=(SubcontractOrderItem)change[0];
            com.uten.imp.common.finance.ProcurementOrderQuantityBounds.synchronizeExpectation(em,orderType(),
                    item.getId(),(BigDecimal)change[2],item.getUnitRate()==null ? BigDecimal.ONE : item.getUnitRate(),
                    (com.uten.imp.common.finance.ProcurementOrderQuantityBounds.ReceiptBound)change[3]);
        }
        materialPlanService.applyOrderQtyChange(
                id, baseDelta, unitRates, goodsByItem);
        // ADR-156：批准后加量同样要有齐套的直属物料(减量不拦); 改量后共用物料的委外申请重算可下单。
        if (changes.stream().anyMatch(change -> ((BigDecimal) change[2]).compareTo((BigDecimal) change[1]) > 0)) {
            requireKit(id, "加量", KIT_HINT_ORDER);
        }
        enqueueKitRecheck(id);
        com.uten.imp.common.finance.ProcurementOrderClosurePolicy.recalculate(em,orderType(),
                ((SubcontractOrderItem)changes.getFirst()[0]).getId());
        em.refresh(order);
        // ADR-103 §2.5 实施记录：系统按约定允许损耗自动结案**照样**开财务复核 case——V503 的
        // fn_check_procurement_source_revision 把「批准后改量必须同事务完成原数量差异账和新的
        // 财务复核」焊进了库里(缺 PENDING 复核直接 23514 回滚), 系统结案与人为改量在这一点上
        // 没有区别; 财务复核的是「按约定损耗把订货量改到实收」这笔既成事实。要免复核得改 V503
        // 守卫(需迁移), 属另一次决策。
        OrderSnapshot postChange = snapshot(order, items);
        UUID caseId = reconfirmation.openReconfirmationCase(
                postChange, changes.size());
        UUID actorEmployee = currentUser.requireEmployeeId();
        for (Object[] change : changes) {
            SubcontractOrderItem item = (SubcontractOrderItem) change[0];
            em.createNativeQuery("""
                    INSERT INTO procurement_order_qty_change_logs(
                        id, order_type, order_id, order_item_id,
                        old_qty, new_qty, case_id, changed_by_employee_id)
                    VALUES (?, 'SUBCONTRACT', ?, ?, ?, ?, ?, ?)
                    """)
                    .setParameter(1, change[4])
                    .setParameter(2, id)
                    .setParameter(3, item.getId())
                    .setParameter(4, change[1])
                    .setParameter(5, change[2])
                    .setParameter(6, caseId)
                    .setParameter(7, actorEmployee)
                    .executeUpdate();
        }
        orderRepo.flush();
        itemRepo.flush();
        // ADR-098：改量后重评开放的短交案件(新订货量不高于累计回厂 → 自然完成)。
        shortDeliveryHook(hooks -> hooks.reevaluateAfterOrderQuantityChange(id));
        if (systemInitiated) {
            // 系统自动结案这条路的返回值在调用点(SubcontractShortDeliveryService.acceptLoss)
            // 就被丢弃, 而 detail(id) 是面向人的读模型, 它自己带一道属主**读**守卫
            // (access.canRead(makerId), 读不到就抛 NOT_FOUND「委外订货单不存在」)。
            // 放开写守卫却在这里构造读模型, 仓库账号照样会在方法最后一行炸, 照样把仓库
            // 确认入库的整个事务标成只能回滚 —— 和放开前的表现一模一样, 只是换了个洞。
            // 系统路径压根不需要这个读模型, 不构造它。
            return null;
        }
        return detail(id);
    }

    /**
     * ADR-098 修订「等待委外判定期间先锁住」：本单还有待委外判定的回厂短交时, 不许人工改量。
     * 只挂公开入口——接受损耗结案走的是 changeQtyForShortDelivery, 那条路已经把本行案件落成
     * 终态再改量, 而同单其它行可能仍在待判定, 守卫若下沉到 changeQtyInternal 会把结案自己拦死。
     */
    /**
     * ADR-098 修订：本单待委外判定的回厂短交(红档 + 分批逾期)。有就返回锁定提示, 没有返回 null。
     * 口径与委外判定页「待判定」段、任务中心红徽章完全一致, 判定完成即自动消失。
     */
    private OrderDetail.ShortDeliveryHold shortDeliveryHold(UUID orderId) {
        if (em == null || orderId == null) return null;
        var query = em.createNativeQuery("""
                SELECT c.id, c.goods_name_snapshot, c.goods_code_snapshot,
                       c.shortfall_qty, c.ordered_qty, c.delivered_qty,
                       (c.status = 'WAITING_MORE') AS overdue_wait,
                       unit.name
                FROM subcontract_short_delivery_cases c
                LEFT JOIN units unit ON unit.id = c.unit_id
                WHERE c.order_id = :id
                  AND ((c.status = 'PENDING_OWNER'
                        AND c.severity IN ('SEVERE', 'BELOW_FLOOR'))
                       OR (c.status = 'WAITING_MORE'
                           AND c.severity <> 'WITHIN_TOLERANCE'
                           AND c.expected_complete_by < CURRENT_DATE))
                ORDER BY c.detected_at
                """);
        // 纯单测用 mock EntityManager, createNativeQuery 会返回 null; 锁定块是只读附加信息,
        // 取不到就当没有, 不要让它把主流程 NPE 掉。真实拦截在 changeQty 与入库闸上, 不靠这里。
        if (query == null) return null;
        @SuppressWarnings("unchecked")
        List<Object[]> rows = query.setParameter("id", orderId).getResultList();
        if (rows == null || rows.isEmpty()) return null;
        Object[] first = rows.getFirst();
        String unit = first[7] == null ? "" : " " + first[7];
        String goods = String.valueOf(first[1]) + (first[2] == null ? "" : " " + first[2]);
        boolean overdue = Boolean.TRUE.equals(first[6]);
        String more = rows.size() > 1 ? "等 " + rows.size() + " 项" : "";
        String summary = "「" + goods + "」" + more + "回厂比订货少 "
                + plainNumber(first[3]) + unit
                + "(订 " + plainNumber(first[4]) + unit
                + ", 累计到 " + plainNumber(first[5]) + unit + ")。"
                + (overdue ? "此前判定的分批到货已过预计到齐日, 需要重新判定。" : "")
                + "仓库已登记并通知委外, 正等委外判定是分批到货继续等还是接受损耗结案; "
                + "判定完成前这批货先不入库(已按先入库后质检上架的货先不转为可用库存, 判定后系统自动转入), "
                + "本单也不改量。";
        return new OrderDetail.ShortDeliveryHold(
                (UUID) first[0], rows.size(), summary, overdue);
    }

    private static String plainNumber(Object value) {
        if (value == null) return "0";
        return new java.math.BigDecimal(value.toString()).stripTrailingZeros().toPlainString();
    }

    private void requireNoPendingShortDeliveryJudgement(UUID id) {
        Boolean pending = (Boolean) em.createNativeQuery("""
                SELECT EXISTS(
                    SELECT 1
                    FROM subcontract_short_delivery_cases c
                    WHERE c.order_id = :id
                      AND ((c.status = 'PENDING_OWNER'
                            AND c.severity IN ('SEVERE', 'BELOW_FLOOR'))
                           OR (c.status = 'WAITING_MORE'
                               AND c.severity <> 'WITHIN_TOLERANCE'
                               AND c.expected_complete_by < CURRENT_DATE)))
                """).setParameter("id", id).getSingleResult();
        if (Boolean.TRUE.equals(pending)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "本单回厂数量少于订货量, 已通知委外判定是分批到货还是接受损耗; "
                            + "判定完成前先锁住不改量。接受损耗结案时系统会自动把订货量改成实际回厂量。");
        }
    }

    private void requireNoPendingApprovalCase(UUID id) {
        Boolean pending = (Boolean) em.createNativeQuery("""
                SELECT EXISTS(
                    SELECT 1
                    FROM procurement_order_approval_cases
                    WHERE order_type = 'SUBCONTRACT' AND order_id = :id
                      AND status = 'PENDING')
                """).setParameter("id", id).getSingleResult();
        if (Boolean.TRUE.equals(pending)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "订货单已在财务复核中，复核办结后才可再次改量");
        }
    }

    private void recalcOrderTotals(
            SubcontractOrder order, List<SubcontractOrderItem> items) {
        BigDecimal original = BigDecimal.ZERO;
        BigDecimal local = BigDecimal.ZERO;
        for (SubcontractOrderItem item : items) {
            original = original.add(item.getAmountOriginal() == null
                    ? BigDecimal.ZERO : item.getAmountOriginal());
            local = local.add(item.getAmountLocal() == null
                    ? BigDecimal.ZERO : item.getAmountLocal());
        }
        order.setTotalOriginal(original);
        order.setTotalLocal(local);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void applyFinanceApproval(UUID id, UUID approverEmployeeId) {
        SubcontractOrder order = requireOrderForUpdate(id);
        if (order.getStatus() == null || order.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.CONFLICT, "订货单已不再是待生效草稿");
        }
        references.requireSelectableSupplier(order.getSupplierId());
        List<SubcontractOrderItem> items =
                itemRepo.findByOrderIdOrderByLineNoAsc(id);
        // ADR-143 §二.3：批准时再兜底检查一次(送审后 BOM 可能被改到没有可发外直属物料)；
        // 缺的转研发时登记订货单制单人等结果，而不是财务审核人。
        requireDrawableBom(order, items, order.getMakerId());
        // ADR-156：批准即锁定当天委外价, 物料必须仍然齐套。
        requireKit(id, "批准", KIT_HINT_REVIEW);
        captureGoodsSnapshots(
                items,
                SubcontractGoodsSnapshot.APPLICATION_ITEM_AT_APPROVAL,
                SubcontractGoodsSnapshot.MASTER_AT_APPROVAL,
                OffsetDateTime.now());
        productionSupply.onSubcontractOrderApproved(id);
        // V463：ordered_qty 按来源分配份额回写（合并行的数量分摊到各申请行）；
        // 手工行（无来源且无主锚点）不回写。
        Map<UUID, List<Object[]>> sourceRows = orderItemSources(
                items.stream().map(SubcontractOrderItem::getId).toList());
        java.util.Set<UUID> closedApplicationItems = new java.util.LinkedHashSet<>();
        for (SubcontractOrderItem item : items) {
            List<Object[]> sources = sourceRows.getOrDefault(item.getId(), List.of());
            if (sources.isEmpty()) {
                if (item.getApplicationItemId() == null) {
                    continue; // 手工行无申请来源，不回写 ordered_qty
                }
                sources = List.<Object[]>of(new Object[]{
                        item.getId(), item.getApplicationItemId(), null, item.getQty()});
            }
            for (Object[] source : sources) {
                em.createNativeQuery("""
                        UPDATE subcontract_application_items
                        SET ordered_qty = COALESCE(ordered_qty, 0) + :qty
                        WHERE id = :id
                        """)
                        .setParameter("qty", (BigDecimal) source[3])
                        .setParameter("id", (UUID) source[1])
                        .executeUpdate();
                closedApplicationItems.add((UUID) source[1]);
            }
        }
        closedApplicationItems.forEach(this::recalcApplicationClosed);
        order.setStatus(STATUS_APPROVED);
        order.setApproverId(approverEmployeeId);
        orderRepo.save(order);
        orderRepo.flush();
        publicSupplyCapture.afterOrderApproved(
                PreplanPublicSupplyCapturePort.SUBCONTRACT, id);
        // ADR-143：按批准时可发外的直属物料冻结领料计划行(物料、颜色、单耗)；每条明细都必须有
        // (缺 BOM 已在上面拒绝，§二.3)。不生成出仓草稿，由委外人员按齐套情况提交领料。
        materialPlanService.createPlanOnApproval(id);
    }

    /** 红冲：1→-1。反向回写 ordered_qty + 重算申请 is_closed（无 ArAp 无库存）。 */
    @Transactional
    @PreAuthorize("hasAuthority('subcontract_order:reverse')")
    public OrderDetail reverse(UUID id) {
        tx.bind();
        var mutationGuard=mutationLocks.order(orderType(),id);
        SubcontractOrder r = requireOrderForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外订货单");
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        mutationGuard.verifyUnchanged();
        reviewCancellation.cancelUnclaimedPending(orderType(),id,"ORDER_REVERSED");
        List<SubcontractOrderItem> items = itemRepo.findByOrderIdOrderByLineNoAsc(id);
        if (items.stream().anyMatch(it ->
                positive(it.getReceivedQty())
                        || positive(it.getReturnedQty()))) {
            throw new ApiException(
                    ErrorCode.BUSINESS,
                    "委外订货已有进仓/成品退货记录，请先红冲下游单据");
        }
        if (hasApprovedMaterialActivity(
                items.stream().map(SubcontractOrderItem::getId).toList())) {
            throw new ApiException(
                    ErrorCode.BUSINESS,
                    "委外订货仍有已审核发料/退料/损耗单，请先红冲下游单据");
        }
        // V463：红冲按来源分配份额对称扣回（与审批回写同口径）。
        Map<UUID, List<Object[]>> reverseSources = orderItemSources(
                items.stream().map(SubcontractOrderItem::getId).toList());
        sourceIntegrity.lockSubcontractApplicationItemsForReversal(
                reverseSources.values().stream().flatMap(List::stream)
                        .map(row -> (UUID) row[1]).distinct().toList());
        productionSupply.onSubcontractOrderReversed(id);
        java.util.Set<UUID> reopenedApplicationItems = new java.util.LinkedHashSet<>();
        for (SubcontractOrderItem it : items) {
            List<Object[]> sources = reverseSources.getOrDefault(it.getId(), List.of());
            if (sources.isEmpty()) {
                if (it.getApplicationItemId() == null) {
                    continue;
                }
                sources = List.<Object[]>of(new Object[]{
                        it.getId(), it.getApplicationItemId(), null, it.getQty()});
            }
            for (Object[] source : sources) {
                em.createNativeQuery(
                        "UPDATE subcontract_application_items SET ordered_qty = COALESCE(ordered_qty,0) - :q WHERE id = :id")
                        .setParameter("q", (BigDecimal) source[3])
                        .setParameter("id", (UUID) source[1])
                        .executeUpdate();
                reopenedApplicationItems.add((UUID) source[1]);
            }
        }
        reopenedApplicationItems.forEach(this::recalcApplicationClosed);
        arrivalControl.cancelForOrderReversal(
                ProcurementArrivalControlPort.SUBCONTRACT, id);
        // 撤回未发出的领料草稿并释放预留 + 领料计划置 CANCELED（已审出仓由上方守卫先行拦截）。
        materialPlanService.cancelForOrderReversal(id);
        enqueueKitRecheck(id);
        // ADR-098：红冲守卫全部通过后, 开放的短交案件作废并撤回通知卡(同事务)。
        shortDeliveryHook(hooks -> hooks.cancelOpenCasesForOrder(id, "ORDER_REVERSED"));
        r.setStatus(STATUS_REVERSED);
        orderRepo.save(r);
        orderRepo.flush();
        publicSupplyCapture.afterOrderReversed(
                PreplanPublicSupplyCapturePort.SUBCONTRACT, id);
        return assembleDetail(r);
    }

    /**
     * ADR-143 §二.3：委外件必须先有可发外的直属物料(BOM，唯一判定 {@code fn_subcontract_draw_edges})
     * 才能提交财务或获批；手工草稿可以先保存。缺 BOM 的委外件逐个转工程研发部完善(独立事务立即提交，
     * 随后的 409 不撤销；[reporterEmployeeId] 进等待名单，为空时取当前操作人)，再逐个点名拒绝。
     */
    private void requireDrawableBom(SubcontractOrder order, List<SubcontractOrderItem> items,
                                    UUID reporterEmployeeId) {
        List<Object[]> missing = goodsWithoutDrawableBom(
                items.stream().map(SubcontractOrderItem::getGoodsId).toList());
        if (missing.isEmpty()) return;
        for (Object[] row : missing) {
            forwardBomGap((UUID) row[0], com.uten.imp.application.port.RdBomGapPort.SOURCE_SUBCONTRACT_ORDER,
                    order.getId(), order.getBillNo(), goodsLabel(row), reporterEmployeeId);
        }
        throw bomMissing(missing);
    }

    /** 委外申请分解的订货行：申请行缺 BOM 时不能生成订货单(ADR-143 §二.3)，同样先转研发。 */
    private void requireDrawableBomForApplicationLines(OrderSaveRequest req) {
        if (req == null || req.getItems() == null) return;
        Map<UUID, UUID> applicationItemByGoods = new LinkedHashMap<>();
        for (OrderItemLine line : req.getItems()) {
            if (line == null || line.getGoodsId() == null || line.resolvedApplicationItemIds().isEmpty()) continue;
            applicationItemByGoods.putIfAbsent(line.getGoodsId(), line.resolvedApplicationItemIds().getFirst());
        }
        List<Object[]> missing = goodsWithoutDrawableBom(List.copyOf(applicationItemByGoods.keySet()));
        if (missing.isEmpty()) return;
        for (Object[] row : missing) {
            List<Object[]> application = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT application.id, application.bill_no
                    FROM subcontract_application_items item
                    JOIN subcontract_applications application ON application.id = item.application_id
                    WHERE item.id = :itemId
                    """).setParameter("itemId", applicationItemByGoods.get((UUID) row[0])));
            forwardBomGap((UUID) row[0], com.uten.imp.application.port.RdBomGapPort.SOURCE_SUBCONTRACT_APPLICATION,
                    application.isEmpty() ? null : (UUID) application.getFirst()[0],
                    application.isEmpty() ? null : Objects.toString(application.getFirst()[1], null),
                    goodsLabel(row), null);
        }
        throw bomMissing(missing);
    }

    /** [goodsId, 名称, 编号]：这些委外件里没有任何可发外直属物料的(按编号排序)。 */
    private List<Object[]> goodsWithoutDrawableBom(List<UUID> requestedGoodsIds) {
        List<UUID> goodsIds = requestedGoodsIds.stream().filter(Objects::nonNull).distinct().toList();
        if (goodsIds.isEmpty()) return List.of();
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT goods.id, COALESCE(goods.name, ''), COALESCE(goods.code, '')
                FROM goods
                WHERE goods.id IN (:goodsIds)
                  AND NOT EXISTS (SELECT 1 FROM fn_subcontract_draw_edges(goods.id))
                ORDER BY goods.code, goods.id
                """).setParameter("goodsIds", goodsIds));
    }

    private void forwardBomGap(UUID goodsId, String sourceDocType, UUID sourceDocId, String sourceDocNo,
                               String goodsLabel, UUID reporterEmployeeId) {
        if (rdBomGaps == null) return;
        boolean order = com.uten.imp.application.port.RdBomGapPort.SOURCE_SUBCONTRACT_ORDER.equals(sourceDocType);
        String source = sourceDocNo == null || sourceDocNo.isBlank() ? "" : sourceDocNo + " ";
        rdBomGaps.forwardBomGap(goodsId, sourceDocType, sourceDocId, sourceDocNo,
                (order ? "委外订货单 " : "委外申请 ") + source + "里的委外件 " + goodsLabel
                        + " 还没有维护 BOM(直属物料)，" + (order ? "不能提交财务" : "不能生成订货单"),
                reporterEmployeeId);
    }

    private static String goodsLabel(Object[] row) {
        return com.uten.imp.application.port.RdBomGapPort.goodsLabel(
                Objects.toString(row[1], ""), Objects.toString(row[2], ""));
    }

    private static ApiException bomMissing(List<Object[]> missing) {
        return new ApiException(ErrorCode.CONFLICT,
                com.uten.imp.application.port.RdBomGapPort.subcontractBomMissingMessage(
                        missing.stream().map(SubcontractOrderService::goodsLabel).toList(), false));
    }

    private void normalizePersistedUnits(
            List<SubcontractOrderItem> items) {
        for (SubcontractOrderItem item : items) {
            if (item.getUnitRate() == null) {
                item.setUnitRate(BigDecimal.ONE);
            }
            if (item.getUnitRate().signum() <= 0) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "委外订货单位换算率必须大于0");
            }
        }
        itemRepo.saveAll(items);
    }

    private void lockAndValidateSourcesIncludingPending(
            SubcontractOrder order, List<SubcontractOrderItem> items) {
        // V463：来源校验按「来源分配行」逐条进行（合并行的每个来源申请行都必须
        // 已下达、委外商一致且维度一致）；手工行（无来源）不参与申请来源校验。
        Map<UUID, List<Object[]>> sourceRows = orderItemSources(
                items.stream().map(SubcontractOrderItem::getId).toList());
        record SourceRef(SubcontractOrderItem item, UUID applicationItemId, BigDecimal qty) {}
        List<SourceRef> refs = new ArrayList<>();
        for (SubcontractOrderItem item : items) {
            List<Object[]> sources = sourceRows.getOrDefault(item.getId(), List.of());
            if (sources.isEmpty()) {
                if (item.getApplicationItemId() == null) {
                    continue; // 手工行无申请来源
                }
                sources = List.<Object[]>of(new Object[]{
                        item.getId(), item.getApplicationItemId(), null, item.getQty()});
            }
            for (Object[] source : sources) {
                refs.add(new SourceRef(item, (UUID) source[1], (BigDecimal) source[3]));
            }
        }
        if (refs.isEmpty()) {
            return;
        }
        List<UUID> sourceIds = refs.stream()
                .map(SourceRef::applicationItemId).distinct().sorted().toList();
        List<?> lockedSources = em.createNativeQuery("""
                        SELECT source.id
                        FROM subcontract_application_items source
                        JOIN subcontract_applications application
                          ON application.id = source.application_id
                        WHERE source.id IN (:sourceIds)
                          AND source.is_deleted = FALSE
                          AND application.is_deleted = FALSE
                        ORDER BY source.id
                        FOR UPDATE OF source, application
                        """)
                .setParameter("sourceIds", sourceIds)
                .getResultList();
        if (lockedSources.size() != sourceIds.size()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "委外申请来源已变化，请刷新后重试");
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT source.id,
                               application.supplier_id,
                               source.goods_id,
                               source.color_id,
                               source.unit_id,
                               COALESCE(source.unit_rate, 1),
                               application.status
                        FROM subcontract_application_items source
                        JOIN subcontract_applications application
                          ON application.id = source.application_id
                        WHERE source.id IN (:sourceIds)
                          AND source.is_deleted = FALSE
                          AND application.is_deleted = FALSE
                        ORDER BY source.id
                        FOR UPDATE OF source, application
                        """)
                        .setParameter("sourceIds", sourceIds));
        if (rows.size() != sourceIds.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "委外申请来源已变化，请刷新后重试");
        }
        Map<UUID, Object[]> bySource = rows.stream()
                .collect(Collectors.toMap(row -> (UUID) row[0], row -> row));
        for (SourceRef ref : refs) {
            Object[] source = bySource.get(ref.applicationItemId());
            if (source == null
                    || !(source[6] instanceof Number status)
                    || status.shortValue() != STATUS_APPROVED) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "委外订货只能关联已下达的委外申请");
            }
            UUID sourceSupplier = (UUID) source[1];
            if (sourceSupplier != null
                    && !sourceSupplier.equals(order.getSupplierId())) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "委外商与来源申请单不一致");
            }
            if (!Objects.equals(ref.item().getGoodsId(), source[2])
                    || !Objects.equals(ref.item().getColorId(), source[3])
                    || !Objects.equals(ref.item().getUnitId(), source[4])
                    || !sameDecimal(ref.item().getUnitRate(), decimal(source[5]))) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "委外订货明细与来源申请明细不一致");
            }
        }
        // 2026-09 起订货允许超过申请剩余量（超委外备货是业务口径）：不再校验
        // ordered + 待审 + 本次 <= 申请量；ordered_qty 超出时剩余量为负、申请照常结案。
        // 来源锁定（FOR UPDATE）与已下达/委外商一致/维度一致校验保留。
    }

    private void requireActiveSettlementMethod(UUID settlementMethodId, String subject) {
        if (settlementMethodId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, subject + "必须选择结算方式");
        }
        long count = ((Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM settlement_methods
                WHERE id=:id AND status='使用' AND COALESCE(is_deleted,FALSE)=FALSE
                """).setParameter("id", settlementMethodId).getSingleResult()).longValue();
        if (count != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    subject + "结算方式不存在、已停用或未经财务核验");
        }
    }

    private static void requireFinanceCommercialAuthority(
            SubcontractOrder order, List<SubcontractOrderItem> items) {
        BigDecimal rate = order.getExchangeRate();
        BigDecimal totalOriginal = BigDecimal.ZERO;
        BigDecimal totalLocal = BigDecimal.ZERO;
        for (SubcontractOrderItem item : items) {
            if (item.getQty() == null || item.getQty().signum() <= 0
                    || item.getPrice() == null || item.getPrice().signum() < 0
                    || item.getAmountOriginal() == null
                    || item.getAmountOriginal().signum() < 0
                    || item.getAmountLocal() == null
                    || item.getAmountLocal().signum() < 0) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "委外订货数量、单价和金额必须完整且不能为负");
            }
            BigDecimal expectedOriginal = com.uten.imp.common.columns.ExtraColumnCalculator.apply(
                    MoneyPolicy.orderBaseAmount(item.getQty(), item.getPrice(), item.getTotalAmountInput()), item.getExtraColumns());
            if (item.getTotalAmountInput() != null
                    && item.getPrice().compareTo(MoneyPolicy.referenceUnitPrice(item.getTotalAmountInput(), item.getQty())) != 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "参考单价与总金额、数量不一致");
            }
            BigDecimal expectedLocal = MoneyPolicy.local(expectedOriginal, rate);
            if (money(item.getAmountOriginal()).compareTo(expectedOriginal) != 0
                    || money(item.getAmountLocal()).compareTo(expectedLocal) != 0) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "委外订货金额与数量、单价或汇率不一致");
            }
            totalOriginal = totalOriginal.add(expectedOriginal);
            totalLocal = totalLocal.add(expectedLocal);
        }
        if (order.getTotalOriginal() == null
                || order.getTotalLocal() == null
                || money(order.getTotalOriginal()).compareTo(money(totalOriginal)) != 0
                || money(order.getTotalLocal()).compareTo(money(totalLocal)) != 0) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "委外订货表头金额与明细汇总不一致");
        }
    }

    private OrderSnapshot snapshot(
            SubcontractOrder order, List<SubcontractOrderItem> items) {
        return new OrderSnapshot(
                orderType(),
                order.getId(),
                order.getBillNo(),
                order.getBillDate(),
                order.getSupplierId(),
                order.getWarehouseId(),
                order.getCurrencyId(),
                order.getExchangeRate(),
                order.getSettlementMethodId(),
                order.getTaxRate(),
                order.getPurchaserId(),
                order.getMakerId(),
                order.getDeliverDate(),
                order.getTotalOriginal(),
                order.getTotalLocal(),
                items.stream()
                        .map(item -> new ItemSnapshot(
                                item.getId(),
                                item.getLineNo(),
                                item.getApplicationItemId(),
                                item.getGoodsId(),
                                item.getColorId(),
                                item.getUnitId(),
                                item.getUnitRate(),
                                item.getQty(),
                                item.getPrice(),
                                item.getAmountOriginal(),
                                item.getAmountLocal(),
                                item.getDeliverDate(), item.getTotalAmountInput()))
                        .toList());
    }

    private static BigDecimal money(BigDecimal value) {
        return com.uten.imp.common.util.FinancialExactAmount.canonicalMoney(value,"委外订货金额");
    }

    private static BigDecimal decimal(Object value) {
        return value == null
                ? BigDecimal.ZERO
                : value instanceof BigDecimal decimal
                        ? decimal
                        : new BigDecimal(value.toString());
    }

    private static boolean sameDecimal(
            BigDecimal left, BigDecimal right) {
        return left == null ? right == null : left.compareTo(right) == 0;
    }

    private static boolean positive(BigDecimal value) {
        return value != null && value.signum() > 0;
    }

    /**
     * 子件活动必须从子件单据判断，不能再依赖成品行上的 legacy 汇总值。
     * 调用方已持有订货头写锁；下游审批的来源校验也会锁该订货，避免并发穿透。
     */
    private boolean hasApprovedMaterialActivity(List<UUID> orderItemIds) {
        if (orderItemIds.isEmpty()) {
            return false;
        }
        Object active = em.createNativeQuery("""
                        SELECT (
                            EXISTS (
                                SELECT 1
                                FROM subcontract_material_issue_items issue_item
                                JOIN subcontract_material_issues issue
                                  ON issue.id = issue_item.issue_id
                                WHERE issue_item.order_item_id IN (:orderItemIds)
                                  AND COALESCE(issue_item.is_deleted, FALSE) = FALSE
                                  AND COALESCE(issue.is_deleted, FALSE) = FALSE
                                  AND issue.status = 1
                            )
                            OR EXISTS (
                                SELECT 1
                                FROM subcontract_material_return_items return_item
                                JOIN subcontract_material_returns material_return
                                  ON material_return.id = return_item.material_return_id
                                WHERE return_item.order_item_id IN (:orderItemIds)
                                  AND COALESCE(return_item.is_deleted, FALSE) = FALSE
                                  AND COALESCE(material_return.is_deleted, FALSE) = FALSE
                                  AND material_return.status = 1
                            )
                            OR EXISTS (
                                SELECT 1
                                FROM subcontract_waste_items waste_item
                                JOIN subcontract_wastes waste
                                  ON waste.id = waste_item.waste_id
                                JOIN subcontract_material_issue_items issue_item
                                  ON issue_item.id = waste_item.material_issue_item_id
                                WHERE issue_item.order_item_id IN (:orderItemIds)
                                  AND COALESCE(waste_item.is_deleted, FALSE) = FALSE
                                  AND COALESCE(waste.is_deleted, FALSE) = FALSE
                                  AND COALESCE(issue_item.is_deleted, FALSE) = FALSE
                                  AND waste.status = 1
                            )
                        )
                        """)
                .setParameter("orderItemIds", orderItemIds)
                .getSingleResult();
        return Boolean.TRUE.equals(active);
    }

    /** 重算申请单结案：所有明细 qty - ordered_qty ≤ 0 → is_closed=true。 */
    private void recalcApplicationClosed(UUID appItemId) {
        em.createNativeQuery("""
                UPDATE subcontract_applications a SET is_closed = (
                    SELECT COALESCE(bool_and(
                        COALESCE(i.qty,0) - COALESCE(i.ordered_qty,0) <= 0
                    ), true)
                    FROM subcontract_application_items i
                    WHERE i.application_id = a.id AND COALESCE(i.is_deleted, false) = false
                ) WHERE a.id = (SELECT application_id FROM subcontract_application_items WHERE id = :iid)
                """).setParameter("iid", appItemId).executeUpdate();
    }

    private void applyHeader(OrderSaveRequest req, SubcontractOrder r) {
        if (r.getSupplierId() == null
                || !java.util.Objects.equals(r.getSupplierId(), req.getSupplierId())) {
            references.requireSelectableSupplier(req.getSupplierId());
        }
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SUB_ORDER));
        }
        r.setBillDate(req.getBillDate());
        r.setSupplierId(req.getSupplierId());
        // 订货仓库只作单据记录、可不填(ADR-143)：领料按物料所在仓出、回厂按到货登记仓收。
        // 填了仍须是具体叶子仓(V476 运营红线)。
        if (warehouseScopes != null) {
            warehouseScopes.require(r.getWarehouseId(), req.getWarehouseId(), "仓库", WarehouseUse.GOOD_IN);
        }
        r.setWarehouseId(req.getWarehouseId());
        r.setCurrencyId(req.getCurrencyId());
        r.setExchangeRate(req.getExchangeRate()==null?null:com.uten.imp.common.util.FinancialExactAmount.rate(req.getExchangeRate(),"委外汇率"));
        if (req.getSettlementMethodId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "委外订货必须选择结算方式");
        }
        var settlement = com.uten.imp.common.util.SettlementMethodReferenceResolver.resolve(
                em, req.getSettlementMethodId(), null, "结帐方式");
        if (settlement == null) throw new ApiException(ErrorCode.CONFLICT, "委外订货结算方式无效");
        r.setSettlementMethodId(settlement.id());
        r.setTaxRate(req.getTaxRate());
        r.setPurchaserId(req.getPurchaserId());
        r.setDeliverDate(req.getDeliverDate());
        r.setRemark(req.getRemark());
    }

    static void requireRowsMatchHeaderSupplier(OrderSaveRequest req) {
        UUID header = req.getSupplierId();
        if (req.getItems() == null) return;
        for (OrderItemLine line : req.getItems()) {
            if (line.getSupplierId() != null
                    && !java.util.Objects.equals(line.getSupplierId(), header)) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "既有委外订货单必须保持一单一商；多委外商新单请使用批量拆单接口");
            }
        }
    }

    /**
     * 单张创建/编辑：行级商业条款（若携带）必须与表头一致——一张订货单只落一套条款
     * （保存到单头）。行值为空表示回落表头（合法）；行级多条款拆单只发生在批量创建
     * （{@link #groupByCommercial}）。
     */
    static void requireRowsMatchHeaderCommercial(OrderSaveRequest req) {
        if (req.getItems() == null) return;
        for (OrderItemLine line : req.getItems()) {
            boolean carriesCommercial = line.getSettlementMethodId() != null
                    || line.getCurrencyId() != null
                    || line.getExchangeRate() != null
                    || line.getTaxRate() != null;
            if (!carriesCommercial) continue;
            boolean same = matchesHeader(line.getSettlementMethodId(), req.getSettlementMethodId())
                    && matchesHeader(line.getCurrencyId(), req.getCurrencyId())
                    && matchesHeaderDecimal(line.getExchangeRate(), req.getExchangeRate())
                    && matchesHeaderDecimal(line.getTaxRate(), req.getTaxRate());
            if (!same) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "既有委外订货单必须保持一套商业条款；多条款新单请使用批量拆单接口");
            }
        }
    }

    private static boolean matchesHeader(UUID lineValue, UUID headerValue) {
        return lineValue == null || java.util.Objects.equals(lineValue, headerValue);
    }

    private static boolean matchesHeaderDecimal(BigDecimal lineValue, BigDecimal headerValue) {
        return lineValue == null
                || (headerValue != null && lineValue.compareTo(headerValue) == 0);
    }

    private List<OrderItemDto> saveItems(SubcontractOrder r, List<OrderItemLine> lines) {
        return saveItems(r,lines,Map.of(), Map.of());
    }

    /** Preserve terms independently of row replacement when quantities or sources change. */
    static Map<OrderItemLine, List<com.uten.imp.common.columns.ExtraColumnSnapshot>> previousColumns(
            List<OrderItemLine> requested, List<SubcontractOrderItem> stored) {
        Map<OrderItemLine, List<com.uten.imp.common.columns.ExtraColumnSnapshot>> snapshots = new java.util.IdentityHashMap<>();
        List<SubcontractOrderItem> remaining = new ArrayList<>(stored);
        for (OrderItemLine line : requested) {
            List<SubcontractOrderItem> candidates = remaining.stream().filter(old -> line.getId() != null
                    ? line.getId().equals(old.getId())
                    : Objects.equals(line.getGoodsId(), old.getGoodsId())
                      && Objects.equals(line.getColorId(), old.getColorId())
                      && Objects.equals(line.getUnitId(), old.getUnitId())
                      && Objects.equals(line.getApplicationItemId(), old.getApplicationItemId())).toList();
            if (line.getId() != null && candidates.isEmpty())
                throw new ApiException(ErrorCode.CONFLICT, "委外明细不存在、重复或不属于本订单");
            SubcontractOrderItem match = candidates.stream()
                    .filter(old -> line.getLineNo() != null && line.getLineNo().equals(old.getLineNo()))
                    .findFirst().orElse(candidates.isEmpty() ? null : candidates.getFirst());
            if (line.getId() == null && match != null && candidates.size() > 1
                    && candidates.stream().map(SubcontractOrderItem::getExtraColumns).distinct().count() > 1)
                throw new ApiException(ErrorCode.CONFLICT, "相同货品存在不同扩展条款，请刷新页面后按明细编号保存");
            if (match != null) {
                snapshots.put(line, match.getExtraColumns());
                remaining.remove(match);
            }
        }
        return snapshots;
    }

    private List<OrderItemDto> saveItems(SubcontractOrder r, List<OrderItemLine> lines,Map<OrderItemLine,SubcontractOrderItem> retained,
            Map<OrderItemLine, List<com.uten.imp.common.columns.ExtraColumnSnapshot>> previousColumns) {
        List<OrderItemDto> out = new ArrayList<>(lines.size());
        // V463 同货品合并行：行数量按各申请行剩余量 FIFO 拆分到 sources
        //（末位来源吸收超额）；application_item_id 落首来源（主锚点）。
        Map<OrderItemLine, List<SourceSplit>> splits = planSourceSplits(lines);
        // V304：applicationItemId 允许为空 = 委外自建手工行（无申请来源）；
        // 快照回落货品主档（preferred 对空来源行自动走 master）。
        Map<UUID, SubcontractGoodsSnapshot> upstream =
                SubcontractGoodsSnapshot.fromApplicationItems(
                        em,
                        splits.values().stream().flatMap(List::stream)
                                .map(SourceSplit::applicationItemId).distinct().toList(),
                        SubcontractGoodsSnapshot.APPLICATION_ITEM_AT_SAVE);
        Map<UUID, SubcontractGoodsSnapshot> master =
                SubcontractGoodsSnapshot.fromMaster(
                        em,
                        lines.stream().map(OrderItemLine::getGoodsId).toList(),
                        SubcontractGoodsSnapshot.MASTER_AT_SAVE);
        UUID actorId = currentUser.requireId();
        // 行金额按单价乘数量或用户约定总金额派生；本币仍由服务端按汇率计算。
        // 单价和约定总金额都缺省时金额为空；汇率缺省则本币为空。
        BigDecimal headerRate = r.getExchangeRate();
        int autoLine = 1;
        for (OrderItemLine l : lines) {
            List<SourceSplit> lineSplits = splits.getOrDefault(l, List.of());
            UUID primarySource = lineSplits.isEmpty()
                    ? null : lineSplits.getFirst().applicationItemId();
            SubcontractOrderItem it = retained.getOrDefault(l,new SubcontractOrderItem());
            it.setOrderId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : autoLine);
            it.setGoodsId(l.getGoodsId());
            applyGoodsSnapshot(
                    it,
                    SubcontractGoodsSnapshot.preferred(
                            upstream,
                            primarySource,
                            master,
                            l.getGoodsId(),
                            "委外订单明细"),
                    null);
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            // 缺省换算率入库即写 1：若留 null，首次 submit-finance 时 normalizePersistedUnits
            // 才在内存补 ONE（scale 0），落库 numeric(18,6) 后重读变 scale 6，审批快照
            // 哈希失配导致 approve/reject 双 409（单据永久卡死）。
            it.setUnitRate(l.getUnitRate() == null ? BigDecimal.ONE : l.getUnitRate());
            it.setQty(l.getQty());
            BigDecimal totalInput = MoneyPolicy.totalAmountInput(l.getTotalAmountInput());
            BigDecimal price = totalInput == null
                    ? (l.getPrice() == null ? null : com.uten.imp.common.util.FinancialExactAmount.unitPrice(l.getPrice(), "单价"))
                    : MoneyPolicy.referenceUnitPrice(totalInput, l.getQty());
            it.setTotalAmountInput(totalInput);
            it.setPrice(price);
            it.setExtraColumns(com.uten.imp.common.columns.BusinessColumnService.resolveForSave(businessColumns, "subcontract_order",
                    l.getExtraColumns(), previousColumns.getOrDefault(l, it.getExtraColumns()), subcontractPriceMasked()));
            BigDecimal original = com.uten.imp.common.columns.ExtraColumnCalculator.apply(
                    MoneyPolicy.orderBaseAmount(l.getQty(), price, totalInput), it.getExtraColumns());
            MoneyPolicy.LineAmounts amounts = new MoneyPolicy.LineAmounts(original,
                    original == null || headerRate == null ? null : MoneyPolicy.local(original, headerRate));
            it.setAmountOriginal(amounts.original());
            it.setAmountLocal(amounts.local());
            it.setApplicationItemId(primarySource);
            it.setDeliverDate(l.getDeliverDate());
            it.setWeight(l.getWeight());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            // ADR-098 允许损耗：保存即冻结到本行; 主档记忆由 masterDefaultsSync 回写。
            it.setAllowedLossPct(l.getAllowedLossPct());
            itemRepo.save(it);
            itemRepo.flush();
            int sourceLine = 1;
            for (SourceSplit split : lineSplits) {
                em.createNativeQuery("""
                        INSERT INTO subcontract_order_item_sources (
                            order_item_id, application_item_id, alloc_qty, line_no, created_by)
                        VALUES (:orderItemId, :applicationItemId, :allocQty, :lineNo, :actorId)
                        """)
                        .setParameter("orderItemId", it.getId())
                        .setParameter("applicationItemId", split.applicationItemId())
                        .setParameter("allocQty", split.allocQty())
                        .setParameter("lineNo", sourceLine++)
                        .setParameter("actorId", actorId)
                        .executeUpdate();
            }
            out.add(toItemDto(it, List.of()));
            autoLine++;
        }
        return out;
    }

    /** V463 合并行来源分配结果：applicationItemId + 归属本行的数量份额。 */
    record SourceSplit(UUID applicationItemId, BigDecimal allocQty) {}

    /**
     * 同货品合并行的来源 FIFO 拆分（采购侧对称）：按各申请行当前剩余量
     *（qty - ordered_qty - 待财务审核订货占用）在「需求日期升序、id 升序」
     * 稳定顺序上先到先得，末位来源吸收超额；份额为 0 的来源丢弃。
     * 手工行（无来源）与单来源行退化为 alloc = 行数量（与历史单锚一致）。
     */
    private Map<OrderItemLine, List<SourceSplit>> planSourceSplits(List<OrderItemLine> lines) {
        List<UUID> allIds = lines.stream()
                .flatMap(line -> line.resolvedApplicationItemIds().stream())
                .distinct().toList();
        Map<OrderItemLine, List<SourceSplit>> result = new java.util.LinkedHashMap<>();
        if (allIds.isEmpty()) {
            return result;
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT item.id,
                               GREATEST(COALESCE(item.qty, 0) - COALESCE(item.ordered_qty, 0)
                                        - COALESCE(pending.pending_qty, 0), 0) AS remaining_qty
                        FROM subcontract_application_items item
                        JOIN subcontract_applications application
                          ON application.id = item.application_id
                        LEFT JOIN (
                            SELECT src.application_item_id,
                                   SUM(COALESCE(src.alloc_qty, 0)) AS pending_qty
                            FROM procurement_order_approval_cases approval
                            JOIN subcontract_orders so
                              ON approval.order_type = 'SUBCONTRACT'
                             AND approval.order_id = so.id
                             AND approval.status = 'PENDING'
                            JOIN subcontract_order_items oi ON oi.order_id = so.id
                            JOIN subcontract_order_item_sources src
                              ON src.order_item_id = oi.id
                            WHERE so.status = 0
                              AND so.is_deleted = FALSE
                              AND oi.is_deleted = FALSE
                              AND src.application_item_id IN (:ids)
                            GROUP BY src.application_item_id
                        ) pending ON pending.application_item_id = item.id
                        WHERE item.id IN (:ids)
                        ORDER BY CASE WHEN EXISTS (
                                     SELECT 1 FROM preplan_supply_actions action
                                     WHERE action.public_surplus_external_item_id = item.id
                                   ) THEN 1 ELSE 0 END,
                                 application.need_date NULLS LAST, item.id
                        """).setParameter("ids", allIds));
        Map<UUID, BigDecimal> remaining = new java.util.HashMap<>();
        List<UUID> stableOrder = new ArrayList<>();
        for (Object[] row : rows) {
            UUID id = (UUID) row[0];
            remaining.put(id, decimal(row[1]));
            stableOrder.add(id);
        }
        for (OrderItemLine line : lines) {
            List<UUID> resolved = line.resolvedApplicationItemIds();
            if (resolved.isEmpty()) {
                result.put(line, List.of());
                continue;
            }
            if (line.getQty() == null || line.getQty().signum() <= 0) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED, "委外订货明细数量必须大于 0");
            }
            List<UUID> ordered = resolved.stream()
                    .sorted(java.util.Comparator.comparing(
                            id -> stableOrder.contains(id)
                                    ? stableOrder.indexOf(id)
                                    : Integer.MAX_VALUE))
                    .toList();
            BigDecimal budget = line.getQty();
            List<SourceSplit> splits = new ArrayList<>();
            for (int index = 0; index < ordered.size(); index++) {
                UUID sourceId = ordered.get(index);
                boolean last = index == ordered.size() - 1;
                BigDecimal take = last
                        ? budget.max(BigDecimal.ZERO)
                        : budget.min(remaining.getOrDefault(sourceId, BigDecimal.ZERO))
                                .max(BigDecimal.ZERO);
                if (take.signum() <= 0) {
                    continue;
                }
                splits.add(new SourceSplit(sourceId, take));
                budget = budget.subtract(take);
                if (budget.signum() <= 0 && !last) {
                    break;
                }
            }
            if (splits.isEmpty()) {
                splits.add(new SourceSplit(resolved.getFirst(), line.getQty()));
            }
            result.put(line, splits);
        }
        return result;
    }

    private void captureGoodsSnapshots(
            List<SubcontractOrderItem> items,
            String upstreamSource,
            String masterSource,
            OffsetDateTime lockedAt) {
        Map<UUID, SubcontractGoodsSnapshot> upstream =
                SubcontractGoodsSnapshot.fromApplicationItems(
                        em,
                        items.stream().map(SubcontractOrderItem::getApplicationItemId).toList(),
                        upstreamSource);
        Map<UUID, SubcontractGoodsSnapshot> master =
                SubcontractGoodsSnapshot.fromMaster(
                        em,
                        items.stream().map(SubcontractOrderItem::getGoodsId).toList(),
                        masterSource);
        for (SubcontractOrderItem item : items) {
            SubcontractGoodsSnapshot snapshot = SubcontractGoodsSnapshot.preferred(
                    upstream,
                    item.getApplicationItemId(),
                    master,
                    item.getGoodsId(),
                    "委外订单明细");
            int updated = em.createNativeQuery("""
                    UPDATE subcontract_order_items
                    SET goods_code_snapshot = :code,
                        goods_name_snapshot = :name,
                        goods_snapshot_source = :source,
                        goods_snapshot_locked_at = :lockedAt
                    WHERE id = :id
                      AND goods_snapshot_locked_at IS NULL
                    """)
                    .setParameter("code", snapshot.code())
                    .setParameter("name", snapshot.name())
                    .setParameter("source", snapshot.source())
                    .setParameter("lockedAt", lockedAt)
                    .setParameter("id", item.getId())
                    .executeUpdate();
            if (updated != 1) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "委外订货明细货品快照已锁定或不存在，请刷新后重试");
            }
        }
    }

    private static void applyGoodsSnapshot(
            SubcontractOrderItem item,
            SubcontractGoodsSnapshot snapshot,
            OffsetDateTime lockedAt) {
        item.setGoodsCodeSnapshot(snapshot.code());
        item.setGoodsNameSnapshot(snapshot.name());
        item.setGoodsSnapshotSource(snapshot.source());
        item.setGoodsSnapshotLockedAt(lockedAt);
    }

    private void applyTotals(SubcontractOrder r, List<OrderItemDto> items) {
        BigDecimal local = items.stream()
                .map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream()
                .map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        r.setTotalLocal(local);
        r.setTotalOriginal(original);
        orderRepo.save(r);
    }

    private OrderListItem toList(
            SubcontractOrder order, FinanceApproval approval, boolean priceMasked) {
        return new OrderListItem(
                order.getId(),
                order.getBillNo(),
                order.getBillDate(),
                order.getSupplierId(),
                order.getWarehouseId(),
                priceMasked ? null : order.getSettlementMethodId(),
                priceMasked ? null : order.getTotalLocal(),
                order.getStatus(),
                order.isClosed(),
                order.isFulfill(),
                order.getLegacyId(),
                approval,
                priceMasked);
    }

    private OrderItemDto toItemDto(SubcontractOrderItem it) {
        return toItemDto(it, List.of());
    }

    /** V463：明细同时暴露全部来源申请（合并行多来源展示/编辑回显）。 */
    private OrderItemDto toItemDto(
            SubcontractOrderItem it,
            List<OrderItemDto.SourceApplicationDoc> sourceApplications) {
        OrderItemDto dto = new OrderItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getReceivedQty(), it.getReturnedQty(), it.getIssuedQty(),
                it.getMaterialReturnedQty(), it.getApplicationItemId(), it.getDeliverDate(),
                it.getWeight(), it.getSourceDocNo(), it.getRemark(),
                sourceApplications, it.getAllowedLossPct(), BigDecimal.ZERO, false);
        dto.setTotalAmountInput(it.getTotalAmountInput());
        dto.setExtraColumns(it.getExtraColumns());
        return dto;
    }

    private OrderCostItemDto toCostItemDto(SubcontractOrderCostItem c) {
        return new OrderCostItemDto(c.getId(), c.getBomLevel(), c.getParentCostItemId(), c.getOrderItemId(),
                c.getParentGoodsId(), c.getParentGoodsCodeSnapshot(), c.getParentGoodsNameSnapshot(),
                c.getParentGoodsSnapshotSource(), c.getParentGoodsSnapshotLockedAt(), c.getParentColorId(),
                c.getGoodsId(), c.getGoodsCodeSnapshot(), c.getGoodsNameSnapshot(),
                c.getGoodsSnapshotSource(), c.getGoodsSnapshotLockedAt(), c.getColorId(),
                c.getUnitId(), c.getUnitRate(), c.getUnitQty(), c.getQty(), c.getWasteAllowance(),
                c.getIssuedQty(), c.getReturnedQty(), c.getLineClass(), c.getSourceDocNo(), c.getRemark());
    }

    private OrderDetail toDetail(
            SubcontractOrder order, List<OrderItemDto> items) {
        FinanceApproval approval = approvalProjection.latestForOrder(
                orderType(), order.getId(), order.getStatus());
        return toDetail(order, items, approval, null);
    }

    private OrderDetail toDetail(
            SubcontractOrder order,
            List<OrderItemDto> items,
            FinanceApproval approval) {
        return toDetail(order, items, approval, null);
    }

    private OrderDetail toDetail(
            SubcontractOrder order,
            List<OrderItemDto> items,
            FinanceApproval approval,
            OrderDetail.ShortDeliveryHold shortDeliveryHold) {
        boolean priceMasked = subcontractPriceMasked();
        markBomMissing(order, items);
        boolean productionLinked =
                productionSourceGuard.isSubcontractOrderLinked(order.getId());
        boolean pending = approval != null
                && "PENDING".equals(approval.status());
        boolean canEdit = order.getStatus() == STATUS_DRAFT
                && !pending;
        OrderSourceRef sourceApplication = singleApplicationSource(items);
        List<OrderItemDto> safeItems = priceMasked
                ? items.stream().map(SubcontractOrderService::maskItemPrices).toList()
                : items;
        return new OrderDetail(
                order.getId(), order.getLegacyId(), order.getBillNo(), order.getBillDate(),
                order.getSupplierId(), order.getWarehouseId(), priceMasked ? null : order.getCurrencyId(),
                priceMasked ? null : order.getExchangeRate(),
                priceMasked ? null : order.getSettlementMethodId(),
                priceMasked ? null : order.getTaxRate(), order.getPurchaserId(),
                order.getMakerId(), order.getApproverId(), order.getDeliverDate(),
                order.isFulfill(), order.getRemark(), priceMasked ? null : order.getTotalOriginal(),
                priceMasked ? null : order.getTotalLocal(), order.getStatus(), order.isClosed(),
                order.getSourceDocNo(), safeItems,
                nameResolver.nameOf(order.getMakerId()), order.getCreatedAt(),
                productionLinked, canEdit, canEdit,
                order.getStatus() == STATUS_APPROVED,
                restrictionReason(pending),
                approval,
                sourceApplication == null ? null : sourceApplication.id(),
                sourceApplication == null ? null : sourceApplication.billNo(),
                priceMasked,
                shortDeliveryHold);
    }

    /** ADR-143 §二.3：草稿上缺 BOM 的委外件逐行标出(提交财务会被拒并通知研发完善)。 */
    private void markBomMissing(SubcontractOrder order, List<OrderItemDto> items) {
        if (items.isEmpty() || order.getStatus() == null || order.getStatus() != STATUS_DRAFT) return;
        java.util.Set<UUID> missing = goodsWithoutDrawableBom(
                items.stream().map(OrderItemDto::getGoodsId).toList()).stream()
                .map(row -> (UUID) row[0]).collect(Collectors.toSet());
        if (missing.isEmpty()) return;
        items.forEach(item -> item.setBomMissing(missing.contains(item.getGoodsId())));
    }

    private boolean subcontractPriceMasked() {
        return commercialPriceVisibility == null
                || !commercialPriceVisibility.canViewSubcontractOrder();
    }

    private static OrderItemDto maskItemPrices(OrderItemDto it) {
        OrderItemDto dto = new OrderItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(), it.getUnitId(), it.getUnitRate(),
                it.getQty(), null, null, null, it.getReceivedQty(), it.getReturnedQty(),
                it.getIssuedQty(), it.getMaterialReturnedQty(), it.getApplicationItemId(),
                it.getDeliverDate(), it.getWeight(), it.getSourceDocNo(), it.getRemark(),
                it.getSourceApplications(), it.getAllowedLossPct(), it.getSettledLossQty(), it.isBomMissing());
        dto.setExtraColumns(com.uten.imp.common.columns.BusinessColumnService.visible(it.getExtraColumns(), true));
        return dto;
    }

    /** 全部明细（含 V463 合并行全部来源）同属一张委外申请时返回该申请 (id, billNo)；否则 null。 */
    private OrderSourceRef singleApplicationSource(List<OrderItemDto> items) {
        List<UUID> applicationItemIds = items.stream()
                .flatMap(it -> it.getSourceApplications() != null
                        && !it.getSourceApplications().isEmpty()
                        ? it.getSourceApplications().stream()
                                .map(OrderItemDto.SourceApplicationDoc::applicationItemId)
                        : java.util.stream.Stream.of(it.getApplicationItemId()))
                .filter(id -> id != null).distinct().toList();
        if (applicationItemIds.isEmpty()) return null;
        List<Object[]> rows = com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT DISTINCT sa.id, sa.bill_no
                        FROM subcontract_application_items i
                        JOIN subcontract_applications sa ON sa.id = i.application_id
                        WHERE i.id IN (:ids)
                        """).setParameter("ids", applicationItemIds));
        return rows.size() == 1 ? new OrderSourceRef((UUID) rows.getFirst()[0], (String) rows.getFirst()[1]) : null;
    }

    /** 详情头溯源引用（id 供跳转、billNo 供展示）。 */
    public record OrderSourceRef(UUID id, String billNo) {
    }

    private static Object[] spreadSource(OrderSourceRef ref) {
        return ref == null ? new Object[]{null, null} : new Object[]{ref.id(), ref.billNo()};
    }

    private String restrictionReason(boolean financePending) {
        if (financePending) {
            return "该委外订单正在财务审核，驳回后方可修改或删除";
        }
        return null;
    }

    private void requireDecompositionAuthorityIfNeeded(OrderSaveRequest req) {
        boolean hasApplicationLines = req != null
                && req.getItems() != null
                && req.getItems().stream()
                .anyMatch(item -> item != null && item.getApplicationItemId() != null);
        if (hasApplicationLines && !access.hasAuthority("subcontract_order:decompose")) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "缺少从委外申请分解订货单的权限");
        }
    }

    private SubcontractOrder requireOrder(UUID id) { return requireOrder(id, false); }

    private SubcontractOrder requireOrder(UUID id, boolean includeDeleted) {
        return orderRepo.findById(id)
                .filter(r -> includeDeleted || !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "委外订货单不存在"));
    }
    private SubcontractOrder requireOrderForUpdate(UUID id) {
        SubcontractOrder order = em.find(
                SubcontractOrder.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        return order == null || order.isDeleted()
                ? requireOrder(id)
                : order;
    }

    private OrderDetail finishHistory(OrderDetail view, SubcontractOrder entity, boolean historyRead) {
        if (!historyRead && !entity.isDeleted()) return view;
        return retainedRecords.detail(view, "subcontract_orders", entity.getId(), entity.isDeleted(), entity.getDeletedAt(), historyRead);
    }

    @Transactional(readOnly = true)
    public java.util.List<com.uten.imp.common.history.RetainedRecordReader.RetainedRow> historyRows(UUID id, Long beforeId, int size) {
        var document=detailHistory(id);
        com.uten.imp.common.history.RetainedRecordAccess.requireUnmaskedCostOriginal(document.isPriceMasked());
        return retainedRecords.children("subcontract_orders",id,beforeId,size);
    }
}
