package com.uten.imp.features.production.quality;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.AnalysisView;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** Planner-confirmed SCRAP/REJECT remediation entry into the existing MRP chain. */
@Service
@RequiredArgsConstructor
public class ProductionFqcReplenishmentService {

    private final EntityManager em;
    private final MaterialAnalysisService materialAnalysis;
    private final ProductionDocumentAccessPolicy productionAccess;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ProductionQualityMutationFootprintService mutationFootprint;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('production_fqc_replenishment:view')"
            + " and hasAuthority('production_material_analysis:view')")
    public PageResponse<ReplenishmentTaskView> pending(
            int requestedPage, int requestedSize) {
        PageRequest pageable = Pageables.of(requestedPage, requestedSize);
        int page = pageable.getPageNumber() + 1;
        int size = pageable.getPageSize();
        var scope = productionAccess.nativeReadScope(
                "report.maker_id", "fqcReplenishmentOwners",
                "production_fqc_replenishment:view");
        String baseSql = """
                        SELECT task.id, recovery_auth.id,
                               recovery_auth.disposition_code,
                               recovery_auth.authorized_qty,
                               recovery_auth.warehouse_id,
                               recovery_auth.goods_id, goods.code, goods.name,
                               recovery_auth.color_id, recovery_auth.unit_id,
                               recovery_auth.source_inspection_id,
                               recovery_auth.source_report_item_id,
                               report.bill_no,
                               link.material_analysis_id,
                               link.material_analysis_item_id
                        FROM production_fqc_replenishment_tasks task
                        JOIN production_fqc_recovery_authorizations recovery_auth
                          ON recovery_auth.id = task.authorization_id
                        JOIN production_daily_report_items source_item
                          ON source_item.id = recovery_auth.source_report_item_id
                        JOIN production_daily_reports report
                          ON report.id = source_item.report_id
                        JOIN goods goods ON goods.id = recovery_auth.goods_id
                        LEFT JOIN production_fqc_replenishment_analysis_links link
                          ON link.replenishment_task_id = task.id
                        WHERE %s
                          AND NOT EXISTS (
                              SELECT 1
                              FROM production_fqc_recovery_cancellation_events c
                              WHERE c.authorization_id = recovery_auth.id)
                        """.formatted(scope.predicate());
        var countQuery = em.createNativeQuery(
                "SELECT COUNT(*) FROM (" + baseSql + ") pending_fqc");
        scope.bind(countQuery);
        long total = ((Number) countQuery.getSingleResult()).longValue();
        var query = em.createNativeQuery(baseSql + """
                        ORDER BY task.created_at, task.id
                        OFFSET :offset LIMIT :limit
                        """);
        scope.bind(query);
        query.setParameter("offset", pageable.getOffset());
        query.setParameter("limit", size);
        List<ReplenishmentTaskView> items = NativeQueryResults.objectArrayRows(query).stream()
                .map(row -> new ReplenishmentTaskView(
                        (UUID) row[0], (UUID) row[1], (String) row[2],
                        decimal(row[3]), (UUID) row[4], (UUID) row[5],
                        (String) row[6], (String) row[7], (UUID) row[8],
                        (UUID) row[9], (UUID) row[10], (UUID) row[11],
                        (String) row[12], (UUID) row[13], (UUID) row[14]))
                .toList();
        int totalPages = total == 0 ? 0 : (int) ((total + size - 1) / size);
        return new PageResponse<>(items, page, size, total, totalPages);
    }

    @Transactional
    @PreAuthorize("hasAuthority('production_fqc_replenishment:confirm')"
            + " and hasAuthority('production_material_analysis:create')")
    public ReplenishmentTaskView createMaterialAnalysis(UUID authorizationId) {
        tx.bind();
        var sourceGuard = mutationFootprint.beginAuthorization(authorizationId, true);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT task.id, recovery_auth.id,
                                       recovery_auth.disposition_code,
                                       recovery_auth.authorized_qty,
                                       recovery_auth.warehouse_id,
                                       recovery_auth.goods_id,
                                       recovery_auth.color_id,
                                       recovery_auth.unit_id,
                                       recovery_auth.source_inspection_id,
                                       recovery_auth.source_report_item_id,
                                       report.maker_id, report.bill_no,
                                       goods.code, goods.name
                                FROM production_fqc_replenishment_tasks task
                                JOIN production_fqc_recovery_authorizations recovery_auth
                                  ON recovery_auth.id = task.authorization_id
                                JOIN production_daily_report_items source_item
                                  ON source_item.id = recovery_auth.source_report_item_id
                                JOIN production_daily_reports report
                                  ON report.id = source_item.report_id
                                JOIN goods goods ON goods.id = recovery_auth.goods_id
                                WHERE recovery_auth.id = :authorizationId
                                FOR UPDATE OF task, recovery_auth
                                """)
                        .setParameter("authorizationId", authorizationId));
        if (rows.size() != 1) throw notFound("FQC 补产规划任务不存在");
        Object[] row = rows.getFirst();
        productionAccess.requireScopedOperationWritable(
                (UUID) row[10], "无权确认此 FQC 补产规划任务",
                "production_fqc_replenishment:confirm");
        List<Object[]> replay = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT material_analysis_id,
                                       material_analysis_item_id
                                FROM production_fqc_replenishment_analysis_links
                                WHERE authorization_id = :authorizationId
                                """)
                        .setParameter("authorizationId", authorizationId));
        UUID analysisId;
        UUID analysisItemId;
        if (!replay.isEmpty()) {
            analysisId = (UUID) replay.getFirst()[0];
            analysisItemId = (UUID) replay.getFirst()[1];
        } else {
            sourceGuard.verifyUnchanged();
            String sourceRef = "FQC-RECOVERY-" + authorizationId;
            AnalysisView analysis = materialAnalysis.preview(new PreviewRequest(
                    null, null, null, (UUID) row[4],
                    "FQC-REPLENISH:" + authorizationId,
                    List.of(new PreviewItem(
                            "REWORK", null, (UUID) row[5], (UUID) row[6],
                            (UUID) row[7], sourceRef,
                            "FQC " + row[2] + " 补产，来源报工 " + row[11],
                            null, decimal(row[3])))));
            if (analysis.products().size() != 1) {
                throw conflict("FQC 补产物料分析未形成唯一产品需求");
            }
            analysisId = analysis.analysisId();
            analysisItemId = analysis.products().getFirst().analysisLineId();
            em.createNativeQuery("""
                            INSERT INTO production_fqc_replenishment_analysis_links(
                                id, replenishment_task_id, authorization_id,
                                material_analysis_id, material_analysis_item_id,
                                idempotency_key, created_by)
                            VALUES (
                                gen_random_uuid(), :taskId, :authorizationId,
                                :analysisId, :analysisItemId, :key, :actorId)
                            """)
                    .setParameter("taskId", row[0])
                    .setParameter("authorizationId", authorizationId)
                    .setParameter("analysisId", analysisId)
                    .setParameter("analysisItemId", analysisItemId)
                    .setParameter("key", "FQC-REPLENISH:" + authorizationId)
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
        }
        return new ReplenishmentTaskView(
                (UUID) row[0], authorizationId, (String) row[2],
                decimal(row[3]), (UUID) row[4], (UUID) row[5],
                (String) row[12], (String) row[13], (UUID) row[6],
                (UUID) row[7], (UUID) row[8], (UUID) row[9],
                (String) row[11], analysisId, analysisItemId);
    }

    public record ReplenishmentTaskView(
            UUID taskId,
            UUID authorizationId,
            String dispositionCode,
            BigDecimal quantity,
            UUID warehouseId,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            UUID colorId,
            UUID unitId,
            UUID sourceInspectionId,
            UUID sourceReportItemId,
            String sourceReportNo,
            UUID materialAnalysisId,
            UUID materialAnalysisItemId) {
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private static ApiException notFound(String message) {
        return new ApiException(ErrorCode.NOT_FOUND, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }
}
