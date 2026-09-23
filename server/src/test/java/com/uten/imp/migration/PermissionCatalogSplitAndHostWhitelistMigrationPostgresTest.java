package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.io.IOException;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V655 / V657(ADR-109)在真实升级路径上的授权平移：
 * <ul>
 *   <li>出货财审、仓库销售出库拆码时，负责人页面委派与部门授权、个人覆盖一样按原持有者平移，
 *       委派过原码的员工迁移后仍能放行 / 退回 / 反审(评审发现：只平移了三张表、漏了委派)；</li>
 *   <li>V657 把接待访客从全员基础包改成对外接待白名单：不可由负责人转授、默认部门持有。</li>
 * </ul>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PermissionCatalogSplitAndHostWhitelistMigrationPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");

    @BeforeAll
    static void start() {
        POSTGRES.start();
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void splitCodesCarryManagerDelegationsAndHostPermissionBecomesAWhitelist() throws IOException {
        migrateTo(latestVersionBefore(655));
        JdbcTemplate db = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        UUID finance = db.queryForObject("SELECT id FROM departments WHERE code = 'DEPT_FIN'", UUID.class);
        UUID grantor = user(db, finance, "委派人");
        UUID target = user(db, finance, "被委派人");
        for (String code : List.of("finance_shipment_audit", "sales_shipment:warehouse-work")) {
            db.update("""
                    INSERT INTO manager_permission_delegations
                        (user_id, permission_id, department_id, enabled, surface_key, granted_by_user_id,
                         target_user_generation, target_employee_generation, target_department_generation,
                         grantor_user_generation, grantor_employee_generation, grantor_auth_version,
                         grantor_authorization_epoch, scope_source)
                    SELECT ?, permission.id, ?, TRUE, 'finance.shipment-audit', ?, 0, 0, 0, 0, NULL, 0, 0,
                           'SUPER_ADMIN'
                    FROM permissions permission WHERE permission.code = ?
                    """, target, finance, grantor, code);
        }

        migrateTo("655");

        List<Map<String, Object>> carried = db.queryForList("""
                SELECT permission.code, delegation.enabled, delegation.granted_by_user_id,
                       delegation.surface_key, delegation.scope_source
                FROM manager_permission_delegations delegation
                JOIN permissions permission ON permission.id = delegation.permission_id
                WHERE delegation.user_id = ?
                ORDER BY permission.code
                """, target);
        assertThat(carried).extracting(row -> row.get("code")).containsExactly(
                "sales_shipment_finance:approve", "sales_shipment_finance:reject",
                "sales_shipment_finance:reverse", "sales_shipment_finance:view",
                "warehouse_sales_outbound:execute", "warehouse_sales_outbound:view");
        assertThat(carried).allSatisfy(row -> {
            assertThat(row.get("enabled")).isEqualTo(Boolean.TRUE);
            assertThat(row.get("granted_by_user_id")).isEqualTo(grantor);
            assertThat(row.get("surface_key")).isEqualTo("finance.shipment-audit");
            assertThat(row.get("scope_source")).isEqualTo("SUPER_ADMIN");
        });

        migrateTo(null);

        assertThat(db.queryForObject(
                "SELECT baseline FROM permissions WHERE code = 'visitor:host_confirm'", Boolean.class)).isFalse();
        assertThat(db.queryForObject(
                "SELECT grant_policy::text FROM permissions WHERE code = 'visitor:host_confirm'", String.class))
                .isEqualTo("{NON_DELEGABLE}");
        assertThat(db.queryForList("""
                SELECT department.code FROM department_permissions allocation
                JOIN departments department ON department.id = allocation.department_id
                JOIN permissions permission ON permission.id = allocation.permission_id
                WHERE permission.code = 'visitor:host_confirm' ORDER BY department.code
                """, String.class)).containsExactlyInAnyOrder(
                "DEPT_ENG", "DEPT_HR", "DEPT_NEWMEDIA", "DEPT_QA", "DEPT_RAIL", "DEPT_SALES", "GM",
                "SUB_PURCHASE");
    }

    private static void migrateTo(String version) {
        var config = Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration");
        if (version != null) {
            config.target(version);
        }
        config.load().migrate();
    }

    /** V655 之前目录里最后一个迁移版本(合并定号后中间可能插入别的迁移，不写死)。 */
    private static String latestVersionBefore(int version) throws IOException {
        Pattern name = Pattern.compile("V(\\d+)__.*\\.sql");
        return Arrays.stream(new org.springframework.core.io.support.PathMatchingResourcePatternResolver()
                        .getResources("classpath:db/migration/V*__*.sql"))
                .map(resource -> name.matcher(resource.getFilename() == null ? "" : resource.getFilename()))
                .filter(Matcher::matches)
                .mapToInt(matcher -> Integer.parseInt(matcher.group(1)))
                .filter(candidate -> candidate < version)
                .max()
                .stream()
                .mapToObj(Integer::toString)
                .findFirst()
                .orElseThrow();
    }

    private static UUID user(JdbcTemplate db, UUID department, String name) {
        UUID employee = UUID.randomUUID();
        UUID user = UUID.randomUUID();
        db.update("""
                INSERT INTO employees(id, code, full_name, id_type, department_id, hire_date, status, employment_type)
                VALUES (?, ?, ?, '其他', ?, DATE '2026-01-01', 'active', 'regular')
                """, employee, "MIG-" + employee, name, department);
        db.update("""
                INSERT INTO users(id, employee_id, login_account, password_hash, must_change_password,
                                  is_super_admin, status)
                VALUES (?, ?, ?, 'x', false, false, 'active')
                """, user, employee, "mig-" + user);
        return user;
    }
}
