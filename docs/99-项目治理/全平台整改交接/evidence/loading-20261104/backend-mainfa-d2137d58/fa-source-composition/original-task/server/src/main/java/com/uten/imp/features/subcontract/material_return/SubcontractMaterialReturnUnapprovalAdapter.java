package com.uten.imp.features.subcontract.material_return;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class SubcontractMaterialReturnUnapprovalAdapter implements DocumentUnapprovalPort {
    private final SubcontractMaterialReturnService service;
    @Override public String family() { return "subcontractMaterialReturn"; }
    @Override public String permission() { return "subcontract_material_return"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.SUB_MATERIAL_RETURN; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("subcontract_material_returns",null,
        List.of("bill_date","supplier_id","warehouse_id","worker_id","maker_id","b_style","remark","total_original","total_local","source_doc_no"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("subcontract_material_return_items","material_return_id",
        List.of("bill_date","material_issue_item_id","order_item_id","line_no","goods_id","goods_code_snapshot","goods_name_snapshot","goods_snapshot_source","color_id","unit_id","unit_rate","qty","price","amount_original","amount_local","parent_goods_id","parent_goods_code_snapshot","parent_goods_name_snapshot","parent_goods_snapshot_source","parent_color_id","weight","source_doc_no","girth_qty","issue_no","order_no","remark"),false,true); }
}
