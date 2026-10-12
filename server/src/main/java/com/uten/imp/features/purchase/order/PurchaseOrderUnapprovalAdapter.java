package com.uten.imp.features.purchase.order;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class PurchaseOrderUnapprovalAdapter implements DocumentUnapprovalPort {
    private final PurchaseOrderService service;
    @Override public String family() { return "purchaseOrder"; }
    @Override public String permission() { return "purchase_order"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.PURCHASE_ORDER; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("purchase_orders",null,
        List.of("quantity_semantics","bill_date","supplier_id","warehouse_id","currency_id","exchange_rate","tax_rate","purchaser_id","maker_id","deliver_date","remark","total_original","total_local","settlement_style_legacy","settlement_method_id","source_doc_no"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("purchase_order_items","order_id",
        List.of("quantity_semantics","bill_date","request_item_id","line_no","goods_id","goods_code_snapshot","goods_name_snapshot","goods_snapshot_source","color_id","unit_id","unit_rate","qty","price","total_amount_input","amount_original","amount_local","gift_qty","deliver_date","weight","source_doc_no","sales_order_no","production_plan_no","remark","allowed_over_receipt_pct","extra_columns"),false,true); }
    @Override public List<SourceSnapshot> sources() {
        return List.of(new SourceSnapshot("purchase_order_item_sources","order_item_id",List.of("request_item_id","alloc_qty","allocated_gift_qty","line_no")));
    }
}
