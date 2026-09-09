package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.ProductionSubcontractRequestPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * V458 委外件「先自制、后通知委外」账本（preplan_subcontract_make_tasks）。
 *
 * <p>有子层级的委外件在物料分析下达时只创建前置自制任务，不生成委外申请。
 * 自制成品实收入库后：产出量进入账本并以 SUBCONTRACT_PREPARE_TASK 专属预留
 * 扣住公共可用库存；满批（produced ≥ required）自动生成委外申请，未满批可由
 * 计划部按「已产未通知量」手动分批通知。委外申请生成后走既有
 * 分解 → 订货 → 财务批准（PREPARED_OUTBOUND）→ 出仓 → 回厂 → IQC 链。</p>
 */
@Service
@RequiredArgsConstructor
public class SubcontractMakeTaskService {

    private final EntityManager em;
    private final MaterialAnalysisService analyses;
    private final ProductionDocumentAccessPolicy access;
    // 走六边形端口而非委外门面类：production 不得直接依赖 subcontract 特性包。
    private final ProductionSubcontractRequestPort subcontractRequests;
    private final ChainNoticeService chainNotice;
    private final SecurityContextCurrentUser currentUser;

    // ==================== 读模型 ====================

    /** 委外前置自制任务进度行（委外准备中心 + 物料分析页共用投影）。 */
    public record TaskView(
            UUID taskId,
            UUID analysisId,
            String analysisStatus,
            String itemSourceRef,
            UUID goodsId, String goodsCode, String goodsName,
            UUID colorId, String colorName,
            UUID unitId, String unitName,
            String warehouseName,
            BigDecimal requiredQty,
            BigDecimal producedQty,
            BigDecimal notifiedQty,
            BigDecimal availableQty,
            BigDecimal plannedQty,
            LocalDate needDate,
            String status,
            String workshopStatus,
            List<String> allowedActions,
            java.time.Instant updatedAt,
            UUID preparationItemId) {
    }

    public record TaskPageRequest(
            int page, int size, String status, String keyword, UUID analysisId, UUID taskId) {
        public TaskPageRequest(int page, int size, String status, String keyword, UUID analysisId) {
            this(page, size, status, keyword, analysisId, null);
        }
    }

    @Transactional(readOnly = true)
    public TaskView task(UUID taskId) {
        List<TaskView> items = tasks(new TaskPageRequest(1, 1, null, null, null, taskId)).getItems();
        if (items.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "委外前置生产任务不存在或不可访问");
        return items.getFirst();
    }

