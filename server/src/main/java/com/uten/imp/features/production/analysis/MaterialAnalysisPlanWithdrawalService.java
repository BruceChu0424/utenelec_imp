package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.mrp.PlanningPackageLifecycleRequest;
import com.uten.imp.features.production.mrp.ProductionPlanningPackageService;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/** Atomic withdrawal of ordinary analysis plan responsibility and execution. */
@Service
@RequiredArgsConstructor
public class MaterialAnalysisPlanWithdrawalService {
    // The existing generic withdrawal operation supports this command without a schema change.
    // Both the hash namespace and stored commandKind distinguish it from supply-action withdrawal.
    private static final String OPERATION = "CANCEL_ACTION";
    private static final String COMMAND_KIND = "PLAN_WITHDRAWAL_V1";

    private final EntityManager em;
    private final MaterialAnalysisService analysis;
    private final MaterialAnalysisCommandService commands;
    private final ProductionDocumentAccessPolicy access;
    private final ProductionPlanningPackageService packages;
    private final ProductionPlanService plans;
    private final SecurityContextCurrentUser user;
    private final TxSessionVars tx;
    private final ObjectMapper mapper;

    @Transactional
    public AnalysisView withdraw(UUID analysisId, UUID planId, PlanWithdrawalRequest request) {
        validate(analysisId, planId, request);
        tx.bind();
        var guard = commands.lockAnalysisWithClaimableShared(analysisId);
        var header = analysis.headerAfterPrelock(analysisId);
        access.requireWritable(header.makerId(), "只能撤回本人负责物料分析的生产计划",
                analysis.scopeForAnalysis(header));
        requirePermission("production_material_analysis:generate", "缺少物料分析生产计划撤回权限");

        // A plan, source and conservation link must all name this exact analysis/source.
        // Keep terminal rows available for authorized idempotent replay.
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT plan.status, plan.is_deleted, plan.is_canceled, source.source_type,
                       EXISTS(SELECT 1 FROM preplan_aggregate_batches batch
                           WHERE batch.plan_id=plan.id OR batch.anchor_analysis_item_id=source.id)
                FROM production_plans plan
                JOIN production_material_analysis_items source
                  ON source.id=plan.material_analysis_item_id AND source.analysis_id=plan.material_analysis_id
                JOIN production_material_analysis_plan_links link
                  ON link.plan_id=plan.id AND link.analysis_id=source.analysis_id AND link.analysis_item_id=source.id
                WHERE plan.id=:plan AND plan.material_analysis_id=:analysis
                FOR UPDATE OF plan, source, link
                """).setParameter("plan", planId).setParameter("analysis", analysisId));
        if (rows.size() != 1) throw new ApiException(ErrorCode.NOT_FOUND, "当前物料分析没有此生产计划");
        Object[] state = rows.getFirst();
        if ("AGGREGATE_MAKE".equals(state[3]) || Boolean.TRUE.equals(state[4])) {
            throw conflict("共享制造计划须从对应物料行整批撤回，不能绕过全部来源份额");
        }
        int status = ((Number) state[0]).intValue();
        if (status == 0) requirePermission("production_plan:delete", "撤回草稿计划需要生产计划删除权限");
        else requirePermission("production_plan:reverse", "撤回已审核计划需要生产计划红冲权限");

        String hash = CanonicalFingerprint.sha256(List.of(COMMAND_KIND, analysisId.toString(), planId.toString(),
                request.version().toString(), request.fingerprint().toLowerCase(java.util.Locale.ROOT), request.effectiveReason()));
        List<Object[]> replay = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT request_hash, result_payload->>'commandKind', result_payload->>'planId'
                FROM production_material_analysis_commands
                WHERE analysis_id=:analysis AND operation=:operation AND idempotency_key=:key
                """).setParameter("analysis", analysisId).setParameter("operation", OPERATION)
                .setParameter("key", request.idempotencyKey()));
        if (!replay.isEmpty()) {
            Object[] proof = replay.getFirst();
            if (!hash.equals(proof[0]) || !COMMAND_KIND.equals(proof[1]) || !planId.toString().equals(proof[2])) {
                throw conflict("同一防重复提交标识已用于另一项撤回操作，请刷新后重试");
            }
            return analysis.detailInternal(analysisId, false);
        }
        guard.verifyUnchanged();
        analysis.requireCurrent(header, request.version(), request.fingerprint());
        if (Boolean.TRUE.equals(state[1]) || Boolean.TRUE.equals(state[2]) || (status != 0 && status != 1)) {
            throw conflict("生产计划已撤回或不再有效，请按最新资料重新核对");
        }

        if (status == 1) {
            for (UUID packageId : NativeQueryResults.typedRows(em.createNativeQuery("""
                    SELECT id FROM production_planning_packages
                    WHERE plan_id=:plan AND status='CONFIRMED' AND NOT is_deleted
                    ORDER BY id FOR UPDATE
                    """).setParameter("plan", planId), UUID.class)) {
                // Reuse the full execution/inventory reversibility guards. A failure later
                // in plan reversal rolls these package changes back in the same transaction.
                String stepKey = "PLAN-WITHDRAW:" + CanonicalFingerprint.sha256(
                        List.of(request.idempotencyKey(), planId.toString(), packageId.toString()));
                packages.reverse(planId, packageId, new PlanningPackageLifecycleRequest(stepKey, request.effectiveReason()));
            }
            plans.reverse(planId);
        } else {
            plans.delete(planId);
        }
        // The plan lifecycle trigger releases its analysis link and approved/submitted
        // responsibility. The ordinary demand remains, and shared child orders stay intact.
        analysis.refreshLocked(analysisId);
        var payload = mapper.createObjectNode().put("commandKind", COMMAND_KIND).put("planId", planId.toString())
                .put("previousPlanStatus", status).put("reason", request.effectiveReason());
        em.createNativeQuery("""
                INSERT INTO production_material_analysis_commands(
                    analysis_id,operation,idempotency_key,request_hash,result_payload,created_by)
                VALUES(:analysis,:operation,:key,:hash,CAST(:payload AS jsonb),:actor)
                """).setParameter("analysis", analysisId).setParameter("operation", OPERATION)
                .setParameter("key", request.idempotencyKey()).setParameter("hash", hash)
                .setParameter("payload", payload.toString()).setParameter("actor", user.requireId()).executeUpdate();
        return analysis.detailInternal(analysisId, false);
    }

    private void requirePermission(String permission, String message) {
        if (!access.hasAuthority(permission)) throw new ApiException(ErrorCode.FORBIDDEN, message);
    }

    private static void validate(UUID analysisId, UUID planId, PlanWithdrawalRequest request) {
        if (analysisId == null || planId == null || request == null || request.version() == null
                || request.fingerprint() == null || !request.fingerprint().matches("(?i)[0-9a-f]{64}")
                || request.idempotencyKey() == null || !request.idempotencyKey().matches("[A-Za-z0-9._:-]{8,128}")
                || request.reason() == null || request.reason().strip().length() < 2 || request.reason().length() > 500) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "撤回计划缺少版本、防重复提交标识或有效原因");
        }
    }

    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT, message); }
}
