package com.uten.imp.features.subcontract.order;

import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.application.port.ProcurementOrderApprovalPort;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.ItemSnapshot;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.OrderSnapshot;
import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
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
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.OffsetDateTime;
import java.util.ArrayList;
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

    @Transactional(readOnly = true)
    public PageResponse<OrderListItem> list(OrderQueryFilter f, int page, int size, String sort, String order) {
        Specification<SubcontractOrder> spec = (Root<SubcontractOrder> root,
                                                jakarta.persistence.criteria.CriteriaQuery<?> q,
                                                CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
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
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<SubcontractOrder> p = orderRepo.findAll(spec, pageable);
        Map<UUID, FinanceApproval> approvals = approvalProjection.latestForOrders(
                orderType(),
                p.getContent().stream().collect(Collectors.toMap(
                        SubcontractOrder::getId,
                        row -> row.getStatus())));
        List<OrderListItem> items = p.getContent().stream()
                .map(row -> toList(row, approvals.get(row.getId())))
                .toList();
        return new PageResponse<>(
                items, page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public OrderDetail detail(UUID id) {
        SubcontractOrder r = requireOrder(id);
        List<OrderItemDto> items = itemRepo.findByOrderIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(r, items);
    }

    /** 查询订货单的 BOM 成本子表（只读；前端按 bom_level + parent_cost_item_id 渲染树）。 */
    @Transactional(readOnly = true)
    public List<OrderCostItemDto> listCostItems(UUID orderId) {
        requireOrder(orderId);
        return costItemRepo.findByOrderIdOrderByBomLevelAsc(orderId).stream()
                .map(this::toCostItemDto).toList();
    }

    @Transactional
    public OrderDetail create(OrderSaveRequest req) {
        tx.bind();
        SubcontractOrder r = new SubcontractOrder();
        applyHeader(req, r);
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        r.setStatus(STATUS_DRAFT);
        orderRepo.save(r);
        List<OrderItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public OrderDetail update(UUID id, OrderSaveRequest req) {
        tx.bind();
        SubcontractOrder r = requireOrderForUpdate(id);
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        approvalProjection.requireMutable(orderType(), id);
        applyHeader(req, r);
        itemRepo.deleteByOrderId(id);
        itemRepo.flush();
        List<OrderItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        SubcontractOrder r = requireOrderForUpdate(id);
        if (r.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
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
        if (items.stream().anyMatch(item -> item.getApplicationItemId() == null)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "委外订货每一行都必须关联计划下达的委外申请明细");
        }
        normalizePersistedUnits(items);
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
        List<SubcontractOrderItem> items =
                itemRepo.findByOrderIdOrderByLineNoAsc(id);
        productionSupply.onSubcontractOrderApproved(id);
        for (SubcontractOrderItem item : items) {
            em.createNativeQuery("""
                    UPDATE subcontract_application_items
                    SET ordered_qty = COALESCE(ordered_qty, 0) + :qty
                    WHERE id = :id
                    """)
                    .setParameter("qty", item.getQty())
                    .setParameter("id", item.getApplicationItemId())
                    .executeUpdate();
            recalcApplicationClosed(item.getApplicationItemId());
        }
        order.setStatus(STATUS_APPROVED);
        order.setApproverId(approverEmployeeId);
        orderRepo.save(order);
    }

    /** 红冲：1→-1。反向回写 ordered_qty + 重算申请 is_closed（无 ArAp 无库存）。 */
    @Transactional
    public OrderDetail reverse(UUID id) {
        tx.bind();
        SubcontractOrder r = requireOrderForUpdate(id);
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
        sourceIntegrity.lockSubcontractApplicationItemsForReversal(
                items.stream().map(SubcontractOrderItem::getApplicationItemId).toList());
        productionSupply.onSubcontractOrderReversed(id);
        for (SubcontractOrderItem it : items) {
            if (it.getApplicationItemId() != null) {
                em.createNativeQuery(
                        "UPDATE subcontract_application_items SET ordered_qty = COALESCE(ordered_qty,0) - :q WHERE id = :id")
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getApplicationItemId())
                        .executeUpdate();
                recalcApplicationClosed(it.getApplicationItemId());
            }
        }
        arrivalControl.cancelForOrderReversal(
                ProcurementArrivalControlPort.SUBCONTRACT, id);
        r.setStatus(STATUS_REVERSED);
        orderRepo.save(r);
        return detail(id);
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
        Map<UUID, BigDecimal> submittedBySource = items.stream()
                .collect(Collectors.toMap(
                        SubcontractOrderItem::getApplicationItemId,
                        SubcontractOrderItem::getQty,
                        BigDecimal::add));
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
                .setParameter("sourceIds", submittedBySource.keySet())
                .getResultList();
        if (lockedSources.size() != submittedBySource.size()) {
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
                               source.qty,
                               COALESCE(source.ordered_qty, 0),
                               application.status,
                               COALESCE((
                                   SELECT SUM(pending_item.qty)
                                   FROM procurement_order_approval_cases approval_case
                                   JOIN subcontract_order_items pending_item
                                     ON pending_item.order_id = approval_case.order_id
                                    AND pending_item.is_deleted = FALSE
                                   JOIN subcontract_orders pending_order
                                     ON pending_order.id = pending_item.order_id
                                    AND pending_order.is_deleted = FALSE
                                   WHERE approval_case.order_type = 'SUBCONTRACT'
                                     AND approval_case.status = 'PENDING'
                                     AND approval_case.order_id <> :orderId
                                     AND pending_item.application_item_id = source.id
                               ), 0)
                        FROM subcontract_application_items source
                        JOIN subcontract_applications application
                          ON application.id = source.application_id
                        WHERE source.id IN (:sourceIds)
                          AND source.is_deleted = FALSE
                          AND application.is_deleted = FALSE
                        ORDER BY source.id
                        FOR UPDATE OF source, application
                        """)
                        .setParameter("orderId", order.getId())
                        .setParameter("sourceIds", submittedBySource.keySet()));
        if (rows.size() != submittedBySource.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "委外申请来源已变化，请刷新后重试");
        }
        Map<UUID, Object[]> bySource = rows.stream()
                .collect(Collectors.toMap(row -> (UUID) row[0], row -> row));
        for (SubcontractOrderItem item : items) {
            Object[] source = bySource.get(item.getApplicationItemId());
            if (source == null
                    || !(source[8] instanceof Number status)
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
            if (!Objects.equals(item.getGoodsId(), source[2])
                    || !Objects.equals(item.getColorId(), source[3])
                    || !Objects.equals(item.getUnitId(), source[4])
                    || !sameDecimal(item.getUnitRate(), decimal(source[5]))) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "委外订货明细与来源申请明细不一致");
            }
        }
        for (Object[] source : rows) {
            UUID sourceId = (UUID) source[0];
            BigDecimal capacity = decimal(source[6]);
            BigDecimal effective = decimal(source[7]);
            BigDecimal pending = decimal(source[9]);
            if (effective.add(pending).add(submittedBySource.get(sourceId))
                    .compareTo(capacity) > 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "委外订货量连同其它待财务审核订单已超过申请剩余量");
            }
        }
    }

    private static void requireFinanceCommercialAuthority(
            SubcontractOrder order, List<SubcontractOrderItem> items) {
        BigDecimal rate = order.getExchangeRate() == null
                ? BigDecimal.ONE
                : order.getExchangeRate();
        if (rate.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "委外订货汇率必须大于0");
        }
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
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SUB_ORDER));
        }
        r.setBillDate(req.getBillDate());
        r.setSupplierId(req.getSupplierId());
        r.setWarehouseId(req.getWarehouseId());
        r.setCurrencyId(req.getCurrencyId());
        r.setExchangeRate(req.getExchangeRate());
        r.setTaxRate(req.getTaxRate());
        r.setPurchaserId(req.getPurchaserId());
        r.setDeliverDate(req.getDeliverDate());
        r.setRemark(req.getRemark());
    }

    private List<OrderItemDto> saveItems(SubcontractOrder r, List<OrderItemLine> lines) {
        List<OrderItemDto> out = new ArrayList<>(lines.size());
        int autoLine = 1;
        for (OrderItemLine l : lines) {
            if (l.getApplicationItemId() == null) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "第 " + autoLine + " 行必须关联委外申请明细");
            }
            SubcontractOrderItem it = new SubcontractOrderItem();
            it.setOrderId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : autoLine);
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
            it.setApplicationItemId(l.getApplicationItemId());
            it.setDeliverDate(l.getDeliverDate());
            it.setWeight(l.getWeight());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            autoLine++;
        }
        return out;
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
            SubcontractOrder order, FinanceApproval approval) {
        return new OrderListItem(
                order.getId(),
                order.getBillNo(),
                order.getBillDate(),
                order.getSupplierId(),
                order.getWarehouseId(),
                order.getTotalLocal(),
                order.getStatus(),
                order.isClosed(),
                order.isFulfill(),
                order.getLegacyId(),
                approval);
    }

    private OrderItemDto toItemDto(SubcontractOrderItem it) {
        return new OrderItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getReceivedQty(), it.getReturnedQty(), it.getIssuedQty(),
                it.getMaterialReturnedQty(), it.getApplicationItemId(), it.getDeliverDate(),
                it.getWeight(), it.getSourceDocNo(), it.getRemark());
    }

    private OrderCostItemDto toCostItemDto(SubcontractOrderCostItem c) {
        return new OrderCostItemDto(c.getId(), c.getBomLevel(), c.getParentCostItemId(), c.getOrderItemId(),
                c.getParentGoodsId(), c.getParentColorId(), c.getGoodsId(), c.getColorId(),
                c.getUnitId(), c.getUnitRate(), c.getUnitQty(), c.getQty(), c.getWasteAllowance(),
                c.getIssuedQty(), c.getReturnedQty(), c.getLineClass(), c.getSourceDocNo(), c.getRemark());
    }

    private OrderDetail toDetail(
            SubcontractOrder order, List<OrderItemDto> items) {
        boolean productionLinked =
                productionSourceGuard.isSubcontractOrderLinked(order.getId());
        FinanceApproval approval = approvalProjection.latestForOrder(
                orderType(), order.getId(), order.getStatus());
        boolean pending = approval != null
                && "PENDING".equals(approval.status());
        boolean canEdit = order.getStatus() == STATUS_DRAFT
                && !pending;
        return new OrderDetail(
                order.getId(), order.getLegacyId(), order.getBillNo(), order.getBillDate(),
                order.getSupplierId(), order.getWarehouseId(), order.getCurrencyId(),
                order.getExchangeRate(), order.getTaxRate(), order.getPurchaserId(),
                order.getMakerId(), order.getApproverId(), order.getDeliverDate(),
                order.isFulfill(), order.getRemark(), order.getTotalOriginal(),
                order.getTotalLocal(), order.getStatus(), order.isClosed(),
                order.getSourceDocNo(), items,
                nameResolver.nameOf(order.getMakerId()), order.getCreatedAt(),
                productionLinked, canEdit, canEdit,
                order.getStatus() == STATUS_APPROVED,
                restrictionReason(pending),
                approval);
    }

    private String restrictionReason(boolean financePending) {
        if (financePending) {
            return "该委外订单正在财务审核，驳回后方可修改或删除";
        }
        return null;
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
