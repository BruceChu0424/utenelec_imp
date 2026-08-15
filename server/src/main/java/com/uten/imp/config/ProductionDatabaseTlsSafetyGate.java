package com.uten.imp.config;

import jakarta.annotation.PostConstruct;
import org.springframework.core.env.Environment;
import org.springframework.core.env.Profiles;
import org.springframework.stereotype.Component;

/**
 * Fails application startup when a remote production PostgreSQL connection is
 * not protected by full certificate and hostname verification.
 */
@Component
public class ProductionDatabaseTlsSafetyGate {

    private static final Profiles PRODUCTION_PROFILES = Profiles.of("prod", "cloud");
    private static final Profiles CLOUD_PROFILE = Profiles.of("cloud");

    private final Environment environment;

    public ProductionDatabaseTlsSafetyGate(Environment environment) {
        this.environment = environment;
    }

    @PostConstruct
    void validate() {
        if (!environment.acceptsProfiles(PRODUCTION_PROFILES)) {
            return;
        }

        requireProductionUrl("spring.datasource.url");
        if (environment.acceptsProfiles(CLOUD_PROFILE)) {
            requireAuthenticatedCloudUrl("app.cloud.db.primary.url");
            requireAuthenticatedCloudUrl("app.cloud.db.replica.url");
        }
    }

    private void requireProductionUrl(String property) {
        PostgresJdbcTlsPolicy.requireProductionConnection(
                property,
                environment.getProperty(property));
    }

    private void requireAuthenticatedCloudUrl(String property) {
        PostgresJdbcTlsPolicy.requireAuthenticatedTls(
                property,
                environment.getProperty(property));
    }
}
