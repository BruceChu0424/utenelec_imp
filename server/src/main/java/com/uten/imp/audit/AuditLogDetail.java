package com.uten.imp.audit;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * Full audit detail guarded by the dedicated audit-log view permission.
 *
 * <p>The list deliberately stays compact; this detail exposes the redacted
 * before/after JSON written by the database audit trigger so a production
 * package, demand, reservation, supply peg, issue, return, report or inbound
 * change can be explained from System Management without querying the
 * database manually.
 *
 * <p>actorName / actorDepartment / actorPosition translate the bare account
 * into "谁（姓名 · 部门 · 职位）"; targetName / pageLabel translate database
 * identifiers and API paths into names an investigator recognizes.
 */
public record AuditLogDetail(
        Long id,
        UUID actorId,
        String actorAccount,
        String actorName,
        String actorDepartment,
        String actorPosition,
        String actorDisplay,
        String actorType,
        String action,
        String targetType,
        String targetId,
        String targetName,
        String pageLabel,
        String before,
        String after,
        String ip,
        String userAgent,
        String result,
        /** 结果码的中文可读形式（如 成功 / 密码错误）。 */
        String resultLabel,
        String actionLabel,
        String objectLabel,
        String summary,
        /** 数据库变更行的逐字段中文变更说明（"状态：待审核 → 已审核；…"）。 */
        String changeSummary,
        String riskLevel,
        String riskReason,
        String eventCategory,
        String eventSource,
        UUID requestId,
        UUID clientEventId,
        AuditDeviceEvidence device,
        String httpMethod,
        String httpPath,
        Integer statusCode,
        Long durationMs,
        OffsetDateTime createdAt) {

    static AuditLogDetail of(AuditLog value, AuditEventInterpreter interpreter) {
        return of(value, interpreter, null);
    }

    static AuditLogDetail of(
            AuditLog value,
            AuditEventInterpreter interpreter,
            AuditActorDirectory.ActorProfile profile) {
        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(value);
        AuditActorPresentation.View actor = AuditActorPresentation.of(value, profile);
        return new AuditLogDetail(
                value.getId(),
                value.getActorId(),
                value.getActorAccount(),
                profile == null ? null : profile.name(),
                profile == null ? null : profile.departmentName(),
                profile == null ? null : profile.positionName(),
                actor.displayName(),
                actor.actorType(),
                value.getAction(),
                value.getTargetType(),
                value.getTargetId(),
                blankToNull(event.targetName()),
                blankToNull(event.pageLabel()),
                value.getBefore(),
                value.getAfter(),
                value.getIp(),
                value.getUserAgent(),
                value.getResult(),
                event.resultLabel(),
                event.actionLabel(),
                event.objectLabel(),
                event.summary(),
                event.changeSummary(),
                event.riskLevel(),
                event.riskReason(),
                event.category(),
                value.getEventSource(),
                value.getRequestId(),
                value.getClientEventId(),
                AuditDeviceEvidence.from(value),
                value.getHttpMethod(),
                value.getHttpPath(),
                value.getStatusCode(),
                value.getDurationMs(),
                value.getCreatedAt());
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value;
    }
}
