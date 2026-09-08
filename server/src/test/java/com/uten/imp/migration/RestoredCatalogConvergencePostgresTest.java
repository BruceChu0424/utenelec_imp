package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

/** Reproduces semantic differences observed in the real V476 server readback. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class RestoredCatalogConvergencePostgresTest {
    private static final Map<String, String> HISTORICAL_GUARDS = Map.of(
            "production_material_stock_events", "trg_00_reject_production_material_stock_event_mutation",
            "production_material_stock_postings", "trg_00_reject_production_material_stock_posting_mutation",
            "production_material_settlement_events", "trg_00_reject_production_material_settlement_event_mutation",
            "production_material_settlement_postings", "trg_00_reject_production_material_settlement_posting_mutation",
            "sales_shipment_warehouse_events", "trg_00_reject_sales_shipment_warehouse_event_mutation",
            "sales_return_quality_events", "trg_00_reject_sales_return_quality_event_mutation",
            "sales_return_disposition_events", "trg_00_reject_sales_return_disposition_event_mutation",
            "procurement_inspection_events", "trg_00_reject_procurement_inspection_event_mutation");

    @Test
    void convergesKnownDriftPreservesEvidenceAndRefusesUnknownObjects() throws Exception {
        try (var database = new PostgreSQLContainer<>("postgres:16-alpine")) {
            database.start();
            Flyway.configure().dataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword())
                    .locations("classpath:db/migration").target("476").load().migrate();
            String migration;
            try (var resource = getClass().getResourceAsStream("/db/migration/V505__restored_catalog_semantic_convergence.sql")) {
                assertThat(resource).isNotNull();
                migration = new String(resource.readAllBytes(), StandardCharsets.UTF_8);
            }
            try (Connection connection = DriverManager.getConnection(database.getJdbcUrl(), database.getUsername(), database.getPassword());
                 var sql = connection.createStatement()) {
                // Ordinary valid business evidence exists before the repair; no disabled FK or trigger seeds.
                sql.execute("INSERT INTO warehouses(id,code,name) VALUES ('00500505-0000-0000-0000-000000000001','W-SCHEMA-TEST','schema test warehouse')");
                sql.execute("INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,warehouse_id,status) VALUES ('00500505-0000-0000-0000-000000000002','DRAW','SL20260907000505','2026-09-07','00500505-0000-0000-0000-000000000001',1)");
                sql.execute("INSERT INTO production_material_stock_events(id,stock_document_id,event_type,idempotency_key,request_hash) VALUES ('00500505-0000-0000-0000-000000000003','00500505-0000-0000-0000-000000000002','ISSUE','schema-guard-505',repeat('a',64))");
                String before = eventDigest(connection);
                for (var guard : HISTORICAL_GUARDS.entrySet()) {
                    sql.execute("ALTER TABLE " + guard.getKey() + " ENABLE TRIGGER " + guard.getValue());
                }
                sql.execute("DROP INDEX audit_log_archive_event_category_created_at_idx");
                sql.execute("DROP INDEX audit_log_archive_request_id_idx");
                sql.execute("DROP INDEX audit_log_archive_risk_level_created_at_idx");
                connection.setAutoCommit(false);
                sql.execute(migration);
                connection.commit();
                assertThat(eventDigest(connection)).isEqualTo(before);
                try (var rows = sql.executeQuery("SELECT count(*) FROM pg_trigger WHERE tgenabled='A' AND tgname IN ('trg_00_reject_production_material_stock_event_mutation','trg_00_reject_production_material_stock_posting_mutation','trg_00_reject_production_material_settlement_event_mutation','trg_00_reject_production_material_settlement_posting_mutation','trg_00_reject_sales_shipment_warehouse_event_mutation','trg_00_reject_sales_return_quality_event_mutation','trg_00_reject_sales_return_disposition_event_mutation','trg_00_reject_procurement_inspection_event_mutation')")) {
                    rows.next(); assertThat(rows.getInt(1)).isEqualTo(8);
                }
                try (var rows = sql.executeQuery("SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND tablename='audit_log_archive' AND indexname IN ('audit_log_archive_event_category_created_at_idx','audit_log_archive_request_id_idx','audit_log_archive_risk_level_created_at_idx')")) {
                    rows.next(); assertThat(rows.getInt(1)).isEqualTo(3);
                }
                try (var rows = sql.executeQuery("SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='sales_other_shipment_items' AND column_name IN ('material_price','die_cast_price','machining_price') AND column_default IS NULL")) {
                    rows.next(); assertThat(rows.getInt(1)).isEqualTo(3);
                }
                try (var rows = sql.executeQuery("SELECT count(*) FROM pg_trigger WHERE tgrelid='master_code_sequences'::regclass AND tgname='trg_audit_master_code_sequences'")) {
                    rows.next(); assertThat(rows.getInt(1)).isZero();
                }
                sql.execute("SET LOCAL session_replication_role='replica'");
                var valid = connection.setSavepoint();
                var refused = assertThrows(PSQLException.class, () -> sql.execute("UPDATE production_material_stock_events SET created_at=created_at WHERE id='00500505-0000-0000-0000-000000000003'"));
                assertThat(refused.getSQLState()).isEqualTo("55000");
                connection.rollback(valid);
                connection.rollback();

                // A same-name but different object must not be treated as an installed good index.
                valid = connection.setSavepoint();
                sql.execute("DROP INDEX audit_log_archive_request_id_idx");
                sql.execute("CREATE INDEX audit_log_archive_request_id_idx ON audit_log_archive(created_at)");
                SQLException wrongIndex = assertThrows(SQLException.class, () -> sql.execute(migration));
                assertThat(wrongIndex.getMessage()).contains("V505 unrecognized archive index");
                connection.rollback(valid);
                valid = connection.setSavepoint();
                sql.execute("ALTER TRIGGER trg_00_reject_production_material_stock_event_mutation ON production_material_stock_events RENAME TO unexpected_stock_event_guard");
                SQLException wrongGuard = assertThrows(SQLException.class, () -> sql.execute(migration));
                assertThat(wrongGuard.getMessage()).contains("V505 unrecognized append-only guard");
                connection.rollback(valid);
                assertThat(eventDigest(connection)).isEqualTo(before);
                connection.rollback();
            }
        }
    }

    private static String eventDigest(Connection connection) throws SQLException {
        try (var query = connection.createStatement(); var rows = query.executeQuery(
                "SELECT md5(string_agg(to_jsonb(e)::text,E'\\n' ORDER BY id)) FROM production_material_stock_events e")) {
            rows.next(); return rows.getString(1);
        }
    }
}
