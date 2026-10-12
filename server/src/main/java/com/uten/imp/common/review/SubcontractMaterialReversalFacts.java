package com.uten.imp.common.review;

import jakarta.persistence.EntityManager;
import java.util.UUID;

/** Fixed native inputs for material reversals; returned outside the feature only as a hash. */
public final class SubcontractMaterialReversalFacts {
    private SubcontractMaterialReversalFacts() { }
    public static String read(EntityManager em,String kind,UUID id) {
        String header,items,parent;
        switch(kind) {
            case "ISSUE" -> { header="subcontract_material_issues";items="subcontract_material_issue_items";parent="issue_id"; }
            case "RETURN" -> { header="subcontract_material_returns";items="subcontract_material_return_items";parent="material_return_id"; }
            case "WASTE" -> { header="subcontract_wastes";items="subcontract_waste_items";parent="waste_id"; }
            default -> throw new IllegalArgumentException("Unsupported material family");
        }
        String issueIds="ISSUE".equals(kind)?"SELECT i.id FROM "+items+" i WHERE i."+parent+"=:id"
                :"SELECT i.material_issue_item_id FROM "+items+" i WHERE i."+parent+"=:id";
        String sql="SELECT jsonb_build_object('header',to_jsonb(h),'items',COALESCE((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM "+items+" i WHERE i."+parent+"=h.id),'[]'::jsonb),"
            +"'issues',COALESCE((SELECT jsonb_agg(jsonb_build_object('line',to_jsonb(i),'header',to_jsonb(d)) ORDER BY i.id) FROM subcontract_material_issue_items i JOIN subcontract_material_issues d ON d.id=i.issue_id WHERE i.id IN("+issueIds+")),'[]'::jsonb),"
            +"'plans',COALESCE((SELECT jsonb_agg(jsonb_build_object('line',to_jsonb(p),'header',to_jsonb(d)) ORDER BY p.id) FROM subcontract_material_plan_items p JOIN subcontract_material_plans d ON d.id=p.plan_id WHERE p.order_item_id IN(SELECT i.order_item_id FROM subcontract_material_issue_items i WHERE i.id IN("+issueIds+"))),'[]'::jsonb),"
            +"'receipts',COALESCE((SELECT jsonb_agg(jsonb_build_object('line',to_jsonb(r),'header',to_jsonb(d)) ORDER BY r.id) FROM subcontract_receipt_items r JOIN subcontract_receipts d ON d.id=r.receipt_id WHERE r.order_item_id IN(SELECT i.order_item_id FROM subcontract_material_issue_items i WHERE i.id IN("+issueIds+"))),'[]'::jsonb),"
            +"'stock',COALESCE((SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id) FROM stock_movements m WHERE m.source_doc_id=h.id),'[]'::jsonb),"
            +"'cost',COALESCE((SELECT jsonb_agg(jsonb_build_object('root',to_jsonb(n),'head',to_jsonb(head)) ORDER BY n.id) FROM stock_value_nodes n LEFT JOIN stock_value_nodes head ON head.id=n.return_head_id WHERE n.owner_id IN("+issueIds+") OR n.id IN(SELECT e.result_node_id FROM stock_value_events e WHERE e.source_doc_id=h.id)),'[]'::jsonb),"
            +"'claims',COALESCE((SELECT jsonb_agg(jsonb_build_object('case',to_jsonb(claim),'resolutions',COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.id) FROM subcontract_loss_resolutions r WHERE r.case_id=claim.id),'[]'::jsonb)) ORDER BY claim.id) FROM subcontract_loss_cases claim WHERE claim.waste_id=h.id),'[]'::jsonb))::text FROM "+header+" h WHERE h.id=:id";
        return String.valueOf(em.createNativeQuery(sql).setParameter("id",id).getSingleResult());
    }
}
