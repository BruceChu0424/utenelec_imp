package com.uten.imp.testsupport;

import org.springframework.test.context.DynamicPropertyRegistry;

import java.util.function.Supplier;

/** Binds an ordinary test fixture's application and migration connections together. */
public final class FixtureDatabaseProperties {
    private FixtureDatabaseProperties() { }

    /**
     * For fixtures intentionally using the same role for their application and Flyway.
     * Dedicated migration-role, external load and bootstrap scenarios keep their own bindings.
     * Suppliers remain lazy; starting or closing the fixture remains the caller's responsibility.
     */
    public static void bindSameRole(DynamicPropertyRegistry registry, Supplier<String> jdbcUrl,
            Supplier<String> username, Supplier<String> password) {
        registry.add("spring.datasource.url", jdbcUrl::get);
        registry.add("spring.datasource.username", username::get);
        registry.add("spring.datasource.password", password::get);
        // An optional developer .env may select a different migrator role. Both
        // credentials and destination must follow this exact private fixture,
        // including callers replacing a shared harness with another test clone.
        registry.add("spring.flyway.url", jdbcUrl::get);
        registry.add("spring.flyway.user", username::get);
        registry.add("spring.flyway.password", password::get);
    }
}
