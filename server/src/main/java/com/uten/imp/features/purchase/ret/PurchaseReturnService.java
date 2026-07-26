package com.uten.imp.features.purchase.ret;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.purchase.ret.dto.ReturnDetail;
import com.uten.imp.features.purchase.ret.dto.ReturnItemDto;
import com.uten.imp.features.purchase.ret.dto.ReturnItemLine;
import com.uten.imp.features.purchase.ret.dto.ReturnListItem;
import com.uten.imp.features.purchase.ret.dto.ReturnQueryFilter;
import com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest;
import com.uten.imp.features.stock.StockService;
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
import java.util.UUID;

/**
 * 采购退货单服务：CRUD + 审核状态机。
 *
 * <p>审核（0→1）：库存出库（DIR_OUT）+ 回写收货明细 returned_qty + 回写订货明细 returned_qty
 *   + 重算订货单 is_closed。红冲（1→-1）反向入库。取代老库 P_Withdraw 触发器 TRI_PWStockItem。
 */
@Service
@RequiredArgsConstructor
public class PurchaseReturnService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    private final PurchaseReturnRepository returnRepo;
    private final PurchaseReturnItemRepository itemRepo;
    private final StockService stockService;
    private final ArApLedgerService arApService;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final EntityManager em;

    @Transactional(readOnly = true)
    public PageResponse<ReturnListItem> list(ReturnQueryFilter f, int page, int size) {
        Specification<PurchaseReturn> spec = (Root<PurchaseReturn> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
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
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.DESC, "billDate"));
        Page<PurchaseReturn> p = returnRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public ReturnDetail detail(UUID id) {
        PurchaseReturn r = requireReturn(id);
        List<ReturnItemDto> items = itemRepo.findByReturnIdOrderByLineNoAsc(id).stream().map(this::toItemDto).toList();
        return toDetail(r, items);
    }

    @Transactional
    public ReturnDetail create(ReturnSaveRequest req) {
        tx.bind();
        PurchaseReturn r = new PurchaseReturn();
        applyHeader(req, r);
        r.setMakerId(currentUser.requireId()); // 制单=当前登录用户
        r.setStatus(STATUS_DRAFT);
        returnRepo.save(r);
        List<ReturnItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public ReturnDetail update(UUID id, ReturnSaveRequest req) {
        tx.bind();
        PurchaseReturn r = requireReturn(id);
        if (r.getStatus() != STATUS_DRAFT) throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        applyHeader(req, r);
        itemRepo.deleteByReturnId(id);
        itemRepo.flush();
        List<ReturnItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        PurchaseReturn r = requireReturn(id);
        if (r.getStatus() == STATUS_APPROVED) throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        returnRepo.save(r);
    }

    /** 审核：库存出库 + 回写收货/订货明细 returned_qty + 订货结案重算。 */
    @Transactional
    public ReturnDetail approve(UUID id) {
        tx.bind();
        PurchaseReturn r = requireReturn(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT)
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        if (r.getWarehouseId() == null) throw new ApiException(ErrorCode.BUSINESS, "退货单需指定仓库");
        List<PurchaseReturnItem> items = itemRepo.findByReturnIdOrderByLineNoAsc(id);
        if (items.isEmpty()) throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        OffsetDateTime now = OffsetDateTime.now();
        for (PurchaseReturnItem it : items) {
            applyMovement(r, it, StockService.DIR_OUT, now, null);
            writeback(it, +1);
        }
        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireId()); // 审核=当前登录用户
        returnRepo.save(r);
        // 立红字应付（AP, PURCHASE_RETURN，金额取负 = 红冲 AP）：取代老库 P_Withdraw 触发器的 M_out 立帐分支。
        // 退货后 supplier 净应付 = 原收货应付 - 退货应付；报表 GROUP BY supplier 自动得出净额。
        BigDecimal returnLocal = r.getTotalLocal() == null ? BigDecimal.ZERO : r.getTotalLocal().negate();
        arApService.postArAp(new ArApLedgerService.ArApPostingRequest(
                "AP", StockService.SRC_PURCHASE_RETURN, r.getId(), r.getBillNo(), r.getBillDate(),
                null, r.getSupplierId(), r.getCurrencyId(), r.getExchangeRate(),
                returnLocal, (short) 17, null));
        return detail(id);
    }

    /**
     * 红冲：status 1→-1，反向入库 + 回减 returned_qty + 结案重算 + 反立红字应付。
     *
     * <p>顺序遵循 28-Java后端契约 §五：先 {@code reverseArAp}（核销校验），再反向库存/回写。
     */
    @Transactional
    public ReturnDetail reverse(UUID id) {
        tx.bind();
        PurchaseReturn r = requireReturn(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        arApService.reverseArAp(r.getId(), StockService.SRC_PURCHASE_RETURN);
        OffsetDateTime now = OffsetDateTime.now();
        for (PurchaseReturnItem it : itemRepo.findByReturnIdOrderByLineNoAsc(id)) {
            applyMovement(r, it, StockService.DIR_IN, now, null);
            writeback(it, -1);
        }
        r.setStatus(STATUS_REVERSED);
        returnRepo.save(r);
        return detail(id);
    }

    private void applyMovement(PurchaseReturn r, PurchaseReturnItem it, short direction, OffsetDateTime ts, BigDecimal overrideAmount) {
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        BigDecimal baseQty = it.getQty().multiply(rate);
        BigDecimal amt = overrideAmount != null ? overrideAmount : it.getAmountLocal();
        stockService.recordMovement(new StockService.MovementRequest(
                ts, StockService.TYPE_PURCHASE_RETURN, StockService.SRC_PURCHASE_RETURN,
                r.getId(), it.getId(), it.getGoodsId(), it.getColorId(), r.getWarehouseId(),
                direction, baseQty, it.getUnitId(), it.getUnitRate(), amt,
                direction < 0 ? "红冲" : null));
    }

    /** sign=+1 审核（returned_qty += qty）/ sign=-1 红冲（returned_qty -= qty）。 */
    private void writeback(PurchaseReturnItem it, int sign) {
        if (it.getReceiptItemId() != null) {
            em.createNativeQuery(
                    "UPDATE purchase_receipt_items SET returned_qty = COALESCE(returned_qty,0) + (:q * :s) WHERE id = :id")
                    .setParameter("q", it.getQty()).setParameter("s", sign)
                    .setParameter("id", it.getReceiptItemId()).executeUpdate();
        }
        if (it.getOrderItemId() != null) {
            em.createNativeQuery(
                    "UPDATE purchase_order_items SET returned_qty = COALESCE(returned_qty,0) + (:q * :s) WHERE id = :id")
                    .setParameter("q", it.getQty()).setParameter("s", sign)
                    .setParameter("id", it.getOrderItemId()).executeUpdate();
            recalcOrderClosed(it.getOrderItemId());
        }
    }

    private void recalcOrderClosed(UUID orderItemId) {
        em.createNativeQuery("""
                UPDATE purchase_orders o SET is_closed = (
                    SELECT COALESCE(bool_and(
                        COALESCE(i.qty,0) - COALESCE(i.received_qty,0) + COALESCE(i.returned_qty,0) <= 0
                    ), true)
                    FROM purchase_order_items i
                    WHERE i.order_id = o.id AND COALESCE(i.is_deleted, false) = false
                ) WHERE o.id = (SELECT order_id FROM purchase_order_items WHERE id = :iid)
                """).setParameter("iid", orderItemId).executeUpdate();
    }

    private void applyHeader(ReturnSaveRequest req, PurchaseReturn r) {
        r.setBillNo(req.getBillNo());
        r.setBillDate(req.getBillDate());
        r.setSupplierId(req.getSupplierId());
        r.setWarehouseId(req.getWarehouseId());
        r.setCurrencyId(req.getCurrencyId());
        r.setExchangeRate(req.getExchangeRate());
        r.setTaxRate(req.getTaxRate());
        r.setReceiverId(req.getReceiverId());
        r.setRemark(req.getRemark());
    }

    private List<ReturnItemDto> saveItems(PurchaseReturn r, List<ReturnItemLine> lines) {
        List<ReturnItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (ReturnItemLine l : lines) {
            PurchaseReturnItem it = new PurchaseReturnItem();
            it.setReturnId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
            it.setReceiptItemId(l.getReceiptItemId());
            it.setOrderItemId(l.getOrderItemId());
            it.setWeight(l.getWeight());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    private void applyTotals(PurchaseReturn r, List<ReturnItemDto> items) {
        BigDecimal local = items.stream().map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream().map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        r.setTotalLocal(local);
        r.setTotalOriginal(original);
        returnRepo.save(r);
    }

    private ReturnListItem toList(PurchaseReturn r) {
        return new ReturnListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getSupplierId(),
                r.getWarehouseId(), r.getTotalLocal(), r.getStatus(), r.getLegacyId());
    }

    private ReturnItemDto toItemDto(PurchaseReturnItem it) {
        return new ReturnItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getReceiptItemId(), it.getOrderItemId(), it.getWeight(),
                it.getSourceDocNo(), it.getRemark());
    }

    private ReturnDetail toDetail(PurchaseReturn r, List<ReturnItemDto> items) {
        return new ReturnDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getSupplierId(), r.getWarehouseId(), r.getCurrencyId(), r.getExchangeRate(), r.getTaxRate(),
                r.getReceiverId(), r.getMakerId(), r.getApproverId(), r.getRemark(),
                r.getTotalOriginal(), r.getTotalLocal(), r.getStatus(), r.isClosed(), r.getSourceDocNo(), items);
    }

    private PurchaseReturn requireReturn(UUID id) {
        return returnRepo.findById(id).filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "采购退货单不存在"));
    }
}
