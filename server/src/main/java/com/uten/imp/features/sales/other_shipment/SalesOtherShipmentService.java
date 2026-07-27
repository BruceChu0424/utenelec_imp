package com.uten.imp.features.sales.other_shipment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentDetail;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentItemDto;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentItemLine;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentListItem;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentQueryFilter;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentSaveRequest;
import com.uten.imp.features.stock.StockService;
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
import java.util.Map;
import java.util.UUID;

/**
 * 其它出货单服务：CRUD + 审核状态机。
 *
 * <p>审核（status 0→1）：**仅**库存出库（TYPE_SALES_OTHER_OUT / DIR_OUT）。
 * <b>不</b>回写订单（即使 order_item_id 字段在，Service 不动它）；
 * <b>不</b>调 ArApService（不立应收）—— 尊重老库 TRI_OCStockItem 对应段已注释的语义
 * （design 20 §〇/§4.1）。红冲反向入库，无 ar 校验。
 *
 * <p>无 ar_posted 列；无 reverseArAp 调用。是销售四单据中约束最简的一类。
 */
@Service
@RequiredArgsConstructor
public class SalesOtherShipmentService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    private final SalesOtherShipmentRepository shipmentRepo;
    private final SalesOtherShipmentItemRepository itemRepo;
    private final StockService stockService;
    private final TxSessionVars tx;

    @Transactional(readOnly = true)
    public PageResponse<OtherShipmentListItem> list(OtherShipmentQueryFilter f, int page, int size, String sort, String order) {
        Specification<SalesOtherShipment> spec = (Root<SalesOtherShipment> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                                  CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
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
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public OtherShipmentDetail detail(UUID id) {
        SalesOtherShipment s = requireShipment(id);
        List<OtherShipmentItemDto> items = itemRepo.findByShipmentIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(s, items);
    }

    @Transactional
    public OtherShipmentDetail create(OtherShipmentSaveRequest req) {
        tx.bind();
        SalesOtherShipment s = new SalesOtherShipment();
        applyHeader(req, s);
        s.setStatus(STATUS_DRAFT);
        shipmentRepo.save(s);
        List<OtherShipmentItemDto> items = saveItems(s, req.getItems());
        applyTotals(s, items);
        return toDetail(s, items);
    }

    @Transactional
    public OtherShipmentDetail update(UUID id, OtherShipmentSaveRequest req) {
        tx.bind();
        SalesOtherShipment s = requireShipment(id);
        if (s.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        applyHeader(req, s);
        itemRepo.deleteByShipmentId(id);
        itemRepo.flush();
        List<OtherShipmentItemDto> items = saveItems(s, req.getItems());
        applyTotals(s, items);
        return toDetail(s, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        SalesOtherShipment s = requireShipment(id);
        if (s.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        s.setDeleted(true);
        s.setDeletedAt(OffsetDateTime.now());
        shipmentRepo.save(s);
    }

    /**
     * 审核：status 0→1，仅库存出库（TYPE_SALES_OTHER_OUT / DIR_OUT）。
     * 不回写订单、不立应收（design 20 §4.1）。client_id 可空（内部领用）。
     */
    @Transactional
    public OtherShipmentDetail approve(UUID id) {
        tx.bind();
        SalesOtherShipment s = requireShipment(id);
        if (s.getStatus() == null || s.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (s.getWarehouseId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "出货单需指定仓库");
        }
        List<SalesOtherShipmentItem> items = itemRepo.findByShipmentIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        OffsetDateTime now = OffsetDateTime.now();
        for (SalesOtherShipmentItem it : items) {
            applyMovement(s, it, StockService.DIR_OUT, now, null);
            // 刻意不回写 order_item_id（业务上不挂订单）
        }
        s.setStatus(STATUS_APPROVED);
        s.setLastDate(now);
        shipmentRepo.save(s);
        return detail(id);
    }

    /** 红冲：status 1→-1，反向入库（无 ar 校验，无回写）。 */
    @Transactional
    public OtherShipmentDetail reverse(UUID id) {
        tx.bind();
        SalesOtherShipment s = requireShipment(id);
        if (s.getStatus() == null || s.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        OffsetDateTime now = OffsetDateTime.now();
        // 反向只翻 direction；amountLocal 传正数（StockService 内部乘 direction）。negate 会致金额符号不回滚。
        for (SalesOtherShipmentItem it : itemRepo.findByShipmentIdOrderByLineNoAsc(id)) {
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
                direction < 0 ? null : "红冲"));
    }

    private void applyHeader(OtherShipmentSaveRequest req, SalesOtherShipment s) {
        s.setBillNo(req.getBillNo());
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
        s.setOutType(req.getOutType());
        s.setRemark(req.getRemark());
    }

    private List<OtherShipmentItemDto> saveItems(SalesOtherShipment s, List<OtherShipmentItemLine> lines) {
        List<OtherShipmentItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (OtherShipmentItemLine l : lines) {
            SalesOtherShipmentItem it = new SalesOtherShipmentItem();
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

    private void applyTotals(SalesOtherShipment s, List<OtherShipmentItemDto> items) {
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

    private OtherShipmentListItem toList(SalesOtherShipment s) {
        return new OtherShipmentListItem(s.getId(), s.getBillNo(), s.getBillDate(), s.getClientId(),
                s.getWarehouseId(), s.getOutType(), s.getTotalLocal(), s.getStatus(), s.isClosed(), s.getLegacyId());
    }

    private OtherShipmentItemDto toItemDto(SalesOtherShipmentItem it) {
        return new OtherShipmentItemDto(it.getId(), it.getLineNo(), it.getOrderItemId(), it.getGoodsId(),
                it.getColorId(), it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(),
                it.getAmountOriginal(), it.getAmountLocal(), it.getCostAmount(), it.getWeight(),
                it.getParcelQty(), it.getCartonCount(), it.getClientNo(), it.getClientModel(),
                it.getMaterialPrice(), it.getDieCastPrice(), it.getMachiningPrice(), it.getCircumference(),
                it.getDiscount(), it.getReturnedQty(), it.getReturnedAmount(), it.getSourceDocNo(),
                it.getRemark());
    }

    private OtherShipmentDetail toDetail(SalesOtherShipment s, List<OtherShipmentItemDto> items) {
        return new OtherShipmentDetail(s.getId(), s.getLegacyId(), s.getBillNo(), s.getBillDate(),
                s.getClientId(), s.getWarehouseId(), s.getCurrencyId(), s.getExchangeRate(), s.getTaxRate(),
                s.getPaymentStyleId(), s.getSellerId(), s.getSenderId(), s.getMakerId(), s.getApproverId(),
                s.getShipAddr(), s.getLinkPhone(), s.getParcelCount(), s.getPrintCount(), s.getLastDate(),
                s.getOutType(), s.getRemark(), s.getTotalOriginal(), s.getTotalLocal(), s.getStatus(),
                s.isClosed(), s.getSourceDocNo(), items);
    }

    private SalesOtherShipment requireShipment(UUID id) {
        return shipmentRepo.findById(id).filter(s -> !s.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "其它出货单不存在"));
    }
}
