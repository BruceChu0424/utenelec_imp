package com.uten.imp.audit;

import com.uten.imp.common.export.WorkbookDownloadService;
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
    private final WorkbookDownloadService workbookDownload;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;

    /**
     * 分页查询审计日志（按 createdAt DESC, id DESC）。
     *
     * @param action      动作前缀模糊匹配（如 "export" 命中所有 export_*_report）
     * @param actorAccount 操作人账号子串模糊（不区分大小写）
     * @param dateFrom    起始日期（含，ISO yyyy-MM-dd）
     * @param dateTo      截止日期（含，ISO yyyy-MM-dd）
     */
    @GetMapping
    @PreAuthorize("hasAuthority('audit_log:view')")
    public AuditPageResponse list(
            @RequestParam(required = false) String action,
            @RequestParam(required = false) String actorAccount,
            @RequestParam(required = false) String actorId,
            @RequestParam(required = false) String actorScope,
            @RequestParam(required = false) String riskLevel,
            @RequestParam(required = false) String eventCategory,
            @RequestParam(required = false) String outcome,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String targetType,
            @RequestParam(required = false) String targetId,
            @RequestParam(required = false) String eventSource,
            @RequestParam(required = false) String requestId,
            @RequestParam(required = false) String operationKind,
            @RequestParam(required = false) Long snapshotId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "true") boolean activityOnly,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        AuditPageResponse result = auditQuery.query(validated(new AuditSearchCriteria(
                action, actorAccount, actorScope, riskLevel, eventCategory, outcome,
                keyword, targetType, targetId, eventSource, requestId, operationKind,
                dateFrom, dateTo, snapshotId, parseOptionalActorId(actorId), activityOnly)),
                page, size);
        logAuditAccess(
                "view_audit_log_list",
                investigationScope(
                        actorId, dateFrom, dateTo, page,
                        result.getItems().size(), result.getTotal())
                        + filterScope(
                        action, operationKind, actorScope, targetType, riskLevel, outcome,
                        eventCategory, eventSource, keyword, targetId, requestId,
                        snapshotId, activityOnly));
        return result;
    }

    /** Overview cards and seven-day risk trend for the same date/actor scope. */
    @GetMapping("/summary")
    @PreAuthorize("hasAuthority('audit_log:view')")
    public AuditSummary summary(
            @RequestParam(required = false) String action,
            @RequestParam(required = false) String actorAccount,
            @RequestParam(required = false) String actorId,
            @RequestParam(required = false) String actorScope,
            @RequestParam(required = false) String eventCategory,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String targetType,
            @RequestParam(required = false) String targetId,
            @RequestParam(required = false) String eventSource,
            @RequestParam(required = false) String requestId,
            @RequestParam(required = false) String operationKind,
            @RequestParam(required = false) Long snapshotId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "true") boolean activityOnly) {
        AuditSummary result = auditQuery.summary(validated(new AuditSearchCriteria(
                action, actorAccount, actorScope, null, eventCategory, null,
                keyword, targetType, targetId, eventSource, requestId, operationKind,
                dateFrom, dateTo, snapshotId, parseOptionalActorId(actorId), activityOnly)));
        logAuditAccess(
                "view_audit_log_summary",
                investigationScope(actorId, dateFrom, dateTo, null, null, result.total())
                        + "；风险条数=" + result.riskCount()
                        + filterScope(
                        action, operationKind, actorScope, targetType, null, null,
                        eventCategory, eventSource, keyword, targetId, requestId,
                        snapshotId, activityOnly));
        return result;
    }

    /** UUID-authoritative people picker; typing in it is intentionally not audited. */
    @GetMapping("/actors")
    @PreAuthorize("hasAuthority('audit_log:view')")
    public PageResponse<AuditActorOption> actors(
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return auditQuery.actors(keyword, page, size);
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
            @RequestParam(required = false) String actorId,
            @RequestParam(required = false) String actorScope,
            @RequestParam(required = false) String riskLevel,
            @RequestParam(required = false) String eventCategory,
            @RequestParam(required = false) String outcome,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String targetType,
            @RequestParam(required = false) String targetId,
            @RequestParam(required = false) String eventSource,
            @RequestParam(required = false) String requestId,
            @RequestParam(required = false) String operationKind,
            @RequestParam(required = false) Long snapshotId,
            @RequestParam(required = false)
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false)
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "true") boolean activityOnly,
            @Valid @RequestBody ExportPasswordRequest body) {
        ExportPayload payload = auditQuery.export(validated(new AuditSearchCriteria(
                action, actorAccount, actorScope, riskLevel, eventCategory, outcome,
                keyword, targetType, targetId, eventSource, requestId, operationKind,
                dateFrom, dateTo, snapshotId, parseOptionalActorId(actorId), activityOnly)),
                runtimeSettings.exportMaxRows());
        byte[] workbook = xlsxExport.build(payload.columns(), payload.rows());
        byte[] downloadBytes = workbookDownload.protect(workbook, body.password());
        logAuditAccess(
                "export_audit_log",
                exportScope(payload.total(), actorId, dateFrom, dateTo, riskLevel)
                        + filterScope(
                        action, operationKind, actorScope, targetType, riskLevel, outcome,
                        eventCategory, eventSource, keyword, targetId, requestId,
                        snapshotId, activityOnly));
        String filename = "审计日志-" + BusinessTime.today() + ".xlsx";
        return ResponseEntity.ok()
                .header(
                        "Content-Disposition",
                        DownloadContentDisposition.attachment(filename))
                .header(
                        "Content-Type",
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .body(downloadBytes);
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
        logAuditAccess(
                "view_audit_log_detail",
                "审计日志编号=" + id
                        + "；原操作关联编号=" + safe(result.requestId())
                        + "；原操作人编号=" + safe(result.actorId()));
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
        return parseCanonicalUuid(value, "本机操作编号");
    }

    private UUID parseOptionalActorId(String value) {
        return value == null || value.isBlank()
                ? null
                : parseCanonicalUuid(value, "人员编号");
    }

    private UUID parseCanonicalUuid(String value, String fieldName) {
        try {
            UUID parsed = UUID.fromString(value);
            if (!parsed.toString().equalsIgnoreCase(value)) {
                throw new IllegalArgumentException("non-canonical UUID");
            }
            return parsed;
        } catch (IllegalArgumentException exception) {
            throw new ApiException(
                    ErrorCode.MALFORMED_REQUEST,
                    fieldName + " 必须为标准 UUID");
        }
    }

    private String exportScope(
            int rows,
            String actorId,
            LocalDate dateFrom,
            LocalDate dateTo,
            String riskLevel) {
        return "导出条数=" + rows
                + "；人员=" + safe(actorId)
                + "；开始日期=" + safe(dateFrom)
                + "；结束日期=" + safe(dateTo)
                + "；风险=" + riskScopeLabel(riskLevel);
    }

    private String investigationScope(
            String actorId,
            LocalDate dateFrom,
            LocalDate dateTo,
            Integer page,
            Integer returned,
            long total) {
        String value = "人员=" + safe(actorId)
                + "；开始日期=" + safe(dateFrom)
                + "；结束日期=" + safe(dateTo);
        if (page != null) {
            value += "；页码=" + page;
        }
        if (returned != null) {
            value += "；本页条数=" + returned;
        }
        return value + "；总条数=" + total;
    }

    private String safe(Object value) {
        return value == null || value.toString().isBlank() ? "全部" : value.toString();
    }

    private String riskScopeLabel(String value) {
        return switch (value == null ? "" : value.trim().toLowerCase()) {
            case "critical" -> "严重";
            case "high" -> "高";
            case "medium" -> "中";
            case "low" -> "低";
            case "risky" -> "有风险";
            default -> "全部";
        };
    }

    private AuditSearchCriteria validated(AuditSearchCriteria criteria) {
        AuditQueryService.validateFilterValues(criteria);
        return criteria;
    }

    private String filterScope(
            String action,
            String operationKind,
            String actorScope,
            String targetType,
            String riskLevel,
            String outcome,
            String eventCategory,
            String eventSource,
            String keyword,
            String targetId,
            String requestId,
            Long snapshotId,
            boolean activityOnly) {
        return "；动作=" + usedFilter(action)
                + "；操作类型=" + operationScopeLabel(operationKind)
                + "；人员范围=" + actorScopeLabel(actorScope)
                + "；业务对象=" + usedFilter(targetType)
                + "；风险=" + riskScopeLabel(riskLevel)
                + "；结果=" + outcomeScopeLabel(outcome)
                + "；事件类型=" + categoryScopeLabel(eventCategory)
                + "；记录来源=" + sourceScopeLabel(eventSource)
                + "；关键字=" + usageLabel(keyword)
                + "；对象编号=" + usageLabel(targetId)
                + "；操作关联编号=" + usageLabel(requestId)
                + "；查询快照=" + safe(snapshotId)
                + "；视图=" + (activityOnly ? "仅人员活动" : "含数据库变化");
    }

    private String usedFilter(String value) {
        return value == null || value.isBlank() ? "全部" : "已筛选";
    }

    private String usageLabel(String value) {
        return value == null || value.isBlank() ? "未使用" : "已使用";
    }

    private String operationScopeLabel(String value) {
        return switch (value == null ? "" : value.trim().toLowerCase()) {
            case "create" -> "新增";
            case "update" -> "修改";
            case "delete" -> "删除";
            case "write" -> "写操作";
            case "read" -> "查看";
            default -> "全部";
        };
    }

    private String actorScopeLabel(String value) {
        return switch (value == null ? "" : value.trim().toLowerCase()) {
            case "user" -> "指定人员";
            case "anonymous" -> "未识别访问";
            case "system" -> "系统异常";
            default -> "全部";
        };
    }

    private String outcomeScopeLabel(String value) {
        return switch (value == null ? "" : value.trim().toLowerCase()) {
            case "success" -> "成功";
            case "failure" -> "失败";
            default -> "全部";
        };
    }

    private String categoryScopeLabel(String value) {
        return switch (value == null ? "" : value.trim().toLowerCase()) {
            case "security" -> "安全事件";
            case "authorization" -> "权限变更";
            case "authentication" -> "登录认证";
            case "export" -> "数据导出";
            case "data_change" -> "数据变化";
            case "system" -> "系统设置";
            case "business" -> "业务操作";
            default -> "全部";
        };
    }

    private String sourceScopeLabel(String value) {
        return switch (value == null ? "" : value.trim().toLowerCase()) {
            case "request" -> "页面操作";
            case "database" -> "数据变化明细";
            case "security" -> "安全拦截";
            case "business" -> "业务事件";
            default -> "全部";
        };
    }
}
