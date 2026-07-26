package com.uten.imp.features.subcontract.receipt;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.arap.ArApLedgerService.ArApPostingRequest;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.features.subcontract.receipt.dto.ReceiptDetail;
import com.uten.imp.features.subcontract.receipt.dto.ReceiptItemDto;
import com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine;
import com.uten.imp.features.subcontract.receipt.dto.ReceiptListItem;
import com.uten.imp.features.subcontract.receipt.dto.ReceiptQueryFilter;
import com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest;
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
 * 委外进仓单服务：CRUD（主+明细）+ 审核状态机。
 *
 * <p>审核（status 0→1，同事务内，对每条明细）：
 * <ol>
 *   <li>{@link StockService#recordMovement} {@code TYPE_SUBCONTRACT_RECEIPT=17, DIR_IN=+1}
 *       —— <b>正向入库（不照搬老库 QTY-= 反向）</b>，design doc 22 §一决策4</li>
 *   <li>回写订货明细 {@code subcontract_order_items.received_qty += qty}</li>
 *   <li>重算订货单 is_closed（{@code qty - received_qty + returned_qty ≤ 0}）</li>
 * </ol>
 * 立应付 {@link ArApLedgerService#postArAp}（AP, SUBCONTRACT_RECEIPT, +amount）+ 置 {@code ap_posted=true}。
 *
 * <p>红冲（1→-1）：先 {@link ArApLedgerService#reverseArAp}（已核销则抛 IllegalStateException 阻断），
 * 再反向 DIR_OUT + 回减 received_qty + 重算 is_closed + 置 {@code ap_posted=false}。
 *
 * <p>取代老库 E_In 触发器 TRI_EIStockItem（其 QTY-= 反向逻辑被本服务纠正为正向）。
 */
@Service
@RequiredArgsConstructor
public class SubcontractReceiptService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    private final SubcontractReceiptRepository receiptRepo;
    private final SubcontractReceiptItemRepository itemRepo;
    private final StockService stockService;
    private final ArApLedgerService arApService;
    private final TxSessionVars tx;
    private final EntityManager em;

    @Transactional(readOnly = true)
    public PageResponse<ReceiptListItem> list(ReceiptQueryFilter f, int page, int size) {
        Specification<SubcontractReceipt> spec = (Root<SubcontractReceipt> root,
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
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.DESC, "billDate"));
        Page<SubcontractReceipt> p = receiptRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public ReceiptDetail detail(UUID id) {
        SubcontractReceipt r = requireReceipt(id);
        List<ReceiptItemDto> items = itemRepo.findByReceiptIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(r, items);
    }

    @Transactional
    public ReceiptDetail create(ReceiptSaveRequest req) {
        tx.bind();
        SubcontractReceipt r = new SubcontractReceipt();
        applyHeader(req, r);
        r.setStatus(STATUS_DRAFT);
        receiptRepo.save(r);
        List<ReceiptItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public ReceiptDetail update(UUID id, ReceiptSaveRequest req) {
        tx.bind();
        SubcontractReceipt r = requireReceipt(id);
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        applyHeader(req, r);
        itemRepo.deleteByReceiptId(id);
        itemRepo.flush();
        List<ReceiptItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        SubcontractReceipt r = requireReceipt(id);
        if (r.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        receiptRepo.save(r);
    }

    /**
     * 审核：status 0→1，库存正向入库（DIR_IN）+ 回写订货 received_qty + 立应付 + ap_posted + 结案重算。
     * 关键纠偏：老库触发器写 QTY-=（减库存）是反的，新库按方向 +1 正向入库。design doc 22 §一决策4。
     */
    @Transactional
    public ReceiptDetail approve(UUID id) {
        tx.bind();
        SubcontractReceipt r = requireReceipt(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (r.getWarehouseId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "进仓单需指定仓库");
        }
        if (r.getSupplierId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "进仓单需指定委外商");
        }
        List<SubcontractReceiptItem> items = itemRepo.findByReceiptIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        OffsetDateTime now = OffsetDateTime.now();
        for (SubcontractReceiptItem it : items) {
            // ① 正向入库（关键：DIR_IN=+1，不照搬老库反向）
            applyMovement(r, it, StockService.DIR_IN, now, null);
            // ② 回写订货明细 received_qty + 重算订货单 is_closed
            if (it.getOrderItemId() != null) {
                em.createNativeQuery(
                        "UPDATE subcontract_order_items SET received_qty = COALESCE(received_qty,0) + :q WHERE id = :id")
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getOrderItemId())
                        .executeUpdate();
                recalcOrderClosed(it.getOrderItemId());
            }
        }
        // ③ 立应付（AP, SUBCONTRACT_RECEIPT, +amount）—— 金额为正
        postAp(r, totalLocalOf(items), +1);
        r.setStatus(STATUS_APPROVED);
        r.setApPosted(true);
        receiptRepo.save(r);
        return detail(id);
    }

    /** 红冲：status 1→-1，先 reverseArAp（已核销则抛错）→ 反向 DIR_OUT + 回减 received_qty + ap_posted=false。 */
    @Transactional
    public ReceiptDetail reverse(UUID id) {
        tx.bind();
        SubcontractReceipt r = requireReceipt(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        // 先反立帐（若有核销 amount_settled<>0 抛 IllegalStateException，对齐老库文案）
        arApService.reverseArAp(r.getId(), StockService.SRC_SUBCONTRACT_RECEIPT);
        List<SubcontractReceiptItem> items = itemRepo.findByReceiptIdOrderByLineNoAsc(id);
        OffsetDateTime now = OffsetDateTime.now();
        // 反向只翻 direction；amountLocal 传正数（StockService 内部乘 direction）。negate 会致金额符号不回滚。
        for (SubcontractReceiptItem it : items) {
            applyMovement(r, it, StockService.DIR_OUT, now, null);
            if (it.getOrderItemId() != null) {
                em.createNativeQuery(
                        "UPDATE subcontract_order_items SET received_qty = COALESCE(received_qty,0) - :q WHERE id = :id")
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getOrderItemId())
                        .executeUpdate();
                recalcOrderClosed(it.getOrderItemId());
            }
        }
        r.setStatus(STATUS_REVERSED);
        r.setApPosted(false);
        receiptRepo.save(r);
        return detail(id);
    }

    /** 写一笔库存流水（方向由调用方给）。qty 为明细量，baseQty = qty×unit_rate。 */
    private void applyMovement(SubcontractReceipt r, SubcontractReceiptItem it, short direction,
                               OffsetDateTime ts, BigDecimal overrideAmount) {
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        BigDecimal baseQty = it.getQty().multiply(rate);
        BigDecimal amt = overrideAmount != null ? overrideAmount : it.getAmountLocal();
        stockService.recordMovement(new StockService.MovementRequest(
                ts, StockService.TYPE_SUBCONTRACT_RECEIPT, StockService.SRC_SUBCONTRACT_RECEIPT,
                r.getId(), it.getId(), it.getGoodsId(), it.getColorId(), r.getWarehouseId(),
                direction, baseQty, it.getUnitId(), it.getUnitRate(), amt,
                direction < 0 ? "红冲" : null));
    }

    /** 立应付 AP。sign=+1 进仓（应付增加）/ sign=-1 退货（应付减少，金额转负）。 */
    private void postAp(SubcontractReceipt r, BigDecimal amount, int sign) {
        if (amount == null) return;
        BigDecimal signed = sign < 0 ? amount.negate() : amount;
        arApService.postArAp(new ArApPostingRequest(
                "AP",
                StockService.SRC_SUBCONTRACT_RECEIPT,
                r.getId(),
                r.getBillNo(),
                r.getBillDate(),
                null,                 // AR client，AP 传 null
                r.getSupplierId(),    // AP 落 supplier
                r.getCurrencyId(),
                r.getExchangeRate() == null ? BigDecimal.ONE : r.getExchangeRate(),
                signed,
                (short) 30,  // 老库 BStyle=30 委外进仓
                null));
    }

    private BigDecimal totalLocalOf(List<SubcontractReceiptItem> items) {
        return items.stream()
                .map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
    }

    /** 重算订货单结案：所有明细 qty - received_qty + returned_qty ≤ 0 → is_closed=true。 */
    private void recalcOrderClosed(UUID orderItemId) {
        em.createNativeQuery("""
                UPDATE subcontract_orders o SET is_closed = (
                    SELECT COALESCE(bool_and(
                        COALESCE(i.qty,0) - COALESCE(i.received_qty,0) + COALESCE(i.returned_qty,0) <= 0
                    ), true)
                    FROM subcontract_order_items i
                    WHERE i.order_id = o.id AND COALESCE(i.is_deleted, false) = false
                ) WHERE o.id = (SELECT order_id FROM subcontract_order_items WHERE id = :iid)
                """).setParameter("iid", orderItemId).executeUpdate();
    }

    private void applyHeader(ReceiptSaveRequest req, SubcontractReceipt r) {
        r.setBillNo(req.getBillNo());
        r.setBillDate(req.getBillDate());
        r.setSupplierId(req.getSupplierId());
        r.setWarehouseId(req.getWarehouseId());
        r.setCurrencyId(req.getCurrencyId());
        r.setExchangeRate(req.getExchangeRate());
        r.setTaxRate(req.getTaxRate());
        r.setSenderId(req.getSenderId());
        r.setLastDate(req.getLastDate());
        r.setRemark(req.getRemark());
    }

    private List<ReceiptItemDto> saveItems(SubcontractReceipt r, List<ReceiptItemLine> lines) {
        List<ReceiptItemDto> out = new ArrayList<>(lines.size());
        int autoLine = 1;
        for (ReceiptItemLine l : lines) {
            SubcontractReceiptItem it = new SubcontractReceiptItem();
            it.setReceiptId(r.getId());
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
            it.setCheckQty(l.getCheckQty());
            it.setOrderQty(l.getOrderQty());
            it.setOrderItemId(l.getOrderItemId());
            it.setWeight(l.getWeight());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            autoLine++;
        }
        return out;
    }

    private void applyTotals(SubcontractReceipt r, List<ReceiptItemDto> items) {
        BigDecimal local = items.stream()
                .map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream()
                .map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        r.setTotalLocal(local);
        r.setTotalOriginal(original);
        receiptRepo.save(r);
    }

    private ReceiptListItem toList(SubcontractReceipt r) {
        return new ReceiptListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getSupplierId(),
                r.getWarehouseId(), r.getTotalLocal(), r.getStatus(), r.isClosed(), r.isApPosted(), r.getLegacyId());
    }

    private ReceiptItemDto toItemDto(SubcontractReceiptItem it) {
        return new ReceiptItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getCheckQty(), it.getOrderQty(), it.getReturnedQty(), it.getWeight(),
                it.getOrderItemId(), it.getSourceDocNo(), it.getRemark());
    }

    private ReceiptDetail toDetail(SubcontractReceipt r, List<ReceiptItemDto> items) {
        return new ReceiptDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getSupplierId(), r.getWarehouseId(), r.getCurrencyId(), r.getExchangeRate(), r.getTaxRate(),
                r.getSenderId(), r.getMakerId(), r.getApproverId(), r.getLastDate(), r.isApPosted(), r.getRemark(),
                r.getTotalOriginal(), r.getTotalLocal(), r.getStatus(), r.isClosed(), r.getSourceDocNo(), items);
    }

    private SubcontractReceipt requireReceipt(UUID id) {
        return receiptRepo.findById(id)
                .filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "委外进仓单不存在"));
    }
}
