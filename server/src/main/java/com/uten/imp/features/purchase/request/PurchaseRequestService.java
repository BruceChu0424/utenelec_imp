package com.uten.imp.features.purchase.request;

import com.uten.imp.application.port.WarehouseUse;
import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.application.port.OrganizationReferencePort;

import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.purchase.PurchaseGoodsSnapshot;
import com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy;
import com.uten.imp.features.purchase.request.dto.DecompositionPreviewItem;
import com.uten.imp.features.purchase.request.dto.RequestDetail;
import com.uten.imp.features.purchase.request.dto.RequestItemDto;
import com.uten.imp.features.purchase.request.dto.RequestItemLine;
import com.uten.imp.features.purchase.request.dto.RequestListItem;
import com.uten.imp.features.purchase.request.dto.RequestQueryFilter;
import com.uten.imp.features.purchase.request.dto.RequestSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
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
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * 采购申请单服务：CRUD + 审核。链路起点：审核无库存联动、无上游回写
 * （被订货单审核时回写 ordered_qty + is_closed）。
 */
@Service
@RequiredArgsConstructor
public class PurchaseRequestService {
    private com.uten.imp.common.history.RetainedRecordReader retainedRecords;
    @org.springframework.beans.factory.annotation.Autowired
    public void setRetainedRecords(com.uten.imp.common.history.RetainedRecordReader reader) { retainedRecords = reader; }

    /** Same pending financial commitment on the detail and order-generation paths.
     * The correlated lookup uses the request-item index instead of aggregating every order source. */
    private static final String PENDING_ORDER_QUANTITY_JOIN = """
            LEFT JOIN LATERAL (
                SELECT COALESCE(SUM(part.qty), 0) AS pending_qty
                FROM (
                    SELECT src.alloc_qty AS qty, oi.order_id
                    FROM purchase_order_item_sources src
                    JOIN purchase_order_items oi ON oi.id=src.order_item_id AND NOT oi.is_deleted
                    WHERE src.request_item_id=i.id
                    UNION ALL
                    SELECT oi.qty, oi.order_id FROM purchase_order_items oi
                    WHERE oi.request_item_id=i.id AND NOT oi.is_deleted
                      AND NOT EXISTS(SELECT 1 FROM purchase_order_item_sources src WHERE src.order_item_id=oi.id)
                ) part
                JOIN purchase_orders o ON o.id=part.order_id
                WHERE o.status = 0 AND o.is_deleted = FALSE
                  AND EXISTS (
                      SELECT 1 FROM procurement_order_approval_cases approval
                      WHERE approval.order_type = 'PURCHASE' AND approval.order_id = o.id
                        AND approval.status = 'PENDING')
            ) pending ON TRUE
            """;

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    private final PurchaseRequestRepository requestRepo;
    private final PurchaseRequestItemRepository itemRepo;
    // V476：叶子仓落库校验。字段注入+可空——单测手工构造时缺省跳过，Spring 环境恒注入。
    @org.springframework.beans.factory.annotation.Autowired(required = false)
    private com.uten.imp.features.master.warehouse.WarehouseScopeService warehouseScopes;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final DocNumberService docNumberService;
    private final jakarta.persistence.EntityManager em;
    private final ProductionSupplySourceGuard productionSourceGuard;
    private final PurchaseLineUnitPolicy lineUnitPolicy;
    private final TaskClaimService taskClaim;
    private final OrganizationReferencePort organizationReferences;
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.common.concurrency.ProcurementMutationLocks mutationLocks;

