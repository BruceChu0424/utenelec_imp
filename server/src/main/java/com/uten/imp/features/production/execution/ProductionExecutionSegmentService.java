package com.uten.imp.features.production.execution;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService;
import com.uten.imp.features.production.mrp.ProductionGoodsWorkshopPreferenceService;
import com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * Minimal executable lifecycle for production execution segments.
 *
 * <p>All mutations lock the segment first, compare an expected version and
 * persist a semantic idempotency event. Package-level cancel/reverse remains
 * the only operation allowed to change the effective partition total.
 */
@Service
@RequiredArgsConstructor
public class ProductionExecutionSegmentService {

    private static final String ACTION_ASSIGNMENT = "ASSIGNMENT";
    private static final String ACTION_DISPATCH = "DISPATCH";
    private static final String ACTION_START = "START";
    private static final String ACTION_RELEASE_DEFER = "RELEASE_DEFER";
    private static final String ACTION_RECHECK_MATERIAL = "RECHECK_MATERIAL";
    private static final String ACTION_ROUTE_CONFIRMED = "ROUTE_CONFIRMED";

    static final String ROUTE_FULL_KIT = "FULL_KIT";
    static final String ROUTE_BATCH = "BATCH";
    static final String ROUTE_CONTINUOUS = "CONTINUOUS";

    private final EntityManager em;
    private final ProductionGoodsWorkshopPreferenceService workshopPreferences;
    private final ProductionExecutionReadinessService readiness;
    private final ProductionAssignmentValidator assignmentValidator;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ChainNoticeService chainNotice;
    private final ProductionDocumentAccessPolicy access;
    private final com.uten.imp.features.production.ProductionWorkshopMembership workshopMembership;
    private final ProductionPlanMutationFootprintService planFootprints;

    @Transactional(readOnly = true)
    public List<ExecutionSegmentView> list(UUID planId) {
        requirePlanReadable(planId);
        return rows(planId, null);
    }

    /**
     * 为 READY/WAITING 执行段分配车间/班组/负责人与计划日期：仅派工前允许调整，乐观锁校验、幂等去重；
     * 车间变更会学习为本货品的偏好，供后续默认。
     */
    @Transactional
    public ExecutionSegmentView assign(
            UUID planId,
            UUID segmentId,
            SegmentAssignmentRequest request) {
        tx.bind();
        requireAssignmentRequest(request);
        requireOperationAuthority("production_execution:assign");
        var assignmentFootprint = planFootprints.beginPlan(planId, List.of());
        LockedSegment segment = lock(planId, segmentId);
        requireSegmentOperationAccess(
                segment, "production_execution:assign");
        String requestHash = hashAssignment(request);
        ExecutionSegmentView replay =
                replay(segment, ACTION_ASSIGNMENT, request.idempotencyKey(), requestHash);
        if (replay != null) return replay;
        assignmentFootprint.verifyUnchanged();
        requireVersion(segment, request.expectedVersion());
        requireActivePlan(segment);
        if (!List.of(
                        ProductionExecutionSegment.STATUS_READY,
                        ProductionExecutionSegment.STATUS_WAITING)
                .contains(segment.status())) {
            throw conflict("仅待料或齐套未派工的执行段可以调整分配");
        }
        if (!Objects.equals(segment.workshopDepartmentId(), request.workshopDepartmentId())
                && !Boolean.TRUE.equals(em.createNativeQuery("SELECT fn_can_reassign_execution_workshop(:id)")
                    .setParameter("id",segment.id()).getSingleResult())) {
            throw conflict("任务已有实物交接、有效历史领料单或共用物料关系，请先由计划核对并处理原任务、领料及关联批次；涉及实物时须沿原来源退回或反向，同车间仍可调整负责人");
        }
        assignmentValidator.validate(new ProductionAssignmentValidator.Assignment(
                request.workshopDepartmentId(),
                request.teamDepartmentId(),
                request.responsibleEmployeeId(),
                request.planBeginDate(),
                request.planEndDate()));
        int updated = em.createNativeQuery("""
                        UPDATE production_execution_segments
                        SET workshop_department_id = :workshopId,
                            team_department_id = :teamId,
                            responsible_employee_id = :employeeId,
                            plan_begin_date = :beginDate,
                            plan_end_date = :endDate
                        WHERE id = :id
                          AND lock_version = :expectedVersion
                          AND status IN ('READY', 'WAITING')
                          AND is_deleted = FALSE
                        """)
                .setParameter("workshopId", request.workshopDepartmentId())
                .setParameter("teamId", request.teamDepartmentId())
                .setParameter("employeeId", request.responsibleEmployeeId())
                .setParameter("beginDate", request.planBeginDate())
                .setParameter("endDate", request.planEndDate())
                .setParameter("id", segmentId)
                .setParameter("expectedVersion", request.expectedVersion())
                .executeUpdate();
        requireUpdated(updated);
        long resultingVersion = request.expectedVersion() + 1;
        recordEvent(
                segmentId,
                ACTION_ASSIGNMENT,
                request.idempotencyKey(),
                requestHash,
                request.expectedVersion(),
                resultingVersion);
        boolean workshopChanged = !Objects.equals(
                segment.workshopDepartmentId(), request.workshopDepartmentId());
        boolean responsibleChanged = !Objects.equals(
                segment.responsibleEmployeeId(),
                request.responsibleEmployeeId());
        synchronizeUnissuedDrawAssignments(segmentId, request, resultingVersion);
        // 2026-09-06 起改派同样学习负责人：车间或负责人任一变化都刷新记忆
        //（未选负责人时服务端保留旧记忆，不清空）。
        if (request.workshopDepartmentId() != null
                && (workshopChanged || responsibleChanged)) {
            workshopPreferences.learnSelection(
                    segment.productGoodsId(),
                    request.workshopDepartmentId(),
                    request.responsibleEmployeeId(),
                    currentUser.requireEmployeeId());
        }
        // 车间/负责人后补或变更必须重建车间任务卡：计划下达时车间为空的段，
        // publishWorkshopTask 会直接早退，首张通知只能在这里补发；换车间时旧
        // 卡先办结再投给新车间，清空车间则把残留弹窗一并办结。
        if (workshopChanged || responsibleChanged) {
            if (request.workshopDepartmentId() == null) {
                chainNotice.resolveProductionWorkshopTasks(
                        List.of(segmentId), "WORKSHOP_UNASSIGNED");
            } else {
                chainNotice.notifyExecutionSegmentWorkshopAssigned(segmentId);
            }
        }
        return one(planId, segmentId);
    }

