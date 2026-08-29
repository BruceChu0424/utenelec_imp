package com.uten.imp.features.purchase.order;

import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.application.port.ProcurementOrderApprovalPort;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.ItemSnapshot;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.OrderSnapshot;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery;
import com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy;
import com.uten.imp.features.purchase.PurchaseGoodsSnapshot;
import com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy;
import com.uten.imp.features.purchase.order.dto.OrderDetail;
import com.uten.imp.features.purchase.order.dto.OrderItemDto;
import com.uten.imp.features.purchase.order.dto.OrderItemLine;
import com.uten.imp.features.purchase.order.dto.OrderListItem;
import com.uten.imp.features.purchase.order.dto.OrderQueryFilter;
import com.uten.imp.features.purchase.order.dto.OrderSaveRequest;
import com.uten.imp.security.CommercialPriceVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
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
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 采购订货单服务：CRUD（主+明细）+ 审核状态机。
 *
 * <p>审核（0→1）：回写申请明细 ordered_qty + 重算申请单 is_closed（订货不入库，不碰库存）。
 * 红冲（1→-1）反向。
 */
@Service
@RequiredArgsConstructor
public class PurchaseOrderService implements ProcurementOrderApprovalPort {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    private final PurchaseOrderRepository orderRepo;
    private final PurchaseOrderItemRepository itemRepo;
    private final LinkedDocumentIntegrityService sourceIntegrity;
    private final ProductionSupplyTransitionPort productionSupply;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final EntityManager em;
    private final DocNumberService docNumberService;
    private final ProductionSupplySourceGuard productionSourceGuard;
    private final PurchaseLineUnitPolicy lineUnitPolicy;
    private final ProcurementApprovalProjectionQuery approvalProjection;
    private final ProcurementArrivalControlPort arrivalControl;
    private final PurchaseDocumentAccessPolicy access;

    /** Spring injects this in production; direct-construction tests fail closed. */
    @Autowired
    private CommercialPriceVisibility commercialPriceVisibility;

