package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.DepartmentPermissionAdminService;
import com.uten.imp.features.admin.PermissionOverrideAdminService;
import com.uten.imp.features.admin.dto.PermissionBulkScopeDto;
import com.uten.imp.features.admin.dto.PermissionChangeDto;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.visitor.VisitorAuthorities;
import com.uten.imp.features.visitor.VisitorDirectoryService;
import com.uten.imp.features.visitor.dto.VisitorScanDto.EmployeeDirectoryItem;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 授权管理的差量保存与业务事件(ADR-109 / permissions-02、audit-retention-settings-03)，
 * 在迁移到最新版本的真实库上验证：
 * <ul>
 *   <li>迁移后每个带部门矩阵的部门原样保存：0 行写入、0 条审计；</li>
 *   <li>加一个码：只插一行，只记一条带 added/removed 的业务事件；收回同理；</li>
 *   <li>对象全量范围等「不随批量」的码原样保留可保存；只能逐人授予的码加不进部门；</li>
 *   <li>「全部授权」由服务端按授权策略补齐，第二次再点什么都不写；</li>
 *   <li>全员基础包只收能放进基础包的码。</li>
 *   <li>个人「全部授权」：撤掉已有收回、部门已给的不重复加授、不随批量的码不带上，第二次 0 审计；</li>
 *   <li>两个超管同时保存同一部门：部门行串行化，只记一条真实改动的业务事件；</li>
 *   <li>访客搜接待人只列持接待访客权限的员工(白名单即权限目录，security-08)。</li>
 * </ul>
 * 同时量出旧写法(整表删掉再插回)与新写法在同一数据上的写入量，供报告前后对比。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000"})
