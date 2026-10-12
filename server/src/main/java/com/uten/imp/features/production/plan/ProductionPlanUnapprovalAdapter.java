package com.uten.imp.features.production.plan;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class ProductionPlanUnapprovalAdapter implements DocumentUnapprovalPort {
    private final ProductionPlanService service;
    private final jakarta.persistence.EntityManager em;
    @Override public String family() { return "productionPlan"; }
    @Override public String permission() { return "production_plan"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.PRODUCTION_PLAN; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("production_plans",null,
        List.of("bill_date","f_style","delivery_date","department_id","workshop_name","worker_name","seller_name","seller_id","worker_id","maker_id","remark","is_pinned","is_important","source_doc_no"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("production_plan_items","plan_id",
        List.of("bill_date","line_no","goods_id","color_id","mgoods_id","unit_id","unit_rate","sales_order_item_id","sales_order_no","client_name","client_no","oqty","qty","allowed_overproduction_rate","allowed_overproduction_rate_source","order_date","plan_begin_date","plan_end_date","step_legacy_id","veil_legacy_id","ass_team_legacy_id","fittings","request_note","customer_model","discount","label_no","plan_app_no","source_doc_no","remark"),true,true); }
    @Override public void requireSupported(UUID id) {
        if(Boolean.TRUE.equals(em.createNativeQuery("""
                SELECT material_analysis_id IS NOT NULL OR source_daily_report_id IS NOT NULL
                    OR actual_output_supplement_request_id IS NOT NULL OR auto_generated
                FROM production_plans WHERE id=:id
                """).setParameter("id",id).getSingleResult()))
            throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.CONFLICT,
                "分析计划、补产计划需从来源计划包撤回，不能通用反审重建来源");
    }
    @Override public java.util.Map<String,String> generatedLineInputs() {
        return java.util.Map.of("product_no","fn_allocate_production_product_no(:draft)");
    }
}
