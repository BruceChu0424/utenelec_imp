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
import com.uten.imp.common.finance.ProcurementOrderClosurePolicy;
import com.uten.imp.common.finance.ProcurementIqcReplacementAllocationService;
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
 *   <li>登记 IQC 待检隔离，不写可用库存</li>
 *   <li>回写订货明细 {@code subcontract_order_items.received_qty += qty}</li>
 *   <li>按 IQC 合格净量重算订货 {@code is_closed}；待检和 FAIL 都不能结案</li>
 * </ol>
 * 仓库确认回厂服务事实时按财务批准加工费快照立应付
 * {@link ArApLedgerService#postArAp}（AP, SUBCONTRACT_RECEIPT, +amount）并置 {@code ap_posted=true}；
 * IQC PASS 只形成仓库待入库量；仓库确认后才写库存/生产供给，不重复立 AP。
 *
 * <p>红冲（1→-1）：先 {@link ArApLedgerService#reverseArAp}（已核销则抛 IllegalStateException 阻断），
 * 再精确反向仓库已确认库存 + 回减 received_qty + 重算 is_closed + 置 {@code ap_posted=false}。
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
    private final ProcurementIqcReplacementAllocationService iqcReplacementAllocation;
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
    private final com.uten.imp.common.concurrency.ProcurementMutationLocks mutationLocks;
    private final com.uten.imp.common.finance.ProcurementReceiptConsiderationService consideration;
    private final com.uten.imp.application.port.ProcurementInventoryValuePort procurementValue;

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
        // 金额被裁剪时也必须关闭金额排序，否则结果顺序会泄露商业金额高低。
        boolean priceMasked = !priceMasker.canViewSubcontractReceipt();
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"),
                        priceMasked ? Map.of("billDate", "billDate") : ALLOWED_SORT));
        Page<SubcontractReceipt> p = receiptRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), p);
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
        lockReceiptRequest(null,req).verifyUnchanged();
        lockAndRequireDraftOutboundCapacity(req.getItems(), null, List.of());
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

    /** Dedicated warehouse-arrival gateway; normal creation keeps its exact action. */
    @Transactional
    @PreAuthorize("hasAuthority('warehouse_inbound:stock_in')")
    public ReceiptDetail createFromWarehouseArrival(ReceiptSaveRequest req) {
        return create(req);
    }

    @Transactional
    @PreAuthorize("hasAuthority('subcontract_receipt:edit')")
    public ReceiptDetail update(UUID id, ReceiptSaveRequest req) {
        tx.bind();
        var mutationGuard=lockReceiptRequest(id,req);
        SubcontractReceipt r = requireReceiptForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外进仓单");
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        mutationGuard.verifyUnchanged();
        List<UUID> previousOrderItemIds = itemRepo.findByReceiptIdOrderByLineNoAsc(id)
                .stream()
                .map(SubcontractReceiptItem::getOrderItemId)
                .filter(Objects::nonNull)
                .toList();
        lockAndRequireDraftOutboundCapacity(req.getItems(), id, previousOrderItemIds);
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
        var mutationGuard=mutationLocks.receipt("SUBCONTRACT",id);
        SubcontractReceipt r = requireReceiptForUpdate(id);
        mutationGuard.verifyUnchanged();
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外进仓单");
        com.uten.imp.common.web.StandardDocumentLifecycleCapabilities.requireDraftForDelete(r.getStatus());
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        receiptRepo.save(r);
    }

    private com.uten.imp.application.concurrency.FulfillmentMutationLocks.Guard lockReceiptRequest(UUID id,ReceiptSaveRequest req) {
        List<ReceiptItemLine> lines=req==null||req.getItems()==null?List.of():req.getItems();
        return mutationLocks.receiptInputs("SUBCONTRACT",id,lines.stream().filter(java.util.Objects::nonNull).map(ReceiptItemLine::getOrderItemId).toList(),
                lines.stream().filter(java.util.Objects::nonNull).filter(line->line.getGoodsId()!=null)
                        .map(line->new com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension(line.getGoodsId(),line.getColorId())).toList(),
                req==null?null:req.getWarehouseId());
    }

    /**
     * 审核：status 0→1，登记 IQC 隔离 + 回写实到量 + 立加工费 AP；
     * PASS 只放行，仓库确认后才正向入可用库存。
     */
    @Transactional(noRollbackFor = ProcurementArrivalBlockedException.class)
    @PreAuthorize("hasAuthority('subcontract_receipt:approve')")
    public ReceiptDetail approve(UUID id) {
        tx.bind();
        SupplierPeriodIdentityGuard.Identity periodIdentity =
        periodIdentityGuard.requireIdentity(SourceTable.SUBCONTRACT_RECEIPT, id);
        periodIdentityGuard.requireOpenAtBillDate(periodIdentity, "委外进仓审核");
        var mutationGuard=mutationLocks.receipt("SUBCONTRACT",id);
        productionSupply.lockSubcontractReceiptMutationDimensions(id);
        SubcontractReceipt r = requireReceiptForUpdate(id);
        mutationGuard.verifyUnchanged();
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
        warehouseScopes.requireActiveLeafWarehouse(r.getWarehouseId(), "入库仓库");
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
        requireTargetOutboundCapacity(items, id);
        arrivalControl.validateBeforeApproval(
                ProcurementArrivalControlPort.SUBCONTRACT, id);
        receiptAmountAuthority.apply(r, items);
        var payable=consideration.freezeReceipt("SUBCONTRACT",id);
        productionSupply.lockSubcontractReceiptProductionDemands(
                id, r.getWarehouseId());
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        OffsetDateTime now = OffsetDateTime.now();
        // IQC：收货入待检隔离；PASS 只放行给仓库，仓库确认后才进可用库存并推进生产。
        inspectionService.receive(ProcurementInspectionPort.SUBCONTRACT, id, r.getWarehouseId(),
                items.stream().map(it -> new ProcurementInspectionPort.ReceivedLine(
                        it.getId(), it.getGoodsId(), it.getColorId(), it.getUnitId(),
                        it.getUnitRate(), it.getQty(), it.getAmountLocal(),
                        it.getWeight())).toList(),
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
                BigDecimal replacementQty=iqcReplacementAllocation
                        .activeAllocatedQty("SUBCONTRACT",it.getId());
                BigDecimal firstReturnQty=it.getQty().subtract(replacementQty);
                if(firstReturnQty.signum()>0){
                    consumeIssuedMaterials(it.getId(),it.getOrderItemId(),firstReturnQty,+1);
                }
            }
        }
        // ③ 立应付（AP, SUBCONTRACT_RECEIPT, +amount）—— 金额为正
        boolean chargeable=payable.original().signum()!=0||payable.local().signum()!=0;
        if(chargeable)postAp(r,payable.original(),payable.local(),+1);
        r.setStatus(STATUS_APPROVED);
        // 正式生产供给由仓库确认 IQC 合格入库量后推进；整单质检结案只做终态校准。
        r.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        canonicalizeApprover(r);
        r.setApPosted(chargeable);
        receiptRepo.save(r);
        arrivalControl.recordApproval(
                ProcurementArrivalControlPort.SUBCONTRACT, id);
        em.flush();
        procurementValue.receiptApproved("SUBCONTRACT",id,currentUser.requireId());
        return detail(id);
    }
    /** Dedicated warehouse-arrival gateway; normal approval keeps its exact action authority. */
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
        var mutationGuard=mutationLocks.receipt("SUBCONTRACT",id);
        List<SubcontractReceiptItem> prelockItems =
                itemRepo.findByReceiptIdOrderByLineNoAsc(id);
        stockService.lockInventory(prelockItems.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        productionSupply.lockSubcontractReceiptMutationDimensions(id);
        SubcontractReceipt r = requireReceiptForUpdate(id);
        mutationGuard.verifyUnchanged();
        periodIdentityGuard.requireUnchanged(
                r.getSupplierId(), r.getCurrencyId(), r.getBillDate(),
                periodIdentity);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外进仓单");
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        List<SubcontractReceiptItem> items = itemRepo.findByReceiptIdOrderByLineNoAsc(id);
        requireSameInventoryDimensions(prelockItems, items);
        if (items.stream().anyMatch(it ->
                it.getReturnedQty() != null && it.getReturnedQty().signum() > 0)) {
            throw new ApiException(ErrorCode.BUSINESS, "委外进仓已有退货记录，请先红冲下游退货单");
        }
        // IQC：红冲前须质检结案；只反向仓库已确认入库量（无冻结行的历史单走全量）。
        inspectionService.requireResolvedForReverse(ProcurementInspectionPort.SUBCONTRACT, id);
        productionSupply.beforeSubcontractReceiptReversed(id);
        // 分析备料绑定对称反向：释放本进仓单建立的分析归属预留（V298）。
        preplanAnalysisPeg.releaseForReceipt(ProcurementInspectionPort.SUBCONTRACT, id);
        // 库存 advisory 锁已在任何 receipt/inspection/AP 行锁之前取得。
        // 反立帐（若有核销 amount_settled<>0 抛 IllegalStateException，对齐老库文案）
        consideration.reverseReceipt("SUBCONTRACT",id,UUID.randomUUID(),"委外收货红冲");
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
                BigDecimal replacementQty=iqcReplacementAllocation
                        .activeAllocatedQty("SUBCONTRACT",it.getId());
                BigDecimal firstReturnQty=it.getQty().subtract(replacementQty);
                if(firstReturnQty.signum()>0){
                    consumeIssuedMaterials(it.getId(),it.getOrderItemId(),firstReturnQty,-1);
                }
            }
        }
        iqcReplacementAllocation.reverseForReceipt(
                "SUBCONTRACT",r.getId(),"补货委外进仓红冲");
        r.setStatus(STATUS_REVERSED);
        r.setApPosted(false);
        // The downstream refresh validates the source's terminal state via a
        // native query, so make that state visible before invoking the hook.
        receiptRepo.saveAndFlush(r);
        arrivalControl.recordReversal(
                ProcurementArrivalControlPort.SUBCONTRACT, id);
        productionSupply.afterSubcontractReceiptReversed(id);
        procurementValue.receiptReversed("SUBCONTRACT",id,currentUser.requireId());
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
                direction < 0 ? "红冲" : null, it.getWeight()));
    }

    private static void requireSameInventoryDimensions(
            List<SubcontractReceiptItem> before,
            List<SubcontractReceiptItem> locked) {
        Map<UUID, InventoryKey> expected = before.stream().collect(
                java.util.stream.Collectors.toMap(
                        SubcontractReceiptItem::getId,
                        item -> new InventoryKey(item.getGoodsId(), item.getColorId())));
        Map<UUID, InventoryKey> actual = locked.stream().collect(
                java.util.stream.Collectors.toMap(
                        SubcontractReceiptItem::getId,
                        item -> new InventoryKey(item.getGoodsId(), item.getColorId())));
        if (!expected.equals(actual)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "委外进仓明细货品/颜色在库存预锁后发生变化，请刷新后重试");
        }
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

    /** 重算订货单结案：新链以 IQC 合格净量为准；无 IQC 的历史单兼容实到净量。 */
    private void recalcOrderClosed(UUID orderItemId) {
        ProcurementOrderClosurePolicy.recalculate(
                em, ProcurementOrderClosurePolicy.SUBCONTRACT, orderItemId);
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
     *   <li>反向(-1)只回退本回厂明细冻结的原发料切片；原消费来源未核定的历史单不按累计量猜源。</li>
     * </ul>
     *
     * <p>单位口径：回厂父件量（父件单据单位）× frozen_unit_qty（子件/父件）= 子件单据单位，与
     * at_supplier_qty / returned_qty / wasted_qty 同口径。
     */
    private void consumeIssuedMaterials(UUID receiptItemId, UUID orderItemId, BigDecimal receivedParentQty, int sign) {
        if (orderItemId == null || receivedParentQty == null || receivedParentQty.signum() == 0) return;
        if(sign<0){
            reverseReceiptMaterialConsumptions(receiptItemId);
            return;
        }
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
                            "委外订货明细下同一子件存在多个冻结 BOM 单耗版本(" + unitQty.stripTrailingZeros().toPlainString()
                                    + " / " + rowRate.stripTrailingZeros().toPlainString()
                                    + ")，无法确定回厂消费口径，请人工核销");
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
                                "委外回厂消费超过供应商在制余量(发料−已消费−已退−已损耗)，疑似超耗或错料，请人工核销");
                    }
                    em.createNativeQuery("""
                            INSERT INTO subcontract_receipt_material_consumptions(receipt_item_id,issue_item_id,
                                qty_doc,qty_base,consumption_basis,created_by)
                            SELECT :receipt,issue.id,:qty,:qty*COALESCE(issue.unit_rate,1),
                                CASE WHEN EXISTS(SELECT 1 FROM subcontract_material_plan_items plan
                                    JOIN subcontract_receipt_items receipt ON receipt.id=:receipt
                                    WHERE plan.id=issue.plan_item_id AND plan.flow_mode<>'LEGACY_BOM_COMPONENT'
                                      AND issue.goods_id=receipt.goods_id AND issue.color_id IS NOT DISTINCT FROM receipt.color_id
                                      AND issue.frozen_unit_qty*COALESCE(issue.unit_rate,1)=COALESCE(receipt.unit_rate,1))
                                    THEN 'DIRECT_TARGET' ELSE 'FROZEN_BOM_ESTIMATE' END,:actor
                            FROM subcontract_material_issue_items issue WHERE issue.id=:issue
                            """).setParameter("receipt",receiptItemId).setParameter("issue",(UUID)row[0])
                            .setParameter("qty",take).setParameter("actor",currentUser.requireId()).executeUpdate();
                    remaining = remaining.subtract(take);
                }
                if (remaining.signum() > 0) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "委外回厂消费超过供应商在制余量(发料−已消费−已退−已损耗)，疑似超耗或错料，请人工核销");
                }
            }
        }
    }

    private void reverseReceiptMaterialConsumptions(UUID receiptItemId){
        @SuppressWarnings("unchecked")
        List<Object[]> sources=em.createNativeQuery("""
                SELECT id,issue_item_id,qty_doc FROM subcontract_receipt_material_consumptions original
                WHERE receipt_item_id=:receipt AND reversal_of IS NULL
                  AND NOT EXISTS(SELECT 1 FROM subcontract_receipt_material_consumptions reversal WHERE reversal.reversal_of=original.id)
                ORDER BY issue_item_id,id
                """).setParameter("receipt",receiptItemId).getResultList();
        if(sources.isEmpty())throw new ApiException(ErrorCode.CONFLICT,"历史回厂未保存实际发料来源，须先核对原消费明细后红冲");
        for(Object[] source:sources){
            int updated=em.createNativeQuery("""
                    UPDATE subcontract_material_issue_items SET consumed_qty=consumed_qty-:qty
                    WHERE id=:issue AND consumed_qty>=:qty
                    """).setParameter("issue",source[1]).setParameter("qty",source[2]).executeUpdate();
            if(updated!=1)throw new ApiException(ErrorCode.CONFLICT,"原发料消费余量已变化，请刷新后重试");
            em.createNativeQuery("""
                    INSERT INTO subcontract_receipt_material_consumptions(receipt_item_id,issue_item_id,qty_doc,
                        qty_base,consumption_basis,reversal_of,created_by)
                    SELECT receipt_item_id,issue_item_id,qty_doc,qty_base,consumption_basis,id,:actor
                    FROM subcontract_receipt_material_consumptions WHERE id=:source
                    """).setParameter("source",source[0]).setParameter("actor",currentUser.requireId()).executeUpdate();
        }
    }

    /** V436 new flow: target-item receipt base quantity can never precede outbound. */
    private void requireTargetOutboundCapacity(
            List<SubcontractReceiptItem> items, UUID currentReceiptId) {
        com.uten.imp.common.finance.ProcurementOrderQuantityBounds.requireConsistentTargetBasis(em,
                items.stream().map(SubcontractReceiptItem::getOrderItemId).filter(java.util.Objects::nonNull).distinct().toList());
        Map<UUID, BigDecimal> currentBaseByOrderItem = new java.util.LinkedHashMap<>();
        for (SubcontractReceiptItem item : items) {
            if (item.getOrderItemId() == null) continue;
            BigDecimal rate = item.getUnitRate() == null
                    ? BigDecimal.ONE : item.getUnitRate();
            currentBaseByOrderItem.merge(item.getOrderItemId(),
                    item.getQty().multiply(rate), BigDecimal::add);
        }
        for (Map.Entry<UUID, BigDecimal> entry : currentBaseByOrderItem.entrySet()) {
            UUID orderItemId = entry.getKey();
            @SuppressWarnings("unchecked")
            List<Object[]> flowRows = em.createNativeQuery("""
                    SELECT plan_item.id
                    FROM subcontract_material_plan_items plan_item
                    WHERE plan_item.order_item_id = :orderItemId
                      AND plan_item.flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                      AND plan_item.is_deleted = FALSE
                    ORDER BY plan_item.id FOR UPDATE
                    """).setParameter("orderItemId", orderItemId).getResultList();
            if (flowRows.isEmpty()) continue;
            BigDecimal issuedBase = decimal(em.createNativeQuery("""
                    SELECT COALESCE(SUM(issue_item.qty * COALESCE(issue_item.unit_rate,1)),0)
                    FROM subcontract_material_issue_items issue_item
                    JOIN subcontract_material_issues issue
                      ON issue.id = issue_item.issue_id
                     AND issue.status = 1 AND issue.is_deleted = FALSE
                    JOIN subcontract_material_plan_items plan_item
                      ON plan_item.id = issue_item.plan_item_id
                     AND plan_item.flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                    WHERE issue_item.order_item_id = :orderItemId
                      AND issue_item.is_deleted = FALSE
                    """).setParameter("orderItemId", orderItemId).getSingleResult());
            BigDecimal receivedBase = decimal(em.createNativeQuery("""
                    SELECT COALESCE(SUM(receipt_item.qty * COALESCE(receipt_item.unit_rate,1)),0)
                    FROM subcontract_receipt_items receipt_item
                    JOIN subcontract_receipts receipt
                      ON receipt.id = receipt_item.receipt_id
                     AND receipt.status = 1 AND receipt.is_deleted = FALSE
                    WHERE receipt_item.order_item_id = :orderItemId
                      AND receipt_item.receipt_id <> :currentReceiptId
                      AND receipt_item.is_deleted = FALSE
                    """).setParameter("orderItemId", orderItemId)
                    .setParameter("currentReceiptId", currentReceiptId).getSingleResult());
            BigDecimal returnedFailureBase=iqcReplacementAllocation
                    .releasedCapacity("SUBCONTRACT",orderItemId).baseQty();
            if (receivedBase.add(entry.getValue())
                    .compareTo(issuedBase.add(returnedFailureBase)) > 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "委外目标件尚未足额出仓且无足够IQC失败返修额度，禁止超量回仓");
            }
        }
    }

    /**
     * 新流委外在创建/改写回厂草稿前按订货明细锁定同一把行锁，并扣除其它活动草稿。
     * 这既防重复登记，也与出仓红冲共享并发边界；没有新流 plan 的历史单继续按旧口径。
     * 审核时仍由 {@link #requireTargetOutboundCapacity(List, UUID)} 重新锁定并做权威校验。
     */
    private void lockAndRequireDraftOutboundCapacity(
            List<ReceiptItemLine> requestedItems,
            UUID currentReceiptId,
            List<UUID> additionalOrderItemIds) {
        Map<UUID, BigDecimal> requestedQty = new HashMap<>();
        if (requestedItems != null) {
            for (ReceiptItemLine item : requestedItems) {
                if (item == null || item.getOrderItemId() == null || item.getQty() == null) {
                    continue;
                }
                requestedQty.merge(item.getOrderItemId(), item.getQty(), BigDecimal::add);
            }
        }
        List<UUID> orderItemIds = java.util.stream.Stream.concat(
                        requestedQty.keySet().stream(),
                        additionalOrderItemIds == null
                                ? java.util.stream.Stream.empty()
                                : additionalOrderItemIds.stream())
                .filter(Objects::nonNull)
                .distinct()
                .sorted()
                .toList();
        if (orderItemIds.isEmpty()) return;

        String currentDraftExclusion = currentReceiptId == null
                ? ""
                : " AND draft.id <> :currentReceiptId";
        var query = em.createNativeQuery(("""
                SELECT order_item.id,
                       COALESCE(order_item.unit_rate, 1) AS order_unit_rate,
                       EXISTS (
                           SELECT 1
                           FROM subcontract_material_plan_items plan_item
                           WHERE plan_item.order_item_id = order_item.id
                             AND plan_item.flow_mode IN (
                                 'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                             AND plan_item.is_deleted = FALSE
                       ) AS new_flow,
                       COALESCE((
                           SELECT SUM(issue_item.qty * COALESCE(issue_item.unit_rate, 1))
                           FROM subcontract_material_issue_items issue_item
                           JOIN subcontract_material_issues issue
                             ON issue.id = issue_item.issue_id
                            AND issue.status = 1
                            AND issue.is_deleted = FALSE
                           JOIN subcontract_material_plan_items plan_item
                             ON plan_item.id = issue_item.plan_item_id
                            AND plan_item.flow_mode IN (
                                'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                            AND plan_item.is_deleted = FALSE
                           WHERE issue_item.order_item_id = order_item.id
                             AND issue_item.is_deleted = FALSE
                       ), 0) AS issued_base,
                       COALESCE((
                           SELECT SUM(rejection.failed_base_qty)
                           FROM procurement_iqc_rejection_cases rejection
                           WHERE rejection.receipt_type = 'SUBCONTRACT'
                             AND rejection.order_item_id = order_item.id
                             AND rejection.is_deleted = FALSE
                             AND rejection.return_recorded_at IS NOT NULL
                             AND rejection.status IN (
                                 'RETURN_RECORDED','CREDIT_CONFIRMED',
                                 'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                       ), 0) AS returned_failure_base,
                       COALESCE((
                           SELECT SUM(receipt_item.qty * COALESCE(receipt_item.unit_rate, 1))
                           FROM subcontract_receipt_items receipt_item
                           JOIN subcontract_receipts receipt
                             ON receipt.id = receipt_item.receipt_id
                            AND receipt.status = 1
                            AND receipt.is_deleted = FALSE
                           WHERE receipt_item.order_item_id = order_item.id
                             AND receipt_item.is_deleted = FALSE
                       ), 0) AS approved_receipt_base,
                       COALESCE((
                           SELECT SUM(draft_item.qty * COALESCE(draft_item.unit_rate, 1))
                           FROM subcontract_receipt_items draft_item
                           JOIN subcontract_receipts draft
                             ON draft.id = draft_item.receipt_id
                            AND draft.status = 0
                            AND draft.is_deleted = FALSE
                           WHERE draft_item.order_item_id = order_item.id
                             AND draft_item.is_deleted = FALSE
                """ + currentDraftExclusion + """
                       ), 0) AS active_draft_base
                FROM subcontract_order_items order_item
                WHERE order_item.id IN (:orderItemIds)
                  AND COALESCE(order_item.is_deleted, FALSE) = FALSE
                ORDER BY order_item.id
                FOR UPDATE OF order_item
                """)).setParameter("orderItemIds", orderItemIds);
        if (currentReceiptId != null) {
            query.setParameter("currentReceiptId", currentReceiptId);
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = query.getResultList();
        if (rows.size() != orderItemIds.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "委外回厂来源订货明细不存在或已删除");
        }
        for (Object[] row : rows) {
            UUID orderItemId = (UUID) row[0];
            if (!Boolean.TRUE.equals(row[2])) continue;
            BigDecimal requestedBase = requestedQty
                    .getOrDefault(orderItemId, BigDecimal.ZERO)
                    .multiply(decimal(row[1]));
            BigDecimal availableBase = decimal(row[3])
                    .add(decimal(row[4]))
                    .subtract(decimal(row[5]))
                    .subtract(decimal(row[6]))
                    .max(BigDecimal.ZERO);
            if (requestedBase.compareTo(availableBase) > 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "委外目标件真实出仓可回厂额度不足，或额度已被其它回厂草稿占用；请刷新预计到货任务");
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

    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.features.master.warehouse.WarehouseScopeService warehouseScopes;

    private void applyHeader(ReceiptSaveRequest req, SubcontractReceipt r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SUB_RECEIPT));
        }
        r.setBillDate(req.getBillDate());
        r.setSupplierId(req.getSupplierId());
        warehouseScopes.requireNewLeafSelection(r.getWarehouseId(), req.getWarehouseId(), "入库仓库");
        r.setWarehouseId(req.getWarehouseId());
        r.setCurrencyId(req.getCurrencyId());
        r.setExchangeRate(req.getExchangeRate()==null?null:com.uten.imp.common.util.FinancialExactAmount.rate(req.getExchangeRate(),"委外收货汇率"));
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
            it.setReplacementIntent(l.getReplacementIntent());
            it.setPrice(l.getPrice()==null?null:com.uten.imp.common.util.FinancialExactAmount.unitPrice(l.getPrice(),"委外收货单价"));
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
        boolean mask = !priceMasker.canViewSubcontractReceipt();
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
        boolean mask = !priceMasker.canViewSubcontractReceipt();
        ReceiptSourceRef sourceOrder = singleOrderSource(items);
        List<ReceiptItemDto> safeItems = mask
                ? items.stream().map(SubcontractReceiptService::maskItemPrices).toList()
                : items;
        return new ReceiptDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getSupplierId(), r.getWarehouseId(), mask ? null : r.getCurrencyId(),
                mask ? null : r.getExchangeRate(), mask ? null : r.getTaxRate(),
                r.getSenderId(), r.getMakerId(), r.getApproverId(), r.getLastDate(), r.isApPosted(), r.getRemark(),
                mask ? null : r.getTotalOriginal(), mask ? null : r.getTotalLocal(),
                r.getStatus(), r.isClosed(), r.getSourceDocNo(), safeItems,
                mask ? null : r.getSettlementStyleLegacy(), mask ? null : r.getSettlementMethodId(),
                r.getReceiverLegacyId(), r.getReceiverName(),
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

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }
}
