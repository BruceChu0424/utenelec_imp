package com.uten.imp.features.sales.order;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class SalesOrderUnapprovalAdapter implements DocumentUnapprovalPort {
    private final SalesOrderService service;
    private final jakarta.persistence.EntityManager em;
    @Override public String family() { return "salesOrder"; }
    @Override public String permission() { return "sales_order"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.SALES_ORDER; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("sales_orders",null,
        List.of("bill_date","client_id","currency_id","exchange_rate","tax_rate","payment_style_id","settlement_method_id","seller_id","owner_employee_id","maker_id","deliver_date","contract_no","link_phone","sign_addr","ship_addr","remark","total_original","total_local","source_doc_no","shipment_policy","client_file_currency"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("sales_order_items","order_id",
        List.of("bill_date","line_no","goods_id","goods_code_snapshot","goods_name_snapshot","goods_name_en_snapshot","goods_snapshot_source","color_id","unit_id","unit_rate","qty","price","amount_original","amount_local","discount","tax_amount","weight","client_no","client_model","client_goods_name","client_price","deliver_date","source_doc_no","machining_price","circumference","priority","remark","extra_columns"),true,true); }
    @Override public void requireSupported(UUID id) {
        if (Boolean.TRUE.equals(em.createNativeQuery("SELECT source_quote_id IS NOT NULL FROM sales_orders WHERE id=:id")
                .setParameter("id",id).getSingleResult()))
            throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.CONFLICT,
                "报价转入的订单请先按报价重新协商流程修订，反审不能改写已接受报价的转换关系");
    }
}
