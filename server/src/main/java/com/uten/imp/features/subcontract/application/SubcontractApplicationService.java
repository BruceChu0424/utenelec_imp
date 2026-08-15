package com.uten.imp.features.subcontract.application;

import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.subcontract.SubcontractGoodsSnapshot;
import com.uten.imp.features.subcontract.SubcontractGoodsKeyword;
import com.uten.imp.features.subcontract.application.dto.ApplicationDetail;
import com.uten.imp.features.subcontract.application.dto.ApplicationItemDto;
import com.uten.imp.features.subcontract.application.dto.ApplicationItemLine;
import com.uten.imp.features.subcontract.application.dto.ApplicationListItem;
import com.uten.imp.features.subcontract.application.dto.ApplicationQueryFilter;
import com.uten.imp.features.subcontract.application.dto.ApplicationSaveRequest;
import com.uten.imp.features.subcontract.application.dto.DecompositionPreviewItem;
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
 * 委外申请单服务：CRUD（主+明细）+ 审核状态机（仅状态变更）。
 *
 * <p>申请单是<b>链路中间节点</b>：审核仅 0→1 状态变更，<b>无库存联动、无应收应付</b>。
 * 被订货单审核时回写 {@code application_items.ordered_qty}（design doc 22 §3.2，由
 * {@code SubcontractOrderService.approve} 同事务回写，不在本服务）。
 *
 * <p>状态机：0 草稿 / 1 已审 / -1 红冲；已审不可删（红冲保留）。
 */
