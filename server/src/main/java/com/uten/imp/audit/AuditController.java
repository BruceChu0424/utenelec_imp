package com.uten.imp.audit;

import com.uten.imp.common.export.EncryptedWorkbookService;
import com.uten.imp.common.export.ExportPasswordRequest;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
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

/**
 * 审计日志查看（管理端读侧）。
 * <p>仅持有 {@code audit_log:view} 的核查人员可读取；导出还须额外持有
 * {@code audit_log:export}。权限默认不授予普通部门或普通用户。
 * <p>写侧：导出报表 / 登录 / 改密等事件由 {@link AuditService#logExplicit} 落库；
 * 数据变更由 audit_log 触发器写入。
 */
@RestController
@RequestMapping("/api/admin/audit-logs")
@RequiredArgsConstructor
public class AuditController {

    private final AuditQueryService auditQuery;
    private final AuditRuntimeSettings runtimeSettings;
    private final XlsxExportService xlsxExport;
    private final EncryptedWorkbookService encryptedWorkbook;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;

    /**
     * 分页查询审计日志（按 createdAt DESC）。
     *
     * @param action      动作前缀模糊匹配（如 "export" 命中所有 export_*_report）
     * @param actorAccount 操作人账号子串模糊（不区分大小写）
     * @param dateFrom    起始日期（含，ISO yyyy-MM-dd）
     * @param dateTo      截止日期（含，ISO yyyy-MM-dd）
     */
    @GetMapping
    @PreAuthorize("hasAuthority('audit_log:view')")
    public PageResponse<AuditLogRow> list(
            @RequestParam(required = false) String action,
            @RequestParam(required = false) String actorAccount,
            @RequestParam(required = false) String riskLevel,
            @RequestParam(required = false) String eventCategory,
            @RequestParam(required = false) String outcome,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        PageResponse<AuditLogRow> result = auditQuery.query(
                action,
                actorAccount,
                riskLevel,
                eventCategory,
                outcome,
                dateFrom,
                dateTo,
                page,
                size);
        logAuditAccess(
                "view_audit_log_list",
                "returned=" + result.getItems().size() + "; total=" + result.getTotal());
        return result;
    }

    /** Overview cards and seven-day risk trend for the same date/actor scope. */
    @GetMapping("/summary")
    @PreAuthorize("hasAuthority('audit_log:view')")
    public AuditSummary summary(
            @RequestParam(required = false) String action,
            @RequestParam(required = false) String actorAccount,
            @RequestParam(required = false) String eventCategory,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo) {
        AuditSummary result = auditQuery.summary(
                action, actorAccount, eventCategory, dateFrom, dateTo);
        logAuditAccess(
                "view_audit_log_summary",
                "total=" + result.total() + "; risk=" + result.riskCount());
        return result;
    }

    /**
     * Password-encrypted Excel export of the current online filters.
     * Raw before/after snapshots remain detail-only and are not bulk exported.
     */
    @PostMapping("/export")
    @PreAuthorize("hasAuthority('audit_log:view')"
            + " and hasAuthority('audit_log:export')")
    public ResponseEntity<byte[]> export(
            @RequestParam(required = false) String action,
            @RequestParam(required = false) String actorAccount,
            @RequestParam(required = false) String riskLevel,
            @RequestParam(required = false) String eventCategory,
            @RequestParam(required = false) String outcome,
            @RequestParam(required = false)
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false)
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @Valid @RequestBody ExportPasswordRequest body) {
        ExportPayload payload = auditQuery.export(
                action,
                actorAccount,
                riskLevel,
                eventCategory,
                outcome,
                dateFrom,
                dateTo,
                runtimeSettings.exportMaxRows());
        byte[] workbook = xlsxExport.build(payload.columns(), payload.rows());
        byte[] encrypted = encryptedWorkbook.encrypt(workbook, body.password());
        logAuditAccess(
                "export_audit_log",
                exportScope(payload.total(), dateFrom, dateTo, riskLevel));
        String filename = "audit-logs-" + BusinessTime.today() + ".xlsx";
        return ResponseEntity.ok()
                .header(
                        "Content-Disposition",
                        DownloadContentDisposition.attachment(filename))
                .header(
                        "Content-Type",
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .body(encrypted);
    }

    /** Records that an investigator checked this event against its local device receipt. */
    @PostMapping("/local-receipt-verifications/{clientEventId}")
    @PreAuthorize("hasAuthority('audit_log:view')")
    public ResponseEntity<Void> verifyLocalReceipt(@PathVariable String clientEventId) {
        UUID parsedClientEventId = parseCanonicalUuid(clientEventId);
        logAuditAccess(
                "verify_local_audit_receipt",
                parsedClientEventId.toString());
        return ResponseEntity.noContent().build();
    }

    /** Full redacted before/after payload for one row; never exposed in list. */
    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('audit_log:view')")
    public AuditLogDetail detail(@PathVariable long id) {
        AuditLogDetail result = auditQuery.detail(id);
        logAuditAccess("view_audit_log_detail", Long.toString(id));
        return result;
    }

    private void logAuditAccess(String action, String targetId) {
        var user = currentUser.get().orElseThrow(
                () -> new IllegalStateException("Authenticated audit investigator is missing"));
        audit.logExplicit(
                user.getId(),
                user.getLoginAccount(),
                action,
                "audit_log",
                targetId,
                "success");
    }

    private UUID parseCanonicalUuid(String value) {
        try {
            UUID parsed = UUID.fromString(value);
            if (!parsed.toString().equalsIgnoreCase(value)) {
                throw new IllegalArgumentException("non-canonical UUID");
            }
            return parsed;
        } catch (IllegalArgumentException exception) {
            throw new ApiException(
                    ErrorCode.MALFORMED_REQUEST,
                    "clientEventId 必须为标准 UUID");
        }
    }

    private String exportScope(
            int rows,
            LocalDate dateFrom,
            LocalDate dateTo,
            String riskLevel) {
        return "rows=" + rows
                + "; dateFrom=" + safe(dateFrom)
                + "; dateTo=" + safe(dateTo)
                + "; risk=" + safe(riskLevel);
    }

    private String safe(Object value) {
        return value == null ? "all" : value.toString();
    }
}
