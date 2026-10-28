package com.uten.imp.audit;

import com.uten.imp.testsupport.FixtureDatabaseProperties;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.security.test.context.support.WithMockUser;
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
@TestExecutionListeners(listeners = AuditSessionQueryPostgresTest.Cleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
@Testcontainers(disabledWithoutDocker = true)
@WithMockUser(authorities = "audit_log:view")
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.MOCK,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.jwt.secret=audit-session-query-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=audit-session-query-pgp-key-test-only-0123456789",
                "uten.crypto.hmac-key=audit-session-query-hmac-key-test-only",
                "uten.bootstrap.admin-login=audit-session-bootstrap-admin",
                "uten.bootstrap.admin-password=AuditSessionBootstrapPass-1!"
        })
class AuditSessionQueryPostgresTest {

    private static MigratedSchemaBaseline.ScopedDatabase database;

    @DynamicPropertySource
    static void dataSource(DynamicPropertyRegistry registry) throws java.sql.SQLException {
        database = MigratedSchemaBaseline.openDatabase("audit_session_query");
        // A developer's opt-in migrator credential must never cross into the
        // private test clone. Validation still uses this clone's real catalog.
        FixtureDatabaseProperties.bindSameRole(registry, database::getJdbcUrl,
                database::getUsername, database::getPassword);
    }

