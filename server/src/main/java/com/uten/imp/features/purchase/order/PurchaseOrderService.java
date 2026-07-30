package com.uten.imp.features.purchase.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.purchase.order.dto.OrderDetail;
import com.uten.imp.features.purchase.order.dto.OrderItemDto;
import com.uten.imp.features.purchase.order.dto.OrderItemLine;
import com.uten.imp.features.purchase.order.dto.OrderListItem;
import com.uten.imp.features.purchase.order.dto.OrderQueryFilter;
import com.uten.imp.features.purchase.order.dto.OrderSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
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
 * 采购订货单服务：CRUD（主+明细）+ 审核状态机。
 *
 * <p>审核（0→1）：回写申请明细 ordered_qty + 重算申请单 is_closed（订货不入库，不碰库存）。
 * 红冲（1→-1）反向。取代老库 P_Order 触发器 TRI_POStockItem（去库存部分，库存由收货/退货动）。
 */
@Service
@RequiredArgsConstructor
public class PurchaseOrderService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    private final PurchaseOrderRepository orderRepo;
    private final PurchaseOrderItemRepository itemRepo;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final EntityManager em;
    private final DocNumberService docNumberService;

    @Transactional(readOnly = true)
    public PageResponse<OrderListItem> list(OrderQueryFilter f, int page, int size, String sort, String order) {
        Specification<PurchaseOrder> spec = (Root<PurchaseOrder> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
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
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<PurchaseOrder> p = orderRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public OrderDetail detail(UUID id) {
        PurchaseOrder o = requireOrder(id);
        List<OrderItemDto> items = itemRepo.findByOrderIdOrderByLineNoAsc(id).stream().map(this::toItemDto).toList();
        return toDetail(o, items);
    }

    @Transactional
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

    @Transactional
    public OrderDetail update(UUID id, OrderSaveRequest req) {
        tx.bind();
        PurchaseOrder o = requireOrder(id);
        if (o.getStatus() != STATUS_DRAFT) throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        applyHeader(req, o);
        itemRepo.deleteByOrderId(id);
        itemRepo.flush();
        List<OrderItemDto> items = saveItems(o, req.getItems());
        applyTotals(o, items);
        return toDetail(o, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        PurchaseOrder o = requireOrder(id);
        if (o.getStatus() == STATUS_APPROVED) throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        o.setDeleted(true);
        o.setDeletedAt(OffsetDateTime.now());
        orderRepo.save(o);
    }

    /** 审核：回写申请明细 ordered_qty + 重算申请单 is_closed（订货不入库）。 */
    @Transactional
    public OrderDetail approve(UUID id) {
        tx.bind();
        PurchaseOrder o = requireOrder(id);
        em.lock(o, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
        if (o.getStatus() == null || o.getStatus() != STATUS_DRAFT)
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        List<PurchaseOrderItem> items = itemRepo.findByOrderIdOrderByLineNoAsc(id);
        if (items.isEmpty()) throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        for (PurchaseOrderItem it : items) {
            if (it.getRequestItemId() != null) {
                em.createNativeQuery(
                        "UPDATE purchase_request_items SET ordered_qty = COALESCE(ordered_qty,0) + :q WHERE id = :id")
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getRequestItemId())
                        .executeUpdate();
                recalcRequestClosed(it.getRequestItemId());
            }
        }
        o.setStatus(STATUS_APPROVED);
        o.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        orderRepo.save(o);
        return detail(id);
    }

    @Transactional
    public OrderDetail reverse(UUID id) {
        tx.bind();
        PurchaseOrder o = requireOrder(id);
        em.lock(o, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥
        if (o.getStatus() == null || o.getStatus() != STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        for (PurchaseOrderItem it : itemRepo.findByOrderIdOrderByLineNoAsc(id)) {
            if (it.getRequestItemId() != null) {
                em.createNativeQuery(
                        "UPDATE purchase_request_items SET ordered_qty = COALESCE(ordered_qty,0) - :q WHERE id = :id")
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getRequestItemId())
                        .executeUpdate();
                recalcRequestClosed(it.getRequestItemId());
            }
        }
        o.setStatus(STATUS_REVERSED);
        orderRepo.save(o);
        return detail(id);
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
        o.setDeliverDate(req.getDeliverDate());
        o.setRemark(req.getRemark());
    }

    private List<OrderItemDto> saveItems(PurchaseOrder o, List<OrderItemLine> lines) {
        List<OrderItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (OrderItemLine l : lines) {
            PurchaseOrderItem it = new PurchaseOrderItem();
            it.setOrderId(o.getId());
            it.setBillNo(o.getBillNo());
            it.setBillDate(o.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
            it.setGiftQty(l.getGiftQty() != null ? l.getGiftQty() : BigDecimal.ZERO);
            it.setRequestItemId(l.getRequestItemId());
            it.setDeliverDate(l.getDeliverDate());
            it.setWeight(l.getWeight());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
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

    private OrderListItem toList(PurchaseOrder o) {
        return new OrderListItem(o.getId(), o.getBillNo(), o.getBillDate(), o.getSupplierId(),
                o.getTotalLocal(), o.getStatus(), o.isClosed(), o.getLegacyId());
    }

    private OrderItemDto toItemDto(PurchaseOrderItem it) {
        return new OrderItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getReceivedQty(), it.getReturnedQty(), it.getGiftQty(),
                it.getRequestItemId(), it.getDeliverDate(), it.getWeight(), it.getSourceDocNo(), it.getRemark());
    }

    private OrderDetail toDetail(PurchaseOrder o, List<OrderItemDto> items) {
        return new OrderDetail(o.getId(), o.getLegacyId(), o.getBillNo(), o.getBillDate(),
                o.getSupplierId(), o.getWarehouseId(), o.getCurrencyId(), o.getExchangeRate(), o.getTaxRate(),
                o.getPurchaserId(), o.getMakerId(), o.getApproverId(), o.getDeliverDate(), o.getRemark(),
                o.getTotalOriginal(), o.getTotalLocal(), o.getStatus(), o.isClosed(), o.getSourceDocNo(), items,
                nameResolver.nameOf(o.getMakerId()), o.getCreatedAt());
    }

    private PurchaseOrder requireOrder(UUID id) {
        return orderRepo.findById(id).filter(o -> !o.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "采购订货单不存在"));
    }
}
