package com.uten.imp.common.util;

import com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DelegatingDataSource;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.testcontainers.containers.PostgreSQLContainer;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.util.*;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.mock;

/** Actual Hibernate bindings and PostgreSQL reads; fixture columns come from the current migrated catalog. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class EmployeeNameResolverBatchPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final List<String> STATEMENTS = Collections.synchronizedList(new ArrayList<>());
    private static EntityManagerFactory factory;
    private static JdbcTemplate db;
    private static NamedParameterJdbcTemplate measuredJdbc;
    private EntityManager em;
    private EmployeeNameResolver names;

    @BeforeAll static void database() {
        POSTGRES.start();
        var source = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        db = new JdbcTemplate(source);
        com.uten.imp.support.MigratedProjectionSchema.createCurrentTables(
                db, "employees", "users", "procurement_order_approval_cases");
        var measured = new DelegatingDataSource(source) {
            @Override public Connection getConnection() throws java.sql.SQLException {
                Connection connection = super.getConnection();
                return (Connection) Proxy.newProxyInstance(Connection.class.getClassLoader(),
                        new Class<?>[]{Connection.class}, (proxy, method, args) -> {
                            if (method.getName().startsWith("prepare") && args != null && args[0] instanceof String sql) {
                                STATEMENTS.add(sql);
                            }
                            try { return method.invoke(connection, args); }
                            catch (InvocationTargetException failure) { throw failure.getCause(); }
                        });
            }
        };
        measuredJdbc = new NamedParameterJdbcTemplate(measured);
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(measured);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.common.util");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto", "none"));
        bean.afterPropertiesSet();
        factory = bean.getObject();
    }

    @AfterAll static void close() {
        if (factory != null) factory.close();
        POSTGRES.stop();
    }

    @BeforeEach void reset() {
        db.execute("TRUNCATE employees, users, procurement_order_approval_cases");
        em = factory.createEntityManager();
        names = new EmployeeNameResolver(em);
        STATEMENTS.clear();
    }

    @AfterEach void closeEntityManager() { if (em != null) em.close(); }

    @Test void nullEmptyAndAllNullCollectionsPerformNoSqlAndAllowNullLookup() {
        for (Collection<UUID> ids : Arrays.<Collection<UUID>>asList(null, List.of(), Arrays.asList(null, null))) {
            assertThat(names.namesOf(ids)).isEmpty();
            assertThat(names.namesOf(ids).get(null)).isNull();
            assertThat(names.namesWithCodeOf(ids).get(null)).isNull();
        }
        assertThat(STATEMENTS).isEmpty();
    }

    @Test void directEmployeeWinsOverUserIdWhileDeletedEmployeesRemainHistoricalNames() {
        UUID direct = employee("001", "直接员工", false);
        UUID history = employee("002", "离职历史", true);
        UUID alias = user(UUID.randomUUID(), history, true);
        UUID collision = employee("003", "同号直接员工", true);
        user(collision, direct, false);
        UUID unknown = UUID.randomUUID();
        List<UUID> ids = Arrays.asList(direct, history, alias, collision, direct, unknown, null);
        Map<UUID, String> plain = names.namesOf(ids);
        Map<UUID, String> coded = names.namesWithCodeOf(ids);
        assertThat(STATEMENTS).hasSize(2);
        assertThat(plain).containsEntry(collision, "同号直接员工").containsEntry(alias, "离职历史");
        assertThat(coded).containsEntry(collision, "同号直接员工(003)").containsEntry(alias, "离职历史(002)");
        for (UUID id : ids) {
            assertThat(plain.get(id)).isEqualTo(names.nameOf(id));
            assertThat(coded.get(id)).isEqualTo(names.nameWithCodeOf(id));
        }
        assertThat(plain).doesNotContainKey(unknown);
        assertThatThrownBy(() -> plain.put(direct, "changed")).isInstanceOf(UnsupportedOperationException.class);
    }

    @Test void aHundredMixedCurrentAndLegacyIdsMatchSingleReadsWithOneSqlInsteadOf150() {
        List<UUID> ids = new ArrayList<>();
        for (int index = 0; index < 100; index++) {
            UUID employee = employee("P" + index, "同名员工", false);
            ids.add(index < 50 ? employee : user(UUID.randomUUID(), employee, false));
        }
        Map<UUID, String> individual = new LinkedHashMap<>();
        STATEMENTS.clear();
        ids.forEach(id -> individual.put(id, names.nameOf(id)));
        int singleStatements = STATEMENTS.size();
        STATEMENTS.clear();
        Map<UUID, String> batch = names.namesOf(ids);
        assertThat(singleStatements).isEqualTo(150);
        assertThat(batch).isEqualTo(individual);
        assertThat(STATEMENTS).hasSize(1);
        assertThat(db.queryForObject("SELECT count(*) FROM employees", Integer.class)).isEqualTo(100);
        System.out.println("EMPLOYEE-NAMES ids=100 singleStatements=" + singleStatements + " batchStatements=" + STATEMENTS.size());
    }

    @Test void largeCollectionsUseBoundedBatchesAndDoNotRepeatDuplicates() {
        List<UUID> ids = new ArrayList<>();
        for (int index = 0; index < EmployeeNameResolver.READ_BATCH_SIZE * 2 + 1; index++) {
            ids.add(employee("B" + index, "员工" + index, false));
        }
        List<UUID> duplicated = new ArrayList<>(ids);
        duplicated.addAll(ids);
        duplicated.add(null);
        STATEMENTS.clear();
        Map<UUID, String> resolved = names.namesOf(duplicated);
        assertThat(resolved).hasSize(ids.size());
        assertThat(STATEMENTS).hasSize(3);
        assertThat(STATEMENTS).allSatisfy(sql -> {
            assertThat(sql.stripLeading()).startsWith("WITH requested_ids");
            assertThat(sql.chars().filter(value -> value == '?').count()).isLessThanOrEqualTo(2L * EmployeeNameResolver.READ_BATCH_SIZE);
        });
    }

    @Test void aNewReadSeesRenamesAndChangedLegacyBindingsWithoutMutatingEarlierResults() {
        UUID first = employee("OLD", "原姓名", false);
        UUID second = employee("NEW", "接续姓名", false);
        UUID alias = user(UUID.randomUUID(), first, false);
        Map<UUID, String> initial = names.namesOf(List.of(first, alias));
        db.update("UPDATE employees SET full_name='更正姓名' WHERE id=?", first);
        db.update("UPDATE users SET employee_id=? WHERE id=?", second, alias);
        STATEMENTS.clear();
        Map<UUID, String> current = names.namesOf(List.of(first, alias));
        assertThat(current).containsEntry(first, "更正姓名").containsEntry(alias, "接续姓名");
        assertThat(initial).containsEntry(first, "原姓名").containsEntry(alias, "原姓名");
        assertThat(STATEMENTS).hasSize(1);
    }

    @Test void formattedBatchRetainsSingleLookupNullAndBlankCodeSemantics() {
        // The production schema requires a code. This projection can represent legacy/incomplete
        // values to prove optimization does not silently change SQL-null concatenation or fallback.
        UUID missingCode = employee(null, "无工号", false);
        UUID fallback = employee("F", "账号映射姓名", false);
        user(missingCode, fallback, false);
        UUID noFallback = employee(null, "未完整资料", false);
        UUID blankCode = employee("", "空工号", false);
        List<UUID> ids = List.of(missingCode, noFallback, blankCode);
        Map<UUID, String> plain = names.namesOf(ids);
        Map<UUID, String> coded = names.namesWithCodeOf(ids);
        assertThat(plain.get(missingCode)).isEqualTo("无工号");
        assertThat(coded.get(missingCode)).isEqualTo("账号映射姓名(F)");
        assertThat(coded.get(noFallback)).isNull();
        assertThat(coded.get(blankCode)).isEqualTo("空工号()");
        ids.forEach(id -> assertThat(coded.get(id)).isEqualTo(names.nameWithCodeOf(id)));
    }

    @ParameterizedTest @ValueSource(strings = {"PURCHASE", "SUBCONTRACT"})
    void procurementApprovalNamesRemainOneQuerySnapshotsAfterEmployeeRename(String orderType) {
        UUID employee = employee("REVIEW", "现在的姓名", true);
        UUID account = user(UUID.randomUUID(), employee, true);
        Map<UUID, Short> statuses = new LinkedHashMap<>();
        for (int index = 0; index < 20; index++) {
            UUID order = UUID.randomUUID();
            statuses.put(order, (short) 0);
            db.update("""
                    INSERT INTO procurement_order_approval_cases(id,order_type,order_id,status,attempt,version,
                        assignee_user_id,assignee_employee_id,assignee_name_snapshot)
                    VALUES(?,?,?,'PENDING',1,1,?,?,?)
                    """, UUID.randomUUID(), orderType, order, account, employee, index == 0 ? null : "审批时姓名");
        }
        var projection = new ProcurementApprovalProjectionQuery(measuredJdbc, mock(SecurityContextCurrentUser.class),
                mock(com.uten.imp.application.port.FinanceReviewerEligibilityPort.class));
        STATEMENTS.clear();
        var result = projection.latestForOrders(orderType, statuses);
        assertThat(result).hasSize(20);
        assertThat(result.get(statuses.keySet().iterator().next()).assigneeName()).isNull();
        assertThat(result.values()).allSatisfy(row -> {
            assertThat(row.assigneeName()).isIn(null, "审批时姓名");
            assertThat(row.assigneeEmployeeId()).isEqualTo(employee);
            assertThat(row.assigneeUserId()).isEqualTo(account);
        });
        assertThat(STATEMENTS).hasSize(1);
        assertThat(STATEMENTS.getFirst()).doesNotContain("FROM employees", "JOIN employees", "FROM users");
    }

    private UUID employee(String code, String name, boolean deleted) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO employees(id,code,full_name,is_deleted) VALUES(?,?,?,?)", id, code, name, deleted);
        return id;
    }

    private UUID user(UUID id, UUID employee, boolean deleted) {
        db.update("INSERT INTO users(id,employee_id,login_account,is_deleted) VALUES(?,?,?,?)", id, employee, id.toString(), deleted);
        return id;
    }
}