@Import(ProductionJdbcMeasurement.Configuration.class)
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = PermissionAdministrationPostgresTest.Cleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class PermissionAdministrationPostgresTest {

    private static final PostgreSQLContainer<?> DATABASE = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final String SECRET = UUID.randomUUID() + "-" + UUID.randomUUID();

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry properties) {
        DATABASE.start();
        properties.add("spring.datasource.url", DATABASE::getJdbcUrl);
        properties.add("spring.datasource.username", DATABASE::getUsername);
        properties.add("spring.datasource.password", DATABASE::getPassword);
        properties.add("uten.jwt.secret", () -> SECRET);
        properties.add("uten.crypto.pgp-master-key", () -> SECRET);
        properties.add("uten.crypto.hmac-key", () -> SECRET);
        properties.add("uten.bootstrap.admin-login", () -> "perm-admin-bootstrap");
        properties.add("uten.bootstrap.admin-password", () -> SECRET + "Aa1!");
    }

    public static class Cleanup extends AbstractTestExecutionListener {
        @Override
        public int getOrder() {
            return new DirtiesContextTestExecutionListener().getOrder() - 1;
        }

        @Override
        public void afterTestClass(TestContext ignored) {
            DATABASE.stop();
        }
    }

    @Autowired JdbcTemplate jdbc;
    @Autowired PermissionResolver permissionResolver;
    @Autowired DepartmentPermissionAdminService departments;
    @Autowired PermissionOverrideAdminService overrides;
    @Autowired PlatformTransactionManager transactionManager;
    @Autowired VisitorDirectoryService visitorDirectory;
    @Autowired UserAccountRepository userAccounts;

    @BeforeEach
    void loginAsSuperAdmin() {
        UUID admin = jdbc.queryForObject(
                "SELECT id FROM users WHERE is_super_admin ORDER BY created_at LIMIT 1", UUID.class);
        // 引导超管首登必须改密(改密前只有改密权)；测试里视为已改过密。
        jdbc.update("UPDATE users SET must_change_password = false WHERE id = ?", admin);
        loginAs(admin);
    }

    @AfterEach
    void cleanup() {
        SecurityContextHolder.clearContext();
        ProductionJdbcMeasurement.end();
    }

    @Test
    void everyMigratedDepartmentMatrixSavesUnchangedWithoutWritesOrAudit() {
        List<UUID> seeded = jdbc.queryForList(
                "SELECT DISTINCT department_id FROM department_permissions ORDER BY department_id", UUID.class);
        assertFalse(seeded.isEmpty(), "迁移后应有部门矩阵");

        int largest = 0;
        UUID largestDepartment = null;
        for (UUID department : seeded) {
            List<String> codes = departments.getDepartmentPermissions(department).permissions();
            if (codes.size() > largest) {
                largest = codes.size();
                largestDepartment = department;
            }
            long auditBefore = auditRows();
            PermissionChangeDto change = departments.setDepartmentPermissions(department, codes);
            assertTrue(change.isEmpty(), "原样保存不应有差量: " + department);
            assertEquals(auditBefore, auditRows(), "原样保存不写任何审计: " + department);
            assertEquals(Set.copyOf(codes),
                    Set.copyOf(departments.getDepartmentPermissions(department).permissions()));
        }

        // 新写法：原样保存的语句数(只有读，没有写)。
        UUID target = largestDepartment;
        List<String> targetCodes = departments.getDepartmentPermissions(target).permissions();
        ProductionJdbcMeasurement.Sample after = ProductionJdbcMeasurement.begin();
        try {
            departments.setDepartmentPermissions(target, targetCodes);
        } finally {
            ProductionJdbcMeasurement.end();
        }

        // 旧写法(整表删掉再插回同样的码)在同一数据上的审计行数：只量，不提交。
        long[] oldAuditRows = new long[1];
        TransactionTemplate rollbackOnly = new TransactionTemplate(transactionManager);
        rollbackOnly.executeWithoutResult(status -> {
            long before = auditRows();
            List<Map<String, Object>> rows = jdbc.queryForList(
                    "SELECT department_id, permission_id FROM department_permissions WHERE department_id = ?",
                    target);
            jdbc.update("DELETE FROM department_permissions WHERE department_id = ?", target);
            for (Map<String, Object> row : rows) {
                jdbc.update("INSERT INTO department_permissions(department_id, permission_id) VALUES (?, ?)",
                        row.get("department_id"), row.get("permission_id"));
            }
            oldAuditRows[0] = auditRows() - before;
            status.setRollbackOnly();
        });
        System.out.printf(
                "MEASURE permission-matrix-unchanged-save departments=%d largestCodes=%d "
                        + "newJdbcCalls=%d newAuditRows=0 oldDeleteReinsertStatements=%d oldAuditRows=%d%n",
                seeded.size(), largest, after.jdbcCalls, 1 + largest, oldAuditRows[0]);
        assertTrue(after.jdbcCalls <= 12, "原样保存只读不写，语句数有上限，实际 " + after.jdbcCalls);
    }

    @Test
    void addingAndRevokingWriteOnlyTheDeltaAndOneBusinessEvent() {
        UUID department = departmentWith("finance:view:all");
        List<String> codes = departments.getDepartmentPermissions(department).permissions();
        assertTrue(codes.contains("finance:view:all"), "财务部原有的看全部钱流数据得以保留");
        String addable = firstCodeWithPolicy("NORMAL", codes);

        long auditBefore = auditRows();
        long eventsBefore = events("department_permission_change", department);
        List<String> desired = new java.util.ArrayList<>(codes);
        desired.add(addable);
        PermissionChangeDto added = departments.setDepartmentPermissions(department, desired);
        assertEquals(List.of(addable), added.added());
        assertTrue(added.removed().isEmpty());
        assertEquals(eventsBefore + 1, events("department_permission_change", department));
        String after = jdbc.queryForObject("""
                SELECT after::text FROM audit_log
                WHERE action = 'department_permission_change' AND target_id = ?
                ORDER BY created_at DESC, id DESC LIMIT 1
                """, String.class, department.toString());
        assertTrue(after.contains(addable) && after.contains("\"removed\""), after);
        // 一条业务事件 + 一行授权行的触发器审计；不会再有整表删插带来的成百行。
        assertTrue(auditRows() - auditBefore <= 2, "差量保存的审计行数: " + (auditRows() - auditBefore));

        PermissionChangeDto revoked = departments.setDepartmentPermissions(department, codes);
        assertEquals(List.of(addable), revoked.removed());
        assertEquals(eventsBefore + 2, events("department_permission_change", department));
    }

    @Test
    void individualOnlyCodesCannotBeGivenToADepartmentButStayRevocable() {
        UUID department = anyDepartment();
        List<String> codes = departments.getDepartmentPermissions(department).permissions();
        String individualOnly = firstCodeWithPolicy("INDIVIDUAL_ONLY", codes);
        List<String> desired = new java.util.ArrayList<>(codes);
        desired.add(individualOnly);
        long auditBefore = auditRows();
        assertThrows(ApiException.class, () -> departments.setDepartmentPermissions(department, desired));
        assertEquals(auditBefore, auditRows(), "被拒绝的保存什么都不写");
        assertFalse(departments.getDepartmentPermissions(department).permissions().contains(individualOnly));
    }

    @Test
    void grantAllUsesTheCatalogPolicyAndIsIdempotent() {
        UUID department = anyDepartment();
        String module = jdbc.queryForObject("""
                SELECT module FROM permissions
                WHERE grant_policy = ARRAY['NORMAL']::text[] AND module IS NOT NULL
                GROUP BY module ORDER BY count(*) DESC LIMIT 1
                """, String.class);
        PermissionChangeDto first = departments.grantAll(department, new PermissionBulkScopeDto(module, null));
        Set<String> excluded = new HashSet<>(jdbc.queryForList("""
                SELECT code FROM permissions
                WHERE grant_policy && ARRAY['BULK_EXCLUDED','INDIVIDUAL_ONLY','SUPERADMIN_ONLY']::text[]
                """, String.class));
        assertTrue(first.added().stream().noneMatch(excluded::contains),
                "批量授权不能带上不随批量 / 逐人 / 超管专属的码: " + first.added());
        long auditBefore = auditRows();
        PermissionChangeDto second = departments.grantAll(department, new PermissionBulkScopeDto(module, null));
        assertTrue(second.isEmpty(), "第二次全部授权没有新增");
        assertEquals(auditBefore, auditRows(), "没有新增就不写审计");
    }

    @Test
    void personalOverridesWriteOneEventPerRealChangeAndNothingWhenUnchanged() {
        UUID department = anyDepartment();
        UUID employee = UUID.randomUUID();
        UUID user = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id, code, full_name, id_type, department_id, hire_date, status, employment_type)
                VALUES (?, ?, '授权测试员工', '其他', ?, DATE '2026-01-01', 'active', 'regular')
                """, employee, "PERM-" + employee, department);
        jdbc.update("""
                INSERT INTO users(id, employee_id, login_account, password_hash, must_change_password,
                                  is_super_admin, status)
                VALUES (?, ?, ?, 'x', false, false, 'active')
                """, user, employee, "perm-" + user);
        List<String> inherited = departments.getDepartmentPermissions(department).permissions();
        String grant = firstCodeWithPolicy("NORMAL", inherited);

        long eventsBefore = events("user_permission_override_change", user);
        PermissionChangeDto added = overrides.setPermissionOverrides(user, List.of(grant), List.of());
        assertEquals(List.of("grant:" + grant), added.added());
        assertEquals(eventsBefore + 1, events("user_permission_override_change", user));

        long auditBefore = auditRows();
        PermissionChangeDto unchanged = overrides.setPermissionOverrides(user, List.of(grant), List.of());
        assertTrue(unchanged.isEmpty());
        assertEquals(auditBefore, auditRows(), "个人覆盖原样保存 0 审计");
    }

    @Test
    void baselineAcceptsOnlyBaselineEligibleCodes() {
        List<String> baseline = departments.baseline().permissions();
        String bulkExcluded = firstCodeWithPolicy("BULK_EXCLUDED", baseline);
        List<String> rejected = new java.util.ArrayList<>(baseline);
        rejected.add(bulkExcluded);
        assertThrows(ApiException.class, () -> departments.setBaseline(rejected));

        String normal = firstCodeWithPolicy("NORMAL", baseline);
        List<String> desired = new java.util.ArrayList<>(baseline);
        desired.add(normal);
        long eventsBefore = jdbc.queryForObject(
                "SELECT count(*) FROM audit_log WHERE action = 'permission_baseline_change'", Long.class);
        assertEquals(List.of(normal), departments.setBaseline(desired).added());
        assertEquals(eventsBefore + 1, (long) jdbc.queryForObject(
                "SELECT count(*) FROM audit_log WHERE action = 'permission_baseline_change'", Long.class));
        assertTrue(departments.setBaseline(baseline).removed().contains(normal));
    }

    @Test
    void personalGrantAllLiftsRevokesSkipsInheritedAndExcludedCodesAndIsIdempotent() {
        UUID department = departmentWith("finance:view:all");
        UUID user = createEmployeeUser(department, "授权测试全部授权");
        List<String> inherited = departments.getDepartmentPermissions(department).permissions();
        String revoked = jdbc.queryForList("""
                        SELECT code FROM permissions
                        WHERE grant_policy = ARRAY['NORMAL']::text[] AND NOT baseline AND module IS NOT NULL
                        ORDER BY code
                        """, String.class).stream()
                .filter(inherited::contains)
                .findFirst()
                .orElseThrow();
        String module = jdbc.queryForObject("SELECT module FROM permissions WHERE code = ?", String.class, revoked);
        overrides.setPermissionOverrides(user, List.of(), List.of(revoked));
        assertTrue(overrides.getPermissionOverrides(user).revokes().contains(revoked), "前置：先收回一个部门给的码");

        // 部门配置按上级部门向下生效：以解析器给出的部门继承集合为准。
        TransactionTemplate readOnly = new TransactionTemplate(transactionManager);
        readOnly.setReadOnly(true);
        Set<String> inheritedAll = readOnly.execute(status -> new HashSet<>(permissionResolver
                .breakdownOf(userAccounts.findById(user).orElseThrow()).departmentPermissions()));
        PermissionChangeDto first = overrides.grantAll(user, new PermissionBulkScopeDto(module, null));

        var after = overrides.getPermissionOverrides(user);
        assertFalse(after.revokes().contains(revoked), "全部授权撤掉该模块里已有的收回");
        assertFalse(after.grants().contains(revoked), "部门已经给了的码不重复加授");
        assertTrue(first.removed().contains("revoke:" + revoked), first.toString());
        Set<String> excluded = new HashSet<>(jdbc.queryForList("""
                SELECT code FROM permissions
                WHERE grant_policy && ARRAY['BULK_EXCLUDED','INDIVIDUAL_ONLY','SUPERADMIN_ONLY']::text[]
                """, String.class));
        assertTrue(after.grants().stream().noneMatch(excluded::contains),
                "不随批量 / 逐人 / 超管专属的码不带上: " + after.grants());
        assertTrue(after.grants().stream().noneMatch(inheritedAll::contains), "部门已给的码一律不加授");
        List<String> expectedGrants = jdbc.queryForList("""
                SELECT code FROM permissions
                WHERE module = ? AND NOT baseline
                  AND NOT (grant_policy && ARRAY['BULK_EXCLUDED','INDIVIDUAL_ONLY','SUPERADMIN_ONLY']::text[])
                ORDER BY code
                """, String.class, module).stream().filter(code -> !inheritedAll.contains(code)).toList();
        assertEquals(Set.copyOf(expectedGrants), Set.copyOf(after.grants()),
                "本模块可批量、还没继承到的码逐条补一条加授");
        Boolean inheritsAgain = readOnly.execute(status -> permissionResolver
                .permsOf(userAccounts.findById(user).orElseThrow()).contains(revoked));
        assertTrue(Boolean.TRUE.equals(inheritsAgain), "收回撤掉后重新从部门继承到");

        long auditBefore = auditRows();
        PermissionChangeDto second = overrides.grantAll(user, new PermissionBulkScopeDto(module, null));
        assertTrue(second.isEmpty(), "第二次全部授权没有改动");
        assertEquals(auditBefore, auditRows(), "没有改动就 0 审计");
    }

    @Test
    void concurrentSavesOfOneDepartmentRecordOnlyTheRealChange() throws Exception {
        UUID department = anyDepartment();
        List<String> codes = departments.getDepartmentPermissions(department).permissions();
        String addable = firstCodeWithPolicy("NORMAL", codes);
        List<String> desired = new java.util.ArrayList<>(codes);
        desired.add(addable);
        UUID admin = jdbc.queryForObject(
                "SELECT id FROM users WHERE is_super_admin ORDER BY created_at LIMIT 1", UUID.class);
        long eventsBefore = events("department_permission_change", department);

        var start = new java.util.concurrent.CountDownLatch(1);
        var pool = java.util.concurrent.Executors.newFixedThreadPool(2);
        try {
            List<java.util.concurrent.Future<Object>> results = new java.util.ArrayList<>();
            for (int i = 0; i < 2; i++) {
                results.add(pool.submit(() -> {
                    loginAs(admin);
                    start.await();
                    try {
                        return departments.setDepartmentPermissions(department, desired);
                    } catch (ApiException conflict) {
                        return conflict;
                    } finally {
                        SecurityContextHolder.clearContext();
                    }
                }));
            }
            start.countDown();
            List<Object> outcomes = new java.util.ArrayList<>();
            for (var result : results) {
                outcomes.add(result.get(60, java.util.concurrent.TimeUnit.SECONDS));
            }
            long added = outcomes.stream().filter(outcome -> outcome instanceof PermissionChangeDto change
                    && change.added().equals(List.of(addable))).count();
            assertEquals(1, added, "只有一个保存真的加上了这个码: " + outcomes);
            assertTrue(outcomes.stream().allMatch(outcome -> outcome instanceof PermissionChangeDto),
                    "部门行串行化：后到者读到先到者的结果，是「无改动」而不是冲突: " + outcomes);
        } finally {
            pool.shutdownNow();
        }
        assertEquals(eventsBefore + 1, events("department_permission_change", department),
                "两次并发保存只记一条真实改动的业务事件");
        departments.setDepartmentPermissions(department, codes);
    }

    @Test
    void visitorHostSearchListsOnlyEmployeesHoldingTheHostPermission() {
        UUID hostDepartment = jdbc.queryForObject("SELECT id FROM departments WHERE code = 'DEPT_SALES'", UUID.class);
        UUID otherDepartment = jdbc.queryForObject("SELECT id FROM departments WHERE code = 'SUB_WH'", UUID.class);
        UUID salesHost = createEmployeeUser(hostDepartment, "访接待甲");
        createEmployeeUser(otherDepartment, "访接待乙");
        UUID revokedHost = createEmployeeUser(hostDepartment, "访接待丙");
        UUID grantedClerk = createEmployeeUser(otherDepartment, "访接待丁");
        overrides.setPermissionOverrides(revokedHost, List.of(), List.of("visitor:host_confirm"));
        overrides.setPermissionOverrides(grantedClerk, List.of("visitor:host_confirm"), List.of());

        AuthUser principal = AuthUser.visitor(UUID.randomUUID(), "13900000000", "V-PERM", VisitorAuthorities.ALL);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(principal, null, principal.getAuthorities()));
        long searchesBefore = jdbc.queryForObject(
                "SELECT count(*) FROM audit_log WHERE action = 'visitor_host_search'", Long.class);
        ProductionJdbcMeasurement.Sample sample = ProductionJdbcMeasurement.begin();
        List<EmployeeDirectoryItem> hosts;
        try {
            hosts = visitorDirectory.searchHosts("员工-访接待", "127.0.0.1");
        } finally {
            ProductionJdbcMeasurement.end();
        }

        Set<String> names = new HashSet<>(hosts.stream().map(EmployeeDirectoryItem::name).toList());
        assertEquals(Set.of("员工-访接待甲", "员工-访接待丁"), names,
                "综合营销的人可接待；仓储的人没被授予就搜不到；个人收回后搜不到；个人授予后搜得到");
        assertEquals(employeeOf(salesHost), hosts.stream()
                .filter(host -> host.name().equals("员工-访接待甲")).findFirst().orElseThrow().id());
        assertEquals(searchesBefore + 1, (long) jdbc.queryForObject(
                "SELECT count(*) FROM audit_log WHERE action = 'visitor_host_search'", Long.class),
                "每次查询写一条审计");
        System.out.printf("MEASURE visitor-host-search candidates=4 returned=%d jdbcCalls=%d%n",
                hosts.size(), sample.jdbcCalls);
    }

    private UUID createEmployeeUser(UUID department, String tag) {
        UUID employee = UUID.randomUUID();
        UUID user = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id, code, full_name, id_type, department_id, hire_date, status, employment_type)
                VALUES (?, ?, ?, '其他', ?, DATE '2026-01-01', 'active', 'regular')
                """, employee, "PERM-" + employee, "员工-" + tag, department);
        jdbc.update("""
                INSERT INTO users(id, employee_id, login_account, password_hash, must_change_password,
                                  is_super_admin, status)
                VALUES (?, ?, ?, 'x', false, false, 'active')
                """, user, employee, "perm-" + user);
        return user;
    }

    private UUID employeeOf(UUID user) {
        return jdbc.queryForObject("SELECT employee_id FROM users WHERE id = ?", UUID.class, user);
    }

    private long auditRows() {
        return jdbc.queryForObject("SELECT count(*) FROM audit_log", Long.class);
    }

    private long events(String action, UUID target) {
        return jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE action = ? AND target_id = ?",
                Long.class, action, target.toString());
    }

    private UUID departmentWith(String code) {
        return jdbc.queryForObject("""
                SELECT dp.department_id FROM department_permissions dp
                JOIN permissions p ON p.id = dp.permission_id
                WHERE p.code = ? ORDER BY dp.department_id LIMIT 1
                """, UUID.class, code);
    }

    private UUID anyDepartment() {
        return jdbc.queryForObject(
                "SELECT DISTINCT department_id FROM department_permissions ORDER BY department_id LIMIT 1",
                UUID.class);
    }

    private String firstCodeWithPolicy(String policy, List<String> except) {
        return jdbc.queryForList("""
                        SELECT code FROM permissions
                        WHERE grant_policy = ARRAY[?]::text[] ORDER BY code
                        """, String.class, policy).stream()
                .filter(code -> !except.contains(code))
                .findFirst()
                .orElseThrow();
    }

    private void loginAs(UUID userId) {
        Map<String, Object> u = jdbc.queryForMap("""
                SELECT employee_id, login_account, is_super_admin, must_change_password, status
                FROM users WHERE id = ?
                """, userId);
        UUID employeeId = (UUID) u.get("employee_id");
        boolean superAdmin = Boolean.TRUE.equals(u.get("is_super_admin"));
        PermissionResolver.AuthorizationSnapshot snapshot =
                permissionResolver.authorizationSnapshot(userId, employeeId, superAdmin);
        AuthUser principal = new AuthUser(userId, employeeId, (String) u.get("login_account"),
                snapshot.permissions(), Boolean.TRUE.equals(u.get("must_change_password")),
                "active".equals(u.get("status")), superAdmin);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(principal, null, principal.getAuthorities()));
    }
}
