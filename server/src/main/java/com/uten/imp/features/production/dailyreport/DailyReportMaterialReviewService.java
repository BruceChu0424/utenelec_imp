package com.uten.imp.features.production.dailyreport;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.ProductionMaterialConsumptionWritePort;
import com.uten.imp.application.port.ProductionMaterialConsumptionWritePort.ConsumptionLine;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.dailyreport.dto.DailyReportDetail;
import com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialDecision;
import com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialReview;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Review a complete source snapshot before any approval effects, then retain it as a command fact. */
@Service
@RequiredArgsConstructor
@Transactional(propagation = Propagation.MANDATORY)
public class DailyReportMaterialReviewService {
    private final EntityManager em;
    private final ObjectMapper json;
    private final ProductionMaterialConsumptionWritePort materials;

    public DailyReportMaterialReview review(UUID reportId, long version, boolean lock) {
        List<SourceScope> scopes = sources(reportId);
        if (lock && !scopes.isEmpty()) {
            // All plans and segments precede every demand/ISSUE lock, across inherited source plans too.
            em.createNativeQuery("SELECT id FROM production_plans WHERE id IN (:ids) ORDER BY id FOR UPDATE")
                    .setParameter("ids", scopes.stream().map(SourceScope::planId).distinct().sorted().toList()).getResultList();
            em.createNativeQuery("SELECT id FROM production_execution_segments WHERE id IN (:ids) ORDER BY id FOR UPDATE")
                    .setParameter("ids", scopes.stream().map(SourceScope::segmentId).distinct().sorted().toList()).getResultList();
        }
        Map<UUID, List<ConsumptionLine>> usages = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT material_execution_segment_id,demand_id,qty_base
                FROM production_daily_report_material_usages WHERE report_id=:id ORDER BY demand_id
                """).setParameter("id", reportId))) {
            usages.computeIfAbsent((UUID) row[0], ignored -> new ArrayList<>())
                    .add(new ConsumptionLine((UUID) row[1], decimal(row[2])));
        }
        List<DailyReportMaterialReview.Row> rows = new ArrayList<>();
        List<String> parts = new ArrayList<>(List.of("DAILY-REPORT-MATERIAL-REVIEW-V3",
                "report:" + reportId, "version:" + version));
        for (SourceScope source : scopes) {
            var review = materials.reviewForDailyReport(source.planId(), source.segmentId(),
                    usages.getOrDefault(source.segmentId(), List.of()), lock);
            parts.add("source:" + source + ":" + review.fingerprint());
            for (var row : review.rows()) {
                boolean returnAllowed = source.finalReport() && row.canReturn();
                String blocked = !source.finalReport() && row.remainingIssuedQty().add(row.undrawnDirectQty()).signum() > 0
                        ? "当前工单尚未收尾，余料留供继续生产" : row.returnBlockedReason();
                rows.add(new DailyReportMaterialReview.Row(row.demandId(), source.planId(), source.segmentId(),
                        row.segmentCode(), row.goodsCode(), row.goodsName(), row.colorName(), row.unitName(),
                        row.availableQty(), row.usageQty(), row.remainingIssuedQty(), row.undrawnDirectQty(),
                        source.finalReport() ? row.returnableIssuedQty() : BigDecimal.ZERO,
                        source.finalReport() ? row.returnableDirectQty() : BigDecimal.ZERO, returnAllowed, blocked));
            }
        }
        rows.sort(Comparator.comparing(row -> row.demandId().toString()));
        if (rows.size() > 2000) throw new ApiException(ErrorCode.VALIDATION_FAILED, "材料审核明细超过2000项，请拆分日报");
        return new DailyReportMaterialReview(reportId, version, CanonicalFingerprint.sha256(parts), List.copyOf(rows));
    }

    private List<SourceScope> sources(UUID reportId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH targets AS (
                    SELECT item.execution_segment_id id,BOOL_OR(item.is_final) final_report,
                           COALESCE(SUM(item.qty) FILTER(WHERE item.fqc_recovery_authorization_id IS NULL
                                                       AND NOT item.is_actual_surplus),0) qty
                    FROM production_daily_report_items item WHERE item.report_id=:id
                      AND NOT item.is_deleted AND item.execution_segment_id IS NOT NULL
                    GROUP BY item.execution_segment_id
                ), target_policy AS (
                    SELECT target.id,(target.final_report OR target.qty+COALESCE((
                        SELECT SUM(item.qty) FROM production_daily_report_items item
                        JOIN production_daily_reports report ON report.id=item.report_id AND report.status=1 AND NOT report.is_deleted
                        WHERE item.execution_segment_id=target.id AND item.report_id<>:id AND NOT item.is_deleted
                          AND item.fqc_recovery_authorization_id IS NULL AND NOT item.is_actual_surplus),0)>=segment.planned_qty) final_report
                    FROM targets target JOIN production_execution_segments segment ON segment.id=target.id AND NOT segment.is_deleted
                ), source_policy AS (
                    SELECT target.id source_id,target.final_report FROM target_policy target
                    UNION ALL SELECT source.segment_id,target.final_report FROM target_policy target
                    CROSS JOIN LATERAL fn_production_material_usage_source_segments(target.id) source
                ), unique_sources AS (
                    SELECT source_id,BOOL_AND(final_report) final_report FROM source_policy GROUP BY source_id
                )
                SELECT segment.plan_id,segment.id,COALESCE(policy.final_report,FALSE)
                FROM production_execution_segments segment
                LEFT JOIN unique_sources policy ON policy.source_id=segment.id
                WHERE NOT segment.is_deleted AND (policy.source_id IS NOT NULL OR segment.id IN(
                    SELECT material_execution_segment_id FROM production_daily_report_material_usages WHERE report_id=:id))
                ORDER BY segment.plan_id,segment.id
                """).setParameter("id", reportId)).stream()
                .map(row -> new SourceScope((UUID) row[0], (UUID) row[1], Boolean.TRUE.equals(row[2]))).toList();
    }

    public static List<DailyReportMaterialDecision> normalizeDecisions(List<DailyReportMaterialDecision> values) {
        if (values == null || values.size() > 2000) throw invalidDecisions();
        Map<UUID, DailyReportMaterialDecision> unique = new LinkedHashMap<>();
        for (var value : values) {
            if (value == null || value.demandId() == null || value.action() == null || !List.of("KEEP", "RETURN").contains(value.action())
                    || unique.putIfAbsent(value.demandId(), value) != null) throw invalidDecisions();
        }
        return unique.values().stream().sorted(Comparator.comparing(value -> value.demandId().toString())).toList();
    }
    public static void requireDecisions(DailyReportMaterialReview review, List<DailyReportMaterialDecision> decisions) {
        Map<UUID, DailyReportMaterialReview.Row> rows = new LinkedHashMap<>();
        review.rows().forEach(row -> rows.put(row.demandId(), row));
        if (rows.size() != decisions.size() || decisions.stream().anyMatch(value -> !rows.containsKey(value.demandId()))) throw invalidDecisions();
        for (var decision : decisions) {
            if ("RETURN".equals(decision.action()) && !rows.get(decision.demandId()).canReturn()) {
                throw new ApiException(ErrorCode.DAILY_REPORT_MATERIAL_REVIEW_CONFLICT,
                        "「" + rows.get(decision.demandId()).goodsName() + "」当前不能申请退仓，请重新核对余料处理方式");
            }
        }
    }
    private static ApiException invalidDecisions() {
        return new ApiException(ErrorCode.VALIDATION_FAILED, "请为全部材料各选择一次留在车间或申请退仓");
    }

    public void recordApproval(UUID actor, String key, String hash, DailyReportMaterialReview review,
            List<DailyReportMaterialDecision> decisions) {
        em.createNativeQuery("""
                INSERT INTO production_daily_report_commands(id,actor_user_id,idempotency_key,request_hash,
                    report_id,created_by,command_kind,approval_protocol_version,reviewed_row_version,
                    material_review_fingerprint,material_review_snapshot,material_decisions)
                VALUES(gen_random_uuid(),:actor,:key,:hash,:report,:actor,'APPROVE',3,:version,
                       :fingerprint,CAST(:snapshot AS jsonb),CAST(:decisions AS jsonb))
                """).setParameter("actor", actor).setParameter("key", key).setParameter("hash", hash)
                .setParameter("report", review.reportId()).setParameter("version", review.reportVersion())
                .setParameter("fingerprint", review.fingerprint()).setParameter("snapshot", encode(review))
                .setParameter("decisions", encode(decisions)).executeUpdate();
    }

    public void hydrateDetail(DailyReportDetail detail) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT material_review_snapshot::text,material_decisions::text
                FROM production_daily_report_commands WHERE report_id=:id AND command_kind='APPROVE'
                  AND approval_protocol_version=3
                """).setParameter("id", detail.getId()));
        if (rows.isEmpty()) return;
        try {
            detail.setMaterialReview(json.readValue(rows.getFirst()[0].toString(), DailyReportMaterialReview.class));
            detail.setMaterialDecisions(json.readValue(rows.getFirst()[1].toString(), new TypeReference<>() { }));
        } catch (Exception error) { throw new IllegalStateException("生产日报材料审核原始记录无法读取", error); }
    }
    private String encode(Object value) {
        try { return json.writeValueAsString(value); }
        catch (Exception error) { throw new IllegalStateException("生产日报材料审核原始记录无法保存", error); }
    }
    private static BigDecimal decimal(Object value) { return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString()); }
    private record SourceScope(UUID planId, UUID segmentId, boolean finalReport) { }
}
