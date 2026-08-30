package com.uten.imp.audit;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.sql.Timestamp;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZonedDateTime;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;

/**
 * Read-only server-side session grouping for the audit center.
 *
 * <p>The date range selects sessions with activity in that Beijing-calendar
 * interval. Once a session is selected, its complete known timeline is grouped
 * across midnight, bounded only by the returned high-water audit ID.
 */
@Service
public class AuditSessionQueryService {

    static final int MAX_SESSION_PAGE_SIZE = 20;
    static final int MAX_EVENT_PAGE_SIZE = 100;
    static final int MAX_DATE_RANGE_DAYS = 31;

    private final EntityManager entityManager;
    private final AuditActorDirectory actorDirectory;
    private final AuditEventInterpreter eventInterpreter;

    public AuditSessionQueryService(
            EntityManager entityManager,
            AuditActorDirectory actorDirectory,
            AuditEventInterpreter eventInterpreter) {
        this.entityManager = entityManager;
        this.actorDirectory = actorDirectory;
        this.eventInterpreter = eventInterpreter;
    }

    @Transactional(readOnly = true)
    public AuditSessionPageResponse sessions(
            UUID actorId,
            LocalDate dateFrom,
            LocalDate dateTo,
            int page,
            int size,
            Long requestedSnapshotAuditId) {
        validateSessionScope(actorId, dateFrom, dateTo, page, size);
        long snapshotAuditId = snapshot(requestedSnapshotAuditId);
        OffsetDateTime from = BusinessTime.startOfDay(dateFrom);
        OffsetDateTime toExclusive = BusinessTime.startOfDay(dateTo.plusDays(1));

        long total = sessionCount(actorId, from, toExclusive, snapshotAuditId);
        if (total == 0) {
            return new AuditSessionPageResponse(
                    List.of(), page, size, 0, 0, snapshotAuditId);
        }

        Query query = entityManager.createNativeQuery(SESSION_PAGE_SQL);
        bindSessionScope(query, actorId, from, toExclusive, snapshotAuditId);
        query.setFirstResult(offset(page, size));
        query.setMaxResults(size);

        List<SessionAggregate> aggregates = new ArrayList<>();
        for (Object raw : query.getResultList()) {
            aggregates.add(toAggregate((Object[]) raw));
        }

        Set<UUID> actorIds = new LinkedHashSet<>();
        Set<String> actorAccounts = new LinkedHashSet<>();
        for (SessionAggregate value : aggregates) {
            if (value.actorId() != null) {
                actorIds.add(value.actorId());
            }
            if (value.actorAccount() != null && !value.actorAccount().isBlank()) {
                actorAccounts.add(value.actorAccount());
            }
        }
        AuditActorDirectory.Resolution actors = actorDirectory.resolve(
                actorIds, actorAccounts);
        List<AuditSessionRow> items = aggregates.stream()
                .map(value -> toRow(value, actors))
                .toList();
        int totalPages = (int) ((total + size - 1) / size);
        return new AuditSessionPageResponse(
                items, page, size, total, totalPages, snapshotAuditId);
    }

    @Transactional(readOnly = true)
    public AuditSessionEventPageResponse events(
            UUID sessionId,
            OffsetDateTime cursorAt,
            Long cursorId,
            int size,
            Long requestedSnapshotAuditId) {
        validateEventScope(
                sessionId, cursorAt, cursorId, size, requestedSnapshotAuditId);
        long snapshotAuditId = snapshot(requestedSnapshotAuditId);
        boolean firstPage = cursorAt == null;
        var query = entityManager.createQuery(
                firstPage ? SESSION_EVENTS_FIRST_JPQL : SESSION_EVENTS_AFTER_JPQL,
                AuditLog.class);
        query.setParameter("sessionId", sessionId);
        query.setParameter("snapshotAuditId", snapshotAuditId);
        if (!firstPage) {
            query.setParameter("cursorAt", cursorAt);
            query.setParameter("cursorId", cursorId);
        }
        query.setMaxResults(size + 1);

        List<AuditLog> rawRows = query.getResultList();
        boolean hasMore = rawRows.size() > size;
        int returned = Math.min(size, rawRows.size());
        List<AuditLog> logs = List.copyOf(rawRows.subList(0, returned));
        AuditActorDirectory.Resolution actors = actorDirectory.resolve(
                AuditActorDirectory.actorIdsOf(logs),
                AuditActorDirectory.actorAccountsOf(logs));
        List<AuditLogRow> items = logs.stream()
                .map(log -> AuditLogRow.of(
                        log,
                        eventInterpreter,
                        actors.forActor(log.getActorId(), log.getActorAccount())))
                .toList();
        AuditLogRow last = hasMore && !items.isEmpty()
                ? items.get(items.size() - 1)
                : null;
        return new AuditSessionEventPageResponse(
                List.copyOf(items),
                size,
                last == null ? null : last.getCreatedAt(),
                last == null ? null : last.getId(),
                hasMore,
                snapshotAuditId);
    }

