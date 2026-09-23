package com.uten.imp.features.admin.systemsetting;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

/**
 * 系统设置单一登记的契约 (ADR-110; audit-retention-settings-09): 全新库跑完全部迁移后,
 * {@code system_settings} 的行集合 = {@link SystemSettingKey} 枚举集合, 种子值 = 枚举默认值,
 * 表里只剩值列 (元数据不再有第二份)。顺带锁住同批迁移的账号安全口径 (V680/V682)。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SystemSettingRegistryContractTest {

    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate jdbc;

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
        jdbc = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void databaseRowsAreExactlyTheRegisteredKeysSeededWithTheirDefaults() {
        Map<String, String> rows = new TreeMap<>();
        jdbc.query("SELECT key, value FROM system_settings", rs -> {
            rows.put(rs.getString("key"), rs.getString("value"));
        });
        Map<String, String> registered = Arrays.stream(SystemSettingKey.values())
                .collect(Collectors.toMap(SystemSettingKey::key, SystemSettingKey::defaultValue,
                        (a, b) -> a, TreeMap::new));

        assertEquals(registered.keySet(), rows.keySet(), "库里的设置行必须与登记枚举一一对应");
        assertEquals(registered, rows, "全新库的种子值必须等于登记默认值");
    }

    @Test
    void settingsTableKeepsOnlyValuesAndAuditColumns() {
        List<String> columns = jdbc.queryForList("""
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'system_settings'
                ORDER BY column_name
                """, String.class);
        assertEquals(List.of("key", "updated_at", "updated_by", "value"), columns);
    }

    @Test
    void registeredDefaultsAreInsideTheirOwnBounds() {
        for (SystemSettingKey key : SystemSettingKey.values()) {
            assertEquals(null, SystemSettingsService.validationError(key, key.defaultValue()), key.key());
        }
    }

    @Test
    void accountSupportIsPersonalOnlyAndAuthTablesExist() {
        assertEquals(0, jdbc.queryForObject("""
                SELECT count(*) FROM department_permissions dp
                JOIN permissions p ON p.id = dp.permission_id
                WHERE p.code = 'account:support'
                """, Integer.class));
        // 只能个人点名授权由授权策略唯一事实源表达 (V682 置 grant_policy = {INDIVIDUAL_ONLY}, ADR-109)
        assertThat(jdbc.queryForObject(
                "SELECT grant_policy = ARRAY['INDIVIDUAL_ONLY']::text[] FROM permissions WHERE code = 'account:support'",
                Boolean.class)).isTrue();
        // 部门级授予在数据库边界同样被拒 (V677 按 grant_policy 判定的通用守卫)
        DataAccessException rejected = assertThrows(DataAccessException.class, () -> jdbc.update("""
                INSERT INTO department_permissions (department_id, permission_id)
                SELECT d.id, p.id FROM departments d, permissions p
                WHERE p.code = 'account:support' AND NOT d.is_deleted
                LIMIT 1
                """));
        assertThat(rejected.getMostSpecificCause().getMessage()).contains("该权限只能逐人授予，不能配置给整个部门");
        assertEquals(2, jdbc.queryForObject("""
                SELECT count(*) FROM information_schema.tables
                WHERE table_schema = 'public' AND table_name IN ('auth_sessions', 'auth_step_up_states')
                """, Integer.class));
        assertThat(jdbc.queryForObject("""
                SELECT pg_get_functiondef('business_data_reset()'::regprocedure)
                """, String.class)).contains("('auth_sessions', 'CLEAR')", "('auth_step_up_states', 'CLEAR')");
    }
}