    public static class Cleanup extends AbstractTestExecutionListener {
        // afterTestClass listeners run in reverse order: close Spring/Hikari first.
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder() - 1; }
        @Override public void afterTestClass(TestContext ignored) throws java.sql.SQLException {
            if (database != null) database.close();
        }
    }

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private AuditSessionQueryService sessions;
    @Autowired
    private AuditSessionTableExportService sessionExport;

    @Autowired
    private AuditService auditService;
    @Autowired
    private AuditQueryService eventQueries;

    /** V952 统一读取视图后, JPA 写通道(实体 INSERT 经 INSTEAD OF 触发器落在线表)必须原样可用。 */
    @Test
    void jpaAuditWritesStillLandInTheOnlineTableThroughTheUnifiedView() {
        UUID actorId = UUID.randomUUID();
        long before = onlineRowCount();

        auditService.logExplicit(actorId, null, "audit-view-write-test",
                "b3_view_write_probe", "B3-VIEW-WRITE-" + actorId, "success");

        long after = onlineRowCount();
        org.junit.jupiter.api.Assertions.assertEquals(before + 1, after,
                "经 AuditService/JPA 写入的审计行必须落入在线表 audit_log");
        // 事件详情(经视图)能立刻读回, 且分类触发器(V556)照常重算了风险等级。
        var detail = jdbc.queryForMap(
                "SELECT id, risk_level FROM v_audit_log_all WHERE target_id = ?",
                "B3-VIEW-WRITE-" + actorId);
        org.junit.jupiter.api.Assertions.assertNotNull(detail.get("id"), "生成的主键必须回填");
        org.junit.jupiter.api.Assertions.assertNotNull(detail.get("risk_level"),
                "V556 分类触发器应继续重算 risk_level");
    }

    private long onlineRowCount() {
        Long count = jdbc.queryForObject(
                "SELECT count(*) FROM audit_log", Long.class);
        return count == null ? 0 : count;
    }

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
        // 统一读取(V952): 归档段的早期 login 一并计入完整时间线, 会话标注跨层。
        assertEquals(OffsetDateTime.parse("2026-01-01T08:00:00+08:00"),
                crossMidnight.loginAt());
        assertEquals("activity_after_logout", crossMidnight.status());
        assertEquals(1, crossMidnight.postLogoutCount());
        assertEquals(5, crossMidnight.eventCount());
        assertTrue(crossMidnight.spansArchive());
        assertEquals(page.snapshotAuditId(), crossMidnight.snapshotAuditId());

        AuditSessionRow direct = sessions.session(
                firstSession, page.snapshotAuditId());
        assertEquals(firstSession, direct.sessionId());
        assertEquals(crossMidnight.actorId(), direct.actorId());
        assertEquals(crossMidnight.operationCount(), direct.operationCount());
        assertEquals(crossMidnight.lastActivityAt(), direct.lastActivityAt());
        assertEquals(crossMidnight.eventCount(), direct.eventCount());
        assertTrue(direct.spansArchive());
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
        assertTrue(second.hasMore());

        // 完整时间线包含冷归档层的最早 login, 复合游标跨层翻页到底。
        AuditSessionEventPageResponse third = sessions.events(
                firstSession,
                second.nextCursorAt(),
                second.nextCursorId(),
                3,
                page.snapshotAuditId());
        assertEquals(1, third.items().size());
        assertEquals("login", third.items().get(0).getAction());
        // 事件时间线来自实体读取(timestamptz 按 UTC 返回): 比较同一时刻。
        assertEquals(OffsetDateTime.parse("2026-01-01T08:00:00+08:00").toInstant(),
                third.items().get(0).getCreatedAt().toInstant());
        assertFalse(third.hasMore());
        assertNull(third.nextCursorAt());
        assertNull(third.nextCursorId());
    }

    @Test
    void rejectsForgedSnapshotsAndServesArchivedSessionsAcrossTiers() {
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
                "SELECT COALESCE(MAX(id), 0) FROM v_audit_log_all",
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

        // 统一读取(V952): 纯归档会话的详情/列表/事件时间线直接可查, 不再整体拒绝。
        insertArchive(
                actorId,
                archivedSession,
                "login",
                "2026-02-10T09:00:00+08:00");
        insertArchive(
                actorId,
                archivedSession,
                "logout",
                "2026-02-10T09:30:00+08:00");
        // 夹具归档行 id 高于在线行; 插入后重新取统一视图高水位再查。
        long snapshotWithArchive = jdbc.queryForObject(
                "SELECT COALESCE(MAX(id), 0) FROM v_audit_log_all",
                Long.class);

        AuditSessionRow archivedDetail = sessions.session(
                archivedSession, snapshotWithArchive);
        assertEquals(archivedSession, archivedDetail.sessionId());
        assertEquals(actorId, archivedDetail.actorId());
        assertEquals("normal_logout", archivedDetail.status());
        assertEquals(2, archivedDetail.eventCount());
        // login/logout 不计入操作数: 纯归档会话只有起止两端事件。
        assertEquals(0, archivedDetail.operationCount());
        assertEquals(OffsetDateTime.parse("2026-02-10T09:00:00+08:00"),
                archivedDetail.loginAt());
        assertTrue(archivedDetail.spansArchive());

        AuditSessionPageResponse archivedRange = sessions.sessions(
                actorId,
                LocalDate.parse("2026-02-10"),
                LocalDate.parse("2026-02-10"),
                1,
                20,
                snapshotWithArchive);
        assertEquals(1, archivedRange.total());
        assertEquals(archivedSession, archivedRange.items().getFirst().sessionId());
        assertTrue(archivedRange.items().getFirst().spansArchive());

        AuditSessionEventPageResponse archivedTimeline = sessions.events(
                archivedSession,
                null,
                null,
                20,
                snapshotWithArchive);
        assertEquals(2, archivedTimeline.items().size());
        assertEquals("logout", archivedTimeline.items().get(0).getAction());
        assertEquals("login", archivedTimeline.items().get(1).getAction());
        assertFalse(archivedTimeline.hasMore());
    }

    @Test
    void pagingKeepsFullCrossMidnightEvidenceAndLoginOrder() {
        UUID actorId = UUID.randomUUID();
        UUID olderLogin = UUID.randomUUID();
        UUID newerLogin = UUID.randomUUID();
        insert(actorId, olderLogin, "login", "2026-08-28T23:00:00+08:00");
        insert(actorId, olderLogin, "update", "2026-08-30T22:00:00+08:00");
        insert(actorId, olderLogin, "logout", "2026-08-31T02:00:00+08:00");
        insert(actorId, newerLogin, "login", "2026-08-29T23:00:00+08:00");
        insert(actorId, newerLogin, "update", "2026-08-30T01:00:00+08:00");
        var first = sessions.sessions(actorId, LocalDate.parse("2026-08-30"),
                LocalDate.parse("2026-08-30"), 1, 1, null);
        var second = sessions.sessions(actorId, LocalDate.parse("2026-08-30"),
                LocalDate.parse("2026-08-30"), 2, 1, first.snapshotAuditId());
        assertEquals(2, first.total());
        assertEquals(newerLogin, first.items().getFirst().sessionId());
        assertEquals(olderLogin, second.items().getFirst().sessionId());
        assertEquals(3, second.items().getFirst().eventCount());
        assertEquals(OffsetDateTime.parse("2026-08-31T02:00:00+08:00"),
                second.items().getFirst().logoutAt());
        assertEquals(sessions.session(olderLogin, first.snapshotAuditId()).operationCount(),
                second.items().getFirst().operationCount());
    }

    @Test
    @WithMockUser(authorities = {"audit_log:view", "audit_log:export"})
    void headerPredicatesUseCompleteSessionEvidenceBeforeCountPageAndExport() {
        UUID actor = UUID.randomUUID(), older = UUID.randomUUID(), middle = UUID.randomUUID(), newer = UUID.randomUUID();
        insertArchive(actor,older,"login","2026-01-01T08:00:00+08:00");
        insert(actor,older,"update","2026-08-30T08:00:00+08:00");
        insert(actor,older,"logout","2026-08-30T08:10:00+08:00");
        insert(actor,older,"http_get","2026-08-30T08:11:00+08:00");
        insert(actor,middle,"login","2026-08-30T09:00:00+08:00");
        insert(actor,middle,"update","2026-08-30T09:01:00+08:00");
        insert(actor,newer,"login","2026-08-30T10:00:00+08:00");
        LocalDate day = LocalDate.parse("2026-08-30");
        var headers = new AuditSessionHeaderQuery(java.util.Map.of("operations", ">=2",
                "status", "activity_after_logout", "login", "2026-01"), "operations", false);
        var filtered = sessions.sessions(actor,day,day,1,1,null,headers);
        assertEquals(1,filtered.total());
        assertEquals(older,filtered.items().getFirst().sessionId());
        assertEquals(2,filtered.items().getFirst().operationCount());
        assertTrue(filtered.items().getFirst().spansArchive());
        var sort = new AuditSessionHeaderQuery(java.util.Map.of(), "operations", true);
        var first = sessions.sessions(actor,day,day,1,1,filtered.snapshotAuditId(),sort);
        var last = sessions.sessions(actor,day,day,3,1,filtered.snapshotAuditId(),sort);
        assertEquals(3,first.total());
        assertEquals(newer,first.items().getFirst().sessionId());
        assertEquals(older,last.items().getFirst().sessionId());
        var exported = sessionExport.export(actor,day,day,filtered.snapshotAuditId(),100,headers);
        assertEquals(1,exported.total());
        assertEquals(1,exported.rows().size());
        assertEquals(2L,exported.rows().getFirst().get("operations"));
    }

    @Test
    @WithMockUser(authorities = {"audit_log:view", "audit_log:export"})
    void eventDeviceAndRedactedComparisonFiltersShareListSummaryAndExportScope() {
        UUID actor = UUID.randomUUID();
        ensureMonth("audit_log", "2026-08-30T08:00:00+08:00");
        jdbc.update("""
            INSERT INTO audit_log(actor_id,actor_account,action,target_type,target_id,result,event_source,
              created_at,device_name,before,after,risk_level,event_category)
            VALUES (?,'audit-header-test','update','audit_header_test','HEADER-RECORDED','success','business',
              '2026-08-30T08:00:00+08:00'::timestamptz,'AUDIT%_DEVICE','{"qty":1}'::jsonb,'{"qty":2}'::jsonb,'low','business'),
              (?,'audit-header-test','http_get','audit_header_test','HEADER-UNRECORDED','success','business',
              '2026-08-30T09:00:00+08:00'::timestamptz,'AUDITxxDEVICE',NULL,NULL,'low','business')
            """, actor, actor);
        LocalDate day = LocalDate.parse("2026-08-30");
        var base = new AuditSearchCriteria(null,null,null,null,null,null,null,null,null,null,null,null,
                day,day,null,actor,false);
        var filtered = base.withHeaderFilters(java.util.Map.of("device", "AUDIT%_DEVICE", "change", "recorded"));
        assertEquals(1,eventQueries.query(filtered,1,1).getTotal());
        assertEquals(1,eventQueries.summary(filtered).total());
        assertEquals(1,eventQueries.export(filtered,100).total());
        assertEquals(1,eventQueries.query(base.withHeaderFilters(java.util.Map.of("change","unrecorded")),1,1).getTotal());
    }

    private void insert(
            UUID actorId,
            UUID sessionId,
            String action,
            String createdAt) {
        ensureMonth("audit_log", createdAt);
        jdbc.update("""
                        INSERT INTO audit_log(
                            actor_id, actor_account, action, target_type,
                            target_id, result, event_source, session_id, created_at,
                            risk_level, event_category)
                        VALUES (?, 'audit-session-test', ?, 'audit_session_test',
                                ?, 'success', 'business', ?, ?::timestamptz, 'low', 'business')
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
        ensureMonth("audit_log_archive", createdAt);
        jdbc.update("""
                        INSERT INTO audit_log_archive(
                            id, actor_id, actor_account, action, target_type,
                            target_id, result, event_source, session_id, created_at,
                            risk_level, event_category)
                        VALUES (?, ?, 'audit-session-test', ?, 'audit_session_test',
                                ?, 'success', 'business', ?, ?::timestamptz, 'low', 'business')
                        """,
                archiveId,
                actorId,
                action,
                UUID.randomUUID().toString(),
                sessionId,
                createdAt);
    }

    /** 审计表按北京时间月分区(ADR-105): 固定历史日期的测试行先确保所在月份的分区存在。 */
    private void ensureMonth(String parent, String createdAt) {
        jdbc.queryForObject("""
                        SELECT fn_audit_ensure_partition(?,
                            (?::timestamptz AT TIME ZONE 'Asia/Shanghai')::date)
                        """,
                String.class, parent, createdAt);
    }
}