    /** Pending DRAW delivery follows the task; issued documents remain historical facts. */
    private void synchronizeUnissuedDrawAssignments(
            UUID segmentId, SegmentAssignmentRequest request, long resultingVersion) {
        List<UUID> documents = NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT document.id FROM stock_documents document
                WHERE fn_execution_draw_assignment_syncable(document.id,:segment)
                  AND (document.department_id IS DISTINCT FROM CAST(:workshop AS uuid)
                    OR document.worker_id IS DISTINCT FROM CAST(:employee AS uuid))
                  AND EXISTS(SELECT 1 FROM production_planning_package_documents mapping
                      WHERE mapping.document_id=document.id AND mapping.document_type='DRAW'
                        AND mapping.execution_segment_id=:segment)
                ORDER BY document.id FOR UPDATE OF document
                """,UUID.class).setParameter("segment",segmentId)
                .setParameter("workshop",request.workshopDepartmentId())
                .setParameter("employee",request.responsibleEmployeeId()),UUID.class);
        if (documents.isEmpty()) return;
        if (request.workshopDepartmentId()==null) {
            throw validation("已有待发领料单的任务须保留有效收料车间，请选择新车间后再保存");
        }
        em.createNativeQuery("""
                UPDATE stock_documents SET department_id=:workshop,worker_id=:employee,
                    updated_at=now(),updated_by=:actor
                WHERE id IN (:documents)
                """).setParameter("workshop",request.workshopDepartmentId())
                .setParameter("employee",request.responsibleEmployeeId())
                .setParameter("actor",currentUser.requireId())
                .setParameter("documents",documents).executeUpdate();
        documents.forEach(document -> chainNotice.notifyProductionDrawReassigned(document,segmentId,resultingVersion));
    }

    /**
     * Releases an explicit USER_DEFER decision exactly once. Material
     * dimensions are locked before the segment row; the same transaction then
     * rechecks complete-kit availability and either promotes to READY or leaves
     * an automatically promotable WAITING segment.
     */
    @Transactional
    public ExecutionSegmentView releaseDefer(
            UUID planId,
            UUID segmentId,
            SegmentTransitionRequest request) {
        tx.bind();
        requireTransitionRequest(request);
        requirePlanOperationAccess(
                planId, "production_execution:release_defer");
        UUID warehouseId = readiness.lockManualReleaseDimensions(
                planId, segmentId);
        LockedSegment segment = lock(planId, segmentId);
        requireSegmentOperationAccess(
                segment, "production_execution:release_defer");
        String requestHash = hashTransition(
                request, ACTION_RELEASE_DEFER);
        ExecutionSegmentView replay = replay(
                segment, ACTION_RELEASE_DEFER,
                request.idempotencyKey(), requestHash);
        if (replay != null) return replay;
        requireVersion(segment, request.expectedVersion());
        requireActivePlan(segment);
        if (!ProductionExecutionSegment.STATUS_WAITING.equals(
                segment.status())
                || segment.autoPromoteWhenReady()) {
            throw conflict("仅人工暂缓中的待料执行段可以解除暂缓");
        }
        if (warehouseId == null) {
            throw conflict("执行段缺少有效的确认计划包或发料仓");
        }

        int updated = em.createNativeQuery("""
                        UPDATE production_execution_segments
                        SET auto_promote_when_ready = TRUE,
                            updated_by = :actorId
                        WHERE id = :segmentId
                          AND lock_version = :expectedVersion
                          AND status = 'WAITING'
                          AND auto_promote_when_ready = FALSE
                          AND is_deleted = FALSE
                        """)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("segmentId", segmentId)
                .setParameter("expectedVersion", request.expectedVersion())
                .executeUpdate();
        requireUpdated(updated);
        readiness.promoteAfterManualRelease(segmentId, warehouseId);
        ExecutionSegmentView result = one(planId, segmentId);
        recordEvent(
                segmentId,
                ACTION_RELEASE_DEFER,
                request.idempotencyKey(),
                requestHash,
                request.expectedVersion(),
                result.lockVersion());
        return result;
    }

    /** Rechecks arrivals and explicitly prepares unused returned material on the same task. */
    @Transactional
    public ExecutionSegmentView recheckMaterial(
            UUID planId, UUID segmentId, SegmentTransitionRequest request) {
        tx.bind();
        requireTransitionRequest(request);
        var materialFootprint = planFootprints.beginPlan(planId, List.of());
        UUID warehouseId = readiness.lockManualReleaseDimensions(planId, segmentId);
        LockedSegment segment = lock(planId, segmentId);
        requireSegmentOperationAccess(segment, "production_execution:start");
        String requestHash = hashTransition(request, ACTION_RECHECK_MATERIAL);
        ExecutionSegmentView replay = replay(segment, ACTION_RECHECK_MATERIAL,
                request.idempotencyKey(), requestHash);
        if (replay != null) return replay;
        requireVersion(segment, request.expectedVersion());
        requireActivePlan(segment);
        if (!List.of("WAITING", "READY", "DISPATCHED", "IN_PROGRESS").contains(segment.status())
                || !segment.autoPromoteWhenReady()) {
            throw conflict("仅有效待料或生产中的任务可以重新检查物料，人工暂缓须先解除暂缓");
        }
        if (warehouseId == null) throw conflict("执行段缺少有效的确认计划包或发料仓");
        requireRouteForRecheck(segment);
        materialFootprint.verifyUnchanged();
        readiness.promoteAfterMaterialRecheck(segmentId, warehouseId);
        readiness.prepareReturnedMaterialDraws(segmentId);
        // Cancelling an unreceived surplus request can unfreeze an existing
        // partial technical DRAW without requiring any new allocation or draft.
        readiness.issuePendingLineSideDraws(segmentId);
        ExecutionSegmentView result = one(planId, segmentId);
        recordEvent(segmentId, ACTION_RECHECK_MATERIAL, request.idempotencyKey(),
                requestHash, request.expectedVersion(), result.lockVersion());
        return result;
    }

    /**
     * 「确认生产路线」(V599 / ADR-091)：车间在开工前显式选定——齐套生产 / 分批生产 / 持续生产。
     * 未确认前所有开工侧动作被服务端拒绝、齐套自动提升被 {@code fn_execution_route_allows_auto_promote}
     * 抑制；确认 FULL_KIT 时若本已可齐套，就地补跑一次提升(与旧的「到货即提升」一致)。
     * 改路线只在 WAITING 且「未动过」(无领料单/报工/供给钉/预留)时允许，路线一经动过即冻结。
     */
    @Transactional
    public ExecutionSegmentView confirmRoute(
            UUID planId, UUID segmentId, SegmentRouteConfirmRequest request) {
        tx.bind();
        requireRouteConfirmRequest(request);
        // 与人工重核同一把锁尺：确认齐套路线可能就地出库线边仓草稿/整批提升，
        // 先按计划预锁履约足迹，再进库存维度锁。
        boolean kitCandidate = ROUTE_FULL_KIT.equals(request.route()) || ROUTE_CONTINUOUS.equals(request.route());
        UUID promotionWarehouseId = null;
        if (kitCandidate) {
            prelockForLineSideIssue(planId, List.of(segmentId));
            promotionWarehouseId = readiness.lockManualReleaseDimensions(planId, segmentId);
        }
        LockedSegment segment = lock(planId, segmentId);
        requireSegmentOperationAccess(segment, "production_execution:start");
        String requestHash = hashRouteConfirm(request);
        ExecutionSegmentView replay = replay(segment, ACTION_ROUTE_CONFIRMED,
                request.idempotencyKey(), requestHash);
        if (replay != null) return replay;
        requireVersion(segment, request.expectedVersion());
        requireActivePlan(segment);
        boolean firstConfirmation = segment.startRoute() == null;
        // A repeated confirmed route preserves existing preparation and physical history.
        boolean sameRoute = !firstConfirmation
                && Objects.equals(segment.startRoute(), request.route());
        if (!sameRoute || ROUTE_BATCH.equals(request.route())) {
            validateRouteChoice(segment, request.route());
        }
        if (!firstConfirmation && !sameRoute) {
            if (!List.of("WAITING", "READY", "DISPATCHED").contains(segment.status())) {
                throw conflict("开工后不能更改生产路线");
            }
            // ADR-095：开工前路线随时可换，已备料/已领料/直送已投都保留；只有开工或已有
            // 报工才冻结(fn_can_change_execution_route 的唯一口径)。
            if (!Boolean.TRUE.equals(em.createNativeQuery(
                            "SELECT fn_can_change_execution_route(:id)")
                            .setParameter("id", segmentId).getSingleResult())) {
                throw conflict("工单已开工或已有报工，开工路线不能更改");
            }
        }
        if (ROUTE_CONTINUOUS.equals(request.route())) {
            em.createNativeQuery("""
                    UPDATE production_material_demands SET direct_supply=TRUE,
                        lock_version=lock_version+1, updated_at=now()
                    WHERE execution_segment_id=:id AND NOT is_deleted
                      AND status NOT IN ('RELEASED','REVERSED')
                      AND NOT direct_supply AND fn_demand_direct_supply_eligible(id)
                    """).setParameter("id", segmentId).executeUpdate();
        }
        // lock_version 由 trg_validate_production_execution_segment 触发器对每次
        // UPDATE 强制 +1（V155），语句无需（也不应）手工推进——与 assign() 同约定。
        // continuous_supply(ADR-095 起=「按增量备料」)：持续生产恒为 TRUE；改回齐套时
        // 已离开 WAITING 的工单保留增量备料(既有部分预留/领料/直送投入一件不动，
        // READY 守卫据此继续接受部分覆盖)，开工门改由 start_route 决定(V628)；
        // 仍在 WAITING 的齐套工单回到整批齐套备料；分批必须是未动过的任务。
        int updated = em.createNativeQuery("""
                        UPDATE production_execution_segments
                        SET start_route = :route,
                            route_confirmed_at = now(),
                            continuous_supply = CASE
                                WHEN :route = 'CONTINUOUS' THEN TRUE
                                WHEN :route = 'FULL_KIT' THEN continuous_supply AND status <> 'WAITING'
                                ELSE FALSE END
                        WHERE id = :id
                          AND lock_version = :expectedVersion
                          AND status IN ('WAITING', 'READY', 'DISPATCHED')
                          AND is_deleted = FALSE
                        """)
                .setParameter("route", request.route())
                .setParameter("id", segmentId)
                .setParameter("expectedVersion", request.expectedVersion())
                .executeUpdate();
        requireUpdated(updated);
        // 到货进展卡的下一步提示带着路线语境（「请先确认生产路线…」），路线一经
        // 确认即办结（ADR-091 §2.3，与开工/领料/分批同一聚合办结点）。放在补跑
        // 提升之前：FULL_KIT 就地齐套的提升会紧接着重发「物料齐套·去领料」新卡。
        chainNotice.resolveProductionWorkshopTasks(
                List.of(segmentId), "ROUTE_CONFIRMED");
        if (kitCandidate
                && (ProductionExecutionSegment.STATUS_WAITING.equals(segment.status())
                    || ROUTE_CONTINUOUS.equals(request.route()))
                && segment.autoPromoteWhenReady()) {
            if (promotionWarehouseId == null) {
                throw conflict("执行段缺少有效的确认计划包或发料仓，不能按齐套生产补跑备料提升");
            }
            readiness.promoteAfterRouteConfirmation(segmentId, promotionWarehouseId,segment.startRoute()==null);
        }
        ExecutionSegmentView result = one(planId, segmentId);
        recordEvent(segmentId, ACTION_ROUTE_CONFIRMED, request.idempotencyKey(),
                requestHash, request.expectedVersion(), result.lockVersion());
        return result;
    }

    /**
     * 路线随时可换(ADR-095)：齐套/持续只改开工门，已有部分预留、领料草稿、仓库发料与
     * 直送投入原样保留(改齐套=保留已备物料、继续补齐、全部实领后才开工)；独立分批要
     * 拆出有谱系的子任务，仍要求未动过的任务(fn_can_split_execution_batch)。
     */
    private void validateRouteChoice(LockedSegment segment, String route) {
        // ADR-096：零物料工单同样三条路线都可选——齐套/持续对它只是「随时可开工」的两种
        // 叫法，分批则按数量拆出独立零料子任务(fn_can_split_execution_batch 已放行 READY 零料)。
        if (ROUTE_FULL_KIT.equals(route)) return;
        // Continuous supply changes when materials are issued, not who owns them.
        // Existing draft preparation and purchase pegs remain attached to this task.
        if (ROUTE_CONTINUOUS.equals(route)) return;
        if (ROUTE_BATCH.equals(route) && !Boolean.TRUE.equals(em.createNativeQuery(
                "SELECT fn_can_split_execution_batch(:id)")
                .setParameter("id", segment.id()).getSingleResult())) {
            throw conflict("本任务不满足独立分批条件：分批要拆出独立子任务，须为已安排车间、等待物料且尚未备料、领料或绑定供给的物料分析任务；已备部分物料的任务请选择齐套生产或持续生产");
        }
    }

    /** Explicit route selection precedes every preparation/start action. */
    private void requireRouteForKitAction(LockedSegment segment, String actionLabel) {
        String route = segment.startRoute();
        if (route == null) throw conflict("请先确认生产路线");
        if (ROUTE_BATCH.equals(route)) {
            throw conflict("本工单已确认为「分批生产」路线，请用「分批领料」按批办理，「" + actionLabel + "」不可用");
        }
    }

    /** Independent batches retain their own preview; other active routes share exact-source picking. */
    private void requireRouteForRecheck(LockedSegment segment) {
        String route = segment.startRoute();
        if (route == null) throw conflict("请先确认生产路线");
        if (ROUTE_BATCH.equals(route)) {
            throw conflict("分批生产路线不走齐套核对，请在分批领料核对页查看当前可生产量");
        }
    }

    public static String routeWord(String route) {
        if (ROUTE_BATCH.equals(route)) {
            return "分批生产";
        }
        if (ROUTE_CONTINUOUS.equals(route)) {
            return "持续生产";
        }
        return "齐套生产";
    }

    private static void requireRouteConfirmRequest(SegmentRouteConfirmRequest request) {
        if (request == null
                || request.expectedVersion() == null
                || request.idempotencyKey() == null
                || request.idempotencyKey().isBlank()
                || request.route() == null
                || request.route().isBlank()
                || !List.of(ROUTE_FULL_KIT, ROUTE_BATCH, ROUTE_CONTINUOUS)
                        .contains(request.route())) {
            throw validation("确认生产路线请求缺少版本、幂等键或合法路线");
        }
    }

    private static String hashRouteConfirm(SegmentRouteConfirmRequest request) {
        return PlanningPackageFingerprint.sha256(List.of(
                "ACTION|" + ACTION_ROUTE_CONFIRMED,
                "VERSION|" + request.expectedVersion(),
                "ROUTE|" + request.route()));
    }

    @Transactional
    public ExecutionSegmentView dispatch(
            UUID planId,
            UUID segmentId,
            SegmentTransitionRequest request) {
        tx.bind();
        requireTransitionRequest(request);
        LockedSegment segment = lock(planId, segmentId);
        requireRouteForKitAction(segment, "派工");
        return applyTransition(prepareTransition(
                segment,
                request,
                ACTION_DISPATCH,
                ProductionExecutionSegment.STATUS_READY,
                ProductionExecutionSegment.STATUS_DISPATCHED,
                "production_execution:dispatch"));
    }

    @Transactional
    public ExecutionSegmentView start(
            UUID planId,
            UUID segmentId,
            SegmentTransitionRequest request) {
        tx.bind();
        requireTransitionRequest(request);
        prelockForLineSideIssue(planId, List.of(segmentId));
        LockedSegment segment = lock(planId, segmentId);
        // Saved assignment and confirmed route are reused. START itself verifies
        // real material capacity; reporting never starts a task implicitly.
        requireRouteForKitAction(segment, "开工");
        return applyTransition(prepareTransition(
                segment,
                request,
                ACTION_START,
                java.util.Set.of(
                        ProductionExecutionSegment.STATUS_READY,
                        ProductionExecutionSegment.STATUS_DISPATCHED),
                ProductionExecutionSegment.STATUS_IN_PROGRESS,
                "production_execution:start"));
    }

    /**
     * Starts up to one hundred exact execution segments atomically.
     *
     * <p>Duplicate segment ids with the same command collapse to one item.
     * Ambiguous duplicates fail closed. Every segment row is locked in UUID
     * order before any item is preflighted or mutated, then all items are
     * preflighted before the first status update. The enclosing transaction
     * rolls back every status, event and notification when any write fails.
     */
    @Transactional
    public List<ExecutionSegmentView> batchStart(
            UUID planId, BatchStartRequest request) {
        List<BatchStartRequest.Item> items = batchStartItems(request);
        tx.bind();
        prelockForLineSideIssue(planId, items.stream().map(BatchStartRequest.Item::segmentId).toList());
        List<LockedStartRequest> locked = new ArrayList<>(items.size());
        for (BatchStartRequest.Item item : items) {
            LockedStartRequest lockedRequest = new LockedStartRequest(
                    lock(planId, item.segmentId()),
                    new SegmentTransitionRequest(
                            item.expectedVersion(), item.idempotencyKey()));
            requireRouteForKitAction(lockedRequest.segment(), "开工");
            locked.add(lockedRequest);
        }

        List<PreparedTransition> prepared = new ArrayList<>(locked.size());
        for (LockedStartRequest target : locked) {
            prepared.add(prepareTransition(
                    target.segment(),
                    target.request(),
                    ACTION_START,
                    // 齐套即开工：READY 与已派工 DISPATCHED 均可直接开工。
                    java.util.Set.of(
                            ProductionExecutionSegment.STATUS_READY,
                            ProductionExecutionSegment.STATUS_DISPATCHED),
                    ProductionExecutionSegment.STATUS_IN_PROGRESS,
                    "production_execution:start"));
        }

        List<ExecutionSegmentView> results = new ArrayList<>(prepared.size());
        for (PreparedTransition transition : prepared) {
            results.add(applyTransition(transition));
        }
        return List.copyOf(results);
    }

    private ExecutionSegmentView transition(
            UUID planId,
            UUID segmentId,
            SegmentTransitionRequest request,
            String action,
            String fromStatus,
            String toStatus,
            String operationAuthority) {
        tx.bind();
        requireTransitionRequest(request);
        LockedSegment segment = lock(planId, segmentId);
        return applyTransition(prepareTransition(
                segment,
                request,
                action,
                fromStatus,
                toStatus,
                operationAuthority));
    }

    private PreparedTransition prepareTransition(
            LockedSegment segment,
            SegmentTransitionRequest request,
            String action,
            String fromStatus,
            String toStatus,
            String operationAuthority) {
        return prepareTransition(
                segment, request, action,
                java.util.Set.of(fromStatus), toStatus, operationAuthority);
    }

    private PreparedTransition prepareTransition(
            LockedSegment segment,
            SegmentTransitionRequest request,
            String action,
            java.util.Set<String> allowedFrom,
            String toStatus,
            String operationAuthority) {
        requireSegmentOperationAccess(segment, operationAuthority);
        String requestHash = hashTransition(request, action);
        ExecutionSegmentView replay =
                replay(segment, action, request.idempotencyKey(), requestHash);
        if (replay != null) {
            return new PreparedTransition(
                    segment, request, action, segment.status(), toStatus,
                    requestHash, replay);
        }
        requireVersion(segment, request.expectedVersion());
        requireActivePlan(segment);
        if (!allowedFrom.contains(segment.status())) {
            if (ACTION_START.equals(action) && ProductionExecutionSegment.STATUS_WAITING.equals(segment.status())) {
                throw conflict("当前仍在等待物料，请先按已确认路线备料并完成本次领料后开工");
            }
            throw conflict("执行段状态已经变化，请刷新后重试");
        }
        if (ACTION_DISPATCH.equals(action) || ACTION_START.equals(action)) {
            // 开工沿用计划已保存的车间和负责人；可选计划日期不成为重复填写门槛。
            requireDispatchPreconditions(segment, ACTION_START.equals(action));
        }
        if (ACTION_START.equals(action)) {
            requireMaterialsIssuedForStart(segment);
        }
        return new PreparedTransition(
                segment, request, action, segment.status(), toStatus,
                requestHash, null);
    }

    /** Uses the saved assignment; starting does not require optional schedule dates. */
    private void requireDispatchPreconditions(LockedSegment segment, boolean starting) {
        ExecutionSegmentView current = one(segment.planId(), segment.id());
        // 齐套判定跟着已确认路线走(ADR-095/V628)：持续生产允许部分覆盖，其余路线
        // 要求物料视图逐种齐套——曾按持续生产备过部分料再改齐套的工单也在这里被拦住。
        if (!ROUTE_CONTINUOUS.equals(segment.startRoute()) && !current.materialReady()) {
            throw conflict(starting ? "执行段尚未齐套，不能开工" : "执行段尚未齐套，不能派工");
        }
        assignmentValidator.validate(new ProductionAssignmentValidator.Assignment(
                current.workshopDepartmentId(),
                current.teamDepartmentId(),
                current.responsibleEmployeeId(),
                current.planBeginDate(),
                current.planEndDate()));
        if (current.workshopDepartmentId() == null
                || current.responsibleEmployeeId() == null) {
            throw validation("工单尚未保存完整的生产车间和负责人，请核对计划分配");
        }
        if (!starting && (current.planBeginDate() == null
                || current.planEndDate() == null)) {
            throw validation("派工前必须填写计划开始和完成日期");
        }
    }

    private ExecutionSegmentView applyTransition(PreparedTransition transition) {
        if (transition.replay() != null) return transition.replay();
        LockedSegment segment = transition.segment();
        SegmentTransitionRequest request = transition.request();
        boolean manualReadyStart = ACTION_START.equals(transition.action())
                && ProductionExecutionSegment.STATUS_READY.equals(transition.fromStatus());
        if (manualReadyStart) {
            bindManualStartContext(segment.id(), request.expectedVersion());
        }
        RuntimeException primaryFailure = null;
        try {
            updateStatus(segment.id(), request.expectedVersion(),
                    transition.fromStatus(), transition.toStatus());
            long resultingVersion = request.expectedVersion() + 1;
            recordEvent(segment.id(), transition.action(), request.idempotencyKey(),
                    transition.requestHash(), request.expectedVersion(), resultingVersion);
            if (ACTION_DISPATCH.equals(transition.action())
                    || ACTION_START.equals(transition.action())) {
                chainNotice.notifyExecutionSegmentTransition(
                        segment.id(), ACTION_START.equals(transition.action()));
            }
            if (ACTION_START.equals(transition.action())) {
                // 车间开工 = 「车间任务」行动卡的办结点（2026-09-10）：同段全部
                // 收件人的弹卡按聚合 (PRODUCTION_EXECUTION_SEGMENT, id) 撤回。
                // 报工不办结；完工入库由 ChainNoticeService 完工投递兜底办结。
                chainNotice.resolveProductionWorkshopTasks(
                        List.of(segment.id()), "STARTED");
            }
            return one(segment.planId(), segment.id());
        } catch (RuntimeException failure) {
            primaryFailure = failure;
            throw failure;
        } finally {
            if (manualReadyStart) {
                try {
                    bindManualStartContext(null, null);
                } catch (RuntimeException cleanupFailure) {
                    if (primaryFailure == null) throw cleanupFailure;
                    primaryFailure.addSuppressed(cleanupFailure);
                }
            }
        }
    }

    private void bindManualStartContext(UUID segmentId, Long expectedVersion) {
        em.createNativeQuery("""
                SELECT set_config('app.production_execution_start_segment_id', :segmentId, true),
                       set_config('app.production_execution_start_expected_version', :expectedVersion, true)
                """)
                .setParameter("segmentId", segmentId == null ? "" : segmentId.toString())
                .setParameter("expectedVersion", expectedVersion == null ? "" : expectedVersion.toString())
                .getSingleResult();
    }

    private void updateStatus(
            UUID segmentId,
            long expectedVersion,
            String fromStatus,
            String toStatus) {
        int updated = em.createNativeQuery("""
                        UPDATE production_execution_segments
                        SET status = :toStatus
                        WHERE id = :id
                          AND lock_version = :expectedVersion
                          AND status = :fromStatus
                          AND is_deleted = FALSE
                        """)
                .setParameter("toStatus", toStatus)
                .setParameter("id", segmentId)
                .setParameter("expectedVersion", expectedVersion)
                .setParameter("fromStatus", fromStatus)
                .executeUpdate();
        requireUpdated(updated);
    }

    private LockedSegment lock(UUID planId, UUID segmentId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT s.id, s.plan_id, s.package_id, s.status,
                                       s.lock_version, p.status,
                                       plan.status, plan.is_closed,
                                       plan.is_canceled, plan.is_stopped,
                                       s.product_goods_id, s.workshop_department_id,
                                       s.responsible_employee_id,
                                       s.auto_promote_when_ready,
                                       s.material_requirement_mode,
                                       plan.maker_id, s.source_segment_id,
                                       s.continuous_supply,
                                       s.start_route
                                FROM production_execution_segments s
                                JOIN production_planning_packages p
                                  ON p.id = s.package_id
                                 AND p.is_deleted = FALSE
                                JOIN production_plans plan
                                  ON plan.id = s.plan_id
                                 AND plan.is_deleted = FALSE
                                WHERE s.id = :segmentId
                                  AND s.plan_id = :planId
                                  AND s.is_deleted = FALSE
                                FOR UPDATE OF s
                                """)
                        .setParameter("segmentId", segmentId)
                        .setParameter("planId", planId));
        if (rows.isEmpty()) {
            throw new ApiException(
                    ErrorCode.NOT_FOUND, "执行段不存在或不属于当前生产计划");
        }
        Object[] row = rows.getFirst();
        return new LockedSegment(
                (UUID) row[0],
                (UUID) row[1],
                (UUID) row[2],
                (String) row[3],
                ((Number) row[4]).longValue(),
                (String) row[5],
                row[6] == null ? null : ((Number) row[6]).shortValue(),
                Boolean.TRUE.equals(row[7]),
                Boolean.TRUE.equals(row[8]),
                Boolean.TRUE.equals(row[9]),
                (UUID) row[10],
                (UUID) row[11],
                (UUID) row[12],
                Boolean.TRUE.equals(row[13]),
                (String) row[14],
                (UUID) row[15], (UUID) row[16],
                Boolean.TRUE.equals(row[17]),
                (String) row[18]);
    }

    /**
     * READY only proves complete reservation and DRAW creation. A DEMANDED
     * segment may start only after warehouse issue has fulfilled every exact
     * material demand. ZERO_MATERIAL keeps its separately frozen exception.
     */
    /**
     * 车间动作可能就地出库线边仓领料单时(V595)，先按计划预锁履约足迹：线边仓出库走仓库单据的
     * 审核/出库链，{@code lockProductionDocuments} 要求完整预锁集合已存在；而重核/开工随后就会
     * 进入库存维度锁，那之后再补前缀会被守卫拒绝(「已进入库存锁阶段」)。只在真有线边仓料或
     * 草稿时才付这笔预锁的代价，普通开工/重核不改锁形状。
     */
    private void prelockForLineSideIssue(UUID planId, List<UUID> segmentIds) {
        if (segmentIds.stream().anyMatch(readiness::mayIssueLineSideDraws)) {
            planFootprints.beginPlan(planId, List.of());
        }
    }

    private void requireMaterialsIssuedForStart(LockedSegment segment) {
        assignmentValidator.requireMaterialCustody(segment.id());
        if ("ZERO_MATERIAL".equals(segment.materialRequirementMode())) return;
        if (segment.sourceSegmentId()!=null && !Boolean.TRUE.equals(em.createNativeQuery("SELECT fn_split_batch_prerequisites_issued(:id)")
                .setParameter("id",segment.id()).getSingleResult()))
            throw conflict("前批共享的固定或整包物料尚未实际领齐，不能开工");
        // 线边仓直送料的草稿领料单在开工这一刻就地出库(V595)：系统对账把父件提升为齐套时
        // 没有用户身份可以出库，留下的草稿不该逼车间去申请、逼仓库替车间发线边仓的料。
        readiness.issuePendingLineSideDraws(segment.id());
        // 开工门按路线(ADR-095)：持续生产=各项必需料共同支持正产出；齐套(含曾按持续
        // 生产备过部分料的工单)=每种物料实领到位。continuous_supply 只表示增量备料。
        if (ROUTE_CONTINUOUS.equals(segment.startRoute())) {
            BigDecimal capacity = decimal(em.createNativeQuery(
                    "SELECT fn_execution_material_output_capacity(:id, TRUE)")
                    .setParameter("id", segment.id()).getSingleResult());
            if (capacity.signum() <= 0) {
                throw conflict("已投入的各项开工物料尚不能支持生产，请继续领料或等待车间直送；全部必需物料须共同支持正产出");
            }
            return;
        }
        List<Object[]> demands = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, status, direct_supply
                                FROM production_material_demands
                                WHERE execution_segment_id = :segmentId
                                  AND is_deleted = FALSE
                                  AND status NOT IN ('RELEASED', 'REVERSED')
                                ORDER BY id
                                FOR UPDATE
                                """)
                        .setParameter("segmentId", segment.id()));
        if (demands.isEmpty()) {
            if (segment.sourceSegmentId()!=null && Boolean.TRUE.equals(em.createNativeQuery("SELECT fn_split_batch_empty_issued(:id)")
                    .setParameter("id",segment.id()).getSingleResult())) return;
            throw conflict("执行段缺少正式物料需求，不能按零物料任务开工");
        }
        long pending = demands.stream()
                .filter(row -> !"FULFILLED".equals(row[1]))
                .count();
        if (pending > 0) {
            throw conflict("仓库尚未完成全部生产领料，不能开工(待发料 "
                    + pending + " 项)");
        }
    }

    private ExecutionSegmentView replay(
            LockedSegment segment,
            String action,
            String idempotencyKey,
            String requestHash) {
        List<Object[]> events = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT request_hash, resulting_version
                                FROM production_execution_segment_events
                                WHERE execution_segment_id = :segmentId
                                  AND action = :action
                                  AND idempotency_key = :key
                                FOR UPDATE
                                """)
                        .setParameter("segmentId", segment.id())
                        .setParameter("action", action)
                        .setParameter("key", idempotencyKey.strip()));
        if (events.isEmpty()) return null;
        if (!Objects.equals(events.getFirst()[0], requestHash)) {
            throw conflict("相同幂等键对应不同的执行段请求");
        }
        return one(segment.planId(), segment.id());
    }

    private void recordEvent(
            UUID segmentId,
            String action,
            String idempotencyKey,
            String requestHash,
            long expectedVersion,
            long resultingVersion) {
        em.createNativeQuery("""
                        INSERT INTO production_execution_segment_events(
                            id, execution_segment_id, action, idempotency_key,
                            request_hash, expected_version, resulting_version,
                            created_at, created_by
                        ) VALUES (
                            gen_random_uuid(), :segmentId, :action, :key,
                            :requestHash, :expectedVersion, :resultingVersion,
                            now(), :actorId
                        )
                        """)
                .setParameter("segmentId", segmentId)
                .setParameter("action", action)
                .setParameter("key", idempotencyKey.strip())
                .setParameter("requestHash", requestHash)
                .setParameter("expectedVersion", expectedVersion)
                .setParameter("resultingVersion", resultingVersion)
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
    }

    private List<ExecutionSegmentView> rows(UUID planId, UUID segmentId) {
        String segmentFilter =
                segmentId == null ? "" : " AND s.id = :segmentId\n";
        var query = em.createNativeQuery("""
                        SELECT s.id, s.package_id, s.plan_id,
                               s.source_plan_item_id, s.segment_no,
                               s.segment_code, s.product_goods_id,
                               s.product_code, s.product_name,
                               s.product_color_id, s.product_unit_id,
                               s.planned_qty,
                               COALESCE(progress.effective_reported_qty, 0),
                               GREATEST(
                                   s.planned_qty
                                   - COALESCE(progress.gross_reported_qty, 0), 0)
                                   + COALESCE(recovery.available_qty, 0),
                               s.status, s.workshop_department_id,
                               s.workshop_name, s.team_department_id,
                               s.team_name, s.responsible_employee_id,
                               s.responsible_employee_name,
                               s.plan_begin_date, s.plan_end_date,
                               s.material_kind_count,
                               s.shortage_kind_count,
                               (s.material_ready OR fn_split_batch_empty_issued(s.id)),
                               base.auto_promote_when_ready,
                               issue.demand_count,
                               issue.fulfilled_count,
                               CASE
                                 WHEN base.material_requirement_mode = 'ZERO_MATERIAL' OR fn_split_batch_empty_issued(s.id)
                                   THEN TRUE
                                 WHEN issue.demand_count > 0
                                  AND issue.fulfilled_count = issue.demand_count
                                   THEN TRUE
                                 ELSE FALSE
                               END AS material_issued,
                               COALESCE(fqc.pending_qty, 0),
                               COALESCE(fqc.passed_qty, 0),
                                COALESCE(fqc.failed_qty, 0),
                                COALESCE(finished.pending_qty, 0),
                                COALESCE(finished.inbound_qty, 0),
                                COALESCE(finished.rejected_qty, 0),
                                GREATEST(
                                   s.planned_qty
                                   - COALESCE(progress.gross_reported_qty, 0), 0),
                               COALESCE(recovery.available_qty, 0),
                               COALESCE(recovery.rework_available_qty, 0),
                               COALESCE(recovery.replacement_available_qty, 0),
                               COALESCE(recovery.replacement_ready_qty, 0),
                               s.lock_version,
                               base.material_requirement_mode = 'ZERO_MATERIAL'
                                   AS zero_material,
                               draw_request.fully_requested,
                               (base.status IN ('READY','DISPATCHED','IN_PROGRESS')
                                 AND plan.status=1 AND NOT plan.is_deleted
                                 AND NOT plan.is_closed AND NOT plan.is_canceled AND NOT plan.is_stopped
                                 AND package.status='CONFIRMED' AND NOT package.is_deleted
                                 AND base.material_requirement_mode<>'ZERO_MATERIAL'
                                 AND base.start_route IS NOT NULL AND base.start_route<>'BATCH'
                                 AND draw_request.has_unrequested),
                               fn_can_split_execution_batch(s.id),
                               base.source_segment_id,
                               EXISTS(SELECT 1 FROM production_execution_segment_splits split WHERE split.source_segment_id=s.id),
                               plan.maker_id,
                               base.continuous_supply,
                               base.start_route,
                               (base.status IN ('READY','DISPATCHED')
                                 AND base.start_route IS NOT NULL AND base.start_route<>'BATCH'
                                 AND plan.status=1 AND NOT plan.is_closed AND NOT plan.is_canceled AND NOT plan.is_stopped
                                 AND package.status='CONFIRMED' AND NOT package.is_deleted
                                 AND base.workshop_department_id IS NOT NULL AND base.responsible_employee_id IS NOT NULL
                                 AND fn_execution_start_material_ready(base.id))
                        FROM v_production_execution_segments s
                        JOIN production_execution_segments base
                          ON base.id = s.id
                        JOIN production_plans plan ON plan.id=s.plan_id
                        JOIN production_planning_packages package ON package.id=s.package_id
                        LEFT JOIN LATERAL (
                            SELECT COALESCE(bool_and(fn_production_draw_fully_requested(document.id)),FALSE) AS fully_requested,
                                   COALESCE(bool_or(NOT fn_production_draw_fully_requested(document.id)),FALSE) AS has_unrequested
                            FROM production_planning_package_documents mapping
                            JOIN stock_documents document ON document.id=mapping.document_id
                            WHERE mapping.execution_segment_id=s.id AND mapping.document_type='DRAW'
                              AND NOT document.is_deleted AND document.status IN (0,1)
                        ) draw_request ON TRUE
                        LEFT JOIN LATERAL (
                            SELECT SUM(item.qty) AS gross_reported_qty,
                                   SUM(item.qty)
                                   - COALESCE(SUM((
                                       SELECT SUM(adjustment.adjusted_qty)
                                       FROM production_fqc_contribution_adjustments
                                            adjustment
                                       WHERE adjustment.source_report_item_id =
                                             item.id
                                   )), 0) AS effective_reported_qty
                            FROM production_daily_report_items item
                            JOIN production_daily_reports report
                              ON report.id = item.report_id
                            WHERE item.execution_segment_id = s.id
                              AND report.is_deleted = FALSE
                              AND report.status = 1
                        ) progress ON TRUE
                        LEFT JOIN LATERAL (
                            SELECT COUNT(*)::integer AS demand_count,
                                   COUNT(*) FILTER (
                                       WHERE demand.status = 'FULFILLED'
                                   )::integer AS fulfilled_count
                            FROM production_material_demands demand
                            WHERE demand.execution_segment_id = s.id
                              AND demand.is_deleted = FALSE
                              AND demand.status NOT IN ('RELEASED', 'REVERSED')
                        ) issue ON TRUE
                        LEFT JOIN LATERAL (
                            SELECT COALESCE(SUM(GREATEST(
                                       inspection.reported_qty
                                       - inspection.passed_qty
                                       - inspection.failed_qty, 0)), 0)
                                       AS pending_qty,
                                   COALESCE(SUM(inspection.passed_qty), 0)
                                       AS passed_qty,
                                   COALESCE(SUM(inspection.failed_qty), 0)
                                       AS failed_qty
                            FROM production_fqc_inspections inspection
                            WHERE inspection.execution_segment_id = s.id
                              AND inspection.status <> 'CANCELLED'
                        ) fqc ON TRUE
                        LEFT JOIN LATERAL (
                            SELECT COALESCE(SUM(item.qty) FILTER (
                                       WHERE document.status = 0), 0)
                                       AS pending_qty,
                                   COALESCE(SUM(item.qty) FILTER (
                                        WHERE document.status = 1), 0)
                                        AS inbound_qty,
                                   COALESCE(SUM(confirmation_item.residual_qty)
                                       FILTER (
                                           WHERE confirmation.decision =
                                                 'REJECTED'
                                             AND rejected_residual.status = 0
                                             AND rejected_residual.is_deleted =
                                                 FALSE), 0)
                                       AS rejected_qty
                             FROM stock_document_items item
                             JOIN stock_documents document
                              ON document.id = item.doc_id
                              AND document.doc_type = 'FINISHED_IN'
                              AND document.is_deleted = FALSE
                            LEFT JOIN production_finished_in_confirmations
                                 confirmation
                              ON confirmation.stock_document_id = document.id
                             AND confirmation.decision = 'REJECTED'
                            LEFT JOIN production_finished_in_confirmation_items
                                 confirmation_item
                              ON confirmation_item.confirmation_id =
                                 confirmation.id
                             AND confirmation_item.stock_document_item_id =
                                 item.id
                            LEFT JOIN stock_documents rejected_residual
                              ON rejected_residual.id =
                                 confirmation.residual_stock_document_id
                             WHERE item.execution_segment_id = s.id
                              AND item.is_deleted = FALSE
                        ) finished ON TRUE
                        LEFT JOIN LATERAL (
                            SELECT COALESCE(SUM(GREATEST(
                                       balance.available_qty, 0)), 0)
                                       AS available_qty,
                                   COALESCE(SUM(GREATEST(
                                       balance.available_qty, 0)) FILTER (
                                       WHERE recovery_auth.disposition_code =
                                             'REWORK'), 0)
                                       AS rework_available_qty,
                                   COALESCE(SUM(GREATEST(
                                       balance.available_qty, 0)) FILTER (
                                       WHERE recovery_auth.disposition_code
                                             IN ('SCRAP', 'REJECT')), 0)
                                       AS replacement_available_qty,
                                   COALESCE(SUM(GREATEST(
                                       balance.available_qty, 0)) FILTER (
                                       WHERE recovery_auth.disposition_code
                                             IN ('SCRAP', 'REJECT')
                                         AND EXISTS (
                                             SELECT 1
                                             FROM v_production_fqc_replenishment_material_ready
                                                  ready
                                             WHERE ready.authorization_id =
                                                   recovery_auth.id
                                         )), 0)
                                       AS replacement_ready_qty
                            FROM v_production_fqc_recovery_balance balance
                            JOIN production_fqc_recovery_authorizations
                                 recovery_auth
                              ON recovery_auth.id = balance.authorization_id
                            WHERE balance.execution_segment_id = s.id
                              AND balance.cancelled = FALSE
                              AND balance.available_qty > 0
                        ) recovery ON TRUE
                        WHERE s.plan_id = :planId
                        """ + segmentFilter + """
                        ORDER BY s.segment_no, s.id
                        """)
                .setParameter("planId", planId);
        if (segmentId != null) {
            query.setParameter("segmentId", segmentId);
        }
        boolean hasDrawAuthority=workshopMembership.isActiveOperator()
                && access.hasAuthority("production_execution:view")
                && access.hasAuthority("production_execution:start");
        UUID employeeId=currentUser.employeeId().orElse(null);
        Map<String,Boolean> workshopAccess=new LinkedHashMap<>();
        List<Object[]> resultRows=NativeQueryResults.objectArrayRows(query);
        UUID owner=resultRows.isEmpty()?null:(UUID)resultRows.getFirst()[48];
        boolean planWritable=hasDrawAuthority && access.canRead(owner)
                && access.canWrite(owner,"production_execution:start");
        return resultRows.stream()
                .map(row->{
                    boolean allowed=hasDrawAuthority && (planWritable
                            || workshopAccess.computeIfAbsent(row[15]+"|"+row[19],ignored->
                            workshopMembership.isWorkshopMember((UUID)row[15],(UUID)row[19],employeeId)));
                    return view(row,allowed);
                })
                .toList();
    }

    private ExecutionSegmentView one(UUID planId, UUID segmentId) {
        List<ExecutionSegmentView> result = rows(planId, segmentId);
        if (result.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "执行段不存在");
        }
        return result.getFirst();
    }

    private UUID requirePlanOwner(UUID planId) {
        List<?> owners = em.createNativeQuery("""
                        SELECT maker_id
                        FROM production_plans
                        WHERE id = :id AND is_deleted = FALSE
                        """)
                .setParameter("id", planId)
                .getResultList();
        if (owners.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "生产计划不存在");
        }
        return (UUID) owners.getFirst();
    }

    private void requirePlanReadable(UUID planId) {
        access.requireReadable(
                requirePlanOwner(planId), "生产计划不存在");
    }

    private void requirePlanOperationAccess(
            UUID planId, String operationAuthority) {
        requireOperationAuthority(operationAuthority);
        access.requireScopedOperationWritable(
                requirePlanOwner(planId),
                "无权操作此生产计划的执行任务",
                operationAuthority);
    }

    private void requireSegmentOperationAccess(
            LockedSegment segment, String operationAuthority) {
        requireOperationAuthority(operationAuthority);
        // 车间口径（2026-09-11）：属于本段车间（或就是段负责人）且持动作权限的人可以操作
        // 自己的工单，不再要求能读计划制单人——V543 收回 production_plan:view:all 后，
        // 车间账号读不到计划归属，旧口径会把「开工 / 确认用料」一并锁死。
        // 读侧（我的车间任务）本就按车间归属收敛，写侧与之同口径。
        if (access.hasAuthority(operationAuthority)
                && workshopMembership.isWorkshopMember(
                        segment.workshopDepartmentId(),
                        segment.responsibleEmployeeId(),
                        currentUser.employeeId().orElse(null))) {
            return;
        }
        access.requireScopedOperationWritable(
                segment.planMakerId(),
                "无权操作此生产计划的执行任务",
                operationAuthority);
    }

    /** An owner/data-scope grant chooses objects; it never grants the command itself. */
    private void requireOperationAuthority(String operationAuthority) {
        if (!access.hasAuthority(operationAuthority)
                || ("production_execution:start".equals(operationAuthority)
                    && !access.hasAuthority("production_execution:view"))) {
            throw new ApiException(ErrorCode.FORBIDDEN, "缺少执行任务操作权限");
        }
        workshopMembership.requireActiveOperator();
    }

    private static void requireAssignmentRequest(
            SegmentAssignmentRequest request) {
        if (request == null
                || request.expectedVersion() == null
                || request.idempotencyKey() == null
                || request.idempotencyKey().isBlank()) {
            throw validation("执行段分配缺少版本或幂等键");
        }
    }

    private static void requireTransitionRequest(
            SegmentTransitionRequest request) {
        if (request == null
                || request.expectedVersion() == null
                || request.idempotencyKey() == null
                || request.idempotencyKey().isBlank()) {
            throw validation("执行段状态请求缺少版本或幂等键");
        }
    }

    private static List<BatchStartRequest.Item> batchStartItems(
            BatchStartRequest request) {
        if (request == null || request.items() == null
                || request.items().isEmpty() || request.items().size() > 100) {
            throw validation("批量开工必须包含 1-100 个执行段");
        }
        Map<UUID, BatchStartRequest.Item> unique = new LinkedHashMap<>();
        for (BatchStartRequest.Item item : request.items()) {
            if (item == null || item.segmentId() == null
                    || item.expectedVersion() == null
                    || item.idempotencyKey() == null
                    || item.idempotencyKey().isBlank()) {
                throw validation("批量开工项缺少执行段、版本或幂等键");
            }
            String key = item.idempotencyKey().strip();
            if (key.length() < 8 || key.length() > 128) {
                throw validation("批量开工幂等键长度必须为 8-128 个字符");
            }
            BatchStartRequest.Item normalized = new BatchStartRequest.Item(
                    item.segmentId(), item.expectedVersion(), key);
            BatchStartRequest.Item previous = unique.putIfAbsent(
                    normalized.segmentId(), normalized);
            if (previous != null
                    && (!Objects.equals(
                            previous.expectedVersion(), normalized.expectedVersion())
                    || !Objects.equals(
                            previous.idempotencyKey(), normalized.idempotencyKey()))) {
                throw conflict("同一执行段的重复批量开工请求不一致");
            }
        }
        return unique.values().stream()
                .sorted(Comparator.comparing(BatchStartRequest.Item::segmentId))
                .toList();
    }

    private static void requireVersion(
            LockedSegment segment, long expectedVersion) {
        if (segment.lockVersion() != expectedVersion) {
            throw conflict("执行段已被其他用户修改，请刷新后重试");
        }
    }

    private static void requireActivePlan(LockedSegment segment) {
        if (!"CONFIRMED".equals(segment.packageStatus())
                || segment.planStatus() == null
                || segment.planStatus() != 1
                || segment.planClosed()
                || segment.planCanceled()
                || segment.planStopped()) {
            throw conflict("生产计划或计划包当前不可执行");
        }
    }

    private static void requireUpdated(int updated) {
        if (updated != 1) {
            throw conflict("执行段已被其他用户修改，请刷新后重试");
        }
    }

    private static String hashAssignment(SegmentAssignmentRequest request) {
        return PlanningPackageFingerprint.sha256(List.of(
                "VERSION|" + request.expectedVersion(),
                "WORKSHOP|" + Objects.toString(
                        request.workshopDepartmentId(), ""),
                "TEAM|" + Objects.toString(request.teamDepartmentId(), ""),
                "OWNER|" + Objects.toString(
                        request.responsibleEmployeeId(), ""),
                "BEGIN|" + Objects.toString(request.planBeginDate(), ""),
                "END|" + Objects.toString(request.planEndDate(), "")));
    }

    private static String hashTransition(
            SegmentTransitionRequest request, String action) {
        return PlanningPackageFingerprint.sha256(List.of(
                "ACTION|" + action,
                "VERSION|" + request.expectedVersion()));
    }

    private static ExecutionSegmentView view(Object[] row,boolean canOperateDraw) {
        return new ExecutionSegmentView(
                (UUID) row[0],
                (UUID) row[1],
                (UUID) row[2],
                (UUID) row[3],
                ((Number) row[4]).intValue(),
                (String) row[5],
                (UUID) row[6],
                (String) row[7],
                (String) row[8],
                (UUID) row[9],
                (UUID) row[10],
                decimal(row[11]),
                decimal(row[12]),
                decimal(row[13]),
                (String) row[14],
                Boolean.TRUE.equals(row[26]),
                (UUID) row[15],
                (String) row[16],
                (UUID) row[17],
                (String) row[18],
                (UUID) row[19],
                (String) row[20],
                date(row[21]),
                date(row[22]),
                ((Number) row[23]).intValue(),
                ((Number) row[24]).intValue(),
                Boolean.TRUE.equals(row[25]),
                ((Number) row[27]).intValue(),
                ((Number) row[28]).intValue(),
                Boolean.TRUE.equals(row[29]),
                decimal(row[30]),
                decimal(row[31]),
                decimal(row[32]),
                decimal(row[33]),
                decimal(row[34]),
                decimal(row[35]),
                decimal(row[36]),
                decimal(row[37]),
                decimal(row[38]),
                decimal(row[39]),
                decimal(row[40]),
                ((Number) row[41]).longValue(),
                Boolean.TRUE.equals(row[42]),
                Boolean.TRUE.equals(row[43]),
                canOperateDraw && Boolean.TRUE.equals(row[44]),
                canOperateDraw && Boolean.TRUE.equals(row[45]),
                (UUID)row[46],
                Boolean.TRUE.equals(row[47]),
                Boolean.TRUE.equals(row[49]),
                (String) row[50],
                canOperateDraw && Boolean.TRUE.equals(row[51]));
    }

    private static BigDecimal decimal(Object value) {
        return value == null
                ? BigDecimal.ZERO
                : new BigDecimal(value.toString());
    }

    private static LocalDate date(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate localDate) return localDate;
        return ((java.sql.Date) value).toLocalDate();
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private record LockedSegment(
            UUID id,
            UUID planId,
            UUID packageId,
            String status,
            long lockVersion,
            String packageStatus,
            Short planStatus,
            boolean planClosed,
            boolean planCanceled,
            boolean planStopped,
            UUID productGoodsId,
            UUID workshopDepartmentId,
            UUID responsibleEmployeeId,
            boolean autoPromoteWhenReady,
            String materialRequirementMode,
            UUID planMakerId,
            UUID sourceSegmentId,
            boolean continuousSupply,
            String startRoute) {
    }

    private record LockedStartRequest(
            LockedSegment segment, SegmentTransitionRequest request) {
    }

    private record PreparedTransition(
            LockedSegment segment,
            SegmentTransitionRequest request,
            String action,
            String fromStatus,
            String toStatus,
            String requestHash,
            ExecutionSegmentView replay) {
    }
}
