package com.uten.imp.features.subcontract.receipt;

import com.uten.imp.application.port.ProcurementArrivalBlockedException;
import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
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
import com.uten.imp.application.port.ProcurementInspectionPort;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.LinkedOrderReadGate;
import com.uten.imp.features.subcontract.SubcontractGoodsSnapshot;
import com.uten.imp.features.subcontract.SubcontractGoodsKeyword;
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
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
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
 * <p>收货库存写入使用正向逻辑（QTY 正向累加）。
 */
@Service
@RequiredArgsConstructor
public class SubcontractReceiptService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    private final SubcontractReceiptRepository receiptRepo;
    private final SubcontractReceiptItemRepository itemRepo;
    private final StockService stockService;
    private final LinkedDocumentIntegrityService sourceIntegrity;
    private final SubcontractReceiptAmountAuthority receiptAmountAuthority;
    private final ArApLedgerService arApService;
    private final SupplierPaymentTermService paymentTerms;
    private final SupplierPeriodIdentityGuard periodIdentityGuard;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final DocNumberService docNumberService;
    private final ProductionSubcontractSupplyTransitionPort productionSupply;
    private final ProcurementArrivalControlPort arrivalControl;
    private final ProcurementInspectionPort inspectionService;
    private final SubcontractDocumentAccessPolicy access;
    private final com.uten.imp.features.subcontract.LinkedOrderReadGate linkedOrderReadGate;
    private final com.uten.imp.application.port.PreplanAnalysisPegPort preplanAnalysisPeg;
    private final com.uten.imp.features.purchase.receipt.ReceiptPriceMasker priceMasker;

    @Transactional(readOnly = true)
    public PageResponse<ReceiptListItem> list(ReceiptQueryFilter f, int page, int size, String sort, String order) {
        var readScope = access.scope();
        Specification<SubcontractReceipt> spec = (Root<SubcontractReceipt> root,
                                                  jakarta.persistence.criteria.CriteriaQuery<?> q,
                                                  CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(access.readablePredicate(root, cb, "makerId", readScope));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(SubcontractGoodsKeyword.predicate(
                        cb, q, root, SubcontractReceiptItem.class, "receiptId", f.keyword()));
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
        Page<SubcontractReceipt> p = receiptRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public ReceiptDetail detail(UUID id) {
        SubcontractReceipt r = requireReceipt(id);
        // V304：仓库执行的进仓单对关联订货单归属人只读放行（委外进度点击溯源）。
        linkedOrderReadGate.requireReadableViaOrder(
                r.getMakerId(), "委外进仓单不存在", LinkedOrderReadGate.LinkedDocKind.RECEIPT, id);
        List<SubcontractReceiptItem> entities = itemRepo.findByReceiptIdOrderByLineNoAsc(id);
        Map<UUID, ReceiptSourceRef> orderRefs = orderRefsByItemIds(
                entities.stream().map(SubcontractReceiptItem::getOrderItemId).toList());
        List<ReceiptItemDto> items = entities.stream()
                .map(it -> toItemDto(it, orderRefs)).toList();
        return toDetail(r, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('subcontract_receipt:create')")
    public ReceiptDetail create(ReceiptSaveRequest req) {
        tx.bind();
        SubcontractReceipt r = new SubcontractReceipt();
        applyHeader(req, r);
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        canonicalizeMaker(r);
        r.setStatus(STATUS_DRAFT);
        receiptRepo.save(r);
        List<ReceiptItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('subcontract_receipt:edit')")
    public ReceiptDetail update(UUID id, ReceiptSaveRequest req) {
        tx.bind();
        SubcontractReceipt r = requireReceiptForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外进仓单");
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
    @PreAuthorize("hasAuthority('subcontract_receipt:delete')")
    public void delete(UUID id) {
        tx.bind();
        SubcontractReceipt r = requireReceiptForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外进仓单");
        com.uten.imp.common.web.StandardDocumentLifecycleCapabilities.requireDraftForDelete(r.getStatus());
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        receiptRepo.save(r);
    }

    /**
     * 审核：status 0→1，库存正向入库（DIR_IN）+ 回写订货 received_qty + 立应付 + ap_posted + 结案重算。
     * 关键纠偏：老库触发器写 QTY-=（减库存）是反的，新库按方向 +1 正向入库。design doc 22 §一决策4。
     */
    @Transactional(noRollbackFor = ProcurementArrivalBlockedException.class)
    @PreAuthorize("hasAuthority('subcontract_receipt:approve')")
    public ReceiptDetail approve(UUID id) {
        tx.bind();
        SupplierPeriodIdentityGuard.Identity periodIdentity =
        periodIdentityGuard.requireIdentity(SourceTable.SUBCONTRACT_RECEIPT, id);
        periodIdentityGuard.requireOpenAtBillDate(periodIdentity, "委外进仓审核");
        productionSupply.lockSubcontractReceiptMutationDimensions(id);
        SubcontractReceipt r = requireReceiptForUpdate(id);
        periodIdentityGuard.requireUnchanged(
                r.getSupplierId(), r.getCurrencyId(), r.getBillDate(),
                periodIdentity);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外进仓单");
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
        sourceIntegrity.validateSubcontractReceipt(
                r.getSupplierId(),
                items.stream()
                        .map(it -> LinkedDocumentIntegrityService.LinkedLine.orderSource(
                                it.getOrderItemId(),
                                it.getGoodsId(),
                                it.getColorId(),
                                it.getUnitId(),
                                it.getUnitRate()))
                        .toList());
        captureGoodsSnapshots(
                items,
                SubcontractGoodsSnapshot.ORDER_ITEM_AT_APPROVAL,
                SubcontractGoodsSnapshot.MASTER_AT_APPROVAL,
                OffsetDateTime.now());
        arrivalControl.validateBeforeApproval(
                ProcurementArrivalControlPort.SUBCONTRACT, id);
        receiptAmountAuthority.apply(r, items);
        productionSupply.lockSubcontractReceiptProductionDemands(
                id, r.getWarehouseId());
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        OffsetDateTime now = OffsetDateTime.now();
        // IQC：收货入待检隔离（不写 stock_balances）；合格处置（PASS）才进可用库存 + 唤醒生产。
        inspectionService.receive(ProcurementInspectionPort.SUBCONTRACT, id, r.getWarehouseId(),
                items.stream().map(it -> new ProcurementInspectionPort.ReceivedLine(
                        it.getId(), it.getGoodsId(), it.getColorId(), it.getUnitId(),
                        it.getUnitRate(), it.getQty(), it.getAmountLocal())).toList(),
                now);
        for (SubcontractReceiptItem it : items) {
            // ② 回写订货明细 received_qty + 重算订货单 is_closed
            if (it.getOrderItemId() != null) {
                em.createNativeQuery(
                        "UPDATE subcontract_order_items SET received_qty = COALESCE(received_qty,0) + :q WHERE id = :id")
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getOrderItemId())
                        .executeUpdate();
                recalcOrderClosed(it.getOrderItemId());
                // ③ 回厂按冻结 BOM 消费发料子件（守恒：consumed_qty += 回厂父件量×frozen_unit_qty）
                consumeIssuedMaterials(it.getOrderItemId(), it.getQty(), +1);
            }
        }
        // ③ 立应付（AP, SUBCONTRACT_RECEIPT, +amount）—— 金额为正
        postAp(r, r.getTotalOriginal(), totalLocalOf(items), +1);
        r.setStatus(STATUS_APPROVED);
        // 生产唤醒（onSubcontractReceiptApproved）推迟到 IQC 整单结案（ProcurementInspectionService.dispose）。
        r.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        canonicalizeApprover(r);
        r.setApPosted(true);
        receiptRepo.save(r);
        arrivalControl.recordApproval(
                ProcurementArrivalControlPort.SUBCONTRACT, id);
        return detail(id);
    }
    /** Dedicated gateway for a finance-decided arrival exception; normal approve keeps its own authority. */
    @Transactional(noRollbackFor = ProcurementArrivalBlockedException.class)
    @PreAuthorize("hasAuthority('warehouse_inbound:stock_in')")
    public ReceiptDetail approveFromWarehouseDecision(UUID id) {
        return approve(id);
    }


    /** 红冲：status 1→-1，先 reverseArAp（已核销则抛错）→ 反向 DIR_OUT + 回减 received_qty + ap_posted=false。 */
    @Transactional
    @PreAuthorize("hasAuthority('subcontract_receipt:reverse')")
    public ReceiptDetail reverse(UUID id) {
        tx.bind();
        SupplierPeriodIdentityGuard.Identity periodIdentity =
        periodIdentityGuard.requireIdentity(SourceTable.SUBCONTRACT_RECEIPT, id);
        periodIdentityGuard.requireOpenToday(periodIdentity, "委外进仓红冲");
        productionSupply.lockSubcontractReceiptMutationDimensions(id);
        SubcontractReceipt r = requireReceiptForUpdate(id);
        periodIdentityGuard.requireUnchanged(
                r.getSupplierId(), r.getCurrencyId(), r.getBillDate(),
                periodIdentity);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外进仓单");
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        List<SubcontractReceiptItem> items = itemRepo.findByReceiptIdOrderByLineNoAsc(id);
        if (items.stream().anyMatch(it ->
                it.getReturnedQty() != null && it.getReturnedQty().signum() > 0)) {
            throw new ApiException(ErrorCode.BUSINESS, "委外进仓已有退货记录，请先红冲下游退货单");
        }
        // IQC：红冲前须质检结案；反向由 inspection 服务按已放行量精确回退（无冻结行的历史单走全量）。
        inspectionService.requireResolvedForReverse(ProcurementInspectionPort.SUBCONTRACT, id);
        productionSupply.beforeSubcontractReceiptReversed(id);
        // 分析备料绑定对称反向：释放本进仓单建立的分析归属预留（V298）。
        preplanAnalysisPeg.releaseForReceipt(ProcurementInspectionPort.SUBCONTRACT, id);
        // KS-P1-2：先取库存 advisory 锁，再 reverseArAp 锁 AP 行——与 approve 锁序一致，消除并发死锁窗。
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        // 反立帐（若有核销 amount_settled<>0 抛 IllegalStateException，对齐老库文案）
        arApService.reverseArAp(r.getId(), StockService.SRC_SUBCONTRACT_RECEIPT);
        OffsetDateTime now = OffsetDateTime.now();
        boolean inspectionManaged = inspectionService.reverseResolvedStock(
                ProcurementInspectionPort.SUBCONTRACT, id, now);
        // 反向只翻 direction；amountLocal 传正数（StockService 内部乘 direction）。negate 会致金额符号不回滚。
        for (SubcontractReceiptItem it : items) {
            if (!inspectionManaged) {
                applyMovement(r, it, StockService.DIR_OUT, now, null);
            }
            if (it.getOrderItemId() != null) {
                em.createNativeQuery(
                        "UPDATE subcontract_order_items SET received_qty = COALESCE(received_qty,0) - :q WHERE id = :id")
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getOrderItemId())
                        .executeUpdate();
                recalcOrderClosed(it.getOrderItemId());
                // 回退回厂消费（consumed_qty -= 回厂父件量×frozen_unit_qty）
                consumeIssuedMaterials(it.getOrderItemId(), it.getQty(), -1);
            }
        }
        r.setStatus(STATUS_REVERSED);
        r.setApPosted(false);
        // The downstream refresh validates the source's terminal state via a
        // native query, so make that state visible before invoking the hook.
        receiptRepo.saveAndFlush(r);
        arrivalControl.recordReversal(
                ProcurementArrivalControlPort.SUBCONTRACT, id);
        productionSupply.afterSubcontractReceiptReversed(id);
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
    private void postAp(
            SubcontractReceipt r,
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
                StockService.SRC_SUBCONTRACT_RECEIPT,
                r.getId(),
                r.getBillNo(),
                r.getBillDate(),
                null,                 // AR client，AP 传 null
                r.getSupplierId(),    // AP 落 supplier
                r.getCurrencyId(),
                r.getExchangeRate() == null ? BigDecimal.ONE : r.getExchangeRate(),
                signedLocal,
                (short) 30,  // 老库 BStyle=30 委外进仓
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
            throw new ApiException(ErrorCode.CONFLICT, "委外进仓结账方式历史编号超出有效范围");
        }
        return legacyId.shortValue();
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

    /**
     * 委外回厂进仓按冻结 BOM 消费发料子件（守恒）。
     *
     * <p>sign=+1 进仓消费 / -1 红冲回退。<b>按子件维度（货品+颜色）聚合</b>：同一订货明细下
     * 同一子件可能分多张发料单/多行，回厂消费量必须按「回厂父件量 × frozen_unit_qty」对每个
     * 子件只算一次，再在组内按发料行 FIFO 分摊——绝不能对组内每行重复消费全额。
     *
     * <ul>
     *   <li>同组各行冻结单耗不一致（BOM 版本分叉）→ 409 人工核销（fail-closed，不猜测版本）；</li>
     *   <li>消费（+1）：组内 FIFO 按 {@code supplier_ending = at_supplier − consumed − returned − wasted}
     *       分摊，逐行 CAS；组内余量合计不足 → 409（DB CHECK supplier_ending≥0 为兜底）；</li>
     *   <li>回退（−1）：组内 LIFO 从 {@code consumed_qty>0} 的行精确回减，逐行 CAS
     *       {@code consumed_qty − :d ≥ 0}；组内可回退合计不足（其它回厂单已消费）→ 409 人工核销，
     *       禁止静默钳位吞错账。</li>
     * </ul>
     *
     * <p>单位口径：回厂父件量（父件单据单位）× frozen_unit_qty（子件/父件）= 子件单据单位，与
     * at_supplier_qty / returned_qty / wasted_qty 同口径。
     */
    private void consumeIssuedMaterials(UUID orderItemId, BigDecimal receivedParentQty, int sign) {
        if (orderItemId == null || receivedParentQty == null || receivedParentQty.signum() == 0) return;
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, goods_id, color_id, COALESCE(frozen_unit_qty, 0),
                               COALESCE(at_supplier_qty, 0), COALESCE(consumed_qty, 0),
                               COALESCE(returned_qty, 0), COALESCE(wasted_qty, 0),
                               COALESCE(compensated_qty,0)
                        FROM subcontract_material_issue_items
                        WHERE order_item_id = :oid
                          AND COALESCE(at_supplier_qty,0)+COALESCE(compensated_qty,0)>0
                          AND COALESCE(frozen_unit_qty, 0) > 0
                        ORDER BY goods_id, color_id NULLS FIRST, id
                        FOR UPDATE
                        """)
                .setParameter("oid", orderItemId)
                .getResultList();
        Map<ComponentKey, List<Object[]>> groups = new java.util.LinkedHashMap<>();
        for (Object[] row : rows) {
            groups.computeIfAbsent(new ComponentKey((UUID) row[1], (UUID) row[2]), k -> new ArrayList<>())
                    .add(row);
        }
        for (Map.Entry<ComponentKey, List<Object[]>> entry : groups.entrySet()) {
            List<Object[]> group = entry.getValue();
            BigDecimal unitQty = (BigDecimal) group.getFirst()[3];
            for (Object[] row : group) {
                BigDecimal rowRate = (BigDecimal) row[3];
                if (rowRate.compareTo(unitQty) != 0) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "委外订货明细下同一子件存在多个冻结 BOM 单耗版本（" + unitQty.stripTrailingZeros().toPlainString()
                                    + " / " + rowRate.stripTrailingZeros().toPlainString()
                                    + "），无法确定回厂消费口径，请人工核销");
                }
            }
            BigDecimal required = receivedParentQty.multiply(unitQty)
                    .setScale(4, java.math.RoundingMode.HALF_UP);
            if (required.signum() == 0) continue;
            BigDecimal remaining = required;
            if (sign > 0) {
                for (Object[] row : group) {
                    if (remaining.signum() <= 0) break;
                    BigDecimal ending = ((BigDecimal) row[4])
                            .add((BigDecimal)row[8])
                            .subtract((BigDecimal) row[5])
                            .subtract((BigDecimal) row[6])
                            .subtract((BigDecimal) row[7]);
                    BigDecimal take = remaining.min(ending);
                    if (take.signum() <= 0) continue;
                    int updated = em.createNativeQuery("""
                                    UPDATE subcontract_material_issue_items
                                    SET consumed_qty = consumed_qty + :delta
                                    WHERE id = :id
                                      AND :delta <= at_supplier_qty+COALESCE(compensated_qty,0)
                                          - consumed_qty-COALESCE(returned_qty,0)
                                          - COALESCE(wasted_qty,0)
                                    """)
                            .setParameter("delta", take)
                            .setParameter("id", (UUID) row[0])
                            .executeUpdate();
                    if (updated != 1) {
                        throw new ApiException(ErrorCode.CONFLICT,
                                "委外回厂消费超过供应商在制余量（发料−已消费−已退−已损耗），疑似超耗或错料，请人工核销");
                    }
                    remaining = remaining.subtract(take);
                }
                if (remaining.signum() > 0) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "委外回厂消费超过供应商在制余量（发料−已消费−已退−已损耗），疑似超耗或错料，请人工核销");
                }
            } else {
                for (int i = group.size() - 1; i >= 0; i--) {
                    if (remaining.signum() <= 0) break;
                    Object[] row = group.get(i);
                    BigDecimal give = remaining.min((BigDecimal) row[5]);
                    if (give.signum() <= 0) continue;
                    int updated = em.createNativeQuery("""
                                    UPDATE subcontract_material_issue_items
                                    SET consumed_qty = consumed_qty - :delta
                                    WHERE id = :id
                                      AND COALESCE(consumed_qty, 0) >= :delta
                                    """)
                            .setParameter("delta", give)
                            .setParameter("id", (UUID) row[0])
                            .executeUpdate();
                    if (updated != 1) {
                        throw new ApiException(ErrorCode.CONFLICT,
                                "委外回厂红冲回退与并发回厂消费冲突（子件已消费量已变化），请重试或人工核销");
                    }
                    remaining = remaining.subtract(give);
                }
                if (remaining.signum() > 0) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "委外回厂红冲需回退的子件消费量不足（其它回厂单据已消费该子件），请人工核销，禁止自动吞并错账");
                }
            }
        }
    }

    /** 子件身份（货品+颜色，颜色可空）：同一订货明细下的同名子件分多行也视为同一物。 */
    private record ComponentKey(UUID goodsId, UUID colorId) {
        @Override
        public boolean equals(Object o) {
            if (!(o instanceof ComponentKey(UUID g, UUID c))) return false;
            return java.util.Objects.equals(goodsId, g) && java.util.Objects.equals(colorId, c);
        }

        @Override
        public int hashCode() {
            return java.util.Objects.hash(goodsId, colorId);
        }
    }

    private void applyHeader(ReceiptSaveRequest req, SubcontractReceipt r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SUB_RECEIPT));
        }
        r.setBillDate(req.getBillDate());
        r.setSupplierId(req.getSupplierId());
        r.setWarehouseId(req.getWarehouseId());
        r.setCurrencyId(req.getCurrencyId());
        r.setExchangeRate(req.getExchangeRate());
        r.setTaxRate(req.getTaxRate());
        var receiver = nameResolver.resolveForWrite(
                req.getSenderId(), req.getReceiverLegacyId(), req.getReceiverName(), "收货人");
        if (!(receiver == null && r.getLegacyId() != null && r.getSenderId() == null)) {
            r.setSenderId(receiver == null ? null : receiver.id());
            r.setReceiverLegacyId(receiver == null ? null : receiver.legacyId());
            r.setReceiverName(receiver == null ? null : receiver.name());
        }
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

    private void canonicalizeMaker(SubcontractReceipt receipt) {
        if (receipt.getMakerId() == null) return;
        receipt.setMakerLegacyId(null);
        receipt.setMakerName(nameResolver.nameOf(receipt.getMakerId()));
    }

    private void canonicalizeApprover(SubcontractReceipt receipt) {
        if (receipt.getApproverId() == null) return;
        receipt.setApproverLegacyId(null);
        receipt.setApproverName(nameResolver.nameOf(receipt.getApproverId()));
    }

    private List<ReceiptItemDto> saveItems(SubcontractReceipt r, List<ReceiptItemLine> lines) {
        List<ReceiptItemDto> out = new ArrayList<>(lines.size());
        Map<UUID, ReceiptSourceRef> orderRefs = orderRefsByItemIds(
                lines.stream().map(ReceiptItemLine::getOrderItemId).toList());
        Map<UUID, SubcontractGoodsSnapshot> upstream =
                SubcontractGoodsSnapshot.fromOrderItems(
                        em,
                        lines.stream().map(ReceiptItemLine::getOrderItemId).toList(),
                        SubcontractGoodsSnapshot.ORDER_ITEM_AT_SAVE);
        Map<UUID, SubcontractGoodsSnapshot> master =
                SubcontractGoodsSnapshot.fromMaster(
                        em,
                        lines.stream().map(ReceiptItemLine::getGoodsId).toList(),
                        SubcontractGoodsSnapshot.MASTER_AT_SAVE);
        int autoLine = 1;
        for (ReceiptItemLine l : lines) {
            SubcontractReceiptItem it = new SubcontractReceiptItem();
            it.setReceiptId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : autoLine);
            it.setGoodsId(l.getGoodsId());
            applyGoodsSnapshot(
                    it,
                    SubcontractGoodsSnapshot.preferred(
                            upstream, l.getOrderItemId(), master, l.getGoodsId(),
                            "委外进仓明细"),
                    null);
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
            it.setGirthQty(l.getGirthQty());
            it.setStepLegacyId(l.getStepLegacyId());
            it.setReturnAmount(l.getReturnAmount());
            it.setReturnNo(l.getReturnNo());
            it.setOrderNo(l.getOrderNo());
            itemRepo.save(it);
            out.add(toItemDto(it, orderRefs));
            autoLine++;
        }
        return out;
    }

    private void captureGoodsSnapshots(
            List<SubcontractReceiptItem> items,
            String upstreamSource,
            String masterSource,
            OffsetDateTime lockedAt) {
        Map<UUID, SubcontractGoodsSnapshot> upstream = SubcontractGoodsSnapshot.fromOrderItems(
                em, items.stream().map(SubcontractReceiptItem::getOrderItemId).toList(), upstreamSource);
        Map<UUID, SubcontractGoodsSnapshot> master = SubcontractGoodsSnapshot.fromMaster(
                em, items.stream().map(SubcontractReceiptItem::getGoodsId).toList(), masterSource);
        for (SubcontractReceiptItem item : items) {
            applyGoodsSnapshot(
                    item,
                    SubcontractGoodsSnapshot.preferred(
                            upstream, item.getOrderItemId(), master, item.getGoodsId(),
                            "委外进仓明细"),
                    lockedAt);
        }
        itemRepo.saveAll(items);
        itemRepo.flush();
    }

    private static void applyGoodsSnapshot(
            SubcontractReceiptItem item,
            SubcontractGoodsSnapshot snapshot,
            OffsetDateTime lockedAt) {
        item.setGoodsCodeSnapshot(snapshot.code());
        item.setGoodsNameSnapshot(snapshot.name());
        item.setGoodsSnapshotSource(snapshot.source());
        item.setGoodsSnapshotLockedAt(lockedAt);
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
        // 价格脱敏（V302）：无 subcontract_receipt:price:view 的角色合计置 null + priceMasked。
        boolean mask = !priceMasker.canViewSubcontract();
        return new ReceiptListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getSupplierId(),
                r.getWarehouseId(), mask ? null : r.getTotalLocal(),
                r.getStatus(), r.isClosed(), r.isApPosted(), r.getLegacyId(), mask);
    }

    /** 明细级来源订货单引用（orderItemId → 订单 id+编号），批量一次查出。 */
    private Map<UUID, ReceiptSourceRef> orderRefsByItemIds(List<UUID> orderItemIds) {
        List<UUID> ids = orderItemIds == null ? List.of()
                : orderItemIds.stream().filter(Objects::nonNull).distinct().toList();
        if (ids.isEmpty()) return Map.of();
        Map<UUID, ReceiptSourceRef> result = new HashMap<>();
        for (Object[] row : com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT i.id, so.id, so.bill_no
                        FROM subcontract_order_items i
                        JOIN subcontract_orders so ON so.id = i.order_id
                        WHERE i.id IN (:ids)
                        """).setParameter("ids", ids))) {
            result.put((UUID) row[0],
                    new ReceiptSourceRef((UUID) row[1], (String) row[2]));
        }
        return result;
    }

    private ReceiptItemDto toItemDto(SubcontractReceiptItem it) {
        return toItemDto(it, Map.of());
    }

    private ReceiptItemDto toItemDto(
            SubcontractReceiptItem it, Map<UUID, ReceiptSourceRef> orderRefs) {
        ReceiptSourceRef orderRef = it.getOrderItemId() == null
                ? null : orderRefs.get(it.getOrderItemId());
        return new ReceiptItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getCheckQty(), it.getOrderQty(), it.getReturnedQty(), it.getWeight(),
                it.getOrderItemId(),
                orderRef == null ? null : orderRef.id(),
                orderRef == null ? null : orderRef.billNo(),
                it.getSourceDocNo(), it.getRemark(), it.getGirthQty(), it.getStepLegacyId(),
                it.getReturnAmount(), it.getReturnNo(), it.getOrderNo());
    }

    private ReceiptDetail toDetail(SubcontractReceipt r, List<ReceiptItemDto> items) {
        // 价格脱敏（V302）：主表金额族 + 明细价格族置 null，priceMasked 标记供前端渲染 ***。
        boolean mask = !priceMasker.canViewSubcontract();
        ReceiptSourceRef sourceOrder = singleOrderSource(items);
        List<ReceiptItemDto> safeItems = mask
                ? items.stream().map(SubcontractReceiptService::maskItemPrices).toList()
                : items;
        return new ReceiptDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getSupplierId(), r.getWarehouseId(), r.getCurrencyId(), r.getExchangeRate(), r.getTaxRate(),
                r.getSenderId(), r.getMakerId(), r.getApproverId(), r.getLastDate(), r.isApPosted(), r.getRemark(),
                mask ? null : r.getTotalOriginal(), mask ? null : r.getTotalLocal(),
                r.getStatus(), r.isClosed(), r.getSourceDocNo(), safeItems,
                r.getSettlementStyleLegacy(), r.getSettlementMethodId(), r.getReceiverLegacyId(), r.getReceiverName(),
                r.getMakerLegacyId(),
                (r.getMakerName() != null && !r.getMakerName().isBlank()) ? r.getMakerName() : nameResolver.nameOf(r.getMakerId()),
                r.getApproverLegacyId(), r.getApproverName(), r.getCreatedAt(),
                sourceOrder == null ? null : sourceOrder.id(),
                sourceOrder == null ? null : sourceOrder.billNo(),
                mask);
    }

    /** 明细价格族置 null 的拷贝（price/amountOriginal/amountLocal/returnAmount；其余字段原样保留）。 */
    private static ReceiptItemDto maskItemPrices(ReceiptItemDto it) {
        return new ReceiptItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), null, null,
                null, it.getCheckQty(), it.getOrderQty(), it.getReturnedQty(), it.getWeight(),
                it.getOrderItemId(), it.getOrderId(), it.getOrderBillNo(),
                it.getSourceDocNo(), it.getRemark(), it.getGirthQty(), it.getStepLegacyId(),
                null, it.getReturnNo(), it.getOrderNo());
    }

    /** 全部明细同属一张委外订货单时返回该订单 (id, billNo)；否则 null。 */
    private ReceiptSourceRef singleOrderSource(List<ReceiptItemDto> items) {
        List<UUID> orderItemIds = items.stream()
                .map(ReceiptItemDto::getOrderItemId).filter(id -> id != null).distinct().toList();
        if (orderItemIds.isEmpty()) return null;
        List<Object[]> rows = com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT DISTINCT so.id, so.bill_no
                        FROM subcontract_order_items i
                        JOIN subcontract_orders so ON so.id = i.order_id
                        WHERE i.id IN (:ids)
                        """).setParameter("ids", orderItemIds));
        return rows.size() == 1 ? new ReceiptSourceRef((UUID) rows.getFirst()[0], (String) rows.getFirst()[1]) : null;
    }

    /** 详情头溯源引用（id 供跳转、billNo 供展示）。 */
    public record ReceiptSourceRef(UUID id, String billNo) {
    }

    private static Object[] spreadSource(ReceiptSourceRef ref) {
        return ref == null ? new Object[]{null, null} : new Object[]{ref.id(), ref.billNo()};
    }


    private SubcontractReceipt requireReceipt(UUID id) {
        return receiptRepo.findById(id)
                .filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "委外进仓单不存在"));
    }
    private SubcontractReceipt requireReceiptForUpdate(UUID id) {
        SubcontractReceipt receipt = em.find(
                SubcontractReceipt.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        return receipt == null || receipt.isDeleted()
                ? requireReceipt(id)
                : receipt;
    }
}
