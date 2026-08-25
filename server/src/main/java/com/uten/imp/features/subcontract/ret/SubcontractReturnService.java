package com.uten.imp.features.subcontract.ret;

import com.uten.imp.application.port.ProcurementArrivalControlPort;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.arap.ArApLedgerService.ArApPostingRequest;
import com.uten.imp.features.finance.payables.SupplierPaymentTermService;
import com.uten.imp.features.finance.payables.SupplierPeriodIdentityGuard;
import com.uten.imp.features.finance.payables.SupplierPeriodIdentityGuard.SourceTable;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.LinkedOrderReadGate;
import com.uten.imp.features.subcontract.SubcontractGoodsSnapshot;
import com.uten.imp.features.subcontract.SubcontractGoodsKeyword;
import com.uten.imp.features.subcontract.ret.dto.ReturnDetail;
import com.uten.imp.features.subcontract.ret.dto.ReturnItemDto;
import com.uten.imp.features.subcontract.ret.dto.ReturnItemLine;
import com.uten.imp.features.subcontract.ret.dto.ReturnListItem;
import com.uten.imp.features.subcontract.ret.dto.ReturnQueryFilter;
import com.uten.imp.features.subcontract.ret.dto.ReturnSaveRequest;
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
 * 委外退货单服务（包名 ret 避开 Java 关键字 return）：CRUD（主+明细）+ 审核状态机。
 *
 * <p>审核（status 0→1，同事务内，对每条明细）：
 * <ol>
 *   <li>{@link StockService#recordMovement} {@code TYPE_SUBCONTRACT_RETURN=18, DIR_OUT=-1}</li>
 *   <li>双回写：{@code receipt_items.returned_qty += qty} + {@code order_items.returned_qty += qty}</li>
 *   <li>重算订货单 is_closed</li>
 * </ol>
 * 立应付反向 {@link ArApLedgerService#postArAp}（AP, SUBCONTRACT_RETURN, <b>amount 取负</b>，
 * 冲减进仓单立的应付）+ 置 {@code ap_posted=true}。
 *
 * <p>红冲（1→-1）：先 {@link ArApLedgerService#reverseArAp}（已核销则抛 IllegalStateException），
 * 再反向 DIR_IN + 回减 returned_qty + 重算 is_closed + 置 {@code ap_posted=false}。
 *
 * <p>AP 反向策略：退货立一条<b>独立的负应付</b>（source_doc_id=退货单 id），与进仓单立的正应付
 * 自然相抵；不调进仓单的 reverseArAp（那是进仓单红冲专用入口）。
 */
@Service
@RequiredArgsConstructor
public class SubcontractReturnService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    private final SubcontractReturnRepository returnRepo;
    private final SubcontractReturnItemRepository itemRepo;
    private final StockService stockService;
    private final LinkedDocumentIntegrityService sourceIntegrity;
    private final SubcontractReturnAmountAuthority returnAmountAuthority;
    private final ArApLedgerService arApService;
    private final SupplierPaymentTermService paymentTerms;
    private final SupplierPeriodIdentityGuard periodIdentityGuard;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final DocNumberService docNumberService;
    private final ProcurementArrivalControlPort arrivalControl;
    private final SubcontractDocumentAccessPolicy access;
    private final com.uten.imp.features.subcontract.LinkedOrderReadGate linkedOrderReadGate;

    @Transactional(readOnly = true)
    public PageResponse<ReturnListItem> list(ReturnQueryFilter f, int page, int size, String sort, String order) {
        var readScope = access.scope();
        Specification<SubcontractReturn> spec = (Root<SubcontractReturn> root,
                                                 jakarta.persistence.criteria.CriteriaQuery<?> q,
                                                 CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(access.readablePredicate(root, cb, "makerId", readScope));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(SubcontractGoodsKeyword.predicate(
                        cb, q, root, SubcontractReturnItem.class, "returnId", f.keyword()));
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
        Page<SubcontractReturn> p = returnRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public ReturnDetail detail(UUID id) {
        SubcontractReturn r = requireReturn(id);
        // V304：仓库执行的退货单对关联订货单归属人只读放行（委外进度点击溯源）。
        linkedOrderReadGate.requireReadableViaOrder(
                r.getMakerId(), "委外退货单不存在", LinkedOrderReadGate.LinkedDocKind.RETURN, id);
        List<ReturnItemDto> items = itemRepo.findByReturnIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(r, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('subcontract_return:create')")
    public ReturnDetail create(ReturnSaveRequest req) {
        tx.bind();
        SubcontractReturn r = new SubcontractReturn();
        applyHeader(req, r);
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        canonicalizeMaker(r);
        r.setStatus(STATUS_DRAFT);
        returnRepo.save(r);
        List<ReturnItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('subcontract_return:edit')")
    public ReturnDetail update(UUID id, ReturnSaveRequest req) {
        tx.bind();
        SubcontractReturn r = requireReturnForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外退货单");
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        applyHeader(req, r);
        itemRepo.deleteByReturnId(id);
        itemRepo.flush();
        List<ReturnItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('subcontract_return:delete')")
    public void delete(UUID id) {
        tx.bind();
        SubcontractReturn r = requireReturnForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外退货单");
        com.uten.imp.common.web.StandardDocumentLifecycleCapabilities.requireDraftForDelete(r.getStatus());
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        returnRepo.save(r);
    }

    /**
     * 审核：0→1。库存出库（DIR_OUT）+ 双回写 returned_qty + 重算订货 is_closed + 反向立 AP（负金额）+ ap_posted。
     */
    @Transactional
    @PreAuthorize("hasAuthority('subcontract_return:approve')")
    public ReturnDetail approve(UUID id) {
        tx.bind();
        SupplierPeriodIdentityGuard.Identity periodIdentity =
        periodIdentityGuard.requireIdentity(SourceTable.SUBCONTRACT_RETURN, id);
        periodIdentityGuard.requireOpenAtBillDate(periodIdentity, "委外退货审核");
        SubcontractReturn r = requireReturnForUpdate(id);
        periodIdentityGuard.requireUnchanged(
                r.getSupplierId(), r.getCurrencyId(), r.getBillDate(),
                periodIdentity);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外退货单");
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (r.getWarehouseId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "退货单需指定仓库");
        }
        if (r.getSupplierId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "退货单需指定委外商");
        }
        List<SubcontractReturnItem> items = itemRepo.findByReturnIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        sourceIntegrity.validateSubcontractReturn(
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
        captureGoodsSnapshots(
                items,
                SubcontractGoodsSnapshot.RECEIPT_ITEM_AT_APPROVAL,
                SubcontractGoodsSnapshot.ORDER_ITEM_AT_APPROVAL,
                SubcontractGoodsSnapshot.MASTER_AT_APPROVAL,
                OffsetDateTime.now());
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        OffsetDateTime now = OffsetDateTime.now();
        for (SubcontractReturnItem it : items) {
            // ① 出库（DIR_OUT=-1）
            applyMovement(r, it, StockService.DIR_OUT, now, null);
            // ② 双回写：receipt_items.returned_qty + order_items.returned_qty
            // CAS 上限：成品退货不得超过该回厂明细已收量、订货已收量（防超退/幽灵库存）
            if (it.getReceiptItemId() != null) {
                int updated = em.createNativeQuery("""
                        UPDATE subcontract_receipt_items
                        SET returned_qty = COALESCE(returned_qty,0) + :q
                        WHERE id = :id
                          AND COALESCE(qty,0) >= COALESCE(returned_qty,0) + :q
                        """)
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getReceiptItemId())
                        .executeUpdate();
                if (updated != 1) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "委外成品退货量超过回厂明细已收量，禁止超退");
                }
            }
            if (it.getOrderItemId() != null) {
                int updated = em.createNativeQuery("""
                        UPDATE subcontract_order_items
                        SET returned_qty = COALESCE(returned_qty,0) + :q
                        WHERE id = :id
                          AND COALESCE(received_qty,0) >= COALESCE(returned_qty,0) + :q
                        """)
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getOrderItemId())
                        .executeUpdate();
                if (updated != 1) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "委外成品退货量超过订货已收量，禁止超退");
                }
                recalcOrderClosed(it.getOrderItemId());
            }
        }
        // ③ 反向立应付（AP, SUBCONTRACT_RETURN, 金额取负 — 冲减进仓单立的应付）
        postAp(r, r.getTotalOriginal(), totalLocalOf(items), -1);
        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        canonicalizeApprover(r);
        r.setApPosted(true);
        returnRepo.save(r);
        arrivalControl.refreshAfterReturn(ProcurementArrivalControlPort.SUBCONTRACT,
                items.stream().map(SubcontractReturnItem::getOrderItemId).toList());
        return detail(id);
    }

    /** 红冲：1→-1。先 reverseArAp（已核销则抛错）→ 反向 DIR_IN + 回减 returned_qty + ap_posted=false。 */
    @Transactional
    @PreAuthorize("hasAuthority('subcontract_return:reverse')")
    public ReturnDetail reverse(UUID id) {
        tx.bind();
        SupplierPeriodIdentityGuard.Identity periodIdentity =
        periodIdentityGuard.requireIdentity(SourceTable.SUBCONTRACT_RETURN, id);
        periodIdentityGuard.requireOpenToday(periodIdentity, "委外退货红冲");
        SubcontractReturn r = requireReturnForUpdate(id);
        periodIdentityGuard.requireUnchanged(
                r.getSupplierId(), r.getCurrencyId(), r.getBillDate(),
                periodIdentity);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外退货单");
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        List<SubcontractReturnItem> items = itemRepo.findByReturnIdOrderByLineNoAsc(id);
        // KS-P1-2：先取库存锁再锁 AP 行（与 approve 锁序一致）。
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        arApService.reverseArAp(r.getId(), StockService.SRC_SUBCONTRACT_RETURN);
        OffsetDateTime now = OffsetDateTime.now();
        // 反向只翻 direction；amountLocal 传正数（StockService 内部乘 direction）。negate 会致金额符号不回滚。
        for (SubcontractReturnItem it : items) {
            applyMovement(r, it, StockService.DIR_IN, now, null);
            if (it.getReceiptItemId() != null) {
                int updated = em.createNativeQuery("""
                        UPDATE subcontract_receipt_items
                        SET returned_qty = COALESCE(returned_qty,0) - :q
                        WHERE id = :id
                          AND COALESCE(returned_qty,0) >= :q
                        """)
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getReceiptItemId())
                        .executeUpdate();
                if (updated != 1) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "委外成品退货红冲量超过回厂明细已退量（可能已被改动），禁止负数");
                }
            }
            if (it.getOrderItemId() != null) {
                int updated = em.createNativeQuery("""
                        UPDATE subcontract_order_items
                        SET returned_qty = COALESCE(returned_qty,0) - :q
                        WHERE id = :id
                          AND COALESCE(returned_qty,0) >= :q
                        """)
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getOrderItemId())
                        .executeUpdate();
                if (updated != 1) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "委外成品退货红冲量超过订货已退量，禁止负数");
                }
                recalcOrderClosed(it.getOrderItemId());
            }
        }
        r.setStatus(STATUS_REVERSED);
        r.setApPosted(false);
        returnRepo.save(r);
        arrivalControl.refreshAfterReturn(ProcurementArrivalControlPort.SUBCONTRACT,
                items.stream().map(SubcontractReturnItem::getOrderItemId).toList());
        return detail(id);
    }

    /** 写一笔库存流水（方向由调用方给）。qty 为明细量，baseQty = qty×unit_rate。 */
    private void applyMovement(SubcontractReturn r, SubcontractReturnItem it, short direction,
                               OffsetDateTime ts, BigDecimal overrideAmount) {
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        BigDecimal baseQty = it.getQty().multiply(rate);
        BigDecimal amt = overrideAmount != null ? overrideAmount : it.getAmountLocal();
        stockService.recordMovement(new StockService.MovementRequest(
                ts, StockService.TYPE_SUBCONTRACT_RETURN, StockService.SRC_SUBCONTRACT_RETURN,
                r.getId(), it.getId(), it.getGoodsId(), it.getColorId(), r.getWarehouseId(),
                direction, baseQty, it.getUnitId(), it.getUnitRate(), amt,
                direction < 0 ? null : "红冲"));
    }

    /** 立应付反向 AP。sign=-1 退货（应付减少，金额转负）。 */
    private void postAp(
            SubcontractReturn r,
            BigDecimal amountOriginal,
            BigDecimal amountLocal,
            int sign) {
        if (amountLocal == null) return;
        BigDecimal signedLocal = sign < 0 ? amountLocal.negate() : amountLocal;
        BigDecimal signedOriginal = amountOriginal == null
                ? null : (sign < 0 ? amountOriginal.negate() : amountOriginal);
        LocalDate dueDate = paymentTerms.resolveDueDate(
                r.getSupplierId(), r.getSettlementMethodId(), r.getBillDate());
        arApService.postArAp(new ArApPostingRequest(
                "AP",
                StockService.SRC_SUBCONTRACT_RETURN,
                r.getId(),
                r.getBillNo(),
                r.getBillDate(),
                null,
                r.getSupplierId(),
                r.getCurrencyId(),
                r.getExchangeRate() == null ? BigDecimal.ONE : r.getExchangeRate(),
                signedLocal,
                (short) 30,  // 老库 BStyle=30 委外进仓/退货（与进仓同 BStyle，方向由 sign 区分）
                null,
                signedOriginal,
                dueDate,
                settlementStyleLegacy(r.getSettlementStyleLegacy()),
                List.of(),
                r.getSettlementMethodId()));
    }

    private static Short settlementStyleLegacy(Integer legacyId) {
        if (legacyId == null) return null;
        if (legacyId < Short.MIN_VALUE || legacyId > Short.MAX_VALUE) {
            throw new ApiException(ErrorCode.CONFLICT, "委外退货结账方式历史编号超出有效范围");
        }
        return legacyId.shortValue();
    }

    private BigDecimal totalLocalOf(List<SubcontractReturnItem> items) {
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

    private void applyHeader(ReturnSaveRequest req, SubcontractReturn r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SUB_RETURN));
        }
        r.setBillDate(req.getBillDate());
        r.setSupplierId(req.getSupplierId());
        r.setWarehouseId(req.getWarehouseId());
        r.setCurrencyId(req.getCurrencyId());
        r.setExchangeRate(req.getExchangeRate());
        r.setTaxRate(req.getTaxRate());
        r.setLastDate(req.getLastDate());
        r.setRemark(req.getRemark());
        if (!(req.getSettlementMethodId() == null && req.getSettlementStyleLegacy() == null
                && r.getSettlementMethodId() == null && r.getSettlementStyleLegacy() != null)) {
            var settlement = com.uten.imp.common.util.SettlementMethodReferenceResolver.resolve(
                    em, req.getSettlementMethodId(), req.getSettlementStyleLegacy(), "结帐方式");
            r.setSettlementMethodId(settlement == null ? null : settlement.id());
            r.setSettlementStyleLegacy(settlement == null ? null : settlement.legacyId());
        }
        canonicalizeMaker(r);
        canonicalizeApprover(r);
    }

    private void canonicalizeMaker(SubcontractReturn subcontractReturn) {
        if (subcontractReturn.getMakerId() == null) return;
        subcontractReturn.setMakerLegacyId(null);
        subcontractReturn.setMakerName(nameResolver.nameOf(subcontractReturn.getMakerId()));
    }

    private void canonicalizeApprover(SubcontractReturn subcontractReturn) {
        if (subcontractReturn.getApproverId() == null) return;
        subcontractReturn.setApproverLegacyId(null);
        subcontractReturn.setApproverName(nameResolver.nameOf(subcontractReturn.getApproverId()));
    }

    private List<ReturnItemDto> saveItems(SubcontractReturn r, List<ReturnItemLine> lines) {
        List<ReturnItemDto> out = new ArrayList<>(lines.size());
        Map<UUID, SubcontractGoodsSnapshot> receipts =
                SubcontractGoodsSnapshot.fromReceiptItems(
                        em,
                        lines.stream().map(ReturnItemLine::getReceiptItemId).toList(),
                        SubcontractGoodsSnapshot.RECEIPT_ITEM_AT_SAVE);
        Map<UUID, SubcontractGoodsSnapshot> orders =
                SubcontractGoodsSnapshot.fromOrderItems(
                        em,
                        lines.stream().map(ReturnItemLine::getOrderItemId).toList(),
                        SubcontractGoodsSnapshot.ORDER_ITEM_AT_SAVE);
        Map<UUID, SubcontractGoodsSnapshot> master =
                SubcontractGoodsSnapshot.fromMaster(
                        em,
                        lines.stream().map(ReturnItemLine::getGoodsId).toList(),
                        SubcontractGoodsSnapshot.MASTER_AT_SAVE);
        int autoLine = 1;
        for (ReturnItemLine l : lines) {
            SubcontractReturnItem it = new SubcontractReturnItem();
            it.setReturnId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : autoLine);
            it.setGoodsId(l.getGoodsId());
            applyGoodsSnapshot(it, preferredReturnSnapshot(
                    l.getReceiptItemId(), l.getOrderItemId(), l.getGoodsId(),
                    receipts, orders, master, "委外成品退货明细"), null);
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
            it.setGirthQty(l.getGirthQty());
            it.setStepLegacyId(l.getStepLegacyId());
            it.setReceiptNo(l.getReceiptNo());
            it.setOrderNo(l.getOrderNo());
            itemRepo.save(it);
            out.add(toItemDto(it));
            autoLine++;
        }
        return out;
    }

    private void captureGoodsSnapshots(
            List<SubcontractReturnItem> items,
            String receiptSource,
            String orderSource,
            String masterSource,
            OffsetDateTime lockedAt) {
        Map<UUID, SubcontractGoodsSnapshot> receipts = SubcontractGoodsSnapshot.fromReceiptItems(
                em, items.stream().map(SubcontractReturnItem::getReceiptItemId).toList(), receiptSource);
        Map<UUID, SubcontractGoodsSnapshot> orders = SubcontractGoodsSnapshot.fromOrderItems(
                em, items.stream().map(SubcontractReturnItem::getOrderItemId).toList(), orderSource);
        Map<UUID, SubcontractGoodsSnapshot> master = SubcontractGoodsSnapshot.fromMaster(
                em, items.stream().map(SubcontractReturnItem::getGoodsId).toList(), masterSource);
        for (SubcontractReturnItem item : items) {
            applyGoodsSnapshot(item, preferredReturnSnapshot(
                    item.getReceiptItemId(), item.getOrderItemId(), item.getGoodsId(),
                    receipts, orders, master, "委外成品退货明细"), lockedAt);
        }
        itemRepo.saveAll(items);
        itemRepo.flush();
    }

    private static SubcontractGoodsSnapshot preferredReturnSnapshot(
            UUID receiptItemId,
            UUID orderItemId,
            UUID goodsId,
            Map<UUID, SubcontractGoodsSnapshot> receipts,
            Map<UUID, SubcontractGoodsSnapshot> orders,
            Map<UUID, SubcontractGoodsSnapshot> master,
            String subject) {
        if (receiptItemId != null) {
            return SubcontractGoodsSnapshot.preferred(receipts, receiptItemId, master, goodsId, subject);
        }
        return SubcontractGoodsSnapshot.preferred(orders, orderItemId, master, goodsId, subject);
    }

    private static void applyGoodsSnapshot(
            SubcontractReturnItem item,
            SubcontractGoodsSnapshot snapshot,
            OffsetDateTime lockedAt) {
        item.setGoodsCodeSnapshot(snapshot.code());
        item.setGoodsNameSnapshot(snapshot.name());
        item.setGoodsSnapshotSource(snapshot.source());
        item.setGoodsSnapshotLockedAt(lockedAt);
    }

    private void applyTotals(SubcontractReturn r, List<ReturnItemDto> items) {
        BigDecimal local = items.stream()
                .map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream()
                .map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        r.setTotalLocal(local);
        r.setTotalOriginal(original);
        returnRepo.save(r);
    }

    private ReturnListItem toList(SubcontractReturn r) {
        return new ReturnListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getSupplierId(),
                r.getWarehouseId(), r.getTotalLocal(), r.getStatus(), r.isClosed(), r.isApPosted(), r.getLegacyId());
    }

    private ReturnItemDto toItemDto(SubcontractReturnItem it) {
        return new ReturnItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getReceiptItemId(), it.getOrderItemId(), it.getWeight(),
                it.getSourceDocNo(), it.getRemark(), it.getGirthQty(), it.getStepLegacyId(),
                it.getReceiptNo(), it.getOrderNo());
    }

    private ReturnDetail toDetail(SubcontractReturn r, List<ReturnItemDto> items) {
        return new ReturnDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getSupplierId(), r.getWarehouseId(), r.getCurrencyId(), r.getExchangeRate(), r.getTaxRate(),
                r.getMakerId(), r.getApproverId(), r.getLastDate(), r.isApPosted(), r.getRemark(),
                r.getTotalOriginal(), r.getTotalLocal(), r.getStatus(), r.isClosed(), r.getSourceDocNo(), items,
                r.getSettlementStyleLegacy(), r.getSettlementMethodId(), r.getMakerLegacyId(),
                (r.getMakerName() != null && !r.getMakerName().isBlank()) ? r.getMakerName() : nameResolver.nameOf(r.getMakerId()),
                r.getApproverLegacyId(), r.getApproverName(), r.getCreatedAt());
    }


    private SubcontractReturn requireReturn(UUID id) {
        return returnRepo.findById(id)
                .filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "委外退货单不存在"));
    }
    private SubcontractReturn requireReturnForUpdate(UUID id) {
        SubcontractReturn subcontractReturn = em.find(
                SubcontractReturn.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        return subcontractReturn == null || subcontractReturn.isDeleted()
                ? requireReturn(id)
                : subcontractReturn;
    }
}
