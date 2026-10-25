package com.uten.imp.testsupport;

import java.util.Objects;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.configuration.FluentConfiguration;
import org.springframework.beans.factory.config.YamlPropertiesFactoryBean;
import org.springframework.core.io.ClassPathResource;

/** Direct test migrations use the production migration-connection policy, without changing ordinary connections. */
public final class TestFlyway {
    private static final String MIGRATION_INIT_SQL = migrationInitSql();

    private TestFlyway() { }

    public static FluentConfiguration configure() {
        return Flyway.configure().initSql(MIGRATION_INIT_SQL)
                .callbacks(new com.uten.imp.migration.AppliedMigrationCompatibilityCallback(),
                        new com.uten.imp.migration.AuditFreshStartGuardCallback());
    }

    /** Retains fixture-specific connection settings after the shared migration policy. */
    public static FluentConfiguration configureWithInitSql(String additionalInitSql) {
        if (additionalInitSql == null || additionalInitSql.isBlank()) {
            throw new IllegalArgumentException("Additional migration connection SQL is required");
        }
        return configure().initSql(MIGRATION_INIT_SQL + ";\n" + additionalInitSql);
    }

    private static String migrationInitSql() {
        var yaml = new YamlPropertiesFactoryBean();
        yaml.setResources(new ClassPathResource("application.yml"));
        var properties = Objects.requireNonNull(yaml.getObject(), "Production migration policy is missing");
        String sql = properties.getProperty("spring.flyway.init-sqls[0]");
        if (sql == null || sql.isBlank()) {
            throw new IllegalStateException("Production migration connection initialization is missing");
        }
        return sql;
    }
}
