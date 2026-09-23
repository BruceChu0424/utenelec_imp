package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditDeviceContext;
import com.uten.imp.config.props.CryptoProperties;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.support.StaticListableBeanFactory;
import org.springframework.jdbc.datasource.DelegatingDataSource;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.util.Optional;
import java.util.Properties;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 审计操作人绑定(ADR-107 / dup-backend-split-15): 读写事务开始时自动绑定一次; 同一事务同一身份
 * 再调用 {@code bind()} 不往返数据库; 换人、回滚到保存点、新事务都会如实重绑。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class TxSessionVarsTransactionBindingPostgresTest {
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    static final AtomicInteger SET_CONFIG = new AtomicInteger();
    static final AtomicReference<AuthUser> PRINCIPAL = new AtomicReference<>();
    static EntityManagerFactory factory;
    static EntityManager em;
    static TransactionTemplate transactions;
    static TxSessionVars vars;

    @BeforeAll static void start() {
        POSTGRES.start();
        var target = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        var counting = new DelegatingDataSource(target) {
            @Override public Connection getConnection() throws java.sql.SQLException {
                Connection connection = super.getConnection();
                return (Connection) Proxy.newProxyInstance(Connection.class.getClassLoader(),
                        new Class<?>[] {Connection.class}, (proxy, method, args) -> {
                            if (method.getName().startsWith("prepare") && args != null && args[0] instanceof String sql
                                    && sql.contains("set_config(")) SET_CONFIG.incrementAndGet();
                            try { return method.invoke(connection, args); }
                            catch (java.lang.reflect.InvocationTargetException failure) { throw failure.getCause(); }
                        });
            }
        };
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(counting);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setJpaDialect(new com.uten.imp.support.NativeSavepointJpaDialect());
        bean.setPackagesToScan("com.uten.imp.security.bindingprobe");
        var props = new Properties(); props.setProperty("hibernate.hbm2ddl.auto", "none");
        bean.setJpaProperties(props); bean.afterPropertiesSet(); factory = bean.getObject();
        em = SharedEntityManagerCreator.createSharedEntityManager(factory);
        var currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenAnswer(ignored -> Optional.ofNullable(PRINCIPAL.get()));
        vars = new TxSessionVars(mock(CryptoProperties.class), currentUser, new AuditDeviceContext(new ObjectMapper()));
        ReflectionTestUtils.setField(vars, "em", em);
        var manager = new JpaTransactionManager(factory);
        manager.setNestedTransactionAllowed(true);
        var beans = new StaticListableBeanFactory();
        beans.addBean("txSessionVars", vars);
        manager.addListener(new TransactionAuditActorBinder(beans.getBeanProvider(TxSessionVars.class)));
        transactions = new TransactionTemplate(manager);
    }
    @AfterAll static void stop() { if (factory != null) factory.close(); POSTGRES.stop(); }
    @BeforeEach void reset() { SET_CONFIG.set(0); PRINCIPAL.set(null); }

    @Test void writeTransactionBindsOnceAtBeginAndRebindsOnlyWhenTheActorChanges() {
        var planner = user("planner");
        PRINCIPAL.set(planner);
        UUID system = UUID.randomUUID();
        transactions.executeWithoutResult(status -> {
            assertEquals(1, SET_CONFIG.get(), "The transaction binds its actor as soon as it begins");
            assertEquals(planner.getId().toString(), setting("app.actor_id"));
            vars.bind(); vars.bind();
            assertEquals(1, SET_CONFIG.get(), "Same transaction, same actor: memory only");
            vars.bindActor(system, "system");
            assertEquals(2, SET_CONFIG.get());
            assertEquals(system.toString(), setting("app.actor_id"));
            vars.bindActor(system, "system");
            assertEquals(2, SET_CONFIG.get());
            vars.bind();
            assertEquals(3, SET_CONFIG.get(), "The signed-in principal replaces an explicit system actor");
            assertEquals(planner.getId().toString(), setting("app.actor_id"));
        });
        var readOnly = new TransactionTemplate(transactions.getTransactionManager());
        readOnly.setReadOnly(true);
        readOnly.executeWithoutResult(status -> assertEquals(3, SET_CONFIG.get(), "Read-only transactions write no audit rows"));
        transactions.executeWithoutResult(status -> {
            assertEquals(4, SET_CONFIG.get(), "A new transaction binds afresh");
            assertEquals(planner.getId().toString(), setting("app.actor_id"));
        });
    }

    @Test void savepointRollbackForgetsTheBindingItUndid() {
        transactions.executeWithoutResult(status -> {
            assertEquals(0, SET_CONFIG.get(), "No principal and no request: nothing to bind");
            Object savepoint = status.createSavepoint();
            var planner = user("savepoint");
            PRINCIPAL.set(planner);
            vars.bind();
            assertEquals(1, SET_CONFIG.get());
            status.rollbackToSavepoint(savepoint);
            assertNotEquals(planner.getId().toString(), setting("app.actor_id"), "PostgreSQL undid the local setting");
            vars.bind();
            assertEquals(2, SET_CONFIG.get(), "The rolled-back binding must be issued again");
            assertEquals(planner.getId().toString(), setting("app.actor_id"));
        });
    }

    @Test void requiresNewBindsItsOwnConnectionWithoutForgettingTheOuterBinding() {
        var planner = user("outer");
        PRINCIPAL.set(planner);
        var inner = new TransactionTemplate(transactions.getTransactionManager());
        inner.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        transactions.executeWithoutResult(status -> {
            assertEquals(1, SET_CONFIG.get());
            inner.executeWithoutResult(nested -> {
                assertEquals(2, SET_CONFIG.get(), "The independent transaction binds on its own connection");
                assertEquals(planner.getId().toString(), setting("app.actor_id"));
            });
            vars.bind();
            assertEquals(2, SET_CONFIG.get(), "The resumed outer transaction is still bound");
            assertEquals(planner.getId().toString(), setting("app.actor_id"));
        });
    }

    private static String setting(String name) {
        return (String) em.createNativeQuery("SELECT current_setting(:name, true)").setParameter("name", name)
                .getSingleResult();
    }

    private static AuthUser user(String account) {
        return new AuthUser(UUID.randomUUID(), UUID.randomUUID(), account, Set.of(), false, true, false);
    }
}
