package com.uten.imp.features.subcontract.receipt;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class SubcontractReceiptUnapprovalAdapter implements DocumentUnapprovalPort {
    private final SubcontractReceiptService service;
    @Override public String family() { return "subcontractReceipt"; }
    @Override public String permission() { return "subcontract_receipt"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.SUB_RECEIPT; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public Eligibility eligibility(UUID id){return service.unapprovalEligibility(id);}
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("subcontract_receipts",null,
        List.of("bill_date","supplier_id","warehouse_id","currency_id","exchange_rate","tax_rate","sender_id","maker_id","last_date","remark","total_original","total_local","source_doc_no","settlement_style_legacy","settlement_method_id"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("subcontract_receipt_items","receipt_id",
        List.of("bill_date","order_item_id","line_no","goods_id","goods_code_snapshot","goods_name_snapshot","goods_snapshot_source","color_id","unit_id","unit_rate","qty","replacement_intent","price","amount_original","amount_local","order_qty","weight","source_doc_no","girth_qty","step_legacy_id","order_no","remark"),false,true); }
}
