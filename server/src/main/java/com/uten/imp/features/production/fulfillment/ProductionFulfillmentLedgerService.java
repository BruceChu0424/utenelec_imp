package com.uten.imp.features.production.fulfillment;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.allocation.ProductionMaterialAllocationFacade;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * Production-owned planning package, material demand and explicit supply-peg
 * lifecycle. Physical stock rows are delegated to the stock facade.
 */
@Service
@RequiredArgsConstructor
public class ProductionFulfillmentLedgerService {

    private final ProductionPlanningPackageRepository packageRepo;
    private final ProductionMaterialDemandRepository demandRepo;
    private final ProductionMaterialSupplyPegRepository pegRepo;
    private final ProductionMaterialAllocationFacade stockAllocation;
    private final EntityManager em;

    @Transactional(propagation = Propagation.MANDATORY)
    public BeginConfirmation beginConfirmation(
            UUID planId,
            UUID warehouseId,
            String idempotencyKey,
            String requestHash,
            String previewFingerprint) {
        String normalizedKey = normalizedKey(idempotencyKey);
        ProductionPlanningPackage existing = packageRepo
                .lockByPlanAndKey(planId, normalizedKey)
                .orElse(null);
        if (existing != null) {
            if (!Objects.equals(existing.getRequestHash(), requestHash)
                    || !Objects.equals(existing.getPreviewFingerprint(), previewFingerprint)
                    || !Objects.equals(existing.getWarehouseId(), warehouseId)) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "相同幂等键对应不同计划包请求");
            }
            if (!ProductionPlanningPackage.STATUS_CONFIRMED.equals(existing.getStatus())) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "\u8be5\u5e42\u7b49\u952e\u5bf9\u5e94\u7684\u8ba1\u5212\u5305\u5df2\u53d6\u6d88\u6216\u7ea2\u51b2\uff1b\u5982\u9700\u91cd\u65b0\u786e\u8ba4\uff0c\u8bf7\u4f7f\u7528\u65b0\u7684\u5e42\u7b49\u952e");
            }
            return new BeginConfirmation(existing, true);
        }
        packageRepo.lockConfirmedByPlan(planId).ifPresent(active -> {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "该生产计划已有生效计划包，请先取消或红冲");
        });

        ProductionPlanningPackage created = new ProductionPlanningPackage();
        created.setPlanId(planId);
        created.setWarehouseId(warehouseId);
        created.setIdempotencyKey(normalizedKey);
        created.setRequestHash(requestHash);
        created.setPreviewFingerprint(previewFingerprint);
        created.setStatus(ProductionPlanningPackage.STATUS_CONFIRMED);
        packageRepo.saveAndFlush(created);
        return new BeginConfirmation(created, false);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public List<ProductionMaterialDemand> createDemands(
            ProductionPlanningPackage planningPackage,
            List<DemandDraft> drafts) {
        if (drafts == null || drafts.isEmpty()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "计划没有可持久化的 BOM 物料需求");
        }
        List<ProductionMaterialDemand> created = new ArrayList<>(drafts.size());
        Set<Dimension> dimensions = new HashSet<>();
        for (DemandDraft draft : drafts) {
            requireDemandDraft(draft);
            Dimension dimension = new Dimension(
                    draft.executionSegmentId(), draft.goodsId(),
                    draft.colorId(), draft.needDate());
            if (!dimensions.add(dimension)) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "计划包存在重复物料需求维度");
            }
            ProductionMaterialDemand demand = new ProductionMaterialDemand();
            demand.setPackageId(planningPackage.getId());
            demand.setPlanId(planningPackage.getPlanId());
            demand.setExecutionSegmentId(draft.executionSegmentId());
            demand.setSourcePlanItemId(draft.sourcePlanItemId());
            demand.setPerProductQty(draft.perProductQty());
            demand.setRequirementMode(draft.requirementMode());
            demand.setRequiredForProductQty(
                    draft.requiredForProductQty());
            demand.setRequirementFingerprint(
                    draft.requirementFingerprint());
            demand.setWarehouseId(planningPackage.getWarehouseId());
            demand.setGoodsId(draft.goodsId());
            demand.setColorId(draft.colorId());
            demand.setUnitId(draft.unitId());
            demand.setRequiredQty(draft.requiredQty());
            demand.setNeedDate(draft.needDate());
            demand.setSupplyRoute(draft.supplyRoute());
            demand.setStatus(ProductionMaterialDemand.STATUS_OPEN);
            demand.setIdempotencyKey(
                    planningPackage.getId() + ":DEMAND:" + draft.stableKey());
            created.add(demandRepo.save(demand));
        }
        demandRepo.flush();
        return List.copyOf(created);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void recordDocument(
            UUID packageId,
            String documentType,
            UUID documentId,
            String documentNo,
            UUID actorId) {
        recordDocument(
                packageId, null, documentType, documentId, documentNo, actorId);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void recordDocument(
            UUID packageId,
            UUID executionSegmentId,
            String documentType,
            UUID documentId,
            String documentNo,
            UUID actorId) {
        int inserted = em.createNativeQuery("""
                        INSERT INTO production_planning_package_documents (
                            package_id, execution_segment_id, document_type,
                            document_id, document_no, created_at, created_by
                        ) VALUES (
                            :packageId, :segmentId, :documentType,
                            :documentId, :documentNo, now(), :actorId
                        )
                        ON CONFLICT (package_id, document_type, document_id)
                        DO NOTHING
                        """)
                .setParameter("packageId", packageId)
                .setParameter("segmentId", executionSegmentId)
                .setParameter("documentType", documentType)
                .setParameter("documentId", documentId)
                .setParameter("documentNo", documentNo)
                .setParameter("actorId", actorId)
                .executeUpdate();
        if (inserted != 1) {
            List<?> existing = em.createNativeQuery("""
                            SELECT 1
                            FROM production_planning_package_documents
                            WHERE package_id = :packageId
                              AND document_type = :documentType
                              AND document_id = :documentId
                              AND execution_segment_id IS NOT DISTINCT FROM CAST(:segmentId AS uuid)
                            """)
                    .setParameter("packageId", packageId)
                    .setParameter("documentType", documentType)
                    .setParameter("documentId", documentId)
                    .setParameter("segmentId", executionSegmentId)
                    .getResultList();
            if (existing.isEmpty()) {
                throw new ApiException(ErrorCode.CONFLICT, "计划包单据关联写入失败");
            }
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void attachPurchaseRequest(
            ProductionPlanningPackage planningPackage,
            UUID requestId) {
        planningPackage.setPurchaseRequestId(requestId);
        planningPackage.setLockVersion(planningPackage.getLockVersion() + 1);
        packageRepo.save(planningPackage);
    }

    /**
     * Opens V164's exact, transaction-local cleanup lane for one draft DRAW.
     *
     * <p>The database still validates the document type, draft state and the
     * exact false-to-true soft-delete shape. Calling this method never permits
     * quantity, warehouse or identity changes.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void authorizeDraftDrawCleanup(UUID documentId) {
        if (documentId == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "生产备料单清理缺少精确单据标识");
        }
        em.createNativeQuery("""
                        SELECT set_config(
                            'app.production_stock_cleanup_doc_id', :id, true)
                        """)
                .setParameter("id", documentId.toString())
                .getSingleResult();
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public ProductionMaterialSupplyPeg createSupplyPeg(
            ProductionMaterialDemand demand,
            String supplyType,
            UUID supplyItemId,
            BigDecimal allocatedQty,
            LocalDate expectedDate) {
        if (demand == null
                || supplyItemId == null
                || allocatedQty == null
                || allocatedQty.signum() <= 0) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "供给挂接缺少必填字段或数量无效");
        }
        ProductionMaterialSupplyPeg peg = new ProductionMaterialSupplyPeg();
        peg.setDemandId(demand.getId());
        peg.setSupplyType(supplyType);
        peg.setSupplyItemId(supplyItemId);
        peg.setAllocatedQty(allocatedQty);
        peg.setExpectedDate(expectedDate);
        peg.setStatus(ProductionMaterialSupplyPeg.STATUS_EFFECTIVE);
        peg.setIdempotencyKey(
                demand.getId() + ":" + supplyType + ":" + supplyItemId);
        ProductionMaterialSupplyPeg saved = pegRepo.save(peg);
        pegRepo.flush();
        return saved;
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void refreshDemandStatuses(Collection<UUID> demandIds) {
        List<UUID> ids = normalizeIds(demandIds);
        if (ids.isEmpty()) {
            return;
        }
        int updated = em.createNativeQuery("""
                        WITH coverage AS (
                            SELECT d.id,
                                   d.required_qty,
                                   d.released_qty,
                                   COALESCE((
                                       SELECT SUM(r.qty - r.released_qty)
                                       FROM stock_reservations r
                                       WHERE r.demand_id = d.id
                                         AND r.is_deleted = FALSE
                                   ), 0) AS stock_committed,
                                   COALESCE((
                                       SELECT SUM(p.allocated_qty
                                                  - p.consumed_qty - p.released_qty)
                                       FROM production_material_supply_pegs p
                                       WHERE p.demand_id = d.id
                                         AND p.status <> 'REVERSED'
                                   ), 0) AS supply_committed,
                                   COALESCE((
                                       SELECT SUM(r.consumed_qty)
                                       FROM stock_reservations r
                                       WHERE r.demand_id = d.id
                                         AND r.is_deleted = FALSE
                                   ), 0) AS fulfilled
                            FROM production_material_demands d
                            WHERE d.id IN (:ids)
                              AND d.is_deleted = FALSE
                        )
                        UPDATE production_material_demands d
                        SET status = CASE
                                WHEN c.released_qty >= c.required_qty THEN 'RELEASED'
                                WHEN c.fulfilled >= c.required_qty THEN 'FULFILLED'
                                WHEN c.stock_committed + c.supply_committed >= c.required_qty
                                     AND c.supply_committed > 0 THEN 'WAITING_SUPPLY'
                                WHEN c.stock_committed >= c.required_qty THEN 'ALLOCATED'
                                WHEN c.stock_committed + c.supply_committed > 0 THEN 'PARTIAL'
                                ELSE 'OPEN'
                            END,
                            lock_version = lock_version + 1,
                            updated_at = now()
                        FROM coverage c
                        WHERE d.id = c.id
                        """)
                .setParameter("ids", ids)
                .executeUpdate();
        if (updated != ids.size()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "物料需求状态刷新数量不一致");
        }
    }

    @Transactional(readOnly = true)
    public Set<MaterialDimension> allocationBackedDimensions(UUID planId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT d.goods_id, d.color_id
                                FROM production_material_demands d
                                JOIN production_planning_packages p
                                  ON p.id = d.package_id
                                 AND p.status = 'CONFIRMED'
                                 AND p.is_deleted = FALSE
                                WHERE d.plan_id = :planId
                                  AND d.is_deleted = FALSE
                                  AND d.status NOT IN ('RELEASED', 'REVERSED')
                                  AND (
                                      COALESCE((
                                          SELECT SUM(r.qty - r.released_qty)
                                          FROM stock_reservations r
                                          WHERE r.demand_id = d.id
                                            AND r.is_deleted = FALSE
                                      ), 0)
                                      + COALESCE((
                                          SELECT SUM(s.allocated_qty
                                                     - s.consumed_qty - s.released_qty)
                                          FROM production_material_supply_pegs s
                                          WHERE s.demand_id = d.id
                                            AND s.status <> 'REVERSED'
                                      ), 0)
                                  ) >= d.required_qty - d.released_qty
                                """)
                        .setParameter("planId", planId));
        Set<MaterialDimension> result = new HashSet<>();
        rows.forEach(row -> result.add(
                new MaterialDimension((UUID) row[0], (UUID) row[1])));
        return Set.copyOf(result);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public LifecycleHandle lockForLifecycle(
            UUID planId,
            UUID packageId,
            LifecycleAction action,
            String idempotencyKey) {
        String normalizedKey = normalizedKey(idempotencyKey);
        ProductionPlanningPackage planningPackage = em.find(
                ProductionPlanningPackage.class,
                packageId,
                LockModeType.PESSIMISTIC_WRITE);
        if (planningPackage == null
                || planningPackage.isDeleted()
                || !Objects.equals(planningPackage.getPlanId(), planId)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "计划包不存在");
        }
        String target = action == LifecycleAction.CANCEL
                ? ProductionPlanningPackage.STATUS_CANCELLED
                : ProductionPlanningPackage.STATUS_REVERSED;
        String storedKey = action == LifecycleAction.CANCEL
                ? planningPackage.getCancelIdempotencyKey()
                : planningPackage.getReverseIdempotencyKey();
        if (target.equals(planningPackage.getStatus())) {
            if (Objects.equals(storedKey, normalizedKey)) {
                return new LifecycleHandle(planningPackage, List.of(), true);
            }
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "计划包已由另一个幂等请求完成相同操作");
        }
        if (!ProductionPlanningPackage.STATUS_CONFIRMED.equals(planningPackage.getStatus())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "计划包当前状态不允许该操作");
        }

        List<UUID> demandIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT id
                        FROM production_material_demands
                        WHERE package_id = :packageId
                          AND is_deleted = FALSE
                        ORDER BY goods_id, color_id NULLS FIRST, id
                        """, UUID.class)
                .setParameter("packageId", packageId), UUID.class);
        // releaseByDemands acquires advisory dimensions before it locks these
        // demand rows, matching allocation and DRAW-issue lock order.
        return new LifecycleHandle(
                planningPackage, List.copyOf(demandIds), false);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void releaseLocked(
            LifecycleHandle handle,
            LifecycleAction action,
            String idempotencyKey,
            String reason) {
        if (handle.replayed()) {
            return;
        }
        List<UUID> demandIds = handle.demandIds();
        stockAllocation.releaseByDemands(demandIds, reason);

        Object consumed = em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_material_supply_pegs
                        WHERE demand_id IN (:ids)
                          AND consumed_qty > 0
                          AND status <> 'REVERSED'
                        """)
                .setParameter("ids", demandIds)
                .getSingleResult();
        if (((Number) consumed).longValue() > 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "采购或委外供给已被消费，必须先反向处理下游履约");
        }

        em.createNativeQuery("""
                        UPDATE production_material_supply_pegs
                        SET released_qty = allocated_qty,
                            status = :status,
                            lock_version = lock_version + 1,
                            updated_at = now()
                        WHERE demand_id IN (:ids)
                          AND status NOT IN ('RELEASED', 'REVERSED')
                        """)
                .setParameter(
                        "status",
                        action == LifecycleAction.CANCEL ? "RELEASED" : "REVERSED")
                .setParameter("ids", demandIds)
                .executeUpdate();

        int demands = em.createNativeQuery("""
                        UPDATE production_material_demands
                        SET released_qty = required_qty,
                            status = :status,
                            lock_version = lock_version + 1,
                            updated_at = now()
                        WHERE id IN (:ids)
                          AND is_deleted = FALSE
                        """)
                .setParameter(
                        "status",
                        action == LifecycleAction.CANCEL ? "RELEASED" : "REVERSED")
                .setParameter("ids", demandIds)
                .executeUpdate();
        if (demands != demandIds.size()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "计划包需求释放数量不一致");
        }

        ProductionPlanningPackage planningPackage = handle.planningPackage();
        if (action == LifecycleAction.CANCEL) {
            planningPackage.setStatus(ProductionPlanningPackage.STATUS_CANCELLED);
            planningPackage.setCancelIdempotencyKey(normalizedKey(idempotencyKey));
        } else {
            planningPackage.setStatus(ProductionPlanningPackage.STATUS_REVERSED);
            planningPackage.setReverseIdempotencyKey(normalizedKey(idempotencyKey));
        }
        planningPackage.setLifecycleReason(normalizeReason(reason));
        planningPackage.setLockVersion(planningPackage.getLockVersion() + 1);
        packageRepo.save(planningPackage);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public List<PackageDocument> lockPackageDocuments(UUID packageId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT document_type, document_id, document_no
                                FROM production_planning_package_documents
                                WHERE package_id = :packageId
                                ORDER BY document_type, document_id
                                FOR UPDATE
                                """)
                        .setParameter("packageId", packageId));
        return rows.stream()
                .map(row -> new PackageDocument(
                        (String) row[0], (UUID) row[1], (String) row[2]))
                .toList();
    }

    private static List<UUID> normalizeIds(Collection<UUID> ids) {
        return ids == null
                ? List.of()
                : ids.stream().filter(Objects::nonNull).distinct().sorted().toList();
    }

    private static void requireDemandDraft(DemandDraft draft) {
        if (draft == null
                || draft.goodsId() == null
                || (
                    draft.executionSegmentId() != null
                    && (
                        draft.sourcePlanItemId() == null
                        || draft.perProductQty() == null
                        || draft.perProductQty().signum() <= 0
                    )
                )
                || draft.unitId() == null
                || draft.requiredQty() == null
                || draft.requiredQty().signum() <= 0
                || !Set.of(
                                ProductionMaterialDemand.ROUTE_BUY,
                                ProductionMaterialDemand.ROUTE_MAKE,
                                ProductionMaterialDemand.ROUTE_SUBCONTRACT)
                        .contains(draft.supplyRoute())
                || draft.stableKey() == null
                || draft.stableKey().isBlank()
                || !validRequirementSnapshot(draft)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "物料需求缺少必填字段或数量/路线无效");
        }
    }

    private static boolean validRequirementSnapshot(DemandDraft draft) {
        if (ProductionMaterialDemand.REQUIREMENT_MODE_LINEAR.equals(
                draft.requirementMode())) {
            return draft.requiredForProductQty() == null
                    && draft.requirementFingerprint() == null;
        }
        return ProductionMaterialDemand.REQUIREMENT_MODE_EXACT_SNAPSHOT.equals(
                        draft.requirementMode())
                && draft.executionSegmentId() != null
                && draft.sourcePlanItemId() != null
                && draft.requiredForProductQty() != null
                && draft.requiredForProductQty().signum() > 0
                && draft.requirementFingerprint() != null
                && draft.requirementFingerprint().matches("[0-9a-f]{64}");
    }

    private static void requireKey(String key) {
        if (key == null || key.isBlank() || key.strip().length() < 8
                || key.strip().length() > 128) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "幂等键长度必须为 8 到 128 个字符");
        }
    }

    private static String normalizedKey(String key) {
        requireKey(key);
        return key.strip();
    }

    private static String normalizeReason(String reason) {
        if (reason == null || reason.isBlank()) {
            return "未填写";
        }
        String normalized = reason.strip();
        return normalized.substring(0, Math.min(normalized.length(), 500));
    }

    public enum LifecycleAction {
        CANCEL,
        REVERSE
    }

    public record BeginConfirmation(
            ProductionPlanningPackage planningPackage,
            boolean replayed) {
    }

    public record DemandDraft(
            UUID executionSegmentId,
            UUID sourcePlanItemId,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal perProductQty,
            BigDecimal requiredQty,
            LocalDate needDate,
            String supplyRoute,
            String stableKey,
            String requirementMode,
            BigDecimal requiredForProductQty,
            String requirementFingerprint) {

        public DemandDraft(
                UUID executionSegmentId,
                UUID sourcePlanItemId,
                UUID goodsId,
                UUID colorId,
                UUID unitId,
                BigDecimal perProductQty,
                BigDecimal requiredQty,
                LocalDate needDate,
                String supplyRoute,
                String stableKey) {
            this(
                    executionSegmentId, sourcePlanItemId,
                    goodsId, colorId, unitId, perProductQty,
                    requiredQty, needDate, supplyRoute, stableKey,
                    ProductionMaterialDemand.REQUIREMENT_MODE_LINEAR,
                    null, null);
        }

        public DemandDraft(
                UUID goodsId,
                UUID colorId,
                UUID unitId,
                BigDecimal requiredQty,
                LocalDate needDate,
                String supplyRoute,
                String stableKey) {
            this(
                    null, null, goodsId, colorId, unitId, null,
                    requiredQty, needDate, supplyRoute, stableKey,
                    ProductionMaterialDemand.REQUIREMENT_MODE_LINEAR,
                    null, null);
        }
    }

    private record Dimension(
            UUID executionSegmentId,
            UUID goodsId,
            UUID colorId,
            LocalDate needDate) {
    }

    public record MaterialDimension(UUID goodsId, UUID colorId) {
    }

    public record LifecycleHandle(
            ProductionPlanningPackage planningPackage,
            List<UUID> demandIds,
            boolean replayed) {
    }

    public record PackageDocument(
            String documentType,
            UUID documentId,
            String documentNo) {
    }
}
