package com.uten.imp.migration;

import org.flywaydb.core.api.Location;
import org.flywaydb.core.api.resource.LoadableResource;
import org.flywaydb.core.internal.resolver.ChecksumCalculator;
import org.flywaydb.core.internal.resource.classpath.ClassPathResource;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertEquals;

class FlywayMigrationImmutabilityTest {

    @Test
    void v148RetainsTheChecksumAlreadyRecordedByDeployedDatabases() {
        LoadableResource migration = new ClassPathResource(
                new Location("classpath:db/migration"),
                "db/migration/V148__repair_finance_stub_party_text.sql",
                getClass().getClassLoader(),
                StandardCharsets.UTF_8);

        assertEquals(
                1590936016,
                ChecksumCalculator.calculate(migration),
                "Applied Flyway migrations are immutable; add a new migration instead");
    }
}
