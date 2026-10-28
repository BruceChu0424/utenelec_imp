package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.reporting.export.*;
import com.uten.imp.common.export.*;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.*;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.interceptor.TransactionInterceptor;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.Connection;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real source triggers and real fresh transactions; only the existing permission engine's effective output is controlled. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ReadScopeVersionAuthorityPostgresTest {
    @org.junit.jupiter.api.io.TempDir Path directory;
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static DriverManagerDataSource dataSource;
    private static EntityManagerFactory factory;
    private static JpaTransactionManager transactions;
    private static JdbcTemplate db;
    private ReadScopeVersionAuthority authority;
    private OwnerVisibility visibility;
    private SubmitterPrincipalRestorer restorer;
    private UUID actor, employee, other;
    private AuthUser subject;
    private final AtomicBoolean delegated = new AtomicBoolean();
    private static final Set<String> BASE = Set.of("sales_report:view", "sales_report:export", "client:view");

    @BeforeAll static void baseline() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("read_scope_versions");
        dataSource = new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword());
        db = new JdbcTemplate(dataSource);
        var bean = new LocalContainerEntityManagerFactoryBean(); bean.setDataSource(dataSource);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter()); bean.setPackagesToScan("com.uten.imp.security");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto", "none")); bean.afterPropertiesSet();
        factory = bean.getObject(); transactions = new JpaTransactionManager(factory);
    }
    @AfterAll static void closeDatabase() throws Exception {
        if (factory != null) {
            factory.close();
        }
        if (database != null) {
            database.close();
        }
    }

    @BeforeEach void identities() {
        delegated.set(false);
        actor = UUID.randomUUID(); employee = employee("reader"); other = employee("owner");
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin) VALUES(?,?,?,'test-only-fixture',false,false)",
                actor, employee, "scope-" + actor);
        var permissionEngine = mock(PermissionResolver.class);
        when(permissionEngine.authorizationSnapshot(actor, employee, false)).thenAnswer(call ->
                new PermissionResolver.AuthorizationSnapshot(permissions(), true));
        restorer = new SubmitterPrincipalRestorer(new NamedParameterJdbcTemplate(dataSource), new StaffAuthorityResolver(permissionEngine));
        var shared = SharedEntityManagerCreator.createSharedEntityManager(factory);
        visibility = new OwnerVisibility(new SecurityContextCurrentUser(), shared, new EmployeeHandoverVisibility(shared));
        var target = new ReadScopeVersionAuthority(new NamedParameterJdbcTemplate(dataSource), restorer, visibility);
        var proxy = new ProxyFactory(target); proxy.setProxyTargetClass(true);
        var transactionAdvice = new TransactionInterceptor();
        transactionAdvice.setTransactionManager(transactions);
        transactionAdvice.setTransactionAttributeSource(new AnnotationTransactionAttributeSource());
        transactionAdvice.afterPropertiesSet();
        proxy.addAdvice(transactionAdvice);
        authority = (ReadScopeVersionAuthority) proxy.getProxy();
        subject = user();
        var context = SecurityContextHolder.createEmptyContext();
        context.setAuthentication(new UsernamePasswordAuthenticationToken(subject, null, subject.getAuthorities()));
        SecurityContextHolder.setContext(context);
    }
    @AfterEach void clearContext() { SecurityContextHolder.clearContext(); }

    @Test void revokingOnlyDataScopesChangesTheVersionWithoutChangingRoleStampsAndAbaCannotReviveIt() {
        grant("sales");
        var stamps = restorer.currentStamps(actor).orElseThrow();
        String a = authority.scopeFor("sales", subject);
        assertThat(visibility.evaluate("sales", "sales:view:all").visibleOwners()).contains(other);
        db.update("DELETE FROM user_data_scopes WHERE user_id=? AND scope='sales'", actor);
        assertThat(restorer.currentStamps(actor).orElseThrow()).isEqualTo(stamps);
        String b = authority.scopeFor("sales", subject);
        grant("sales");
        String a2 = authority.scopeFor("sales", subject);
        assertThat(a).isNotEqualTo(b).isNotEqualTo(a2);
    }

    @Test void freshProbeEscapesAnOuterRepeatableSnapshotWithinTheSameRequestContext() {
        grant("sales"); String initial = authority.scopeFor("sales", subject);
        var requestContext = SecurityContextHolder.getContext();
        var outer = new TransactionTemplate(transactions);
        outer.setReadOnly(true); outer.setIsolationLevel(Connection.TRANSACTION_REPEATABLE_READ);
        outer.executeWithoutResult(status -> {
            assertThat(visibility.evaluate("sales", "sales:view:all").visibleOwners()).contains(other);
            var independent = new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword()));
            independent.update("DELETE FROM user_data_scopes WHERE user_id=? AND scope='sales'", actor);
            assertThat(authority.scopeFor("sales", subject)).isNotEqualTo(initial);
            assertThat(visibility.evaluate("sales", "sales:view:all").visibleOwners()).contains(other);
            assertThat(SecurityContextHolder.getContext()).isSameAs(requestContext);
        });
    }

    @Test void naturalDelegationExpiryIsObservedWithoutAnyRoleOrDataScopeDatabaseWrite() {
        var stamps = restorer.currentStamps(actor).orElseThrow(); long generation = generation("sales");
        delegated.set(true); AuthUser wide = user(); String before = authority.scopeFor("sales", wide);
        delegated.set(false);
        assertThat(authority.scopeFor("sales", subject)).isNotEqualTo(before);
        assertThatThrownBy(() -> authority.scopeFor("sales", wide)).isInstanceOfSatisfying(ApiException.class,
                failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.READ_SCOPE_CHANGED));
        assertThat(restorer.currentStamps(actor).orElseThrow()).isEqualTo(stamps); assertThat(generation("sales")).isEqualTo(generation);
    }

    @Test void appendOnlyEventsCountLateCommitsAndDoNotTakeAGlobalCounterRowLock() throws Exception {
        long before = generation("sales");
        UUID secondActor = UUID.randomUUID(), secondEmployee = employee("independent reader"), secondOwner = employee("independent owner");
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin) VALUES(?,?,?,'test-only-fixture',false,false)",
                secondActor, secondEmployee, "scope-" + secondActor);
        try (Connection a = dataSource.getConnection(); Connection b = dataSource.getConnection()) {
            a.setAutoCommit(false); b.setAutoCommit(false);
            // Both source statements finish while the other transaction is still open.
            try (var statement = a.prepareStatement("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id) VALUES(?,'sales',?)")) {
                statement.setObject(1, actor); statement.setObject(2, other); statement.executeUpdate();
            }
            try (var statement = b.prepareStatement("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id) VALUES(?,'sales',?)")) {
                // Different recipients avoid the existing per-recipient authorization lock;
                // only a newly introduced global generation lock could serialize these writes.
                statement.setObject(1, secondActor); statement.setObject(2, secondOwner); statement.setQueryTimeout(5); statement.executeUpdate();
            }
            b.commit(); assertThat(generation("sales")).isEqualTo(before + 1);
            String afterNewerCommit = authority.scopeFor("sales", subject);
            a.commit(); assertThat(generation("sales")).isEqualTo(before + 2);
            assertThat(authority.scopeFor("sales", subject)).isNotEqualTo(afterNewerCommit);
        }
    }

    @Test void oneTransactionProducesOneEventAndRollbackProducesNone() throws Exception {
        long before = generation("sales");
        UUID secondOwner = employee("second owner");
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            try (var statement = connection.prepareStatement("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id) VALUES(?,'sales',?),(?,'sales',?)")) {
                statement.setObject(1, actor); statement.setObject(2, other); statement.setObject(3, actor); statement.setObject(4, secondOwner);
                statement.executeUpdate();
            }
            connection.commit();
        }
        assertThat(generation("sales")).isEqualTo(before + 1);
        db.update("UPDATE user_data_scopes SET created_by=created_by WHERE user_id=? AND scope='sales'", actor);
        assertThat(generation("sales")).isEqualTo(before + 1);
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            try (var statement = connection.prepareStatement("DELETE FROM user_data_scopes WHERE user_id=? AND scope='sales'")) {
                statement.setObject(1, actor); statement.executeUpdate();
            }
            connection.rollback();
        }
        assertThat(generation("sales")).isEqualTo(before + 1);
    }

    @Test void ordinaryDocumentInsertsAmountsAndStatusesCannotFireOwnershipWatchers() {
        for (String table : List.of("sales_orders", "sales_shipments", "sales_returns", "sales_other_shipments",
                "finance_receipts", "finance_payments", "finance_expenses", "finance_other_incomes")) {
            var rows = db.queryForList("""
                    SELECT trigger_row.tgtype,pg_get_triggerdef(trigger_row.oid) AS definition
                    FROM pg_trigger trigger_row WHERE trigger_row.tgrelid=CAST(? AS regclass)
                      AND trigger_row.tgname IN ('trg_read_scope_owner','trg_read_scope_maker')
                    """, "public." + table);
            assertThat(rows).hasSize(1);
            int type = ((Number) rows.getFirst().get("tgtype")).intValue();
            assertThat(type & 4).isZero(); assertThat(type & 8).isZero(); assertThat(type & 16).isEqualTo(16);
            assertThat(rows.getFirst().get("definition").toString()).contains("UPDATE OF", "IS DISTINCT FROM")
                    .doesNotContain("UPDATE OF status", "UPDATE OF amount");
        }
    }

    @Test void newTaskStampsAreMandatoryAndImmutableWhileEventIdentitiesCannotBeRewritten() {
        UUID id = UUID.randomUUID();
        assertThatThrownBy(() -> insertTask(id, null)).isInstanceOf(org.springframework.dao.DataAccessException.class);
        String stamp = authority.scopeFor("sales", subject); insertTask(id, stamp);
        assertThatThrownBy(() -> db.update("UPDATE report_export_jobs SET access_stamp=? WHERE id=?", "a".repeat(64), id))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        grant("sales");
        assertThatThrownBy(() -> db.update("DELETE FROM read_scope_change_events WHERE domain='sales'"))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThatThrownBy(() -> db.execute("TRUNCATE read_scope_change_events"))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThatThrownBy(() -> db.update("INSERT INTO read_scope_change_events(domain,change_txid) VALUES('sales',txid_current())"))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
    }

    @Test void aRealCompletedJobRefusesDownloadAfterOnlyItsDataScopeIsRevokedAndKeepsItsRequestAndFile() throws Exception {
        grant("sales");
        var stamps = restorer.currentStamps(actor).orElseThrow(); String access = authority.scopeFor("sales", subject);
        UUID id = UUID.randomUUID(); var request = new ReportExportRequest(id, "sales", "ORDER/detail", Map.of(), null, null, null);
        var mapper = new com.fasterxml.jackson.databind.ObjectMapper(); String json = mapper.writeValueAsString(request);
        var repository = new ReportExportRepository(new NamedParameterJdbcTemplate(dataSource));
        var queue = new TransactionTemplate(transactions);
        queue.executeWithoutResult(status -> repository.insert(request, actor, stamps.authVersion(), stamps.authorizationEpoch(), json, "fixture-build", access));
        db.update("UPDATE report_export_jobs SET status='RUNNING',attempt=1,started_at=clock_timestamp(),lease_until=clock_timestamp()+interval '120 seconds' WHERE id=?", id);
        var running = repository.find(id).orElseThrow(); String retainedRequest = running.request();
        assertThat(mapper.readTree(retainedRequest)).isEqualTo(mapper.readTree(json));
        var identity = mock(ReportExportBuildIdentity.class); when(identity.revision()).thenReturn("fixture-build");
        @SuppressWarnings("unchecked") var projection = (org.springframework.beans.factory.ObjectProvider<ExportProjectionAccessGuard>) mock(org.springframework.beans.factory.ObjectProvider.class);
        var service = new ReportExportService(repository, new SecurityContextCurrentUser(), restorer, mapper, identity,
                mock(ExportRateLimiter.class), authority, projection, directory.toString());
        byte[] workbook = new XlsxExportService().build(List.of(new ExportColumn("source", "原范围事实", ExportColumn.TEXT)),
                List.of(Map.of("source", "owner=" + other)));
        Path file = service.artifact(running); Files.write(file, workbook);
        String sha = HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256").digest(workbook));
        Boolean completed = queue.execute(status -> repository.succeed(running, 1, workbook.length, sha));
        assertThat(completed).isTrue();
        var controller = new ReportExportController(service, new WorkbookDownloadService(), mock(com.uten.imp.audit.AuditService.class), new SecurityContextCurrentUser());
        var before = new org.springframework.mock.web.MockHttpServletResponse();
        controller.download(id, new ExportPasswordRequest(null), before);
        assertThat(before.getContentAsByteArray()).isEqualTo(workbook);

        db.update("DELETE FROM user_data_scopes WHERE user_id=? AND scope='sales'", actor);
        assertThat(restorer.currentStamps(actor).orElseThrow()).isEqualTo(stamps);
        var denied = new org.springframework.mock.web.MockHttpServletResponse();
        assertThatThrownBy(() -> controller.download(id, new ExportPasswordRequest(null), denied)).isInstanceOfSatisfying(ApiException.class,
                failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.CONFLICT));
        assertThat(denied.getContentAsByteArray()).isEmpty();
        assertThat(repository.find(id).orElseThrow().request()).isEqualTo(retainedRequest);
        assertThat(Files.readAllBytes(file)).isEqualTo(workbook);
        grant("sales"); // The same effective set does not revive the pre-revocation artifact.
        assertThatThrownBy(() -> controller.download(id, new ExportPasswordRequest(null), new org.springframework.mock.web.MockHttpServletResponse()))
                .isInstanceOfSatisfying(ApiException.class, failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.CONFLICT));
        assertThat(Files.readAllBytes(file)).isEqualTo(workbook);
    }

    private void insertTask(UUID id, String stamp) {
        var version = restorer.currentStamps(actor).orElseThrow();
        db.update("INSERT INTO report_export_jobs(id,submitted_by,submitted_auth_version,submitted_auth_epoch,request,read_contract,build_identity,access_stamp)"
                + " VALUES(?,?,?,?,'{}','fixture-contract','fixture-build',?)", id, actor, version.authVersion(), version.authorizationEpoch(), stamp);
    }
    private void grant(String scope) { db.update("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id) VALUES(?,?,?)", actor, scope, other); }
    private long generation(String domain) { return db.queryForObject("SELECT generation FROM read_scope_generations WHERE domain=?", Long.class, domain); }
    private Set<String> permissions() {
        var result = new HashSet<>(BASE);
        if (delegated.get()) {
            result.add("sales:view:all");
        }
        return Set.copyOf(result);
    }
    private AuthUser user() { return new AuthUser(actor, employee, "scope-reader", permissions(), false, true, false); }
    private UUID employee(String label) {
        UUID id = UUID.randomUUID(); db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT ?,?,?,id_type,department_id,CURRENT_DATE,'active','regular' FROM employees WHERE code='ADMIN'
                """, id, "RS-" + id, com.uten.imp.support.SyntheticEmployeeIdentity.name("Read scope " + label,id)); return id;
    }
}
