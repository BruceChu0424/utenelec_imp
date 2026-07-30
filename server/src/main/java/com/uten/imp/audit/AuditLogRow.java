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
    private final OffsetDateTime createdAt;

    static AuditLogRow of(AuditLog a) {
        return new AuditLogRow(
                a.getId(),
                a.getActorId(),
                a.getActorAccount(),
                a.getAction(),
                a.getTargetType(),
                a.getTargetId(),
                a.getIp(),
                a.getResult(),
                a.getCreatedAt());
    }
}
