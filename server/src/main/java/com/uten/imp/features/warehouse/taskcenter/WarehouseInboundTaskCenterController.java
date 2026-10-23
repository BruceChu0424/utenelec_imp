package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Filter;
import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Page;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.UUID;
import java.util.Map;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Row;

@RestController
@RequestMapping("/api/warehouse/task-center/inbound")
@RequiredArgsConstructor
public class WarehouseInboundTaskCenterController {
    private final WarehouseInboundTaskCenterQueryService service;
    private final AuditDetailViewRecorder auditViews;

    @GetMapping
    @PreAuthorize("hasAnyAuthority('warehouse_inbound:view','warehouse_purchase_receipt_history:view',"
            + "'warehouse_subcontract_receipt_history:view','warehouse_iqc_stock_in:view','warehouse_iqc_return:view','stock_doc:view','workshop_material:view')")
    public Page list(@RequestParam(defaultValue="ALL") String source,
                     @RequestParam(defaultValue="ACTIVE") String view,
                     @RequestParam(defaultValue="") String status,
                     @RequestParam(defaultValue="") String keyword,
                     @RequestParam(required=false) String billNo,
                     @RequestParam(required=false) @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate dateFrom,
                     @RequestParam(required=false) @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate dateTo,
                     @RequestParam(required=false) UUID scopeWarehouseId,
                     @RequestParam(required=false) String sort,
                     @RequestParam(required=false) String order,
                     @RequestParam(defaultValue="1") int page,
                     @RequestParam(defaultValue="30") int size) {
        return service.list(new Filter(source,status,keyword,billNo,dateFrom,dateTo,scopeWarehouseId,page,size,sort,order,
                WarehouseTaskCenterContracts.TaskView.requested(view)));
    }

    @GetMapping("/{rowKey}/detail")
    @PreAuthorize("hasAnyAuthority('warehouse_inbound:view','warehouse_purchase_receipt_history:view',"
            + "'warehouse_subcontract_receipt_history:view','warehouse_iqc_stock_in:view','warehouse_iqc_return:view','stock_doc:view','workshop_material:view')")
    public Map<String,Object> detail(@PathVariable String rowKey,@RequestParam(required=false) UUID scopeWarehouseId,
                                     @RequestParam(defaultValue="1") int linePage,@RequestParam(defaultValue="50") int lineSize) {
        Map<String,Object> detail=service.detail(rowKey,scopeWarehouseId,linePage,lineSize);
        Row row=(Row)detail.get("row");
        String table=switch(row.recordType()) {
            case "WORKSHOP_REQUISITION"->"workshop_material_requisitions";
            case "EXPECTATION"->"inbound_expectations";
            case "ARRIVAL_EXCEPTION"->"procurement_arrival_exceptions";
            case "PURCHASE_RECEIPT"->"purchase_receipts";
            case "SUBCONTRACT_RECEIPT"->"subcontract_receipts";
            case "FINISHED_REGISTRATION"->"production_finished_arrival_registrations";
            case "FINISHED_REGISTER"->"production_daily_reports";
            default->"stock_documents";
        };
        String action=switch(row.recordType()) {
            case "EXPECTATION"->"view_warehouse_inbound_expectation_detail";
            case "ARRIVAL_EXCEPTION"->"view_procurement_arrival_exception_detail";
            case "PURCHASE_RECEIPT"->"view_purchase_receipt_detail";
            case "SUBCONTRACT_RECEIPT"->"view_subcontract_receipt_detail";
            case "STOCK_DOCUMENT","FINISHED_COUNT"->"view_stock_document_detail";
            case "FINISHED_REGISTER"->"view_production_daily_report_detail";
            default->"view_production_finished_arrival_registration_detail";
        };
        auditViews.record(action,table,row.id(),row.billNo(),null,"仓库入库记录");
        return detail;
    }
}