    @Transactional(readOnly = true)
    public PageResponse<RequestListItem> list(RequestQueryFilter f, int page, int size, String sort, String order) {
        Specification<PurchaseRequest> spec = requestSpec(f);
        // 列排序：sort 命中白名单(日期/金额/单据号)才按实体属性排序，否则默认 billDate DESC。
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"),
                        Map.of("billDate", "billDate", "total", "totalLocal", "billNo", "billNo")));
        Page<PurchaseRequest> p = requestRepo.findAll(spec, pageable);
        PageResponse<RequestListItem> result = new PageResponse<>(p.map(this::toList).getContent(), p);
        return p.stream().noneMatch(PurchaseRequest::isDeleted) ? result
                : retainedRecords.page(result, "purchase_requests", p.getContent());
    }

    /** 单据号列值筛选桶（2026-09-25 单号列统一）：与列表同一份谓词分组计数。 */
    @Transactional(readOnly = true)
    public java.util.Map<String, List<java.util.Map<String, Object>>> facets(RequestQueryFilter f) {
        return java.util.Map.of("billNo",
                com.uten.imp.common.web.TableFacets.groupCount(em, PurchaseRequest.class, requestSpec(f), "billNo"));
    }

    private Specification<PurchaseRequest> requestSpec(RequestQueryFilter f) {
        return (Root<PurchaseRequest> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            if (f.onlyDeleted()) ps.add(cb.isTrue(root.get("deleted")));
            else if (!f.includeDeleted()) ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
            }
            if (f.warehouseId() != null) ps.add(cb.equal(root.get("warehouseId"), f.warehouseId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            if (f.billNo() != null && !f.billNo().isBlank()) {
                ps.add(cb.equal(root.get("billNo"), f.billNo().trim()));
            }
            f.headerFilters().apply(root, cb, ps, null, false, null, false, null, false);
            return cb.and(ps.toArray(new Predicate[0]));
        };
    }

    @Transactional(readOnly = true, isolation = org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public RequestDetail detail(UUID id) { return readDetail(id, false); }


    @Transactional(readOnly = true, isolation = org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public RequestDetail detailHistory(UUID id) { return readDetail(id, true); }

    private RequestDetail readDetail(UUID id, boolean historyRead) {
        PurchaseRequest r = requireRequest(id, historyRead);
        Map<UUID, BigDecimal> pending = new LinkedHashMap<>();
        Map<UUID, Long> versions = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT i.id, pending.pending_qty, i.row_version FROM purchase_request_items i
                %s
                WHERE i.request_id = :requestId AND i.is_deleted = FALSE
                """.formatted(PENDING_ORDER_QUANTITY_JOIN)).setParameter("requestId", id))) {
            pending.put(uuid(row[0]), decimal(row[1]));
            versions.put(uuid(row[0]), ((Number) row[2]).longValue());
        }
        List<RequestItemDto> items = itemRepo.findByRequestIdOrderByLineNoAsc(id).stream()
                .filter(item -> versions.containsKey(item.getId()))
                .map(item -> toItemDto(item, pending.getOrDefault(item.getId(), BigDecimal.ZERO),
                        versions.get(item.getId()))).toList();
        return finishHistory(toDetail(r, items), r, historyRead);
    }

    /**
     * V477：计划下达申请的「分解前数量修正」。
     *
     * <p>计划来源申请落库即已审核（无草稿态），通用 [update] 的「仅草稿可编辑
     * + 生产来源不可改」双闸不适用——本方法是这类申请唯一 sanctioned 的写入口：
     * 仅已审核单据、且该明细既无已订货量也无待财务审核的订货占用时允许改量
     * （否则订货行多来源 FIFO 分摊（ADR-069）的血缘会被破坏）。修正不重拍审批
     * 快照、不动来源锚定；分解任务台的剩余量随新数量自然重算。</p>
     */
    /** Unsafe historical callers must refresh to obtain the persistent item version. */
    @Deprecated
    public RequestDetail adjustItemQty(UUID requestId, UUID itemId, java.math.BigDecimal qty) {
        throw new ApiException(ErrorCode.VALIDATION_FAILED, "数量修正必须携带当前明细版本，请刷新后重试");
    }

    @Transactional
    @PreAuthorize("hasAuthority('purchase_request:view') and hasAuthority('purchase_order:decompose')")
    public RequestDetail adjustItemQty(UUID requestId, UUID itemId, java.math.BigDecimal qty, Long expectedVersion) {
        if (expectedVersion == null || expectedVersion < 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "数量修正必须携带当前明细版本，请刷新后重试");
        }
        if (qty == null || qty.signum() <= 0 || qty.stripTrailingZeros().scale() > 4
                || qty.precision() - qty.scale() > 14) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "数量必须大于0且最多14位整数和4位小数");
        }
        tx.bind();
        PurchaseRequest r = requestRepo.findById(requestId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "采购申请不存在"));
        if (r.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "采购申请不存在");
        }
        PurchaseRequestItem item = itemRepo.findById(itemId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "申请明细不存在"));
        if (!requestId.equals(item.getRequestId()) || item.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "申请明细不存在");
        }
        // Same canonical request-head/item/analysis/inventory lock prefix as
        // decomposition/order creation. Refresh after waiting, never edit a
        // persistence-context snapshot loaded before the lock was acquired.
        var guard = mutationLocks.orderInputs("PURCHASE", null, List.of(itemId),
                item.getGoodsId() == null ? List.of() : List.of(
                        new com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension(
                                item.getGoodsId(), item.getColorId())), r.getWarehouseId());
        em.refresh(r); em.refresh(item); guard.verifyUnchanged();
        if (r.isDeleted() || item.isDeleted() || !requestId.equals(item.getRequestId())) {
            throw new ApiException(ErrorCode.NOT_FOUND, "申请明细不存在");
        }
        if (item.getRowVersion() != expectedVersion) {
            throw new ApiException(ErrorCode.CONFLICT, "申请明细已变化，请保留原输入并刷新核对");
        }
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED || r.isClosed()
                || Boolean.TRUE.equals(r.getIsStopped()) || item.getUnitId() == null
                || item.getUnitRate() == null || item.getUnitRate().signum() <= 0) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已下达且可分解的申请明细可修正数量");
        }
        taskClaim.requireNoActiveClaimByOther("PURCHASE_DECOMPOSE", requestId.toString());
        java.math.BigDecimal ordered = item.getOrderedQty();
        if (ordered != null && ordered.signum() > 0) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "该明细已生成订货单（在途 " + ordered.stripTrailingZeros().toPlainString()
                            + "），不能直接修改数量");
        }
        java.math.BigDecimal pending = pendingApprovalOrderQty(itemId);
        if (pending.signum() > 0) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "该明细已有待财务审核的订货单（" + pending.stripTrailingZeros().toPlainString()
                            + "），不能修改数量");
        }
        List<?> changed = em.createNativeQuery("""
                UPDATE purchase_request_items SET qty=:qty,updated_at=now(),updated_by=:actor
                WHERE id=:item AND request_id=:request AND NOT is_deleted AND row_version=:version
                RETURNING row_version
                """).setParameter("qty", qty).setParameter("actor", currentUser.requireId())
                .setParameter("item", itemId).setParameter("request", requestId)
                .setParameter("version", expectedVersion).getResultList();
        if (changed.size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "申请明细已变化，请保留原输入并刷新核对");
        }
        em.refresh(item);
        return detail(requestId);
    }

    /** 待财务审核订货单对该申请明细的占用量（与工作台 V199 purchase_pending 同口径）。 */
    private java.math.BigDecimal pendingApprovalOrderQty(UUID requestItemId) {
        Object value = em.createNativeQuery("""
                SELECT pending.pending_qty FROM purchase_request_items i
                %s WHERE i.id=:itemId AND NOT i.is_deleted
                """.formatted(PENDING_ORDER_QUANTITY_JOIN))
                .setParameter("itemId", requestItemId)
                .getSingleResult();
        return value == null ? java.math.BigDecimal.ZERO
                : new java.math.BigDecimal(value.toString());
    }

    /** 分解预览（只读）：可下达量 = 申请数量 − 已下单 − 已进待财务审核的订货单数量，避免重复分解；并对每个申请取 PURCHASE_DECOMPOSE 任务认领守卫，他人正分解同一申请时拒绝重复操作（认领仅 UX 防碰撞层，正确性仍由下单/财务审核兜底）。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('purchase_request:view') and hasAuthority('purchase_order:decompose')")
    public List<DecompositionPreviewItem> decompositionPreview(List<UUID> requestedItemIds) {
        List<UUID> itemIds = normalizePreviewItemIds(requestedItemIds, "采购申请");
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT r.id, r.bill_no, i.id, i.goods_id, i.color_id, i.unit_id,
                                       COALESCE(i.unit_rate, 1), COALESCE(i.qty, 0),
                                       COALESCE(i.ordered_qty, 0), COALESCE(pending.pending_qty, 0),
                                       COALESCE(i.deliver_date, r.need_date), r.warehouse_id,
                                       COALESCE(NULLIF(i.production_plan_no, ''),
                                                NULLIF(i.source_doc_no, ''),
                                                NULLIF(r.source_doc_no, ''), r.bill_no)
                                FROM purchase_request_items i
                                JOIN purchase_requests r ON r.id = i.request_id
                                %s
                                WHERE i.id IN (:itemIds)
                                  AND i.is_deleted = FALSE
                                  AND r.status = 1
                                  AND r.is_deleted = FALSE
                                  AND r.is_closed = FALSE
                                  AND COALESCE(r.is_stopped, FALSE) = FALSE
                                  AND i.unit_id IS NOT NULL
                                  AND COALESCE(i.unit_rate, 0) > 0
                                  AND COALESCE(i.qty, 0)
                                        - COALESCE(i.ordered_qty, 0)
                                        - COALESCE(pending.pending_qty, 0) > 0
                                ORDER BY i.id
                                """.formatted(PENDING_ORDER_QUANTITY_JOIN))
                        .setParameter("itemIds", itemIds));

        // 并发认领守卫（PURCHASE_DECOMPOSE，最高双工风险）：他人正分解同一申请时拒绝重复操作。
        // request_id 直接复用本查询结果行 row[0]，不发额外 query（保持 DecompositionPreviewTest 的单次 createNativeQuery 校验）。
        // 认领只是 UX/防碰撞层；下游 createBatch/财务审核的 ordered_qty 回写与状态守卫仍是正确性底线。
        rows.stream().map(r -> uuid(r[0])).distinct().forEach(rid ->
                taskClaim.requireNoActiveClaimByOther("PURCHASE_DECOMPOSE", rid.toString()));

        Map<UUID, Object[]> rowsByItemId = new LinkedHashMap<>();
        for (Object[] row : rows) {
            UUID itemId = uuid(row[2]);
            if (rowsByItemId.putIfAbsent(itemId, row) != null) {
                throw unavailablePreviewSelection("采购申请");
            }
        }
        if (rowsByItemId.size() != itemIds.size()) {
            throw unavailablePreviewSelection("采购申请");
        }
        // ADR-038：订货不携带仓库（入库仓库后移到收货登记），跨仓库申请行可在同一张订货单分解，
        // 拆单只按供应商约束；行上的 warehouse_id 仅作申请侧库存口径展示。
        return itemIds.stream().map(itemId -> {
            Object[] row = rowsByItemId.get(itemId);
            BigDecimal requestedQty = decimal(row[7]);
            BigDecimal orderedQty = decimal(row[8]);
            BigDecimal pendingQty = decimal(row[9]);
            BigDecimal remainingQty = requestedQty
                    .subtract(orderedQty)
                    .subtract(pendingQty);
            return new DecompositionPreviewItem(
                    uuid(row[0]), text(row[1]), itemId, uuid(row[3]), uuid(row[4]),
                    uuid(row[5]), decimal(row[6]), requestedQty, orderedQty, pendingQty,
                    remainingQty, localDate(row[10]), uuid(row[11]), text(row[12]));
        }).toList();
    }

    @Transactional
    @com.uten.imp.common.platformcolumns.PlatformColumnDocumentSave(scope="purchase_request_item")
    public RequestDetail create(RequestSaveRequest req) {
        tx.bind();
        PurchaseRequest r = new PurchaseRequest();
        applyHeader(req, r);
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户
        r.setStatus(STATUS_DRAFT);
        requestRepo.save(r);
        List<RequestItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    @com.uten.imp.common.platformcolumns.PlatformColumnDocumentSave(scope="purchase_request_item", requestArgument=1, documentIdArgument=0)
    public RequestDetail update(UUID id, RequestSaveRequest req) {
        tx.bind();
        PurchaseRequest r = requireRequestForUpdate(id);
        if (r.getStatus() != STATUS_DRAFT) throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        productionSourceGuard.requirePurchaseRequestMutable(id);
        applyHeader(req, r);
        itemRepo.deleteByRequestId(id);
        itemRepo.flush();
        List<RequestItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        PurchaseRequest r = requireRequestForUpdate(id);
        com.uten.imp.common.web.StandardDocumentLifecycleCapabilities
                .requireDraftForDelete(r.getStatus());
        productionSourceGuard.requirePurchaseRequestMutable(id);
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        requestRepo.save(r);
    }

    /**
     * 审核：链路起点，仅改状态（无库存联动、无上游回写）。
     *
     * <p>申请单本体已是「计划下达的只读事实」，无任何控制器暴露本方法；
     * 保留它是因为链路端到端测试用它把夹具推到已审核态。守卫取计划分解
     * 权限——真正能把申请推到可执行态的就是计划侧分解，避免未来被无守卫接线。
     */
    @PreAuthorize("hasAuthority('purchase_order:decompose')")
    @Transactional
    public RequestDetail approve(UUID id) {
        tx.bind();
        PurchaseRequest r = requireRequestForUpdate(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT)
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        List<PurchaseRequestItem> items = itemRepo.findByRequestIdOrderByLineNoAsc(id);
        if (items.isEmpty())
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        normalizePersistedItemUnits(items);
        captureMasterGoodsSnapshots(
                items, PurchaseGoodsSnapshot.MASTER_AT_APPROVAL, OffsetDateTime.now());
        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户
        requestRepo.save(r);
        return detail(id);
    }

    private void applyHeader(RequestSaveRequest req, PurchaseRequest r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.PURCHASE_REQUEST));
        }
        r.setBillDate(req.getBillDate());
        // V476 运营红线：申请仓库必须选具体叶子仓（后续订货/收货沿用）。
        if (warehouseScopes != null) {
            warehouseScopes.require(r.getWarehouseId(), req.getWarehouseId(), "仓库", WarehouseUse.GOOD_IN);
        }
        r.setWarehouseId(req.getWarehouseId());
        applyDepartmentReference(req, r);
        r.setApplicantId(req.getApplicantId());
        r.setNeedDate(req.getNeedDate());
        r.setRemark(req.getRemark());
    }

    /** UUID is authoritative; the old StepID snapshot is never accepted from the API. */
    private void applyDepartmentReference(RequestSaveRequest req, PurchaseRequest request) {
        if (!req.hasDepartmentReference()) return;
        UUID departmentId = req.getDepartmentId();
        if (departmentId == null) {
            request.setDepartmentId(null);
            request.setDepartmentLegacyId(null);
            return;
        }
        UUID resolvedDepartmentId = organizationReferences.findActiveDepartment(departmentId)
                .map(OrganizationReferencePort.DepartmentReference::id)
                .orElse(null);
        if (resolvedDepartmentId == null) {
            throw new ApiException(ErrorCode.NOT_FOUND, "申请部门不存在");
        }
        if (!departmentId.equals(request.getDepartmentId())) {
            // A new UUID selection has no safe inverse mapping to one historical StepID.
            request.setDepartmentLegacyId(null);
        }
        request.setDepartmentId(resolvedDepartmentId);
    }

    private List<RequestItemDto> saveItems(PurchaseRequest r, List<RequestItemLine> lines) {
        List<RequestItemDto> out = new ArrayList<>(lines.size());
        Map<UUID, PurchaseGoodsSnapshot> masterSnapshots =
                PurchaseGoodsSnapshot.fromMaster(
                        em,
                        lines.stream().map(RequestItemLine::getGoodsId).toList(),
                        PurchaseGoodsSnapshot.MASTER_AT_SAVE);
        int auto = 1;
        for (RequestItemLine l : lines) {
            int lineNo = l.getLineNo() != null ? l.getLineNo() : auto;
            PurchaseLineUnitPolicy.ResolvedUnit resolvedUnit =
                    lineUnitPolicy.normalizeAndValidate(
                            l.getGoodsId(), l.getUnitId(), l.getUnitRate(), lineNo);
            PurchaseRequestItem it = new PurchaseRequestItem();
            it.setRequestId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(lineNo);
            it.setGoodsId(l.getGoodsId());
            applyGoodsSnapshot(
                    it,
                    PurchaseGoodsSnapshot.require(
                            masterSnapshots, l.getGoodsId(), "采购申请明细"),
                    null);
            it.setColorId(l.getColorId());
            it.setUnitId(resolvedUnit.unitId());
            it.setUnitRate(resolvedUnit.unitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            // 金额只由服务端派生(ADR-112): 数量 × 单价; 本单据无币种, 按本位币计(汇率 1)。单价空则金额空。
            MoneyPolicy.LineAmounts amounts = MoneyPolicy.line(l.getQty(), it.getPrice(), null, BigDecimal.ONE);
            it.setAmountOriginal(amounts.original());
            it.setAmountLocal(amounts.local());
            it.setGiftQty(l.getGiftQty() != null ? l.getGiftQty() : BigDecimal.ZERO);
            it.setWeight(l.getWeight());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    private void captureMasterGoodsSnapshots(
            List<PurchaseRequestItem> items, String source, OffsetDateTime lockedAt) {
        Map<UUID, PurchaseGoodsSnapshot> snapshots = PurchaseGoodsSnapshot.fromMaster(
                em,
                items.stream().map(PurchaseRequestItem::getGoodsId).toList(),
                source);
        for (PurchaseRequestItem item : items) {
            applyGoodsSnapshot(
                    item,
                    PurchaseGoodsSnapshot.require(
                            snapshots, item.getGoodsId(), "采购申请明细"),
                    lockedAt);
        }
        itemRepo.saveAll(items);
        itemRepo.flush();
    }

    private static void applyGoodsSnapshot(
            PurchaseRequestItem item,
            PurchaseGoodsSnapshot snapshot,
            OffsetDateTime lockedAt) {
        item.setGoodsCodeSnapshot(snapshot.code());
        item.setGoodsNameSnapshot(snapshot.name());
        item.setGoodsSnapshotSource(snapshot.source());
        item.setGoodsSnapshotLockedAt(lockedAt);
    }

    private void normalizePersistedItemUnits(List<PurchaseRequestItem> items) {
        int fallbackLineNo = 1;
        for (PurchaseRequestItem item : items) {
            int lineNo = item.getLineNo() != null ? item.getLineNo() : fallbackLineNo;
            PurchaseLineUnitPolicy.ResolvedUnit resolvedUnit =
                    lineUnitPolicy.normalizeAndValidate(
                            item.getGoodsId(), item.getUnitId(), item.getUnitRate(), lineNo);
            item.setUnitId(resolvedUnit.unitId());
            item.setUnitRate(resolvedUnit.unitRate());
            fallbackLineNo++;
        }
    }

    private void applyTotals(PurchaseRequest r, List<RequestItemDto> items) {
        BigDecimal local = items.stream().map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        r.setTotalLocal(local);
        r.setTotalOriginal(local);
        requestRepo.save(r);
    }

    private RequestListItem toList(PurchaseRequest r) {
        return new RequestListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getWarehouseId(),
                r.getTotalLocal(), r.getStatus(), r.isClosed(), r.getLegacyId());
    }

    private RequestItemDto toItemDto(PurchaseRequestItem it) {
        return toItemDto(it, BigDecimal.ZERO);
    }

    private RequestItemDto toItemDto(PurchaseRequestItem it, BigDecimal pendingQty) {
        return toItemDto(it, pendingQty, it.getRowVersion());
    }

    private RequestItemDto toItemDto(PurchaseRequestItem it, BigDecimal pendingQty, long rowVersion) {
        return new RequestItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getOrderedQty(), it.getGiftQty(), it.getWeight(),
                it.getSourceDocNo(), it.getDeliverDate(), it.getProductionPlanNo(),
                it.getSalesOrderNo(), it.getRemark(), pendingQty,
                (it.getQty() == null ? BigDecimal.ZERO : it.getQty())
                        .subtract(it.getOrderedQty() == null ? BigDecimal.ZERO : it.getOrderedQty())
                        .subtract(pendingQty).max(BigDecimal.ZERO), rowVersion);
    }

    private RequestDetail toDetail(PurchaseRequest r, List<RequestItemDto> items) {
        boolean productionLinked =
                productionSourceGuard.isPurchaseRequestLinked(r.getId());
        String makerName = nameResolver.nameOf(r.getMakerId());
        String applicantName = java.util.Objects.equals(r.getApplicantId(), r.getMakerId())
                ? makerName : nameResolver.nameOf(r.getApplicantId());
        return new RequestDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getWarehouseId(), r.getDepartmentId(), r.getApplicantId(), r.getMakerId(), r.getApproverId(),
                r.getNeedDate(), r.getRemark(), r.getTotalOriginal(), r.getTotalLocal(),
                r.getStatus(), r.isClosed(), r.getSourceDocNo(), items,
                makerName, r.getCreatedAt(),
                productionLinked, !productionLinked, !productionLinked,
                !productionLinked,
                restrictionReason(productionLinked), applicantName);
    }

    private String restrictionReason(boolean linked) {
        return linked ? "该采购申请关联生产物料需求，请在生产计划专用流程中调整或红冲" : null;
    }

    private static List<UUID> normalizePreviewItemIds(
            List<UUID> requestedItemIds, String documentLabel) {
        if (requestedItemIds == null
                || requestedItemIds.isEmpty()
                || requestedItemIds.size() > 200
                || requestedItemIds.stream().anyMatch(Objects::isNull)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    documentLabel + "明细数量须为 1 至 200 条且不能为空");
        }
        return requestedItemIds.stream()
                .distinct()
                .sorted(Comparator.comparing(UUID::toString))
                .toList();
    }

    private static ApiException unavailablePreviewSelection(String documentLabel) {
        return new ApiException(
                ErrorCode.CONFLICT,
                "所选" + documentLabel + "明细不存在、已失效或已无可分解数量，请刷新后重试");
    }

    private static UUID uuid(Object value) {
        return value == null ? null : value instanceof UUID id
                ? id
                : UUID.fromString(value.toString());
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : value instanceof BigDecimal number
                ? number
                : new BigDecimal(value.toString());
    }

    private static LocalDate localDate(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof LocalDate date) {
            return date;
        }
        if (value instanceof java.sql.Date date) {
            return date.toLocalDate();
        }
        return LocalDate.parse(value.toString());
    }

    private static String text(Object value) {
        return value == null ? null : value.toString();
    }

    private PurchaseRequest requireRequest(UUID id) { return requireRequest(id, false); }

    private PurchaseRequest requireRequest(UUID id, boolean includeDeleted) {
        return requestRepo.findById(id).filter(r -> includeDeleted || !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "采购申请单不存在"));
    }
    private PurchaseRequest requireRequestForUpdate(UUID id) {
        PurchaseRequest request = em.find(
                PurchaseRequest.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        return request == null || request.isDeleted()
                ? requireRequest(id)
                : request;
    }

    private RequestDetail finishHistory(RequestDetail view, PurchaseRequest entity, boolean historyRead) {
        if (!historyRead && !entity.isDeleted()) return view;
        return retainedRecords.detail(view, "purchase_requests", entity.getId(), entity.isDeleted(), entity.getDeletedAt(), historyRead);
    }

    @Transactional(readOnly = true)
    public java.util.List<com.uten.imp.common.history.RetainedRecordReader.RetainedRow> historyRows(UUID id, Long beforeId, int size) {
        var document=detailHistory(id);
        com.uten.imp.common.history.RetainedRecordAccess.requireUnmaskedCostOriginal(false);
        return retainedRecords.children("purchase_requests",id,beforeId,size);
    }
}
