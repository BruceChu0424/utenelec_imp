package com.uten.imp.features.subcontract.material_issue;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class SubcontractMaterialIssueUnapprovalAdapter implements DocumentUnapprovalPort {
    private final SubcontractMaterialIssueService service;
    private final com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService plans;
    private final com.uten.imp.application.port.SubcontractChainNoticePort notices;
    @Override public String family() { return "subcontractMaterialIssue"; }
    @Override public String permission() { return "subcontract_material_issue"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.SUB_MATERIAL_ISSUE; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("subcontract_material_issues",null,
        List.of("bill_date","supplier_id","warehouse_id","worker_id","maker_id","owner_pool","deliver_date","remark","total_original","total_local","source_doc_no"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("subcontract_material_issue_items","issue_id",
        List.of("bill_date","order_item_id","plan_item_id","line_no","goods_id","goods_code_snapshot","goods_name_snapshot","goods_snapshot_source","color_id","unit_id","unit_rate","qty","requested_qty","price","amount_original","amount_local","frozen_unit_qty","parent_goods_id","parent_goods_code_snapshot","parent_goods_name_snapshot","parent_goods_snapshot_source","parent_color_id","weight","qty_from_weight","source_doc_no","box_qty","order_no","remark"),false,true); }
    @Override public void afterDraftCreated(UUID originalId,UUID draftId) {
        plans.reserveDraft(draftId,service.detail(draftId).getWarehouseId());
        notices.notifySubcontractOutboundReady(draftId);
    }
}