    @Transactional(readOnly = true)
    public PageResponse<TaskView> tasks(TaskPageRequest request) {
        int page = Math.max(request.page(), 1);
        int size = Math.min(Math.max(request.size(), 1), 100);
        StringBuilder where = new StringBuilder("""
                WHERE task.status IN ('ACTIVE','CANCELLED')
                """);
        // The subcontract queue is a shared dispatch pool, like its application
        // list. Planning-only readers remain inside the production owner scope.
        var actorScope = access.scope();
        var readScope = access.nativeReadScope("analysis.maker_id", "visibleAnalysisOwners", actorScope);
        if (!access.hasAuthority("subcontract_application:view")) {
            where.append(" AND (").append(readScope.predicate()).append(")");
        }
        boolean canNotify = access.hasAuthority("production_material_analysis:view")
                && access.hasAuthority("production_material_analysis:notify");
        if (request.taskId() != null) where.append(" AND task.id = :taskId");
        if (request.analysisId() != null) {
            where.append(" AND task.analysis_id = :analysisId");
        }
        if (request.status() != null && !request.status().isBlank()) {
            where.append(" AND task.status = :statusFilter");
        }
        if (request.keyword() != null && !request.keyword().isBlank()) {
            where.append("""
                 AND (goods.code ILIKE :keyword OR goods.name ILIKE :keyword
                      OR item.source_ref ILIKE :keyword)
                """);
        }
        String baseFrom = """
                FROM preplan_subcontract_make_tasks task
                JOIN goods ON goods.id = task.goods_id
                LEFT JOIN colors ON colors.id = task.color_id
                LEFT JOIN units ON units.id = task.unit_id
                LEFT JOIN warehouses warehouse ON warehouse.id = task.warehouse_id
                LEFT JOIN production_material_analysis_items item
                  ON item.id = task.preparation_item_id
                LEFT JOIN production_material_analyses analysis
                  ON analysis.id = task.analysis_id
                """;
        var countQuery = em.createNativeQuery(
                "SELECT COUNT(*) " + baseFrom + where);
        // 2026-09-05 委外同构直下：委外部从下达一刻起就要能看到车间进度。
        // 车间进度取委托行（preparation_item）名下计划段的状态聚合
        // （production_execution_segments.plan_id → production_plans.material_analysis_item_id）；
        // 仅列表查询挂 LATERAL（每页 20 行），计数查询不挂，避免大表全量展开。
        String listFrom = baseFrom + """
                LEFT JOIN LATERAL (
                    SELECT COUNT(*) AS total,
                           COUNT(*) FILTER (WHERE seg.status = 'WAITING') AS waiting,
                           COUNT(*) FILTER (WHERE seg.status IN
                               ('READY','DISPATCHED','IN_PROGRESS','COMPLETED')) AS working
                    FROM production_execution_segments seg
                    JOIN production_plans p
                      ON p.id = seg.plan_id
                     AND p.material_analysis_item_id = task.preparation_item_id
                     AND p.is_deleted = FALSE
                     AND p.is_canceled = FALSE
                    WHERE seg.is_deleted = FALSE
                      AND seg.status NOT IN ('CANCELLED','REVERSED')
                ) workshop ON TRUE
                """;
        var listQuery = em.createNativeQuery("""
                SELECT task.id, task.analysis_id, analysis.status,
                       item.source_ref,
                       task.goods_id, goods.code, goods.name,
                       task.color_id, colors.name,
                       task.unit_id, units.name,
                       warehouse.name,
                       task.required_qty, task.produced_qty, task.notified_qty,
                       LEAST(task.required_qty, task.produced_qty) - task.notified_qty,
                       COALESCE((
                           SELECT SUM(analysis_link_link.submitted_qty)
                           FROM production_material_analysis_plan_links analysis_link_link
                           WHERE analysis_link_link.analysis_id = task.analysis_id
                             AND analysis_link_link.analysis_item_id =
                                 task.preparation_item_id
                             AND analysis_link_link.allocation_status IN (
                                 'SUBMITTED','APPROVED')
                       ), 0),
                       item.delivery_date,
                       task.status, task.updated_at,
                       task.preparation_item_id,
                       COALESCE(workshop.total, 0),
                       COALESCE(workshop.waiting, 0),
                       COALESCE(workshop.working, 0), analysis.maker_id
                """ + listFrom + where
                + " ORDER BY task.updated_at DESC NULLS LAST, task.id");
        if (!access.hasAuthority("subcontract_application:view")) {
            readScope.bind(countQuery);
            readScope.bind(listQuery);
        }
        if (request.analysisId() != null) {
            countQuery.setParameter("analysisId", request.analysisId());
            listQuery.setParameter("analysisId", request.analysisId());
        }
        if (request.taskId() != null) {
            countQuery.setParameter("taskId", request.taskId());
            listQuery.setParameter("taskId", request.taskId());
        }
        if (request.status() != null && !request.status().isBlank()) {
            countQuery.setParameter("statusFilter", request.status());
            listQuery.setParameter("statusFilter", request.status());
        }
        if (request.keyword() != null && !request.keyword().isBlank()) {
            for (var query : List.of(countQuery, listQuery)) {
                query.setParameter("keyword", "%" + request.keyword().strip() + "%");
            }
        }
        long total = ((Number) countQuery.getSingleResult()).longValue();
        @SuppressWarnings("unchecked")
        List<Object[]> rows = listQuery
                .setFirstResult((page - 1) * size)
                .setMaxResults(size)
                .getResultList();
        List<TaskView> content = rows.stream().map(row -> new TaskView(
                (UUID) row[0], (UUID) row[1], Objects.toString(row[2], ""),
                Objects.toString(row[3], ""),
                (UUID) row[4], Objects.toString(row[5], ""), Objects.toString(row[6], ""),
                (UUID) row[7], Objects.toString(row[8], ""),
                (UUID) row[9], Objects.toString(row[10], ""),
                Objects.toString(row[11], ""),
                decimal(row[12]), decimal(row[13]), decimal(row[14]), decimal(row[15]),
                decimal(row[16]),
                row[17] == null ? null
                        : com.uten.imp.common.util.NativeValueConverters
                                .toLocalDate(row[17]),
                Objects.toString(row[18], ""),
                workshopStatus(decimal(row[12]), decimal(row[13]), decimal(row[14]),
                        ((Number) row[21]).longValue(), ((Number) row[22]).longValue(),
                        ((Number) row[23]).longValue(), Objects.toString(row[18], "")),
                canNotify && access.canWrite((UUID) row[24], actorScope)
                        ? allowedActions(decimal(row[15]), Objects.toString(row[18], ""))
                        : List.of(),
                row[19] == null ? null : toInstant(row[19]),
                (UUID) row[20])).toList();
        return new PageResponse<>(content, page, size, total,
                (int) Math.ceil((double) total / size));
    }

