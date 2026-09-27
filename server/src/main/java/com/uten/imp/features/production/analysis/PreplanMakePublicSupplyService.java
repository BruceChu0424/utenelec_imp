package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.validation.constraints.*;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/** Adopts only unowned planned public output. Claims are promises until a real stock receipt pegs them. */
@Service
@RequiredArgsConstructor
public class PreplanMakePublicSupplyService {
    private final EntityManager em;
    private final SecurityContextCurrentUser user;
    public record ClaimRequest(@NotNull Long version,@NotBlank String fingerprint,@NotBlank @Size(min=8,max=128) String idempotencyKey,
            @NotNull UUID sourcePlanItemId,@NotNull UUID materialLineId,@NotNull @DecimalMin("0.0001") @Digits(integer=14,fraction=4) BigDecimal qty) { }
    public record CancelRequest(@NotNull Long version,@NotBlank String fingerprint,@NotBlank @Size(min=8,max=128) String idempotencyKey,
            @NotNull @DecimalMin("0.0001") @Digits(integer=14,fraction=4) BigDecimal qty,@NotBlank @Size(max=1000) String reason) { }
    public record Candidate(UUID sourcePlanItemId,UUID sourcePlanId,UUID sourceAnalysisId,String documentNo,
            BigDecimal availableQty,LocalDate expectedDate,boolean currentAnalysis,boolean adoptable) { }

    static Map<UUID,List<Candidate>> candidates(EntityManager em,UUID analysisId) {
        return candidates(em,analysisId,ignored->true,null);
    }
    static Map<UUID,List<Candidate>> candidates(EntityManager em,UUID analysisId,java.util.function.Predicate<UUID> readableOwner) {
        return candidates(em,analysisId,readableOwner,null);
    }
    private static Map<UUID,List<Candidate>> candidates(EntityManager em,UUID analysisId,java.util.function.Predicate<UUID> readableOwner,Collection<UUID> targetIds) {
        Map<UUID,List<Candidate>> result=new HashMap<>();
        if(targetIds!=null&&targetIds.isEmpty())return result;
        var query=em.createNativeQuery("""
                SELECT material.id,source.source_plan_item_id,source.source_plan_id,source.source_analysis_id,
                       source.document_no,source.available_to_claim_qty,source.expected_date,plan.maker_id,NOT fn_preplan_make_public_target_is_source(source.source_plan_item_id,material.id)
                FROM production_material_analysis_materials material
                JOIN production_material_analyses analysis ON analysis.id=material.analysis_id
                JOIN fn_preplan_make_public_supply_sources(:analysis) source ON source.goods_id=material.goods_id
                  AND source.color_id IS NOT DISTINCT FROM material.color_id AND source.unit_id=material.unit_id
                  AND fn_warehouse_same_main(source.warehouse_id,analysis.warehouse_id)
                JOIN production_plans plan ON plan.id=source.source_plan_id
                WHERE material.analysis_id=:analysis AND material.active AND source.available_to_claim_qty>0
                """+(targetIds==null?"":" AND material.id IN(:targets)")+
                " ORDER BY source.expected_date NULLS LAST,source.source_plan_item_id,material.id").setParameter("analysis",analysisId);
        if(targetIds!=null)query.setParameter("targets",targetIds);
        for(Object[] row:NativeQueryResults.objectArrayRows(query)) {
            UUID sourceAnalysis=(UUID)row[3];boolean reveal=readableOwner.test((UUID)row[7]);
            result.computeIfAbsent((UUID)row[0],ignored->new ArrayList<>()).add(new Candidate((UUID)row[1],reveal?(UUID)row[2]:null,reveal?sourceAnalysis:null,
                    reveal?(String)row[4]:null,decimal(row[5]),row[6]==null?null:LocalDate.parse(row[6].toString()),analysisId.equals(sourceAnalysis),Boolean.TRUE.equals(row[8])));
        }
        return result;
    }

