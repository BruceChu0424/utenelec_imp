package com.uten.imp.features.org.hrtask;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.sql.DriverManager;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.Optional;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class HrCelebrationHistoryHeaderPostgresTest {
    private static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("hr_header");
    @BeforeAll static void start() { POSTGRES.start(); }
    @AfterAll static void stop() { POSTGRES.stop(); }

    @Test void snapshotSearchDatesAndPagingKeepTheNoticeAudienceAndDeletedStateBoundary() throws Exception {
        try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())) {
            var jdbc = new JdbcTemplate(new SingleConnectionDataSource(connection, true));
            jdbc.execute("""
                    CREATE TABLE notices(id uuid, type text, source_event text, audience_user_id uuid,
                      audience_scope text, subject_employee_id uuid, subject_name text, event_label text,
                      published_at timestamptz, publisher text);
                    CREATE TABLE notice_celebration_subjects(id uuid, notice_id uuid, employee_id uuid,
                      employee_name text, event_label text);
                    CREATE TABLE notice_user_states(notice_id uuid,user_id uuid,deleted_at timestamptz);
                    """);
            UUID actor = UUID.randomUUID(), first = UUID.randomUUID(), second = UUID.randomUUID(), hidden = UUID.randomUUID(), deleted = UUID.randomUUID();
            jdbc.update("INSERT INTO notices VALUES (?, 'birthday', NULL, NULL, 'all', NULL, '王一历史', '生日祝福', '2026-10-27 18:00+00', '人事甲')", first);
            jdbc.update("INSERT INTO notices VALUES (?, 'birthday', NULL, NULL, 'all', NULL, '旧姓名', '旧事项', '2026-10-28 02:00+00', '人事乙')", second);
            jdbc.update("INSERT INTO notice_celebration_subjects VALUES (?, ?, ?, '王二历史', '生日祝福')", UUID.randomUUID(), second, UUID.randomUUID());
            jdbc.update("INSERT INTO notices VALUES (?, 'birthday', NULL, ?, 'selected', NULL, '王三不可见', '生日祝福', '2026-10-28 03:00+00', '人事丙')", hidden, UUID.randomUUID());
            jdbc.update("INSERT INTO notices VALUES (?, 'birthday', NULL, NULL, 'all', NULL, '王四已删除', '生日祝福', '2026-10-28 04:00+00', '人事丁')", deleted);
            jdbc.update("INSERT INTO notice_user_states VALUES (?, ?, now())", deleted, actor);
            var current = mock(SecurityContextCurrentUser.class);
            when(current.get()).thenReturn(Optional.of(new AuthUser(actor, UUID.randomUUID(), "reader",
                    Set.of("employee:view", "notice:read", "employee:pii:view"), false, true, false)));
            var service = new HrCelebrationHistoryService(jdbc, current);
            var secondPage = service.list("birthday", 2, 1, Map.of("search.employeeName", "王", "search.eventLabel", "生日",
                    "search.publisher", "人事", "search.publishedAt", "2026-10-28", "sort", "publishedAt", "order", "asc"));
            assertThat(secondPage.getTotal()).isEqualTo(2);
            assertThat(secondPage.getPage()).isEqualTo(2);
            assertThat(secondPage.getItems()).singleElement().satisfies(row -> {
                assertThat(row.employeeName()).isEqualTo("王二历史");
                assertThat(row.eventLabel()).isEqualTo("生日祝福");
                assertThat(row.noticeId()).isEqualTo(second);
            });
            assertThat(service.list("birthday", 1, 20, Map.of("search.publishedAt", "2026-10-27")).getTotal()).isZero();
        }
    }
}
