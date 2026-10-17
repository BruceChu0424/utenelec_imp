package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.TransactionWritePreparationPort;
import com.uten.imp.audit.AuditDeviceContext;
import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.history.GoodsOperationHistoryTransactionPreparation;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.support.StaticListableBeanFactory;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Exercises the real transaction-start listener, SPI and shipped lock function. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class TransactionWritePreparationPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final AtomicReference<AuthUser> PRINCIPAL = new AtomicReference<>();
    private static final AtomicInteger PREPARATIONS = new AtomicInteger();
    private static EntityManagerFactory factory;
    private static EntityManager em;
    private static TxSessionVars vars;
    private static TransactionTemplate writes;
    private static TransactionTemplate reads;

    @BeforeAll
    static void start() throws Exception {
        DB.start();
        String migration;
        try (var stream = TransactionWritePreparationPostgresTest.class.getResourceAsStream(
                "/db/migration/V871__goods_operation_history.sql")) {
            migration = new String(java.util.Objects.requireNonNull(stream).readAllBytes(), StandardCharsets.UTF_8);
        }
        try (Connection connection = connection(); var statement = connection.createStatement()) {
            statement.execute(function(migration, "fn_goods_history_operation"));
            statement.execute(function(migration, "fn_begin_goods_history_request"));
            statement.execute("CREATE TABLE preparation_probe(id uuid PRIMARY KEY)");
            statement.execute("""
                    CREATE FUNCTION fn_require_preparation_probe() RETURNS trigger LANGUAGE plpgsql AS $$
                    BEGIN
                      IF current_setting('app.goods_history_prelocked_actor',true)
                          IS DISTINCT FROM current_setting('app.actor_id',true) THEN
                        RAISE EXCEPTION 'business DML ran before history coordination';
                      END IF;
                      RETURN NEW;
                    END $$
                    """);
            statement.execute("CREATE TRIGGER preparation_probe_guard BEFORE INSERT ON preparation_probe "
                    + "FOR EACH ROW EXECUTE FUNCTION fn_require_preparation_probe()");
            // Deterministic lock contention below must finish within a bound.
            statement.execute("ALTER DATABASE " + DB.getDatabaseName() + " SET lock_timeout='300ms'");
        }
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword()));
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.security.bindingprobe");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto", "none"));
        bean.afterPropertiesSet();
        factory = bean.getObject();
        em = SharedEntityManagerCreator.createSharedEntityManager(factory);

        var current = mock(SecurityContextCurrentUser.class);
        when(current.get()).thenAnswer(ignored -> Optional.ofNullable(PRINCIPAL.get()));
        var preparations = new StaticListableBeanFactory();
        var history = new GoodsOperationHistoryTransactionPreparation(em);
        preparations.addBean("historyPreparation", (TransactionWritePreparationPort) (path, method) -> {
            PREPARATIONS.incrementAndGet();
            history.prepare(path, method);
        });
        vars = new TxSessionVars(new CryptoProperties(), current, new AuditDeviceContext(new ObjectMapper()),
                preparations.getBeanProvider(TransactionWritePreparationPort.class));
        ReflectionTestUtils.setField(vars, "em", em);
        var providers = new StaticListableBeanFactory();
        providers.addBean("txSessionVars", vars);
        var manager = new JpaTransactionManager(factory);
        manager.addListener(new TransactionAuditActorBinder(providers.getBeanProvider(TxSessionVars.class)));
        writes = new TransactionTemplate(manager);
        reads = new TransactionTemplate(manager);
        reads.setReadOnly(true);
    }

    @AfterAll
    static void stop() {
        if (factory != null) factory.close();
        DB.stop();
    }

    @BeforeEach
    void identify() {
        PRINCIPAL.set(new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "history-lock",
                Set.of("goods:edit"), false, true, false));
        PREPARATIONS.set(0);
    }

    @AfterEach
    void clear() {
        RequestContextHolder.resetRequestAttributes();
        PRINCIPAL.set(null);
    }

    @Test
    void provenanceAndPersonalLockExistBeforeTheFirstBusinessStatement() {
        request("POST", "/app/api/master/goods", "/app");
        UUID id = UUID.randomUUID();
        writes.executeWithoutResult(status -> {
            assertEquals(1, PREPARATIONS.get());
            assertEquals(PRINCIPAL.get().getId().toString(), setting("app.goods_history_prelocked_actor"));
            assertEquals("/api/master/goods", setting("app.audit_request_path"));
            insert(id);
            vars.bind();
            vars.bind();
            assertEquals(1, PREPARATIONS.get(), "Cached binding must not take the lock again");
        });
        reads.executeWithoutResult(status -> {
            assertEquals(1, count(id));
            String marker = setting("app.goods_history_prelocked_actor");
            assertTrue(marker == null || marker.isEmpty(), "The marker must not leak to another transaction");
        });
    }

    @Test
    void unrelatedWritesAndHistoryReadsDoNotAcquireThePersonalLock() {
        request("PUT", "/api/master/suppliers/" + UUID.randomUUID(), "");
        writes.executeWithoutResult(status -> assertNullOrEmpty(setting("app.goods_history_prelocked_actor")));
        request("GET", "/api/master/goods/history", "");
        reads.executeWithoutResult(status -> assertNullOrEmpty(setting("app.goods_history_prelocked_actor")));
    }

    @Test
    void failedStartPreparationCannotBeSwallowedIntoAnUncoordinatedBusinessWrite() throws Exception {
        request("POST", "/api/master/goods", "");
        UUID id = UUID.randomUUID();
        try (Connection blocker = connection()) {
            blocker.setAutoCommit(false);
            try (var statement = blocker.prepareStatement(
                    "SELECT pg_advisory_xact_lock(hashtextextended('goods-history:'||CAST(? AS text),0))")) {
                statement.setObject(1, PRINCIPAL.get().getId());
                statement.execute();
            }
            // The transaction-start listener intentionally logs binding failures.
            // PostgreSQL must nevertheless leave this transaction aborted.
            assertThrows(RuntimeException.class, () -> writes.executeWithoutResult(status -> {
                ApiException firstFailure = assertThrows(ApiException.class, vars::bind);
                assertEquals(ErrorCode.CONFLICT, firstFailure.getCode(), "Preserve the original lock conflict");
                // Even an application that ignored the explicit failure cannot
                // continue with business DML on the aborted transaction.
                insert(id);
            }));
            blocker.rollback();
        }
        reads.executeWithoutResult(status -> assertEquals(0, count(id)));
        writes.executeWithoutResult(status -> insert(id));
        reads.executeWithoutResult(status -> assertEquals(1, count(id)));
    }

    private static void request(String method, String uri, String context) {
        var request = new MockHttpServletRequest(method, uri);
        request.setContextPath(context);
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
    }

    private static String function(String migration, String name) {
        var matcher = Pattern.compile("(?s)CREATE(?: OR REPLACE)? FUNCTION "
                + Pattern.quote(name) + "\\(.*?\\$\\$;").matcher(migration);
        assertTrue(matcher.find(), "Missing shipped function " + name);
        return matcher.group();
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
    }

    private static void insert(UUID id) {
        em.createNativeQuery("INSERT INTO preparation_probe(id) VALUES(:id)").setParameter("id", id).executeUpdate();
    }

    private static int count(UUID id) {
        return ((Number) em.createNativeQuery("SELECT count(*) FROM preparation_probe WHERE id=:id")
                .setParameter("id", id).getSingleResult()).intValue();
    }

    private static String setting(String key) {
        return (String) em.createNativeQuery("SELECT current_setting(:key,true)").setParameter("key", key).getSingleResult();
    }

    private static void assertNullOrEmpty(String value) {
        assertTrue(value == null || value.isEmpty());
    }
}
