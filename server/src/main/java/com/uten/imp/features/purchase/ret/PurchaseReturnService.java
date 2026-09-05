package com.uten.imp.features.purchase.ret;

import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.integrity.NonNegativeCommercialSignGuard;
import com.uten.imp.common.finance.ProcurementOrderClosurePolicy;
import com.uten.imp.common.finance.ProcurementReturnHeaderAuthority;
import com.uten.imp.common.finance.ProcurementReturnQualityPolicy;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.payables.SupplierPaymentTermService;
import com.uten.imp.features.finance.payables.SupplierPeriodIdentityGuard;
import com.uten.imp.features.finance.payables.SupplierPeriodIdentityGuard.SourceTable;
import com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy;
import com.uten.imp.features.purchase.PurchaseGoodsSnapshot;
import com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy;
import com.uten.imp.features.purchase.ret.dto.ReturnDetail;
import com.uten.imp.features.purchase.ret.dto.ReturnItemDto;
import com.uten.imp.features.purchase.ret.dto.ReturnItemLine;
import com.uten.imp.features.purchase.ret.dto.ReturnListItem;
import com.uten.imp.features.purchase.ret.dto.ReturnQueryFilter;
import com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest;
import com.uten.imp.security.CommercialPriceVisibility;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 采购退货单服务：CRUD + 审核状态机。
 *
 * <p>审核（0→1）：库存出库（DIR_OUT）+ 回写收货明细 returned_qty + 回写订货明细 returned_qty
 *   + 重算订货单 is_closed。红冲（1→-1）反向入库。
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
    private final LinkedDocumentIntegrityService sourceIntegrity;
    private final PurchaseReturnAmountAuthority returnAmountAuthority;
    private final ArApLedgerService arApService;
    private final SupplierPaymentTermService paymentTerms;
    private final SupplierPeriodIdentityGuard periodIdentityGuard;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final EntityManager em;
    // V476：叶子仓落库校验。字段注入+可空——单测手工构造时缺省跳过，Spring 环境恒注入。
    @org.springframework.beans.factory.annotation.Autowired(required = false)
    private com.uten.imp.features.master.warehouse.WarehouseScopeService warehouseScopes;
    private final DocNumberService docNumberService;
    private final PurchaseLineUnitPolicy lineUnitPolicy;
    private final ProcurementArrivalControlPort arrivalControl;
    private final PurchaseDocumentAccessPolicy access;

    @Autowired
    private CommercialPriceVisibility commercialPriceVisibility;

    @Transactional(readOnly = true)
    public PageResponse<ReturnListItem> list(ReturnQueryFilter f, int page, int size, String sort, String order) {
        boolean priceMasked = purchasePriceMasked();
        var readScope = access.scope();
        Specification<PurchaseReturn> spec = (Root<PurchaseReturn> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
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
                        priceMasked
                                ? Map.of("billDate", "billDate")
                                : Map.of("billDate", "billDate", "total", "totalLocal")));
        Page<PurchaseReturn> p = returnRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(row -> toList(row, priceMasked)).getContent(),
                page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public ReturnDetail detail(UUID id) {
        PurchaseReturn r = requireReturn(id);
        access.requireReadable(r.getMakerId(), "采购退货单不存在");
        List<ReturnItemDto> items = itemRepo.findByReturnIdOrderByLineNoAsc(id).stream().map(this::toItemDto).toList();
        return toDetail(r, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('purchase_return:create')")
    public ReturnDetail create(ReturnSaveRequest req) {
        tx.bind();
        PurchaseReturn r = new PurchaseReturn();
        applyHeader(req, r, returnHeader(req));
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户
        r.setStatus(STATUS_DRAFT);
        returnRepo.save(r);
        List<ReturnItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('purchase_return:edit')")
    public ReturnDetail update(UUID id, ReturnSaveRequest req) {
        tx.bind();
        PurchaseReturn r = requireReturnForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的采购退货单");
        if (r.getStatus() != STATUS_DRAFT) throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        applyHeader(req, r, returnHeader(req));
        itemRepo.deleteByReturnId(id);
        itemRepo.flush();
        List<ReturnItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('purchase_return:delete')")
    public void delete(UUID id) {
        tx.bind();
        PurchaseReturn r = requireReturnForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的采购退货单");
        com.uten.imp.common.web.StandardDocumentLifecycleCapabilities.requireDraftForDelete(r.getStatus());
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        returnRepo.save(r);
    }

    /** 审核：库存出库 + 回写收货/订货明细 returned_qty + 订货结案重算。 */
    @Transactional
    @PreAuthorize("hasAuthority('purchase_return:approve')")
    public ReturnDetail approve(UUID id) {
        tx.bind();
        SupplierPeriodIdentityGuard.Identity periodIdentity =
        periodIdentityGuard.requireIdentity(SourceTable.PURCHASE_RETURN, id);
        periodIdentityGuard.requireOpenAtBillDate(periodIdentity, "采购退货审核");
        PurchaseReturn r = requireReturnForUpdate(id);
        periodIdentityGuard.requireUnchanged(
                r.getSupplierId(), r.getCurrencyId(), r.getBillDate(),
                periodIdentity);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的采购退货单");
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT)
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        if (r.getWarehouseId() == null) throw new ApiException(ErrorCode.BUSINESS, "退货单需指定仓库");
        List<PurchaseReturnItem> items = itemRepo.findByReturnIdOrderByLineNoAsc(id);
        if (items.isEmpty()) throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        ProcurementReturnQualityPolicy.lockInspectionRows(
                em,
                "PURCHASE",
                items.stream().map(PurchaseReturnItem::getReceiptItemId).toList());
        requireNonNegativeStoredCommercial(r, items);
        normalizePersistedItemUnits(items);
        sourceIntegrity.validatePurchaseReturn(
                r.getSupplierId(),
                items.stream()
                        .map(it -> LinkedDocumentIntegrityService.LinkedLine.receiptSource(
                                it.getReceiptItemId(),
                                it.getOrderItemId(),
                                it.getGoodsId(),
                                it.getColorId(),
                                it.getUnitId(),
                                it.getUnitRate()))
                        .toList());
        returnAmountAuthority.apply(r, items);
        // 应用层容量校验（友好 409）：退量 ≤ 来源收货行「已收 − 已退」。行已被上方
        // FOR UPDATE 锁定到本事务结束，并发两张退货单按提交顺序串行校验；
        // V132 DB 触发器仍是最终守卫（此处只把 500 变成可读的业务提示）。
        requireReceiptReturnCapacity(items);
        captureGoodsSnapshots(
                items,
                PurchaseGoodsSnapshot.RECEIPT_ITEM_AT_APPROVAL,
                PurchaseGoodsSnapshot.ORDER_ITEM_AT_APPROVAL,
                PurchaseGoodsSnapshot.MASTER_AT_APPROVAL,
                OffsetDateTime.now());
        OffsetDateTime now = OffsetDateTime.now();
        for (PurchaseReturnItem it : items) {
            applyMovement(r, it, StockService.DIR_OUT, now, null);
            writeback(it, +1);
        }
        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户
        returnRepo.save(r);
        // 立红字应付（AP, PURCHASE_RETURN，金额取负 = 红冲 AP）。
        // 退货后 supplier 净应付 = 原收货应付 - 退货应付；报表 GROUP BY supplier 自动得出净额。
        BigDecimal returnLocal = r.getTotalLocal() == null
                ? BigDecimal.ZERO : r.getTotalLocal().negate();
        BigDecimal returnOriginal = r.getTotalOriginal() == null
                ? BigDecimal.ZERO : r.getTotalOriginal().negate();
        LocalDate dueDate = paymentTerms.resolveDueDate(
                r.getSupplierId(), r.getSettlementMethodId(), r.getBillDate());
        arApService.postArAp(new ArApLedgerService.ArApPostingRequest(
                "AP", StockService.SRC_PURCHASE_RETURN, r.getId(), r.getBillNo(), r.getBillDate(),
                null, r.getSupplierId(), r.getCurrencyId(), r.getExchangeRate(),
                returnLocal, (short) 17, null, returnOriginal, dueDate,
                r.getSettlementStyleLegacy(), List.of(), r.getSettlementMethodId()));
        arrivalControl.refreshAfterReturn(ProcurementArrivalControlPort.PURCHASE,
                items.stream().map(PurchaseReturnItem::getOrderItemId).toList());
        return detail(id);
    }

    /**
     * 红冲：status 1→-1，反向入库 + 回减 returned_qty + 结案重算 + 反立红字应付。
     *
     * <p>顺序遵循 28-Java后端契约 §五：先 {@code reverseArAp}（核销校验），再反向库存/回写。
     */
    @Transactional
    @PreAuthorize("hasAuthority('purchase_return:reverse')")
    public ReturnDetail reverse(UUID id) {
        tx.bind();
        SupplierPeriodIdentityGuard.Identity periodIdentity =
        periodIdentityGuard.requireIdentity(SourceTable.PURCHASE_RETURN, id);
        periodIdentityGuard.requireOpenToday(periodIdentity, "采购退货红冲");
        PurchaseReturn r = requireReturnForUpdate(id);
        periodIdentityGuard.requireUnchanged(
                r.getSupplierId(), r.getCurrencyId(), r.getBillDate(),
                periodIdentity);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的采购退货单");
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        List<PurchaseReturnItem> items = itemRepo.findByReturnIdOrderByLineNoAsc(id);
        requireNonNegativeStoredCommercial(r, items);
        // KS-P1-2：先取库存 advisory 锁，再 reverseArAp 锁 AP 行——与 approve（先 lockInventory 后 postArAp）锁序一致。
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        arApService.reverseArAp(r.getId(), StockService.SRC_PURCHASE_RETURN);
        OffsetDateTime now = OffsetDateTime.now();
        for (PurchaseReturnItem it : items) {
            applyMovement(r, it, StockService.DIR_IN, now, null);
            writeback(it, -1);
        }
        r.setStatus(STATUS_REVERSED);
        returnRepo.save(r);
        arrivalControl.refreshAfterReturn(ProcurementArrivalControlPort.PURCHASE,
                items.stream().map(PurchaseReturnItem::getOrderItemId).toList());
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
                direction < 0 ? "红冲" : null, it.getWeight()));
    }

    /** 逐行校验退量不超过来源收货明细可退余量（已收 − 已退），超退给业务 409。 */
    private void requireReceiptReturnCapacity(List<PurchaseReturnItem> items) {
        for (PurchaseReturnItem it : items) {
            if (it.getReceiptItemId() == null) continue;
            Object[] row = (Object[]) em.createNativeQuery("""
                            SELECT COALESCE(qty, 0), COALESCE(returned_qty, 0)
                            FROM purchase_receipt_items
                            WHERE id = :id
                            """)
                    .setParameter("id", it.getReceiptItemId())
                    .getSingleResult();
            BigDecimal capacity = ((BigDecimal) row[0]).subtract((BigDecimal) row[1]);
            if (it.getQty() != null && it.getQty().compareTo(capacity) > 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "第 " + it.getLineNo() + " 行退货数量超过来源收货明细可退余量(已收 − 已退 = "
                                + capacity.stripTrailingZeros().toPlainString() + ")，禁止超退");
            }
        }
    }

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
        ProcurementOrderClosurePolicy.recalculate(
                em, ProcurementOrderClosurePolicy.PURCHASE, orderItemId);
    }

    private ProcurementReturnHeaderAuthority.Header returnHeader(ReturnSaveRequest req) {
        return ProcurementReturnHeaderAuthority.derive(
                em,
                "PURCHASE",
                req == null || req.getItems() == null ? List.of()
                        : req.getItems().stream()
                            .map(ReturnItemLine::getReceiptItemId).toList());
    }

    private void applyHeader(
            ReturnSaveRequest req,
            PurchaseReturn r,
            ProcurementReturnHeaderAuthority.Header header) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.PURCHASE_RETURN));
        }
        r.setBillDate(req.getBillDate());
        r.setSupplierId(header.supplierId());
        // V476 运营红线：退回出库必须落到具体叶子仓。
        if (warehouseScopes != null) {
            warehouseScopes.requireLeafWarehouse(req.getWarehouseId(), "仓库");
        }
        r.setWarehouseId(req.getWarehouseId());
        r.setCurrencyId(header.currencyId());
        r.setExchangeRate(header.exchangeRate());
        r.setTaxRate(header.taxRate());
        r.setReceiverId(req.getReceiverId());
        r.setSettlementMethodId(header.settlementMethodId());
        r.setSettlementStyleLegacy(header.settlementStyleLegacy() == null
                ? null : header.settlementStyleLegacy().shortValue());
        r.setRemark(req.getRemark());
    }

    private List<ReturnItemDto> saveItems(PurchaseReturn r, List<ReturnItemLine> lines) {
        List<ReturnItemDto> out = new ArrayList<>(lines.size());
        Map<UUID, PurchaseGoodsSnapshot> receiptSnapshots =
                PurchaseGoodsSnapshot.fromReceiptItems(
                        em,
                        lines.stream().map(ReturnItemLine::getReceiptItemId).toList(),
                        PurchaseGoodsSnapshot.RECEIPT_ITEM_AT_SAVE);
        Map<UUID, PurchaseGoodsSnapshot> orderSnapshots =
                PurchaseGoodsSnapshot.fromOrderItems(
                        em,
                        lines.stream().map(ReturnItemLine::getOrderItemId).toList(),
                        PurchaseGoodsSnapshot.ORDER_ITEM_AT_SAVE);
        Map<UUID, PurchaseGoodsSnapshot> masterSnapshots =
                PurchaseGoodsSnapshot.fromMaster(
                        em,
                        lines.stream().map(ReturnItemLine::getGoodsId).toList(),
                        PurchaseGoodsSnapshot.MASTER_AT_SAVE);
        int auto = 1;
        for (ReturnItemLine l : lines) {
            NonNegativeCommercialSignGuard.requireRequestLine(
                    "采购退货", l.getQty(), l.getPrice(),
                    l.getAmountOriginal(), l.getAmountLocal());
            int lineNo = l.getLineNo() != null ? l.getLineNo() : auto;
            PurchaseLineUnitPolicy.ResolvedUnit resolvedUnit =
                    lineUnitPolicy.normalizeAndValidate(
                            l.getGoodsId(), l.getUnitId(), l.getUnitRate(), lineNo);
            PurchaseReturnItem it = new PurchaseReturnItem();
            it.setReturnId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(lineNo);
            it.setGoodsId(l.getGoodsId());
            applyGoodsSnapshot(
                    it,
                    preferredGoodsSnapshot(
                            receiptSnapshots,
                            l.getReceiptItemId(),
                            orderSnapshots,
                            l.getOrderItemId(),
                            masterSnapshots,
                            l.getGoodsId()),
                    null);
            it.setColorId(l.getColorId());
            it.setUnitId(resolvedUnit.unitId());
            it.setUnitRate(resolvedUnit.unitRate());
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

    private void captureGoodsSnapshots(
            List<PurchaseReturnItem> items,
            String receiptSource,
            String orderSource,
            String masterSource,
            OffsetDateTime lockedAt) {
        Map<UUID, PurchaseGoodsSnapshot> receiptSnapshots =
                PurchaseGoodsSnapshot.fromReceiptItems(
                        em,
                        items.stream().map(PurchaseReturnItem::getReceiptItemId).toList(),
                        receiptSource);
        Map<UUID, PurchaseGoodsSnapshot> orderSnapshots =
                PurchaseGoodsSnapshot.fromOrderItems(
                        em,
                        items.stream().map(PurchaseReturnItem::getOrderItemId).toList(),
                        orderSource);
        Map<UUID, PurchaseGoodsSnapshot> masterSnapshots =
                PurchaseGoodsSnapshot.fromMaster(
                        em,
                        items.stream().map(PurchaseReturnItem::getGoodsId).toList(),
                        masterSource);
        for (PurchaseReturnItem item : items) {
            applyGoodsSnapshot(
                    item,
                    preferredGoodsSnapshot(
                            receiptSnapshots,
                            item.getReceiptItemId(),
                            orderSnapshots,
                            item.getOrderItemId(),
                            masterSnapshots,
                            item.getGoodsId()),
                    lockedAt);
        }
        itemRepo.saveAll(items);
        itemRepo.flush();
    }

    private static PurchaseGoodsSnapshot preferredGoodsSnapshot(
            Map<UUID, PurchaseGoodsSnapshot> receiptSnapshots,
            UUID receiptItemId,
            Map<UUID, PurchaseGoodsSnapshot> orderSnapshots,
            UUID orderItemId,
            Map<UUID, PurchaseGoodsSnapshot> masterSnapshots,
            UUID goodsId) {
        if (receiptItemId != null && receiptSnapshots.containsKey(receiptItemId)) {
            return PurchaseGoodsSnapshot.preferred(
                    receiptSnapshots,
                    receiptItemId,
                    masterSnapshots,
                    goodsId,
                    "采购退货明细");
        }
        return PurchaseGoodsSnapshot.preferred(
                orderSnapshots,
                orderItemId,
                masterSnapshots,
                goodsId,
                "采购退货明细");
    }

    private static void applyGoodsSnapshot(
            PurchaseReturnItem item,
            PurchaseGoodsSnapshot snapshot,
            OffsetDateTime lockedAt) {
        item.setGoodsCodeSnapshot(snapshot.code());
        item.setGoodsNameSnapshot(snapshot.name());
        item.setGoodsSnapshotSource(snapshot.source());
        item.setGoodsSnapshotLockedAt(lockedAt);
    }

    private void normalizePersistedItemUnits(List<PurchaseReturnItem> items) {
        int fallbackLineNo = 1;
        for (PurchaseReturnItem item : items) {
            int lineNo = item.getLineNo() != null ? item.getLineNo() : fallbackLineNo;
            PurchaseLineUnitPolicy.ResolvedUnit resolvedUnit =
                    lineUnitPolicy.normalizeAndValidate(
                            item.getGoodsId(), item.getUnitId(), item.getUnitRate(), lineNo);
            item.setUnitId(resolvedUnit.unitId());
            item.setUnitRate(resolvedUnit.unitRate());
            fallbackLineNo++;
        }
    }

    private static void requireNonNegativeStoredCommercial(
            PurchaseReturn purchaseReturn, List<PurchaseReturnItem> items) {
        NonNegativeCommercialSignGuard.requireStoredTotals(
                "采购退货", purchaseReturn.getTotalOriginal(), purchaseReturn.getTotalLocal());
        for (PurchaseReturnItem item : items) {
            NonNegativeCommercialSignGuard.requireStoredLine(
                    "采购退货", item.getQty(), item.getPrice(),
                    item.getAmountOriginal(), item.getAmountLocal());
        }
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

    private ReturnListItem toList(PurchaseReturn r, boolean priceMasked) {
        return new ReturnListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getSupplierId(),
                r.getWarehouseId(), priceMasked ? null : r.getTotalLocal(), r.getStatus(),
                r.getLegacyId(), priceMasked);
    }

    private ReturnItemDto toItemDto(PurchaseReturnItem it) {
        return new ReturnItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getReceiptItemId(), it.getOrderItemId(), it.getWeight(),
                it.getSourceDocNo(), it.getRemark());
    }

    private ReturnDetail toDetail(PurchaseReturn r, List<ReturnItemDto> items) {
        boolean priceMasked = purchasePriceMasked();
        List<ReturnItemDto> safeItems = priceMasked
                ? items.stream().map(PurchaseReturnService::maskItemPrices).toList()
                : items;
        return new ReturnDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getSupplierId(), r.getWarehouseId(), priceMasked ? null : r.getCurrencyId(),
                priceMasked ? null : r.getExchangeRate(), priceMasked ? null : r.getTaxRate(),
                r.getReceiverId(), priceMasked ? null : r.getSettlementMethodId(),
                priceMasked || r.getSettlementStyleLegacy() == null
                        ? null : r.getSettlementStyleLegacy().intValue(),
                r.getMakerId(), r.getApproverId(), r.getRemark(),
                priceMasked ? null : r.getTotalOriginal(), priceMasked ? null : r.getTotalLocal(),
                r.getStatus(), r.isClosed(), r.getSourceDocNo(), safeItems,
                nameResolver.nameOf(r.getMakerId()), r.getCreatedAt(), priceMasked);
    }

    private boolean purchasePriceMasked() {
        return commercialPriceVisibility == null
                || !commercialPriceVisibility.canViewPurchaseReturn();
    }

    private static ReturnItemDto maskItemPrices(ReturnItemDto it) {
        return new ReturnItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(), it.getUnitId(), it.getUnitRate(),
                it.getQty(), null, null, null, it.getReceiptItemId(), it.getOrderItemId(),
                it.getWeight(), it.getSourceDocNo(), it.getRemark());
    }


    private PurchaseReturn requireReturn(UUID id) {
        return returnRepo.findById(id).filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "采购退货单不存在"));
    }
    private PurchaseReturn requireReturnForUpdate(UUID id) {
        PurchaseReturn purchaseReturn = em.find(
                PurchaseReturn.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        return purchaseReturn == null || purchaseReturn.isDeleted()
                ? requireReturn(id)
                : purchaseReturn;
    }
}
