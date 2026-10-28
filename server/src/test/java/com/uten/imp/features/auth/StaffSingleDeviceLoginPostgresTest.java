package com.uten.imp.features.auth;

import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.time.Clock;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 单设备登录（2026-10-03 实装）：同一账号新处登录即顶号——撤销该账号其余会话；
 * 同一台设备上其它账号的会话不受影响。直接对着迁移后的库验证 auth_sessions 行。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(i?)true")
class StaffSingleDeviceLoginPostgresTest {
    MigratedSchemaBaseline.ScopedDatabase database;
    AuthSessionService sessions;
    JdbcTemplate jdbc;

    @BeforeEach
    void start() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("auth_single_device_login");
        var ds = new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword());
        jdbc = new JdbcTemplate(ds);
        SystemSettingsService settings = mock(SystemSettingsService.class);
        when(settings.readLong(SystemSettingKey.JWT_REFRESH_TTL_DAYS)).thenReturn(7L);
        sessions = new AuthSessionService(new NamedParameterJdbcTemplate(ds), settings, Clock.systemUTC());
    }

    @AfterEach
    void stop() throws Exception {
        if (database != null) database.close();
    }

    private UUID user(String label) {
        UUID employee = UUID.randomUUID();
        UUID id = UUID.randomUUID();
        jdbc.update("""
            INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
            SELECT ?,?,?,'其他',id,CURRENT_DATE,'active','regular'
            FROM departments WHERE code='DEPT_FIN'
            """, employee, "SDL-" + label,com.uten.imp.support.SyntheticEmployeeIdentity.name("单设备测试",employee));
        jdbc.update("""
            INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status,is_super_admin)
            VALUES(?,?,?,'test-only',false,'active',false)
            """, id, employee, "single-device-" + label);
        return id;
    }

    private boolean revoked(UUID sid) {
        return Boolean.TRUE.equals(jdbc.queryForObject(
                "SELECT revoked_at IS NOT NULL FROM auth_sessions WHERE sid=?", Boolean.class, sid));
    }

    private String string(UUID sid, String column) {
        return jdbc.queryForObject(
                "SELECT " + column + " FROM auth_sessions WHERE sid=?", String.class, sid);
    }

    @Test
    void newLoginReplacesSameAccountSessionsAndKeepsOtherAccounts() {
        UUID account = user("a");
        UUID colleague = user("b");
        var firstDevice = sessions.openStaffSession(account, "Windows 客户端");
        var colleagueSession = sessions.openStaffSession(colleague, null);

        var secondDevice = sessions.openStaffSession(account, " 网页端 · Chrome ");

        assertThat(revoked(firstDevice.sid())).isTrue();
        assertThat(jdbc.queryForObject(
                "SELECT revoked_reason FROM auth_sessions WHERE sid=?", String.class, firstDevice.sid()))
                .isEqualTo(AuthSessionService.REASON_REPLACED_BY_LOGIN);
        assertThat(string(firstDevice.sid(), "replaced_by_device")).isEqualTo("网页端 · Chrome");
        assertThat(string(secondDevice.sid(), "device_info")).isEqualTo("网页端 · Chrome");
        assertThat(string(colleagueSession.sid(), "device_info")).isNull();
        assertThat(revoked(secondDevice.sid())).isFalse();
        assertThat(revoked(colleagueSession.sid())).isFalse();
    }

    @Test
    void repeatLogoutLoginCycleKeepsOnlyTheLatestSession() {
        UUID account = user("cycle");
        var first = sessions.openStaffSession(account, null);
        var second = sessions.openStaffSession(account, null);
        assertThat(revoked(first.sid())).isTrue();
        sessions.revoke(second.sid(), AuthSessionService.REASON_LOGOUT);
        var third = sessions.openStaffSession(account, null);
        assertThat(revoked(second.sid())).isTrue();
        assertThat(revoked(third.sid())).isFalse();
    }

    @Test
    void refreshVerdictReportsReplacementDeviceForKickedSession() {
        UUID account = user("refresh");
        var first = sessions.openStaffSession(account, "Windows 客户端");
        sessions.openStaffSession(account, "网页端 · Chrome");

        var verdict = sessions.lockAndEvaluateForRefresh(first.sid(), account, null);

        assertThat(verdict.replacedByLogin()).isTrue();
        assertThat(verdict.replacedNotice())
                .isEqualTo("账号已在「网页端 · Chrome」登录，本设备已自动下线");
    }
}
