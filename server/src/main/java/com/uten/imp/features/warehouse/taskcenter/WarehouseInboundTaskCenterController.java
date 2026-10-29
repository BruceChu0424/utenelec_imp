package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Filter;
import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Page;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.ExportPasswordRequest;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
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
    private final WarehouseTaskCenterExportService exports;
    private final XlsxExportService xlsxExport;
    private final WorkbookDownloadService workbookDownload;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;
    private final AuditDetailViewRecorder auditViews;

    private static final String VIEW_AUTHORITIES = "hasAnyAuthority('warehouse_inbound:view','warehouse_purchase_receipt_history:view',"
            + "'warehouse_subcontract_receipt_history:view','warehouse_iqc_stock_in:view','warehouse_iqc_return:view','stock_doc:view','workshop_material:view')";

    @GetMapping
    @PreAuthorize(VIEW_AUTHORITIES)
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
                WarehouseTaskCenterContracts.TaskView.requested(view)).withColumnSearch(
                        com.uten.imp.common.util.ColumnKeywordSearch.requestValues(
                                com.uten.imp.common.util.ColumnKeywordSearch.currentRequest())));
    }

    /** 按当前筛选结果导出表格（2026-10-29 用户批注）：与列表同授权同投影，密码走请求体。 */
    @PostMapping("/export")
    @PreAuthorize(VIEW_AUTHORITIES)
    public ResponseEntity<byte[]> export(
            @RequestParam(defaultValue="ALL") String source,
            @RequestParam(defaultValue="ACTIVE") String view,
            @RequestParam(defaultValue="") String status,
            @RequestParam(defaultValue="") String keyword,
            @RequestParam(required=false) String billNo,
            @RequestParam(required=false) @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required=false) @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required=false) UUID scopeWarehouseId,
            @RequestParam(required=false) String sort,
            @RequestParam(required=false) String order,
            @Valid @RequestBody ExportPasswordRequest body) {
        ExportPayload payload = exports.inbound(new Filter(source,status,keyword,billNo,dateFrom,dateTo,scopeWarehouseId,
                1,100,sort,order, WarehouseTaskCenterContracts.TaskView.requested(view)).withColumnSearch(
                        com.uten.imp.common.util.ColumnKeywordSearch.requestValues(
                                com.uten.imp.common.util.ColumnKeywordSearch.currentRequest())));
        byte[] xlsx = xlsxExport.build(payload.columns(), payload.rows(), body.columnProjection(),
                "view_warehouse_task_center");
        byte[] downloadBytes = workbookDownload.protect(xlsx, body.password());
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "export_warehouse_task_center", "warehouse_task_center",
                "inbound/" + payload.total() + "rows", "success"));
        return ResponseEntity.ok()
                .header("Content-Disposition",
                        DownloadContentDisposition.attachment("warehouse_task_center_inbound.xlsx"))
                .header("Content-Type",
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .body(downloadBytes);
    }

    @GetMapping("/{rowKey}/detail")
    @PreAuthorize("hasAnyAuthority('warehouse_inbound:view','warehouse_purchase_receipt_history:view',"
            + "'warehouse_subcontract_receipt_history:view','warehouse_iqc_stock_in:view','warehouse_iqc_return:view','stock_doc:view','workshop_material:view')")
    public Map<String,Object> detail(@PathVariable String rowKey,@RequestParam(required=false) UUID scopeWarehouseId,
                                     @RequestParam(defaultValue="1") int linePage,@RequestParam(defaultValue="50") int lineSize) {
        var request=com.uten.imp.common.util.ColumnKeywordSearch.currentRequest();
        var columns=com.uten.imp.common.util.ColumnKeywordSearch.requestValues(request);
        String sort=request==null?null:request.getParameter("sort"),order=request==null?null:request.getParameter("order");
        Map<String,Object> detail=columns.isEmpty()&&sort==null&&order==null?service.detail(rowKey,scopeWarehouseId,linePage,lineSize)
                :service.detail(rowKey,scopeWarehouseId,linePage,lineSize,columns,sort,order);
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
