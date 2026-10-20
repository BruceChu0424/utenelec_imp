package com.uten.imp.features.master.history;

import com.uten.imp.support.MigratedSchemaBaseline;
import com.uten.imp.migration.MigrationRehearsalSupport;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;

import java.sql.SQLException;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Schema failure is isolated to its owning domain, never silently ignored there. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MasterOperationHistoryPreparationPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static EntityManagerFactory factory;
    private EntityManager em;

    @BeforeAll static void start() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("master_history_preparation");
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword()));
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.security");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto", "none"));
        bean.afterPropertiesSet();
        factory = bean.getObject();
    }

    @AfterAll static void closeDatabase() throws Exception {
        if (factory != null) factory.close();
        if (database != null) database.close();
    }

    @BeforeEach void begin() {
        em = factory.createEntityManager();
        em.getTransaction().begin();
    }

    @AfterEach void rollback() {
        if (em.getTransaction().isActive()) em.getTransaction().rollback();
        em.close();
    }

    @Test void goodsInlineAndBomPreviewDoNotDependOnTheOtherMasterHistoryFunction() {
        em.createNativeQuery("DROP FUNCTION public.fn_begin_master_history_request()").executeUpdate();
        var preparation = new MasterOperationHistoryTransactionPreparation(em);
        preparation.prepare("/api/master/inline-edit/goods/" + UUID.randomUUID(), "PATCH");
        preparation.prepare("/api/master/goods/" + UUID.randomUUID() + "/bom/edit/preview", "POST");
        preparation.prepare("/api/master/colors", "GET");
        assertEquals(1, ((Number) em.createNativeQuery("SELECT 1").getSingleResult()).intValue());
    }

    @Test void missingMandatoryHistoryFunctionStillRejectsItsOwnWrite() {
        em.createNativeQuery("DROP FUNCTION public.fn_begin_master_history_request()").executeUpdate();
        RuntimeException failure = assertThrows(RuntimeException.class, () ->
                new MasterOperationHistoryTransactionPreparation(em).prepare("/api/master/colors", "POST"));
        boolean undefinedFunction = false;
        for (Throwable cause = failure; cause != null; cause = cause.getCause()) {
            if (cause instanceof SQLException sql && "42883".equals(sql.getSQLState())) undefinedFunction = true;
        }
        assertTrue(undefinedFunction);
    }

    @Test void managedWriteAcquiresItsActorCoordinationAndTheCompleteMigrationChainIsPresent() {
        UUID actor = UUID.randomUUID();
        em.createNativeQuery("SELECT set_config('app.actor_id', :actor, true), "
                        + "set_config('app.audit_request_path', '/api/master/colors', true), "
                        + "set_config('app.audit_request_method', 'POST', true)")
                .setParameter("actor", actor.toString()).getSingleResult();
        new MasterOperationHistoryTransactionPreparation(em).prepare("/api/master/colors", "POST");
        assertEquals(actor.toString(), em.createNativeQuery(
                "SELECT current_setting('app.master_history_prelocked_actor', true)").getSingleResult());
        assertEquals(MigrationRehearsalSupport.CURRENT_MIGRATION_COUNT, ((Number) em.createNativeQuery(
                "SELECT count(*) FROM public.flyway_schema_history WHERE success").getSingleResult()).intValue());
        assertEquals(MigrationRehearsalSupport.CURRENT_HEAD_VERSION, em.createNativeQuery(
                "SELECT version FROM public.flyway_schema_history WHERE success ORDER BY installed_rank DESC LIMIT 1").getSingleResult());
    }
}
