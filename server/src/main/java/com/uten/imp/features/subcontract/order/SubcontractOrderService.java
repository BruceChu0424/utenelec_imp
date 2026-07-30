package com.uten.imp.features.subcontract.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
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
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

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
public class SubcontractOrderService {

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
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
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
        SubcontractOrder r = requireOrder(id);
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
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
        SubcontractOrder r = requireOrder(id);
        if (r.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        orderRepo.save(r);
    }

    /**
     * 审核：0→1。仅状态变更（无库存/ArAp）；若明细挂申请明细则回写
     * {@code application_items.ordered_qty += qty} + 重算申请 is_closed。
     */
    @Transactional
    public OrderDetail approve(UUID id) {
        tx.bind();
        SubcontractOrder r = requireOrder(id);
        em.lock(r, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        List<SubcontractOrderItem> items = itemRepo.findByOrderIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        sourceIntegrity.validateSubcontractOrder(
                r.getSupplierId(),
                items.stream()
                        .map(it -> new LinkedDocumentIntegrityService.QuantityLinkedLine(
                                it.getApplicationItemId(),
                                it.getGoodsId(),
                                it.getColorId(),
                                it.getUnitId(),
                                it.getQty()))
                        .toList());
        for (SubcontractOrderItem it : items) {
            if (it.getApplicationItemId() != null) {
                em.createNativeQuery(
                        "UPDATE subcontract_application_items SET ordered_qty = COALESCE(ordered_qty,0) + :q WHERE id = :id")
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getApplicationItemId())
                        .executeUpdate();
                recalcApplicationClosed(it.getApplicationItemId());
            }
        }
        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        orderRepo.save(r);
        return detail(id);
    }

    /** 红冲：1→-1。反向回写 ordered_qty + 重算申请 is_closed（无 ArAp 无库存）。 */
    @Transactional
    public OrderDetail reverse(UUID id) {
        tx.bind();
        SubcontractOrder r = requireOrder(id);
        em.lock(r, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        List<SubcontractOrderItem> items = itemRepo.findByOrderIdOrderByLineNoAsc(id);
        if (items.stream().anyMatch(it ->
                positive(it.getReceivedQty())
                        || positive(it.getReturnedQty())
                        || positive(it.getIssuedQty())
                        || positive(it.getMaterialReturnedQty()))) {
            throw new ApiException(
                    ErrorCode.BUSINESS,
                    "委外订货已有进仓/退货/发料/退料记录，请先红冲下游单据");
        }
        sourceIntegrity.lockSubcontractApplicationItemsForReversal(
                items.stream().map(SubcontractOrderItem::getApplicationItemId).toList());
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
        r.setStatus(STATUS_REVERSED);
        orderRepo.save(r);
        return detail(id);
    }

    private static boolean positive(BigDecimal value) {
        return value != null && value.signum() > 0;
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

    private OrderListItem toList(SubcontractOrder r) {
        return new OrderListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getSupplierId(),
                r.getWarehouseId(), r.getTotalLocal(), r.getStatus(), r.isClosed(), r.isFulfill(), r.getLegacyId());
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

    private OrderDetail toDetail(SubcontractOrder r, List<OrderItemDto> items) {
        return new OrderDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getSupplierId(), r.getWarehouseId(), r.getCurrencyId(), r.getExchangeRate(), r.getTaxRate(),
                r.getPurchaserId(), r.getMakerId(), r.getApproverId(), r.getDeliverDate(), r.isFulfill(),
                r.getRemark(), r.getTotalOriginal(), r.getTotalLocal(), r.getStatus(), r.isClosed(),
                r.getSourceDocNo(), items,
                nameResolver.nameOf(r.getMakerId()), r.getCreatedAt());
    }

    private SubcontractOrder requireOrder(UUID id) {
        return orderRepo.findById(id)
                .filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "委外订货单不存在"));
    }
}