    /**
     * 车间进度口径（委外部视角，2026-09-05 委外=自制同构直下）：
     * 已全额通知委外 → 已完工入库待通知 → 车间生产中（含派工/开工/完工收尾段）
     * → 车间正在等物料（全部执行段处于待料 WAITING）→ 正在通知车间生产
     * （刚下达，尚未形成执行段）。CANCELLED 透传。
     */
    private static String workshopStatus(BigDecimal required, BigDecimal produced,
            BigDecimal notified, long total, long waiting, long working, String status) {
        if ("CANCELLED".equals(status)) return "CANCELLED";
        if (notified.signum() > 0 && notified.compareTo(required) >= 0) {
            return "FULLY_NOTIFIED";
        }
        if (produced.signum() > 0) return "PRODUCED";
        if (working > 0) return "IN_PRODUCTION";
        if (total > 0 && waiting >= total) return "WAITING_MATERIALS";
        return "NOTIFYING_WORKSHOP";
    }

    private static List<String> allowedActions(BigDecimal available, String status) {
        if ("ACTIVE".equals(status) && available.signum() > 0) {
            return List.of("NOTIFY_SUBCONTRACT");
        }
        return List.of();
    }

    // ==================== 分批通知 ====================

    public record NotifyRequest(BigDecimal qty, String idempotencyKey) {
    }

    public record NotifyResult(
            UUID taskId, UUID applicationId, String applicationBillNo,
            BigDecimal notifiedQty, BigDecimal availableQty) {
    }

