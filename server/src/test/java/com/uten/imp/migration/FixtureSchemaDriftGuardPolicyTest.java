package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.Map;
import java.util.TreeSet;

import static org.assertj.core.api.Assertions.assertThat;

class FixtureSchemaDriftGuardPolicyTest {
    private static final String OWNER =
            "com/uten/imp/common/finance/BusinessPrecisionHttpPostgresTest.java";

    @Test void aPrivateProbeNameCannotBeBorrowedByAnotherFixture() {
        var columns = Map.of("id", "integer", "value", "numeric");
        var admitted = new ArrayList<String>();
        FixtureSchemaDriftGuardPostgresTest.reconcileTable(
                new FixtureSchemaDdl.FixtureTable(OWNER, "precision_http_probe", columns),
                admitted, new TreeSet<>(), Map.of());
        assertThat(admitted).isEmpty();

        var refused = new ArrayList<String>();
        FixtureSchemaDriftGuardPostgresTest.reconcileTable(
                new FixtureSchemaDdl.FixtureTable("another/Fixture.java", "precision_http_probe", columns),
                refused, new TreeSet<>(), Map.of());
        assertThat(refused).hasSize(1);
    }

    @Test void aKnownCatalogRelationAlwaysChecksColumnsEvenForTheProbeOwner() {
        var violations = new ArrayList<String>();
        FixtureSchemaDriftGuardPostgresTest.reconcileTable(
                new FixtureSchemaDdl.FixtureTable(OWNER, "precision_http_probe",
                        Map.of("id", "text", "invented", "numeric")),
                violations, new TreeSet<>(),
                Map.of("precision_http_probe", Map.of("id", "integer")));
        assertThat(violations).hasSize(2);
    }

    @Test void realBusinessColumnsNeverInheritAnOracleFlagExemption() {
        var violations = new ArrayList<String>();
        FixtureSchemaDriftGuardPostgresTest.reconcileTable(
                new FixtureSchemaDdl.FixtureTable(
                        "com/uten/imp/businesschain/DirectMakeDeliveryClosedCreditPostgresTest.java",
                        "preplan_aggregate_material_aliases", Map.of("id", "uuid", "valid", "boolean")),
                violations, new TreeSet<>(),
                Map.of("preplan_aggregate_material_aliases", Map.of("id", "uuid")));
        assertThat(violations).hasSize(1);
    }
}
