package com.uten.imp.migration;

import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

/**
 * Named PostgreSQL regression surface for the V415 material cycle.
 *
 * <p>It intentionally inherits the same real PostgreSQL/Flyway fixture and the
 * fake-READY plus fulfilled-DRAW reconciliation assertions from the empty-head
 * migration test so those guards remain selectable as a focused V415 suite.</p>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionFqcReplenishmentMaterialPostgresTest
        extends ProductionFqcEmptyDatabaseMigrationPostgresTest {
}
