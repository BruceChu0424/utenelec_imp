package com.uten.imp.audit;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

@Testcontainers(disabledWithoutDocker = true)
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
        assertFalse(crossMidnight.timelinePartial());

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
}
