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
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
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

    private final EntityManager em;
    private final ProductionGoodsWorkshopPreferenceService workshopPreferences;
    private final ProductionExecutionReadinessService readiness;
    private final ProductionAssignmentValidator assignmentValidator;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ChainNoticeService chainNotice;
    private final ProductionDocumentAccessPolicy access;

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
        if (request.workshopDepartmentId() != null
                && !Objects.equals(segment.workshopDepartmentId(),
                        request.workshopDepartmentId())) {
            workshopPreferences.learnSelection(
                    segment.productGoodsId(),
                    request.workshopDepartmentId(),
                    currentUser.requireEmployeeId());
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

    @Transactional
    public ExecutionSegmentView dispatch(
            UUID planId,
            UUID segmentId,
            SegmentTransitionRequest request) {
        return transition(
                planId,
                segmentId,
                request,
                ACTION_DISPATCH,
                ProductionExecutionSegment.STATUS_READY,
                ProductionExecutionSegment.STATUS_DISPATCHED,
                "production_execution:dispatch");
    }

    @Transactional
    public ExecutionSegmentView start(
            UUID planId,
            UUID segmentId,
            SegmentTransitionRequest request) {
        return transition(
                planId,
                segmentId,
                request,
                ACTION_START,
                ProductionExecutionSegment.STATUS_DISPATCHED,
                ProductionExecutionSegment.STATUS_IN_PROGRESS,
                "production_execution:start");
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
        requireSegmentOperationAccess(segment, operationAuthority);
        String requestHash = hashTransition(request, action);
        ExecutionSegmentView replay =
                replay(segment, action, request.idempotencyKey(), requestHash);
        if (replay != null) return replay;
        requireVersion(segment, request.expectedVersion());
        requireActivePlan(segment);
        if (!fromStatus.equals(segment.status())) {
            throw conflict("执行段状态已经变化，请刷新后重试");
        }
        if (ACTION_DISPATCH.equals(action)) {
            ExecutionSegmentView current = one(planId, segmentId);
            if (!current.materialReady()) {
                throw conflict("执行段尚未齐套，不能派工");
            }
            assignmentValidator.validate(new ProductionAssignmentValidator.Assignment(
                    current.workshopDepartmentId(),
                    current.teamDepartmentId(),
                    current.responsibleEmployeeId(),
                    current.planBeginDate(),
                    current.planEndDate()));
            if (current.workshopDepartmentId() == null
                    || current.responsibleEmployeeId() == null
                    || current.planBeginDate() == null
                    || current.planEndDate() == null) {
                throw validation("派工前必须完整分配车间、负责人和计划日期");
            }
        } else if (ACTION_START.equals(action)) {
            requireMaterialsIssuedForStart(segment);
        }
        updateStatus(segmentId, request.expectedVersion(), fromStatus, toStatus);
        long resultingVersion = request.expectedVersion() + 1;
        recordEvent(
                segmentId,
                action,
                request.idempotencyKey(),
                requestHash,
                request.expectedVersion(),
                resultingVersion);
        if (ACTION_DISPATCH.equals(action) || ACTION_START.equals(action)) {
            chainNotice.notifyExecutionSegmentTransition(
                    segmentId, ACTION_START.equals(action));
        }
        return one(planId, segmentId);
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
            throw conflict("已派工或已开工执行段不能直接取消/红冲");
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
                                       s.auto_promote_when_ready,
                                       s.material_requirement_mode,
                                       plan.maker_id
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
                Boolean.TRUE.equals(row[12]),
                (String) row[13],
                (UUID) row[14]);
    }

    /**
     * READY only proves complete reservation and DRAW creation. A DEMANDED
     * segment may start only after warehouse issue has fulfilled every exact
     * material demand. ZERO_MATERIAL keeps its separately frozen exception.
     */
    private void requireMaterialsIssuedForStart(LockedSegment segment) {
        if ("ZERO_MATERIAL".equals(segment.materialRequirementMode())) return;
        List<Object[]> demands = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, status
                                FROM production_material_demands
                                WHERE execution_segment_id = :segmentId
                                  AND is_deleted = FALSE
                                  AND status NOT IN ('RELEASED', 'REVERSED')
                                ORDER BY id
                                FOR UPDATE
                                """)
                        .setParameter("segmentId", segment.id()));
        if (demands.isEmpty()) {
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
                               s.material_ready,
                               base.auto_promote_when_ready,
                               issue.demand_count,
                               issue.fulfilled_count,
                               CASE
                                 WHEN base.material_requirement_mode = 'ZERO_MATERIAL'
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
                               s.lock_version
                        FROM v_production_execution_segments s
                        JOIN production_execution_segments base
                          ON base.id = s.id
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
        return NativeQueryResults.objectArrayRows(query).stream()
                .map(ProductionExecutionSegmentService::view)
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

    private static ExecutionSegmentView view(Object[] row) {
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
                ((Number) row[41]).longValue());
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
            boolean autoPromoteWhenReady,
            String materialRequirementMode,
            UUID planMakerId) {
    }
}
