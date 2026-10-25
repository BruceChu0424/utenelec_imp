package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.production.execution.ProductionOverproductionRateService;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/** Exact source-item identity, including shared manufacture anchors, bounds the planning edit. */
@Service
@RequiredArgsConstructor
@Transactional(readOnly=true)
public class MaterialAnalysisOverproductionRateService {
    private final EntityManager em;
    private final MaterialAnalysisService analyses;
    private final ProductionOverproductionRateService rates;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ObjectMapper mapper;

    public List<ProductionOverproductionRateService.PlanningRate> context(UUID analysis,Set<UUID> sources) {
        var result=rates.planningRates(plans(analysis,sources));
        if(analyses.canWriteAnalysis(analysis))return result;
        return result.stream().map(rate->new ProductionOverproductionRateService.PlanningRate(rate.segmentId(),rate.planItemId(),
                rate.planId(),rate.effectiveRate(),rate.rateVersion(),false,"该物料分析仅有查看权限")).toList();
    }

    @Transactional
    public List<ProductionOverproductionRateService.PlanningRate> change(UUID analysis,Set<UUID> sources,
            List<ProductionOverproductionRateService.PlanningRateVersion> expected,
            BigDecimal rate,String key) {
        List<UUID> discovered=plans(analysis,sources);
        analyses.requireWritableAnalysis(analysis);
        tx.bind();
        UUID actor=currentUser.requireId();
        if(key==null || !key.matches("[A-Za-z0-9._:-]{8,128}") || rate==null || expected==null)
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"比例修改缺少当前版本或防重复标识");
        String hash=CanonicalFingerprint.sha256(List.of(analysis.toString(),actor.toString(),
                sources.stream().map(UUID::toString).sorted().toList().toString(),
                expected.stream().map(Object::toString).sorted().toList().toString(),rate.stripTrailingZeros().toPlainString()));
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                .setParameter("key","analysis-rate:"+analysis+":"+key).getSingleResult();
        var replay=NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT request_hash FROM production_material_analysis_commands
                WHERE analysis_id=:analysis AND operation='OVERPRODUCTION_RATE' AND idempotency_key=:key
                """).setParameter("analysis",analysis).setParameter("key",key),String.class);
        if(!replay.isEmpty()) {
            if(!hash.equals(replay.getFirst()))throw new ApiException(ErrorCode.CONFLICT,"同一防重复标识已用于另一项比例修改");
            return rates.planningRates(discovered);
        }
        // beginPlans discovers and locks the complete plan family, including its analysis.
        // A concurrent issue may add another plan before those locks are acquired.
        // Re-read under that shared lock before changing any task, avoiding partial synchronization.
        var result=rates.changePlanningRates(discovered,expected,rate,key,()->{
            analyses.requireWritableAnalysis(analysis);
            if(!discovered.equals(plans(analysis,sources)))
                throw new ApiException(ErrorCode.CONFLICT,"此来源新增或撤回了生产计划，请刷新后重新修改比例");
        });
        em.createNativeQuery("""
                INSERT INTO production_material_analysis_commands(analysis_id,operation,idempotency_key,request_hash,result_payload,created_by)
                VALUES(:analysis,'OVERPRODUCTION_RATE',:key,:hash,CAST(:payload AS jsonb),:actor)
                """).setParameter("analysis",analysis).setParameter("key",key).setParameter("hash",hash)
                .setParameter("payload",mapper.valueToTree(java.util.Map.of("rates",result)).toString()).setParameter("actor",actor).executeUpdate();
        return result;
    }

    private List<UUID> plans(UUID analysis,Set<UUID> sources) {
        analyses.requireReadableAnalysis(analysis);
        if(sources==null || sources.isEmpty() || sources.size()>RequestLimits.DOCUMENT_LINES)
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择1至"+RequestLimits.DOCUMENT_LINES+"个分析来源");
        long found=((Number)em.createNativeQuery("""
                SELECT COUNT(*) FROM production_material_analysis_items
                WHERE analysis_id=:analysis AND id IN (:sources) AND NOT is_deleted
                """).setParameter("analysis",analysis).setParameter("sources",sources).getSingleResult()).longValue();
        if(found!=sources.size())throw new ApiException(ErrorCode.NOT_FOUND,"分析来源不存在或不可见");
        return NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT id FROM (SELECT * FROM production_plans archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('production_plans',archive_origin.id)) production_plans WHERE material_analysis_id=:analysis
                    AND material_analysis_item_id IN (:sources) AND NOT is_deleted
                    AND status IN(0,1) AND NOT is_canceled ORDER BY id
                """).setParameter("analysis",analysis).setParameter("sources",sources),UUID.class);
    }
}
