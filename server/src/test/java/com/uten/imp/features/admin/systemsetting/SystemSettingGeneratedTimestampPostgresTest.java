package com.uten.imp.features.admin.systemsetting;

import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.hibernate.SessionFactory;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.testcontainers.containers.PostgreSQLContainer;

import java.time.OffsetDateTime;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Exercises actual database-generated timestamps; no application clock or entity refresh. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SystemSettingGeneratedTimestampPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("settings_generated_timestamp")
            .withUsername("test").withPassword(UUID.randomUUID().toString());
    private static EntityManagerFactory factory;
    private static JdbcTemplate jdbc;

    @BeforeAll
    static void start() {
        POSTGRES.start();
        var dataSource = new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        // Match the current V72 column defaults and BEFORE UPDATE trigger.
        jdbc.execute("""
                CREATE TABLE system_settings (
                    key text PRIMARY KEY, value text NOT NULL,
                    value_type text NOT NULL DEFAULT 'int', category text NOT NULL,
                    label text NOT NULL, description text, unit text,
                    sort_order integer NOT NULL DEFAULT 0,
                    updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid
                )
                """);
        jdbc.execute("""
                CREATE FUNCTION fn_set_updated_at() RETURNS trigger AS $$
                BEGIN NEW.updated_at = now(); RETURN NEW; END;
                $$ LANGUAGE plpgsql
                """);
        jdbc.execute("""
                CREATE TRIGGER trg_system_settings_updated BEFORE UPDATE ON system_settings
                FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at()
                """);
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(dataSource);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.features.admin.systemsetting");
        bean.setJpaPropertyMap(Map.of(
                "hibernate.hbm2ddl.auto", "none", "hibernate.generate_statistics", "true"));
        bean.afterPropertiesSet();
        factory = bean.getObject();
    }

    @AfterAll
    static void stop() {
        if (factory != null) factory.close();
        POSTGRES.stop();
    }

    @Test
    void updateReturnsTriggerTimeInManagedEntityAndDtoWithoutARefreshQuery() {
        String key = "existing_" + UUID.randomUUID();
        OffsetDateTime oldTime = OffsetDateTime.parse("2001-01-01T00:00:00Z");
        jdbc.update("""
                INSERT INTO system_settings(key,value,value_type,category,label,updated_at)
                VALUES (?, '15', 'int', 'security', 'Lockout minutes', ?)
                """, key, oldTime);
        try (EntityManager em = factory.createEntityManager()) {
            em.getTransaction().begin();
            SystemSetting setting = em.find(SystemSetting.class, key);
            assertThat(setting.getUpdatedAt().toInstant()).isEqualTo(oldTime.toInstant());
            setting.setValue("20");
            var statistics = factory.unwrap(SessionFactory.class).getStatistics();
            statistics.clear();
            em.flush();
            long mutationStatements = statistics.getPrepareStatementCount();
            OffsetDateTime databaseTime = (OffsetDateTime) em.createNativeQuery(
                    "SELECT updated_at FROM system_settings WHERE key=:key", OffsetDateTime.class)
                    .setParameter("key", key).getSingleResult();
            assertThat(setting.getUpdatedAt().toInstant()).isEqualTo(databaseTime.toInstant());
            assertThat(SystemSettingDto.of(setting).updatedAt().toInstant()).isEqualTo(databaseTime.toInstant());
            assertThat(setting.getUpdatedAt().toInstant()).isNotEqualTo(oldTime.toInstant());
            assertThat(mutationStatements).as("update and generated value share one JDBC statement").isEqualTo(1);
            em.getTransaction().rollback();
        }
    }

    @Test
    void insertReturnsDatabaseDefaultTimeWithoutARefreshQuery() {
        try (EntityManager em = factory.createEntityManager()) {
            em.getTransaction().begin();
            SystemSetting setting = new SystemSetting();
            setting.setKey("inserted_" + UUID.randomUUID());
            setting.setValue("15");
            setting.setCategory("security");
            setting.setLabel("Lockout minutes");
            var statistics = factory.unwrap(SessionFactory.class).getStatistics();
            statistics.clear();
            em.persist(setting);
            em.flush();
            long mutationStatements = statistics.getPrepareStatementCount();
            OffsetDateTime databaseTime = (OffsetDateTime) em.createNativeQuery(
                    "SELECT updated_at FROM system_settings WHERE key=:key", OffsetDateTime.class)
                    .setParameter("key", setting.getKey()).getSingleResult();
            assertThat(setting.getUpdatedAt()).isNotNull();
            assertThat(setting.getUpdatedAt().toInstant()).isEqualTo(databaseTime.toInstant());
            assertThat(mutationStatements).as("insert and generated value share one JDBC statement").isEqualTo(1);
            em.getTransaction().rollback();
        }
    }
}