    @Transactional(readOnly = true)
    public PageResponse<OrderListItem> list(OrderQueryFilter f, int page, int size, String sort, String order) {
        boolean priceMasked = purchasePriceMasked();
        var readScope = access.scope();
        Specification<PurchaseOrder> spec = (Root<PurchaseOrder> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                             CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(access.readablePredicate(root, cb, "makerId", readScope));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
            }
            if (f.supplierId() != null) ps.add(cb.equal(root.get("supplierId"), f.supplierId()));
            if (f.warehouseId() != null) ps.add(cb.equal(root.get("warehouseId"), f.warehouseId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"),
                        priceMasked ? Map.of("billDate", "billDate") : ALLOWED_SORT));
        Page<PurchaseOrder> p = orderRepo.findAll(spec, pageable);
        Map<UUID, FinanceApproval> approvals = approvalProjection.latestForOrders(
                orderType(),
                p.getContent().stream().collect(Collectors.toMap(
                        PurchaseOrder::getId,
                        row -> row.getStatus())));
        List<OrderListItem> items = p.getContent().stream()
                .map(row -> toList(row, approvals.get(row.getId()), priceMasked))
                .toList();
        return new PageResponse<>(
                items, page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public OrderDetail detail(UUID id) {
        PurchaseOrder o = requireOrder(id);
        if (!access.canRead(o.getMakerId())
                && !approvalProjection.canCurrentActorReviewPending(orderType(), id)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "采购订货单不存在");
        }
        return assembleDetail(o);
    }

    /**
     * Read-back used only after the approve/reject command has succeeded. The
     * controller already requires the review authority; the service also
     * verifies authoritative reviewer eligibility without changing normal
     * detail or list scope.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    OrderDetail financeDecisionResultDetail(UUID id, FinanceApproval decision) {
        if (!approvalProjection.isCurrentActorEligibleReviewer()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "采购订货单不存在");
        }
        requireDecisionReceipt(decision);
        PurchaseOrder o = requireOrder(id);
        List<OrderItemDto> items = itemRepo.findByOrderIdOrderByLineNoAsc(o.getId()).stream()
                .map(this::toItemDto).toList();
        return toDetail(o, items, decision);
    }

    private OrderDetail assembleDetail(PurchaseOrder o) {
        List<OrderItemDto> items = itemRepo.findByOrderIdOrderByLineNoAsc(o.getId()).stream()
                .map(this::toItemDto).toList();
        return toDetail(o, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('purchase_order:create') and hasAuthority('purchase_order:decompose')")
    public OrderDetail create(OrderSaveRequest req) {
        tx.bind();
        PurchaseOrder o = new PurchaseOrder();
        applyHeader(req, o);
        o.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        o.setStatus(STATUS_DRAFT);
        orderRepo.save(o);
        List<OrderItemDto> items = saveItems(o, req.getItems());
        applyTotals(o, items);
        return toDetail(o, items);
    }

    /**
     * 按明细级供应商拆单创建（保留「一张订货单一个供应商」归集）：每行 supplierId 为空时回落表头
     * supplierId，按供应商分组在同一事务内生成 N 张订货单（多数情况 1 张）。返回按分组顺序的明细。
     */
    @Transactional
    @PreAuthorize("hasAuthority('purchase_order:create') and hasAuthority('purchase_order:decompose')")
    public List<OrderDetail> createBatch(OrderSaveRequest req) {
        tx.bind();
        if (req.getItems() == null || req.getItems().isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "订货明细不能为空");
        }
        Map<UUID, List<OrderItemLine>> groups = new LinkedHashMap<>();
        for (OrderItemLine item : req.getItems()) {
            UUID supplier = item.getSupplierId() != null
                    ? item.getSupplierId()
                    : req.getSupplierId();
            if (supplier == null) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "每一行都必须指定供应商(明细级或表头)");
            }
            groups.computeIfAbsent(supplier, k -> new ArrayList<>()).add(item);
        }
        List<OrderDetail> created = new ArrayList<>();
        for (Map.Entry<UUID, List<OrderItemLine>> entry : groups.entrySet()) {
            OrderSaveRequest sub = new OrderSaveRequest();
            sub.setBillDate(req.getBillDate());
            sub.setSupplierId(entry.getKey());
            sub.setWarehouseId(req.getWarehouseId());
            sub.setCurrencyId(req.getCurrencyId());
            sub.setExchangeRate(req.getExchangeRate());
            sub.setTaxRate(req.getTaxRate());
            // 拆单必须携带结算方式，否则生成的订货单无法通过送审校验
            sub.setSettlementMethodId(req.getSettlementMethodId());
            sub.setSettlementStyleLegacy(req.getSettlementStyleLegacy());
            sub.setPurchaserId(req.getPurchaserId());
            sub.setDeliverDate(req.getDeliverDate());
            sub.setRemark(req.getRemark());
            sub.setItems(entry.getValue());
            created.add(create(sub));
        }
        return created;
    }

    @Transactional
    @PreAuthorize("hasAuthority('purchase_order:edit')")
    public OrderDetail update(UUID id, OrderSaveRequest req) {
        tx.bind();
        PurchaseOrder o = requireOrderForUpdate(id);
        access.requireWritable(o.getMakerId(), "只能操作本人负责的采购订货单");
        if (o.getStatus() != STATUS_DRAFT) throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        approvalProjection.requireMutable(orderType(), id);
        applyHeader(req, o);
        itemRepo.deleteByOrderId(id);
        itemRepo.flush();
        List<OrderItemDto> items = saveItems(o, req.getItems());
        applyTotals(o, items);
        return toDetail(o, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('purchase_order:delete')")
    public void delete(UUID id) {
        tx.bind();
        PurchaseOrder o = requireOrderForUpdate(id);
        access.requireWritable(o.getMakerId(), "只能操作本人负责的采购订货单");
        com.uten.imp.common.web.StandardDocumentLifecycleCapabilities.requireDraftForDelete(o.getStatus());
        approvalProjection.requireMutable(orderType(), id);
        o.setDeleted(true);
        o.setDeletedAt(OffsetDateTime.now());
        orderRepo.save(o);
    }

    @Override
    public String orderType() {
        return "PURCHASE";
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireFinanceSubmitterWritable(UUID id) {
        PurchaseOrder order = requireOrderForUpdate(id);
        access.requireWritable(
                order.getMakerId(),
                "只能提交本人负责或已正式交接的采购订货单");
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public OrderSnapshot lockAndValidateFinanceSubmission(UUID id) {
        PurchaseOrder order = requireOrderForUpdate(id);
        if (order.getStatus() == null || order.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.CONFLICT, "仅草稿订货单可提交或执行财务审核");
        }
        if (order.getSupplierId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "采购订货单必须指定供应商");
        }
        List<PurchaseOrderItem> items = itemRepo.findByOrderIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "订货明细不能为空");
        }
        if (items.stream().anyMatch(item -> item.getRequestItemId() == null)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "采购订货每一行都必须关联计划下达的采购申请明细");
        }
        normalizePersistedItemUnits(items);
        requireActiveSettlementMethod(order.getSettlementMethodId(), "采购订货");
        requireFinanceCommercialAuthority(order, items);
        sourceIntegrity.validatePurchaseOrder(items.stream()
                .map(item -> new LinkedDocumentIntegrityService.QuantityLinkedLine(
                        item.getRequestItemId(),
                        item.getGoodsId(),
                        item.getColorId(),
                        item.getUnitId(),
                        item.getUnitRate(),
                        item.getQty()))
                .toList());
        requireCapacityIncludingPending(id, items);
        return snapshot(order, items);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void applyFinanceApproval(UUID id, UUID approverEmployeeId) {
        PurchaseOrder order = requireOrderForUpdate(id);
        if (order.getStatus() == null || order.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.CONFLICT, "订货单已不再是待生效草稿");
        }
        List<PurchaseOrderItem> items = itemRepo.findByOrderIdOrderByLineNoAsc(id);
        captureGoodsSnapshots(
                items,
                PurchaseGoodsSnapshot.REQUEST_ITEM_AT_APPROVAL,
                PurchaseGoodsSnapshot.MASTER_AT_APPROVAL,
                OffsetDateTime.now());
        productionSupply.onPurchaseOrderApproved(id);
        for (PurchaseOrderItem item : items) {
            em.createNativeQuery("""
                    UPDATE purchase_request_items
                    SET ordered_qty = COALESCE(ordered_qty, 0) + :qty
                    WHERE id = :id
                    """)
                    .setParameter("qty", item.getQty())
                    .setParameter("id", item.getRequestItemId())
                    .executeUpdate();
            recalcRequestClosed(item.getRequestItemId());
        }
        order.setStatus(STATUS_APPROVED);
        order.setApproverId(approverEmployeeId);
        orderRepo.save(order);
    }

    @Transactional
    @PreAuthorize("hasAuthority('purchase_order:reverse')")
    public OrderDetail reverse(UUID id) {
        tx.bind();
        PurchaseOrder o = requireOrderForUpdate(id);
        access.requireWritable(o.getMakerId(), "只能操作本人负责的采购订货单");
        if (o.getStatus() == null || o.getStatus() != STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        List<PurchaseOrderItem> items = itemRepo.findByOrderIdOrderByLineNoAsc(id);
        if (items.stream().anyMatch(it ->
                positive(it.getReceivedQty()) || positive(it.getReturnedQty()))) {
            throw new ApiException(ErrorCode.BUSINESS, "采购订货已有收货/退货记录，请先红冲下游单据");
        }
        sourceIntegrity.lockPurchaseRequestItemsForReversal(
                items.stream().map(PurchaseOrderItem::getRequestItemId).toList());
        productionSupply.onPurchaseOrderReversed(id);
        for (PurchaseOrderItem it : items) {
            if (it.getRequestItemId() != null) {
                em.createNativeQuery(
                        "UPDATE purchase_request_items SET ordered_qty = COALESCE(ordered_qty,0) - :q WHERE id = :id")
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getRequestItemId())
                        .executeUpdate();
                recalcRequestClosed(it.getRequestItemId());
            }
        }
        arrivalControl.cancelForOrderReversal(
                ProcurementArrivalControlPort.PURCHASE, id);
        o.setStatus(STATUS_REVERSED);
        orderRepo.save(o);
        return assembleDetail(o);
    }

    private void requireCapacityIncludingPending(
            UUID orderId, List<PurchaseOrderItem> items) {
        Map<UUID, BigDecimal> submittedBySource = items.stream()
                .collect(Collectors.toMap(
                        PurchaseOrderItem::getRequestItemId,
                        PurchaseOrderItem::getQty,
                        BigDecimal::add));
        List<?> lockedSources = em.createNativeQuery("""
                        SELECT source.id
                        FROM purchase_request_items source
                        WHERE source.id IN (:sourceIds)
                        ORDER BY source.id
                        FOR UPDATE OF source
                        """)
                .setParameter("sourceIds", submittedBySource.keySet())
                .getResultList();
        if (lockedSources.size() != submittedBySource.size()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "采购申请来源已变化，请刷新后重试");
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT source.id,
                               source.qty,
                               COALESCE(source.ordered_qty, 0),
                               COALESCE((
                                   SELECT SUM(pending_item.qty)
                                   FROM procurement_order_approval_cases approval_case
                                   JOIN purchase_order_items pending_item
                                     ON pending_item.order_id = approval_case.order_id
                                    AND pending_item.is_deleted = FALSE
                                   JOIN purchase_orders pending_order
                                     ON pending_order.id = pending_item.order_id
                                    AND pending_order.is_deleted = FALSE
                                   WHERE approval_case.order_type = 'PURCHASE'
                                     AND approval_case.status = 'PENDING'
                                     AND approval_case.order_id <> :orderId
                                     AND pending_item.request_item_id = source.id
                               ), 0)
                        FROM purchase_request_items source
                        WHERE source.id IN (:sourceIds)
                        ORDER BY source.id
                        """)
                        .setParameter("orderId", orderId)
                        .setParameter("sourceIds", submittedBySource.keySet()));
        if (rows.size() != submittedBySource.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "采购申请来源已变化，请刷新后重试");
        }
        for (Object[] row : rows) {
            UUID sourceId = (UUID) row[0];
            BigDecimal capacity = decimal(row[1]);
            BigDecimal effective = decimal(row[2]);
            BigDecimal pending = decimal(row[3]);
            BigDecimal submitted = submittedBySource.get(sourceId);
            if (effective.add(pending).add(submitted).compareTo(capacity) > 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "采购订货量连同其它待财务审核订单已超过申请剩余量");
            }
        }
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
            PurchaseOrder order, List<PurchaseOrderItem> items) {
        BigDecimal rate = order.getExchangeRate() == null
                ? BigDecimal.ONE
                : order.getExchangeRate();
        if (rate.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "采购订货汇率必须大于0");
        }
        BigDecimal totalOriginal = BigDecimal.ZERO;
        BigDecimal totalLocal = BigDecimal.ZERO;
        for (PurchaseOrderItem item : items) {
            if (item.getQty() == null || item.getQty().signum() <= 0
                    || item.getPrice() == null || item.getPrice().signum() < 0
                    || item.getAmountOriginal() == null
                    || item.getAmountOriginal().signum() < 0
                    || item.getAmountLocal() == null
                    || item.getAmountLocal().signum() < 0) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "采购订货数量、单价和金额必须完整且不能为负");
            }
            BigDecimal expectedOriginal =
                    money(item.getQty().multiply(item.getPrice()));
            BigDecimal expectedLocal = money(expectedOriginal.multiply(rate));
            if (money(item.getAmountOriginal()).compareTo(expectedOriginal) != 0
                    || money(item.getAmountLocal()).compareTo(expectedLocal) != 0) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "采购订货金额与数量、单价或汇率不一致");
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
                    "采购订货表头金额与明细汇总不一致");
        }
    }

    private OrderSnapshot snapshot(
            PurchaseOrder order, List<PurchaseOrderItem> items) {
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
                                item.getRequestItemId(),
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

    private static boolean positive(BigDecimal value) {
        return value != null && value.signum() > 0;
    }

    private void recalcRequestClosed(UUID requestItemId) {
        em.createNativeQuery("""
                UPDATE purchase_requests r SET is_closed = (
                    SELECT COALESCE(bool_and(COALESCE(i.qty,0) - COALESCE(i.ordered_qty,0) <= 0), true)
                    FROM purchase_request_items i
                    WHERE i.request_id = r.id AND COALESCE(i.is_deleted, false) = false
                ) WHERE r.id = (SELECT request_id FROM purchase_request_items WHERE id = :iid)
                """).setParameter("iid", requestItemId).executeUpdate();
    }

    private void applyHeader(OrderSaveRequest req, PurchaseOrder o) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (o.getBillNo() == null || o.getBillNo().isBlank()) {
            o.setBillNo(docNumberService.nextNumber(DocNumberPrefix.PURCHASE_ORDER));
        }
        o.setBillDate(req.getBillDate());
        o.setSupplierId(req.getSupplierId());
        o.setWarehouseId(req.getWarehouseId());
        o.setCurrencyId(req.getCurrencyId());
        o.setExchangeRate(req.getExchangeRate());
        o.setTaxRate(req.getTaxRate());
        o.setPurchaserId(req.getPurchaserId());
        if (!(req.getSettlementMethodId() == null && req.getSettlementStyleLegacy() == null
                && o.getSettlementMethodId() == null && o.getSettlementStyleLegacy() != null)) {
            var settlement = com.uten.imp.common.util.SettlementMethodReferenceResolver.resolve(
                    em, req.getSettlementMethodId(), req.getSettlementStyleLegacy(), "结帐方式");
            o.setSettlementMethodId(settlement == null ? null : settlement.id());
            o.setSettlementStyleLegacy(settlement == null || settlement.legacyId() == null
                    ? null : settlement.legacyId().shortValue());
        }
        o.setDeliverDate(req.getDeliverDate());
        o.setRemark(req.getRemark());
    }

    private List<OrderItemDto> saveItems(PurchaseOrder o, List<OrderItemLine> lines) {
        List<OrderItemDto> out = new ArrayList<>(lines.size());
        for (int index = 0; index < lines.size(); index++) {
            OrderItemLine line = lines.get(index);
            int lineNo = line.getLineNo() != null ? line.getLineNo() : index + 1;
            if (line.getRequestItemId() == null) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "第 " + lineNo + " 行必须关联采购申请明细");
            }
        }
        Map<UUID, PurchaseGoodsSnapshot> requestSnapshots =
                PurchaseGoodsSnapshot.fromRequestItems(
                        em,
                        lines.stream().map(OrderItemLine::getRequestItemId).toList(),
                        PurchaseGoodsSnapshot.REQUEST_ITEM_AT_SAVE);
        // 谱系继承：订货行从申请行继承 来源计划号/销售订单号/需求日期，采购全程可溯源到销售来源。
        Map<UUID, Object[]> requestLineage = requestItemLineage(
                lines.stream().map(OrderItemLine::getRequestItemId).distinct().toList());
        Map<UUID, PurchaseGoodsSnapshot> masterSnapshots =
                PurchaseGoodsSnapshot.fromMaster(
                        em,
                        lines.stream().map(OrderItemLine::getGoodsId).toList(),
                        PurchaseGoodsSnapshot.MASTER_AT_SAVE);
        int auto = 1;
        for (OrderItemLine l : lines) {
            int lineNo = l.getLineNo() != null ? l.getLineNo() : auto;
            PurchaseLineUnitPolicy.ResolvedUnit resolvedUnit =
                    lineUnitPolicy.normalizeAndValidate(
                            l.getGoodsId(), l.getUnitId(), l.getUnitRate(), lineNo);
            PurchaseOrderItem it = new PurchaseOrderItem();
            it.setOrderId(o.getId());
            it.setBillNo(o.getBillNo());
            it.setBillDate(o.getBillDate());
            it.setLineNo(lineNo);
            it.setGoodsId(l.getGoodsId());
            applyGoodsSnapshot(
                    it,
                    PurchaseGoodsSnapshot.preferred(
                            requestSnapshots,
                            l.getRequestItemId(),
                            masterSnapshots,
                            l.getGoodsId(),
                            "采购订货明细"),
                    null);
            it.setColorId(l.getColorId());
            it.setUnitId(resolvedUnit.unitId());
            it.setUnitRate(resolvedUnit.unitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
            it.setGiftQty(l.getGiftQty() != null ? l.getGiftQty() : BigDecimal.ZERO);
            it.setRequestItemId(l.getRequestItemId());
            it.setDeliverDate(l.getDeliverDate());
            it.setWeight(l.getWeight());
            it.setSourceDocNo(l.getSourceDocNo());
            // 谱系继承：优先取申请行的计划号/销售单号/需求日（客户端不传也不丢溯源）。
            Object[] lineage = requestLineage.get(l.getRequestItemId());
            if (lineage != null) {
                if (it.getSourceDocNo() == null || it.getSourceDocNo().isBlank()) {
                    it.setSourceDocNo((String) lineage[0]);
                }
                if (it.getDeliverDate() == null) {
                    it.setDeliverDate(toLocalDate(lineage[3]));
                }
                it.setProductionPlanNo((String) lineage[1]);
                it.setSalesOrderNo((String) lineage[2]);
            }
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    private void captureGoodsSnapshots(
            List<PurchaseOrderItem> items,
            String requestSource,
            String masterSource,
            OffsetDateTime lockedAt) {
        Map<UUID, PurchaseGoodsSnapshot> requestSnapshots =
                PurchaseGoodsSnapshot.fromRequestItems(
                        em,
                        items.stream().map(PurchaseOrderItem::getRequestItemId).toList(),
                        requestSource);
        Map<UUID, PurchaseGoodsSnapshot> masterSnapshots =
                PurchaseGoodsSnapshot.fromMaster(
                        em,
                        items.stream().map(PurchaseOrderItem::getGoodsId).toList(),
                        masterSource);
        for (PurchaseOrderItem item : items) {
            PurchaseGoodsSnapshot snapshot = PurchaseGoodsSnapshot.preferred(
                    requestSnapshots,
                    item.getRequestItemId(),
                    masterSnapshots,
                    item.getGoodsId(),
                    "采购订货明细");
            int updated = em.createNativeQuery("""
                    UPDATE purchase_order_items
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
                        "采购订货明细货品快照已锁定或不存在，请刷新后重试");
            }
        }
    }

    private static void applyGoodsSnapshot(
            PurchaseOrderItem item,
            PurchaseGoodsSnapshot snapshot,
            OffsetDateTime lockedAt) {
        item.setGoodsCodeSnapshot(snapshot.code());
        item.setGoodsNameSnapshot(snapshot.name());
        item.setGoodsSnapshotSource(snapshot.source());
        item.setGoodsSnapshotLockedAt(lockedAt);
    }

    private void normalizePersistedItemUnits(List<PurchaseOrderItem> items) {
        int fallbackLineNo = 1;
        for (PurchaseOrderItem item : items) {
            int lineNo = item.getLineNo() != null ? item.getLineNo() : fallbackLineNo;
            PurchaseLineUnitPolicy.ResolvedUnit resolvedUnit =
                    lineUnitPolicy.normalizeAndValidate(
                            item.getGoodsId(), item.getUnitId(), item.getUnitRate(), lineNo);
            item.setUnitId(resolvedUnit.unitId());
            item.setUnitRate(resolvedUnit.unitRate());
            fallbackLineNo++;
        }
        itemRepo.saveAll(items);
    }

    private void applyTotals(PurchaseOrder o, List<OrderItemDto> items) {
        BigDecimal local = items.stream().map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream().map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        o.setTotalLocal(local);
        o.setTotalOriginal(original);
        orderRepo.save(o);
    }

    private OrderListItem toList(
            PurchaseOrder order, FinanceApproval approval, boolean priceMasked) {
        return new OrderListItem(
                order.getId(),
                order.getBillNo(),
                order.getBillDate(),
                order.getSupplierId(),
                priceMasked ? null : order.getTotalLocal(),
                order.getStatus(),
                order.isClosed(),
                order.getLegacyId(),
                approval,
                priceMasked);
    }

    /** 原生查询 DATE 列（驱动返回 java.sql.Date）安全转 LocalDate。 */
    private static java.time.LocalDate toLocalDate(Object value) {
        if (value == null) return null;
        if (value instanceof java.time.LocalDate localDate) return localDate;
        if (value instanceof java.sql.Date sqlDate) return sqlDate.toLocalDate();
        if (value instanceof java.time.OffsetDateTime odt) return odt.toLocalDate();
        return java.time.LocalDate.parse(value.toString());
    }

    /** 申请行谱系：id → [source_doc_no, production_plan_no, sales_order_no, deliver_date]，供订货行继承。 */
    @SuppressWarnings("unchecked")
    private Map<UUID, Object[]> requestItemLineage(List<UUID> requestItemIds) {
        if (requestItemIds == null || requestItemIds.isEmpty()) return Map.of();
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, source_doc_no, production_plan_no, sales_order_no, deliver_date
                        FROM purchase_request_items
                        WHERE id IN (:ids)
                        """)
                .setParameter("ids", requestItemIds)
                .getResultList();
        Map<UUID, Object[]> out = new java.util.HashMap<>();
        for (Object[] row : rows) {
            out.put((UUID) row[0], new Object[]{row[1], row[2], row[3], row[4]});
        }
        return out;
    }

    private OrderItemDto toItemDto(PurchaseOrderItem it) {
        return new OrderItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getReceivedQty(), it.getReturnedQty(), it.getGiftQty(),
                it.getRequestItemId(), it.getDeliverDate(), it.getWeight(), it.getSourceDocNo(),
                it.getProductionPlanNo(), it.getSalesOrderNo(), it.getRemark());
    }

    private OrderDetail toDetail(PurchaseOrder order, List<OrderItemDto> items) {
        FinanceApproval approval = approvalProjection.latestForOrder(
                orderType(), order.getId(), order.getStatus());
        return toDetail(order, items, approval);
    }

    private OrderDetail toDetail(
            PurchaseOrder order,
            List<OrderItemDto> items,
            FinanceApproval approval) {
        boolean priceMasked = purchasePriceMasked();
        boolean productionLinked =
                productionSourceGuard.isPurchaseOrderLinked(order.getId());
        boolean pending = approval != null
                && "PENDING".equals(approval.status());
        boolean canEdit = order.getStatus() == STATUS_DRAFT
                && !pending;
        OrderSourceRef sourceRequest = singleRequestSource(items);
        List<OrderItemDto> safeItems = priceMasked
                ? items.stream().map(PurchaseOrderService::maskItemPrices).toList()
                : items;
        return new OrderDetail(
                order.getId(), order.getLegacyId(), order.getBillNo(), order.getBillDate(),
                order.getSupplierId(), order.getWarehouseId(), priceMasked ? null : order.getCurrencyId(),
                priceMasked ? null : order.getExchangeRate(), priceMasked ? null : order.getTaxRate(),
                order.getPurchaserId(), priceMasked ? null : order.getSettlementMethodId(),
                priceMasked || order.getSettlementStyleLegacy() == null
                        ? null : order.getSettlementStyleLegacy().intValue(),
                order.getMakerId(), order.getApproverId(), order.getDeliverDate(),
                order.getRemark(), priceMasked ? null : order.getTotalOriginal(),
                priceMasked ? null : order.getTotalLocal(),
                order.getStatus(), order.isClosed(), order.getSourceDocNo(), safeItems,
                nameResolver.nameOf(order.getMakerId()), order.getCreatedAt(),
                productionLinked, canEdit, canEdit,
                order.getStatus() == STATUS_APPROVED,
                restrictionReason(pending),
                approval,
                sourceRequest == null ? null : sourceRequest.id(),
                sourceRequest == null ? null : sourceRequest.billNo(),
                priceMasked);
    }

    private boolean purchasePriceMasked() {
        return commercialPriceVisibility == null || !commercialPriceVisibility.canViewPurchase();
    }

    private static OrderItemDto maskItemPrices(OrderItemDto it) {
        return new OrderItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(), it.getUnitId(), it.getUnitRate(),
                it.getQty(), null, null, null, it.getReceivedQty(), it.getReturnedQty(),
                it.getGiftQty(), it.getRequestItemId(), it.getDeliverDate(), it.getWeight(),
                it.getSourceDocNo(), it.getProductionPlanNo(), it.getSalesOrderNo(), it.getRemark());
    }

    /** 全部明细同属一张采购申请时返回该申请 (id, billNo)；否则 null（跨申请部分分解）。 */
    private OrderSourceRef singleRequestSource(List<OrderItemDto> items) {
        List<UUID> requestItemIds = items.stream()
                .map(OrderItemDto::getRequestItemId).filter(id -> id != null).distinct().toList();
        if (requestItemIds.isEmpty()) return null;
        List<Object[]> rows = com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT DISTINCT pr.id, pr.bill_no
                        FROM purchase_request_items i
                        JOIN purchase_requests pr ON pr.id = i.request_id
                        WHERE i.id IN (:ids)
                        """).setParameter("ids", requestItemIds));
        return rows.size() == 1 ? new OrderSourceRef((UUID) rows.getFirst()[0], (String) rows.getFirst()[1]) : null;
    }

    /** 详情头溯源引用（id 供跳转、billNo 供展示）。 */
    public record OrderSourceRef(UUID id, String billNo) {
    }



    private static void requireDecisionReceipt(FinanceApproval decision) {
        if (decision == null
                || decision.caseId() == null
                || decision.version() < 2
                || !("APPROVED".equals(decision.status())
                || "REJECTED".equals(decision.status()))) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "财务审批结果已变化，请刷新任务后重试");
        }
    }

    private String restrictionReason(boolean financePending) {
        if (financePending) {
            return "该采购订单正在财务审核，驳回后方可修改或删除";
        }
        return null;
    }

    private PurchaseOrder requireOrder(UUID id) {
        return orderRepo.findById(id).filter(o -> !o.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "采购订货单不存在"));
    }
    private PurchaseOrder requireOrderForUpdate(UUID id) {
        PurchaseOrder order = em.find(
                PurchaseOrder.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        return order == null || order.isDeleted()
                ? requireOrder(id)
                : order;
    }
}
