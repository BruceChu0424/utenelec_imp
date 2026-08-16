package com.uten.imp.features.purchase.request;

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

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    private final PurchaseRequestRepository requestRepo;
    private final PurchaseRequestItemRepository itemRepo;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final DocNumberService docNumberService;
    private final jakarta.persistence.EntityManager em;
    private final ProductionSupplySourceGuard productionSourceGuard;
    private final PurchaseLineUnitPolicy lineUnitPolicy;
    private final TaskClaimService taskClaim;
    private final OrganizationReferencePort organizationReferences;

    @Transactional(readOnly = true)
    public PageResponse<RequestListItem> list(RequestQueryFilter f, int page, int size, String sort, String order) {
        Specification<PurchaseRequest> spec = (Root<PurchaseRequest> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                               CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
            }
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
        Page<PurchaseRequest> p = requestRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public RequestDetail detail(UUID id) {
        PurchaseRequest r = requireRequest(id);
        List<RequestItemDto> items = itemRepo.findByRequestIdOrderByLineNoAsc(id).stream().map(this::toItemDto).toList();
        return toDetail(r, items);
    }

    /** 分解预览（只读）：可下达量 = 申请数量 − 已下单 − 已进待财务审核的订货单数量，避免重复分解；并对每个申请取 PURCHASE_DECOMPOSE 任务认领守卫，他人正分解同一申请时拒绝重复操作（认领仅 UX 防碰撞层，正确性仍由下单/财务审核兜底）。 */
    @Transactional(readOnly = true)
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
                                LEFT JOIN (
                                    SELECT oi.request_item_id,
                                           SUM(COALESCE(oi.qty, 0)) AS pending_qty
                                    FROM purchase_order_items oi
                                    JOIN purchase_orders o ON o.id = oi.order_id
                                    JOIN (
                                        SELECT DISTINCT order_id
                                        FROM procurement_order_approval_cases
                                        WHERE order_type = 'PURCHASE'
                                          AND status = 'PENDING'
                                    ) pending_case ON pending_case.order_id = o.id
                                    WHERE oi.is_deleted = FALSE
                                      AND oi.request_item_id IS NOT NULL
                                      AND o.status = 0
                                      AND o.is_deleted = FALSE
                                    GROUP BY oi.request_item_id
                                ) pending ON pending.request_item_id = i.id
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
                                """)
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
        if (rowsByItemId.values().stream()
                .map(row -> uuid(row[11]))
                .distinct()
                .count() > 1) {
            throw new ApiException(ErrorCode.CONFLICT, "不同仓库请分别生成订货单");
        }
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
        if (r.getStatus() == STATUS_APPROVED) throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        productionSourceGuard.requirePurchaseRequestMutable(id);
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        requestRepo.save(r);
    }

    /** 审核：链路起点，仅改状态（无库存联动、无上游回写）。 */
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

    @Transactional
    public RequestDetail reverse(UUID id) {
        tx.bind();
        PurchaseRequest r = requireRequestForUpdate(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        productionSourceGuard.requirePurchaseRequestMutable(id);
        List<PurchaseRequestItem> items = itemRepo.findByRequestIdOrderByLineNoAsc(id);
        if (items.stream().anyMatch(it ->
                it.getOrderedQty() != null && it.getOrderedQty().signum() > 0)) {
            throw new ApiException(ErrorCode.BUSINESS, "采购申请已有订货记录，请先红冲下游订货单");
        }
        r.setStatus(STATUS_REVERSED);
        requestRepo.save(r);
        return detail(id);
    }

    private void applyHeader(RequestSaveRequest req, PurchaseRequest r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.PURCHASE_REQUEST));
        }
        r.setBillDate(req.getBillDate());
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
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
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
        return new RequestItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getOrderedQty(), it.getGiftQty(), it.getWeight(),
                it.getSourceDocNo(), it.getDeliverDate(), it.getProductionPlanNo(),
                it.getSalesOrderNo(), it.getRemark());
    }

    private RequestDetail toDetail(PurchaseRequest r, List<RequestItemDto> items) {
        boolean productionLinked =
                productionSourceGuard.isPurchaseRequestLinked(r.getId());
        return new RequestDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getWarehouseId(), r.getDepartmentId(), r.getApplicantId(), r.getMakerId(), r.getApproverId(),
                r.getNeedDate(), r.getRemark(), r.getTotalOriginal(), r.getTotalLocal(),
                r.getStatus(), r.isClosed(), r.getSourceDocNo(), items,
                nameResolver.nameOf(r.getMakerId()), r.getCreatedAt(),
                productionLinked, !productionLinked, !productionLinked,
                !productionLinked,
                restrictionReason(productionLinked));
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

    private PurchaseRequest requireRequest(UUID id) {
        return requestRepo.findById(id).filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "采购申请单不存在"));
    }
    private PurchaseRequest requireRequestForUpdate(UUID id) {
        PurchaseRequest request = em.find(
                PurchaseRequest.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        return request == null || request.isDeleted()
                ? requireRequest(id)
                : request;
    }
}
