package com.uten.imp.features.production.execution;

import com.uten.imp.application.port.ProductionCompletionReversePort;
import com.uten.imp.application.port.SubcontractOrderPreparationPort;
import com.uten.imp.application.port.SubcontractPreparationInventoryPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.analysis.MaterialAnalysisSupplyWakeupService;
import com.uten.imp.features.production.analysis.SubcontractMakeTaskService;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.List;
import java.util.Objects;
import java.util.TreeSet;
import java.util.UUID;

/**
 * Explicit, auditable completion-reopen step used by FINISHED_IN reversal.
 *
 * <p>This service intentionally does not restore material reservations released
 * at completion and does not reverse report facts. It only opens the exact
 * segment for the remainder of the same stock-document reversal transaction.
 * A later explicit daily-report reversal remains responsible for reversing the
 * report fact.
 */
@Service
@RequiredArgsConstructor
public class ProductionCompletionReverseService
        implements ProductionCompletionReversePort {

    private static final String ACTION = "REOPEN_COMPLETION";
    private static final String KEY_PREFIX = "FINISHED_IN_REVERSE:";

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;

    private final ProductionExecutionReadinessService readiness;
    private final MaterialAnalysisSupplyWakeupService materialAnalysisWakeup;
    private final SubcontractPreparationInventoryPort subcontractPreparation;
    private final SubcontractMakeTaskService subcontractMakeTasks;
    private final SubcontractOrderPreparationPort subcontractOrderPreparation;

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void lockFinishedInboundProductionDimensions(
            UUID stockDocumentId,
            UUID warehouseId) {
        readiness.lockFinishedInboundProductionDimensions(
                stockDocumentId, warehouseId);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void afterFinishedInboundApproved(
            UUID stockDocumentId,
            UUID warehouseId) {
        if (stockDocumentId == null || warehouseId == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "成品入库触发自制件就绪提升时缺少单据或仓库");
        }
        readiness.onFinishedInboundApproved(
                stockDocumentId, warehouseId);
        subcontractPreparation.afterFinishedInboundApproved(
                stockDocumentId, warehouseId);
        // V458：有子层级委外件的前置自制产出先转 SUBCONTRACT_PREPARE_TASK
        // 专属预留并触发满批自动通知，再让分析刷新读 v_stock_available。
        subcontractMakeTasks.afterFinishedInboundApproved(
                stockDocumentId, warehouseId);
        // 2026-09-05 委外收敛：直接下单草稿期的前置生产分析有产出时，
        // 通知委外制单人目标件开始回笼（全部备齐即可提交财务审核）。
        subcontractOrderPreparation.afterFinishedInboundApproved(
                stockDocumentId);
        // The dedicated outbound reservation must exist before any analysis
        // refresh reads v_stock_available, otherwise the new target item can
        // be snapshotted as public stock by another analysis.
        materialAnalysisWakeup.afterFinishedInboundApproved(stockDocumentId);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void afterFinishedInboundReversed(
            UUID stockDocumentId, UUID warehouseId) {
        materialAnalysisWakeup.afterFinishedInboundReversed(stockDocumentId);
    }

    /**
     * 成品入库红冲前置：把该入库关联的 COMPLETED 执行段回退为 IN_PROGRESS。COMPLETED→IN_PROGRESS 受行触发器拦截，
     * 这里写事务级 GUC app.production_completion_reopen_doc_id 作为放行凭据；逐段幂等，并发版本不匹配即整体回滚。
     */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void beforeFinishedInboundReversed(UUID stockDocumentId) {
        if (stockDocumentId == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "成品入库红冲缺少单据标识");
        }
        lockAndRequireApprovedFinishedIn(stockDocumentId);
        subcontractPreparation.beforeFinishedInboundReversed(stockDocumentId);
        subcontractMakeTasks.beforeFinishedInboundReversed(stockDocumentId);
        readiness.beforeFinishedInboundReversed(stockDocumentId);
        List<UUID> segmentIds = exactSegmentIds(stockDocumentId);
        if (segmentIds.isEmpty()) {
            return;
        }

        // The row trigger checks this transaction-local document identity
        // together with the semantic event before allowing COMPLETED -> IN_PROGRESS.
        em.createNativeQuery("""
                        SELECT set_config(
                            'app.production_completion_reopen_doc_id',
                            :documentId,
                            true)
                        """)
                .setParameter("documentId", stockDocumentId.toString())
                .getSingleResult();

        for (UUID segmentId : segmentIds) {
            LockedSegment segment =
                    lockAndValidateSegment(stockDocumentId, segmentId);
            if ("IN_PROGRESS".equals(segment.status())) {
                continue;
            }
            if (!"COMPLETED".equals(segment.status())) {
                throw conflict(
                        "成品入库关联的执行子计划状态异常，禁止自动猜测重开："
                                + segment.segmentCode());
            }

            String idempotencyKey = KEY_PREFIX + stockDocumentId;
            String requestHash = requestHash(stockDocumentId, segment);
            requireNoConflictingReplay(
                    segmentId, idempotencyKey, requestHash);
            recordEvent(segment, idempotencyKey, requestHash);

            int updated = em.createNativeQuery("""
                            UPDATE production_execution_segments
                            SET status = 'IN_PROGRESS',
                                completion_reopened = TRUE
                            WHERE id = :segmentId
                              AND status = 'COMPLETED'
                              AND lock_version = :expectedVersion
                              AND is_deleted = FALSE
                            """)
                    .setParameter("segmentId", segmentId)
                    .setParameter("expectedVersion", segment.lockVersion())
                    .executeUpdate();
            if (updated != 1) {
                throw conflict(
                        "执行子计划已被其他操作修改，成品入库未红冲，请刷新后重试");
            }
        }
    }

    private DocumentHeader lockAndRequireApprovedFinishedIn(UUID documentId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, doc_type, status, is_deleted
                                FROM stock_documents
                                WHERE id = :documentId
                                FOR UPDATE
                                """)
                        .setParameter("documentId", documentId));
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "成品入库单不存在");
        }
        Object[] row = rows.getFirst();
        DocumentHeader header = new DocumentHeader(
                (UUID) row[0],
                (String) row[1],
                row[2] == null ? null : ((Number) row[2]).shortValue(),
                Boolean.TRUE.equals(row[3]));
        if (!"FINISHED_IN".equals(header.documentType())
                || header.status() == null
                || header.status() != 1
                || header.deleted()) {
            throw conflict("仅未删除、已审核的成品入库单可以进入完成红冲流程");
        }
        return header;
    }

    private List<UUID> exactSegmentIds(UUID documentId) {
        TreeSet<UUID> ids = new TreeSet<>(NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT DISTINCT execution_segment_id
                                FROM stock_document_items
                                WHERE doc_id = :documentId
                                  AND bill_type = 'FINISHED_IN'
                                  AND execution_segment_id IS NOT NULL
                                  AND is_deleted = FALSE
                                ORDER BY execution_segment_id
                                """)
                        .setParameter("documentId", documentId),
                UUID.class));
        return List.copyOf(ids);
    }

    private LockedSegment lockAndValidateSegment(
            UUID documentId,
            UUID segmentId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT segment.id, segment.segment_code,
                                       segment.plan_id,
                                       segment.source_plan_item_id,
                                       segment.product_goods_id,
                                       segment.product_color_id,
                                       segment.product_unit_id,
                                       segment.product_unit_rate,
                                       segment.planned_qty,
                                       segment.status,
                                       segment.lock_version,
                                       segment.completion_reopened,
                                       package.status,
                                       package.execution_model_version
                                FROM production_execution_segments segment
                                JOIN production_planning_packages package
                                  ON package.id = segment.package_id
                                 AND package.is_deleted = FALSE
                                WHERE segment.id = :segmentId
                                  AND segment.is_deleted = FALSE
                                FOR UPDATE OF segment
                                """)
                        .setParameter("segmentId", segmentId));
        if (rows.isEmpty()) {
            throw conflict("成品入库关联的执行子计划不存在");
        }
        Object[] row = rows.getFirst();
        LockedSegment segment = new LockedSegment(
                (UUID) row[0],
                (String) row[1],
                (UUID) row[2],
                (UUID) row[3],
                (UUID) row[4],
                (UUID) row[5],
                (UUID) row[6],
                decimal(row[7]),
                decimal(row[8]),
                (String) row[9],
                ((Number) row[10]).longValue(),
                Boolean.TRUE.equals(row[11]),
                (String) row[12],
                ((Number) row[13]).shortValue());

        if (!"CONFIRMED".equals(segment.packageStatus())
                || segment.executionModelVersion() != 1) {
            throw conflict("成品入库关联的执行计划包已失效，禁止红冲");
        }
        validateExactLines(documentId, segment);
        validateDocumentPlanLink(documentId, segment.planId());
        if ("COMPLETED".equals(segment.status())) {
            if (segment.completionReopened()) {
                throw conflict("已完成执行子计划的纠错状态异常，禁止重复重开");
            }
            BigDecimal approvedInbound = approvedInbound(segment.id());
            if (approvedInbound.compareTo(segment.plannedQty()) != 0) {
                throw conflict(
                        "已完成执行子计划的入库累计与计划数量不一致，禁止自动红冲");
            }
        }
        return segment;
    }

    private void validateExactLines(UUID documentId, LockedSegment segment) {
        Number invalid = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM stock_document_items item
                        WHERE item.doc_id = :documentId
                          AND item.execution_segment_id = :segmentId
                          AND (
                              item.is_deleted
                              OR item.bill_type <> 'FINISHED_IN'
                              OR item.qty IS NULL
                              OR item.qty <= 0
                              OR item.upstream_item_id IS DISTINCT FROM :planItemId
                              OR item.goods_id IS DISTINCT FROM :goodsId
                              OR item.color_id IS DISTINCT FROM CAST(:colorId AS uuid)
                              OR item.unit_id IS DISTINCT FROM :unitId
                              OR COALESCE(item.unit_rate, 1)
                                   IS DISTINCT FROM :unitRate
                          )
                        """)
                .setParameter("documentId", documentId)
                .setParameter("segmentId", segment.id())
                .setParameter("planItemId", segment.sourcePlanItemId())
                .setParameter("goodsId", segment.productGoodsId())
                .setParameter("colorId", segment.productColorId())
                .setParameter("unitId", segment.productUnitId())
                .setParameter("unitRate", segment.productUnitRate())
                .getSingleResult();
        if (invalid.longValue() != 0) {
            throw conflict("成品入库行与原执行子计划的产品、单位或计划行不一致");
        }
    }

    private void validateDocumentPlanLink(UUID documentId, UUID planId) {
        Number count = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM plan_draw_links link
                        WHERE link.draw_id = :documentId
                          AND link.plan_id = :planId
                          AND link.is_deleted = FALSE
                        """)
                .setParameter("documentId", documentId)
                .setParameter("planId", planId)
                .getSingleResult();
        if (count.longValue() != 1) {
            throw conflict("成品入库单与执行子计划的生产计划来源不一致");
        }
    }

    private BigDecimal approvedInbound(UUID segmentId) {
        Object value = em.createNativeQuery("""
                        SELECT COALESCE(SUM(item.qty), 0)
                        FROM stock_document_items item
                        JOIN stock_documents document
                          ON document.id = item.doc_id
                        WHERE item.execution_segment_id = :segmentId
                          AND item.bill_type = 'FINISHED_IN'
                          AND item.is_deleted = FALSE
                          AND document.doc_type = 'FINISHED_IN'
                          AND document.status = 1
                          AND document.is_deleted = FALSE
                        """)
                .setParameter("segmentId", segmentId)
                .getSingleResult();
        return decimal(value);
    }

    private void requireNoConflictingReplay(
            UUID segmentId,
            String idempotencyKey,
            String requestHash) {
        List<Object[]> events = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT request_hash, resulting_version
                                FROM production_execution_segment_events
                                WHERE execution_segment_id = :segmentId
                                  AND action = :action
                                  AND idempotency_key = :idempotencyKey
                                FOR UPDATE
                                """)
                        .setParameter("segmentId", segmentId)
                        .setParameter("action", ACTION)
                        .setParameter("idempotencyKey", idempotencyKey));
        if (events.isEmpty()) {
            return;
        }
        if (!Objects.equals(events.getFirst()[0], requestHash)) {
            throw conflict("相同成品入库红冲幂等键对应不同的执行子计划版本");
        }
        throw conflict("该成品入库完成重开已处理，请刷新单据状态");
    }

    private void recordEvent(
            LockedSegment segment,
            String idempotencyKey,
            String requestHash) {
        em.createNativeQuery("""
                        INSERT INTO production_execution_segment_events(
                            id, execution_segment_id, action, idempotency_key,
                            request_hash, expected_version, resulting_version,
                            created_at, created_by
                        ) VALUES (
                            gen_random_uuid(), :segmentId, :action,
                            :idempotencyKey, :requestHash, :expectedVersion,
                            :resultingVersion, now(), :actorId
                        )
                        """)
                .setParameter("segmentId", segment.id())
                .setParameter("action", ACTION)
                .setParameter("idempotencyKey", idempotencyKey)
                .setParameter("requestHash", requestHash)
                .setParameter("expectedVersion", segment.lockVersion())
                .setParameter("resultingVersion", segment.lockVersion() + 1)
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
    }

    private static String requestHash(
            UUID documentId, LockedSegment segment) {
        return PlanningPackageFingerprint.sha256(List.of(
                "ACTION|" + ACTION,
                "DOCUMENT|" + documentId,
                "SEGMENT|" + segment.id(),
                "VERSION|" + segment.lockVersion(),
                "PLANNED_QTY|"
                        + segment.plannedQty().stripTrailingZeros().toPlainString()));
    }

    private static BigDecimal decimal(Object value) {
        return value == null
                ? BigDecimal.ZERO
                : new BigDecimal(value.toString());
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private record DocumentHeader(
            UUID id, String documentType, Short status, boolean deleted) {
    }

    private record LockedSegment(
            UUID id,
            String segmentCode,
            UUID planId,
            UUID sourcePlanItemId,
            UUID productGoodsId,
            UUID productColorId,
            UUID productUnitId,
            BigDecimal productUnitRate,
            BigDecimal plannedQty,
            String status,
            long lockVersion,
            boolean completionReopened,
            String packageStatus,
            short executionModelVersion) {
    }
}
