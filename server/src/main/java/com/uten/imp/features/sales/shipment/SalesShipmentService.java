package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.arap.ArApLedgerService.ArApPostingRequest;
import com.uten.imp.features.sales.shipment.dto.ShipmentDetail;
import com.uten.imp.features.sales.shipment.dto.ShipmentItemDto;
import com.uten.imp.features.sales.shipment.dto.ShipmentItemLine;
import com.uten.imp.features.sales.shipment.dto.ShipmentListItem;
import com.uten.imp.features.sales.shipment.dto.ShipmentQueryFilter;
import com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest;
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
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 销售出货单服务：CRUD（主+明细）+ 审核状态机（库存 + 订单回写 + 立应收 + 结案）。
 *
 * <p>审核（status 0→1）同事务内：
 * <ol>
 *   <li>逐明细 {@link StockService#recordMovement} 出库（TYPE_SALES_OUT / DIR_OUT）</li>
 *   <li>回写 sales_order_items.shipped_qty += qty（order_item_id 非空时）</li>
 *   <li>{@link ArApLedgerService#postArAp} 立应收（AR, SALES_SHIPMENT, BStyle=3, 正应收）</li>
 *   <li>ar_posted=true</li>
 *   <li>重算受影响订货单 is_closed</li>
 * </ol>
 *
 * <p>红冲（1→-1）同事务反向：先 {@link ArApLedgerService#reverseArAp}（钱流校验无收款核销，否则抛
 * "此单已经存在收款，请先反审收款单!"，对齐老库 RAISERROR）→ 反向库存 + 回减 shipped_qty + 结案重算 + ar_posted=false。
 *
 * <p>取代老库 S_Out 触发器 TRI_SOStockItem（库存段）+ 钱流立 M_in 段（design 20 §〇/§4.3）。
 */
@Service
@RequiredArgsConstructor
public class SalesShipmentService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 老库 BStyle=3 销售出货正应收。 */
    private static final short BSTYLE_SALES_SHIPMENT = 3;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    private final SalesShipmentRepository shipmentRepo;
    private final SalesShipmentItemRepository itemRepo;
    private final StockService stockService;
    private final ArApLedgerService arApService;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final DocNumberService docNumberService;

    @Transactional(readOnly = true)
    public PageResponse<ShipmentListItem> list(ShipmentQueryFilter f, int page, int size, String sort, String order) {
        Specification<SalesShipment> spec = (Root<SalesShipment> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                             CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
            }
            if (f.clientId() != null) ps.add(cb.equal(root.get("clientId"), f.clientId()));
            if (f.warehouseId() != null) ps.add(cb.equal(root.get("warehouseId"), f.warehouseId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.arPosted() != null) ps.add(cb.equal(root.get("arPosted"), f.arPosted()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<SalesShipment> p = shipmentRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public ShipmentDetail detail(UUID id) {
        SalesShipment s = requireShipment(id);
        List<ShipmentItemDto> items = itemRepo.findByShipmentIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(s, items);
    }

    @Transactional
    public ShipmentDetail create(ShipmentSaveRequest req) {
        tx.bind();
        SalesShipment s = new SalesShipment();
        applyHeader(req, s);
        s.setStatus(STATUS_DRAFT);
        shipmentRepo.save(s);
        List<ShipmentItemDto> items = saveItems(s, req.getItems());
        applyTotals(s, items);
        return toDetail(s, items);
    }

    @Transactional
    public ShipmentDetail update(UUID id, ShipmentSaveRequest req) {
        tx.bind();
        SalesShipment s = requireShipment(id);
        if (s.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        applyHeader(req, s);
        itemRepo.deleteByShipmentId(id);
        itemRepo.flush();
        List<ShipmentItemDto> items = saveItems(s, req.getItems());
        applyTotals(s, items);
        return toDetail(s, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        SalesShipment s = requireShipment(id);
        if (s.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        s.setDeleted(true);
        s.setDeletedAt(OffsetDateTime.now());
        shipmentRepo.save(s);
    }

    /** 审核：status 0→1，库存出库 + 回写订货 shipped_qty + 立应收 + 结案重算。 */
    @Transactional
    public ShipmentDetail approve(UUID id) {
        tx.bind();
        SalesShipment s = requireShipment(id);
        if (s.getStatus() == null || s.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (s.getWarehouseId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "出货单需指定仓库");
        }
        if (s.getClientId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "出货单需指定客户");
        }
        List<SalesShipmentItem> items = itemRepo.findByShipmentIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }

        OffsetDateTime now = OffsetDateTime.now();
        for (SalesShipmentItem it : items) {
            applyMovement(s, it, StockService.DIR_OUT, now, null);
            if (it.getOrderItemId() != null) {
                addShippedQty(it.getOrderItemId(), it.getQty()); // +qty
                recalcOrderClosed(it.getOrderItemId());
            }
        }

        // 立应收（AR, SALES_SHIPMENT, BStyle=3, 正应收）。金额为本币总额（正数）。
        if (!s.isArPosted()) {
            arApService.postArAp(new ArApPostingRequest(
                    "AR",
                    StockService.SRC_SALES_SHIPMENT,
                    s.getId(), s.getBillNo(), s.getBillDate(),
                    s.getClientId(), null,
                    s.getCurrencyId(), s.getExchangeRate(),
                    s.getTotalLocal(),
                    BSTYLE_SALES_SHIPMENT,
                    s.getRemark()));
            s.setArPosted(true);
        }

        s.setStatus(STATUS_APPROVED);
        s.setLastDate(now);
        shipmentRepo.save(s);
        return detail(id);
    }

    /** 红冲：status 1→-1，先校验收款核销 → 反向库存 + 回减 shipped_qty + 结案重算 + ar_posted=false。 */
    @Transactional
    public ShipmentDetail reverse(UUID id) {
        tx.bind();
        SalesShipment s = requireShipment(id);
        if (s.getStatus() == null || s.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }

        // 1. 钱流先校验：若已有收款核销 → reverseArAp 抛 IllegalStateException（阻止红冲）
        if (s.isArPosted()) {
            arApService.reverseArAp(s.getId(), StockService.SRC_SALES_SHIPMENT);
            s.setArPosted(false);
        }

        // 2. 反向库存（type=3 dir=+1 倒回）+ 回减 shipped_qty
        // 反向只翻 direction；amountLocal 必须传正数（StockService.recordMovement 内部乘 direction 取符号）。
        // 若再 negate() 金额 → (-amt)×(+1) 与原 (+amt)×(-1) 同号 → 库存金额无法回滚（design §一决策）。
        List<SalesShipmentItem> items = itemRepo.findByShipmentIdOrderByLineNoAsc(id);
        OffsetDateTime now = OffsetDateTime.now();
        for (SalesShipmentItem it : items) {
            applyMovement(s, it, StockService.DIR_IN, now, null);
            if (it.getOrderItemId() != null) {
                addShippedQty(it.getOrderItemId(), it.getQty().negate()); // -qty
                recalcOrderClosed(it.getOrderItemId());
            }
        }

        s.setStatus(STATUS_REVERSED);
        shipmentRepo.save(s);
        return detail(id);
    }

    /** 写一笔库存流水（方向由调用方给）。qty 为明细量，baseQty = qty×unit_rate。 */
    private void applyMovement(SalesShipment s, SalesShipmentItem it, short direction,
                               OffsetDateTime ts, BigDecimal overrideAmount) {
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        BigDecimal baseQty = it.getQty().multiply(rate);
        BigDecimal amt = overrideAmount != null ? overrideAmount : it.getAmountLocal();
        stockService.recordMovement(new StockService.MovementRequest(
                ts, StockService.TYPE_SALES_OUT, StockService.SRC_SALES_SHIPMENT,
                s.getId(), it.getId(), it.getGoodsId(), it.getColorId(), s.getWarehouseId(),
                direction, baseQty, it.getUnitId(), it.getUnitRate(), amt,
                direction < 0 ? null : "红冲"));
    }

    /** sales_order_items.shipped_qty += delta（delta=±qty）。 */
    private void addShippedQty(UUID orderItemId, BigDecimal delta) {
        em.createNativeQuery(
                "UPDATE sales_order_items SET shipped_qty = COALESCE(shipped_qty,0) + :d WHERE id = :id")
                .setParameter("d", delta)
                .setParameter("id", orderItemId)
                .executeUpdate();
    }

    /** 重算订货单结案：所有明细 qty - shipped_qty + returned_qty - flag_qty ≤ 0 → is_closed=true。 */
    private void recalcOrderClosed(UUID orderItemId) {
        em.createNativeQuery("""
                UPDATE sales_orders o SET is_closed = (
                    SELECT COALESCE(bool_and(
                        COALESCE(i.qty,0) - COALESCE(i.shipped_qty,0)
                        + COALESCE(i.returned_qty,0) - COALESCE(i.flag_qty,0) <= 0
                    ), true)
                    FROM sales_order_items i
                    WHERE i.order_id = o.id AND COALESCE(i.is_deleted, false) = false
                ) WHERE o.id = (SELECT order_id FROM sales_order_items WHERE id = :iid)
                """).setParameter("iid", orderItemId).executeUpdate();
    }

    private void applyHeader(ShipmentSaveRequest req, SalesShipment s) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (s.getBillNo() == null || s.getBillNo().isBlank()) {
            s.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SALES_SHIPMENT));
        }
        s.setBillDate(req.getBillDate());
        s.setClientId(req.getClientId());
        s.setWarehouseId(req.getWarehouseId());
        s.setCurrencyId(req.getCurrencyId());
        s.setExchangeRate(req.getExchangeRate());
        s.setTaxRate(req.getTaxRate());
        s.setPaymentStyleId(req.getPaymentStyleId());
        s.setSellerId(req.getSellerId());
        s.setSenderId(req.getSenderId());
        s.setShipAddr(req.getShipAddr());
        s.setLinkPhone(req.getLinkPhone());
        s.setParcelCount(req.getParcelCount());
        s.setRemark(req.getRemark());
    }

    private List<ShipmentItemDto> saveItems(SalesShipment s, List<ShipmentItemLine> lines) {
        List<ShipmentItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (ShipmentItemLine l : lines) {
            SalesShipmentItem it = new SalesShipmentItem();
            it.setShipmentId(s.getId());
            it.setBillNo(s.getBillNo());
            it.setBillDate(s.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setOrderItemId(l.getOrderItemId());
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
            it.setCostAmount(l.getCostAmount());
            it.setWeight(l.getWeight());
            it.setParcelQty(l.getParcelQty());
            it.setCartonCount(l.getCartonCount());
            it.setClientNo(l.getClientNo());
            it.setClientModel(l.getClientModel());
            it.setMaterialPrice(l.getMaterialPrice());
            it.setDieCastPrice(l.getDieCastPrice());
            it.setMachiningPrice(l.getMachiningPrice());
            it.setCircumference(l.getCircumference());
            it.setDiscount(l.getDiscount());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    private void applyTotals(SalesShipment s, List<ShipmentItemDto> items) {
        BigDecimal local = items.stream()
                .map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream()
                .map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        s.setTotalLocal(local);
        s.setTotalOriginal(original);
        shipmentRepo.save(s);
    }

    private ShipmentListItem toList(SalesShipment s) {
        return new ShipmentListItem(s.getId(), s.getBillNo(), s.getBillDate(), s.getClientId(),
                s.getWarehouseId(), s.getTotalLocal(), s.getStatus(), s.isClosed(), s.isArPosted(), s.getLegacyId());
    }

    private ShipmentItemDto toItemDto(SalesShipmentItem it) {
        return new ShipmentItemDto(it.getId(), it.getLineNo(), it.getOrderItemId(), it.getGoodsId(),
                it.getColorId(), it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(),
                it.getAmountOriginal(), it.getAmountLocal(), it.getCostAmount(), it.getReturnedQty(),
                it.getReturnedAmount(), it.getWeight(), it.getParcelQty(), it.getCartonCount(),
                it.getClientNo(), it.getClientModel(), it.getMaterialPrice(), it.getDieCastPrice(),
                it.getMachiningPrice(), it.getCircumference(), it.getDiscount(), it.getSourceDocNo(),
                it.getRemark());
    }

    private ShipmentDetail toDetail(SalesShipment s, List<ShipmentItemDto> items) {
        return new ShipmentDetail(s.getId(), s.getLegacyId(), s.getBillNo(), s.getBillDate(),
                s.getClientId(), s.getWarehouseId(), s.getCurrencyId(), s.getExchangeRate(), s.getTaxRate(),
                s.getPaymentStyleId(), s.getSellerId(), s.getSenderId(), s.getMakerId(), s.getApproverId(),
                s.getShipAddr(), s.getLinkPhone(), s.getParcelCount(), s.getPrintCount(), s.getLastDate(),
                s.getRemark(), s.getTotalOriginal(), s.getTotalLocal(), s.getStatus(), s.isClosed(),
                s.getSourceDocNo(), s.isArPosted(), items);
    }

    private SalesShipment requireShipment(UUID id) {
        return shipmentRepo.findById(id).filter(s -> !s.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "销售出货单不存在"));
    }
}
