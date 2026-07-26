package com.uten.imp.features.sales.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.sales.order.dto.OrderCostItemDto;
import com.uten.imp.features.sales.order.dto.OrderDetail;
import com.uten.imp.features.sales.order.dto.OrderItemDto;
import com.uten.imp.features.sales.order.dto.OrderItemLine;
import com.uten.imp.features.sales.order.dto.OrderListItem;
import com.uten.imp.features.sales.order.dto.OrderQueryFilter;
import com.uten.imp.features.sales.order.dto.OrderSaveRequest;
import com.uten.imp.security.TxSessionVars;
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
import java.util.UUID;

/**
 * 销售订货单服务：CRUD（主+明细）+ 审核状态机。
 *
 * <p>审核（0→1）无库存/应收副作用（订货只承诺，不动账，design 20 §4.1）。红冲 1→-1。
 * BOM 展开子表 {@link SalesOrderCostItem} 本期只读（design 20 §一·13）。
 * is_closed 由出货/退货审核 Service 重算（{@code features.sales.shipment} / {@code .ret}）。
 */
@Service
@RequiredArgsConstructor
public class SalesOrderService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    private final SalesOrderRepository orderRepo;
    private final SalesOrderItemRepository itemRepo;
    private final SalesOrderCostItemRepository costItemRepo;
    private final TxSessionVars tx;

    @Transactional(readOnly = true)
    public PageResponse<OrderListItem> list(OrderQueryFilter f, int page, int size) {
        Specification<SalesOrder> spec = (Root<SalesOrder> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                          CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
            }
            if (f.clientId() != null) ps.add(cb.equal(root.get("clientId"), f.clientId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.closed() != null) ps.add(cb.equal(root.get("closed"), f.closed()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.DESC, "billDate"));
        Page<SalesOrder> p = orderRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public OrderDetail detail(UUID id) {
        SalesOrder o = requireOrder(id);
        List<SalesOrderItem> items = itemRepo.findByOrderIdOrderByLineNoAsc(id);
        List<OrderItemDto> itemDtos = items.stream().map(this::toItemDto).toList();
        List<OrderCostItemDto> costDtos = items.isEmpty() ? List.of()
                : costItemRepo.findByOrderItemIdIn(items.stream().map(SalesOrderItem::getId).toList())
                        .stream().map(this::toCostDto).toList();
        return toDetail(o, itemDtos, costDtos);
    }

    @Transactional
    public OrderDetail create(OrderSaveRequest req) {
        tx.bind();
        SalesOrder o = new SalesOrder();
        applyHeader(req, o);
        o.setStatus(STATUS_DRAFT);
        orderRepo.save(o);
        List<OrderItemDto> items = saveItems(o, req.getItems());
        applyTotals(o, items);
        return toDetail(o, items, List.of());
    }

    @Transactional
    public OrderDetail update(UUID id, OrderSaveRequest req) {
        tx.bind();
        SalesOrder o = requireOrder(id);
        if (o.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        applyHeader(req, o);
        costItemRepo.deleteByOrderId(id);
        itemRepo.deleteByOrderId(id);
        itemRepo.flush();
        List<OrderItemDto> items = saveItems(o, req.getItems());
        applyTotals(o, items);
        return toDetail(o, items, List.of());
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        SalesOrder o = requireOrder(id);
        if (o.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        o.setDeleted(true);
        o.setDeletedAt(OffsetDateTime.now());
        orderRepo.save(o);
    }

    /** 审核：status 0→1（订货不入库、不立应收）。 */
    @Transactional
    public OrderDetail approve(UUID id) {
        tx.bind();
        SalesOrder o = requireOrder(id);
        if (o.getStatus() == null || o.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (itemRepo.findByOrderIdOrderByLineNoAsc(id).isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        o.setStatus(STATUS_APPROVED);
        orderRepo.save(o);
        return detail(id);
    }

    @Transactional
    public OrderDetail reverse(UUID id) {
        tx.bind();
        SalesOrder o = requireOrder(id);
        if (o.getStatus() == null || o.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        o.setStatus(STATUS_REVERSED);
        orderRepo.save(o);
        return detail(id);
    }

    /** 中止位切换（独立业务位，贴老库 Stop；不依赖 status）。 */
    @Transactional
    public OrderDetail toggleStopped(UUID id, boolean stopped) {
        tx.bind();
        SalesOrder o = requireOrder(id);
        o.setStopped(stopped);
        orderRepo.save(o);
        return detail(id);
    }

    private void applyHeader(OrderSaveRequest req, SalesOrder o) {
        o.setBillNo(req.getBillNo());
        o.setBillDate(req.getBillDate());
        o.setClientId(req.getClientId());
        o.setCurrencyId(req.getCurrencyId());
        o.setExchangeRate(req.getExchangeRate());
        o.setTaxRate(req.getTaxRate());
        o.setPaymentStyleId(req.getPaymentStyleId());
        o.setSellerId(req.getSellerId());
        o.setDeliverDate(req.getDeliverDate());
        o.setContractNo(req.getContractNo());
        o.setLinkPhone(req.getLinkPhone());
        o.setSignAddr(req.getSignAddr());
        o.setShipAddr(req.getShipAddr());
        o.setDeposit(req.getDeposit());
        o.setRemark(req.getRemark());
    }

    private List<OrderItemDto> saveItems(SalesOrder o, List<OrderItemLine> lines) {
        List<OrderItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (OrderItemLine l : lines) {
            SalesOrderItem it = new SalesOrderItem();
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
            it.setDiscount(l.getDiscount());
            it.setTaxAmount(l.getTaxAmount());
            it.setWeight(l.getWeight());
            it.setClientNo(l.getClientNo());
            it.setClientModel(l.getClientModel());
            it.setDeliverDate(l.getDeliverDate());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setMachiningPrice(l.getMachiningPrice());
            it.setCircumference(l.getCircumference());
            it.setInboundQty(l.getInboundQty());
            it.setInNo(l.getInNo());
            it.setOutNo(l.getOutNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    private void applyTotals(SalesOrder o, List<OrderItemDto> items) {
        BigDecimal local = items.stream()
                .map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream()
                .map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        o.setTotalLocal(local);
        o.setTotalOriginal(original);
        orderRepo.save(o);
    }

    private OrderListItem toList(SalesOrder o) {
        return new OrderListItem(o.getId(), o.getBillNo(), o.getBillDate(), o.getClientId(),
                o.getCurrencyId(), o.getTotalLocal(), o.getStatus(), o.isClosed(), o.isStopped(), o.getLegacyId());
    }

    private OrderItemDto toItemDto(SalesOrderItem it) {
        return new OrderItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getShippedQty(), it.getReturnedQty(), it.getFlagQty(),
                it.getDiscount(), it.getTaxAmount(), it.getWeight(), it.getClientNo(), it.getClientModel(),
                it.getDeliverDate(), it.getSourceDocNo(), it.getMachiningPrice(), it.getCircumference(),
                it.getInboundQty(), it.getInNo(), it.getOutNo(), it.getRemark());
    }

    private OrderCostItemDto toCostDto(SalesOrderCostItem c) {
        return new OrderCostItemDto(c.getId(), c.getOrderItemId(), c.getParentId(), c.getLevel(),
                c.getClassCode(), c.getGoodsId(), c.getColorId(), c.getAltGoodsId(), c.getAltColorId(),
                c.getUnitId(), c.getQty(), c.getOrderQty(), c.getReceivedQty(), c.getDrawQty(),
                c.getPurgeQty(), c.getOtherDrawQty(), c.getSupplierId(), c.getLStatus(),
                c.getBillDate(), c.getSourceDocNo(), c.getRemark());
    }

    private OrderDetail toDetail(SalesOrder o, List<OrderItemDto> items, List<OrderCostItemDto> costItems) {
        return new OrderDetail(o.getId(), o.getLegacyId(), o.getBillNo(), o.getBillDate(),
                o.getClientId(), o.getCurrencyId(), o.getExchangeRate(), o.getTaxRate(), o.getPaymentStyleId(),
                o.getSellerId(), o.getMakerId(), o.getApproverId(), o.getDeliverDate(), o.getContractNo(),
                o.getLinkPhone(), o.getSignAddr(), o.getShipAddr(), o.getDeposit(), o.getRemark(),
                o.getTotalOriginal(), o.getTotalLocal(), o.getStatus(), o.isClosed(), o.isStopped(),
                o.getSourceDocNo(), items, costItems);
    }

    private SalesOrder requireOrder(UUID id) {
        return orderRepo.findById(id).filter(o -> !o.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "销售订货单不存在"));
    }
}
