package com.uten.imp.features.production;

import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.UUID;

/** The same active planning/production department pool that receives direct preparation tasks. */
@Component
@RequiredArgsConstructor
public class SubcontractDraftPreparationAccessPolicy {
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;

    public boolean inPlanningPool(){
        var actor=currentUser.get().orElse(null);
        if(actor==null||actor.isVisitor()||actor.getEmployeeId()==null
                ||actor.getAuthorities().stream().noneMatch(p->p.getAuthority().equals("production_material_analysis:view")))return false;
        Number matches=(Number)em.createNativeQuery("""
                WITH RECURSIVE departments_in_pool(id) AS (
                    SELECT id FROM departments WHERE code IN('SUB_PLAN','DEPT_PROD') AND is_deleted=FALSE
                    UNION SELECT child.id FROM departments child JOIN departments_in_pool parent ON child.parent_id=parent.id WHERE child.is_deleted=FALSE)
                SELECT count(*) FROM employees employee JOIN users account ON account.employee_id=employee.id
                WHERE account.id=:user AND account.status='active' AND account.is_deleted=FALSE
                  AND employee.is_deleted=FALSE AND employee.status<>'resigned'
                  AND (employee.department_id IN(SELECT id FROM departments_in_pool)
                    OR EXISTS(SELECT 1 FROM employee_secondary_departments secondary WHERE secondary.employee_id=employee.id
                        AND secondary.department_id IN(SELECT id FROM departments_in_pool)))
                """).setParameter("user",actor.getId()).getSingleResult();
        return matches.longValue()==1;
    }

    public boolean canAccess(UUID analysisId){
        if(!inPlanningPool())return false;
        return ((Number)em.createNativeQuery("SELECT count(*) FROM production_material_analyses analysis WHERE analysis.id=:id AND analysis.is_deleted=FALSE AND "+sourcePredicate("analysis.id"))
                .setParameter("id",analysisId).getSingleResult()).longValue()==1;
    }

    public String sourcePredicate(String analysisIdExpression){
        return "EXISTS(SELECT 1 FROM production_material_analysis_items draft_source "
                +"JOIN subcontract_order_items draft_item ON draft_item.id=draft_source.subcontract_order_item_id "
                +"JOIN subcontract_orders draft_order ON draft_order.id=draft_item.order_id "
                +"WHERE draft_source.analysis_id="+analysisIdExpression+" AND draft_source.source_type='SUBCONTRACT_PREPARATION' "
                +"AND draft_source.source_ref='SC-ORDER:'||draft_item.id::text AND draft_source.is_deleted=FALSE "
                +"AND draft_item.is_deleted=FALSE AND draft_order.is_deleted=FALSE)";
    }

    public String readPredicate(String analysisIdExpression,String normal){
        return inPlanningPool()?"("+normal+" OR "+sourcePredicate(analysisIdExpression)+")":normal;
    }
}
