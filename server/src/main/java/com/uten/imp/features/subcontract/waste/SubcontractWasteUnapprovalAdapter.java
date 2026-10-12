package com.uten.imp.features.subcontract.waste;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class SubcontractWasteUnapprovalAdapter implements DocumentUnapprovalPort {
    private final SubcontractWasteService service;
    @Override public String family() { return "subcontractWaste"; }
    @Override public String permission() { return "subcontract_waste"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.SUB_WASTE; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("subcontract_wastes",null,
        List.of("bill_date","supplier_id","warehouse_id","worker_id","maker_id","total_weight","deduct_amount","remark","total_original","total_local","source_doc_no"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("subcontract_waste_items","waste_id",
        List.of("bill_date","material_issue_item_id","line_no","goods_id","goods_code_snapshot","goods_name_snapshot","goods_snapshot_source","color_id","unit_id","unit_rate","qty","ending_qty","standard_qty","waste_rate","cause","price","amount_original","amount_local","weight","source_doc_no","remark"),false,true); }
}
