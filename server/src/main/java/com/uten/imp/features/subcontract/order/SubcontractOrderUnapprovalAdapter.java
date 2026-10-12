package com.uten.imp.features.subcontract.order;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class SubcontractOrderUnapprovalAdapter implements DocumentUnapprovalPort {
    private final SubcontractOrderService service;
    @Override public String family() { return "subcontractOrder"; }
    @Override public String permission() { return "subcontract_order"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.SUB_ORDER; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("subcontract_orders",null,
        List.of("bill_date","supplier_id","warehouse_id","currency_id","exchange_rate","settlement_method_id","tax_rate","purchaser_id","maker_id","deliver_date","remark","total_original","total_local","source_doc_no"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("subcontract_order_items","order_id",
        List.of("bill_date","line_no","goods_id","goods_code_snapshot","goods_name_snapshot","goods_snapshot_source","color_id","unit_id","unit_rate","qty","price","total_amount_input","amount_original","amount_local","application_item_id","deliver_date","weight","source_doc_no","remark","allowed_loss_pct","extra_columns"),true,true); }
    @Override public List<SourceSnapshot> sources() {
        return List.of(new SourceSnapshot("subcontract_order_item_sources","order_item_id",List.of("application_item_id","alloc_qty","line_no")));
    }
}
