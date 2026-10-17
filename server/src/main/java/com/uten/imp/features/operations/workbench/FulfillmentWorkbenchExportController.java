package com.uten.imp.features.operations.workbench;

import com.uten.imp.application.port.ExportLimitPort;
import com.uten.imp.audit.AuditService;
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
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.Map;

/** Purchase exports share the list's authoritative item projection and document fences. */
@RestController
@RequestMapping("/api/operations/workbench")
@RequiredArgsConstructor
public class FulfillmentWorkbenchExportController {
    private final FulfillmentWorkbenchQueryService queries;
    private final XlsxExportService xlsx;
    private final WorkbookDownloadService downloads;
    private final SecurityContextCurrentUser currentUser;
    private final AuditService audit;
    private final ExportLimitPort exportLimits;

    @PostMapping("/purchase/export")
    @PreAuthorize("hasAuthority('purchase_report:export') and hasAnyAuthority('purchase_request:view','purchase_order:view','purchase_receipt:view','purchase_return:view')")
    public ResponseEntity<byte[]> purchase(
            @RequestParam(defaultValue = "") String status,
            @RequestParam(defaultValue = "") String exception,
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "needDate") String sort,
            @RequestParam(defaultValue = "asc") String order,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate issuedFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate issuedTo,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate needFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate needTo,
            @RequestParam Map<String, String> params,
            @Valid @RequestBody ExportPasswordRequest body) {
        var payload = queries.exportPurchase(status, keyword, exception, dateFrom, dateTo,
                FulfillmentWorkbenchTableQuery.from(sort, order, params, issuedFrom, issuedTo, needFrom, needTo),
                exportLimits.exportMaxRows());
        byte[] bytes = downloads.protect(xlsx.build(payload.columns(), payload.rows(), body.columnProjection(), "view_purchase"),
                body.password());
        currentUser.get().ifPresent(user -> audit.logExplicit(user.getId(), user.getLoginAccount(),
                "export_purchase_tasks", "purchase_workbench", payload.total() + "rows", "success"));
        return ResponseEntity.ok()
                .header("Content-Disposition", DownloadContentDisposition.attachment("purchase_tasks.xlsx"))
                .header("Content-Type", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .body(bytes);
    }
}
