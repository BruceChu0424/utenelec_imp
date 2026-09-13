package com.uten.imp.security;

import com.uten.imp.audit.AuditDeviceContext;
import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.config.props.CryptoProperties;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.hibernate.SessionFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

/** Real driver/ORM proof: audit fields share one statement and remain transaction local. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class TxSessionVarsBindingPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("audit_binding").withUsername("test").withPassword(UUID.randomUUID().toString());
    private static EntityManagerFactory factory;

    @BeforeAll
    static void start() {
        POSTGRES.start();
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.security");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto", "none", "hibernate.generate_statistics", "true"));
        bean.afterPropertiesSet();
        factory = bean.getObject();
    }

    @AfterAll
    static void stop() {
        if (factory != null) factory.close();
        POSTGRES.stop();
    }

    @AfterEach
    void clearRequest() { RequestContextHolder.resetRequestAttributes(); }

    @Test
    void bindsAllSixFieldsInOneStatementAndClearsOnCommit() {
        try (EntityManager em = factory.createEntityManager()) {
            var currentUser = mock(SecurityContextCurrentUser.class);
            var device = mock(AuditDeviceContext.class);
            var userId = UUID.randomUUID();
            when(currentUser.get()).thenReturn(Optional.of(new AuthUser(userId, UUID.randomUUID(), "audit-test",
                    Set.of(), Set.of(), false, true, false)));
            var request = new MockHttpServletRequest();
            request.setRemoteAddr("192.0.2.10");
            request.addHeader("User-Agent", "audit-test-agent");
            when(device.sessionJson(request)).thenReturn("{}");
            RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
            var service = new TxSessionVars(new CryptoProperties(), currentUser, device);
            ReflectionTestUtils.setField(service, "em", em);
            em.getTransaction().begin();
            var statistics = factory.unwrap(SessionFactory.class).getStatistics();
            statistics.clear();
            service.bind();
            assertThat(statistics.getQueryExecutionCount()).isEqualTo(1);
            Object[] values = (Object[]) em.createNativeQuery("""
                    SELECT current_setting('app.actor_id'),current_setting('app.actor_account'),
                           current_setting('app.audit_request_id'),current_setting('app.audit_ip'),
                           current_setting('app.audit_user_agent'),current_setting('app.audit_device_context')
                    """).getSingleResult();
            assertThat(values).containsExactly(userId.toString(), "audit-test",
                    AuditRequestContext.ensureRequestId(request).toString(), "192.0.2.10", "audit-test-agent", "{}");
            UUID nextActor = UUID.randomUUID();
            service.bindActor(nextActor, "system-operation");
            assertThat(em.createNativeQuery("SELECT current_setting('app.actor_id')").getSingleResult())
                    .isEqualTo(nextActor.toString());
            UUID unlabeledActor = UUID.randomUUID();
            service.bindActor(unlabeledActor);
            Object[] rebound = (Object[]) em.createNativeQuery(
                    "SELECT current_setting('app.actor_id'), current_setting('app.actor_account')").getSingleResult();
            assertThat(rebound).containsExactly(unlabeledActor.toString(), "");
            em.getTransaction().commit();
            em.getTransaction().begin();
            assertThat((String) em.createNativeQuery("SELECT current_setting('app.actor_id', true)").getSingleResult())
                    .isNullOrEmpty();
            RequestContextHolder.resetRequestAttributes();
            when(currentUser.get()).thenReturn(Optional.empty());
            em.createNativeQuery("""
                    SELECT set_config('app.production_readiness_reconcile','v1',true),
                           set_config('app.actor_id','',true),
                           set_config('app.actor_account','system readiness',true)
                    """).getSingleResult();
            service.bind();
            Object[] system = (Object[]) em.createNativeQuery("""
                    SELECT current_setting('app.production_readiness_reconcile'),
                           current_setting('app.actor_id'),current_setting('app.actor_account')
                    """).getSingleResult();
            assertThat(system).containsExactly("v1", "", "system readiness");
            service.bindActor(UUID.randomUUID(), "previous-actor");
            service.bindActor(null, "system readiness");
            assertThat(em.createNativeQuery("SELECT current_setting('app.actor_id')").getSingleResult())
                    .isEqualTo("");
            em.getTransaction().rollback();
        }
    }

    @Test
    void absentActorAndRequestDoesNotQuery() {
        var currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenReturn(Optional.empty());
        var em = mock(EntityManager.class);
        var service = new TxSessionVars(new CryptoProperties(), currentUser, mock(AuditDeviceContext.class));
        ReflectionTestUtils.setField(service, "em", em);
        service.bind();
        verifyNoInteractions(em);
    }
}
