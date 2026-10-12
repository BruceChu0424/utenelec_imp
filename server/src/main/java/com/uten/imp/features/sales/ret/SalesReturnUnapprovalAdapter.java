package com.uten.imp.features.sales.ret;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class SalesReturnUnapprovalAdapter implements DocumentUnapprovalPort {
    private final SalesReturnService service;
    @Override public String family() { return "salesReturn"; }
    @Override public String permission() { return "sales_return"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.SALES_RETURN; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("sales_returns",null,
        List.of("bill_date","client_id","warehouse_id","currency_id","exchange_rate","tax_rate","payment_style_id","settlement_method_id","seller_id","owner_employee_id","maker_id","last_date","remark","total_original","total_local","source_doc_no","source_shipment_id","return_reason","customer_disposition"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("sales_return_items","return_id",
        List.of("bill_date","out_item_id","order_item_id","line_no","goods_id","goods_code_snapshot","goods_name_snapshot","goods_snapshot_source","color_id","unit_id","unit_rate","qty","price","amount_original","amount_local","cost_amount","weight","client_no","client_model","solution","responsible","discount","source_doc_no","remark"),false,true); }
}
