package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.util.*;

/** Explicit extra child demand caused by a conserved outbound reallocation. */
final class PreplanReallocationMakeSupplement {
    private final EntityManager em;
    PreplanReallocationMakeSupplement(EntityManager em) { this.em=em; }
    record Allowance(UUID reallocationId,UUID childId,BigDecimal relationQty,BigDecimal childFutureQty) {
        static final Allowance NONE=new Allowance(null,null,BigDecimal.ZERO,BigDecimal.ZERO);
        BigDecimal additional(BigDecimal uncovered,BigDecimal openSupply) {
            return uncovered.subtract(openSupply.max(childFutureQty)).max(BigDecimal.ZERO).min(relationQty);
        }
    }
    Map<UUID,Allowance> read(UUID analysisId) {
        Map<UUID,Allowance> result=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT relation.from_analysis_material_id,relation.id,child.id,
                       LEAST(relation.qty-relation.priority_fulfilled_qty,
                           relation.qty-COALESCE((SELECT SUM(supplement.qty)
                               FROM preplan_reallocation_make_supplements supplement WHERE supplement.reallocation_id=relation.id),0)),
                       CASE WHEN child.source_type='MAKE_COMPONENT' THEN
                           GREATEST(child.requested_qty-COALESCE((SELECT SUM(item.iqty)
                               FROM production_plans plan JOIN production_plan_items item ON item.plan_id=plan.id
                               WHERE plan.material_analysis_item_id=child.id AND plan.status=1
                                 AND NOT plan.is_deleted AND NOT item.is_deleted),0),0)
                       ELSE 0 END
                FROM preplan_material_reallocations relation
                JOIN production_material_analysis_materials material ON material.id=relation.from_analysis_material_id
                JOIN production_material_analysis_items child ON child.parent_analysis_material_id=material.id
                    AND child.analysis_id=relation.from_analysis_id AND NOT child.is_deleted
                WHERE relation.from_analysis_id=:analysisId AND relation.status IN ('OPEN','PARTIAL')
                  AND material.active AND ((material.confirmed_route='MAKE' AND child.source_type='MAKE_COMPONENT')
                    OR (material.confirmed_route='SUBCONTRACT' AND child.source_type='SUBCONTRACT_MAKE'))
                ORDER BY relation.created_at,relation.id
                """).setParameter("analysisId",analysisId))) {
            result.put((UUID)row[0],new Allowance((UUID)row[1],(UUID)row[2],bd(row[3]),bd(row[4])));
        }
        return result;
    }
    Set<UUID> supplementedChildren(UUID analysisId) {
        return Set.copyOf(NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT DISTINCT supplement.child_analysis_item_id
                FROM preplan_reallocation_make_supplements supplement
                JOIN preplan_material_reallocations relation ON relation.id=supplement.reallocation_id
                WHERE relation.from_analysis_id=:analysisId
                """).setParameter("analysisId",analysisId),UUID.class));
    }
    void append(UUID analysisId,UUID materialId,UUID childId,BigDecimal qty,UUID actor) {
        if(qty==null || qty.signum()<=0) return;
        List<Object[]> rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT relation.id,relation.qty-relation.priority_fulfilled_qty,
                       relation.qty-COALESCE((SELECT SUM(supplement.qty) FROM preplan_reallocation_make_supplements supplement
                           WHERE supplement.reallocation_id=relation.id),0),child.requested_qty
                FROM preplan_material_reallocations relation
                JOIN production_material_analysis_items child ON child.id=:childId
                    AND child.parent_analysis_material_id=relation.from_analysis_material_id
                    AND child.analysis_id=relation.from_analysis_id AND NOT child.is_deleted
                WHERE relation.from_analysis_id=:analysisId AND relation.from_analysis_material_id=:materialId
                  AND relation.status IN ('OPEN','PARTIAL')
                FOR UPDATE OF relation,child
                """).setParameter("childId",childId).setParameter("analysisId",analysisId).setParameter("materialId",materialId));
        if(rows.size()!=1 || qty.compareTo(bd(rows.getFirst()[1]).min(bd(rows.getFirst()[2])))>0)
            throw new ApiException(ErrorCode.CONFLICT,"让料补自制额度已变化，请刷新后重试");
        Object[] row=rows.getFirst();BigDecimal before=bd(row[3]);
        em.createNativeQuery("UPDATE production_material_analysis_items SET requested_qty=requested_qty+:qty,updated_by=:actor,updated_at=now() WHERE id=:id")
                .setParameter("qty",qty).setParameter("actor",actor).setParameter("id",childId).executeUpdate();
        em.createNativeQuery("""
                INSERT INTO preplan_reallocation_make_supplements(reallocation_id,source_analysis_material_id,
                    child_analysis_item_id,qty,before_requested_qty,after_requested_qty,created_by)
                VALUES(:relation,:material,:child,:qty,:before,:after,:actor)
                """).setParameter("relation",row[0]).setParameter("material",materialId).setParameter("child",childId)
                .setParameter("qty",qty).setParameter("before",before).setParameter("after",before.add(qty)).setParameter("actor",actor).executeUpdate();
    }
    void recordExistingIncrease(UUID analysisId,UUID materialId,UUID childId,BigDecimal qty,
            BigDecimal before,BigDecimal after,UUID actor) {
        if(qty==null || qty.signum()<=0) return;
        List<UUID> relations=NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT id FROM preplan_material_reallocations
                WHERE from_analysis_id=:analysis AND from_analysis_material_id=:material AND status IN ('OPEN','PARTIAL')
                FOR UPDATE
                """).setParameter("analysis",analysisId).setParameter("material",materialId),UUID.class);
        if(relations.size()!=1) throw new ApiException(ErrorCode.CONFLICT,"让料补供来源已变化，请刷新后重试");
        em.createNativeQuery("""
                INSERT INTO preplan_reallocation_make_supplements(reallocation_id,source_analysis_material_id,
                    child_analysis_item_id,qty,before_requested_qty,after_requested_qty,created_by)
                VALUES(:relation,:material,:child,:qty,:before,:after,:actor)
                """).setParameter("relation",relations.getFirst()).setParameter("material",materialId).setParameter("child",childId)
                .setParameter("qty",qty).setParameter("before",before).setParameter("after",after).setParameter("actor",actor).executeUpdate();
    }
    private static BigDecimal bd(Object value) { return value==null?BigDecimal.ZERO:(BigDecimal)value; }
}
