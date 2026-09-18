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
    private static final String ACTION_CANCEL = "CANCEL";
    private static final String ACTION_REVERSE = "REVERSE";
    private static final String ACTION_RELEASE_DEFER = "RELEASE_DEFER";
    private static final String ACTION_RECHECK_MATERIAL = "RECHECK_MATERIAL";
    private static final String ACTION_START_CONTINUOUS = "START_CONTINUOUS";
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
        LockedSegment segment = lock(planId, segmentId);
        requireSegmentOperationAccess(
                segment, "production_execution:assign");
        String requestHash = hashAssignment(request);
        ExecutionSegmentView replay =
                replay(segment, ACTION_ASSIGNMENT, request.idempotencyKey(), requestHash);
        if (replay != null) return replay;
        requireVersion(segment, request.expectedVersion());
        requireActivePlan(segment);
        if (!List.of(
                        ProductionExecutionSegment.STATUS_READY,
                        ProductionExecutionSegment.STATUS_WAITING)
                .contains(segment.status())) {
            throw conflict("仅待料或齐套未派工的执行段可以调整分配");
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

    /** Explicit repair of a waiting task using current physical inventory facts. */
    @Transactional
    public ExecutionSegmentView recheckMaterial(
            UUID planId, UUID segmentId, SegmentTransitionRequest request) {
        tx.bind();
        requireTransitionRequest(request);
        prelockForLineSideIssue(planId, List.of(segmentId));
        UUID warehouseId = readiness.lockManualReleaseDimensions(planId, segmentId);
        LockedSegment segment = lock(planId, segmentId);
        requireSegmentOperationAccess(segment, "production_execution:start");
        String requestHash = hashTransition(request, ACTION_RECHECK_MATERIAL);
        ExecutionSegmentView replay = replay(segment, ACTION_RECHECK_MATERIAL,
                request.idempotencyKey(), requestHash);
        if (replay != null) return replay;
        requireVersion(segment, request.expectedVersion());
        requireActivePlan(segment);
        if (!ProductionExecutionSegment.STATUS_WAITING.equals(segment.status())
                || !segment.autoPromoteWhenReady()) {
            throw conflict("仅自动待料中的执行段可以重新检查物料，人工暂缓须先解除暂缓");
        }
        if (warehouseId == null) throw conflict("执行段缺少有效的确认计划包或发料仓");
        requireRouteForRecheck(segment);
        readiness.promoteAfterMaterialRecheck(segmentId, warehouseId);
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
        boolean kitCandidate = ROUTE_FULL_KIT.equals(request.route());
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
        if (!firstConfirmation) {
            if (!ProductionExecutionSegment.STATUS_WAITING.equals(segment.status())) {
                throw conflict("开工路线只能在等待物料阶段确认或更改");
            }
            if (!Objects.equals(segment.startRoute(), request.route())
                    && !Boolean.TRUE.equals(em.createNativeQuery(
                            "SELECT fn_can_change_execution_route(:id)")
                            .setParameter("id", segmentId).getSingleResult())) {
                throw conflict("工单已产生领料单、报工或预留，开工路线不能更改");
            }
        }
        validateRouteChoice(segment, request.route());
        int updated = em.createNativeQuery("""
                        UPDATE production_execution_segments
                        SET start_route = :route,
                            route_confirmed_at = now()
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
        if (kitCandidate
                && ProductionExecutionSegment.STATUS_WAITING.equals(segment.status())
                && segment.autoPromoteWhenReady()) {
            if (promotionWarehouseId == null) {
                throw conflict("执行段缺少有效的确认计划包或发料仓，不能按齐套生产补跑备料提升");
            }
            readiness.promoteAfterRouteConfirmation(segmentId, promotionWarehouseId);
        }
        ExecutionSegmentView result = one(planId, segmentId);
        recordEvent(segmentId, ACTION_ROUTE_CONFIRMED, request.idempotencyKey(),
                requestHash, request.expectedVersion(), result.lockVersion());
        return result;
    }

    /** 路线本身合不合这张工单：非默认路线只允许在「还能改主意」的时候选——
     * 对抗复审 M1：带供给钉/已动过的工单选了分批/持续会把全部出口封死成永久 WAITING
     * (分批的拆批、持续的开工、改回路线三者都要求未动过)。 */
    private void validateRouteChoice(LockedSegment segment, String route) {
        if (ROUTE_FULL_KIT.equals(route)) {
            return;
        }
        if (!Boolean.TRUE.equals(em.createNativeQuery(
                        "SELECT fn_can_change_execution_route(:id)")
                .setParameter("id", segment.id()).getSingleResult())) {
            throw validation("本工单已有在途供给或领料/预留记录，只能按齐套生产路线办理；"
                    + "如需分批生产或持续生产，请在计划下达后、采购/委外供给绑定前确认路线");
        }
        if (ROUTE_BATCH.equals(route)) {
            if (ProductionExecutionSegment.MATERIAL_REQUIREMENT_MODE_ZERO.equals(
                    segment.materialRequirementMode())) {
                throw validation("无物料子件的工单用不上分批生产，请选择齐套生产");
            }
            return;
        }
        Number eligible = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_material_demands demand
                        WHERE demand.execution_segment_id = :segmentId
                          AND demand.is_deleted = FALSE
                          AND demand.status NOT IN ('RELEASED', 'REVERSED')
                          AND fn_demand_direct_supply_eligible(demand.id)
                        """)
                .setParameter("segmentId", segment.id())
                .getSingleResult();
        if (eligible.longValue() == 0) {
            throw validation("本工单没有可由本车间直送供给的子件，持续生产路线不适用；请选择齐套或分批生产");
        }
    }

    /**
     * 开工路线门控(V599)：齐套开工/批量开工/领料申请共用——未确认路线一律拒绝；
     * 已确认「分批生产」的工单不能走齐套链；「持续生产」路线的工单须先按持续生产开工
     * (混合链直送冻结、仓库料领齐后再点普通开工)。
     */
    private void requireRouteForKitAction(LockedSegment segment, String actionLabel) {
        String route = segment.startRoute();
        if (route == null) {
            throw conflict("请先确认生产路线——「" + actionLabel + "」需要工单先选定齐套/分批/持续生产之一");
        }
        if (ROUTE_BATCH.equals(route)) {
            throw conflict("本工单已确认为「分批生产」路线，请用「分批领料」按批办理，「" + actionLabel + "」不可用");
        }
        if (ROUTE_CONTINUOUS.equals(route) && !segment.continuousSupply()) {
            throw conflict("本工单已确认为「持续生产」路线，请先用「部分开工 · 持续生产」开工，仓库物料领齐后再点开工");
        }
    }

    private void requireExactRoute(
            LockedSegment segment, String requiredRoute, String actionLabel) {
        String route = segment.startRoute();
        if (route == null) {
            throw conflict("请先确认生产路线——「" + actionLabel + "」需要工单先选定齐套/分批/持续生产之一");
        }
        if (!requiredRoute.equals(route)) {
            throw conflict("本工单已确认为「" + routeWord(route) + "」路线，「" + actionLabel
                    + "」不可用；如需更改，请在等待物料且未领料时重新确认生产路线");
        }
    }

    /** 重新核对备料=齐套提升：分批/未开工的持续生产路线各自有专属视图，不走这里。 */
    private void requireRouteForRecheck(LockedSegment segment) {
        String route = segment.startRoute();
        if (route == null) {
            throw conflict("请先确认生产路线，再核对备料");
        }
        if (ROUTE_BATCH.equals(route)) {
            throw conflict("分批生产路线不走齐套核对，请在分批领料核对页查看当前可生产量");
        }
        if (ROUTE_CONTINUOUS.equals(route) && !segment.continuousSupply()) {
            throw conflict("持续生产工单请先按「部分开工 · 持续生产」开工，再核对仓库物料");
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
        // 防御性对称(V599)：派工也是开工侧动作，未确认路线的段不该被派工(正常路径中
        // READY+未确认不可达——提升被路线门抑制，零料段落生 READY 但开工有同样的门)。
        if (segment.startRoute() == null) {
            throw conflict("请先确认生产路线——派工与开工一样需要工单先选定齐套/分批/持续生产之一");
        }
        // 复用上面已锁的段：不再走 transition() 二次加锁(少一次锁查询，也让
        // 单测的 lock+replay 两条桩序列保持稳定)。
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
        // 2026-09-06 车间任务页改版：物料齐套（READY）工单可直接开工——与报工
        // 自动开工（AUTO_START_ON_REPORT，READY/DISPATCHED → IN_PROGRESS）同口径；
        // READY 段在 prepareTransition 里补派工前置校验（齐套 + 完整分配）。
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

    @Transactional
    public ExecutionSegmentView cancel(
            UUID planId,
            UUID segmentId,
            SegmentTransitionRequest request) {
        return terminal(
                planId,
                segmentId,
                request,
                ACTION_CANCEL,
                "CANCELLED",
                ProductionExecutionSegment.STATUS_CANCELLED,
                "production_execution:cancel");
    }

    @Transactional
    public ExecutionSegmentView reverse(
            UUID planId,
            UUID segmentId,
            SegmentTransitionRequest request) {
        return terminal(
                planId,
                segmentId,
                request,
                ACTION_REVERSE,
                "REVERSED",
                ProductionExecutionSegment.STATUS_REVERSED,
                "production_execution:reverse");
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
            throw conflict("执行段状态已经变化，请刷新后重试");
        }
        if (ACTION_DISPATCH.equals(action)
                || (ACTION_START.equals(action)
                        && ProductionExecutionSegment.STATUS_READY.equals(
                                segment.status()))) {
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
        if (!current.materialReady()) {
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

    private ExecutionSegmentView terminal(
            UUID planId,
            UUID segmentId,
            SegmentTransitionRequest request,
            String action,
            String requiredPackageStatus,
            String terminalStatus,
            String operationAuthority) {
        tx.bind();
        requireTransitionRequest(request);
        LockedSegment segment = lock(planId, segmentId);
        requireSegmentOperationAccess(segment, operationAuthority);
        String requestHash = hashTransition(request, action);
        ExecutionSegmentView replay =
                replay(segment, action, request.idempotencyKey(), requestHash);
        if (replay != null) return replay;
        requireVersion(segment, request.expectedVersion());
        if ("CONFIRMED".equals(segment.packageStatus())) {
            throw conflict(
                    "单段取消/红冲会破坏计划行数量守恒；请使用计划包整包"
                            + ("CANCELLED".equals(requiredPackageStatus) ? "取消" : "红冲")
                            + "入口");
        }
        if (!requiredPackageStatus.equals(segment.packageStatus())) {
            throw conflict("计划包状态与执行段操作不一致");
        }
        if (!List.of(
                        ProductionExecutionSegment.STATUS_READY,
                        ProductionExecutionSegment.STATUS_WAITING)
                .contains(segment.status())) {
            throw conflict("历史已确认或已进入生产的执行工单不能直接取消/红冲");
        }
        if (hasExecutionActivity(segmentId)) {
            throw conflict("执行段已有发料、报工或入库记录，必须先完成精确反向处理");
        }
        updateStatus(
                segmentId,
                request.expectedVersion(),
                segment.status(),
                terminalStatus);
        long resultingVersion = request.expectedVersion() + 1;
        recordEvent(
                segmentId,
                action,
                request.idempotencyKey(),
                requestHash,
                request.expectedVersion(),
                resultingVersion);
        chainNotice.resolveProductionWorkshopTasks(
                List.of(segmentId), terminalStatus);
        return one(planId, segmentId);
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
        if ("ZERO_MATERIAL".equals(segment.materialRequirementMode())) return;
        if (segment.sourceSegmentId()!=null && !Boolean.TRUE.equals(em.createNativeQuery("SELECT fn_split_batch_prerequisites_issued(:id)")
                .setParameter("id",segment.id()).getSingleResult()))
            throw conflict("前批共享的固定或整包物料尚未实际领齐，不能开工");
        // 线边仓直送料的草稿领料单在开工这一刻就地出库(V595)：系统对账把父件提升为齐套时
        // 没有用户身份可以出库，留下的草稿不该逼车间去申请、逼仓库替车间发线边仓的料。
        readiness.issuePendingLineSideDraws(segment.id());
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
        // 持续生产(V595)：同车间直送供给的子件允许部分到料甚至尚未到料，不挡开工；
        // 仓库供给的物料仍必须全部实际发出。
        long pending = demands.stream()
                .filter(row -> !"FULFILLED".equals(row[1]))
                .filter(row -> !(segment.continuousSupply() && Boolean.TRUE.equals(row[2])))
                .count();
        if (pending > 0) {
            throw conflict("仓库尚未完成全部生产领料，不能开工(待发料 "
                    + pending + " 项)");
        }
    }

    /**
     * 「部分开工 · 持续生产」(V595 / ADR-089)。用户口径：「物料只准备了 20% 也可以先开工，
     * 后面物料源源不断来了不用再开工，来物料了就继续做，数量最后交付的时候再算，不是再开个生产单。」
     *
     * <p>同一张工单、开一次工：
     * <ol>
     *   <li>把可由同车间直送供给的子件需求冻结为 direct_supply，段标记 continuous_supply；</li>
     *   <li>仓库供给的需求照旧整批齐套(缺什么直接报出来)，形成仓库领料单等车间申请、仓库发料；
     *       直送需求只把线边仓已到的量预留出库，一件没到也不拦；</li>
     *   <li>没有任何仓库需求时直接开工(IN_PROGRESS)；否则停在「齐套 · 去领料」，仓库料领齐后再点开工。</li>
     * </ol>
     * 之后每一笔同车间直送审核都会自动补投给这张工单，报工量以已到料折算的上限为准。
     */
    @Transactional
    public ExecutionSegmentView startContinuousSupply(
            UUID planId,
            UUID segmentId,
            SegmentTransitionRequest request) {
        tx.bind();
        requireTransitionRequest(request);
        prelockForLineSideIssue(planId, List.of(segmentId));
        LockedSegment segment = lock(planId, segmentId);
        requireSegmentOperationAccess(segment, "production_execution:start");
        String requestHash = hashTransition(request, ACTION_START_CONTINUOUS);
        ExecutionSegmentView replay =
                replay(segment, ACTION_START_CONTINUOUS, request.idempotencyKey(), requestHash);
        if (replay != null) return replay;
        requireVersion(segment, request.expectedVersion());
        requireActivePlan(segment);
        requireExactRoute(segment, ROUTE_CONTINUOUS, "部分开工 · 持续生产");
        if (!ProductionExecutionSegment.STATUS_WAITING.equals(segment.status())) {
            throw conflict("只有等待物料的工单可以按「部分开工 · 持续生产」开工，请刷新后重试");
        }
        if (!Boolean.TRUE.equals(em.createNativeQuery(
                        "SELECT fn_can_start_continuous_supply(:id)")
                .setParameter("id", segmentId).getSingleResult())) {
            throw conflict(continuousStartBlockedReason(segmentId));
        }
        // 与开工/派工同一把尺子：车间与负责人必须已保存(持续生产同样要有人负责收料与报工)。
        ExecutionSegmentView current = one(planId, segmentId);
        if (current.workshopDepartmentId() == null || current.responsibleEmployeeId() == null) {
            throw validation("工单尚未保存完整的生产车间和负责人，请核对计划分配");
        }
        int marked = em.createNativeQuery("""
                        UPDATE production_material_demands
                        SET direct_supply = TRUE,
                            lock_version = lock_version + 1,
                            updated_at = now()
                        WHERE execution_segment_id = :segmentId
                          AND is_deleted = FALSE
                          AND status NOT IN ('RELEASED', 'REVERSED')
                          AND fn_demand_direct_supply_eligible(id)
                        """)
                .setParameter("segmentId", segmentId)
                .executeUpdate();
        if (marked == 0) {
            throw conflict("本工单没有可由本车间直送供给的子件，请按普通流程领料开工");
        }
        int flagged = em.createNativeQuery("""
                        UPDATE production_execution_segments
                        SET continuous_supply = TRUE
                        WHERE id = :id
                          AND lock_version = :expectedVersion
                          AND status = 'WAITING'
                          AND is_deleted = FALSE
                        """)
                .setParameter("id", segmentId)
                .setParameter("expectedVersion", request.expectedVersion())
                .executeUpdate();
        requireUpdated(flagged);
        UUID warehouseId = readiness.lockManualReleaseDimensions(planId, segmentId);
        if (warehouseId == null) {
            throw conflict("工单所属计划包缺少主仓，不能持续生产开工");
        }
        readiness.promoteContinuousSupply(segmentId, warehouseId);
        long version = currentVersion(segmentId);
        recordEvent(segmentId, ACTION_START_CONTINUOUS, request.idempotencyKey(),
                requestHash, request.expectedVersion(), version);
        Number warehouseDemands = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_material_demands
                        WHERE execution_segment_id = :segmentId
                          AND is_deleted = FALSE
                          AND status NOT IN ('RELEASED', 'REVERSED')
                          AND direct_supply = FALSE
                        """)
                .setParameter("segmentId", segmentId)
                .getSingleResult();
        if (warehouseDemands.longValue() == 0) {
            // 全部子件都由同车间直送：没有任何仓库领料要等，就地开工。
            LockedSegment ready = lock(planId, segmentId);
            return applyTransition(prepareTransition(
                    ready,
                    new SegmentTransitionRequest(version, request.idempotencyKey() + ":START"),
                    ACTION_START,
                    java.util.Set.of(ProductionExecutionSegment.STATUS_READY),
                    ProductionExecutionSegment.STATUS_IN_PROGRESS,
                    "production_execution:start"));
        }
        return one(planId, segmentId);
    }

    /**
     * 「部分开工 · 持续生产」被拒的原因(V595)。最常见的一种单独说清：**某些直送子件一件都还没
     * 送到**。用户口径(2026-09-17)：「持续开工的前提是已经有一部分的料，子层级每一种料都有一部分
     * 了，至少能开始生产了。」空料架开工等于零物料在产，随后还会去领仓库的料，账就乱了。
     */
    private String continuousStartBlockedReason(UUID segmentId) {
        List<String> missing = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT goods.name
                               || COALESCE(' ' || goods.code, '')
                               || COALESCE('(' || color.name || ')', '')
                        FROM production_material_demands demand
                        JOIN goods ON goods.id = demand.goods_id
                        LEFT JOIN colors color ON color.id = demand.color_id
                        WHERE demand.execution_segment_id = :segmentId
                          AND demand.is_deleted = FALSE
                          AND demand.status NOT IN ('RELEASED', 'REVERSED')
                          AND fn_demand_direct_supply_eligible(demand.id)
                          AND NOT fn_demand_has_direct_supply_on_hand(demand.id)
                        ORDER BY 1
                        """)
                .setParameter("segmentId", segmentId), String.class);
        if (missing.isEmpty()) {
            return "本工单不能按持续生产开工：需要至少一个子件由本车间直送供给，"
                    + "且尚未领料、分批或预留；请用「分批领料」或等待物料齐套";
        }
        String names = String.join("、", missing.size() > 3 ? missing.subList(0, 3) : missing);
        return "「部分开工 · 持续生产」要求每种同车间直送的子件都已经送到一部分，"
                + "以下子件一件都还没到：" + names
                + (missing.size() > 3 ? " 等 " + missing.size() + " 种" : "")
                + "；请先在本车间把这些子件报工并选「转送车间」送过来，再按持续生产开工";
    }

    private long currentVersion(UUID segmentId) {
        return ((Number) em.createNativeQuery(
                        "SELECT lock_version FROM production_execution_segments WHERE id = :id")
                .setParameter("id", segmentId)
                .getSingleResult()).longValue();
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

    private boolean hasExecutionActivity(UUID segmentId) {
        Number count = (Number) em.createNativeQuery("""
                        SELECT
                            (SELECT COUNT(*)
                             FROM production_material_stock_postings posting
                             JOIN production_material_demands demand
                               ON demand.id = posting.demand_id
                             WHERE demand.execution_segment_id = :segmentId)
                          + (SELECT COUNT(*)
                             FROM production_daily_report_items item
                             JOIN production_daily_reports report
                               ON report.id = item.report_id
                             WHERE item.execution_segment_id = :segmentId
                               AND report.is_deleted = FALSE
                               AND report.status <> -1)
                          + (SELECT COUNT(*)
                             FROM stock_document_items item
                             JOIN stock_documents document
                               ON document.id = item.doc_id
                             WHERE item.execution_segment_id = :segmentId
                               AND item.bill_type = 'FINISHED_IN'
                               AND item.is_deleted = FALSE
                               AND document.is_deleted = FALSE
                               AND document.status <> -1)
                        """)
                .setParameter("segmentId", segmentId)
                .getSingleResult();
        return count.longValue() > 0;
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
                               (base.status IN ('READY','DISPATCHED')
                                 AND plan.status=1 AND NOT plan.is_deleted
                                 AND NOT plan.is_closed AND NOT plan.is_canceled AND NOT plan.is_stopped
                                 AND package.status='CONFIRMED' AND NOT package.is_deleted
                                 AND base.material_requirement_mode<>'ZERO_MATERIAL'
                                 AND issue.fulfilled_count<issue.demand_count
                                 AND draw_request.has_unrequested),
                               fn_can_split_execution_batch(s.id),
                               base.source_segment_id,
                               EXISTS(SELECT 1 FROM production_execution_segment_splits split WHERE split.source_segment_id=s.id),
                               plan.maker_id,
                               base.continuous_supply,
                               fn_can_start_continuous_supply(s.id),
                               base.start_route
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
        boolean hasDrawAuthority=access.hasAuthority("production_execution:view")
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
        access.requireScopedOperationWritable(
                requirePlanOwner(planId),
                "无权操作此生产计划的执行任务",
                operationAuthority);
    }

    private void requireSegmentOperationAccess(
            LockedSegment segment, String operationAuthority) {
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
                canOperateDraw && Boolean.TRUE.equals(row[50]),
                (String) row[51]);
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
