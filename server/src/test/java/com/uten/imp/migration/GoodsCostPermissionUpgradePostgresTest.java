package com.uten.imp.migration;

import java.util.UUID;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import static org.assertj.core.api.Assertions.assertThat;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsCostPermissionUpgradePostgresTest {
    @Test
    void viewOnlyUsersAndDepartmentsDoNotAcquireCostWriteApprovalExportOrTemplateWhenUpgrading() {
        try (var postgres = new PostgreSQLContainer<>("postgres:16-alpine")) {
            postgres.start();
            migrate(postgres, "752");
            var sql = new JdbcTemplate(new DriverManagerDataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword()));
            UUID actor = UUID.randomUUID();
            UUID employee = sql.queryForObject("SELECT id FROM employees WHERE code='ADMIN'", UUID.class);
            UUID department = sql.queryForObject("SELECT id FROM departments ORDER BY id LIMIT 1", UUID.class);
            sql.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status) VALUES(?,?,?,'not-a-login-hash',false,false,'active')",
                    actor, employee, "cost-view-upgrade-" + actor);
            sql.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'grant' FROM permissions WHERE code='goods:cost:view'", actor);
            sql.update("INSERT INTO department_permissions(department_id,permission_id) SELECT ?,id FROM permissions WHERE code='goods:cost:view' ON CONFLICT DO NOTHING", department);
            migrate(postgres, "753");
            String capabilities = "('goods:cost:edit','goods:cost:confirm','goods:cost:export','goods:cost:template')";
            assertThat(sql.queryForObject("SELECT count(*) FROM user_permission_overrides o JOIN permissions p ON p.id=o.permission_id WHERE o.user_id=? AND p.code IN " + capabilities,
                    Integer.class, actor)).isZero();
            assertThat(sql.queryForObject("SELECT count(*) FROM department_permissions o JOIN permissions p ON p.id=o.permission_id WHERE o.department_id=? AND p.code IN " + capabilities,
                    Integer.class, department)).isZero();
            assertThat(sql.queryForObject("SELECT count(*) FROM permissions WHERE code IN " + capabilities
                    + " AND sensitivity='SENSITIVE_COMMERCIAL' AND grant_policy=ARRAY['BULK_EXCLUDED']::text[] AND NOT baseline", Integer.class)).isEqualTo(4);
            assertThat(sql.queryForObject("SELECT count(*) FROM user_permission_overrides o JOIN permissions p ON p.id=o.permission_id WHERE o.user_id=? AND p.code='goods:cost:view' AND o.effect='grant'",
                    Integer.class, actor)).isEqualTo(1);
        }
    }

    private static void migrate(PostgreSQLContainer<?> postgres, String version) {
        Flyway.configure().dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                .locations("classpath:db/migration").initSql("SET client_min_messages = WARNING").target(version).load().migrate();
    }
}
