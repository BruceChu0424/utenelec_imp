package com.uten.imp.features.subcontract.inquiry;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Explicit frozen business inputs; posting/approval/cumulative fields are intentionally omitted. */
@Component
@RequiredArgsConstructor
public class SubcontractInquiryUnapprovalAdapter implements DocumentUnapprovalPort {
    private final SubcontractInquiryService service;
    @Override public String family() { return "subcontractInquiry"; }
    @Override public String permission() { return "subcontract_inquiry"; }
    @Override public DocNumberPrefix numberPrefix(UUID id) { return DocNumberPrefix.SUB_INQUIRY; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public TableSnapshot header() { return new TableSnapshot("subcontract_inquiries",null,
        List.of("bill_date","supplier_id","warehouse_id","currency_id","exchange_rate","maker_id","deliver_date","remark","total_original","total_local","source_doc_no"),true,false); }
    @Override public TableSnapshot lines() { return new TableSnapshot("subcontract_inquiry_items","inquiry_id",
        List.of("bill_date","line_no","goods_id","goods_code_snapshot","goods_name_snapshot","goods_snapshot_source","color_id","unit_id","unit_rate","qty","price","amount_original","amount_local","weight","source_doc_no","remark"),false,true); }
}
