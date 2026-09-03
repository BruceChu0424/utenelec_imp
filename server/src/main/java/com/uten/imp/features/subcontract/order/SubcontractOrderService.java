package com.uten.imp.features.subcontract.order;

import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.application.port.ProcurementOrderApprovalPort;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.ItemSnapshot;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.OrderSnapshot;
import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.application.port.MasterReferenceValidationPort;
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
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
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

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    private final SubcontractOrderRepository orderRepo;
    private final SubcontractOrderItemRepository itemRepo;
    private final SubcontractOrderCostItemRepository costItemRepo;
    private final LinkedDocumentIntegrityService sourceIntegrity;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final DocNumberService docNumberService;
    private final ProductionSubcontractSupplyTransitionPort productionSupply;
    private final ProductionSupplySourceGuard productionSourceGuard;
    private final ProcurementApprovalProjectionQuery approvalProjection;
    private final ProcurementArrivalControlPort arrivalControl;
    private final SubcontractDocumentAccessPolicy access;
    private final com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService materialPlanService;
    private final MasterReferenceValidationPort references;

    @Autowired
    private CommercialPriceVisibility commercialPriceVisibility;

    @Transactional(readOnly = true)
    public PageResponse<OrderListItem> list(OrderQueryFilter f, int page, int size, String sort, String order) {
        boolean priceMasked = subcontractPriceMasked();
        var readScope = access.scope();
        Specification<SubcontractOrder> spec = (Root<SubcontractOrder> root,
                                                jakarta.persistence.criteria.CriteriaQuery<?> q,
                                                CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
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
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"),
                        priceMasked ? Map.of("billDate", "billDate") : ALLOWED_SORT));
        Page<SubcontractOrder> p = orderRepo.findAll(spec, pageable);
        Map<UUID, FinanceApproval> approvals = approvalProjection.latestForOrders(
                orderType(),
                p.getContent().stream().collect(Collectors.toMap(
                        SubcontractOrder::getId,
                        row -> row.getStatus())));
        List<OrderListItem> items = p.getContent().stream()
                .map(row -> toList(row, approvals.get(row.getId()), priceMasked))
                .toList();
        return new PageResponse<>(
                items, page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public OrderDetail detail(UUID id) {
        SubcontractOrder r = requireOrder(id);
        if (!access.canRead(r.getMakerId())
                && !approvalProjection.canCurrentActorReviewPending(orderType(), id)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "委外订货单不存在");
        }
        return assembleDetail(r);
    }

    private OrderDetail assembleDetail(SubcontractOrder r) {
        List<SubcontractOrderItem> items = itemRepo.findByOrderIdOrderByLineNoAsc(r.getId());
        Map<UUID, List<Object[]>> sources = orderItemSources(
                items.stream().map(SubcontractOrderItem::getId).toList());
        List<OrderItemDto> itemDtos = items.stream()
                .map(it -> toItemDto(it, sourceApplicationDocs(
                        sources.getOrDefault(it.getId(), List.of()))))
                .toList();
        return toDetail(r, itemDtos);
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
        SubcontractOrder r = new SubcontractOrder();
        applyHeader(req, r);
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        r.setStatus(STATUS_DRAFT);
        orderRepo.save(r);
        List<OrderItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
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
     * 货品 → 最近一次委外订货供应商（订货编辑页行级委外商「学习预填」用）。
     * 明细不落供应商（拆单后归集到单头 supplier_id），取每个货品最新一张未删订货单
     * 的单头供应商；批量一次查询，无历史返回空 Map。
     */
    @Transactional(readOnly = true)
    public Map<UUID, UUID> lastSuppliersPerGoods(java.util.Collection<UUID> goodsIds) {
        if (goodsIds == null || goodsIds.isEmpty()) {
            return Map.of();
        }
        Map<UUID, UUID> result = new LinkedHashMap<>();
        for (Object[] row : itemRepo.findLastSupplierPerGoods(goodsIds)) {
            result.put((UUID) row[0], (UUID) row[1]);
        }
        return result;
    }

    /**
     * 货品 → 最近一次委外订货商业条款（行级条款「学习预填」：同一货品下次建单自动
     * 带出上次的委外商/结算方式/币种/汇率/税率）。批量一次查询；无历史返回空 Map。
     * 委外商是否可用（停用/内部车间已过滤）由前端在回填时判断。
     */
    @Transactional(readOnly = true)
    public Map<UUID, LastTermsPerGoods> lastTermsPerGoods(
            java.util.Collection<UUID> goodsIds) {
        if (goodsIds == null || goodsIds.isEmpty()) {
            return Map.of();
        }
        Map<UUID, LastTermsPerGoods> result = new LinkedHashMap<>();
        for (Object[] row : itemRepo.findLastTermsPerGoods(goodsIds)) {
            result.put((UUID) row[0], new LastTermsPerGoods(
                    (UUID) row[1], (UUID) row[2], (UUID) row[3],
                    (BigDecimal) row[4], (BigDecimal) row[5]));
        }
        return result;
    }

    /** 行级条款学习记忆视图（/last-terms 返回体；金额口径字段见 subcontract_orders 头）。 */
    public record LastTermsPerGoods(
            UUID supplierId,
            UUID settlementMethodId,
            UUID currencyId,
            BigDecimal exchangeRate,
            BigDecimal taxRate) {}

    @Transactional
    @PreAuthorize("hasAuthority('subcontract_order:edit')")
    public OrderDetail update(UUID id, OrderSaveRequest req) {
        tx.bind();
        SubcontractOrder r = requireOrderForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外订货单");
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        approvalProjection.requireMutable(orderType(), id);
        requireRowsMatchHeaderSupplier(req);
        requireRowsMatchHeaderCommercial(req);
        applyHeader(req, r);
        itemRepo.deleteByOrderId(id);
        itemRepo.flush();
        List<OrderItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('subcontract_order:delete')")
    public void delete(UUID id) {
        tx.bind();
        SubcontractOrder r = requireOrderForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外订货单");
        com.uten.imp.common.web.StandardDocumentLifecycleCapabilities.requireDraftForDelete(r.getStatus());
        approvalProjection.requireMutable(orderType(), id);
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        orderRepo.save(r);
    }

    @Override
    public String orderType() {
        return "SUBCONTRACT";
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
        return snapshot(order, items);
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
        // V304：按批准时 BOM 展开发料计划并自动生成仓库出仓草稿（无 BOM 子件=委外商自备料则不建）。
        materialPlanService.createPlanOnApproval(id);
    }

    /** 红冲：1→-1。反向回写 ordered_qty + 重算申请 is_closed（无 ArAp 无库存）。 */
    @Transactional
    @PreAuthorize("hasAuthority('subcontract_order:reverse')")
    public OrderDetail reverse(UUID id) {
        tx.bind();
        SubcontractOrder r = requireOrderForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外订货单");
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
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
        materialPlanService.requireOrderReversalAllowed(id);
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
        // V304：软删未审出仓草稿 + 发料计划置 CANCELED（已审出仓由上方守卫先行拦截）。
        materialPlanService.cancelForOrderReversal(id);
        r.setStatus(STATUS_REVERSED);
        orderRepo.save(r);
        return assembleDetail(r);
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
            BigDecimal expectedOriginal =
                    money(item.getQty().multiply(item.getPrice()));
            BigDecimal expectedLocal = money(expectedOriginal.multiply(rate));
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
                                item.getDeliverDate()))
                        .toList());
    }

    private static BigDecimal money(BigDecimal value) {
        return value.setScale(4, RoundingMode.HALF_UP);
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
        r.setWarehouseId(req.getWarehouseId());
        r.setCurrencyId(req.getCurrencyId());
        r.setExchangeRate(req.getExchangeRate());
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
        List<OrderItemDto> out = new ArrayList<>(lines.size());
        // V463 同货品合并行：行数量按各申请行剩余量 FIFO 拆分到 sources
        //（末位来源吸收超额）；application_item_id 落首来源（主锚点）。
        Map<OrderItemLine, List<SourceSplit>> splits = planSourceSplits(lines);
        // 前置谱系守卫：合并行不得包含「先做后审（前置自制已完成）」来源——
        // V458 的准备/出仓谱线（preparedLineage/sourceLineage）按单一来源设计，
        // 合并会在财务批准/准备启动深处 409；提前到保存时给出可操作指引。
        requireMergeSourcesWithoutMakeTaskLineage(lines, splits);
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
        int autoLine = 1;
        for (OrderItemLine l : lines) {
            List<SourceSplit> lineSplits = splits.getOrDefault(l, List.of());
            UUID primarySource = lineSplits.isEmpty()
                    ? null : lineSplits.getFirst().applicationItemId();
            SubcontractOrderItem it = new SubcontractOrderItem();
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
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
            it.setApplicationItemId(primarySource);
            it.setDeliverDate(l.getDeliverDate());
            it.setWeight(l.getWeight());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
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
     * 前置谱系守卫（V463）：多来源合并行只要包含任一「先做后审（V458 前置自制
     * 已完成、申请行挂 make 任务批次）」来源即拒绝——该类需求的准备权益/出仓
     * 谱系按单一来源设计，合并会让财务批准（createPlanOnApproval→preparedLineage）
     * 或准备启动（sourceLineage）在深处 409。保存时拦截并给出可操作指引。
     */
    private void requireMergeSourcesWithoutMakeTaskLineage(
            List<OrderItemLine> lines,
            Map<OrderItemLine, List<SourceSplit>> splits) {
        Map<UUID, OrderItemLine> mergedSources = new java.util.LinkedHashMap<>();
        for (OrderItemLine line : lines) {
            List<SourceSplit> lineSplits = splits.getOrDefault(line, List.of());
            if (lineSplits.size() <= 1) {
                continue;
            }
            for (SourceSplit split : lineSplits) {
                mergedSources.putIfAbsent(split.applicationItemId(), line);
            }
        }
        if (mergedSources.isEmpty()) {
            return;
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT batch.application_item_id, application.bill_no
                        FROM preplan_subcontract_make_task_batches batch
                        JOIN preplan_subcontract_make_tasks task
                          ON task.id = batch.task_id
                         AND task.status = 'ACTIVE'
                        JOIN subcontract_application_items item
                          ON item.id = batch.application_item_id
                         AND item.is_deleted = FALSE
                        LEFT JOIN subcontract_applications application
                          ON application.id = item.application_id
                        WHERE batch.application_item_id IN (:ids)
                        ORDER BY batch.application_item_id
                        """).setParameter("ids", mergedSources.keySet()));
        if (rows.isEmpty()) {
            return;
        }
        UUID blockedSource = (UUID) rows.getFirst()[0];
        OrderItemLine line = mergedSources.get(blockedSource);
        String billNo = rows.getFirst()[1] == null ? "" : rows.getFirst()[1].toString();
        throw new ApiException(
                ErrorCode.VALIDATION_FAILED,
                "第 " + (line.getLineNo() != null ? line.getLineNo() : "?")
                        + " 行包含「前置自制已完成」的委外申请来源"
                        + (billNo.isEmpty() ? "" : "（" + billNo + "）")
                        + "：该类需求的准备/出仓谱系只支持单一来源，不能与其它申请合并，"
                        + "请去掉该来源后分开生成订货单");
    }

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
                        ORDER BY application.need_date NULLS LAST, item.id
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
        return new OrderItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getReceivedQty(), it.getReturnedQty(), it.getIssuedQty(),
                it.getMaterialReturnedQty(), it.getApplicationItemId(), it.getDeliverDate(),
                it.getWeight(), it.getSourceDocNo(), it.getRemark(),
                sourceApplications);
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
        return toDetail(order, items, approval);
    }

    private OrderDetail toDetail(
            SubcontractOrder order,
            List<OrderItemDto> items,
            FinanceApproval approval) {
        boolean priceMasked = subcontractPriceMasked();
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
                priceMasked);
    }

    private boolean subcontractPriceMasked() {
        return commercialPriceVisibility == null
                || !commercialPriceVisibility.canViewSubcontractOrder();
    }

    private static OrderItemDto maskItemPrices(OrderItemDto it) {
        return new OrderItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(), it.getUnitId(), it.getUnitRate(),
                it.getQty(), null, null, null, it.getReceivedQty(), it.getReturnedQty(),
                it.getIssuedQty(), it.getMaterialReturnedQty(), it.getApplicationItemId(),
                it.getDeliverDate(), it.getWeight(), it.getSourceDocNo(), it.getRemark(),
                it.getSourceApplications());
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

    private SubcontractOrder requireOrder(UUID id) {
        return orderRepo.findById(id)
                .filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "委外订货单不存在"));
    }
    private SubcontractOrder requireOrderForUpdate(UUID id) {
        SubcontractOrder order = em.find(
                SubcontractOrder.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        return order == null || order.isDeleted()
                ? requireOrder(id)
                : order;
    }
}
