package com.uten.imp.audit;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.security.test.context.support.WithMockUser;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@Testcontainers(disabledWithoutDocker = true)
@WithMockUser(authorities = "audit_log:view")
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.MOCK,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.policy-intelligence.enabled=false",
                "uten.jwt.secret=audit-session-query-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=audit-session-query-pgp-key-test-only-0123456789",
                "uten.crypto.hmac-key=audit-session-query-hmac-key-test-only",
                "uten.bootstrap.admin-login=audit-session-bootstrap-admin",
                "uten.bootstrap.admin-password=AuditSessionBootstrapPass-1!"
        })
class AuditSessionQueryPostgresTest {

    @Container
    static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine");

    @DynamicPropertySource
    static void dataSource(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private AuditSessionQueryService sessions;

    @Test
    void groupsCrossMidnightLoginsAndUsesCompositeTimelineCursor() {
        UUID actorId = UUID.randomUUID();
        UUID firstSession = UUID.randomUUID();
        UUID secondSession = UUID.randomUUID();

        insert(actorId, firstSession, "login", "2026-08-29T23:50:00+08:00");
        insert(actorId, firstSession, "view_sales_order_detail",
                "2026-08-30T00:05:00+08:00");
        insert(actorId, firstSession, "logout", "2026-08-30T00:10:00+08:00");
        insert(actorId, firstSession, "http_get", "2026-08-30T00:11:00+08:00");
        insertArchive(actorId, firstSession, "login", "2026-01-01T08:00:00+08:00");
        insert(actorId, secondSession, "login", "2026-08-30T09:00:00+08:00");
        insert(actorId, null, "legacy_without_session", "2026-08-30T10:00:00+08:00");

        AuditSessionPageResponse page = sessions.sessions(
                actorId,
                LocalDate.parse("2026-08-30"),
                LocalDate.parse("2026-08-30"),
                1,
                10,
                null);

        assertEquals(2, page.total());
        assertEquals(secondSession, page.items().get(0).sessionId());
        AuditSessionRow crossMidnight = page.items().get(1);
        assertEquals(firstSession, crossMidnight.sessionId());
        assertEquals(OffsetDateTime.parse("2026-08-29T23:50:00+08:00"),
                crossMidnight.loginAt());
        assertEquals("activity_after_logout", crossMidnight.status());
        assertEquals(1, crossMidnight.postLogoutCount());
        assertTrue(crossMidnight.timelinePartial());
        assertEquals(page.snapshotAuditId(), crossMidnight.snapshotAuditId());

        AuditSessionRow direct = sessions.session(
                firstSession, page.snapshotAuditId());
        assertEquals(firstSession, direct.sessionId());
        assertEquals(crossMidnight.actorId(), direct.actorId());
        assertEquals(crossMidnight.operationCount(), direct.operationCount());
        assertEquals(crossMidnight.lastActivityAt(), direct.lastActivityAt());
        assertEquals(page.snapshotAuditId(), direct.snapshotAuditId());

        AuditSessionEventPageResponse first = sessions.events(
                firstSession, null, null, 2, page.snapshotAuditId());
        assertEquals(2, first.items().size());
        assertEquals("http_get", first.items().get(0).getAction());
        assertEquals("logout", first.items().get(1).getAction());
        assertTrue(first.hasMore());
        assertEquals(first.items().get(1).getCreatedAt(), first.nextCursorAt());
        assertEquals(first.items().get(1).getId(), first.nextCursorId());

        AuditSessionEventPageResponse second = sessions.events(
                firstSession,
                first.nextCursorAt(),
                first.nextCursorId(),
                2,
                page.snapshotAuditId());
        assertEquals(2, second.items().size());
        assertEquals("view_sales_order_detail", second.items().get(0).getAction());
        assertEquals("login", second.items().get(1).getAction());
        assertFalse(second.hasMore());
        assertNull(second.nextCursorAt());
        assertNull(second.nextCursorId());
    }

    @Test
    void rejectsForgedSnapshotsAndDistinguishesMissingArchivedAndNewerSessions() {
        UUID actorId = UUID.randomUUID();
        UUID onlineSession = UUID.randomUUID();
        UUID archivedSession = UUID.randomUUID();
        UUID missingSession = UUID.randomUUID();
        insert(actorId, onlineSession, "login", "2026-08-20T09:00:00+08:00");

        long onlineEventId = jdbc.queryForObject(
                "SELECT id FROM audit_log WHERE session_id = ?",
                Long.class,
                onlineSession);
        long currentHighWater = jdbc.queryForObject(
                "SELECT COALESCE(MAX(id), 0) FROM audit_log",
                Long.class);

        ApiException forgedSnapshot = assertThrows(ApiException.class, () ->
                sessions.session(onlineSession, currentHighWater + 1));
        assertEquals(ErrorCode.MALFORMED_REQUEST, forgedSnapshot.getCode());
        assertTrue(forgedSnapshot.getMessage().contains("超出当前审计范围"));

        ApiException newerThanSnapshot = assertThrows(ApiException.class, () ->
                sessions.session(onlineSession, onlineEventId - 1));
        assertEquals(ErrorCode.CONFLICT, newerThanSnapshot.getCode());
        assertTrue(newerThanSnapshot.getMessage().contains("晚于当前查询快照"));

        ApiException missing = assertThrows(ApiException.class, () ->
                sessions.events(
                        missingSession,
                        null,
                        null,
                        20,
                        currentHighWater));
        assertEquals(ErrorCode.NOT_FOUND, missing.getCode());
        assertEquals("登录会话不存在", missing.getMessage());

        ApiException forgedCursor = assertThrows(ApiException.class, () ->
                sessions.events(
                        onlineSession,
                        OffsetDateTime.parse("2026-08-20T09:00:00+08:00"),
                        currentHighWater + 1,
                        20,
                        currentHighWater));
        assertEquals(ErrorCode.MALFORMED_REQUEST, forgedCursor.getCode());
        assertTrue(forgedCursor.getMessage().contains("不能超过查询快照编号"));

        insertArchive(
                actorId,
                archivedSession,
                "login",
                "2026-02-10T09:00:00+08:00");
        ApiException archived = assertThrows(ApiException.class, () ->
                sessions.session(archivedSession, currentHighWater));
        assertEquals(ErrorCode.NOT_FOUND, archived.getCode());
        assertTrue(archived.getMessage().contains("已转入冷归档"));

        ApiException archivedRange = assertThrows(ApiException.class, () ->
                sessions.sessions(
                        actorId,
                        LocalDate.parse("2026-02-10"),
                        LocalDate.parse("2026-02-10"),
                        1,
                        20,
                        currentHighWater));
        assertEquals(ErrorCode.CONFLICT, archivedRange.getCode());
        assertTrue(archivedRange.getMessage().contains("只提供在线日志"));
    }

    private void insert(
            UUID actorId,
            UUID sessionId,
            String action,
            String createdAt) {
        jdbc.update("""
                        INSERT INTO audit_log(
                            actor_id, actor_account, action, target_type,
                            target_id, result, event_source, session_id, created_at)
                        VALUES (?, 'audit-session-test', ?, 'audit_session_test',
                                ?, 'success', 'business', ?, ?::timestamptz)
                        """,
                actorId,
                action,
                UUID.randomUUID().toString(),
                sessionId,
                createdAt);
    }

    private void insertArchive(
            UUID actorId,
            UUID sessionId,
            String action,
            String createdAt) {
        long archiveId = jdbc.queryForObject("""
                        SELECT GREATEST(
                            COALESCE((SELECT MAX(id) FROM audit_log), 0),
                            COALESCE((SELECT MAX(id) FROM audit_log_archive), 0)) + 1000
                        """,
                Long.class);
        jdbc.update("""
                        INSERT INTO audit_log_archive(
                            id, actor_id, actor_account, action, target_type,
                            target_id, result, event_source, session_id, created_at)
                        VALUES (?, ?, 'audit-session-test', ?, 'audit_session_test',
                                ?, 'success', 'business', ?, ?::timestamptz)
                        """,
                archiveId,
                actorId,
                action,
                UUID.randomUUID().toString(),
                sessionId,
                createdAt);
    }
}
