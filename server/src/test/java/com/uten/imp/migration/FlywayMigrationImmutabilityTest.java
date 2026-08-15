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
    void triggerHeavySnapshotAndSettlementMigrationsRetainAppliedChecksums() {
        assertAppliedChecksum(
                "V260__purchase_goods_history_snapshots.sql",
                -1244751074);
        assertAppliedChecksum(
                "V263__subcontract_goods_history_snapshots.sql",
                1004929131);
        assertAppliedChecksum(
                "V273__settlement_method_uuid_authority.sql",
                -912055456);
    }

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

    @Test
    void v169RetainsTheChecksumOfTheFullAuditCoverageSweep() {
        LoadableResource migration = new ClassPathResource(
                new Location("classpath:db/migration"),
                "db/migration/V169__audit_center_risk_and_full_operation_coverage.sql",
                getClass().getClassLoader(),
                StandardCharsets.UTF_8);

        assertEquals(
                1098302988,
                ChecksumCalculator.calculate(migration),
                "V169 is the trusted full-table audit sweep; keep its applied bytes immutable "
                        + "and add a later migration for changes");
    }

    @Test
    void v219RetainsTheChecksumAlreadyRecordedByLocalDatabases() {
        LoadableResource migration = new ClassPathResource(
                new Location("classpath:db/migration"),
                "db/migration/V219__finance_object_scope.sql",
                getClass().getClassLoader(),
                StandardCharsets.UTF_8);

        assertEquals(
                377101663,
                ChecksumCalculator.calculate(migration),
                "V219 is deployed history; restore its exact bytes and add later migrations instead");
    }

    @Test
    void v236RetainsTheChecksumAlreadyRecordedByLocalDatabases() {
        LoadableResource migration = new ClassPathResource(
                new Location("classpath:db/migration"),
                "db/migration/V236__receivable_settlement_metadata.sql",
                getClass().getClassLoader(),
                StandardCharsets.UTF_8);

        assertEquals(
                -2024018731,
                ChecksumCalculator.calculate(migration),
                "V236 is deployed history; carry later finance safeguards in V238+");
    }

    private void assertAppliedChecksum(String filename, int expectedChecksum) {
        LoadableResource migration = new ClassPathResource(
                new Location("classpath:db/migration"),
                "db/migration/" + filename,
                getClass().getClassLoader(),
                StandardCharsets.UTF_8);

        assertEquals(
                expectedChecksum,
                ChecksumCalculator.calculate(migration),
                "Applied Flyway migrations are immutable; use a compatibility callback "
                        + "or add a later migration instead");
    }
}
