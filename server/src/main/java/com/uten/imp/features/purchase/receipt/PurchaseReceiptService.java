package com.uten.imp.features.purchase.receipt;

import com.uten.imp.application.port.ProcurementArrivalBlockedException;
import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.integrity.NonNegativeCommercialSignGuard;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy;
import com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy;
import com.uten.imp.features.purchase.receipt.dto.ReceiptDetail;
import com.uten.imp.features.purchase.receipt.dto.ReceiptItemDto;
import com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine;
import com.uten.imp.features.purchase.receipt.dto.ReceiptListItem;
import com.uten.imp.features.purchase.receipt.dto.ReceiptQueryFilter;
import com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.application.port.ProcurementInspectionPort;
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
 * 采购收货单服务：CRUD（主+明细）+ 审核状态机。
 *
 * <p>审核（status 0→1）：同事务内，逐明细 ① {@link StockService#recordMovement} 入库 ② 回写订货明细 received_qty
 * ③ 重算订货单 is_closed。红冲（1→-1）反向冲销。取代老库 P_In 触发器 TRI_PIStockItem。
 *
 * <p>明细独立仓库管理（不走主表 @OneToMany），update 时物理删旧+插新；total 由明细 amount_local 求和。
 */
@Service
@RequiredArgsConstructor
public class PurchaseReceiptService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    private final PurchaseReceiptRepository receiptRepo;
    private final PurchaseReceiptItemRepository itemRepo;
    private final StockService stockService;
    private final LinkedDocumentIntegrityService sourceIntegrity;
    private final ArApLedgerService arApService;
    private final ProductionSupplyTransitionPort productionSupply;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final EntityManager em;
    private final DocNumberService docNumberService;
    private final PurchaseLineUnitPolicy lineUnitPolicy;
    private final ProcurementArrivalControlPort arrivalControl;
    private final ProcurementInspectionPort inspectionService;
    private final PurchaseDocumentAccessPolicy access;

    @Transactional(readOnly = true)
    public PageResponse<ReceiptListItem> list(ReceiptQueryFilter f, int page, int size, String sort, String order) {
        var readScope = access.scope();
        Specification<PurchaseReceipt> spec = (Root<PurchaseReceipt> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
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
        // 列排序：sort 命中白名单(日期/金额)才按实体属性排序，否则默认 billDate DESC。
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"),
                        Map.of("billDate", "billDate", "total", "totalLocal")));
        Page<PurchaseReceipt> p = receiptRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public ReceiptDetail detail(UUID id) {
        PurchaseReceipt r = requireReceipt(id);
        access.requireReadable(r.getMakerId(), "采购收货单不存在");
        List<ReceiptItemDto> items = itemRepo.findByReceiptIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(r, items);
    }

    @Transactional
    public ReceiptDetail create(ReceiptSaveRequest req) {
        tx.bind();
        PurchaseReceipt r = new PurchaseReceipt();
        applyHeader(req, r);
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户
        r.setStatus(STATUS_DRAFT);
        receiptRepo.save(r);
        List<ReceiptItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public ReceiptDetail update(UUID id, ReceiptSaveRequest req) {
        tx.bind();
        PurchaseReceipt r = requireReceiptForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的采购收货单");
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
        PurchaseReceipt r = requireReceiptForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的采购收货单");
        if (r.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        receiptRepo.save(r);
    }

    /** 审核：status 0→1，库存入库 + 回写订货 received_qty + 结案重算。 */
    @Transactional(noRollbackFor = ProcurementArrivalBlockedException.class)
    public ReceiptDetail approve(UUID id) {
        tx.bind();
        productionSupply.lockPurchaseReceiptMutationDimensions(
                id);
        PurchaseReceipt r = requireReceiptForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的采购收货单");
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (r.getWarehouseId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "收货单需指定仓库");
        }
        List<PurchaseReceiptItem> items = itemRepo.findByReceiptIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        requireNonNegativeStoredCommercial(r, items);
        normalizePersistedItemUnits(items);
        sourceIntegrity.validatePurchaseReceipt(
                r.getSupplierId(),
                items.stream()
                        .map(it -> LinkedDocumentIntegrityService.LinkedLine.orderSource(
                                it.getOrderItemId(),
                                it.getGoodsId(),
                                it.getColorId(),
                                it.getUnitId(),
                                it.getUnitRate()))
                        .toList());
        arrivalControl.validateBeforeApproval(
                ProcurementArrivalControlPort.PURCHASE, id);
        productionSupply.lockReceiptProductionDemands(
                id, r.getWarehouseId());
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        OffsetDateTime now = OffsetDateTime.now();
        // V222 IQC：收货入待检隔离（不写 stock_balances）；合格处置（PASS）才进可用库存 + 唤醒生产。
        inspectionService.receive(ProcurementInspectionPort.PURCHASE, id, r.getWarehouseId(),
                items.stream().map(it -> new ProcurementInspectionPort.ReceivedLine(
                        it.getId(), it.getGoodsId(), it.getColorId(), it.getUnitId(),
                        it.getUnitRate(), it.getQty(), it.getAmountLocal())).toList(),
                now);
        for (PurchaseReceiptItem it : items) {
            if (it.getOrderItemId() != null) {
                em.createNativeQuery(
                        "UPDATE purchase_order_items SET received_qty = COALESCE(received_qty,0) + :q WHERE id = :id")
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getOrderItemId())
                        .executeUpdate();
                recalcOrderClosed(it.getOrderItemId());
            }
        }
        // 生产唤醒（onPurchaseReceiptApproved）推迟到 IQC 整单结案（ProcurementInspectionService.dispose）。
        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户
        receiptRepo.save(r);
        // 立应付（AP, PURCHASE_RECEIPT）：取代老库 P_In 触发器 TRI_PIStockItem 的 M_out 立帐分支。
        arApService.postArAp(new ArApLedgerService.ArApPostingRequest(
                "AP", StockService.SRC_PURCHASE_RECEIPT, r.getId(), r.getBillNo(), r.getBillDate(),
                null, r.getSupplierId(), r.getCurrencyId(), r.getExchangeRate(),
                r.getTotalLocal(), (short) 1, null));
        arrivalControl.recordApproval(
                ProcurementArrivalControlPort.PURCHASE, id);
        return detail(id);
    }

    /**
     * 红冲：status 1→-1，库存反向出库 + 回减订货 received_qty + 结案重算 + 反立应付。
     *
     * <p>顺序遵循 28-Java后端契约 §五：先 {@code reverseArAp}（若有核销 amount_settled&lt;&gt;0 抛
     * "此单已经存在收/付款，请先反审"），再做反向库存/回写。purchase_receipts 无 ar_posted 列，只调 Service。
     */
    @Transactional
    public ReceiptDetail reverse(UUID id) {
        tx.bind();
        productionSupply.lockPurchaseReceiptMutationDimensions(
                id);
        PurchaseReceipt r = requireReceiptForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的采购收货单");
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        List<PurchaseReceiptItem> items = itemRepo.findByReceiptIdOrderByLineNoAsc(id);
        requireNonNegativeStoredCommercial(r, items);
        if (items.stream().anyMatch(it ->
                it.getReturnedQty() != null && it.getReturnedQty().signum() > 0)) {
            throw new ApiException(ErrorCode.BUSINESS, "采购收货已有退货记录，请先红冲下游退货单");
        }
        // V222 IQC：红冲前须质检结案；反向由 inspection 服务按已放行量精确回退（无冻结行的历史单走全量）。
        inspectionService.requireResolvedForReverse(ProcurementInspectionPort.PURCHASE, id);
        productionSupply.beforePurchaseReceiptReversed(id);
        // KS-P1-2：先取库存 advisory 锁，再 reverseArAp 锁 AP 行——与 approve（先 lockInventory 后 postArAp）锁序一致，消除并发 approve vs reverse 死锁。
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        arApService.reverseArAp(r.getId(), StockService.SRC_PURCHASE_RECEIPT);
        OffsetDateTime now = OffsetDateTime.now();
        boolean inspectionManaged = inspectionService.reverseResolvedStock(
                ProcurementInspectionPort.PURCHASE, id, now);
        for (PurchaseReceiptItem it : items) {
            if (!inspectionManaged) {
                // 历史无 IQC 冻结行的单据：全量反向（兼容）。
                applyMovement(r, it, StockService.DIR_OUT, now, null);
            }
            if (it.getOrderItemId() != null) {
                em.createNativeQuery(
                        "UPDATE purchase_order_items SET received_qty = COALESCE(received_qty,0) - :q WHERE id = :id")
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getOrderItemId())
                        .executeUpdate();
                recalcOrderClosed(it.getOrderItemId());
            }
        }
        r.setStatus(STATUS_REVERSED);
        // The downstream refresh validates the source's terminal state via a
        // native query, so make that state visible before invoking the hook.
        receiptRepo.saveAndFlush(r);
        arrivalControl.recordReversal(
                ProcurementArrivalControlPort.PURCHASE, id);
        productionSupply.afterPurchaseReceiptReversed(id);
        return detail(id);
    }

    /** 写一笔库存流水（方向由调用方给）。qty 为明细量，baseQty = qty×unit_rate（基本单位）。 */
    private void applyMovement(PurchaseReceipt r, PurchaseReceiptItem it, short direction,
                               OffsetDateTime ts, BigDecimal overrideAmount) {
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        BigDecimal baseQty = it.getQty().multiply(rate);
        BigDecimal amt = overrideAmount != null ? overrideAmount : it.getAmountLocal();
        stockService.recordMovement(new StockService.MovementRequest(
                ts, StockService.TYPE_PURCHASE_RECEIPT, StockService.SRC_PURCHASE_RECEIPT,
                r.getId(), it.getId(), it.getGoodsId(), it.getColorId(), r.getWarehouseId(),
                direction, baseQty, it.getUnitId(), it.getUnitRate(), amt,
                direction < 0 ? "红冲" : null));
    }

    /** 重算订货单结案：所有明细 qty - received_qty + returned_qty ≤ 0 → is_closed=true。 */
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

    private void applyHeader(ReceiptSaveRequest req, PurchaseReceipt r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.PURCHASE_RECEIPT));
        }
        r.setBillDate(req.getBillDate());
        r.setSupplierId(req.getSupplierId());
        r.setWarehouseId(req.getWarehouseId());
        r.setCurrencyId(req.getCurrencyId());
        r.setExchangeRate(req.getExchangeRate());
        r.setTaxRate(req.getTaxRate());
        r.setSenderId(req.getSenderId());
        r.setReceiverId(req.getReceiverId());
        r.setRemark(req.getRemark());
    }

    private List<ReceiptItemDto> saveItems(PurchaseReceipt r, List<ReceiptItemLine> lines) {
        List<ReceiptItemDto> out = new ArrayList<>(lines.size());
        int autoLine = 1;
        for (ReceiptItemLine l : lines) {
            NonNegativeCommercialSignGuard.requireRequestLine(
                    "采购收货", l.getQty(), l.getPrice(),
                    l.getAmountOriginal(), l.getAmountLocal());
            int lineNo = l.getLineNo() != null ? l.getLineNo() : autoLine;
            PurchaseLineUnitPolicy.ResolvedUnit resolvedUnit =
                    lineUnitPolicy.normalizeAndValidate(
                            l.getGoodsId(), l.getUnitId(), l.getUnitRate(), lineNo);
            PurchaseReceiptItem it = new PurchaseReceiptItem();
            it.setReceiptId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(lineNo);
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setUnitId(resolvedUnit.unitId());
            it.setUnitRate(resolvedUnit.unitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
            it.setGiftQty(l.getGiftQty() != null ? l.getGiftQty() : BigDecimal.ZERO);
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

    private void normalizePersistedItemUnits(List<PurchaseReceiptItem> items) {
        int fallbackLineNo = 1;
        for (PurchaseReceiptItem item : items) {
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

    private static void requireNonNegativeStoredCommercial(
            PurchaseReceipt receipt, List<PurchaseReceiptItem> items) {
        NonNegativeCommercialSignGuard.requireStoredTotals(
                "采购收货", receipt.getTotalOriginal(), receipt.getTotalLocal());
        for (PurchaseReceiptItem item : items) {
            NonNegativeCommercialSignGuard.requireStoredLine(
                    "采购收货", item.getQty(), item.getPrice(),
                    item.getAmountOriginal(), item.getAmountLocal());
        }
    }

    private void applyTotals(PurchaseReceipt r, List<ReceiptItemDto> items) {
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

    private ReceiptListItem toList(PurchaseReceipt r) {
        return new ReceiptListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getSupplierId(),
                r.getWarehouseId(), r.getTotalLocal(), r.getStatus(), r.isClosed(), r.getLegacyId());
    }

    private ReceiptItemDto toItemDto(PurchaseReceiptItem it) {
        return new ReceiptItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getReturnedQty(), it.getGiftQty(), it.getWeight(),
                it.getOrderItemId(), it.getSourceDocNo(), it.getRemark());
    }

    private ReceiptDetail toDetail(PurchaseReceipt r, List<ReceiptItemDto> items) {
        return new ReceiptDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getSupplierId(), r.getWarehouseId(), r.getCurrencyId(), r.getExchangeRate(), r.getTaxRate(),
                r.getSenderId(), r.getReceiverId(), r.getMakerId(), r.getApproverId(), r.getRemark(),
                r.getTotalOriginal(), r.getTotalLocal(), r.getStatus(), r.isClosed(), r.getSourceDocNo(), items,
                nameResolver.nameOf(r.getMakerId()), r.getCreatedAt());
    }

    private PurchaseReceipt requireReceipt(UUID id) {
        return receiptRepo.findById(id)
                .filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "采购收货单不存在"));
    }
    private PurchaseReceipt requireReceiptForUpdate(UUID id) {
        PurchaseReceipt receipt = em.find(
                PurchaseReceipt.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        return receipt == null || receipt.isDeleted()
                ? requireReceipt(id)
                : receipt;
    }
}
