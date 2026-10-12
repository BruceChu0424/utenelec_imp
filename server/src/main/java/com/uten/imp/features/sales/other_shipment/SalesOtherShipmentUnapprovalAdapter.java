package com.uten.imp.features.sales.other_shipment;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class SalesOtherShipmentUnapprovalAdapter implements DocumentUnapprovalPort {
    private final SalesOtherShipmentService service;
    @Override public String family() { return "salesOtherShipment"; }
    @Override public String permission() { return "sales_other_shipment"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.SALES_OTHER_SHIPMENT; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public void requireSupported(UUID id) {
        service.detail(id);
        throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.CONFLICT,
            "其他发货仅保留历史核对；新出货请通过销售财务与仓库交接流程办理，不能通用反审生成草稿");
    }
    @Override public TableSnapshot header() { return new TableSnapshot("sales_other_shipments",null,
        List.of("bill_date","client_id","warehouse_id","currency_id","exchange_rate","tax_rate","payment_style_id","settlement_method_id","seller_id","owner_employee_id","sender_id","maker_id","ship_addr","link_phone","parcel_count","out_type","remark","total_original","total_local","source_doc_no","source_order_id"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("sales_other_shipment_items","shipment_id",
        List.of("bill_date","order_item_id","line_no","goods_id","goods_code_snapshot","goods_name_snapshot","goods_snapshot_source","color_id","unit_id","unit_rate","qty","price","amount_original","amount_local","cost_amount","weight","parcel_qty","carton_count","client_no","client_model","material_price","die_cast_price","machining_price","circumference","discount","source_doc_no","remark"),false,true); }
}
