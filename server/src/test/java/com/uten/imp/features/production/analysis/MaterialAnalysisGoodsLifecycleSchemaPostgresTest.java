package com.uten.imp.features.production.analysis;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;

import java.util.Properties;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertNotNull;

/** Production Hibernate SQL against the complete forward-migrated application schema. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MaterialAnalysisGoodsLifecycleSchemaPostgresTest {
    @Test void lifecycleQueryMatchesTheCurrentMigratedSchemaAndRealHibernateBinding() throws Exception {
        try (var database = MigratedSchemaBaseline.openDatabase("analysis_goods_lifecycle")) {
            var dataSource = new DriverManagerDataSource(database.getJdbcUrl(),
                    database.getUsername(), database.getPassword());
            var factory = new LocalContainerEntityManagerFactoryBean();
            factory.setDataSource(dataSource);
            factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
            factory.setPackagesToScan("com.uten.imp.features.production.fulfillment");
            Properties properties = new Properties();
            properties.setProperty("hibernate.hbm2ddl.auto", "none");
            properties.setProperty("hibernate.show_sql", "false");
            factory.setJpaProperties(properties);
            factory.afterPropertiesSet();
            var emf = factory.getObject();
            assertNotNull(emf);
            try (var em = emf.createEntityManager()) {
                em.getTransaction().begin();
                var reader = new MaterialAnalysisGoodsLifecycleReader(em);
                UUID analysis = UUID.randomUUID();
                reader.lockSources(analysis);
                assertThat(reader.blockedReasons(analysis)).isEmpty();
                em.getTransaction().rollback();
            } finally {
                emf.close();
            }
        }
    }
}