    static void validateSessionScope(
            UUID actorId,
            LocalDate dateFrom,
            LocalDate dateTo,
            int page,
            int size) {
        if (actorId == null) {
            throw malformed("必须先选择人员");
        }
        if (dateFrom == null || dateTo == null) {
            throw malformed("必须选择完整的开始日期和结束日期");
        }
        if (dateTo.isBefore(dateFrom)) {
            throw malformed("结束日期不能早于开始日期");
        }
        long inclusiveDays = Duration.between(
                BusinessTime.startOfDayInstant(dateFrom),
                BusinessTime.startOfDayInstant(dateTo.plusDays(1))).toDays();
        if (inclusiveDays > MAX_DATE_RANGE_DAYS) {
            throw malformed("查询日期范围不能超过31天");
        }
        if (page < 1) {
            throw malformed("页码必须大于等于1");
        }
        if (size < 1 || size > MAX_SESSION_PAGE_SIZE) {
            throw malformed("每页条数必须在1到20之间");
        }
        offset(page, size);
    }

    static void validateEventScope(
            UUID sessionId,
            OffsetDateTime cursorAt,
            Long cursorId,
            int size,
            Long snapshotAuditId) {
        if (sessionId == null) {
            throw malformed("登录会话编号不能为空");
        }
        if ((cursorAt == null) != (cursorId == null)) {
            throw malformed("事件时间游标和事件编号游标必须同时提供");
        }
        if (cursorId != null && cursorId < 1) {
            throw malformed("事件游标必须为正整数");
        }
        if (snapshotAuditId != null && snapshotAuditId < 0) {
            throw malformed("查询快照编号不能为负数");
        }
        if (size < 1 || size > MAX_EVENT_PAGE_SIZE) {
            throw malformed("每次加载条数必须在1到100之间");
        }
    }

    private long sessionCount(
            UUID actorId,
            OffsetDateTime from,
            OffsetDateTime toExclusive,
            long snapshotAuditId) {
        Query query = entityManager.createNativeQuery(SESSION_COUNT_SQL);
        bindSessionScope(query, actorId, from, toExclusive, snapshotAuditId);
        return ((Number) query.getSingleResult()).longValue();
    }

    private void bindSessionScope(
            Query query,
            UUID actorId,
            OffsetDateTime from,
            OffsetDateTime toExclusive,
            long snapshotAuditId) {
        query.setParameter("actorId", actorId);
        query.setParameter("dateFrom", from);
        query.setParameter("dateToExclusive", toExclusive);
        query.setParameter("snapshotAuditId", snapshotAuditId);
    }

    private long snapshot(Long requested) {
        if (requested != null) {
            if (requested < 0) {
                throw malformed("查询快照编号不能为负数");
            }
            return requested;
        }
        Object value = entityManager.createNativeQuery(
                "SELECT COALESCE(MAX(id), 0) FROM audit_log")
                .getSingleResult();
        return ((Number) value).longValue();
    }

    private SessionAggregate toAggregate(Object[] row) {
        return new SessionAggregate(
                toUuid(row[0]),
                toUuid(row[1]),
                toText(row[2]),
                toText(row[3]),
                toBeijingTime(row[4]),
                toBeijingTime(row[5]),
                toBeijingTime(row[6]),
                toBeijingTime(row[7]),
                toLong(row[8]),
                toLong(row[9]),
                toLong(row[10]),
                toLong(row[11]),
                toLong(row[12]),
                toLong(row[13]),
                toUuid(row[14]),
                toText(row[15]),
                toText(row[16]),
                toText(row[17]),
                toText(row[18]),
                toBeijingTime(row[19]),
                toBeijingTime(row[20]));
    }

