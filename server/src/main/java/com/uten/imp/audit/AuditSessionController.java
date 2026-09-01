package com.uten.imp.audit;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.util.UUID;

/** Independent, lazy audit-session read API. */
@RestController
@RequestMapping("/api/admin/audit-sessions")
@RequiredArgsConstructor
public class AuditSessionController {

    private static final DateTimeFormatter BEIJING_MINUTES =
            DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm");

    private final AuditSessionQueryService queryService;
    private final AuditService auditService;
    private final SecurityContextCurrentUser currentUser;

    @GetMapping
    @PreAuthorize("hasAuthority('audit_log:view')")
    public AuditSessionPageResponse sessions(
            @RequestParam String actorId,
            @RequestParam
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) Long snapshotAuditId) {
        UUID parsedActorId = parseCanonicalUuid(actorId, "人员编号");
        AuditSessionPageResponse response = queryService.sessions(
                parsedActorId, dateFrom, dateTo, page, size, snapshotAuditId);
        logAccess(
                "view_audit_session_list",
                "人员=" + parsedActorId
                        + "；开始日期=" + dateFrom
                        + "；结束日期=" + dateTo
                        + "；页码=" + page
                        + "；本页会话数=" + response.items().size()
                        + "；会话总数=" + response.total()
                        + "；查询快照=" + response.snapshotAuditId(),
                selectedActorDisplay(response, parsedActorId)
                        + " · " + beijingDateRange(dateFrom, dateTo)
                        + " · 第 " + page + " 页（共 " + response.total()
                        + " 次登录）");
        return response;
    }

    @GetMapping("/{sessionId}")
    @PreAuthorize("hasAuthority('audit_log:view')")
    public AuditSessionRow session(
            @PathVariable String sessionId,
            @RequestParam(required = false) Long snapshotAuditId) {
        UUID parsedSessionId = parseCanonicalUuid(sessionId, "登录会话编号");
        AuditSessionRow response = queryService.session(
                parsedSessionId, snapshotAuditId);
        logAccess(
                "view_audit_session_detail",
                "登录会话编号=" + parsedSessionId
                        + "；操作人员=" + response.actorDisplay()
                        + "；会话状态=" + response.statusLabel()
                        + "；操作次数=" + response.operationCount()
                        + "；查询快照=" + response.snapshotAuditId(),
                response.actorDisplay()
                        + " · 登录会话 " + shortReference(parsedSessionId)
                        + " · " + beijingTime(firstKnownActivity(response)));
        return response;
    }

    @GetMapping("/{sessionId}/events")
    @PreAuthorize("hasAuthority('audit_log:view')")
    public AuditSessionEventPageResponse events(
            @PathVariable String sessionId,
            @RequestParam(required = false)
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime cursorAt,
            @RequestParam(required = false) Long cursorId,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) Long snapshotAuditId) {
        UUID parsedSessionId = parseCanonicalUuid(sessionId, "登录会话编号");
        AuditSessionEventPageResponse response = queryService.events(
                parsedSessionId, cursorAt, cursorId, size, snapshotAuditId);
        logAccess(
                "view_audit_session_events",
                "登录会话编号=" + parsedSessionId
                        + "；本次条数=" + response.items().size()
                        + "；是否还有记录=" + (response.hasMore() ? "是" : "否")
                        + "；查询快照=" + response.snapshotAuditId(),
                "登录会话 " + shortReference(parsedSessionId)
                        + " · " + (cursorId == null ? "从最新操作查看" : "继续查看更早操作")
                        + " · 本次 " + response.items().size() + " 条");
        return response;
    }

    private UUID parseCanonicalUuid(String value, String fieldName) {
        try {
            UUID parsed = UUID.fromString(value);
            if (!parsed.toString().equalsIgnoreCase(value)) {
                throw new IllegalArgumentException("non-canonical UUID");
            }
            return parsed;
        } catch (RuntimeException exception) {
            throw new ApiException(
                    ErrorCode.MALFORMED_REQUEST,
                    fieldName + "必须为标准 UUID");
        }
    }

    private void logAccess(
            String action,
            String targetId,
            String viewDisplayName) {
        AuditRequestContext.VerifiedActor verified =
                AuditRequestContext.verifiedActor(AuditRequestContext.currentRequest());
        UUID actorId;
        String actorAccount;
        if (verified != null) {
            actorId = verified.actorId();
            actorAccount = verified.actorAccount();
        } else {
            var investigator = currentUser.get().orElseThrow(
                    () -> new IllegalStateException(
                            "Authenticated audit investigator is missing"));
            actorId = investigator.getId();
            actorAccount = investigator.getLoginAccount();
        }
        auditService.logSuccessfulAuditView(
                actorId,
                actorAccount,
                action,
                "audit_session",
                targetId,
                viewDisplayName);
    }

    private String selectedActorDisplay(
            AuditSessionPageResponse response,
            UUID actorId) {
        return response.items().stream()
                .filter(row -> actorId.equals(row.actorId()))
                .map(AuditSessionRow::actorDisplay)
                .filter(value -> value != null && !value.isBlank())
                .findFirst()
                .orElse("人员编号 " + actorId);
    }

    private String beijingDateRange(LocalDate dateFrom, LocalDate dateTo) {
        return dateFrom.equals(dateTo)
                ? dateFrom + "（北京时间）"
                : dateFrom + " 至 " + dateTo + "（北京时间）";
    }

    private OffsetDateTime firstKnownActivity(AuditSessionRow response) {
        return response.loginAt() != null
                ? response.loginAt()
                : response.firstActivityAt();
    }

    private String beijingTime(OffsetDateTime value) {
        return value == null
                ? "开始时间未记录"
                : value.format(BEIJING_MINUTES) + "（北京时间）";
    }

    private String shortReference(UUID value) {
        return value.toString().substring(0, 8) + "…";
    }
}
