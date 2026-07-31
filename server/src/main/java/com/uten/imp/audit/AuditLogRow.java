package com.uten.imp.audit;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 审计日志列表项（管理端只读视图）。
 * <p>不含 before/after（体积大且对列表无意义）、user_agent（噪音大）。ip 保留用于安全审计。
 * 字段全部来自 {@link AuditLog}，构造时直接拷贝。
 */
@Getter
@AllArgsConstructor
public class AuditLogRow {
    private final Long id;
    private final UUID actorId;
    private final String actorAccount;
    private final String action;
    private final String targetType;
    private final String targetId;
    private final String ip;
    private final String result;
    private final String actionLabel;
    private final String objectLabel;
    private final String summary;
    private final String riskLevel;
    private final String riskReason;
    private final String eventCategory;
    private final String eventSource;
    private final UUID requestId;
    private final UUID clientEventId;
    private final UUID deviceInstallationId;
    private final String deviceLabel;
    private final String devicePlatform;
    private final Integer statusCode;
    private final Long durationMs;
    private final OffsetDateTime createdAt;

    static AuditLogRow of(AuditLog a, AuditEventInterpreter interpreter) {
        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(a);
        return new AuditLogRow(
                a.getId(),
                a.getActorId(),
                a.getActorAccount(),
                a.getAction(),
                a.getTargetType(),
                a.getTargetId(),
                a.getIp(),
                a.getResult(),
                event.actionLabel(),
                event.objectLabel(),
                event.summary(),
                event.riskLevel(),
                event.riskReason(),
                event.category(),
                a.getEventSource(),
                a.getRequestId(),
                a.getClientEventId(),
                a.getDeviceInstallationId(),
                AuditDeviceEvidence.from(a).displayLabel(),
                a.getDevicePlatform(),
                a.getStatusCode(),
                a.getDurationMs(),
                a.getCreatedAt());
    }
}
