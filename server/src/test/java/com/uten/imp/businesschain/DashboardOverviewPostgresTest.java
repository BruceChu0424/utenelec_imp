package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/**
 * 工作台「今日概览」(GET /api/dashboard/overview) 在迁到迁移头的真库上跑通。
 *
 * <p>2026-09-27 (ADR-133): V741 删了 official_policy_briefs, 而概览服务当时还在查它,
 * 迁移后的库上每次打开工作台都会 500。单元测试只 mock JdbcTemplate, 抓不到「SQL 引用的表/列
 * 已被迁移删掉」这类漂移; 本类让概览自己的 SQL (本人部门递归 CTE、执行中订单计数) 与它经
 * 端口调用的通知/徽章 SQL 全部在真实 schema 上执行一次, 并锁住响应恰好是 5 个字段。
 *
 * <p>权限口径同时在真库上验一次: 同样持有 sales_order:view 的财务员工，无论是否兼职销售，
 * 都能看到按销售单据既有对象范围计算的指标；部门只展示本人主部门。
 *
 * <p><b>CI 必须显式设置 {@code UTEN_RUN_DB_TESTS=true}</b>, 否则本类 SKIP。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print = org.springframework.boot.webmvc.test.autoconfigure.MockMvcPrint.NONE)
class DashboardOverviewPostgresTest {

    private static final Set<String> OVERVIEW_FIELDS = Set.of(
            "departmentCode", "departmentName", "generatedAt", "metrics", "todos");

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @Autowired JdbcTemplate db;

    private FullChainEndToEndTest fixture;

    @BeforeEach
    void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void clear() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void overviewRunsOnTheMigratedSchemaAndUsesPermissionsRegardlessOfDepartmentMembership()
            throws Exception {
        String tag = tag();
        UUID finance = departmentId("DEPT_FIN");
        UUID sales = departmentId("DEPT_SALES");
        String sectionCode = "FIN-OVERVIEW-" + tag;
        UUID section = UUID.randomUUID();
        db.update("""
                INSERT INTO departments(id, code, name, level, parent_id)
                VALUES (?, ?, ?, '二级班组', ?)
                """, section, sectionCode, "概览测试科室-" + tag, finance);

        UUID withSales = user(section, "S" + tag, "notice:read", "sales_order:view");
        UUID withSalesEmployee = employeeOf(withSales);
        db.update("""
                INSERT INTO employee_secondary_departments(employee_id, department_id)
                VALUES (?, ?)
                """, withSalesEmployee, sales);
        UUID financeOnly = user(section, "F" + tag, "notice:read", "sales_order:view");

        JsonNode crossDepartment = overview(auth(withSales));
        assertThat(names(crossDepartment)).as("概览响应恰好 5 个字段, 不再有 intelligence")
                .isEqualTo(new TreeSet<>(OVERVIEW_FIELDS));
        assertThat(crossDepartment.path("departmentCode").asText())
                .as("部门只展示主部门，不参与指标授权").isEqualTo(sectionCode);
        assertThat(metricIds(crossDepartment)).contains("notice-unread", "sales-active");

        JsonNode financeSection = overview(auth(financeOnly));
        assertThat(names(financeSection)).isEqualTo(new TreeSet<>(OVERVIEW_FIELDS));
        assertThat(financeSection.path("departmentCode").asText()).isEqualTo(sectionCode);
        assertThat(metricIds(financeSection))
                .as("已授 sales_order:view 即显示对象范围内的执行中订单指标")
                .contains("notice-unread", "sales-active");
    }

    /**
     * 超管无需兼职业务部门也可请求所有已授权入口。各入口继续应用原对象与状态限制。
     */
    @Test
    void superAdminRunsAuthorizedPartitionsWithoutSecondaryDepartmentMemberships() throws Exception {
        String tag = tag();
        UUID section = UUID.randomUUID();
        db.update("""
                INSERT INTO departments(id, code, name, level, parent_id)
                VALUES (?, ?, ?, '二级班组', ?)
                """, section, "FIN-OVERVIEW-SU-" + tag, "概览超管科室-" + tag, departmentId("DEPT_FIN"));
        UUID admin = user(section, "SU" + tag, true);
        JsonNode overview = overview(auth(admin));

        assertThat(names(overview)).isEqualTo(new TreeSet<>(OVERVIEW_FIELDS));
        // 2026-10-18 ADR-184 修订: 概览的待排产卡直接吃徽章服务, 徽章展示层按会话主体
        // 浏览口径读取(超管镜像生效), 因此超管即使挂在财务科室、不兼职生产部门,
        // 待排产卡也恢复可见; 数量仍按徽章事实聚合, 不叠加部门条件。
        assertThat(metricIds(overview)).contains("notice-unread", "sales-active", "production-pending");
    }

    private JsonNode overview(Authentication actor) throws Exception {
        var response = http.perform(get("/api/dashboard/overview").with(authentication(actor)))
                .andReturn().getResponse();
        assertThat(response.getStatus()).as("GET /api/dashboard/overview").isEqualTo(200);
        return json.readTree(response.getContentAsByteArray());
    }

    private UUID departmentId(String code) {
        return db.queryForObject(
                "SELECT id FROM departments WHERE code = ? AND is_deleted = FALSE", UUID.class, code);
    }

    private UUID user(UUID department, String tag, String... permissionCodes) {
        return user(department, tag, false, permissionCodes);
    }

    private UUID user(UUID department, String tag, boolean superAdmin, String... permissionCodes) {
        UUID employee = UUID.randomUUID();
        UUID user = UUID.randomUUID();
        db.update("""
                INSERT INTO employees(id, code, full_name, id_type, department_id, hire_date,
                                      status, employment_type)
                VALUES (?, ?, ?, '其他', ?, DATE '2026-01-01', 'active', 'regular')
                """, employee, "EMP-OVW-" + tag, "概览测试员工-" + tag, department);
        db.update("""
                INSERT INTO users(id, employee_id, login_account, password_hash,
                                  must_change_password, is_super_admin, status)
                VALUES (?, ?, ?, 'x', false, ?, 'active')
                """, user, employee, "USR-OVW-" + tag, superAdmin);
        for (String code : permissionCodes) {
            db.update("""
                    INSERT INTO user_permission_overrides(user_id, permission_id, effect)
                    SELECT ?, p.id, 'grant' FROM permissions p WHERE p.code = ?
                    """, user, code);
        }
        return user;
    }

    private UUID employeeOf(UUID user) {
        return db.queryForObject("SELECT employee_id FROM users WHERE id = ?", UUID.class, user);
    }

    private Authentication auth(UUID userId) {
        fixture.loginAs(userId);
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        SecurityContextHolder.clearContext();
        return authentication;
    }

    private static Set<String> names(JsonNode object) {
        Set<String> names = new TreeSet<>();
        object.fieldNames().forEachRemaining(names::add);
        return names;
    }

    private static List<String> metricIds(JsonNode overview) {
        List<String> ids = new ArrayList<>();
        overview.path("metrics").forEach(metric -> ids.add(metric.path("id").asText()));
        return ids;
    }

    private static String tag() {
        return UUID.randomUUID().toString().substring(0, 8).toUpperCase(Locale.ROOT);
    }
}
