package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Installs the forward migration against the actual V646 schema, preserving the old guard chain. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MaterialAnalysisExecutionGrowthMigrationPostgresTest {
    @Test void forwardMigrationPreservesExecutionBoundariesAndDoesNotRewriteBusinessRows() {
        try (var postgres = new PostgreSQLContainer<>("postgres:16-alpine")) {
            postgres.start();
            migrate(postgres, "646");
            var jdbc = new JdbcTemplate(new DriverManagerDataSource(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword()));
            String consumption = definition(jdbc, "fn_material_snapshot_required(jsonb,numeric)");
            String curveGuard = definition(jdbc, "fn_guard_execution_consumption_snapshot()");
            String coverage = definition(jdbc, "fn_execution_segment_material_coverage(uuid)");
            String integrity = definition(jdbc, "fn_assert_execution_segment_integrity(uuid)");
            String planGuard = definition(jdbc, "fn_material_analysis_plan_growable(uuid)");
            long segmentsBefore = count(jdbc, "production_execution_segments");
            long demandsBefore = count(jdbc, "production_material_demands");

            migrate(postgres, "647");

            assertEquals(consumption, definition(jdbc, "fn_material_snapshot_required(jsonb,numeric)"));
            assertEquals(curveGuard, definition(jdbc, "fn_guard_execution_consumption_snapshot()"));
            assertEquals(coverage, definition(jdbc, "fn_execution_segment_material_coverage(uuid)"));
            assertEquals(integrity, definition(jdbc, "fn_assert_execution_segment_integrity(uuid)"));
            String currentPlanGuard = definition(jdbc, "fn_material_analysis_plan_growable(uuid)");
            String addedPredicate = "\n          AND NOT EXISTS (SELECT 1 FROM production_execution_segments growth_segment"
                    + "\n              WHERE growth_segment.plan_id=plan.id AND NOT growth_segment.is_deleted"
                    + "\n                AND NOT fn_material_analysis_execution_segment_growable(growth_segment.id))";
            assertEquals(planGuard, currentPlanGuard.replace(addedPredicate, ""),
                    "Keep all existing plan lifecycle predicates while adding the workshop execution boundary");
            assertEquals(segmentsBefore, count(jdbc, "production_execution_segments"));
            assertEquals(demandsBefore, count(jdbc, "production_material_demands"));
            assertEquals(0L, count(jdbc, "production_execution_segment_growth_events"));
            assertEquals(3, jdbc.queryForObject("""
                    SELECT COUNT(*) FROM pg_trigger
                    WHERE tgrelid='production_execution_segment_growth_events'::regclass
                      AND NOT tgisinternal AND tgenabled='A'
                    """, Integer.class));
            assertTrue(definition(jdbc, "business_data_reset()")
                    .contains("('production_execution_segment_growth_events', 'CLEAR')"));

            UUID absent = UUID.randomUUID();
            assertFalse(jdbc.queryForObject(
                    "SELECT fn_material_analysis_execution_segment_growable(?)", Boolean.class, absent));
            assertFalse(jdbc.queryForObject(
                    "SELECT fn_is_recorded_material_analysis_execution_growth(?,3000,4000)", Boolean.class, absent));
            jdbc.queryForObject("SELECT set_config('app.execution_growth_event_id',?,false)", String.class, absent.toString());
            assertFalse(jdbc.queryForObject(
                    "SELECT fn_is_material_analysis_execution_growth(?,3000,4000)", Boolean.class, absent),
                    "An arbitrary session flag is never authority to change a frozen task");
        }
    }

    private static void migrate(PostgreSQLContainer<?> postgres, String target) {
        Flyway.configure().dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                .locations("classpath:db/migration").target(target).load().migrate();
    }

    private static String definition(JdbcTemplate jdbc, String signature) {
        return jdbc.queryForObject("SELECT pg_get_functiondef(CAST(? AS regprocedure))", String.class, signature);
    }

    private static long count(JdbcTemplate jdbc, String table) {
        return jdbc.queryForObject("SELECT COUNT(*) FROM " + table, Long.class);
    }
}
