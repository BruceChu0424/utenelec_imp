package com.uten.imp.features.production.report;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.TabularPdfExportService;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Size;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.time.LocalDate;
import java.util.UUID;

@RestController
@RequestMapping("/api/production/reports/where-used")
@RequiredArgsConstructor
public class WhereUsedExportController {
    public record Request(@Size(max = 128) String password, String format) { }
    private final WhereUsedExportService service;
    private final XlsxExportService excel;
    private final TabularPdfExportService pdf;
    private final WorkbookDownloadService protection;
    private final SecurityContextCurrentUser currentUser;
    private final AuditService audit;

    @PostMapping("/export")
    @PreAuthorize("hasAuthority('production_where_used:view') and hasAuthority('production_where_used:export')")
    public ResponseEntity<byte[]> export(@RequestParam UUID materialGoodsId,
            @RequestParam(defaultValue = "all") String source,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String sort, @RequestParam(required = false) String order,
            @Valid @RequestBody Request request) {
        String format = request.format() == null ? "xlsx" : request.format();
        if (!format.equals("xlsx") && !format.equals("pdf"))
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "导出格式只能选择 Excel 或 PDF");
        var document = service.document(materialGoodsId, source, dateFrom, dateTo, sort, order);
        byte[] bytes = format.equals("pdf") ? pdf.build(document, request.password())
                : protection.protect(excel.buildDocument(document), request.password());
        currentUser.get().ifPresent(user -> audit.logExplicit(user.getId(), user.getLoginAccount(),
                "export_where_used", "production_reports", materialGoodsId + "/" + source + "/"
                        + document.sections().getFirst().rows().size() + "rows/" + format, "success"));
        return ResponseEntity.ok().header("Content-Disposition",
                        DownloadContentDisposition.attachment("where_used." + format))
                .header("Content-Type", format.equals("pdf") ? "application/pdf"
                        : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet").body(bytes);
    }
}
