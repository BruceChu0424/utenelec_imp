package com.uten.imp.features.master.goods.costing;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.TableColumnProjection;
import com.uten.imp.common.export.ExportDocumentProjectionService;
import com.uten.imp.common.export.TabularPdfExportService;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

@RestController
@RequiredArgsConstructor
public class GoodsCostExportController {
    private final GoodsCostSheetService sheets;
    private final XlsxExportService excel;
    private final TabularPdfExportService pdf;
    private final WorkbookDownloadService protection;
    private final SecurityContextCurrentUser user;
    private final AuditService audit;
    private final ExportDocumentProjectionService projections;

    public record Request(@NotNull UUID sheetId, @NotNull UUID snapshotId,
            @Pattern(regexp = "xlsx|pdf") String format, @Size(max = 128) String password,
            @Pattern(regexp = "ALL|MATERIAL|FEES") String section, @Size(max = 5000) List<String> paths,
            @Valid TableColumnProjection columnProjection) {}

    @PostMapping("/api/master/goods/cost-sheets/export")
    @PreAuthorize("hasAuthority('goods:cost:view') and hasAuthority('goods:cost:export')")
    public ResponseEntity<byte[]> export(@Valid @RequestBody Request request) {
        var snapshot = sheets.exportSnapshot(request.sheetId(), request.snapshotId());
        var document = GoodsCostDocumentMapper.map(snapshot, request.section(), request.paths(), null);
        boolean feeView = request.columnProjection() != null && request.columnProjection().tableKey() != null
                && request.columnProjection().tableKey().endsWith(".fees");
        boolean partial = request.paths() != null && !request.paths().isEmpty();
        String projectedSheet = feeView ? (partial ? "选中物料费用" : "工序与费用") : (partial ? "选中物料" : "物料明细");
        document = projections.project(document, request.columnProjection(), projectedSheet, "view_goods_cost");
        String format = request.format() == null ? "xlsx" : request.format();
        byte[] bytes;
        String contentType;
        if ("xlsx".equals(format)) {
            bytes = protection.protect(excel.buildDocument(document), request.password());
            contentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
        } else if ("pdf".equals(format)) {
            bytes = pdf.build(document, request.password());
            contentType = "application/pdf";
        } else throw new ApiException(ErrorCode.VALIDATION_FAILED, "不支持的下载格式");
        user.get().ifPresent(actor -> audit.logExplicit(actor.getId(), actor.getLoginAccount(), "export_goods_cost",
                "master_data", snapshot.id() + ":" + snapshot.contentDigest() + ":" + format, "success"));
        return ResponseEntity.ok().header("Content-Disposition", DownloadContentDisposition.attachment(
                "cost-" + snapshot.sheetNo() + "-v" + snapshot.sheetVersion() + "." + format))
                .header("Content-Type", contentType).header("X-Cost-Snapshot", snapshot.id().toString())
                .header("X-Cost-Digest", snapshot.contentDigest()).body(bytes);
    }
}
