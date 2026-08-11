package com.uten.imp.features.production.mrp;

import com.uten.imp.application.port.ProductionSubcontractRequestPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import com.uten.imp.features.production.fulfillment.ProductionFulfillmentLedgerService;
import com.uten.imp.features.production.fulfillment.ProductionPlanningPackage;
import com.uten.imp.features.production.fulfillment.ProductionPlanningPackageRepository;
import com.uten.imp.features.purchase.request.ProductionPurchaseRequestFacade;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * Atomic production planning-package command service.
 *
 * <p>Lock order: parent plan/package, purchase source headers/items, inventory
 * dimensions, then demand/allocation rows. Matching goods never implies an
 * allocation: only persisted stock reservations and supply pegs do.
 */
@Service
@RequiredArgsConstructor
public class ProductionPlanningPackageService {

    private final EntityManager em;
    private final ProductionExecutionPackageCommandService executionCommand;
    private final ProductionPlanningPackageRepository planningPackageRepo;
    private final MrpService mrpService;
    private final ProductionExecutionPlanningService executionPlanning;
    private final ProductionFulfillmentLedgerService ledger;
    private final ProductionPurchaseRequestFacade purchaseFacade;
    private final ProductionSubcontractRequestPort subcontractRequests;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    @Transactional(readOnly = true)
    public PlanningPreviewResult preview(UUID planId, UUID warehouseId) {
        if (warehouseId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "必须选择目标仓库");
        }
        requireWarehouse(warehouseId);
        List<MrpRow> rows = mrpService.preview(planId);
        ProductionExecutionPlanningService.Snapshot snapshot =
                executionPlanning.preview(planId, warehouseId);
        CompleteKitAllocator.Allocation proposal =
                snapshot.productLines().isEmpty()
                        ? new CompleteKitAllocator.Allocation(
                                List.of(), snapshot.availability())
                        : executionPlanning.propose(snapshot);
        Map<MaterialKey, BigDecimal> targetWarehouseAvailable =
                warehouseAvailability(warehouseId, rows);
        List<UUID> noBomGoodsIds = noBomGoodsIds(planId, snapshot.noBomPlanItemIds());
        // 已转发工程研发部的货品（成品 + 一层自制组件）——用于前端展示「已通知·等待中」。
        // 注意：转发态不进 fingerprint，否则研发一转发，计划员手里的预览就过期要重算。
        List<UUID> forwardedGoodsIds = forwardedGoodsIds(rows, noBomGoodsIds);
        return new PlanningPreviewResult(
                planId,
                warehouseId,
                snapshot.fingerprint(),
                rows,
                targetWarehouseMaterials(rows, targetWarehouseAvailable),
                isBalancedKitCoverage(rows, targetWarehouseAvailable),
                true,
                executionPlanning.toPreview(proposal),
                snapshot.noBomPlanItemIds(),
                noBomGoodsIds,
                forwardedGoodsIds);
    }

    /** 成品 noBom 行的货品 id（供前端判成品缺 BOM 的转发态）。noBomPlanItemIds 是计划行 id，需 join 取 goods_id。 */
    @SuppressWarnings("unchecked")
    private List<UUID> noBomGoodsIds(UUID planId, List<UUID> noBomPlanItemIds) {
        if (noBomPlanItemIds == null || noBomPlanItemIds.isEmpty()) {
            return List.of();
        }
        return em.createNativeQuery("""
                SELECT goods_id FROM production_plan_items
                WHERE id IN (:ids) AND is_deleted = false
                """)
                .setParameter("ids", noBomPlanItemIds)
                .getResultStream()
                .map(o -> (UUID) o)
                .distinct()
                .toList();
    }

    /** 在当前计划涉及的货品（一层自制组件 + 成品 noBom）中，哪些已有未完成 BOM 类研发任务。 */
    @SuppressWarnings("unchecked")
    private List<UUID> forwardedGoodsIds(List<MrpRow> rows, List<UUID> noBomGoodsIds) {
        Set<UUID> goods = new java.util.LinkedHashSet<>();
        rows.forEach(row -> goods.add(row.goodsId()));
        if (noBomGoodsIds != null) {
            goods.addAll(noBomGoodsIds);
        }
        goods.remove(null);
        if (goods.isEmpty()) {
            return List.of();
        }
        return em.createNativeQuery("""
                SELECT DISTINCT goods_id FROM rd_tasks
                WHERE category = 'BOM' AND status IN ('OPEN','IN_PROGRESS') AND is_deleted = false
                  AND goods_id IN (:ids)
                """)
                .setParameter("ids", goods)
                .getResultStream()
                .map(o -> (UUID) o)
                .toList();
    }

    @Transactional
    public Optional<PlanningPackageResult> currentResult(UUID planId) {
        return planningPackageRepo
                .findFirstByPlanIdAndStatusAndExecutionModelVersionAndDeletedFalseOrderByCreatedAtDesc(
                        planId,
                        ProductionPlanningPackage.STATUS_CONFIRMED,
                        (short) 1)
                .map(executionCommand::replay);
    }

    @Transactional
    public PlanningPackageResult confirm(
            UUID planId,
            GeneratePlanningPackageRequest request) {
        tx.bind();
        return executionCommand.confirm(planId, request);
    }

    @Transactional
    public PlanningPackageLifecycleResult cancel(
            UUID planId,
            UUID packageId,
            PlanningPackageLifecycleRequest request) {
        tx.bind();
        return lifecycle(
                planId,
                packageId,
                request,
                ProductionFulfillmentLedgerService.LifecycleAction.CANCEL);
    }

    @Transactional
    public PlanningPackageLifecycleResult reverse(
            UUID planId,
            UUID packageId,
            PlanningPackageLifecycleRequest request) {
        tx.bind();
        return lifecycle(
                planId,
                packageId,
                request,
                ProductionFulfillmentLedgerService.LifecycleAction.REVERSE);
    }

    private PlanningPackageLifecycleResult lifecycle(
            UUID planId,
            UUID packageId,
            PlanningPackageLifecycleRequest request,
            ProductionFulfillmentLedgerService.LifecycleAction action) {
        if (request == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "缺少计划包生命周期请求");
        }
        lockPlan(planId);
        ProductionFulfillmentLedgerService.LifecycleHandle handle =
                ledger.lockForLifecycle(
                        planId, packageId, action, request.idempotencyKey());
        if (handle.replayed()) {
            return new PlanningPackageLifecycleResult(
                    packageId, handle.planningPackage().getStatus(), true);
        }
        List<ProductionFulfillmentLedgerService.PackageDocument> documents =
                ledger.lockPackageDocuments(packageId);

        ProductionFulfillmentLedgerService.PackageDocument purchase = documents.stream()
                .filter(document -> "PURCHASE_REQUEST".equals(document.documentType()))
                .findFirst()
                .orElse(null);
        if (purchase != null) {
            purchaseFacade.cancelGeneratedDraft(
                    purchase.documentId(),
                    action == ProductionFulfillmentLedgerService.LifecycleAction.CANCEL
                            ? ProductionPurchaseRequestFacade.LifecycleAction.CANCEL
                            : ProductionPurchaseRequestFacade.LifecycleAction.REVERSE);
        }
        ProductionFulfillmentLedgerService.PackageDocument subcontract =
                documents.stream()
                        .filter(document ->
                                "SUBCONTRACT_APPLICATION".equals(
                                        document.documentType()))
                        .findFirst()
                        .orElse(null);
        if (subcontract != null) {
            subcontractRequests.closeGeneratedDraft(
                    subcontract.documentId(),
                    action == ProductionFulfillmentLedgerService
                                    .LifecycleAction.CANCEL
                            ? ProductionSubcontractRequestPort
                                    .LifecycleAction.CANCEL
                            : ProductionSubcontractRequestPort
                                    .LifecycleAction.REVERSE);
        }
        closeExecutionSegments(packageId, action);
        closeDraw(documents, action);
        ledger.releaseLocked(
                handle, action, request.idempotencyKey(), request.reason());
        closeSubplans(documents, action, request);
        return new PlanningPackageLifecycleResult(
                packageId, handle.planningPackage().getStatus(), false);
    }

    private void closeExecutionSegments(
            UUID packageId,
            ProductionFulfillmentLedgerService.LifecycleAction action) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, status
                                FROM production_execution_segments
                                WHERE package_id = :packageId
                                  AND is_deleted = FALSE
                                ORDER BY id
                                FOR UPDATE
                                """)
                        .setParameter("packageId", packageId));
        if (rows.isEmpty()) {
            return;
        }
        if (rows.stream().anyMatch(row ->
                !Set.of(
                                ProductionExecutionSegment.STATUS_READY,
                                ProductionExecutionSegment.STATUS_WAITING)
                        .contains((String) row[1]))) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "只有未开工的「就绪/等待」执行分段才能随计划包一起关闭");
        }
        int updated = em.createNativeQuery("""
                        UPDATE production_execution_segments
                        SET status = :status,
                            updated_at = now(),
                            updated_by = :actorId
                        WHERE package_id = :packageId
                          AND is_deleted = FALSE
                          AND status IN ('READY', 'WAITING')
                        """)
                .setParameter(
                        "status",
                        action == ProductionFulfillmentLedgerService
                                        .LifecycleAction.CANCEL
                                ? ProductionExecutionSegment.STATUS_CANCELLED
                                : ProductionExecutionSegment.STATUS_REVERSED)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("packageId", packageId)
                .executeUpdate();
        if (updated != rows.size()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "执行分段已被并发修改，请刷新后重试");
        }
    }

    private void closeDraw(
            List<ProductionFulfillmentLedgerService.PackageDocument> documents,
            ProductionFulfillmentLedgerService.LifecycleAction action) {
        List<UUID> ids = documents.stream()
                .filter(document -> "DRAW".equals(document.documentType()))
                .map(ProductionFulfillmentLedgerService.PackageDocument::documentId)
                .sorted()
                .toList();
        for (UUID id : ids) {
            List<Object[]> rows = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                                    SELECT status, is_deleted
                                    FROM stock_documents
                                    WHERE id = :id AND doc_type = 'DRAW'
                                    FOR UPDATE
                                    """)
                            .setParameter("id", id));
            @SuppressWarnings("unchecked")
            List<Object> issueRows = em.createNativeQuery("""
                            SELECT issued_qty
                            FROM stock_document_items
                            WHERE doc_id = :id
                            ORDER BY id
                            FOR UPDATE
                            """)
                    .setParameter("id", id)
                    .getResultList();
            BigDecimal issuedQty = issueRows.stream()
                    .map(ProductionPlanningPackageService::decimal)
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            if (rows.isEmpty()
                    || Boolean.TRUE.equals(rows.getFirst()[1])
                    || ((Number) rows.getFirst()[0]).shortValue() != 0
                    || issuedQty.signum() > 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "备料单已审核、发料或删除，必须先完成退料/红冲链路");
            }
            ledger.authorizeDraftDrawCleanup(id);
            if (action == ProductionFulfillmentLedgerService.LifecycleAction.CANCEL) {
                em.createNativeQuery("""
                                UPDATE stock_documents
                                SET is_deleted = TRUE, deleted_at = now(), updated_at = now()
                                WHERE id = :id
                                """)
                        .setParameter("id", id)
                        .executeUpdate();
            } else {
                em.createNativeQuery("""
                                UPDATE stock_documents
                                SET status = -1, updated_at = now()
                                WHERE id = :id
                                """)
                        .setParameter("id", id)
                        .executeUpdate();
            }
            em.createNativeQuery("""
                            UPDATE plan_draw_links
                            SET is_deleted = TRUE, deleted_at = now()
                            WHERE draw_id = :id AND is_deleted = FALSE
                            """)
                    .setParameter("id", id)
                    .executeUpdate();
        }
    }

    private void closeSubplans(
            List<ProductionFulfillmentLedgerService.PackageDocument> documents,
            ProductionFulfillmentLedgerService.LifecycleAction action,
            PlanningPackageLifecycleRequest request) {
        List<UUID> ids = documents.stream()
                .filter(document -> "SUBPLAN".equals(document.documentType()))
                .map(ProductionFulfillmentLedgerService.PackageDocument::documentId)
                .sorted()
                .toList();
        for (UUID id : ids) {
            List<Object[]> rows = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                                    SELECT status, is_deleted
                                    FROM production_plans
                                    WHERE id = :id
                                    FOR UPDATE
                                    """)
                            .setParameter("id", id));
            if (rows.isEmpty()) {
                throw new ApiException(ErrorCode.CONFLICT, "计划包子计划不存在");
            }
            Object[] row = rows.getFirst();
            short status = ((Number) row[0]).shortValue();
            List<Object[]> itemRows = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                                    SELECT fqty, iqty
                                    FROM production_plan_items
                                    WHERE plan_id = :id AND is_deleted = FALSE
                                    ORDER BY id
                                    FOR UPDATE
                                    """)
                            .setParameter("id", id));
            BigDecimal finishedQty = itemRows.stream()
                    .map(item -> decimal(item[0]))
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            BigDecimal inboundQty = itemRows.stream()
                    .map(item -> decimal(item[1]))
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            // #13: 自底向上 orchestrator 建的多层树——auto_generated 子计划若自带 CONFIRMED 包（更深层 MAKE），
            // 先递归 cancel/reverse 该子包（下到叶子），再关本子；使整树可一次回退。
            // 仅 auto_generated 子级联；人工建的嵌套包绝不静默反转（落到下面 hasActiveSubplanDownstream 抛清晰冲突）。
            UUID childPackageId = confirmedPackageOf(id);
            if (isAutoGeneratedPlan(id) && childPackageId != null) {
                PlanningPackageLifecycleRequest childRequest = new PlanningPackageLifecycleRequest(
                        request.idempotencyKey() + ":cascade:" + id,
                        request.reason() + "（整树级联）");
                lifecycle(id, childPackageId, childRequest, action);
            }
            if (Boolean.TRUE.equals(row[1])
                    || finishedQty.signum() > 0
                    || inboundQty.signum() > 0
                    || hasActiveSubplanDownstream(id)) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "子计划已有执行或下游单据，必须先完成反向链路");
            }
            if (action == ProductionFulfillmentLedgerService.LifecycleAction.CANCEL
                    && status != 0) {
                throw new ApiException(ErrorCode.CONFLICT, "仅草稿子计划可随计划包取消");
            }
            if (action == ProductionFulfillmentLedgerService.LifecycleAction.CANCEL) {
                em.createNativeQuery("""
                                UPDATE production_plans
                                SET is_deleted = TRUE, deleted_at = now(), updated_at = now()
                                WHERE id = :id
                                """)
                        .setParameter("id", id)
                        .executeUpdate();
            } else {
                em.createNativeQuery("""
                                UPDATE production_plans
                                SET status = -1, updated_at = now()
                                WHERE id = :id
                                """)
                        .setParameter("id", id)
                        .executeUpdate();
            }
            em.createNativeQuery("""
                            UPDATE subplan_links
                            SET is_deleted = TRUE, deleted_at = now()
                            WHERE subplan_id = :id AND is_deleted = FALSE
                            """)
                    .setParameter("id", id)
                    .executeUpdate();
        }
    }

    private boolean hasActiveSubplanDownstream(UUID subplanId) {
        Object count = em.createNativeQuery("""
                        SELECT
                            (SELECT COUNT(*)
                             FROM plan_draw_links l
                             JOIN stock_documents d ON d.id = l.draw_id
                             WHERE l.plan_id = :id
                               AND l.is_deleted = FALSE
                               AND d.is_deleted = FALSE
                               AND d.status <> -1)
                          + (SELECT COUNT(*)
                             FROM mrp_generations g
                             JOIN purchase_requests r ON r.id = g.request_id
                             WHERE g.plan_id = :id
                               AND g.is_deleted = FALSE
                               AND r.is_deleted = FALSE
                               AND r.status <> -1)
                          + (SELECT COUNT(*)
                             FROM subplan_links l
                             JOIN production_plans p ON p.id = l.subplan_id
                             WHERE l.plan_id = :id
                               AND l.is_deleted = FALSE
                               AND p.is_deleted = FALSE
                               AND p.status <> -1)
                          + (SELECT COUNT(*)
                             FROM production_planning_packages package
                             WHERE package.plan_id = :id
                               AND package.is_deleted = FALSE
                               AND package.status = 'CONFIRMED')
                        """)
                .setParameter("id", subplanId)
                .getSingleResult();
        return ((Number) count).longValue() > 0;
    }

    /** 该计划是否由自底向上 orchestrator 自动创建（V230 auto_generated）。级联回退仅作用于此类子计划。 */
    private boolean isAutoGeneratedPlan(UUID planId) {
        Object value = em.createNativeQuery(
                        "SELECT COALESCE(auto_generated, FALSE) FROM production_plans WHERE id = :id")
                .setParameter("id", planId).getSingleResult();
        return Boolean.TRUE.equals(value);
    }

    /** 该计划的生效 CONFIRMED 执行包 id（无则 null）。用于级联回退判定子计划是否有更深 MAKE 层。 */
    private UUID confirmedPackageOf(UUID planId) {
        List<UUID> rows = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                        SELECT id FROM production_planning_packages
                        WHERE plan_id = :id AND is_deleted = FALSE AND status = 'CONFIRMED'
                        ORDER BY id
                        """).setParameter("id", planId), UUID.class);
        return rows.isEmpty() ? null : rows.getFirst();
    }

    private Map<MaterialKey, BigDecimal> warehouseAvailability(
            UUID warehouseId,
            List<MrpRow> rows) {
        if (rows.isEmpty()) {
            return Map.of();
        }
        List<UUID> goodsIds = rows.stream()
                .map(MrpRow::goodsId)
                .distinct()
                .sorted()
                .toList();
        List<Object[]> values = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT a.goods_id, a.color_id,
                                       GREATEST(a.available_qty
                                                - GREATEST(COALESCE(g.min_qty, 0), 0), 0)
                                FROM v_stock_available a
                                JOIN goods g ON g.id = a.goods_id
                                WHERE a.warehouse_id = :warehouseId
                                  AND a.goods_id IN (:goodsIds)
                                """)
                        .setParameter("warehouseId", warehouseId)
                        .setParameter("goodsIds", goodsIds));
        Map<MaterialKey, BigDecimal> result = new HashMap<>();
        values.forEach(row -> result.put(
                new MaterialKey((UUID) row[0], (UUID) row[1]),
                decimal(row[2])));
        return result;
    }

    private static List<PlanningPreviewResult.TargetWarehouseMaterial>
            targetWarehouseMaterials(
                    List<MrpRow> rows,
                    Map<MaterialKey, BigDecimal> warehouseAvailable) {
        return rows.stream()
                .map(row -> {
                    BigDecimal required = row.gross();
                    BigDecimal available = warehouseAvailable.getOrDefault(
                            new MaterialKey(row.goodsId(), row.colorId()),
                            BigDecimal.ZERO);
                    BigDecimal candidate = required.min(available);
                    return new PlanningPreviewResult.TargetWarehouseMaterial(
                            row.goodsId(),
                            row.colorId(),
                            required,
                            available,
                            candidate,
                            required.subtract(candidate).max(BigDecimal.ZERO));
                })
                .toList();
    }

    private static boolean isBalancedKitCoverage(
            List<MrpRow> rows,
            Map<MaterialKey, BigDecimal> warehouseAvailable) {
        return hasCommonCoverageRatio(rows.stream()
                .filter(row -> row.gross().signum() > 0)
                .map(row -> new CoverageQuantity(
                        row.gross(),
                        warehouseAvailable
                                .getOrDefault(
                                        new MaterialKey(row.goodsId(), row.colorId()),
                                        BigDecimal.ZERO)
                                .min(row.gross())))
                .toList());
    }

    static boolean hasCommonCoverageRatio(List<CoverageQuantity> quantities) {
        if (quantities.isEmpty()) {
            return true;
        }
        CoverageQuantity reference = quantities.getFirst();
        if (reference.requiredQty().signum() <= 0) {
            throw new IllegalArgumentException("需求数量必须大于零");
        }
        return quantities.stream().allMatch(quantity -> {
            if (quantity.requiredQty().signum() <= 0
                    || quantity.allocatedQty().signum() < 0
                    || quantity.allocatedQty().compareTo(quantity.requiredQty()) > 0) {
                throw new IllegalArgumentException("覆盖数量无效");
            }
            return quantity.allocatedQty().multiply(reference.requiredQty())
                    .compareTo(reference.allocatedQty().multiply(
                            quantity.requiredQty())) == 0;
        });
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private void requireWarehouse(UUID warehouseId) {
        Object count = em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM warehouses
                        WHERE id = :id AND is_deleted = FALSE
                        """)
                .setParameter("id", warehouseId)
                .getSingleResult();
        if (((Number) count).longValue() != 1) {
            throw new ApiException(ErrorCode.NOT_FOUND, "目标仓库不存在或已停用");
        }
    }

    private PlanHeader lockPlan(UUID planId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT bill_no, delivery_date, status,
                                       is_deleted, is_canceled, is_stopped
                                FROM production_plans
                                WHERE id = :id
                                FOR UPDATE
                                """)
                        .setParameter("id", planId));
        if (rows.isEmpty() || Boolean.TRUE.equals(rows.getFirst()[3])) {
            throw new ApiException(ErrorCode.NOT_FOUND, "生产计划不存在");
        }
        Object[] row = rows.getFirst();
        if (((Number) row[2]).shortValue() == -1
                || Boolean.TRUE.equals(row[4])
                || Boolean.TRUE.equals(row[5])) {
            throw new ApiException(ErrorCode.CONFLICT, "终态生产计划不能操作计划包");
        }
        return new PlanHeader(
                (String) row[0],
                row[1] == null ? null : ((java.sql.Date) row[1]).toLocalDate());
    }

    private record PlanHeader(String billNo, LocalDate deliveryDate) {
    }

    private record MaterialKey(UUID goodsId, UUID colorId) {
    }

    record CoverageQuantity(BigDecimal requiredQty, BigDecimal allocatedQty) {
    }
}
