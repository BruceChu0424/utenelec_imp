package com.uten.imp.features.production.dailyreport;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Preserve the exact server-owned output slices and material declarations; never split them again. */
@Component
@RequiredArgsConstructor
public class ProductionDailyReportUnapprovalAdapter implements DocumentUnapprovalPort {
    private final ProductionDailyReportService service;
    private final EntityManager em;
    private final SecurityContextCurrentUser user;
    @Override public String family() { return "productionDailyReport"; }
    @Override public String permission() { return "production_daily_report"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.PRODUCTION_DAILY_REPORT; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public void reverse(UUID id) {
        com.uten.imp.common.review.DailyReportApprovalReturnDependencies.requireResolved(em,id);
        service.reverse(id);
    }
    @Override public TableSnapshot header() {
        return new TableSnapshot("production_daily_reports",null,List.of("bill_date","warehouse_id","department_id",
            "workshop_name","worker_id","supplier_id","maker_id","remark","source_doc_no","surplus_return_requested"),true,false);
    }
    @Override public TableSnapshot lines() {
        return new TableSnapshot("production_daily_report_items","report_id",List.of("bill_date","line_no",
            "output_batch_qty","is_public_output","is_actual_surplus","is_over_limit","over_limit_reason","supplement_proof_id",
            "goods_id","color_id","unit_id","unit_rate","qty","defect_qty","sales_order_item_id","sales_order_no","plan_item_id",
            "execution_segment_id","execution_segment_sales_allocation_id","fqc_recovery_authorization_id","is_final","plan_no",
            "outbound_no","outbound_qty","order_qty","step_legacy_id","order_date","boxes","per_box_qty","weight","client_name",
            "source_doc_no","destination","direct_transfer_demand_id","output_route_reason","remark"),false,true);
    }
    @Override public java.util.Map<String,String> generatedLineInputs() {
        // Batch UUIDs own the cross-report first-defect-slice guard. A new report generation needs
        // its own batch identity, while every slice of the same old batch remains grouped together.
        return java.util.Map.of("output_batch_id", "CAST(md5('UNAPPROVAL_OUTPUT_BATCH:' || CAST(:draft AS text)"
                + " || ':' || COALESCE(CAST(source.output_batch_id AS text),CAST(source.id AS text))) AS uuid)");
    }
    @Override public void afterDraftCreated(UUID originalId,UUID draftId) {
        em.createNativeQuery("""
                INSERT INTO production_daily_report_workers(report_id,employee_id,sort_order)
                SELECT :draft,employee_id,sort_order FROM production_daily_report_workers WHERE report_id=:original
                """).setParameter("draft",draftId).setParameter("original",originalId).executeUpdate();
        em.createNativeQuery("""
                INSERT INTO production_daily_report_material_usages(report_id,line_no,plan_id,demand_id,
                    material_execution_segment_id,qty_base,counted_leftover_qty,created_by,updated_by)
                SELECT :draft,line_no,plan_id,demand_id,material_execution_segment_id,qty_base,
                    counted_leftover_qty,created_by,:actor FROM production_daily_report_material_usages WHERE report_id=:original
                """).setParameter("draft",draftId).setParameter("original",originalId).setParameter("actor",user.requireId()).executeUpdate();
        // Existing report reversal releases its claims. The append-only claim guard rejects concurrent reuse.
        em.createNativeQuery("""
                INSERT INTO production_actual_output_supplement_claims(proof_id,report_id,event_type,created_by)
                SELECT DISTINCT supplement_proof_id,:draft,'CLAIM',:actor FROM production_daily_report_items
                WHERE report_id=:draft AND supplement_proof_id IS NOT NULL
                """).setParameter("draft",draftId).setParameter("actor",user.requireId()).executeUpdate();
    }
}