@Service
@RequiredArgsConstructor
public class SubcontractApplicationService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    private final SubcontractApplicationRepository applicationRepo;
    private final SubcontractApplicationItemRepository itemRepo;
    private final TxSessionVars tx;
    private final DocNumberService docNumberService;
    private final EntityManager em;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final ProductionSubcontractSupplyTransitionPort productionSupply;
    private final ProductionSupplySourceGuard productionSourceGuard;

    @Transactional(readOnly = true)
    public PageResponse<ApplicationListItem> list(ApplicationQueryFilter f, int page, int size, String sort, String order) {
        Specification<SubcontractApplication> spec = (Root<SubcontractApplication> root,
                                                      jakarta.persistence.criteria.CriteriaQuery<?> q,
                                                      CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(SubcontractGoodsKeyword.predicate(
                        cb, q, root, SubcontractApplicationItem.class, "applicationId", f.keyword()));
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
        Page<SubcontractApplication> p = applicationRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public ApplicationDetail detail(UUID id) {
        SubcontractApplication r = requireApplication(id);
        List<ApplicationItemDto> items = itemRepo.findByApplicationIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(r, items);
    }

    /** 分解预览（只读）：可下达量 = 申请数量 − 已下单 − 已进待财务审核的订货单数量，避免对尚在审核中的订货单重复分解；强制同批发起项属同一仓库，否则提示分别生成。 */
    @Transactional(readOnly = true)
    public List<DecompositionPreviewItem> decompositionPreview(List<UUID> requestedItemIds) {
        List<UUID> itemIds = normalizePreviewItemIds(requestedItemIds, "委外申请");
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT a.id, a.bill_no, i.id, i.goods_id, i.color_id, i.unit_id,
                                       COALESCE(i.unit_rate, 1), COALESCE(i.qty, 0),
                                       COALESCE(i.ordered_qty, 0), COALESCE(pending.pending_qty, 0),
                                       a.need_date, a.warehouse_id,
                                       COALESCE(NULLIF(i.source_doc_no, ''),
                                                NULLIF(a.source_doc_no, ''), a.bill_no)
                                FROM subcontract_application_items i
                                JOIN subcontract_applications a ON a.id = i.application_id
                                LEFT JOIN (
                                    SELECT oi.application_item_id,
                                           SUM(COALESCE(oi.qty, 0)) AS pending_qty
                                    FROM subcontract_order_items oi
                                    JOIN subcontract_orders o ON o.id = oi.order_id
                                    JOIN (
                                        SELECT DISTINCT order_id
                                        FROM procurement_order_approval_cases
                                        WHERE order_type = 'SUBCONTRACT'
                                          AND status = 'PENDING'
                                    ) pending_case ON pending_case.order_id = o.id
                                    WHERE oi.is_deleted = FALSE
                                      AND oi.application_item_id IS NOT NULL
                                      AND o.status = 0
                                      AND o.is_deleted = FALSE
                                    GROUP BY oi.application_item_id
                                ) pending ON pending.application_item_id = i.id
                                WHERE i.id IN (:itemIds)
                                  AND i.is_deleted = FALSE
                                  AND a.status = 1
                                  AND a.is_deleted = FALSE
                                  AND a.is_closed = FALSE
                                  AND i.unit_id IS NOT NULL
                                  AND COALESCE(i.unit_rate, 0) > 0
                                  AND COALESCE(i.qty, 0)
                                        - COALESCE(i.ordered_qty, 0)
                                        - COALESCE(pending.pending_qty, 0) > 0
                                ORDER BY i.id
                                """)
                        .setParameter("itemIds", itemIds));

        Map<UUID, Object[]> rowsByItemId = new LinkedHashMap<>();
        for (Object[] row : rows) {
            UUID itemId = uuid(row[2]);
            if (rowsByItemId.putIfAbsent(itemId, row) != null) {
                throw unavailablePreviewSelection("委外申请");
            }
        }
        if (rowsByItemId.size() != itemIds.size()) {
            throw unavailablePreviewSelection("委外申请");
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
    public ApplicationDetail create(ApplicationSaveRequest req) {
        tx.bind();
        SubcontractApplication r = new SubcontractApplication();
        applyHeader(req, r);
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        r.setStatus(STATUS_DRAFT);
        applicationRepo.save(r);
        List<ApplicationItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public ApplicationDetail update(UUID id, ApplicationSaveRequest req) {
        tx.bind();
        SubcontractApplication r = requireApplicationForUpdate(id);
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        productionSourceGuard.requireSubcontractApplicationMutable(id);
        applyHeader(req, r);
        itemRepo.deleteByApplicationId(id);
        itemRepo.flush();
        List<ApplicationItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        SubcontractApplication r = requireApplicationForUpdate(id);
        if (r.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        productionSourceGuard.requireSubcontractApplicationMutable(id);
        productionSupply.onSubcontractApplicationRemoved(id);
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        applicationRepo.save(r);
    }

    /** 审核：0→1（仅状态变更；申请单无库存/ArAp 联动）。 */
    @Transactional
    public ApplicationDetail approve(UUID id) {
        tx.bind();
        SubcontractApplication r = requireApplicationForUpdate(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        List<SubcontractApplicationItem> items = itemRepo.findByApplicationIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        captureMasterGoodsSnapshots(
                items, SubcontractGoodsSnapshot.MASTER_AT_APPROVAL, OffsetDateTime.now());
        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        applicationRepo.save(r);
        return detail(id);
    }

    /** 红冲：1→-1（仅状态变更；申请无 ArAp 无库存，无需反向冲销）。 */
    @Transactional
    public ApplicationDetail reverse(UUID id) {
        tx.bind();
        SubcontractApplication r = requireApplicationForUpdate(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        List<SubcontractApplicationItem> items =
                itemRepo.findByApplicationIdOrderByLineNoAsc(id);
        if (items.stream().anyMatch(it ->
                it.getOrderedQty() != null && it.getOrderedQty().signum() > 0)) {
            throw new ApiException(ErrorCode.BUSINESS, "委外申请已有订货记录，请先红冲下游订货单");
        }
        productionSupply.onSubcontractApplicationRemoved(id);
        r.setStatus(STATUS_REVERSED);
        applicationRepo.save(r);
        return detail(id);
    }

    private void applyHeader(ApplicationSaveRequest req, SubcontractApplication r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SUB_APPLICATION));
        }
        r.setBillDate(req.getBillDate());
        r.setSupplierId(req.getSupplierId());
        r.setWarehouseId(req.getWarehouseId());
        r.setApplicantId(req.getApplicantId());
        r.setNeedDate(req.getNeedDate());
        r.setRemark(req.getRemark());
    }

    private List<ApplicationItemDto> saveItems(SubcontractApplication r, List<ApplicationItemLine> lines) {
        List<ApplicationItemDto> out = new ArrayList<>(lines.size());
        Map<UUID, SubcontractGoodsSnapshot> masterSnapshots =
                SubcontractGoodsSnapshot.fromMaster(
                        em,
                        lines.stream().map(ApplicationItemLine::getGoodsId).toList(),
                        SubcontractGoodsSnapshot.MASTER_AT_SAVE);
        int autoLine = 1;
        for (ApplicationItemLine l : lines) {
            SubcontractApplicationItem it = new SubcontractApplicationItem();
            it.setApplicationId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : autoLine);
            it.setGoodsId(l.getGoodsId());
            applyGoodsSnapshot(
                    it,
                    SubcontractGoodsSnapshot.require(
                            masterSnapshots, l.getGoodsId(), "委外申请明细"),
                    null);
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
            it.setWeight(l.getWeight());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            autoLine++;
        }
        return out;
    }

    private void captureMasterGoodsSnapshots(
            List<SubcontractApplicationItem> items, String source, OffsetDateTime lockedAt) {
        Map<UUID, SubcontractGoodsSnapshot> snapshots = SubcontractGoodsSnapshot.fromMaster(
                em, items.stream().map(SubcontractApplicationItem::getGoodsId).toList(), source);
        for (SubcontractApplicationItem item : items) {
            applyGoodsSnapshot(
                    item,
                    SubcontractGoodsSnapshot.require(
                            snapshots, item.getGoodsId(), "委外申请明细"),
                    lockedAt);
        }
        itemRepo.saveAll(items);
        itemRepo.flush();
    }

    private static void applyGoodsSnapshot(
            SubcontractApplicationItem item,
            SubcontractGoodsSnapshot snapshot,
            OffsetDateTime lockedAt) {
        item.setGoodsCodeSnapshot(snapshot.code());
        item.setGoodsNameSnapshot(snapshot.name());
        item.setGoodsSnapshotSource(snapshot.source());
        item.setGoodsSnapshotLockedAt(lockedAt);
    }

    private void applyTotals(SubcontractApplication r, List<ApplicationItemDto> items) {
        BigDecimal local = items.stream()
                .map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream()
                .map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        r.setTotalLocal(local);
        r.setTotalOriginal(original);
        applicationRepo.save(r);
    }

    private ApplicationListItem toList(SubcontractApplication r) {
        return new ApplicationListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getSupplierId(),
                r.getWarehouseId(), r.getTotalLocal(), r.getStatus(), r.isClosed(), r.getLegacyId());
    }

    private ApplicationItemDto toItemDto(SubcontractApplicationItem it) {
        return new ApplicationItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getOrderedQty(), it.getWeight(), it.getSourceDocNo(), it.getRemark());
    }

    private ApplicationDetail toDetail(SubcontractApplication r, List<ApplicationItemDto> items) {
        boolean productionLinked =
                productionSourceGuard.isSubcontractApplicationLinked(r.getId());
        return new ApplicationDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getSupplierId(), r.getWarehouseId(), r.getApplicantId(), r.getMakerId(), r.getApproverId(),
                r.getNeedDate(), r.getRemark(), r.getTotalOriginal(), r.getTotalLocal(), r.getStatus(),
                r.isClosed(), r.getSourceDocNo(), items,
                nameResolver.nameOf(r.getMakerId()), r.getCreatedAt(),
                productionLinked, !productionLinked, !productionLinked, true,
                restrictionReason(productionLinked));
    }

    private String restrictionReason(boolean linked) {
        return linked ? "该委外申请关联生产物料需求，编辑和删除已锁定；红冲须走生产供给校验" : null;
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

    private SubcontractApplication requireApplication(UUID id) {
        return applicationRepo.findById(id)
                .filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "委外申请单不存在"));
    }
    private SubcontractApplication requireApplicationForUpdate(UUID id) {
        SubcontractApplication application = em.find(
                SubcontractApplication.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        return application == null || application.isDeleted()
                ? requireApplication(id)
                : application;
    }
}
