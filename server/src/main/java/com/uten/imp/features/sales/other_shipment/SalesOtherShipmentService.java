package com.uten.imp.features.sales.other_shipment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentDetail;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentItemDto;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentListItem;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentQueryFilter;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentSaveRequest;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.StockService;
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
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * Historical other-shipment reader and controlled reversal boundary.
 * New customer dispatches use SalesShipmentService and its sales/finance/warehouse workflow.
 * Old rows retain their original inventory-only history; no receivable or approval is fabricated.
 */
@Service
@RequiredArgsConstructor
public class SalesOtherShipmentService {

    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    private final SalesOtherShipmentRepository shipmentRepo;
    private final SalesOtherShipmentItemRepository itemRepo;
    private final StockService stockService;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final SalesDocumentAccessPolicy accessPolicy;
    private final com.uten.imp.features.sales.SalesMutationFootprintService mutationFootprint;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_other_shipment:view')")
    public PageResponse<OtherShipmentListItem> list(OtherShipmentQueryFilter f, int page, int size, String sort, String order) {
        var readScope = accessPolicy.scope();
        Specification<SalesOtherShipment> spec = (Root<SalesOtherShipment> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                                  CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(accessPolicy.readablePredicate(root, cb, "ownerEmployeeId", readScope));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                String kw = "%" + f.keyword().toLowerCase() + "%";
                // 关键字同时匹配 单据号 / 客户名称（日常检索按客户找单）
                jakarta.persistence.criteria.Subquery<java.util.UUID> cs = q.subquery(java.util.UUID.class);
                Root<com.uten.imp.features.master.client.Client> cr =
                        cs.from(com.uten.imp.features.master.client.Client.class);
                cs.select(cr.get("id")).where(cb.isFalse(cr.get("deleted")),
                        cb.like(cb.lower(cr.get("name")), kw));
                ps.add(cb.or(cb.like(cb.lower(root.get("billNo")), kw),
                        root.get("clientId").in(cs)));
            }
            if (f.clientId() != null) ps.add(cb.equal(root.get("clientId"), f.clientId()));
            if (f.warehouseId() != null) ps.add(cb.equal(root.get("warehouseId"), f.warehouseId()));
            if (f.outType() != null && !f.outType().isBlank()) ps.add(cb.equal(root.get("outType"), f.outType()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<SalesOtherShipment> p = shipmentRepo.findAll(spec, pageable);
        boolean canEdit = hasObjectActionAuthority();
        return new PageResponse<>(p.map(s -> toList(s,
                        canEdit && accessPolicy.canWrite(s.getOwnerEmployeeId(), readScope))).getContent(),
                p);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_other_shipment:view')")
    public OtherShipmentDetail detail(UUID id) {
        SalesOtherShipment s = requireReadableShipment(id);
        List<SalesOtherShipmentItem> entities = itemRepo.findByShipmentIdOrderByLineNoAsc(id);
        Set<UUID> readableOrderItems = readableOrderItemIds(entities.stream()
                .map(SalesOtherShipmentItem::getOrderItemId).filter(Objects::nonNull).toList());
        List<OtherShipmentItemDto> items = entities.stream()
                .map(item -> toItemDto(item,
                        item.getOrderItemId() == null || readableOrderItems.contains(item.getOrderItemId())))
                .toList();
        boolean headerSourceReadable = isOrderSourceReadable(s.getSourceOrderId());
        return toDetail(s, items, headerSourceReadable,
                hasObjectActionAuthority()
                        && accessPolicy.canWrite(s.getOwnerEmployeeId()));
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_other_shipment:create')")
    public OtherShipmentDetail create(OtherShipmentSaveRequest req) {
        throw retiredWrite();
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_other_shipment:edit')")
    public OtherShipmentDetail update(UUID id, OtherShipmentSaveRequest req) {
        throw retiredWrite();
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_other_shipment:delete')")
    public void delete(UUID id) {
        throw retiredWrite();
    }

    /** Retired stock-out shortcut. It cannot be re-enabled by possessing the old permission. */
    @Transactional
    @PreAuthorize("hasAuthority('sales_other_shipment:approve')")
    public OtherShipmentDetail approve(UUID id) {
        throw retiredWrite();
    }

    private static ApiException retiredWrite() {
        return new ApiException(ErrorCode.CONFLICT,"历史其它出货单只供查阅。客户发货请新建客户零星发货，经财务确认后由仓库出库；内部领用请使用仓库内部单据");
    }

    /** 红冲：status 1→-1，反向入库（无 ar 校验，无回写）。 */
    @Transactional
    @PreAuthorize("hasAuthority('sales_other_shipment:reverse')")
    public OtherShipmentDetail reverse(UUID id) {
        tx.bind();
        SalesOtherShipment s = requireWritableShipment(id);
        if (s.getStatus() == null || s.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        List<SalesOtherShipmentItem> items = itemRepo.findByShipmentIdOrderByLineNoAsc(id);
        requireStoredCommercial(s, items);
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        OffsetDateTime now = OffsetDateTime.now();
        // 反向只翻 direction；amountLocal 传正数（StockService 内部乘 direction）。negate 会致金额符号不回滚。
        for (SalesOtherShipmentItem it : items) {
            applyMovement(s, it, StockService.DIR_IN, now, null);
        }
        s.setStatus(STATUS_REVERSED);
        shipmentRepo.save(s);
        return detail(id);
    }

    private void applyMovement(SalesOtherShipment s, SalesOtherShipmentItem it, short direction,
                               OffsetDateTime ts, BigDecimal overrideAmount) {
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        BigDecimal baseQty = it.getQty().multiply(rate);
        BigDecimal amt = overrideAmount != null ? overrideAmount : it.getAmountLocal();
        stockService.recordMovement(new StockService.MovementRequest(
                ts, StockService.TYPE_SALES_OTHER_OUT, StockService.SRC_SALES_OTHER_SHIPMENT,
                s.getId(), it.getId(), it.getGoodsId(), it.getColorId(), s.getWarehouseId(),
                direction, baseQty, it.getUnitId(), it.getUnitRate(), amt,
                direction < 0 ? null : "红冲", it.getWeight()));
    }

    private Set<UUID> readableOrderItemIds(List<UUID> ids) {
        if (ids.isEmpty() || !accessPolicy.hasAuthority("sales_order:view")) {
            return Set.of();
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT i.id, o.owner_employee_id
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                WHERE i.id IN (:ids)
                  AND COALESCE(i.is_deleted,false)=false
                  AND COALESCE(o.is_deleted,false)=false
                """).setParameter("ids", ids).getResultList();
        var readScope = accessPolicy.scope();
        java.util.HashSet<UUID> readable = new java.util.HashSet<>();
        for (Object[] row : rows) {
            if (accessPolicy.canRead((UUID) row[1], readScope)) {
                readable.add((UUID) row[0]);
            }
        }
        return readable;
    }

    private boolean isOrderSourceReadable(UUID sourceOrderId) {
        if (sourceOrderId == null) {
            return true;
        }
        if (!accessPolicy.hasAuthority("sales_order:view")) {
            return false;
        }
        @SuppressWarnings("unchecked")
        List<UUID> owners = em.createNativeQuery("""
                SELECT owner_employee_id
                FROM sales_orders
                WHERE id = :sourceOrderId
                  AND COALESCE(is_deleted,false)=false
                """)
                .setParameter("sourceOrderId", sourceOrderId)
                .getResultList();
        return owners.size() == 1 && accessPolicy.canRead(owners.getFirst());
    }

    private OtherShipmentListItem toList(SalesOtherShipment s, boolean writable) {
        return new OtherShipmentListItem(s.getId(), s.getBillNo(), s.getBillDate(), s.getClientId(),
                s.getWarehouseId(), s.getOutType(), s.getTotalLocal(), s.getStatus(), s.isClosed(),
                s.getLegacyId(), writable && s.getStatus()!=null && s.getStatus()==STATUS_APPROVED);
    }

    private OtherShipmentItemDto toItemDto(SalesOtherShipmentItem it, boolean sourceReadable) {
        return new OtherShipmentItemDto(it.getId(), it.getLineNo(),
                sourceReadable ? it.getOrderItemId() : null, it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(),
                it.getGoodsSnapshotSource(), it.getGoodsSnapshotLockedAt(),
                it.getColorId(), it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(),
                it.getAmountOriginal(), it.getAmountLocal(), it.getCostAmount(), it.getWeight(),
                it.getParcelQty(), it.getCartonCount(), it.getClientNo(), it.getClientModel(),
                it.getMaterialPrice(), it.getDieCastPrice(), it.getMachiningPrice(), it.getCircumference(),
                it.getDiscount(), it.getReturnedQty(), it.getReturnedAmount(),
                sourceReadable ? it.getSourceDocNo() : null,
                it.getRemark());
    }

    private OtherShipmentDetail toDetail(SalesOtherShipment s, List<OtherShipmentItemDto> items,
                                         boolean sourceReadable, boolean writable) {
        return new OtherShipmentDetail(s.getId(), s.getLegacyId(), s.getBillNo(), s.getBillDate(),
                s.getClientId(), s.getWarehouseId(), s.getCurrencyId(), s.getExchangeRate(), s.getTaxRate(),
                s.getPaymentStyleId(), s.getSettlementMethodId(), s.getSellerId(), s.getSenderId(),
                s.getMakerId(), s.getApproverId(),
                s.getShipAddr(), s.getLinkPhone(), s.getParcelCount(), s.getPrintCount(), s.getLastDate(),
                s.getOutType(), s.getRemark(), s.getTotalOriginal(), s.getTotalLocal(), s.getStatus(),
                s.isClosed(), sourceReadable ? s.getSourceOrderId() : null,
                sourceReadable ? s.getSourceDocNo() : null, items,
                nameResolver.nameOf(s.getMakerId()), s.getCreatedAt(), writable && s.getStatus()!=null && s.getStatus()==STATUS_APPROVED);
    }

    private boolean hasObjectActionAuthority() {
        return accessPolicy.hasAuthority("sales_other_shipment:reverse");
    }

    private SalesOtherShipment requireShipment(UUID id) {
        return shipmentRepo.findById(id).filter(s -> !s.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "其它出货单不存在"));
    }

    private SalesOtherShipment requireReadableShipment(UUID id) {
        SalesOtherShipment shipment = requireShipment(id);
        accessPolicy.requireReadable(shipment.getOwnerEmployeeId(), "其它出货单不存在");
        return shipment;
    }

    private SalesOtherShipment requireWritableShipment(UUID id) {
        SalesOtherShipment visible = requireShipment(id);
        accessPolicy.requireWritable(visible.getOwnerEmployeeId(), "只能操作本人负责的其它出货单");
        mutationFootprint.lockOtherShipment(id, List.of());
        SalesOtherShipment shipment = em.find(SalesOtherShipment.class, id,
                jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (shipment == null) throw new ApiException(ErrorCode.NOT_FOUND, "其它出货单不存在");
        em.refresh(shipment, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (shipment.isDeleted()) throw new ApiException(ErrorCode.NOT_FOUND, "其它出货单不存在");
        accessPolicy.requireWritable(shipment.getOwnerEmployeeId(), "只能操作本人负责的其它出货单");
        return shipment;
    }

    private static void requireStoredCommercial(SalesOtherShipment shipment, List<SalesOtherShipmentItem> items) {
        com.uten.imp.common.integrity.NonNegativeCommercialSignGuard.requireStoredTotals(
                "其它出货", shipment.getTotalOriginal(), shipment.getTotalLocal());
        for (SalesOtherShipmentItem item : items) {
            com.uten.imp.common.integrity.NonNegativeCommercialSignGuard.requireStoredLine(
                    "其它出货", item.getQty(), item.getPrice(), item.getAmountOriginal(),
                    item.getAmountLocal(), item.getCostAmount());
            requirePositiveUnitRate(item.getUnitRate());
        }
    }

    private static void requirePositiveUnitRate(BigDecimal rate) {
        if (rate != null && rate.signum() <= 0) {
            throw new ApiException(ErrorCode.CONFLICT, "其它出货单位换算率必须大于 0");
        }
    }


}