    static Map<UUID,String> claimedStages(EntityManager em,UUID analysisId) {
        Map<UUID,String> result=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT claim.target_material_id,
                    CASE WHEN SUM(fn_preplan_make_public_claim_pending_qty(claim.id))=0 THEN 'MAKE_COMPLETED'
                         WHEN BOOL_AND(segment.status='COMPLETED') THEN 'MAKE_WAIT_STOCK_IN'
                         WHEN BOOL_OR(segment.status='IN_PROGRESS') THEN 'MAKE_IN_PROGRESS'
                         WHEN BOOL_OR(segment.status IN('READY','DISPATCHED')) THEN 'MAKE_WAITING_DRAW'
                         WHEN BOOL_OR(plan.status=1) THEN 'MAKE_WAITING_MATERIAL'
                         ELSE 'MAKE_PLAN_SUBMITTED' END
                FROM preplan_make_public_claims claim
                JOIN production_plan_items item ON item.id=claim.source_plan_item_id
                JOIN production_plans plan ON plan.id=item.plan_id
                LEFT JOIN production_execution_segments segment ON segment.source_plan_item_id=item.id AND NOT segment.is_deleted
                WHERE claim.target_analysis_id=:analysis AND claim.qty>fn_preplan_make_public_claim_cancelled_qty(claim.id)
                GROUP BY claim.target_material_id
                """).setParameter("analysis",analysisId)))result.put((UUID)row[0],(String)row[1]);
        return result;
    }

    /** Caller already owns the complete commercial/inventory/analysis prefix and has checked authority. */
    Map<UUID,BigDecimal> adoptLocked(UUID analysisId,MaterialAnalysisContracts.AnalysisView view,
            AggregateMaterialOrderContracts.GroupPreview group,String commandKey) {
        Map<UUID,BigDecimal> desired=new HashMap<>();group.sources().forEach(source->desired.put(source.materialLineId(),source.allocatedQty()));
        return adoptLocked(analysisId,desired,Map.of(),commandKey);
    }

    Map<UUID,BigDecimal> adoptLocked(UUID analysisId,Map<UUID,BigDecimal> desired,Map<UUID,BigDecimal> baseQuanta,String commandKey) {
        return adoptLocked(analysisId,desired,baseQuanta,commandKey,ignored->{ });
    }
    Map<UUID,BigDecimal> adoptLocked(UUID analysisId,Map<UUID,BigDecimal> desired,Map<UUID,BigDecimal> baseQuanta,String commandKey,
            java.util.function.Consumer<AggregateMaterialOrderContracts.AdoptedClaim> collector) {
        Map<UUID,List<Candidate>> available=candidates(em,analysisId,ignored->true,desired.entrySet().stream()
                .filter(entry->entry.getValue().signum()>0).map(Map.Entry::getKey).toList());
        Map<UUID,BigDecimal> result=new HashMap<>();
        for(UUID materialId:desired.keySet().stream().sorted(Comparator.comparing(UUID::toString)).toList()) {
            BigDecimal remaining=desired.get(materialId);
            BigDecimal quantum=baseQuanta.getOrDefault(materialId,new BigDecimal("0.0001"));
            for(Candidate candidate:available.getOrDefault(materialId,List.of())) {
                if(!candidate.adoptable()||remaining.signum()==0)continue;
                lockSource(candidate.sourcePlanItemId());
                BigDecimal current=decimal(em.createNativeQuery("SELECT available_to_claim_qty FROM fn_preplan_make_public_supply_sources(NULL::uuid,:id)")
                        .setParameter("id",candidate.sourcePlanItemId()).getSingleResult());
                BigDecimal amount=remaining.min(current).divide(quantum,0,java.math.RoundingMode.DOWN).multiply(quantum);
                if(amount.signum()==0)continue;
                String key="MAKE-CLAIM-"+CanonicalFingerprint.sha256(List.of(commandKey,materialId.toString(),candidate.sourcePlanItemId().toString()));
                UUID claimId=insertClaim(analysisId,materialId,candidate.sourcePlanItemId(),amount,key);
                collector.accept(new AggregateMaterialOrderContracts.AdoptedClaim("MAKE_PUBLIC",claimId,materialId,amount));
                result.merge(materialId,amount,BigDecimal::add);remaining=remaining.subtract(amount);
            }
        }
        return result;
    }

    static BigDecimal baseQuantum(BigDecimal unitRate) {
        BigDecimal rate=unitRate.stripTrailingZeros().setScale(Math.max(0,unitRate.stripTrailingZeros().scale()));
        java.math.BigInteger numerator=rate.unscaledValue(),denominator=java.math.BigInteger.TEN.pow(rate.scale());
        return new BigDecimal(numerator.divide(numerator.gcd(denominator)),4);
    }

    UUID claimLocked(UUID analysisId,UUID materialId,UUID planItemId,BigDecimal qty,String key) {
        lockSource(planItemId);
        Candidate source=candidates(em,analysisId,ignored->true,List.of(materialId)).getOrDefault(materialId,List.of()).stream()
                .filter(candidate->candidate.sourcePlanItemId().equals(planItemId)&&candidate.adoptable()).findFirst()
                .orElseThrow(()->conflict("该自制供给不属于当前物料可采用范围"));
        if(qty.compareTo(source.availableQty())>0)throw conflict("可采用自制供给余量已变化，请刷新后重试");
        return insertClaim(analysisId,materialId,planItemId,qty,key);
    }
    private void lockSource(UUID planItemId) {
        if(em.createNativeQuery("SELECT item.id FROM production_plan_items item JOIN production_plans plan ON plan.id=item.plan_id WHERE item.id=:id AND NOT item.is_deleted AND NOT plan.is_deleted FOR UPDATE OF plan,item")
                .setParameter("id",planItemId).getResultList().isEmpty())throw conflict("公共自制供给已变化，请刷新后重试");
    }
    private UUID insertClaim(UUID analysisId,UUID materialId,UUID planItemId,BigDecimal qty,String key) {
        String hash=CanonicalFingerprint.sha256(List.of(analysisId.toString(),materialId.toString(),planItemId.toString(),qty.stripTrailingZeros().toPlainString()));
        List<Object[]> replay=NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT id,request_hash FROM preplan_make_public_claims WHERE target_analysis_id=:analysis AND idempotency_key=:key")
                .setParameter("analysis",analysisId).setParameter("key",key));
        if(!replay.isEmpty()){if(!hash.equals(replay.getFirst()[1]))throw conflict("相同幂等键不能用于不同自制供给采用意图");return (UUID)replay.getFirst()[0];}
        return (UUID)em.createNativeQuery("""
                INSERT INTO preplan_make_public_claims(source_plan_item_id,target_analysis_id,target_material_id,qty,idempotency_key,request_hash,created_by)
                VALUES(:source,:analysis,:material,:qty,:key,:hash,:actor) RETURNING id
                """).setParameter("source",planItemId).setParameter("analysis",analysisId).setParameter("material",materialId)
                .setParameter("qty",qty).setParameter("key",key).setParameter("hash",hash).setParameter("actor",user.requireId()).getSingleResult();
    }
    void cancelLocked(UUID analysisId,UUID claimId,CancelRequest request) {
        List<Object[]> claims=NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT source_plan_item_id,id FROM preplan_make_public_claims WHERE id=:id AND target_analysis_id=:analysis")
                .setParameter("id",claimId).setParameter("analysis",analysisId));
        if(claims.isEmpty())throw conflict("自制供给采用记录不存在");
        lockSource((UUID)claims.getFirst()[0]);
        String hash=CanonicalFingerprint.sha256(List.of(claimId.toString(),request.qty().stripTrailingZeros().toPlainString(),request.reason()));
        List<?> replay=em.createNativeQuery("SELECT request_hash FROM preplan_make_public_claim_cancellations WHERE claim_id=:id AND idempotency_key=:key")
                .setParameter("id",claimId).setParameter("key",request.idempotencyKey()).getResultList();
        if(!replay.isEmpty()){if(!hash.equals(replay.getFirst()))throw conflict("相同幂等键不能用于不同撤回意图");return;}
        BigDecimal pending=decimal(em.createNativeQuery("SELECT fn_preplan_make_public_claim_pending_qty(:id)").setParameter("id",claimId).getSingleResult());
        if(request.qty().compareTo(pending)>0)throw conflict("只能撤回尚未实收的自制供给采用量");
        em.createNativeQuery("""
                INSERT INTO preplan_make_public_claim_cancellations(claim_id,qty,reason,idempotency_key,request_hash,created_by)
                VALUES(:id,:qty,:reason,:key,:hash,:actor)
                """).setParameter("id",claimId).setParameter("qty",request.qty()).setParameter("reason",request.reason())
                .setParameter("key",request.idempotencyKey()).setParameter("hash",hash).setParameter("actor",user.requireId()).executeUpdate();
    }
    /** Called only after the existing inventory/entitlement cancellation chain safely released this analysis. */
    List<UUID> closeForCancelledAnalysis(UUID analysisId,String commandKey,String reason) {
        List<UUID> closed=new ArrayList<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT claim.id,claim.source_plan_item_id,claim.qty-fn_preplan_make_public_claim_cancelled_qty(claim.id)
                FROM preplan_make_public_claims claim WHERE claim.target_analysis_id=:analysis
                  AND claim.qty>fn_preplan_make_public_claim_cancelled_qty(claim.id)
                ORDER BY claim.source_plan_item_id,claim.id
                """).setParameter("analysis",analysisId))) {
            UUID claim=(UUID)row[0];lockSource((UUID)row[1]);BigDecimal amount=decimal(row[2]);
            String key="MAKE-CLAIM-END-"+CanonicalFingerprint.sha256(List.of(commandKey,claim.toString()));
            String hash=CanonicalFingerprint.sha256(List.of("CANCEL-ANALYSIS",analysisId.toString(),claim.toString(),amount.toPlainString(),reason));
            em.createNativeQuery("""
                    INSERT INTO preplan_make_public_claim_cancellations(claim_id,qty,reason,idempotency_key,request_hash,created_by)
                    VALUES(:id,:qty,:reason,:key,:hash,:actor)
                    """).setParameter("id",claim).setParameter("qty",amount).setParameter("reason",reason)
                    .setParameter("key",key).setParameter("hash",hash).setParameter("actor",user.requireId()).executeUpdate();
            closed.add(claim);
        }
        return List.copyOf(closed);
    }

    private static BigDecimal decimal(Object value){return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static ApiException conflict(String text){return new ApiException(ErrorCode.CONFLICT,text);}
}
