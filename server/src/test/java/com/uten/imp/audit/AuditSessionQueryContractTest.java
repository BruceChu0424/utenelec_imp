package com.uten.imp.audit;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.Arrays;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class AuditSessionQueryContractTest {

    private static final Path SOURCE_ROOT = Path.of("src/main/java/com/uten/imp/audit");

    @Test
    void listScopeRequiresOneActorCompleteBeijingRangeAndSmallPage() {
        UUID actorId = UUID.randomUUID();
        assertDoesNotThrow(() -> AuditSessionQueryService.validateSessionScope(
                actorId,
                LocalDate.of(2026, 8, 1),
                LocalDate.of(2026, 8, 31),
                1,
                20));

        assertThrows(ApiException.class, () ->
                AuditSessionQueryService.validateSessionScope(
                        null,
                        LocalDate.of(2026, 8, 1),
                        LocalDate.of(2026, 8, 1),
                        1,
                        20));
        assertThrows(ApiException.class, () ->
                AuditSessionQueryService.validateSessionScope(
                        actorId,
                        LocalDate.of(2026, 8, 1),
                        LocalDate.of(2026, 9, 1),
                        1,
                        20));
        assertThrows(ApiException.class, () ->
                AuditSessionQueryService.validateSessionScope(
                        actorId,
                        LocalDate.of(2026, 8, 1),
                        LocalDate.of(2026, 8, 1),
                        1,
                        21));
        assertThrows(ApiException.class, () ->
                AuditSessionQueryService.validateSessionScope(
                        actorId,
                        LocalDate.MAX,
                        LocalDate.MAX,
                        1,
                        20));
    }

    @Test
    void statusUsesOnlyRecordedEvidenceAndFlagsPostLogoutActivityFirst() {
        OffsetDateTime logoutAt = OffsetDateTime.parse("2026-08-01T08:00:00+08:00");
        assertEquals(
                "activity_after_logout",
                AuditSessionQueryService.statusForEvidence(1, 1, logoutAt));
        assertEquals(
                "security_terminated",
                AuditSessionQueryService.statusForEvidence(0, 1, logoutAt));
        assertEquals(
                "normal_logout",
                AuditSessionQueryService.statusForEvidence(0, 0, logoutAt));
        assertEquals(
                "no_logout_record",
                AuditSessionQueryService.statusForEvidence(0, 0, null));
        assertEquals(
                "退出后仍有活动",
                AuditSessionQueryService.statusLabel("activity_after_logout"));
    }

    @Test
    void eventCursorTimeAndIdMustBeAbsentOrPresentTogether() {
        UUID sessionId = UUID.randomUUID();
        OffsetDateTime cursorAt = OffsetDateTime.parse(
                "2026-08-01T08:00:00+08:00");
        assertDoesNotThrow(() -> AuditSessionQueryService.validateEventScope(
                sessionId, null, null, 20, null));
        assertDoesNotThrow(() -> AuditSessionQueryService.validateEventScope(
                sessionId, cursorAt, 123L, 20, 456L));
        assertThrows(ApiException.class, () ->
                AuditSessionQueryService.validateEventScope(
                        sessionId, cursorAt, null, 20, null));
        assertThrows(ApiException.class, () ->
                AuditSessionQueryService.validateEventScope(
                        sessionId, null, 123L, 20, null));
    }

    @Test
    void sessionDetailRequiresIdentityAndValidSnapshot() {
        UUID sessionId = UUID.randomUUID();
        assertDoesNotThrow(() ->
                AuditSessionQueryService.validateSessionDetailScope(
                        sessionId, null));
        assertDoesNotThrow(() ->
                AuditSessionQueryService.validateSessionDetailScope(
                        sessionId, 0L));
        assertThrows(ApiException.class, () ->
                AuditSessionQueryService.validateSessionDetailScope(
                        null, null));
        assertThrows(ApiException.class, () ->
                AuditSessionQueryService.validateSessionDetailScope(
                        sessionId, -1L));
    }

    @Test
    void dateOnlySelectsSessionAndTimelineAggregationCrossesMidnight()
            throws IOException {
        String source = source("AuditSessionQueryService.java");
        assertTrue(source.contains("WITH matched_sessions AS"));
        assertTrue(source.contains(
                "JOIN matched_sessions matched ON matched.session_id = a.session_id"));
        int timelineStart = source.indexOf("session_events AS");
        int timelineEnd = source.indexOf("logout_event AS", timelineStart);
        assertTrue(timelineStart >= 0 && timelineEnd > timelineStart);
        String timelineBlock = source.substring(timelineStart, timelineEnd);
        assertFalse(timelineBlock.contains(":dateFrom"));
        assertFalse(timelineBlock.contains(":dateToExclusive"));
        assertTrue(source.contains(
                "ORDER BY COALESCE(grouped.login_at, grouped.first_activity_at) DESC"));
        assertTrue(source.contains("grouped.session_id DESC"));
        assertTrue(source.contains("session_start_after_password_change"));
        assertTrue(source.contains("'bad_credentials'"));
        assertTrue(source.contains("'rate_limited'"));
        assertTrue(source.contains("'reuse_detected'"));
    }

    @Test
    void eventExpansionIsLazySnapshotBoundAndCannotCrossSession()
            throws IOException {
        String source = source("AuditSessionQueryService.java");
        assertTrue(source.contains("WHERE a.sessionId = :sessionId"));
        assertTrue(source.contains("a.id <= :snapshotAuditId"));
        assertTrue(source.contains("a.createdAt < :cursorAt"));
        assertTrue(source.contains(
                "a.createdAt = :cursorAt AND a.id < :cursorId"));
        assertTrue(source.contains("ORDER BY a.createdAt DESC, a.id DESC"));
        assertTrue(source.contains("query.setMaxResults(size + 1)"));
        assertTrue(source.contains("AuditLogRow.of("));
        assertTrue(source.contains("actorDirectory.resolve("));
        assertFalse(source.contains("SESSION_EVENTS_SQL"));

        String response = source("AuditSessionEventPageResponse.java");
        assertTrue(response.contains("OffsetDateTime nextCursorAt"));
        assertTrue(response.contains("Long nextCursorId"));
        assertFalse(response.contains("Long nextCursor,"));
    }

    @Test
    void sessionReadsHaveControllerAndServicePermissionDefenseInDepth()
            throws Exception {
        String controller = source("AuditSessionController.java");
        String permission = "@PreAuthorize(\"hasAuthority('audit_log:view')\")";
        assertEquals(3, occurrences(controller, permission));

        for (String methodName : java.util.List.of("sessions", "session", "events")) {
            var method = Arrays.stream(AuditSessionQueryService.class.getDeclaredMethods())
                    .filter(candidate -> candidate.getName().equals(methodName))
                    .filter(candidate -> java.lang.reflect.Modifier.isPublic(
                            candidate.getModifiers()))
                    .findFirst()
                    .orElseThrow();
            assertEquals(
                    "hasAuthority('audit_log:view')",
                    method.getAnnotation(PreAuthorize.class).value(),
                    methodName);
        }
    }

    @Test
    void sessionQueriesExposeArchiveAndSnapshotBoundariesWithoutSilentEmptySuccess()
            throws IOException {
        String source = source("AuditSessionQueryService.java");
        assertTrue(source.contains("hasArchivedSessions("));
        assertTrue(source.contains("登录会话已转入冷归档"));
        assertTrue(source.contains("登录会话不存在"));
        assertTrue(source.contains("登录会话晚于当前查询快照"));
        assertTrue(source.contains("查询快照编号超出当前审计范围"));
        assertTrue(source.contains("SessionAvailability availability"));
        assertTrue(source.contains("archive_presence AS"));
        assertTrue(source.contains("AS timeline_partial"));
    }

    @Test
    void sessionAndTokenLookupsKeepTheExistingIndexContract() throws IOException {
        String migration = Files.readString(Path.of(
                "src/main/resources/db/migration/"
                        + "V428__audit_login_session_correlation.sql"));
        assertTrue(migration.contains("idx_audit_session_created_id"));
        assertTrue(migration.contains(
                "ON audit_log (session_id, created_at DESC, id DESC)"));
        assertTrue(migration.contains("idx_audit_archive_session_created_id"));
        assertTrue(migration.contains(
                "ON audit_log_archive (session_id, created_at DESC, id DESC)"));
        assertTrue(migration.contains("idx_refresh_tokens_session_id"));
        assertTrue(migration.contains("idx_visitor_refresh_tokens_session_id"));

        String service = source("AuditSessionQueryService.java");
        assertTrue(service.contains(
                "JOIN matched_sessions matched\n"
                        + "                  ON matched.session_id = token.session_id"));
    }

    @Test
    void everySessionEndpointRequiresAuditViewPermission() throws IOException {
        String source = source("AuditSessionController.java");
        String permission = "@PreAuthorize(\"hasAuthority('audit_log:view')\")";
        assertEquals(3, occurrences(source, permission));
        assertTrue(source.contains("@RequestMapping(\"/api/admin/audit-sessions\")"));
        assertTrue(source.contains("@GetMapping(\"/{sessionId}\")"));
        assertTrue(source.contains("@GetMapping(\"/{sessionId}/events\")"));
    }

    private static String source(String name) throws IOException {
        return Files.readString(SOURCE_ROOT.resolve(name));
    }

    private static int occurrences(String source, String expected) {
        int count = 0;
        int from = 0;
        while ((from = source.indexOf(expected, from)) >= 0) {
            count++;
            from += expected.length();
        }
        return count;
    }
}
