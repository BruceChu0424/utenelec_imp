package com.uten.imp.features.purchase.ret;

import com.uten.imp.common.web.HeaderColumnFilter;

import com.uten.imp.application.port.WarehouseUse;
import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.common.util.NameRefKeyword;
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


    private com.uten.imp.common.history.RetainedRecordReader retainedRecords;
    @org.springframework.beans.factory.annotation.Autowired
    public void setRetainedRecords(com.uten.imp.common.history.RetainedRecordReader reader) { retainedRecords = reader; }


    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.application.port.InventoryPositionPort unapprovalPositions;
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.application.port.InventoryValuationPort unapprovalValues;

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
    private final com.uten.imp.common.concurrency.ProcurementMutationLocks mutationLocks;

    @Autowired
    private CommercialPriceVisibility commercialPriceVisibility;

    @Transactional(readOnly = true)
    public PageResponse<ReturnListItem> list(ReturnQueryFilter f, int page, int size, String sort, String order) {
        boolean priceMasked = purchasePriceMasked();
        Specification<PurchaseReturn> spec = returnSpec(f);
        // 列排序：sort 命中白名单(日期/金额/单据号)才按实体属性排序，否则默认 billDate DESC。
        // 2026-09-25 单号列统一：billNo 进两分支白名单（价格遮蔽只挡金额排序）。
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"),
                        priceMasked
                                ? Map.of("billDate", "billDate", "billNo", "billNo")
                                : Map.of("billDate", "billDate", "total", "totalLocal", "billNo", "billNo")));
        var searchPage = NameRefKeyword.page(spec, pageable, f.keyword());
        Page<PurchaseReturn> p = returnRepo.findAll(searchPage.specification(), searchPage.pageable());
        PageResponse<ReturnListItem> result = new PageResponse<>(p.map(row -> toList(row, priceMasked)).getContent(),
                p);
        return p.stream().noneMatch(PurchaseReturn::isDeleted) ? result
                : retainedRecords.page(result, "purchase_returns", p.getContent());
    }

    /** 单据号列值筛选桶（2026-09-25 单号列统一）：与列表同一份谓词分组计数。 */
    @Transactional(readOnly = true)
    public java.util.Map<String, List<java.util.Map<String, Object>>> facets(ReturnQueryFilter f) {
        return java.util.Map.of("billNo",
                com.uten.imp.common.web.TableFacets.groupCount(em, PurchaseReturn.class, returnSpec(f), "billNo"));
    }

    /** 列表/桶共用的谓词基座（2026-09-25 单号列统一抽出）。 */
    private Specification<PurchaseReturn> returnSpec(ReturnQueryFilter f) {
        var readScope = access.scope();
        return (Root<PurchaseReturn> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                              CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            if (f.onlyDeleted()) ps.add(cb.isTrue(root.get("deleted")));
            else if (!f.includeDeleted()) ps.add(cb.isFalse(root.get("deleted")));
            ps.add(access.readablePredicate(root, cb, "makerId", readScope));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                // 全行可搜（2026-10-09「行里显示什么就能按什么搜」）：单据号 + 供应商名称
                // + 仓库名称（名称经 NameRefKeyword 转成外键 IN 子查询，count 同谓词派生）。
                ps.add(NameRefKeyword.match(root, q, cb, f.keyword(), kw -> {
                var kws = NameRefKeyword.keywords();
                kws.add(NameRefKeyword.text(cb, root.get("billNo"), kw));
                NameRefKeyword.byName(kws, q, cb, root.get("supplierId"),
                        com.uten.imp.features.master.supplier.Supplier.class, "name", kw);
                NameRefKeyword.byName(kws, q, cb, root.get("supplierId"),
                        com.uten.imp.features.master.supplier.Supplier.class, "code", kw);
                NameRefKeyword.byName(kws, q, cb, root.get("warehouseId"),
                        com.uten.imp.features.master.warehouse.Warehouse.class, "name", kw);
                return cb.or(kws.toArray(new Predicate[0]));
                }));
            }
            if (f.supplierId() != null) ps.add(cb.equal(root.get("supplierId"), f.supplierId()));
            if (f.warehouseId() != null) ps.add(cb.equal(root.get("warehouseId"), f.warehouseId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            // 2026-09-25 单号列统一：单据号表头值筛选（精确匹配）。
            if (f.billNo() != null && !f.billNo().isBlank()) {
                ps.add(cb.equal(root.get("billNo"), f.billNo().trim()));
            }
            f.headerFilters().apply(root, cb, ps, "totalLocal", commercialPriceVisibility != null && commercialPriceVisibility.canViewPurchaseReturn(), null, false, null, false);
            f.headerFilters().applySearch(root, q, cb, ps, java.util.Map.of(
                    "billNo", HeaderColumnFilter.SearchField.text("billNo"),
                    "supplier", HeaderColumnFilter.SearchField.reference("supplierId", com.uten.imp.features.master.supplier.Supplier.class),
                    "warehouse", HeaderColumnFilter.SearchField.reference("warehouseId", com.uten.imp.features.master.warehouse.Warehouse.class).withParent("parentId")));
            return cb.and(ps.toArray(new Predicate[0]));
        };
    }

    @Transactional(readOnly=true,noRollbackFor=ApiException.class)
    public ReturnDetail detail(UUID id) { return readDetail(id, false); }


    @Transactional(readOnly = true)
    public ReturnDetail detailHistory(UUID id) { return readDetail(id, true); }

    private ReturnDetail readDetail(UUID id, boolean historyRead) {
        PurchaseReturn r = requireReturn(id, historyRead);
        access.requireReadable(r.getMakerId(), "采购退货单不存在");
        List<ReturnItemDto> items = itemRepo.findByReturnIdOrderByLineNoAsc(id).stream().map(this::toItemDto).toList();
        return finishHistory(toDetail(r, items), r, historyRead);
    }

    @Transactional
    @PreAuthorize("hasAuthority('purchase_return:create')")
    @com.uten.imp.common.platformcolumns.PlatformColumnDocumentSave(scope="purchase_return_item")
    public ReturnDetail create(ReturnSaveRequest req) {
        tx.bind();
        lockReturnRequest(null,req).verifyUnchanged();
        com.uten.imp.common.finance.ProcurementTerminatedReceiptBasis.requireMutable(em,"PURCHASE",
                req.getItems().stream().map(ReturnItemLine::getOrderItemId).toList());
        com.uten.imp.common.finance.ProcurementTerminatedReceiptBasis.requireReceiptItemsMutable(em,"PURCHASE",
                req.getItems().stream().map(ReturnItemLine::getReceiptItemId).toList());
        PurchaseReturn r = new PurchaseReturn();
        r.setQuantitySemantics(com.uten.imp.common.finance.ProcurementQuantities.EXTRA_GIFT);
        applyHeader(req, r, returnHeader(req));
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户
        r.setStatus(STATUS_DRAFT);
        returnRepo.save(r);
        List<ReturnItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    /** Preserve the business prefix, header lock and source check before the field snapshot. */
    @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
    @PreAuthorize("hasAuthority('purchase_return:edit')")
    public void lockPlatformColumnSave(UUID id, ReturnSaveRequest request) {
        tx.bind();
        var guard = lockReturnRequest(id, request);
        requireReturnForUpdate(id);
        guard.verifyUnchanged();
    }

    @Transactional
    @PreAuthorize("hasAuthority('purchase_return:edit')")
    @com.uten.imp.common.platformcolumns.PlatformColumnDocumentSave(scope="purchase_return_item", requestArgument=1, documentIdArgument=0)
    public ReturnDetail update(UUID id, ReturnSaveRequest req) {
        tx.bind();
        var mutationGuard=lockReturnRequest(id,req);
        PurchaseReturn r = requireReturnForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的采购退货单");
        if (r.getStatus() != STATUS_DRAFT) throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        mutationGuard.verifyUnchanged();
        if(req.isConfirmGiftSemantics())r.setQuantitySemantics(com.uten.imp.common.finance.ProcurementQuantities.EXTRA_GIFT);
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
        var mutationGuard=mutationLocks.productReturn("PURCHASE",id);
        PurchaseReturn r = requireReturnForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的采购退货单");
        com.uten.imp.common.web.StandardDocumentLifecycleCapabilities.requireDraftForDelete(r.getStatus());
        mutationGuard.verifyUnchanged();
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        returnRepo.save(r);
    }

    private com.uten.imp.application.concurrency.FulfillmentMutationLocks.Guard lockReturnRequest(UUID id,ReturnSaveRequest req) {
        List<ReturnItemLine> lines=req==null||req.getItems()==null?List.of():req.getItems();
        var present=lines.stream().filter(java.util.Objects::nonNull).toList();
        return mutationLocks.returnInputs("PURCHASE",id,false,present.stream().map(ReturnItemLine::getOrderItemId).toList(),
                present.stream().map(ReturnItemLine::getReceiptItemId).toList(),present.stream().filter(line->line.getGoodsId()!=null)
                        .map(line->new com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension(line.getGoodsId(),line.getColorId())).toList(),
                req==null?null:req.getWarehouseId());
    }

    /** 审核：库存出库 + 回写收货/订货明细 returned_qty + 订货结案重算。 */
    @Transactional
    @PreAuthorize("hasAuthority('purchase_return:approve')")
    public ReturnDetail approve(UUID id) {
        tx.bind();
        SupplierPeriodIdentityGuard.Identity periodIdentity =
        periodIdentityGuard.requireIdentity(SourceTable.PURCHASE_RETURN, id);
        periodIdentityGuard.requireOpenAtBillDate(periodIdentity, "采购退货审核");
        var mutationGuard=mutationLocks.productReturn("PURCHASE",id);
        PurchaseReturn r = requireReturnForUpdate(id);
        mutationGuard.verifyUnchanged();
        periodIdentityGuard.requireUnchanged(
                r.getSupplierId(), r.getCurrencyId(), r.getBillDate(),
                periodIdentity);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的采购退货单");
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT)
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        if (r.getWarehouseId() == null) throw new ApiException(ErrorCode.BUSINESS, "退货单需指定仓库");
        List<PurchaseReturnItem> items = itemRepo.findByReturnIdOrderByLineNoAsc(id);
        com.uten.imp.common.finance.ProcurementTerminatedReceiptBasis.requireMutable(em,"PURCHASE",
                items.stream().map(PurchaseReturnItem::getOrderItemId).toList());
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
        if(returnOriginal.signum()!=0||returnLocal.signum()!=0)arApService.postArAp(new ArApLedgerService.ArApPostingRequest(
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
    @Transactional(readOnly=true,noRollbackFor=ApiException.class)
    @PreAuthorize("hasAuthority('purchase_return:view')")
    public com.uten.imp.application.port.DocumentUnapprovalPort.Eligibility unapprovalEligibility(UUID id){
        detail(id);var r=requireReturn(id);
        return com.uten.imp.common.finance.ProcurementUnapprovalPreflight.evaluate(em,"purchaseReturn","purchase_returns",id,"purchase_return:reverse",()->unapprovalDependencyFacts(id),
            com.uten.imp.common.finance.ProcurementUnapprovalPreflight.check("DOCUMENT_REVERSE_BLOCKED",()->requireUnapprovalHeader(r)),
            com.uten.imp.common.finance.ProcurementUnapprovalPreflight.check("SUPPLIER_PERIOD_CLOSED",()->periodIdentityGuard.requireOpenTodayReadOnly(periodIdentityGuard.requireIdentity(SourceTable.PURCHASE_RETURN,id),"采购退货反审")),
            com.uten.imp.common.finance.ProcurementUnapprovalPreflight.check("DOWNSTREAM_OR_COST_BLOCKED",()->requireReversibleBusiness(r)));
    }
    private void requireUnapprovalHeader(PurchaseReturn r){
        com.uten.imp.common.finance.ProcurementTerminatedReceiptBasis.requireMutable(em,"PURCHASE",
                itemRepo.findByReturnIdOrderByLineNoAsc(r.getId()).stream().map(PurchaseReturnItem::getOrderItemId).toList());
        access.requireWritable(r.getMakerId(),"只能操作本人负责的采购退货单");
        com.uten.imp.common.web.ImportedDocumentLifecycleCapabilities.requireMutable(r.getLegacyId());
        if(r.getStatus()==null||r.getStatus()!=STATUS_APPROVED)throw new ApiException(ErrorCode.BUSINESS,"仅已审核单据可反审");
    }
    private void requireReversibleBusiness(PurchaseReturn r){UUID id=r.getId();
        var items=itemRepo.findByReturnIdOrderByLineNoAsc(id);
        requireNonNegativeStoredCommercial(r,items);
        if(r.getTotalOriginal().signum()!=0||r.getTotalLocal().signum()!=0)requireReversibleArAp(id,StockService.SRC_PURCHASE_RETURN);
        arApService.requireReturnCostProjectionReversible(id,StockService.SRC_PURCHASE_RETURN,r.getBillNo(),r.getBillDate());
        List<com.uten.imp.application.port.InventoryValuationPort.IssueReturnSource> sources=new java.util.ArrayList<>();
        for(var item:items){
            var original=com.uten.imp.common.util.NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id,warehouse_id,goods_id,color_id,qty FROM stock_movements
                WHERE source_doc_type=:type AND source_doc_id=:doc AND source_item_id=:item AND movement_type=:movement AND direction=-1 ORDER BY ledger_seq
                """).setParameter("type",StockService.SRC_PURCHASE_RETURN).setParameter("doc",id).setParameter("item",item.getId()).setParameter("movement",StockService.TYPE_PURCHASE_RETURN));
            if(original.size()!=1)throw new ApiException(ErrorCode.CONFLICT,"原退货实物出库来源缺失或重复，请专项核对");
            var row=original.getFirst();sources.add(new com.uten.imp.application.port.InventoryValuationPort.IssueReturnSource(new com.uten.imp.application.port.InventoryValuationPort.PoolKey((UUID)row[1],(UUID)row[2],(UUID)row[3]),(UUID)row[0],(BigDecimal)row[4]));
        }
        unapprovalValues.requireIssueReturnsAvailable(sources);
        requireReturnCounterBalances(id);
    }
    private void requireReversibleArAp(UUID id,String type){
        try{arApService.requireReversibleSource(id,type);}
        catch(IllegalStateException denied){throw new ApiException(ErrorCode.CONFLICT,denied.getMessage());}
    }
    private void requireReturnCounterBalances(UUID id){
        var receipt=com.uten.imp.common.util.NativeQueryResults.objectArrayRows(em.createNativeQuery("""
            SELECT SUM(line.qty),COALESCE(original.returned_qty,0),SUM(CASE WHEN line.quantity_semantics='CHARGED_PLUS_GIFT_V1' THEN line.gift_qty ELSE 0 END),original.gift_returned_qty
            FROM purchase_return_items line JOIN purchase_receipt_items original ON original.id=line.receipt_item_id
            WHERE line.return_id=:id GROUP BY original.id ORDER BY original.id
            """).setParameter("id",id));
        for(Object[] row:receipt)if(((BigDecimal)row[0]).compareTo((BigDecimal)row[1])>0||((BigDecimal)row[2]).compareTo((BigDecimal)row[3])>0)throw new ApiException(ErrorCode.CONFLICT,"原来源累计已退数量不足以完整反审");
        var order=com.uten.imp.common.util.NativeQueryResults.objectArrayRows(em.createNativeQuery("""
            SELECT SUM(line.qty),COALESCE(original.returned_qty,0),SUM(CASE WHEN line.quantity_semantics='CHARGED_PLUS_GIFT_V1' THEN line.gift_qty ELSE 0 END),original.gift_returned_qty
            FROM purchase_return_items line JOIN purchase_order_items original ON original.id=line.order_item_id
            WHERE line.return_id=:id GROUP BY original.id ORDER BY original.id
            """).setParameter("id",id));
        for(Object[] row:order)if(((BigDecimal)row[0]).compareTo((BigDecimal)row[1])>0||((BigDecimal)row[2]).compareTo((BigDecimal)row[3])>0)throw new ApiException(ErrorCode.CONFLICT,"原来源累计已退数量不足以完整反审");
    }

    private String unapprovalDependencyFacts(UUID id){return String.valueOf(em.createNativeQuery("""
        SELECT jsonb_build_object(
            'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY line.id) FROM purchase_return_items line WHERE line.return_id=:id),
            'arAp',(SELECT jsonb_agg(to_jsonb(ledger) ORDER BY ledger.id) FROM ar_ap_ledger ledger WHERE ledger.source_doc_id=:id),
            'vouchers',(SELECT jsonb_agg(to_jsonb(voucher) ORDER BY voucher.id) FROM gl_vouchers voucher WHERE voucher.source_doc_id=:id),
            'supplierPeriods',(SELECT jsonb_agg(to_jsonb(batch) ORDER BY batch.id) FROM supplier_settlement_batches batch JOIN purchase_returns doc ON doc.supplier_id=batch.supplier_id AND doc.currency_id=batch.currency_id WHERE doc.id=:id),
            'movements',(SELECT jsonb_agg(to_jsonb(movement) ORDER BY movement.id) FROM stock_movements movement WHERE movement.source_doc_id=:id),
            'inspection',(SELECT jsonb_agg(to_jsonb(inspection) ORDER BY inspection.id) FROM procurement_inspection_items inspection WHERE inspection.receipt_type='PURCHASE' AND inspection.receipt_id=:id),
            'cases',(SELECT jsonb_agg(to_jsonb(rejection) ORDER BY rejection.id) FROM procurement_iqc_rejection_cases rejection WHERE rejection.receipt_type='PURCHASE' AND rejection.receipt_id=:id),
            'poolHeads',(SELECT jsonb_agg(to_jsonb(pool) ORDER BY pool.id) FROM stock_value_pools pool WHERE (pool.goods_id,pool.color_id) IN(SELECT goods_id,color_id FROM purchase_return_items WHERE return_id=:id)))::text
        """).setParameter("id",id).getSingleResult());}

    @Transactional
    @PreAuthorize("hasAuthority('purchase_return:reverse')")
    public ReturnDetail reverse(UUID id) {
        tx.bind();
        SupplierPeriodIdentityGuard.Identity periodIdentity =
        periodIdentityGuard.requireIdentity(SourceTable.PURCHASE_RETURN, id);
        periodIdentityGuard.requireOpenToday(periodIdentity, "采购退货红冲");
        var mutationGuard=mutationLocks.productReturn("PURCHASE",id);
        PurchaseReturn r = requireReturnForUpdate(id);
        mutationGuard.verifyUnchanged();
        periodIdentityGuard.requireUnchanged(
                r.getSupplierId(), r.getCurrencyId(), r.getBillDate(),
                periodIdentity);
        requireUnapprovalHeader(r);
        List<PurchaseReturnItem> items = itemRepo.findByReturnIdOrderByLineNoAsc(id);
        requireNonNegativeStoredCommercial(r, items);
        // KS-P1-2：先取库存 advisory 锁，再 reverseArAp 锁 AP 行——与 approve（先 lockInventory 后 postArAp）锁序一致。
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        arApService.reverseReturnCostProjection(r.getId(),StockService.SRC_PURCHASE_RETURN,r.getBillNo(),r.getBillDate());
        if(r.getTotalOriginal().signum()!=0||r.getTotalLocal().signum()!=0)
            arApService.reverseArAp(r.getId(), StockService.SRC_PURCHASE_RETURN);
        OffsetDateTime now = OffsetDateTime.now();
        for (PurchaseReturnItem it : items) {
            reverseOriginalMovement(r,it,now);
            writeback(it, -1);
        }
        r.setStatus(STATUS_REVERSED);
        returnRepo.save(r);
        arrivalControl.refreshAfterReturn(ProcurementArrivalControlPort.PURCHASE,
                items.stream().map(PurchaseReturnItem::getOrderItemId).toList());
        return detail(id);
    }


    private void reverseOriginalMovement(PurchaseReturn document,PurchaseReturnItem item,OffsetDateTime now){
        var rows=com.uten.imp.common.util.NativeQueryResults.objectArrayRows(em.createNativeQuery("""
            SELECT movement.id,movement.goods_id,movement.color_id,movement.warehouse_id,movement.qty,movement.unit_id,movement.unit_rate
            FROM stock_movements movement WHERE source_doc_type=:kind AND source_doc_id=:doc AND source_item_id=:item
                AND movement_type=:type AND direction=-1 ORDER BY ledger_seq FOR UPDATE
            """).setParameter("kind",StockService.SRC_PURCHASE_RETURN).setParameter("doc",document.getId())
                .setParameter("item",item.getId()).setParameter("type",StockService.TYPE_PURCHASE_RETURN));
        if(rows.size()!=1)throw new ApiException(ErrorCode.CONFLICT,"原采购退货出库数量或成本来源缺失/重复，请专项核对后撤销");
        Object[] original=rows.getFirst();
        stockService.recordMovement(new StockService.MovementRequest(now,StockService.TYPE_PURCHASE_RETURN,StockService.SRC_PURCHASE_RETURN,
            document.getId(),item.getId(),(UUID)original[1],(UUID)original[2],(UUID)original[3],StockService.DIR_IN,
            (BigDecimal)original[4],(UUID)original[5],(BigDecimal)original[6],null,"采购退货反审镜像原出库",null,
            new com.uten.imp.application.port.InventoryMovementCostReference.OriginalIssueMovement((UUID)original[0])));
    }

    private void applyMovement(PurchaseReturn r, PurchaseReturnItem it, short direction, OffsetDateTime ts, BigDecimal overrideAmount) {
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        var q=com.uten.imp.common.finance.ProcurementQuantities.of(it.getQuantitySemantics(),it.getQty(),it.getGiftQty(),rate);
        BigDecimal baseQty = com.uten.imp.common.finance.ProcurementQuantities.isExtraGift(it.getQuantitySemantics())
                && it.getChargedBaseQty()!=null && it.getGiftBaseQty()!=null
                ? it.getChargedBaseQty().add(it.getGiftBaseQty()) : q.physicalBase();
        BigDecimal amt = overrideAmount != null ? overrideAmount : it.getAmountLocal();
        stockService.recordMovement(new StockService.MovementRequest(
                ts, StockService.TYPE_PURCHASE_RETURN, StockService.SRC_PURCHASE_RETURN,
                r.getId(), it.getId(), it.getGoodsId(), it.getColorId(), r.getWarehouseId(),
                direction, baseQty, it.getUnitId(), it.getUnitRate(), amt,
                // 退货单不是仓库称重单据: 不带重量, 由库存账推算; 红冲按原流水镜像(ADR-135)。
                direction < 0 ? "红冲" : null, null));
    }

    /** 逐行校验退量不超过来源收货明细可退余量（已收 − 已退），超退给业务 409。 */
    private void requireReceiptReturnCapacity(List<PurchaseReturnItem> items) {
        for (PurchaseReturnItem it : items) {
            if (it.getReceiptItemId() == null) continue;
            Object[] row = (Object[]) em.createNativeQuery("""
                            SELECT COALESCE(qty, 0), COALESCE(returned_qty, 0),quantity_semantics,gift_qty,gift_returned_qty
                            FROM purchase_receipt_items
                            WHERE id = :id
                            """)
                    .setParameter("id", it.getReceiptItemId())
                    .getSingleResult();
            BigDecimal capacity = ((BigDecimal) row[0]).subtract((BigDecimal) row[1]);
            if(com.uten.imp.common.finance.ProcurementQuantities.isExtraGift(it.getQuantitySemantics()) && it.getGiftQty().signum()>0
                    && (!com.uten.imp.common.finance.ProcurementQuantities.isExtraGift((String)row[2]) || it.getGiftQty().compareTo(((BigDecimal)row[3]).subtract((BigDecimal)row[4]))>0))
                throw new ApiException(ErrorCode.CONFLICT,"赠品退货超过来源实物未退数量");
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
                    "UPDATE purchase_receipt_items SET returned_qty=COALESCE(returned_qty,0)+(:q*:s),gift_returned_qty=gift_returned_qty+(:gift*:s) WHERE id=:id")
                    .setParameter("q", it.getQty()).setParameter("s", sign).setParameter("gift", com.uten.imp.common.finance.ProcurementQuantities.isExtraGift(it.getQuantitySemantics())?it.getGiftQty():BigDecimal.ZERO)
                    .setParameter("id", it.getReceiptItemId()).executeUpdate();
        }
        if (it.getOrderItemId() != null) {
            em.createNativeQuery(
                    "UPDATE purchase_order_items SET returned_qty=COALESCE(returned_qty,0)+(:q*:s),gift_returned_qty=gift_returned_qty+(:gift*:s) WHERE id=:id")
                    .setParameter("q", it.getQty()).setParameter("s", sign).setParameter("gift", com.uten.imp.common.finance.ProcurementQuantities.isExtraGift(it.getQuantitySemantics())?it.getGiftQty():BigDecimal.ZERO)
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
            warehouseScopes.require(r.getWarehouseId(), req.getWarehouseId(), "仓库", WarehouseUse.DISPOSAL_OUT);
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
            if(l.getPrice()!=null&&l.getPrice().signum()<0)throw new ApiException(ErrorCode.VALIDATION_FAILED,"采购退货单价不能为负数");
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
            var q=com.uten.imp.common.finance.ProcurementQuantities.of(r.getQuantitySemantics(),l.getQty(),l.getGiftQty(),resolvedUnit.unitRate());
            it.setQuantitySemantics(r.getQuantitySemantics());it.setQty(q.charged());
            it.setGiftQty(com.uten.imp.common.util.FinancialExactAmount.optionalNonNegativeQuantity(l.getGiftQty(),"采购退货赠品数量"));
            it.setChargedBaseQty(q.chargedBase());it.setGiftBaseQty(q.giftBase());
            it.setPrice(l.getPrice());
            // 金额只由服务端派生(ADR-112): 数量 × 单价 × 表头汇率; 单价空则金额空, 汇率空则本币空。
            MoneyPolicy.LineAmounts amounts = q.charged().signum()==0?new MoneyPolicy.LineAmounts(BigDecimal.ZERO,BigDecimal.ZERO):MoneyPolicy.line(l.getQty(), it.getPrice(), null, r.getExchangeRate());
            it.setAmountOriginal(amounts.original());
            it.setAmountLocal(amounts.local());
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
            com.uten.imp.common.finance.ProcurementQuantities.of(item.getQuantitySemantics(),item.getQty(),item.getGiftQty(),item.getUnitRate());
            if(item.getPrice()!=null&&item.getPrice().signum()<0 || item.getAmountOriginal()!=null&&item.getAmountOriginal().signum()<0 || item.getAmountLocal()!=null&&item.getAmountLocal().signum()<0)
                throw new ApiException(ErrorCode.CONFLICT,"采购退货金额异常");
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
        ReturnItemDto dto=new ReturnItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getReceiptItemId(), it.getOrderItemId(), it.getWeight(),
                it.getSourceDocNo(), it.getRemark());
        dto.setQuantitySemantics(it.getQuantitySemantics());dto.setGiftQty(it.getGiftQty());return dto;
    }

    private ReturnDetail toDetail(PurchaseReturn r, List<ReturnItemDto> items) {
        boolean priceMasked = purchasePriceMasked();
        List<ReturnItemDto> safeItems = priceMasked
                ? items.stream().map(PurchaseReturnService::maskItemPrices).toList()
                : items;
        return new ReturnDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getSupplierId(), r.getWarehouseId(), priceMasked ? null : r.getCurrencyId(),
                priceMasked ? null : r.getExchangeRate(), priceMasked ? null : r.getTaxRate(),
                r.getReceiverId(), nameResolver.nameWithCodeOf(r.getReceiverId()),
                priceMasked ? null : r.getSettlementMethodId(),
                priceMasked || r.getSettlementStyleLegacy() == null
                        ? null : r.getSettlementStyleLegacy().intValue(),
                r.getMakerId(), r.getApproverId(), r.getRemark(),
                priceMasked ? null : r.getTotalOriginal(), priceMasked ? null : r.getTotalLocal(),
                r.getStatus(), r.isClosed(), r.getSourceDocNo(), safeItems,
                nameResolver.nameWithCodeOf(r.getMakerId()), r.getCreatedAt(), priceMasked);
    }

    private boolean purchasePriceMasked() {
        return commercialPriceVisibility == null
                || !commercialPriceVisibility.canViewPurchaseReturn();
    }

    private static ReturnItemDto maskItemPrices(ReturnItemDto it) {
        ReturnItemDto dto=new ReturnItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(), it.getUnitId(), it.getUnitRate(),
                it.getQty(), null, null, null, it.getReceiptItemId(), it.getOrderItemId(),
                it.getWeight(), it.getSourceDocNo(), it.getRemark());
        dto.setQuantitySemantics(it.getQuantitySemantics());dto.setGiftQty(it.getGiftQty());return dto;
    }


    private PurchaseReturn requireReturn(UUID id) { return requireReturn(id, false); }

    private PurchaseReturn requireReturn(UUID id, boolean includeDeleted) {
        return returnRepo.findById(id).filter(r -> includeDeleted || !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "采购退货单不存在"));
    }
    private PurchaseReturn requireReturnForUpdate(UUID id) {
        PurchaseReturn purchaseReturn = em.find(
                PurchaseReturn.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        return purchaseReturn == null || purchaseReturn.isDeleted()
                ? requireReturn(id)
                : purchaseReturn;
    }

    private ReturnDetail finishHistory(ReturnDetail view, PurchaseReturn entity, boolean historyRead) {
        if (!historyRead && !entity.isDeleted()) return view;
        return retainedRecords.detail(view, "purchase_returns", entity.getId(), entity.isDeleted(), entity.getDeletedAt(), historyRead);
    }

    @Transactional(readOnly = true)
    public java.util.List<com.uten.imp.common.history.RetainedRecordReader.RetainedRow> historyRows(UUID id, Long beforeId, int size) {
        var document=detailHistory(id);
        com.uten.imp.common.history.RetainedRecordAccess.requireUnmaskedCostOriginal(document.isPriceMasked());
        return retainedRecords.children("purchase_returns",id,beforeId,size);
    }
}
