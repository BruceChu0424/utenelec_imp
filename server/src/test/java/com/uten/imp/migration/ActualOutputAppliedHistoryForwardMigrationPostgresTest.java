package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Replays the actual applied V701 bytes, rather than blessing rewritten history. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class ActualOutputAppliedHistoryForwardMigrationPostgresTest {
    @Test
    void upgradesAppliedV701WithoutChangingReportMaterialOrStockFacts() {
        try (var database = new PostgreSQLContainer<>("postgres:16-alpine")) {
            database.start();
            migration(database, "701").migrate();
            var jdbc = jdbc(database);
            assertThat(jdbc.queryForObject("SELECT checksum FROM flyway_schema_history WHERE version='694'", Integer.class))
                    .isEqualTo(-1248105708);
            assertThat(jdbc.queryForObject("SELECT checksum FROM flyway_schema_history WHERE version='700'", Integer.class))
                    .isEqualTo(-55642355);
            assertThat(jdbc.queryForObject("SELECT checksum FROM flyway_schema_history WHERE version='701'", Integer.class))
                    .isEqualTo(-1134610811);
            assertThat(jdbc.queryForObject("SELECT to_regprocedure('fn_report_has_prior_same_segment_consumption(uuid,uuid)')::text", String.class))
                    .isNull();

            seedHistory(jdbc);
            Map<String,String> before = snapshot(jdbc);
            // Cloud V703 is preserved before the local follow-ups; the plan column
            // is intentionally introduced only by the unapplied migration renamed V707.
            assertThat(migration(database, "703").migrate().migrationsExecuted).isEqualTo(2);
            assertThat(jdbc.queryForObject("SELECT to_regclass('production_planning_urges')::text", String.class))
                    .isEqualTo("production_planning_urges");
            assertThat(jdbc.queryForObject("SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='production_plan_items' AND column_name='allowed_overproduction_rate'", Long.class))
                    .isZero();
            assertThat(snapshot(jdbc)).isEqualTo(before);
            assertThat(migration(database, "707").migrate().migrationsExecuted).isEqualTo(4);
            migration(database, "707").validate();
            assertThat(snapshot(jdbc)).isEqualTo(before);
            assertThat(jdbc.queryForObject("SELECT allowed_overproduction_rate FROM production_plan_items", java.math.BigDecimal.class))
                    .isEqualByComparingTo("0.10");
            assertThat(jdbc.queryForObject("SELECT material_increment_request_id FROM production_material_demands", UUID.class))
                    .isNull();
            assertForwardGuards(jdbc);
            assertThat(migration(database, "707").migrate().migrationsExecuted).isZero();
            assertThat(snapshot(jdbc)).isEqualTo(before);
        }
    }

    @Test
    void cleanDatabaseAndRepeatedMigrateHaveTheSameForwardGuards() {
        try (var database = new PostgreSQLContainer<>("postgres:16-alpine")) {
            database.start();
            var migration = migration(database, "707");
            assertThat(migration.migrate().targetSchemaVersion).isEqualTo("707");
            migration.validate();
            assertForwardGuards(jdbc(database));
            assertThat(migration.migrate().migrationsExecuted).isZero();
        }
    }

    private static void seedHistory(JdbcTemplate jdbc) {
        UUID unit=UUID.randomUUID(), warehouse=UUID.randomUUID(), goods=UUID.randomUUID();
        UUID plan=UUID.randomUUID(), item=UUID.randomUUID(), pack=UUID.randomUUID(), report=UUID.randomUUID();
        jdbc.update("INSERT INTO units(id,code,name) VALUES(?,'V705-U','迁移单位')",unit);
        jdbc.update("INSERT INTO warehouses(id,code,name,status) VALUES(?,'V705-W','迁移仓库','使用')",warehouse);
        jdbc.update("""
                INSERT INTO goods(id,code,name,unit_id,code_sequence)
                VALUES(?,'V705-G','迁移材料',?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))
                """,goods,unit);
        jdbc.update("""
                INSERT INTO production_plans(id,bill_no,bill_date,status)
                VALUES(?,'SJ20260924007051',DATE '2026-09-24',1)
                """,plan);
        jdbc.update("""
                INSERT INTO production_plan_items(id,plan_id,bill_no,bill_date,product_no,goods_id,unit_id,unit_rate,qty,fqty,iqty)
                VALUES(?,?,'SJ20260924007051',DATE '2026-09-24','V705-P',?,?,1,100,0,0)
                """,item,plan,goods,unit);
        // A preserved pre-segment planning package is a supported historical source.
        jdbc.update("""
                INSERT INTO production_planning_packages(id,plan_id,warehouse_id,idempotency_key,request_hash,preview_fingerprint)
                VALUES(?,?,?,'v705-package',repeat('a',64),repeat('b',64))
                """,pack,plan,warehouse);
        jdbc.update("""
                INSERT INTO production_material_demands(package_id,plan_id,warehouse_id,goods_id,unit_id,required_qty,supply_route,idempotency_key)
                VALUES(?,?,?,?,?,11.75,'BUY','v705-demand')
                """,pack,plan,warehouse,goods,unit);
        jdbc.update("""
                INSERT INTO production_daily_reports(id,bill_no,bill_date,remark)
                VALUES(?,'SR20260924007051',DATE '2026-09-24','保留真实申报数量')
                """,report);
        jdbc.update("""
                INSERT INTO production_daily_report_items(report_id,plan_item_id,goods_id,unit_id,bill_no,bill_date,unit_rate,qty,is_final,destination)
                VALUES(?,?,?,?,'SR20260924007051',DATE '2026-09-24',1,17,FALSE,'WAREHOUSE')
                """,report,item,goods,unit);
        jdbc.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES(?,?,13.125)",warehouse,goods);
    }

    private static Map<String,String> snapshot(JdbcTemplate jdbc) {
        Map<String,String> result = new LinkedHashMap<>();
        for (String table : new String[]{"production_daily_reports","production_daily_report_items",
                "production_material_demands","production_planning_packages","production_plan_items","stock_balances"}) {
            result.put(table, jdbc.queryForObject("SELECT jsonb_agg(to_jsonb(fact)-'allowed_overproduction_rate'-'material_increment_request_id' ORDER BY id)::text FROM "
                    +table+" fact",String.class));
        }
        return result;
    }

    private static void assertForwardGuards(JdbcTemplate jdbc) {
        assertThat(jdbc.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE success AND version IS NOT NULL", Long.class))
                .isEqualTo(636);
        assertThat(jdbc.queryForObject("SELECT script FROM flyway_schema_history WHERE version='703'", String.class))
                .isEqualTo("V703__workshop_planning_urges.sql");
        assertThat(jdbc.queryForObject("SELECT script FROM flyway_schema_history WHERE version='707'", String.class))
                .isEqualTo("V707__planned_initial_overproduction_allowance.sql");
        assertThat(jdbc.queryForObject("SELECT pg_get_functiondef('fn_initialize_execution_overproduction_rate()'::regprocedure)", String.class))
                .contains("production_plan_items", "allowed_overproduction_rate");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='production_daily_report_target_events' AND column_name='overproduction_authorizations'", Long.class))
                .isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT pg_get_functiondef('fn_actual_supplement_material_ready(uuid)'::regprocedure)",String.class))
                .contains("LANGUAGE plpgsql", "fn_actual_supplement_increment_identity(target.id)");
        assertThat(jdbc.queryForObject("SELECT pg_get_functiondef('fn_execution_material_output_capacity(uuid,boolean)'::regprocedure)",String.class))
                .contains("LANGUAGE plpgsql", "demand.material_increment_request_id IS NULL");
        assertThat(jdbc.queryForObject("SELECT pg_get_functiondef('fn_assert_actual_report_material_posting(uuid)'::regprocedure)",String.class))
                .contains("fn_report_has_prior_same_segment_consumption");
        assertThat(jdbc.queryForObject("SELECT pg_get_indexdef('uq_actual_supplement_active_captured_input'::regclass)",String.class))
                .contains("CREATE UNIQUE INDEX", "idempotencyKey", "input_line_index");
        assertThat(jdbc.queryForObject("SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE tgname='trg_guard_supplement_plan_approval_context'",String.class))
                .contains("UPDATE OF status, actual_output_supplement_request_id");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgname='trg_guard_actual_supplement_plan_item_snapshot'",Long.class))
                .isEqualTo(1);
    }

    private static JdbcTemplate jdbc(PostgreSQLContainer<?> database) {
        return new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()));
    }

    private static Flyway migration(PostgreSQLContainer<?> database, String target) {
        return Flyway.configure().dataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword())
                .locations("classpath:db/migration").target(target).load();
    }
}