    private AuditSessionRow toRow(
            SessionAggregate value,
            AuditActorDirectory.Resolution actors) {
        AuditActorDirectory.ActorProfile profile = actors.forActor(
                value.actorId(), value.actorAccount());
        String actorDisplay = profile == null
                ? fallbackActorDisplay(value.actorId(), value.actorAccount())
                : blankToFallback(profile.displayName(),
                fallbackActorDisplay(value.actorId(), value.actorAccount()));
        String status = sessionStatus(value);
        String credentialStatus = credentialStatus(value);
        return new AuditSessionRow(
                value.sessionId(),
                value.actorId(),
                value.actorAccount(),
                actorDisplay,
                profile == null ? null : profile.departmentName(),
                profile == null ? null : profile.positionName(),
                value.startAction(),
                startLabel(value.startAction()),
                value.loginAt(),
                value.firstActivityAt(),
                value.lastActivityAt(),
                value.logoutAt(),
                status,
                statusLabel(status),
                value.eventCount(),
                value.operationCount(),
                value.successCount(),
                value.failureCount(),
                value.postLogoutCount(),
                value.deviceInstallationId(),
                deviceLabel(value.deviceName(), value.deviceModel(), value.devicePlatform()),
                value.devicePlatform(),
                value.lastIp(),
                value.refreshExpiresAt(),
                value.refreshRevokedAt(),
                credentialStatus,
                credentialStatusLabel(credentialStatus),
                false);
    }

    private String sessionStatus(SessionAggregate value) {
        return statusForEvidence(
                value.postLogoutCount(),
                value.securityTerminationCount(),
                value.logoutAt());
    }

    static String statusForEvidence(
            long postLogoutCount,
            long securityTerminationCount,
            OffsetDateTime logoutAt) {
        if (postLogoutCount > 0) {
            return "activity_after_logout";
        }
        if (securityTerminationCount > 0) {
            return "security_terminated";
        }
        if (logoutAt != null) {
            return "normal_logout";
        }
        return "no_logout_record";
    }

    static String statusLabel(String status) {
        return switch (status) {
            case "activity_after_logout" -> "退出后仍有活动";
            case "security_terminated" -> "安全终止";
            case "normal_logout" -> "正常退出";
            default -> "未记录退出";
        };
    }

    private String credentialStatus(SessionAggregate value) {
        if (value.refreshExpiresAt() == null && value.refreshRevokedAt() == null) {
            return "no_record";
        }
        if (value.refreshRevokedAt() != null) {
            return "revoked";
        }
        if (value.refreshExpiresAt() != null
                && !value.refreshExpiresAt().isAfter(
                OffsetDateTime.now(BusinessTime.ZONE))) {
            return "expired";
        }
        if (value.refreshExpiresAt() != null) {
            return "not_expired";
        }
        return "unknown";
    }

    private String credentialStatusLabel(String status) {
        return switch (status) {
            case "revoked" -> "刷新凭证已撤销";
            case "expired" -> "刷新凭证已过期";
            case "not_expired" -> "刷新凭证尚未到期";
            case "no_record" -> "未记录刷新凭证";
            default -> "刷新凭证状态未知";
        };
    }

    private String startLabel(String action) {
        return switch (normalize(action)) {
            case "login" -> "员工登录";
            case "visitor_login" -> "访客登录";
            case "session_start_after_password_change" -> "修改密码后建立新会话";
            default -> "会话起点未记录";
        };
    }

    private String deviceLabel(String name, String model, String platform) {
        if (notBlank(name) && notBlank(model) && !name.equalsIgnoreCase(model)) {
            return name + " · " + model;
        }
        if (notBlank(name)) {
            return name;
        }
        if (notBlank(model)) {
            return model;
        }
        return notBlank(platform) ? platform : "未提供设备信息";
    }

    private String fallbackActorDisplay(UUID actorId, String account) {
        if (notBlank(account)) {
            return account;
        }
        return actorId == null ? "未识别人员" : actorId.toString();
    }

    private String blankToFallback(String value, String fallback) {
        return notBlank(value) ? value : fallback;
    }

    private static int offset(int page, int size) {
        long offset = (long) (page - 1) * size;
        if (offset > Integer.MAX_VALUE) {
            throw malformed("页码超出可查询范围");
        }
        return (int) offset;
    }

    private static ApiException malformed(String message) {
        return new ApiException(ErrorCode.MALFORMED_REQUEST, message);
    }

    private static String normalize(String value) {
        return value == null ? "" : value.trim().toLowerCase(Locale.ROOT);
    }

    private static boolean notBlank(String value) {
        return value != null && !value.isBlank();
    }

    private static long toLong(Object value) {
        return value == null ? 0 : ((Number) value).longValue();
    }

    private static String toText(Object value) {
        return value == null ? null : value.toString();
    }

    private static UUID toUuid(Object value) {
        if (value instanceof UUID uuid) {
            return uuid;
        }
        if (value == null) {
            return null;
        }
        try {
            return UUID.fromString(value.toString());
        } catch (IllegalArgumentException ignored) {
            return null;
        }
    }

