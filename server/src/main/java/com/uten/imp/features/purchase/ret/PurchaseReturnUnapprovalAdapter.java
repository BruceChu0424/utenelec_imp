package com.uten.imp.features.purchase.ret;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class PurchaseReturnUnapprovalAdapter implements DocumentUnapprovalPort {
    private final PurchaseReturnService service;
    @Override public String family() { return "purchaseReturn"; }
    @Override public String permission() { return "purchase_return"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.PURCHASE_RETURN; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public Eligibility eligibility(UUID id){return service.unapprovalEligibility(id);}
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("purchase_returns",null,
        List.of("quantity_semantics","bill_date","supplier_id","warehouse_id","currency_id","exchange_rate","tax_rate","receiver_id","maker_id","settlement_style_legacy","settlement_method_id","remark","total_original","total_local","source_doc_no"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("purchase_return_items","return_id",
        List.of("quantity_semantics","bill_date","receipt_item_id","order_item_id","line_no","goods_id","goods_code_snapshot","goods_name_snapshot","goods_snapshot_source","color_id","unit_id","unit_rate","qty","gift_qty","price","amount_original","amount_local","weight","source_doc_no","receipt_no","sales_order_no","production_plan_no","order_no","remark"),false,true); }
}
