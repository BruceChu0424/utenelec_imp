package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V831 常用模块分组：工作台「常用功能」四张自助码归「常用模块」（子类与卡片同名、
 * 按卡片顺序排序），只挪目录归类，授权策略 / 基础包口径与管理码归属保持 V677/V679 现状。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class CommonModuleCatalogMigrationPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("common_module_catalog");

    private static JdbcTemplate jdbc;

    @BeforeAll
    static void start() {
        DB.start();
        Flyway.configure()
                .dataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword())
                .load()
                .migrate();
        jdbc = new JdbcTemplate(
                new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword()));
    }

    @AfterAll
    static void stop() {
        DB.stop();
    }

    record Grouped(String code, String category, int sortOrder) {}

    @Test
    void workbenchSelfServiceCodesFormTheCommonModuleGroupInCardOrder() {
        List<Grouped> rows = jdbc.query(
                "SELECT code, category, sort_order FROM permissions WHERE module = '常用模块' ORDER BY sort_order",
                (rs, i) -> new Grouped(rs.getString("code"), rs.getString("category"), rs.getInt("sort_order")));

        assertThat(rows).containsExactly(
                new Grouped("visitor:host_confirm", "我的访客", 10),
                new Grouped("payroll:view:self", "工资条", 20),
                new Grouped("expense:apply", "我的报销", 30),
                new Grouped("suggestion:submit", "意见箱", 40));
    }

    @Test
    void regroupingKeepsGrantPoliciesBaselineAndManagementCodesUntouched() {
        // 工资条/报销/意见箱三码仍随全员基础包发放，收回或移出基础包才隐藏卡片。
        Integer selfBaseline = jdbc.queryForObject(
                "SELECT count(*) FROM permissions "
                        + "WHERE code IN ('payroll:view:self', 'expense:apply', 'suggestion:submit') AND baseline",
                Integer.class);
        assertThat(selfBaseline).isEqualTo(3);
        // 接待访客仍是 V679 的对外白名单码：不在基础包、只能超管按部门或逐人授予。
        assertThat(jdbc.queryForObject(
                "SELECT NOT baseline AND array_to_string(grant_policy, ',') = 'NON_DELEGABLE' "
                        + "FROM permissions WHERE code = 'visitor:host_confirm'", Boolean.class))
                .isTrue();
        // 管理码留在「人事行政」，常用模块里不混入其它码。
        Integer hrManagement = jdbc.queryForObject(
                "SELECT count(*) FROM permissions WHERE module = '人事行政' AND code IN ("
                        + "'payroll:view:all', 'payroll:generate', 'payroll:review', 'payroll:publish', 'payroll:export', "
                        + "'expense:approve', 'expense:pay', 'expense:settings', "
                        + "'visitor:approve', 'visitor:check_in', 'visitor:verify', 'visitor:blacklist', "
                        + "'suggestion:reply')",
                Integer.class);
        assertThat(hrManagement).isEqualTo(13);
    }
}
