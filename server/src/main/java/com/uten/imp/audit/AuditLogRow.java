package com.uten.imp.audit;

import lombok.Getter;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 审计日志列表项（管理端只读视图）。
 * <p>不含 before/after（体积大且对列表无意义）、user_agent（噪音大）。ip 保留用于安全审计。
 * <p>actor* / targetName / pageLabel 由查询层填充：把 actor_id 翻译成姓名/部门/职位，
 * 把快照里的业务字段翻译成可读对象名，把 API 路径翻译成页面名。
 */
@Getter
public class AuditLogRow {
    private final Long id;
    private final UUID actorId;
    private final String actorAccount;
    /** 操作人姓名（解析自员工档案；访客/系统任务为空）。 */
    private final String actorName;
    /** 操作人部门名。 */
    private final String actorDepartment;
    /** 操作人职位/岗位名。 */
    private final String actorPosition;
    /** 列表直接展示的"姓名（账号）"。 */
    private final String actorDisplay;
    /** 中文主体类型：人员 / 未识别访问 / 系统任务。 */
    private final String actorType;
    private final String action;
    private final String targetType;
    private final String targetId;
    /** 对象可读名称或单据类型标签；仅从明确的名称/标题字段提取。 */
    private final String targetDisplayName;
    /** 业务编号、单号或账号编码；与名称分开提供。 */
    private final String targetBusinessCode;
    /** 明确记录的旧系统编号；未知时为空，不从其他字段猜测。 */
    private final String targetLegacyCode;
    /** 从快照提取的对象可读名（单据号/名称/编码），取不到为空。 */
    private final String targetName;
    /** 请求路径翻译成的页面名（"哪个页面操作的"）。 */
    private final String pageLabel;
    private final String ip;
    private final String result;
    /** 结果码的中文可读形式（如 密码错误 / 尝试过于频繁（已限流））。 */
    private final String resultLabel;
    private final String actionLabel;
    private final String objectLabel;
    private final String summary;
    /** 脱敏后的中文字段变化摘要；列表关联下钻无需逐条请求详情。 */
    private final String changeSummary;
    private final String riskLevel;
    private final String riskReason;
    private final String eventCategory;
    private final String eventSource;
    private final UUID sessionId;
    private final UUID requestId;
    private final UUID clientEventId;
    private final UUID deviceInstallationId;
    private final String deviceLabel;
    private final String devicePlatform;
    private final Integer statusCode;
    private final Long durationMs;
    private final OffsetDateTime createdAt;

    private AuditLogRow(
            Long id,
            UUID actorId,
            String actorAccount,
            AuditActorDirectory.ActorProfile profile,
            String action,
            String targetType,
            String targetId,
            String targetDisplayName,
            String targetBusinessCode,
            String targetLegacyCode,
            String targetName,
            String pageLabel,
            String ip,
            String result,
            String resultLabel,
            String actionLabel,
            String objectLabel,
            String summary,
            String changeSummary,
            String riskLevel,
            String riskReason,
            String eventCategory,
            String eventSource,
            UUID sessionId,
            UUID requestId,
            UUID clientEventId,
            UUID deviceInstallationId,
            String deviceLabel,
            String devicePlatform,
            Integer statusCode,
            Long durationMs,
            OffsetDateTime createdAt) {
        this.id = id;
        this.actorId = actorId;
        this.actorAccount = actorAccount;
        this.actorName = profile == null ? null : profile.name();
        this.actorDepartment = profile == null ? null : profile.departmentName();
        this.actorPosition = profile == null ? null : profile.positionName();
        AuditActorPresentation.View actor = AuditActorPresentation.of(
                actorId != null,
                actorAccount,
                action,
                eventCategory,
                eventSource,
                profile);
        this.actorDisplay = actor.displayName();
        this.actorType = actor.actorType();
        this.action = action;
        this.targetType = targetType;
        this.targetId = targetId;
        this.targetDisplayName = targetDisplayName;
        this.targetBusinessCode = targetBusinessCode;
        this.targetLegacyCode = targetLegacyCode;
        this.targetName = targetName;
        this.pageLabel = pageLabel;
        this.ip = ip;
        this.result = result;
        this.resultLabel = resultLabel;
        this.actionLabel = actionLabel;
        this.objectLabel = objectLabel;
        this.summary = summary;
        this.changeSummary = changeSummary;
        this.riskLevel = riskLevel;
        this.riskReason = riskReason;
        this.eventCategory = eventCategory;
        this.eventSource = eventSource;
        this.sessionId = sessionId;
        this.requestId = requestId;
        this.clientEventId = clientEventId;
        this.deviceInstallationId = deviceInstallationId;
        this.deviceLabel = deviceLabel;
        this.devicePlatform = devicePlatform;
        this.statusCode = statusCode;
        this.durationMs = durationMs;
        this.createdAt = createdAt;
    }

    static AuditLogRow of(AuditLog a, AuditEventInterpreter interpreter) {
        return of(a, interpreter, null);
    }

    static AuditLogRow of(
            AuditLog a,
            AuditEventInterpreter interpreter,
            AuditActorDirectory.ActorProfile profile) {
        AuditEventInterpreter.InterpretedEvent event = interpreter.interpret(a);
        return new AuditLogRow(
                a.getId(),
                a.getActorId(),
                a.getActorAccount(),
                profile,
                a.getAction(),
                a.getTargetType(),
                a.getTargetId(),
                blankToNull(event.targetDisplayName()),
                blankToNull(event.targetBusinessCode()),
                blankToNull(event.targetLegacyCode()),
                blankToNull(event.targetName()),
                blankToNull(event.pageLabel()),
                a.getIp(),
                a.getResult(),
                event.resultLabel(),
                event.actionLabel(),
                event.objectLabel(),
                event.summary(),
                event.changeSummary(),
                event.riskLevel(),
                event.riskReason(),
                event.category(),
                a.getEventSource(),
                a.getSessionId(),
                a.getRequestId(),
                a.getClientEventId(),
                a.getDeviceInstallationId(),
                AuditDeviceEvidence.from(a).displayLabel(),
                a.getDevicePlatform(),
                a.getStatusCode(),
                a.getDurationMs(),
                a.getCreatedAt());
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value;
    }
}
