package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.ExportPasswordRequest;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.util.ColumnKeywordSearch;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.UUID;

/** Read-only source union. Every original command keeps its original authorization. */
@RestController
@RequestMapping("/api/warehouse/task-center/outbound")
public class WarehouseOutboundTaskCenterController {
    private final WarehouseOutboundTaskCenterQueryService queries;
    private final WarehouseTaskCenterExportService exports;
    private final XlsxExportService xlsxExport;
    private final WorkbookDownloadService workbookDownload;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;

    public WarehouseOutboundTaskCenterController(WarehouseOutboundTaskCenterQueryService queries,
            WarehouseTaskCenterExportService exports, XlsxExportService xlsxExport,
            WorkbookDownloadService workbookDownload, AuditService audit,
            SecurityContextCurrentUser currentUser) {
        this.queries = queries;
        this.exports = exports;
        this.xlsxExport = xlsxExport;
        this.workbookDownload = workbookDownload;
        this.audit = audit;
        this.currentUser = currentUser;
    }

    private static final String VIEW_AUTHORITIES = "hasAnyAuthority('warehouse_sales_outbound:view','subcontract_outbound:view',"
            + "'warehouse_subcontract_outbound_history:view','stock_doc:view','workshop_material:view')";

    @org.springframework.web.bind.annotation.RequestMapping(method={org.springframework.web.bind.annotation.RequestMethod.GET,org.springframework.web.bind.annotation.RequestMethod.POST})
    @PreAuthorize(VIEW_AUTHORITIES)
    public WarehouseTaskCenterContracts.Page list(
            @RequestParam(defaultValue = "ALL") String source,
            @RequestParam(defaultValue = "ACTIVE") String view,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) UUID scopeWarehouseId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        var filter=new WarehouseTaskCenterContracts.Filter(source, status, keyword, billNo,
                dateFrom, dateTo, scopeWarehouseId, page, size, sort, order,
                WarehouseTaskCenterContracts.TaskView.requested(view)).withColumnSearch(
                        ColumnKeywordSearch.requestValues(ColumnKeywordSearch.currentRequest()));
        if(!com.uten.imp.common.web.PageMetadataRequest.included(com.uten.imp.common.util.ColumnKeywordSearch.currentRequest()))
            return queries.list(filter,false);
        return queries.list(filter);
    }

    /** 按当前筛选结果导出表格（2026-10-29 用户批注）：与列表同授权同投影，密码走请求体。 */
    @com.uten.imp.common.web.JsonBodyLimit(16 * 1024 * 1024)
    @PostMapping("/export")
    @PreAuthorize(VIEW_AUTHORITIES)
    public ResponseEntity<byte[]> export(
            @RequestParam(defaultValue = "ALL") String source,
            @RequestParam(defaultValue = "ACTIVE") String view,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) UUID scopeWarehouseId,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @Valid @RequestBody ExportPasswordRequest body) {
        var workbook = xlsxExport.buildSource(() -> exports.outbound(new WarehouseTaskCenterContracts.Filter(source, status, keyword,
                billNo, dateFrom, dateTo, scopeWarehouseId, 1, 100, sort, order,
                WarehouseTaskCenterContracts.TaskView.requested(view)).withColumnSearch(
                        ColumnKeywordSearch.requestValues(ColumnKeywordSearch.currentRequest()))),
                body.columnProjection(), "view_warehouse_task_center");
        ExportPayload payload = workbook.payload();
        byte[] downloadBytes = workbookDownload.protect(workbook.bytes(), body.password());
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "export_warehouse_task_center", "warehouse_task_center",
                "outbound/" + payload.total() + "rows", "success"));
        return ResponseEntity.ok()
                .header("Content-Disposition",
                        DownloadContentDisposition.attachment("warehouse_task_center_outbound.xlsx"))
                .header("Content-Type",
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .body(downloadBytes);
    }

    @GetMapping("/{rowKey}/detail")
    @PreAuthorize(VIEW_AUTHORITIES)
    public WarehouseOutboundTaskCenterQueryService.PhysicalDetail detail(
            @PathVariable String rowKey,
            @RequestParam(required = false) UUID scopeWarehouseId,
            @RequestParam(defaultValue = "1") int linePage,
            @RequestParam(defaultValue = "100") int lineSize) {
        var request=ColumnKeywordSearch.currentRequest();
        var columns=ColumnKeywordSearch.requestValues(request);
        String sort=request==null?null:request.getParameter("sort"),order=request==null?null:request.getParameter("order");
        return columns.isEmpty()&&sort==null&&order==null?queries.detail(rowKey,scopeWarehouseId,linePage,lineSize)
                :queries.detail(rowKey,scopeWarehouseId,linePage,lineSize,columns,sort,order);
    }
}