    private static OffsetDateTime toBeijingTime(Object value) {
        if (value == null) {
            return null;
        }
        Instant instant;
        if (value instanceof OffsetDateTime offset) {
            instant = offset.toInstant();
        } else if (value instanceof ZonedDateTime zoned) {
            instant = zoned.toInstant();
        } else if (value instanceof Timestamp timestamp) {
            instant = timestamp.toInstant();
        } else if (value instanceof Instant parsed) {
            instant = parsed;
        } else if (value instanceof LocalDateTime local) {
            instant = local.atZone(BusinessTime.ZONE).toInstant();
        } else {
            instant = OffsetDateTime.parse(value.toString()).toInstant();
        }
        return instant.atZone(BusinessTime.ZONE).toOffsetDateTime();
    }

    private record SessionAggregate(
            UUID sessionId,
            UUID actorId,
            String actorAccount,
            String startAction,
            OffsetDateTime loginAt,
            OffsetDateTime firstActivityAt,
            OffsetDateTime lastActivityAt,
            OffsetDateTime logoutAt,
            long eventCount,
            long operationCount,
            long successCount,
            long failureCount,
            long securityTerminationCount,
            long postLogoutCount,
            UUID deviceInstallationId,
            String deviceName,
            String deviceModel,
            String devicePlatform,
            String lastIp,
            OffsetDateTime refreshExpiresAt,
            OffsetDateTime refreshRevokedAt) {
    }

    private static final String SESSION_SCOPE = """
            a.session_id IS NOT NULL
            AND a.actor_id = :actorId
            AND a.created_at >= :dateFrom
            AND a.created_at < :dateToExclusive
            AND a.id <= :snapshotAuditId
            AND LOWER(COALESCE(a.event_source, '')) <> 'database'
            """;

    private static final String SESSION_COUNT_SQL = """
            SELECT COUNT(DISTINCT a.session_id)
            FROM audit_log a
            WHERE
            """ + SESSION_SCOPE;

