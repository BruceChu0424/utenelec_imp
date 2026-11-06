package com.uten.imp.features.purchase.receipt;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class PurchaseReceiptUnapprovalAdapter implements DocumentUnapprovalPort {
    private final PurchaseReceiptService service;
    @Override public String family() { return "purchaseReceipt"; }
    @Override public String permission() { return "purchase_receipt"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.PURCHASE_RECEIPT; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public Eligibility eligibility(UUID id){return service.unapprovalEligibility(id);}
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("purchase_receipts",null,
        List.of("quantity_semantics","bill_date","supplier_id","warehouse_id","currency_id","exchange_rate","tax_rate","sender_id","receiver_id","purchaser_id","maker_id","settlement_style_legacy","settlement_method_id","remark","total_original","total_local","source_doc_no"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("purchase_receipt_items","receipt_id",
        List.of("quantity_semantics","bill_date","order_item_id","line_no","goods_id","goods_code_snapshot","goods_name_snapshot","goods_snapshot_source","color_id","unit_id","unit_rate","qty","replacement_intent","gift_replacement_intent","price","amount_original","amount_local","gift_qty","weight","source_doc_no","order_no","sales_order_no","production_plan_no","remark"),false,true); }
}