    /**
     * 手动分批通知委外：按可通知量生成只读委外申请并通知委外部。
     * 幂等键命中时重放既有批次结果。
     */
    @Transactional
    public NotifyResult notifyBatch(UUID taskId, NotifyRequest request) {
        if (request.idempotencyKey() == null
                || request.idempotencyKey().strip().length() < 8
                || request.idempotencyKey().strip().length() > 128) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "幂等键长度必须为 8-128 字符");
        }
        String idempotencyKey = request.idempotencyKey().strip();
        if (request.qty() == null || request.qty().signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "分批通知数量必须大于零");
        }
        BigDecimal qty = request.qty().setScale(4, java.math.RoundingMode.CEILING);
        // Match analysis commands' header -> task lock order. Recheck receipts only
        // after the task lock so concurrent identical commands replay one batch.
        MaterialAnalysisService.AnalysisHeader header = lockTaskAnalysis(taskId);
        access.requireWritable(header.makerId(),
                "只能通知本人负责的物料分析委外任务", access.scope());
        LockedTask task = lockTask(taskId);
        List<Object[]> replay = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT batch.application_id, batch.application_item_id,
                               batch.notify_qty, application.bill_no, reversal.id
                        FROM preplan_subcontract_make_task_batches batch
                        JOIN subcontract_applications application
                          ON application.id = batch.application_id
                        LEFT JOIN preplan_subcontract_make_batch_reversals reversal
                          ON reversal.batch_id = batch.id
                        WHERE batch.task_id = :taskId
                          AND batch.idempotency_key = :idempotencyKey
                        """).setParameter("taskId", taskId)
                        .setParameter("idempotencyKey", idempotencyKey));
        if (!replay.isEmpty()) {
            Object[] row = replay.getFirst();
            if (row[4] != null) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "该批通知已撤回，重新通知请使用新的操作请求");
            }
            if (qty.compareTo(decimal(row[2])) != 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "同一幂等键不能用于不同的分批通知数量");
            }
            return replayResult(taskId, (UUID) row[0],
                    Objects.toString(row[3]), decimal(row[2]));
        }
        BigDecimal available = task.availableQty();
        if (qty.compareTo(available) > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "可通知量仅 " + available.stripTrailingZeros().toPlainString()
                            + "（已产未通知），请刷新后重新确认");
        }
        CreatedBatch batch = createApplicationBatch(
                task, qty, idempotencyKey, currentUser.requireEmployeeId(),
                currentUser.requireId());
        return replayResult(taskId, batch.applicationId(),
                batch.billNo(), qty);
    }

    private MaterialAnalysisService.AnalysisHeader lockTaskAnalysis(UUID taskId) {
        List<UUID> analysisIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT analysis_id FROM preplan_subcontract_make_tasks WHERE id = :id
                """).setParameter("id", taskId), UUID.class);
        if (analysisIds.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "委外前置自制任务不存在");
        }
        return analyses.lockHeader(analysisIds.getFirst());
    }

    private NotifyResult replayResult(
            UUID taskId, UUID applicationId, String billNo, BigDecimal notified) {
        BigDecimal available = decimal(em.createNativeQuery("""
                SELECT LEAST(required_qty, produced_qty) - notified_qty
                FROM preplan_subcontract_make_tasks WHERE id = :id
                """).setParameter("id", taskId).getSingleResult());
        return new NotifyResult(taskId, applicationId, billNo, notified, available);
    }

    private record CreatedBatch(
            UUID batchId, UUID applicationId, String billNo) {
    }

    /** Called by the authorized analysis cancellation after its generated application is reversed. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void reverseNotificationBatchesForApplication(UUID applicationId, String reason) {
        em.flush();
        List<Object[]> batches = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT batch.id, batch.task_id, batch.notify_qty
                FROM preplan_subcontract_make_task_batches batch
                JOIN preplan_subcontract_make_tasks task ON task.id=batch.task_id
                WHERE batch.application_id=:applicationId
                  AND NOT EXISTS (SELECT 1 FROM preplan_subcontract_make_batch_reversals reversal
                                  WHERE reversal.batch_id=batch.id)
                ORDER BY task.id,batch.id
                FOR UPDATE OF task,batch
                """).setParameter("applicationId",applicationId));
        if (batches.isEmpty()) return;
        boolean activeOrders = Boolean.TRUE.equals(em.createNativeQuery("""
                SELECT EXISTS (
                    SELECT 1 FROM subcontract_order_item_sources source
                    JOIN subcontract_application_items application_item ON application_item.id=source.application_item_id
                    JOIN subcontract_order_items item ON item.id=source.order_item_id
                    JOIN subcontract_orders orders ON orders.id=item.order_id
                    WHERE application_item.application_id=:applicationId
                      AND orders.is_deleted=FALSE AND orders.status<>-1)
                """).setParameter("applicationId",applicationId).getSingleResult());
        if (activeOrders) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该通知仍有关联委外订单，请先删除草稿或完整反向订货、出仓与回厂单据");
        }
        UUID actorId = currentUser.requireId();
        for (Object[] batch : batches) {
            int inserted = em.createNativeQuery("""
                    INSERT INTO preplan_subcontract_make_batch_reversals
                        (batch_id,task_id,qty,reason,created_by)
                    VALUES(:batchId,:taskId,:qty,:reason,:actorId)
                    ON CONFLICT(batch_id) DO NOTHING
                    """).setParameter("batchId",batch[0]).setParameter("taskId",batch[1])
                    .setParameter("qty",batch[2]).setParameter("reason",reason.strip())
                    .setParameter("actorId",actorId).executeUpdate();
            if (inserted==0) continue;
            int updated = em.createNativeQuery("""
                    UPDATE preplan_subcontract_make_tasks
                    SET notified_qty=notified_qty-:qty,version=version+1,updated_at=now(),updated_by=:actorId
                    WHERE id=:id AND status='ACTIVE' AND notified_qty>=:qty
                    """).setParameter("qty",batch[2]).setParameter("id",batch[1])
                    .setParameter("actorId",actorId).executeUpdate();
            if (updated!=1) throw new ApiException(ErrorCode.CONFLICT,"委外通知冲销数量已变化，请刷新后重试");
        }
    }

    /** 建申请、分配、批次及账本；调用方已锁分析和任务，人工入口已校验对象权限。 */
    private CreatedBatch createApplicationBatch(
            LockedTask task, BigDecimal qty, String idempotencyKey,
            UUID employeeId, UUID actorUserId) {
        // 每批通知建立独立的 SUBCONTRACT action 锚定申请：任务 action 的
        // (action_id, analysis_material_id) 唯一 allocation 已在任务外部化时占用，
        // 复用同一 action 会撞唯一键；新 action 以 CREATED+external 直接 INSERT
        // （不经 UPDATE 外部化握手，V250/V460 守卫语义不变）。
        List<Object[]> sourceAction = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT source.action_group_key, latest.generation,
                               source.request_hash, latest.id
                        FROM preplan_supply_actions source
                        JOIN LATERAL (
                            SELECT id, generation FROM preplan_supply_actions candidate
                            WHERE candidate.analysis_id = source.analysis_id
                              AND candidate.action_group_key = source.action_group_key
                              AND candidate.route = 'SUBCONTRACT'
                            ORDER BY candidate.generation DESC
                            LIMIT 1
                        ) latest ON TRUE
                        WHERE source.id = :id AND source.analysis_id = :analysisId
                        """).setParameter("id", task.supplyActionId())
                        .setParameter("analysisId", task.analysisId()));
        if (sourceAction.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "委外前置自制任务的备料动作不存在，请刷新后重试");
        }
        Object[] source = sourceAction.getFirst();
        String actionGroupKey = Objects.toString(source[0], "");
        int generation = ((Number) source[1]).intValue() + 1;
        UUID notifyActionId = UUID.randomUUID();
        String businessKey = PlanningPackageFingerprint.sha256(List.of(
                "PREPLAN-SUPPLY-ACTION-V1", task.analysisId().toString(),
                actionGroupKey, "SUBCONTRACT", Integer.toString(generation)));
        String actionIdempotency = "NOTIFY-" + PlanningPackageFingerprint.sha256(
                List.of(task.taskId().toString(), idempotencyKey));
        ProductionSubcontractRequestPort.DraftResult result =
                subcontractRequests.createProductionDraft(
                        task.sourceLabel(), task.analysisId(), task.needDate(),
                        task.warehouseId(),
                        List.of(new ProductionSubcontractRequestPort.DraftLine(
                                task.taskId(), task.goodsId(), task.colorId(),
                                task.unitId(), qty, task.needDate(),
                                "委外件前置自制已入库，分批通知委外")),
                        employeeId, employeeId);
        ProductionSubcontractRequestPort.DraftLineResult line = result.lines().getFirst();
        em.createNativeQuery("""
                INSERT INTO preplan_supply_actions (
                    id, analysis_id, warehouse_id, goods_id, color_id, unit_id,
                    need_date, route, requested_qty, status,
                    idempotency_key, action_group_key, request_business_key,
                    generation, predecessor_action_id, request_hash,
                    external_document_type, external_document_id,
                    external_document_no, created_by)
                VALUES (
                    :id, :analysisId, :warehouseId, :goodsId, :colorId, :unitId,
                    :needDate, 'SUBCONTRACT', :qty, 'CREATED',
                    :idempotencyKey, :actionGroupKey, :businessKey,
                    :generation, :predecessorId, :requestHash,
                    'SUBCONTRACT_APPLICATION', :documentId,
                    :documentNo, :actorId)
                """)
                .setParameter("id", notifyActionId)
                .setParameter("analysisId", task.analysisId())
                .setParameter("warehouseId", task.warehouseId())
                .setParameter("goodsId", task.goodsId())
                .setParameter("colorId", task.colorId())
                .setParameter("unitId", task.unitId())
                .setParameter("needDate", task.needDate())
                .setParameter("qty", qty)
                .setParameter("idempotencyKey", actionIdempotency)
                .setParameter("actionGroupKey", actionGroupKey)
                .setParameter("businessKey", businessKey)
                .setParameter("generation", generation)
                .setParameter("predecessorId", source[3])
                .setParameter("requestHash", Objects.toString(source[2], ""))
                .setParameter("documentId", result.applicationId())
                .setParameter("documentNo", result.billNo())
                .setParameter("actorId", actorUserId)
                .executeUpdate();
        UUID allocationId = UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO preplan_supply_action_allocations (
                    id, analysis_id, action_id, analysis_material_id,
                    allocated_qty, external_item_id, created_by)
                VALUES (
                    :id, :analysisId, :actionId, :materialId,
                    :qty, :externalItemId, :actorId)
                """)
                .setParameter("id", allocationId)
                .setParameter("analysisId", task.analysisId())
                .setParameter("actionId", notifyActionId)
                .setParameter("materialId", task.analysisMaterialId())
                .setParameter("qty", qty)
                .setParameter("externalItemId", line.applicationItemId())
                .setParameter("actorId", actorUserId)
                .executeUpdate();
        UUID batchId = UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO preplan_subcontract_make_task_batches (
                    id, task_id, application_id, application_item_id,
                    allocation_id, notify_qty, idempotency_key, created_by)
                VALUES (
                    :id, :taskId, :applicationId, :applicationItemId,
                    :allocationId, :qty, :idempotencyKey, :actorId)
                """)
                .setParameter("id", batchId)
                .setParameter("taskId", task.taskId())
                .setParameter("applicationId", result.applicationId())
                .setParameter("applicationItemId", line.applicationItemId())
                .setParameter("allocationId", allocationId)
                .setParameter("qty", qty)
                .setParameter("idempotencyKey", idempotencyKey)
                .setParameter("actorId", actorUserId)
                .executeUpdate();
        int updated = em.createNativeQuery("""
                UPDATE preplan_subcontract_make_tasks
                SET notified_qty = notified_qty + :qty,
                    version = version + 1,
                    updated_by = :actorId, updated_at = now()
                WHERE id = :id
                  AND status = 'ACTIVE'
                  AND notified_qty + :qty <= LEAST(required_qty, produced_qty)
                """)
                .setParameter("qty", qty)
                .setParameter("actorId", actorUserId)
                .setParameter("id", task.taskId())
                .executeUpdate();
        if (updated != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "委外前置自制任务可通知量已被其他操作使用，请刷新后重试");
        }
        chainNotice.notifySubcontractMakeNotified(batchId);
        return new CreatedBatch(batchId, result.applicationId(), result.billNo());
    }

    private LockedTask lockTask(UUID taskId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT task.id, task.analysis_id, task.analysis_material_id,
                       task.supply_action_id, task.preparation_item_id,
                       task.goods_id, task.color_id, task.unit_id,
                       task.warehouse_id, task.required_qty, task.produced_qty,
                       task.notified_qty, task.status,
                       item.delivery_date, analysis.analyzed_at
                FROM preplan_subcontract_make_tasks task
                LEFT JOIN production_material_analysis_items item
                  ON item.id = task.preparation_item_id
                LEFT JOIN production_material_analyses analysis
                  ON analysis.id = task.analysis_id
                WHERE task.id = :id
                FOR UPDATE OF task
                """).setParameter("id", taskId));
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "委外前置自制任务不存在");
        }
        Object[] row = rows.getFirst();
        // SELECT 顺序：row[12] 是任务状态，row[13] 才是需求日期。这里若取
        // row[13]，所有有交期的 ACTIVE 任务都会被误判成已取消，分批通知恒失败。
        if (!"ACTIVE".equals(Objects.toString(row[12], ""))) {
            throw new ApiException(ErrorCode.CONFLICT, "委外前置自制任务已取消");
        }
        BigDecimal available = decimal(row[9]).min(decimal(row[10]))
                .subtract(decimal(row[11])).max(BigDecimal.ZERO);
        String sourceLabel = "计划前物料分析 " + (row[14] == null ? ""
                : toInstant(row[14]).atZone(com.uten.imp.common.time.BusinessTime.ZONE)
                        .toLocalDate());
        return new LockedTask((UUID) row[0], (UUID) row[1], (UUID) row[2],
                (UUID) row[3], (UUID) row[4], (UUID) row[5], (UUID) row[6],
                (UUID) row[7], (UUID) row[8], decimal(row[9]), decimal(row[10]),
                decimal(row[11]), available,
                row[13] == null ? null
                        : com.uten.imp.common.util.NativeValueConverters
                                .toLocalDate(row[13]),
                sourceLabel);
    }

    private record LockedTask(
            UUID taskId, UUID analysisId, UUID analysisMaterialId,
            UUID supplyActionId, UUID preparationItemId,
            UUID goodsId, UUID colorId, UUID unitId, UUID warehouseId,
            BigDecimal requiredQty, BigDecimal producedQty, BigDecimal notifiedQty,
            BigDecimal availableQty, LocalDate needDate, String sourceLabel) {
    }

    // ==================== 成品入库钩子 ====================

    /**
     * FINISHED_IN 审核同事务：把 SUBCONTRACT_MAKE 任务的成品实收转入
     * SUBCONTRACT_PREPARE_TASK 专属预留并累计 produced_qty；
     * 满批（produced ≥ required）且有未通知余量时自动生成委外申请。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void afterFinishedInboundApproved(
            UUID stockDocumentId, UUID warehouseId) {
        // The warehouse action owns this internal callback. It is not a manual
        // planning command and must not require the warehouse user to own the analysis.
        List<UUID> analysisIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT DISTINCT task.analysis_id
                FROM stock_document_items stock_item
                JOIN production_plan_items production_item
                  ON production_item.id = stock_item.upstream_item_id
                JOIN production_plans production_plan ON production_plan.id = production_item.plan_id
                JOIN preplan_subcontract_make_tasks task
                  ON task.preparation_item_id = production_plan.material_analysis_item_id
                 AND task.analysis_id = production_plan.material_analysis_id
                WHERE stock_item.doc_id = :documentId AND task.status = 'ACTIVE'
                ORDER BY task.analysis_id
                """).setParameter("documentId", stockDocumentId), UUID.class);
        Map<UUID, UUID> analysisOwners = new java.util.LinkedHashMap<>();
        for (UUID analysisId : analysisIds) {
            analysisOwners.put(analysisId, analyses.lockHeader(analysisId).makerId());
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT task.id, stock_item.id,
                       stock_item.goods_id, stock_item.color_id,
                       stock_item.qty * COALESCE(stock_item.unit_rate, 1),
                       stock_item.unit_id, COALESCE(stock_item.unit_rate, 1),
                       production_item.goods_id, production_item.color_id,
                       production_item.unit_id,
                       COALESCE(production_item.unit_rate, 1),
                       task.goods_id, task.color_id, task.unit_id,
                       stock_doc.warehouse_id
                FROM stock_document_items stock_item
                JOIN stock_documents stock_doc
                  ON stock_doc.id = stock_item.doc_id
                 AND stock_doc.status = 1 AND stock_doc.is_deleted = FALSE
                JOIN production_plan_items production_item
                  ON production_item.id = stock_item.upstream_item_id
                 AND production_item.is_deleted = FALSE
                JOIN production_plans production_plan
                  ON production_plan.id = production_item.plan_id
                 AND production_plan.status = 1
                 AND production_plan.is_deleted = FALSE
                JOIN preplan_subcontract_make_tasks task
                  ON task.preparation_item_id =
                     production_plan.material_analysis_item_id
                 AND task.analysis_id = production_plan.material_analysis_id
                 AND task.status = 'ACTIVE'
                WHERE stock_item.doc_id = :documentId
                  AND stock_item.bill_type = 'FINISHED_IN'
                  AND stock_item.is_deleted = FALSE
                ORDER BY task.id, stock_item.id
                FOR UPDATE OF task
                """).setParameter("documentId", stockDocumentId).getResultList();
        if (rows.isEmpty()) return;
        UUID actorId = currentUser.requireId();
        Map<UUID, BigDecimal> producedAfterByTask = new java.util.LinkedHashMap<>();
        for (Object[] row : rows) {
            UUID taskId = (UUID) row[0];
            UUID stockItemId = (UUID) row[1];
            BigDecimal baseQty = decimal(row[4]);
            // Keep the task identity and unit snapshot; custody follows the
            // actual qualified FINISHED_IN document, including another main warehouse.
            boolean dimensionOk = Objects.equals(row[7], row[11])
                    && Objects.equals(row[8], row[12])
                    && Objects.equals(row[9], row[13])
                    && Objects.equals(row[2], row[11])
                    && Objects.equals(row[3], row[12])
                    && Objects.equals(row[5], row[13]);
            if (!dimensionOk
                    || decimal(row[6]).compareTo(BigDecimal.ONE) != 0
                    || decimal(row[10]).compareTo(BigDecimal.ONE) != 0
                    || !Objects.equals(row[14], warehouseId)) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "委外前置自制成品入库与任务货品、单位、换算率或实收单据仓不一致，"
                                + "禁止静默释放通知委外");
            }
            if (baseQty.signum() <= 0) continue;
            String idempotencyKey = "SC-MAKE-IN:" + stockItemId;
            Number existing = (Number) em.createNativeQuery("""
                    SELECT COUNT(*) FROM stock_reservations
                    WHERE idempotency_key = :key
                    """).setParameter("key", idempotencyKey).getSingleResult();
            if (existing.longValue() > 0) continue;
            em.createNativeQuery("""
                    INSERT INTO stock_reservations(
                        id, order_item_id, goods_id, color_id, warehouse_id,
                        qty, consumed_qty, released_qty, status, source,
                        source_doc_type, source_doc_id,
                        owner_type, owner_id, purpose, demand_id,
                        supply_type, supply_id, idempotency_key,
                        created_by, updated_by)
                    VALUES (
                        :id, NULL, :goodsId, :colorId, :warehouseId,
                        :qty, 0, 0, 0, 1,
                        'PRODUCTION_INBOUND', :documentId,
                        'SUBCONTRACT_PREPARE_TASK', :taskId,
                        'SUBCONTRACT_PREPARE_TASK', NULL,
                        'PRODUCTION_FINISHED_IN', :stockItemId, :key,
                        :actorId, :actorId)
                    """)
                    .setParameter("id", UUID.randomUUID())
                    .setParameter("goodsId", row[2])
                    .setParameter("colorId", row[3])
                    .setParameter("warehouseId", warehouseId)
                    .setParameter("qty", baseQty)
                    .setParameter("documentId", stockDocumentId)
                    .setParameter("taskId", taskId)
                    .setParameter("stockItemId", stockItemId)
                    .setParameter("key", idempotencyKey)
                    .setParameter("actorId", actorId)
                    .executeUpdate();
            em.createNativeQuery("""
                    UPDATE preplan_subcontract_make_tasks
                    SET produced_qty = produced_qty + :qty,
                        version = version + 1,
                        updated_by = :actorId, updated_at = now()
                    WHERE id = :id AND status = 'ACTIVE'
                    """)
                    .setParameter("qty", baseQty)
                    .setParameter("actorId", actorId)
                    .setParameter("id", taskId)
                    .executeUpdate();
            producedAfterByTask.merge(taskId, baseQty, BigDecimal::add);
        }
        // 满批自动通知：produced ≥ required 且仍有已产未通知量。
        for (Map.Entry<UUID, BigDecimal> entry : producedAfterByTask.entrySet()) {
            autoNotifyIfComplete(entry.getKey(), actorId, analysisOwners);
        }
    }

    private void autoNotifyIfComplete(
            UUID taskId, UUID actorUserId, Map<UUID, UUID> analysisOwners) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT task.id, task.analysis_id, task.analysis_material_id,
                       task.supply_action_id, task.preparation_item_id,
                       task.goods_id, task.color_id, task.unit_id,
                       task.warehouse_id, task.required_qty, task.produced_qty,
                       task.notified_qty,
                       item.delivery_date, analysis.analyzed_at,
                       LEAST(task.required_qty, task.produced_qty)
                           - task.notified_qty AS available_qty
                FROM preplan_subcontract_make_tasks task
                LEFT JOIN production_material_analysis_items item
                  ON item.id = task.preparation_item_id
                LEFT JOIN production_material_analyses analysis
                  ON analysis.id = task.analysis_id
                WHERE task.id = :id AND task.status = 'ACTIVE'
                FOR UPDATE OF task
                """).setParameter("id", taskId));
        if (rows.isEmpty()) return;
        Object[] row = rows.getFirst();
        BigDecimal available = decimal(row[14]);
        if (available.signum() <= 0) return;
        if (decimal(row[10]).compareTo(decimal(row[9])) < 0) return;
        LockedTask task = new LockedTask((UUID) row[0], (UUID) row[1],
                (UUID) row[2], (UUID) row[3], (UUID) row[4], (UUID) row[5],
                (UUID) row[6], (UUID) row[7], (UUID) row[8], decimal(row[9]),
                decimal(row[10]), decimal(row[11]), available,
                row[12] == null ? null
                        : com.uten.imp.common.util.NativeValueConverters
                                .toLocalDate(row[12]),
                "计划前物料分析 " + (row[13] == null ? ""
                        : toInstant(row[13]).atZone(
                                com.uten.imp.common.time.BusinessTime.ZONE)
                                .toLocalDate()));
        Number batchCount = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM preplan_subcontract_make_task_batches WHERE task_id=:taskId
                """).setParameter("taskId",taskId).getSingleResult();
        // Historical batch count is monotonic even after reversal; newly produced
        // replacements must not collide with a reversed batch's old notified total.
        String idempotencyKey = "SC-MAKE-AUTO-V2:" + taskId + ':' + batchCount.longValue();
        Number exists = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM preplan_subcontract_make_task_batches
                WHERE task_id = :taskId AND idempotency_key = :idempotencyKey
                """).setParameter("taskId", taskId)
                .setParameter("idempotencyKey", idempotencyKey)
                .getSingleResult();
        if (exists.longValue() > 0) return;
        UUID ownerEmployeeId = analysisOwners.get(task.analysisId());
        if (ownerEmployeeId == null) {
            // Legacy ownerless analyses remain explicit manual remediation tasks;
            // do not silently attribute their request to a warehouse employee.
            return;
        }
        createApplicationBatch(task, available, idempotencyKey,
                ownerEmployeeId, actorUserId);
    }

    /**
     * FINISHED_IN 红冲前置：释放该入库建立的 SUBCONTRACT_PREPARE_TASK 预留，
     * 回减 produced_qty；已通知量超过回减后产出时失败关闭。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void beforeFinishedInboundReversed(UUID stockDocumentId) {
        @SuppressWarnings("unchecked")
        List<Object[]> reservations = em.createNativeQuery("""
                SELECT reservation.id, reservation.owner_id, reservation.qty,
                       reservation.consumed_qty, reservation.released_qty
                FROM stock_reservations reservation
                WHERE reservation.owner_type = 'SUBCONTRACT_PREPARE_TASK'
                  AND reservation.supply_type = 'PRODUCTION_FINISHED_IN'
                  AND reservation.source_doc_type = 'PRODUCTION_INBOUND'
                  AND reservation.source_doc_id = :documentId
                  AND reservation.is_deleted = FALSE
                ORDER BY reservation.owner_id, reservation.id
                FOR UPDATE
                """).setParameter("documentId", stockDocumentId).getResultList();
        UUID actorId = currentUser.requireId();
        for (Object[] row : reservations) {
            UUID reservationId = (UUID) row[0];
            UUID taskId = (UUID) row[1];
            BigDecimal qty = decimal(row[2]);
            if (decimal(row[3]).signum() > 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "委外前置自制产出已被委外订货出仓占用，必须先红冲委外出仓"
                                + "与订货后再红冲成品入库");
            }
            if (decimal(row[4]).compareTo(qty) < 0) {
                BigDecimal remaining = qty.subtract(decimal(row[4]));
                em.createNativeQuery("""
                        UPDATE stock_reservations
                        SET released_qty = qty, status = 1,
                            release_reason = 'PRODUCTION_FINISHED_IN_REVERSED',
                            lock_version = lock_version + 1,
                            updated_at = now(), updated_by = :actorId
                        WHERE id = :id AND consumed_qty = 0
                        """).setParameter("actorId", actorId)
                        .setParameter("id", reservationId).executeUpdate();
                int updated = em.createNativeQuery("""
                        UPDATE preplan_subcontract_make_tasks
                        SET produced_qty = produced_qty - :qty,
                            version = version + 1,
                            updated_by = :actorId, updated_at = now()
                        WHERE id = :id
                          AND produced_qty >= :qty
                          AND notified_qty <= produced_qty - :qty
                        """).setParameter("qty", remaining)
                        .setParameter("actorId", actorId)
                        .setParameter("id", taskId).executeUpdate();
                if (updated != 1) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "该入库切片已通知委外（委外申请已生成），"
                                    + "必须先反向委外链再红冲成品入库");
                }
            }
        }
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }

    private static java.time.Instant toInstant(Object value) {
        if (value instanceof java.time.Instant instant) return instant;
        if (value instanceof java.sql.Timestamp timestamp) {
            return timestamp.toInstant();
        }
        if (value instanceof java.time.OffsetDateTime offsetDateTime) {
            return offsetDateTime.toInstant();
        }
        throw new IllegalStateException(
                "不支持的时间类型：" + value.getClass().getName());
    }
}