    private static final String SESSION_PAGE_SQL = """
            WITH matched_sessions AS (
                SELECT DISTINCT a.session_id
                FROM audit_log a
                WHERE
                """ + SESSION_SCOPE + """
            ),
            session_events AS (
                SELECT a.*
                FROM audit_log a
                JOIN matched_sessions matched ON matched.session_id = a.session_id
                WHERE a.id <= :snapshotAuditId
                  AND LOWER(COALESCE(a.event_source, '')) <> 'database'
            ),
            logout_event AS (
                SELECT DISTINCT ON (event.session_id)
                       event.session_id,
                       event.created_at AS logout_at,
                       event.id AS logout_id
                FROM session_events event
                WHERE event.action IN ('logout', 'visitor_logout')
                ORDER BY event.session_id, event.created_at, event.id
            ),
            token_rows AS (
                SELECT token.session_id,
                       token.id AS token_id,
                       token.issued_at,
                       token.expires_at,
                       token.revoked_at
                FROM refresh_tokens token
                WHERE token.session_id IS NOT NULL
                UNION ALL
                SELECT token.session_id,
                       token.id AS token_id,
                       token.issued_at,
                       token.expires_at,
                       token.revoked_at
                FROM visitor_refresh_tokens token
                WHERE token.session_id IS NOT NULL
            ),
            latest_token AS (
                SELECT DISTINCT ON (token.session_id)
                       token.session_id,
                       token.expires_at,
                       token.revoked_at
                FROM token_rows token
                JOIN matched_sessions matched ON matched.session_id = token.session_id
                ORDER BY token.session_id, token.issued_at DESC, token.token_id DESC
            ),
            grouped AS (
                SELECT event.session_id,
                       (array_agg(event.actor_id ORDER BY event.created_at DESC, event.id DESC)
                           FILTER (WHERE event.actor_id IS NOT NULL))[1] AS actor_id,
                       (array_agg(event.actor_account ORDER BY event.created_at DESC, event.id DESC)
                           FILTER (WHERE event.actor_account IS NOT NULL
                               AND BTRIM(event.actor_account) <> ''))[1] AS actor_account,
                       (array_agg(event.action ORDER BY event.created_at, event.id)
                           FILTER (WHERE event.action IN (
                               'login', 'visitor_login',
                               'session_start_after_password_change')))[1] AS start_action,
                       MIN(event.created_at) FILTER (
                           WHERE event.action IN (
                               'login', 'visitor_login',
                               'session_start_after_password_change')) AS login_at,
                       MIN(event.created_at) AS first_activity_at,
                       MAX(event.created_at) AS last_activity_at,
                       logout.logout_at,
                       COUNT(*) AS event_count,
                       COUNT(*) FILTER (
                           WHERE event.action NOT IN (
                               'login', 'visitor_login',
                               'session_start_after_password_change',
                               'logout', 'visitor_logout')) AS operation_count,
                       COUNT(*) FILTER (
                           WHERE LOWER(COALESCE(event.result, '')) = 'success'
                             AND COALESCE(event.status_code, 0) < 400) AS success_count,
                       COUNT(*) FILTER (
                           WHERE LOWER(COALESCE(event.result, '')) IN (
                               'failure', 'failed', 'denied', 'bad_password',
                               'bad_credentials', 'account_not_found',
                               'account_locked', 'account_locked_by_admin',
                               'account_disabled', 'rate_limited', 'invalid',
                               'invalid_phone', 'expired',
                               'temporary_password_expired',
                               'remote_access_denied', 'unauthorized',
                               'visitor_blocked', 'is_employee',
                               'token_not_found', 'missing_token',
                               'reuse_detected')
                              OR RIGHT(COALESCE(event.action, ''), 7) = '_failed'
                              OR COALESCE(event.status_code, 0) >= 400) AS failure_count,
                       COUNT(*) FILTER (
                           WHERE event.action IN ('refresh_reuse', 'visitor_refresh_reuse'))
                           AS security_termination_count,
                       COUNT(*) FILTER (
                           WHERE logout.logout_at IS NOT NULL
                             AND event.action NOT IN ('logout', 'visitor_logout')
                             AND (event.created_at > logout.logout_at
                               OR (event.created_at = logout.logout_at
                                 AND event.id > logout.logout_id))) AS post_logout_count,
                       (array_agg(event.device_installation_id
                           ORDER BY event.created_at DESC, event.id DESC)
                           FILTER (WHERE event.device_installation_id IS NOT NULL))[1]
                           AS device_installation_id,
                       (array_agg(event.device_name ORDER BY event.created_at DESC, event.id DESC)
                           FILTER (WHERE event.device_name IS NOT NULL
                               AND BTRIM(event.device_name) <> ''))[1] AS device_name,
                       (array_agg(event.device_model ORDER BY event.created_at DESC, event.id DESC)
                           FILTER (WHERE event.device_model IS NOT NULL
                               AND BTRIM(event.device_model) <> ''))[1] AS device_model,
                       (array_agg(event.device_platform ORDER BY event.created_at DESC, event.id DESC)
                           FILTER (WHERE event.device_platform IS NOT NULL
                               AND BTRIM(event.device_platform) <> ''))[1] AS device_platform,
                       (array_agg(event.ip ORDER BY event.created_at DESC, event.id DESC)
                           FILTER (WHERE event.ip IS NOT NULL AND BTRIM(event.ip) <> ''))[1]
                           AS last_ip
                FROM session_events event
                LEFT JOIN logout_event logout ON logout.session_id = event.session_id
                GROUP BY event.session_id, logout.logout_at, logout.logout_id
            )
            SELECT grouped.session_id,
                   grouped.actor_id,
                   grouped.actor_account,
                   grouped.start_action,
                   grouped.login_at,
                   grouped.first_activity_at,
                   grouped.last_activity_at,
                   grouped.logout_at,
                   grouped.event_count,
                   grouped.operation_count,
                   grouped.success_count,
                   grouped.failure_count,
                   grouped.security_termination_count,
                   grouped.post_logout_count,
                   grouped.device_installation_id,
                   grouped.device_name,
                   grouped.device_model,
                   grouped.device_platform,
                   grouped.last_ip,
                   token.expires_at AS refresh_expires_at,
                   token.revoked_at AS refresh_revoked_at
            FROM grouped
            LEFT JOIN latest_token token ON token.session_id = grouped.session_id
            ORDER BY COALESCE(grouped.login_at, grouped.first_activity_at) DESC,
                     grouped.session_id DESC
            """;

    private static final String SESSION_EVENTS_FIRST_JPQL = """
            SELECT a
            FROM AuditLog a
            WHERE a.sessionId = :sessionId
              AND a.id <= :snapshotAuditId
              AND LOWER(COALESCE(a.eventSource, '')) <> 'database'
            ORDER BY a.createdAt DESC, a.id DESC
            """;

    private static final String SESSION_EVENTS_AFTER_JPQL = """
            SELECT a
            FROM AuditLog a
            WHERE a.sessionId = :sessionId
              AND a.id <= :snapshotAuditId
              AND (a.createdAt < :cursorAt
                OR (a.createdAt = :cursorAt AND a.id < :cursorId))
              AND LOWER(COALESCE(a.eventSource, '')) <> 'database'
            ORDER BY a.createdAt DESC, a.id DESC
            """;
}
