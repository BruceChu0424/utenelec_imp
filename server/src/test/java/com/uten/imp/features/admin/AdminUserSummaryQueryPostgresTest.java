package com.uten.imp.features.admin;

import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.admin.dto.UserSummary;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DelegatingDataSource;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Owns an isolated disposable PostgreSQL container; never uses application datasource settings. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class AdminUserSummaryQueryPostgresTest {
    static final PostgreSQLContainer DATABASE = new PostgreSQLContainer("postgres:16-alpine").withReuse(false);
    static final UUID DEPARTMENT = UUID.randomUUID();
    static final UUID POSITION = UUID.randomUUID();
    final List<String> statements = new ArrayList<>();
    JdbcTemplate jdbc;
    AdminUserSummaryQuery query;
    ProvisionCandidateQuery provision;

    @BeforeAll static void start() {
        DATABASE.start();
        var jdbc = new JdbcTemplate(new DriverManagerDataSource(
                DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword()));
        // Complete migrated columns/defaults; retain this oracle's original keys and constraints.
        MigratedProjectionSchema.createCurrentColumns(jdbc,
                "departments", "positions", "employees", "users", "employee_sensitive");
        jdbc.execute("""
                ALTER TABLE departments ADD PRIMARY KEY (id);
                ALTER TABLE positions ADD PRIMARY KEY (id);
                ALTER TABLE employees ADD PRIMARY KEY (id);
                ALTER TABLE users ADD PRIMARY KEY (id);
                ALTER TABLE employee_sensitive ADD PRIMARY KEY (employee_id);
                ALTER TABLE users ADD UNIQUE (employee_id), ADD UNIQUE (login_account);
                ALTER TABLE departments ALTER COLUMN is_deleted SET NOT NULL;
                ALTER TABLE employees ALTER COLUMN is_deleted SET NOT NULL;
                ALTER TABLE users ALTER COLUMN is_super_admin SET NOT NULL, ALTER COLUMN status SET NOT NULL, ALTER COLUMN must_change_password SET NOT NULL, ALTER COLUMN remote_access SET NOT NULL, ALTER COLUMN is_deleted SET NOT NULL;
                """);
        jdbc.update("INSERT INTO departments(id,name) VALUES (?, '部门')", DEPARTMENT);
        jdbc.update("INSERT INTO positions(id,name) VALUES (?, '岗位')", POSITION);
    }

    @AfterAll static void stop() { DATABASE.stop(); }

    @BeforeEach void reset() {
        var source = new DriverManagerDataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword());
        var counted = new DelegatingDataSource(source) {
            @Override public Connection getConnection() throws SQLException {
                Connection delegate = super.getConnection();
                return (Connection) Proxy.newProxyInstance(Connection.class.getClassLoader(), new Class<?>[]{Connection.class},
                        (proxy, method, args) -> {
                            if (method.getName().equals("prepareStatement") && args[0] instanceof String sql) statements.add(sql);
                            try { return method.invoke(delegate, args); }
                            catch (InvocationTargetException failure) { throw failure.getCause(); }
                        });
            }
        };
        jdbc = new JdbcTemplate(source);
        jdbc.execute("TRUNCATE users, employees, employee_sensitive");
        var support = mock(AdminUserSupport.class);
        when(support.canSupportTarget(any(UUID.class), anyBoolean())).thenAnswer(call -> !call.<Boolean>getArgument(1));
        when(support.canResetPasswordTarget(any(UUID.class), any(UUID.class), anyBoolean())).thenReturn(true);
        query = new AdminUserSummaryQuery(new NamedParameterJdbcTemplate(counted), support);
        provision = new ProvisionCandidateQuery(new NamedParameterJdbcTemplate(counted));
        statements.clear();
    }

    @Test void wholeIdentityTiersSingleCharactersAndCrossFieldWordsStayAccurateBeforePaging() {
        UUID contains = fixture("附加陈力尾", "E103", "account-contains");
        UUID prefix = fixture("陈力助手", "E102", "account-prefix");
        UUID exact = fixture("陈力", "E101", "account-exact");
        assertEquals(List.of(exact, prefix, contains), ids("陈力"));
        assertEquals(java.util.Set.of(exact, prefix, contains), java.util.Set.copyOf(ids("力")));
        assertEquals(List.of(prefix), ids("陈力\u3000e102"));
        assertEquals(List.of(contains), ids("ACCOUNT-CONTAINS"));
        assertEquals(List.of(), ids("陈力 不存在"));
        for (int page = 1; page <= 3; page++) {
            var result = query.list(Pageables.of(page, 1), "陈力", null);
            assertEquals(3, result.getTotalElements());
            assertEquals(List.of(exact, prefix, contains).get(page - 1), result.getContent().getFirst().getId());
        }
    }

    @Test void wildcardCharactersAreLiteralAndDepartedAccountsRemainVisible() {
        UUID literal = fixture("字面_%\\", "E201", "literal-account");
        fixture("字面AX", "E202", "lookalike-account");
        jdbc.update("UPDATE employees SET status='resigned' WHERE id=(SELECT employee_id FROM users WHERE id=?)", literal);
        assertEquals(List.of(literal), ids("_%\\"));
        var summary = query.list(Pageables.of(1, 20), "_%\\", null).getContent().getFirst();
        assertFalse(summary.isCurrentEmployee());
        assertEquals("resigned", summary.getEmployeeStatus());
        assertEquals("部门", summary.getDepartmentName());
        assertEquals("岗位", summary.getPositionName());
        assertTrue(summary.getAccountSupportAllowed());
        UUID employeeId = summary.getEmployeeId();
        jdbc.update("UPDATE users SET status='disabled' WHERE id=?", literal);
        UserSummary linked = query.byEmployeeId(employeeId).orElseThrow();
        assertEquals("disabled", linked.getStatus());
        assertEquals("resigned", linked.getEmployeeStatus());
        assertFalse(linked.isCurrentEmployee());
        assertEquals(Boolean.TRUE, linked.getAccountSupportAllowed());
        assertEquals(employeeId, linked.getEmployeeId());
    }

    @Test void boundedPageReadsExactlyTwoStatementsRegardlessOfReturnedEmployeeCount() {
        for (int index = 0; index < 120; index++) {
            UUID user = fixture("分页员工" + index, "PAGE-" + index, "page-" + index);
            if (index < 20) {
                UUID department = UUID.randomUUID(), position = UUID.randomUUID();
                jdbc.update("INSERT INTO departments(id,name) VALUES (?, ?)", department, "分页部门" + index);
                jdbc.update("INSERT INTO positions(id,name) VALUES (?, ?)", position, "分页岗位" + index);
                jdbc.update("UPDATE employees SET department_id=?,position_id=? WHERE id="
                        + "(SELECT employee_id FROM users WHERE id=?)", department, position, user);
            }
        }
        for (int size : List.of(1, 20, 100)) {
            statements.clear();
            var result = query.list(Pageables.of(1, size), "分页", null);
            assertEquals(size, result.getContent().size());
            assertEquals(120, result.getTotalElements());
            assertEquals(2, statements.size(), "One bounded projection and one count, without per-row reads");
            assertTrue(statements.stream().noneMatch(sql -> sql.contains("password_hash") || sql.contains("SELECT *")));
            assertTrue(statements.getFirst().contains("LIMIT ? OFFSET ?"));
        }
        statements.clear();
        assertEquals(0, query.list(Pageables.of(1, 20), "找不到", null).getTotalElements());
        assertEquals(1, statements.size(), "Retain partial-page count elision");
    }

    @Test void exactSummaryUsesListVisibilityAndKeepsAllDisplayedAccountFields() {
        UUID visible = fixture("可见", "E301", "visible");
        UUID deletedAccount = fixture("删除账号", "E302", "deleted-account");
        UUID deletedEmployee = fixture("删除员工", "E303", "deleted-employee");
        jdbc.update("UPDATE users SET is_deleted=TRUE WHERE id=?", deletedAccount);
        jdbc.update("UPDATE employees SET is_deleted=TRUE WHERE id=(SELECT employee_id FROM users WHERE id=?)", deletedEmployee);
        OffsetDateTime expires = OffsetDateTime.parse("2026-11-05T08:00:00Z");
        jdbc.update("UPDATE users SET status='locked', remote_access=TRUE, must_change_password=TRUE,"
                + " temp_password_expires_at=?, last_login_at=? WHERE id=?", expires, expires.minusDays(1), visible);
        var summary = query.byId(visible).orElseThrow();
        assertEquals("locked", summary.getStatus());
        assertTrue(summary.isRemoteAccess());
        assertTrue(summary.isMustChangePassword());
        assertEquals(expires.toInstant(), summary.getTempPasswordExpiresAt().toInstant());
        assertTrue(query.byId(deletedAccount).isEmpty());
        assertTrue(query.byId(deletedEmployee).isEmpty());
        assertTrue(query.byId(UUID.randomUUID()).isEmpty());
        assertEquals(List.of(visible), query.list(Pageables.of(1, 20), null, "locked").getContent().stream()
                .map(UserSummary::getId).toList());
    }

    @Test void accountWithoutAnEmployeeAndExistingEmployeeDeepLinkKeepTheirDifferentContracts() {
        UUID orphan = UUID.randomUUID();
        jdbc.update("INSERT INTO users(id,login_account,is_super_admin,status,must_change_password,remote_access,is_deleted) VALUES (?, 'unbound',false,'active',false,false,false)", orphan);
        var summary = query.byId(orphan).orElseThrow();
        assertNull(summary.getEmployeeId());
        assertNull(summary.getDepartmentName());
        assertFalse(summary.isCurrentEmployee());
        UUID retained = fixture("保留历史", "E401", "retained");
        UUID employee = jdbc.queryForObject("SELECT employee_id FROM users WHERE id=?", UUID.class, retained);
        jdbc.update("UPDATE employees SET is_deleted=TRUE WHERE id=?", employee);
        assertTrue(query.byId(retained).isEmpty());
        assertEquals(retained, query.byEmployeeId(employee).orElseThrow().getId(),
                "Existing super-admin employee deep link retains its prior historical account contract");
    }

    private List<UUID> ids(String search) {
        return query.list(Pageables.of(1, 20), search, null).getContent().stream().map(UserSummary::getId).toList();
    }

    @Test void provisionProjectionKeepsPhoneReadinessEligibilityAndOneSharedLegacyOrder() {
        UUID exact = unprovisioned("开户人员", "E101", "active", false, "opaque-phone-ciphertext");
        UUID prefix = unprovisioned("开户人员助理", "E102", "onLeave", false, null);
        UUID contains = unprovisioned("其他开户人员", "E103", "probation", false, " \t\r\n");
        unprovisioned("开户人员离职", "E104", "resigned", false, null);
        unprovisioned("开户人员已删", "E105", "active", true, null);
        fixture("开户人员已开号", "E106", "existing-account");
        var first = provision.provisionPage("开户人员", 1, 1, null, false);
        assertEquals(3, first.getTotal());
        assertEquals(exact, first.getItems().getFirst().employeeId());
        assertTrue(first.getItems().getFirst().hasPhone());
        var full = provision.provisionPage("开户人员", 1, 100, DEPARTMENT, true);
        assertEquals(List.of(exact, prefix, contains), full.getItems().stream().map(row -> row.employeeId()).toList());
        assertEquals(List.of(true, false, false), full.getItems().stream().map(row -> row.hasPhone()).toList());
        assertEquals(full.getItems(), provision.provisionLegacy("开户人员", 5001));
        assertEquals(prefix, provision.provisionPage("开户人员\u3000E102", 1, 100, null, false).getItems().getFirst().employeeId());
        assertTrue(statements.stream().noneMatch(sql -> sql.contains("id_card") || sql.contains("bank_account") || sql.contains("decrypt")),
                "Readiness must not read/decrypt other sensitive fields");
    }

    @Test void provisioningDirectoryAboveFiveThousandStillReadsOnlyTheRequestedPage() {
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,status,department_id,position_id)
                SELECT md5('provision-page-'||n)::uuid,'LARGE-'||lpad(n::text,6,'0'),
                       '开户大样本'||n,'active',?,? FROM generate_series(1,5005) n
                """, DEPARTMENT, POSITION);
        statements.clear();
        var first = provision.provisionPage("开户大样本", 1, 100, null, false);
        assertEquals(5005, first.getTotal()); assertEquals(100, first.getItems().size());
        assertEquals(2, statements.size());
        statements.clear();
        var last = provision.provisionPage("开户大样本", 51, 100, null, false);
        assertEquals(5005, last.getTotal()); assertEquals(5, last.getItems().size());
        assertEquals(1, statements.size());
    }

    private UUID unprovisioned(String name, String code, String status, boolean deleted, String phone) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO employees(id,code,full_name,status,department_id,position_id,is_deleted) VALUES (?,?,?,?,?,?,?)",
                id, code, name, status, DEPARTMENT, POSITION, deleted);
        if (phone != null) jdbc.update("INSERT INTO employee_sensitive(employee_id,phone_enc) VALUES (?,?)", id, phone);
        return id;
    }

    private UUID fixture(String name, String code, String login) {
        UUID employee = UUID.randomUUID();
        UUID user = UUID.randomUUID();
        jdbc.update("INSERT INTO employees(id,code,full_name,status,department_id,position_id) VALUES (?,?,?,'active',?,?)",
                employee, code, name, DEPARTMENT, POSITION);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,is_super_admin,status,must_change_password,remote_access,is_deleted) VALUES (?,?,?,'excluded-test-hash',false,'active',false,false,false)",
                user, employee, login);
        return user;
    }
}
