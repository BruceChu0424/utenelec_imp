package com.uten.imp.features.stock;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

@Component
@RequiredArgsConstructor
public class StockDocumentUnapprovalAdapter implements DocumentUnapprovalPort {
    private final StockDocService service;
    @Override public String family() { return "stockDocument"; }
    @Override public String permission() { return "stock_doc"; }
    @Override public Object detail(UUID id) { return service.detail(id); }
    @Override public Eligibility eligibility(UUID id) { return service.unapprovalEligibility(id); }
    @Override public void reverse(UUID id) { service.reverse(id); }
    @Override public void requireSupported(UUID id) {
        var detail=service.detail(id);
        if(detail.isProductionLinked() || detail.isProductionMaterialReturn() || "WDRAW".equals(detail.getDocType()) || "CHECK".equals(detail.getDocType())
                || !"NORMAL".equals(detail.getTransferKind()))
            throw new ApiException(ErrorCode.CONFLICT,
                "生产领退料、成品点收、盘点及不良品专用单据需从来源工作台撤回，不能通用反审");
    }
    @Override public DocNumberPrefix numberPrefix(UUID id) {
        return switch(service.detail(id).getDocType()) {
            case "TRANSFER" -> DocNumberPrefix.STOCK_TRANSFER;
            case "OTHER_IN" -> DocNumberPrefix.STOCK_OTHER_IN;
            case "OTHER_OUT" -> DocNumberPrefix.STOCK_OTHER_OUT;
            case "DRAW" -> DocNumberPrefix.STOCK_DRAW;
            case "WDRAW" -> DocNumberPrefix.STOCK_WDRAW;
            case "FINISHED_IN" -> DocNumberPrefix.STOCK_FINISHED_IN;
            case "FINISHED_OUT" -> DocNumberPrefix.STOCK_FINISHED_OUT;
            case "WASTE" -> DocNumberPrefix.STOCK_WASTE;
            default -> throw new ApiException(ErrorCode.CONFLICT,"该仓库单据没有通用反审入口");
        };
    }
    @Override public TableSnapshot header() {
        return new TableSnapshot("stock_documents",null,List.of("doc_type","bill_date","warehouse_id","to_warehouse_id",
            "transfer_kind","defect_reason","supplier_id","client_id","worker_id","maker_id","ass_team","department_id",
            "plan_no","remark","total_original","total_local","source_doc_no"),true,false);
    }
    @Override public TableSnapshot lines() {
        return new TableSnapshot("stock_document_items","doc_id",List.of("bill_type","bill_date","line_no","goods_id",
            "goods_code_snapshot","goods_name_snapshot","goods_snapshot_source","color_id",
            "unit_id","unit_rate","qty","reported_qty","base_qty","price","amount_original","amount_local","weight",
            "qty_from_weight","gift_qty","place","warehouse_id","upstream_item_id","source_doc_no","remark"),true,true);
    }
}
