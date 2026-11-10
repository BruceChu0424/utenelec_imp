package com.uten.imp.migration;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V831/V925/V1127 常用模块分组：公司资料库、我的申请、报销、工资条、意见箱、访客按工作台
 * 卡片顺序排列；我的申请五码对齐自助码 NORMAL 策略（可进全员基础包），基础包默认关闭。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class CommonModuleCatalogMigrationPostgresTest {
    private static final PostgreSQLContainer DB = new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("common_module_catalog");

    private static JdbcTemplate jdbc;

    @BeforeAll
    static void start() {
        DB.start();
        com.uten.imp.testsupport.TestFlyway.configure()
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
                "SELECT code, category, sort_order FROM permissions WHERE module = '常用模块' ORDER BY sort_order,code",
                (rs, i) -> new Grouped(rs.getString("code"), rs.getString("category"), rs.getInt("sort_order")));

        assertThat(rows).containsExactly(
                new Grouped("company_file:view", "公司资料库", 15),
                // V1127：我的申请五码并入常用模块，落在资料库与报销之间（工作台卡片顺序）。
                new Grouped("application:apply", "我的申请", 20),
                new Grouped("application:apply:payment", "我的申请", 20),
                new Grouped("application:apply:prepayment", "我的申请", 20),
                new Grouped("application:apply:travel", "我的申请", 20),
                new Grouped("application:view", "我的申请", 21),
                new Grouped("expense:apply", "我的报销", 30),
                new Grouped("payroll:view:self", "工资条", 40),
                new Grouped("suggestion:submit", "意见箱", 50),
                new Grouped("suggestion:view", "意见箱", 50),
                new Grouped("visitor:host_confirm", "我的访客", 60),
                new Grouped("visitor:host_view", "我的访客", 60));
    }

    @Test
    void applicationSelfServiceCodesLeaveNoStrayCommonFunctionModule() {
        // V1127：V1001 的临时一级模块「常用功能」清空后不再出现在任何目录/全选分组里。
        assertThat(jdbc.queryForObject(
                "SELECT count(*) FROM permissions WHERE module = '常用功能'", Integer.class))
                .isZero();
        // 供应商付款申请仍归「采购管理」且维持 INDIVIDUAL_ONLY（采购侧专码、按人开通）。
        assertThat(jdbc.queryForObject(
                "SELECT module || '/' || category || '/' || array_to_string(grant_policy, ',')"
                        + " FROM permissions WHERE code = 'application:apply:supplier_payment'",
                String.class))
                .isEqualTo("采购管理/我的申请/INDIVIDUAL_ONLY");
        // 自助码对齐报销/工资条口径：NORMAL 才能进全员基础包（baselineEligible），
        // baseline 默认仍关闭，由管理员在基础包里自行勾选开通。
        assertThat(jdbc.queryForObject(
                "SELECT count(*) FROM permissions WHERE module = '常用模块' AND category = '我的申请'"
                        + " AND array_to_string(grant_policy, ',') = 'NORMAL' AND NOT baseline",
                Integer.class))
                .isEqualTo(5);
        assertThat(jdbc.queryForObject(
                "SELECT count(*) FROM permission_surfaces s JOIN permission_surface_permissions p"
                        + " ON p.surface_id = s.id WHERE s.surface_key = 'common.applications'",
                Integer.class))
                .isEqualTo(6);
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
        // V958: 资料库写操作码移入「系统管理」，常用模块只剩入口开关。
        Integer libraryAdministration = jdbc.queryForObject(
                "SELECT count(*) FROM permissions WHERE module = '系统管理' AND code LIKE 'company_file:%'",
                Integer.class);
        assertThat(libraryAdministration).isEqualTo(7);
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
