package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import static org.junit.jupiter.api.Assertions.*;

/** The performance migration must retain every existing integrity boundary. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ExecutionMaterialCoverageMigrationContractPostgresTest {
    @Test void migrationOnlyReplacesTheCoverageSourceAndPreservesAllGuards() {
        try (var postgres = new PostgreSQLContainer<>("postgres:16-alpine")) {
            postgres.start();
            migrate(postgres, "621");
            var jdbc = new JdbcTemplate(new DriverManagerDataSource(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword()));
            String previous = definition(jdbc, "fn_assert_execution_segment_integrity_before_v561");
            String scalar = definition(jdbc, "fn_execution_demand_draw_commitment_qty");
            String wrapper = definition(jdbc, "fn_assert_execution_segment_integrity");
            assertTrue(wrapper.contains("fn_assert_execution_segment_integrity_before_v561"),
                    "The real integrity entry point must reach the guard being optimized");
            migrate(postgres, "622");
            String current = definition(jdbc, "fn_assert_execution_segment_integrity_before_v561");
            int previousStart = previous.indexOf("WITH coverage AS (");
            int currentStart = current.indexOf("WITH coverage AS MATERIALIZED (");
            int previousEnd = previous.indexOf("SELECT COUNT(*) FILTER (", previousStart);
            int currentEnd = current.indexOf("SELECT COUNT(*) FILTER (", currentStart);
            assertTrue(previousStart > 0 && currentStart > 0 && previousEnd > previousStart && currentEnd > currentStart,
                    "Both migrations must expose the complete expected coverage boundary");
            assertEquals(normalize(previous.substring(0, previousStart)), normalize(current.substring(0, currentStart)),
                    "Snapshot, active-segment and zero-material guards cannot change");
            assertEquals(normalize(previous.substring(previousEnd)), normalize(current.substring(currentEnd)),
                    "Readiness, over-allocation, closure and exact DRAW lineage guards cannot change");
            assertEquals(normalize(scalar), normalize(definition(jdbc, "fn_execution_demand_draw_commitment_qty")),
                    "Keep the independent scalar oracle and existing callers unchanged");
            assertEquals(normalize(wrapper), normalize(definition(jdbc, "fn_assert_execution_segment_integrity")),
                    "The split/frozen-consumption wrapper must keep invoking the same integrity chain");
            assertTrue(current.substring(currentStart, currentEnd)
                    .contains("fn_execution_segment_material_coverage(v_segment.id)"));
            assertEquals(0, jdbc.queryForObject(
                    "SELECT count(*) FROM fn_execution_segment_material_coverage(gen_random_uuid())", Integer.class));
        }
    }

    private static void migrate(PostgreSQLContainer<?> postgres, String target) {
        Flyway.configure().dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                .locations("classpath:db/migration").target(target).load().migrate();
    }

    private static String definition(JdbcTemplate jdbc, String function) {
        return jdbc.queryForObject("SELECT pg_get_functiondef(CAST(? AS regprocedure))", String.class, function + "(uuid)");
    }

    private static String normalize(String text) { return text.replaceAll("\\s+", " ").trim(); }
}
