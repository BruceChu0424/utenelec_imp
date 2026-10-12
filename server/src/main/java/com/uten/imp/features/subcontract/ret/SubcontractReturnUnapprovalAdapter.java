package com.uten.imp.features.subcontract.ret;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class SubcontractReturnUnapprovalAdapter implements DocumentUnapprovalPort {
    private final SubcontractReturnService service;
    @Override public String family() { return "subcontractReturn"; }
    @Override public String permission() { return "subcontract_return"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.SUB_RETURN; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public Eligibility eligibility(UUID id){return service.unapprovalEligibility(id);}
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("subcontract_returns",null,
        List.of("bill_date","supplier_id","warehouse_id","currency_id","exchange_rate","tax_rate","maker_id","last_date","remark","total_original","total_local","source_doc_no","settlement_style_legacy","settlement_method_id"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("subcontract_return_items","return_id",
        List.of("bill_date","receipt_item_id","order_item_id","line_no","goods_id","goods_code_snapshot","goods_name_snapshot","goods_snapshot_source","color_id","unit_id","unit_rate","qty","price","amount_original","amount_local","weight","source_doc_no","girth_qty","step_legacy_id","receipt_no","order_no","remark"),false,true); }
}
