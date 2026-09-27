package com.uten.imp.migration;

import com.uten.imp.support.MigratedProjectionSchema;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.FlywayException;
import org.flywaydb.core.api.MigrationInfo;
import org.flywaydb.core.api.MigrationVersion;
import org.flywaydb.core.api.callback.Context;
import org.flywaydb.core.api.callback.Event;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Runs the immutable V719/V720 label SQL against real PostgreSQL and the actual
 * V438/V503 freeze functions. The fixture intentionally isolates label/finance
 * lineage from unrelated workbench views and operational data requirements.
 * Column shapes come from the actual V718 catalog, not handwritten fixture DDL.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class FrozenAnalysisLabelMigrationPostgresTest {
    @TempDir Path migrations;

    @Test
    void immutableBackfillsKeepApprovedRowsAndRestoreAllGuards() throws Exception {
        try (var database = new PostgreSQLContainer<>("postgres:16-alpine")) {
            database.start();
            List<Seed> seeds = new ArrayList<>();
            try (var connection = connection(database)) {
                schema(connection);
                for (String type : List.of("PURCHASE", "SUBCONTRACT")) {
                    for (String prefix : List.of("计划前物料分析 ", "物料分析汇总 ")) {
                        seeds.add(seed(connection, type, prefix, "PENDING"));
                        seeds.add(seed(connection, type, prefix, "APPROVED"));
                        seeds.add(seed(connection, type, prefix, null));
                    }
                }
            }
            // Copy the exact label backfill section; V719's following workbench
            // view definition is independent of the historical label conflict.
            String v719 = resource("V719__material_analysis_plan_numbers.sql");
            Files.writeString(migrations.resolve("V719__label_backfill.sql"),
                    v719.substring(0, v719.indexOf("-- ⑤ 执行工作台")));
            Files.writeString(migrations.resolve("V720__label_backfill.sql"),
                    resource("V720__aggregate_order_source_labels.sql"));

            assertThrows(FlywayException.class, () -> flyway(database, false).migrate());
            try (var connection = connection(database)) {
                assertEquals(0, scalar(connection,
                        "SELECT count(*) FROM information_schema.columns WHERE table_name="
                                + "'production_material_analyses' AND column_name='analysis_no'"));
                assertEquals(0, scalar(connection, "SELECT count(*) FROM pg_proc "
                        + "WHERE proname='fn_preserve_frozen_analysis_label_migration'"));
            }
            assertEquals(2, flyway(database, true).migrate().migrationsExecuted);
            assertEquals(0, flyway(database, true).migrate().migrationsExecuted);
            try (var connection = connection(database)) {
                for (Seed seed : seeds) {
                    String label = text(connection, "SELECT source_doc_no FROM "
                            + seed.table() + " WHERE id='" + seed.item() + "'");
                    if (seed.locked()) {
                        assertEquals(seed.originalRow(), text(connection,
                                "SELECT to_jsonb(item)::text FROM " + seed.table()
                                        + " item WHERE id='" + seed.item() + "'"));
                        assertEquals(seed.originalSnapshot(), text(connection,
                                "SELECT display_snapshot::text FROM procurement_order_approval_cases "
                                        + "WHERE order_id='" + seed.order() + "'"));
                    } else {
                        assertTrue(label.matches("WL[0-9]{14}"));
                        assertEquals(seed.originalCore(), text(connection,
                                "SELECT (to_jsonb(item)-ARRAY['source_doc_no','production_plan_no'])::text "
                                        + "FROM " + seed.table() + " item WHERE id='" + seed.item() + "'"));
                    }
                }
                assertNoCompatibilityObjects(connection);
                assertEquals(2, scalar(connection, "SELECT count(*) FROM pg_trigger "
                        + "WHERE tgname IN('trg_guard_purchase_order_commercial_items',"
                        + "'trg_guard_subcontract_order_commercial_items') AND tgenabled='A'"));
                for (Seed seed : seeds.stream().filter(Seed::locked).toList()) {
                    assertGuarded(connection, "UPDATE " + seed.table()
                            + " SET source_doc_no='WL20260925009999' WHERE id='" + seed.item() + "'");
                    assertGuarded(connection, "UPDATE " + seed.table()
                            + " SET qty=11 WHERE id='" + seed.item() + "'");
                }
                strictProtectionAndRollback(connection, seeds.getFirst());
            }
        }
    }

    private void strictProtectionAndRollback(Connection connection, Seed seed) throws Exception {
        var callback = new AppliedMigrationCompatibilityCallback();
        var context = context(connection, "719");
        assertTrue(callback.supports(Event.BEFORE_EACH_MIGRATE, context));
        assertTrue(callback.supports(Event.AFTER_EACH_MIGRATE, context));
        assertFalse(callback.supports(Event.AFTER_EACH_MIGRATE, context(connection, "718")));
        assertFalse(callback.supports(Event.BEFORE_EACH_MIGRATE, context(connection, "721")));
        String target = text(connection, "SELECT analysis_no FROM production_material_analyses "
                + "WHERE id='" + seed.analysis() + "'");
        String precise = "UPDATE purchase_order_items SET source_doc_no='" + target
                + "',production_plan_no='" + target + "'";
        String where = " WHERE id='" + seed.item() + "'";
        connection.setAutoCommit(false);
        callback.handle(Event.BEFORE_EACH_MIGRATE, context);
        for (String extra : List.of(
                ",qty=11", ",amount_original=11", ",request_item_id=gen_random_uuid()",
                ",remark='unexpected change'")) {
            var savepoint = connection.setSavepoint();
            assertGuarded(connection, precise + extra + where);
            connection.rollback(savepoint);
        }
        var savepoint = connection.setSavepoint();
        assertGuarded(connection, "UPDATE purchase_order_items SET source_doc_no='WL20260925009999',"
                + "production_plan_no='WL20260925009999'" + where);
        connection.rollback(savepoint);
        savepoint = connection.setSavepoint();
        exec(connection, "DELETE FROM purchase_order_item_sources WHERE order_item_id='" + seed.item() + "'");
        assertGuarded(connection, precise + where);
        connection.rollback(savepoint);
        savepoint = connection.setSavepoint();
        UUID otherAnalysis = UUID.randomUUID();
        exec(connection, "INSERT INTO production_material_analyses(id,analysis_no,analyzed_at) VALUES ('"
                + otherAnalysis + "','WL20260925009998','2026-09-25T10:00:00+08:00')");
        exec(connection, "INSERT INTO preplan_supply_actions(analysis_id,external_document_type,external_document_id) SELECT '" + otherAnalysis + "',"
                + "external_document_type,external_document_id FROM preplan_supply_actions "
                + "WHERE analysis_id='" + seed.analysis() + "'");
        assertGuarded(connection, precise + where);
        connection.rollback(savepoint);
        assertEquals(0, exec(connection, precise + where));
        // A failed migration rolls back installation, without an after callback.
        connection.rollback();
        connection.setAutoCommit(true);
        assertNoCompatibilityObjects(connection);
        assertGuarded(connection, precise + where);
        assertEquals(seed.originalRow(), text(connection,
                "SELECT to_jsonb(item)::text FROM purchase_order_items item" + where));
    }

    private static Context context(Connection connection, String version) {
        Context context = mock(Context.class);
        MigrationInfo migration = mock(MigrationInfo.class);
        when(context.getConnection()).thenReturn(connection);
        when(context.getMigrationInfo()).thenReturn(migration);
        when(migration.getVersion()).thenReturn(MigrationVersion.fromVersion(version));
        return context;
    }

    private Flyway flyway(PostgreSQLContainer<?> database, boolean compatible) {
        var configuration = Flyway.configure()
                .dataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword())
                .locations("filesystem:" + migrations.toAbsolutePath())
                .baselineVersion("718").baselineOnMigrate(true).cleanDisabled(true);
        if (compatible) configuration.callbacks(new AppliedMigrationCompatibilityCallback());
        return configuration.load();
    }

    private static Seed seed(Connection connection, String type, String prefix, String status)
            throws Exception {
        String stem = type.equals("PURCHASE") ? "purchase" : "subcontract";
        String source = type.equals("PURCHASE") ? "request" : "application";
        UUID analysis = UUID.randomUUID(), request = UUID.randomUUID(), requestItem = UUID.randomUUID();
        UUID order = UUID.randomUUID(), item = UUID.randomUUID();
        String label = prefix + "2026-09-25";
        exec(connection, "INSERT INTO production_material_analyses(id,analyzed_at) VALUES ('" + analysis
                + "','2026-09-25T10:00:00+08:00')");
        exec(connection, "INSERT INTO " + stem + "_" + source + "s(id,source_doc_no,remark) VALUES ('" + request
                + "','" + label + "','" + label + "')");
        exec(connection, "INSERT INTO " + stem + "_" + source + "_items(id," + source + "_id,source_doc_no"
                + (type.equals("PURCHASE") ? ",production_plan_no" : "") + ") VALUES ('" + requestItem
                + "','" + request + "','" + label + "'" + (type.equals("PURCHASE") ? ",'" + label + "'" : "") + ")");
        exec(connection, "INSERT INTO preplan_supply_actions(analysis_id,external_document_type,external_document_id) VALUES ('" + analysis + "','"
                + (type.equals("PURCHASE") ? "PURCHASE_REQUEST" : "SUBCONTRACT_APPLICATION")
                + "','" + request + "')");
        exec(connection, "INSERT INTO " + stem + "_orders(id,source_doc_no) VALUES ('"
                + order + "','" + label + "')");
        exec(connection, "INSERT INTO " + stem + "_order_items(id,order_id,qty,price,amount_original,"
                + "amount_local,source_doc_no," + (type.equals("PURCHASE") ? "production_plan_no," : "") + source + "_item_id) VALUES ('"
                + item + "','" + order + "',10,2,20,20,'" + label + "'," + (type.equals("PURCHASE") ? "'" + label + "'," : "") + "'" + requestItem + "')");
        exec(connection, "INSERT INTO " + stem + "_order_item_sources(order_item_id," + source + "_item_id) VALUES ('" + item
                + "','" + requestItem + "')");
        if (status != null) {
            exec(connection, "INSERT INTO procurement_order_approval_cases(order_type,order_id,status,display_snapshot) VALUES ('" + type + "','"
                    + order + "','" + status + "',jsonb_build_object('sourceDocNo','" + label + "'))");
        }
        return new Seed(stem + "_order_items", item, order, analysis, status != null,
                text(connection, "SELECT to_jsonb(item)::text FROM " + stem + "_order_items item WHERE id='" + item + "'"),
                text(connection, "SELECT (to_jsonb(item)-ARRAY['source_doc_no','production_plan_no'])::text "
                        + "FROM " + stem + "_order_items item WHERE id='" + item + "'"),
                status == null ? null : text(connection, "SELECT display_snapshot::text FROM procurement_order_approval_cases WHERE order_id='" + order + "'"));
    }

    private static void schema(Connection connection) throws Exception {
        MigratedProjectionSchema.createTables(
                new JdbcTemplate(new SingleConnectionDataSource(connection, true)), "718",
                "business_identifier_namespaces", "business_document_sequences",
                "production_material_analyses", "preplan_supply_actions",
                "procurement_order_approval_cases", "procurement_order_source_revisions",
                "purchase_requests", "purchase_request_items", "purchase_orders", "purchase_order_items",
                "purchase_order_item_sources", "purchase_receipt_items", "subcontract_applications",
                "subcontract_application_items", "subcontract_orders", "subcontract_order_items",
                "subcontract_order_item_sources", "subcontract_receipt_items");
        String v438 = resource("V438__procurement_commercial_snapshot_guard.sql");
        exec(connection, function(v438, "CREATE OR REPLACE FUNCTION procurement_order_commercial_locked("));
        String v503 = resource("V503__procurement_order_source_quantity_revisions.sql");
        exec(connection, function(v503, "CREATE FUNCTION fn_is_proven_procurement_qty_revision("));
        exec(connection, function(v503, "CREATE OR REPLACE FUNCTION fn_guard_procurement_order_item_commercial_mutation()"));
        exec(connection, v438.substring(v438.indexOf("CREATE TRIGGER trg_guard_purchase_order_commercial_items"),
                v438.indexOf("COMMENT ON COLUMN subcontract_wastes")));
    }

    private static String function(String resource, String start) {
        int from = resource.indexOf(start);
        int end = resource.indexOf("\n$$;", from);
        assertTrue(from >= 0 && end > from);
        return resource.substring(from, end + 4);
    }

    private static String resource(String name) throws Exception {
        try (var input = FrozenAnalysisLabelMigrationPostgresTest.class.getResourceAsStream("/db/migration/" + name)) {
            assertNotNull(input);
            return new String(input.readAllBytes(), StandardCharsets.UTF_8).replace("\r\n", "\n");
        }
    }

    private static void assertGuarded(Connection connection, String sql) {
        SQLException failure = assertThrows(SQLException.class, () -> exec(connection, sql));
        assertEquals("23514", failure.getSQLState());
        assertEquals("procurement_order_commercial_item_freeze_guard",
                ((org.postgresql.util.PSQLException) failure).getServerErrorMessage().getConstraint());
    }

    private static void assertNoCompatibilityObjects(Connection connection) throws Exception {
        assertEquals(0, scalar(connection, "SELECT count(*) FROM pg_trigger "
                + "WHERE tgname='aa_preserve_frozen_analysis_label_migration'"));
        assertEquals(0, scalar(connection, "SELECT count(*) FROM pg_proc "
                + "WHERE proname='fn_preserve_frozen_analysis_label_migration'"));
    }

    private static int scalar(Connection connection, String sql) throws Exception {
        return Integer.parseInt(text(connection, sql));
    }

    private static String text(Connection connection, String sql) throws Exception {
        try (var statement = connection.createStatement(); var result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getString(1);
        }
    }

    private static int exec(Connection connection, String sql) throws SQLException {
        try (var statement = connection.createStatement()) {
            return statement.executeUpdate(sql);
        }
    }

    private static Connection connection(PostgreSQLContainer<?> database) throws Exception {
        return DriverManager.getConnection(database.getJdbcUrl(), database.getUsername(), database.getPassword());
    }

    private record Seed(String table, UUID item, UUID order, UUID analysis, boolean locked,
                        String originalRow, String originalCore, String originalSnapshot) {}
}
