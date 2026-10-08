package com.uten.imp.features.notice;

import com.uten.imp.support.MigratedSchemaBaseline;
import com.uten.imp.audit.AuditLoginFailureObservation;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import java.util.List;
import java.util.UUID;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class LoginFailureAlertPostgresTest {
    @Test void onlyTenRecentFailuresFromTheSameIpCauseAnAlert() throws Exception {
        try (var database = MigratedSchemaBaseline.openDatabase("login_failure_alert")) {
            var jdbc = new JdbcTemplate(new DriverManagerDataSource(
                    database.getJdbcUrl(), database.getUsername(), database.getPassword()));
            var audience = mock(ServerAlertAudience.class);
            var notices = mock(NoticeService.class);
            UUID receiver = UUID.randomUUID();
            when(audience.receivers()).thenReturn(List.of(receiver));
            var scheduler = new LoginFailureAlertScheduler(jdbc, new AuditLoginFailureObservation(jdbc), audience, notices);
            insert(jdbc, "192.0.2.1", 9, "1 minute");
            insert(jdbc, "192.0.2.2", 8, "1 minute");
            insert(jdbc, "192.0.2.1", 10, "11 minutes");
            scheduler.scan();
            verifyNoInteractions(notices);
            insert(jdbc, "192.0.2.1", 1, "1 minute");
            scheduler.scan();
            verify(notices).publishForUser(eq(receiver), eq("检测到连续登录失败"),
                    contains("10 次"), eq("urgent"), eq("系统监控"),
                    eq("/admin/server-status"), startsWith("SERVER_STATUS_ALERT:LOGIN_FAILURE:"), eq("urgent"));
        }
    }
    private static void insert(JdbcTemplate jdbc, String ip, int count, String age) {
        jdbc.update("""
                INSERT INTO audit_log(actor_account,action,target_type,result,event_source,risk_level,
                    event_category,device_capture_status,ip,created_at)
                SELECT 'fixture','login_failed','users','bad_credentials','business','medium',
                    'authentication','missing',?,CURRENT_TIMESTAMP-CAST(? AS interval)
                FROM generate_series(1,?)
                """, ip, age, count);
    }
}
