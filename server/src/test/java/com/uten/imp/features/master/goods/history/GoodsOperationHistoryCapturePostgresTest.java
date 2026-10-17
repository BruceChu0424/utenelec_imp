package com.uten.imp.features.master.goods.history;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.sql.Connection;
import java.sql.SQLException;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Real, fully migrated PostgreSQL coverage of capture provenance and transaction boundaries. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsOperationHistoryCapturePostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;

    @BeforeAll static void migrate() throws SQLException {
        database = MigratedSchemaBaseline.openDatabase("goods_history_capture");
    }

    @AfterAll static void cleanup() throws SQLException {
        if (database != null) database.close();
    }

    @Test void actualControllerRoutesAreRecognizedAndReadOnlyCallsAreExcluded() throws SQLException {
        String goods = UUID.randomUUID().toString();
        String item = UUID.randomUUID().toString();
        try (Connection db = database.openConnection()) {
            assertEquals("BOM_PASTE", operation(db, "/api/master/goods/" + goods + "/bom/import/commit", "POST"));
            assertEquals("BOM_PASTE", operation(db, "/api/master/goods/bom/paste", "POST"));
            assertEquals("BOM_AUDIT", operation(db, "/api/master/goods/" + goods + "/bom/" + item + "/audit", "PUT"));
            assertEquals("GOODS_EDIT", operation(db, "/api/master/goods/" + goods.toUpperCase(java.util.Locale.ROOT), "PUT"));
            assertNull(operation(db, "/api/master/goods/" + goods + "/bom/import/detect", "POST"));
            assertNull(operation(db, "/api/master/goods/" + goods + "/bom/export", "POST"));
            assertNull(operation(db, "/api/master/goods/" + goods, "GET"));
        }
    }

    @Test void oneCommittedRequestGroupsRowsAndPreservesTheFirstBeforeAndFinalAfter() throws SQLException {
        UUID actor = UUID.randomUUID();
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        try (Connection db = database.openConnection()) {
            db.setAutoCommit(false);
            provenance(db, actor, "/api/master/goods/batch-status", "POST");
            goods(db, first, "first");
            goods(db, second, "second");
            execute(db, "UPDATE goods SET name='intermediate' WHERE id=?", first);
            execute(db, "UPDATE goods SET name='final' WHERE id=?", first);
            db.commit();

            assertEquals(1, count(db, "SELECT count(*) FROM goods_operation_history WHERE actor_id=?", actor));
            assertEquals(2, count(db, "SELECT count(*) FROM goods_operation_history_rows r JOIN goods_operation_history h ON h.id=r.operation_id WHERE h.actor_id=?", actor));
            assertEquals("final", scalar(db, "SELECT r.after_row->>'name' FROM goods_operation_history_rows r JOIN goods_operation_history h ON h.id=r.operation_id WHERE h.actor_id=? AND r.row_id=?", actor, first));
            assertNull(scalar(db, "SELECT r.before_row::text FROM goods_operation_history_rows r JOIN goods_operation_history h ON h.id=r.operation_id WHERE h.actor_id=? AND r.row_id=?", actor, first));
            assertEquals("final", scalar(db, "SELECT r.expected_row->>'name' FROM goods_operation_history_rows r JOIN goods_operation_history h ON h.id=r.operation_id WHERE h.actor_id=? AND r.row_id=?", actor, first));
            assertNull(scalar(db, "SELECT fn_audit_redact_row('goods_operation_history_rows',jsonb_build_object('before_row',jsonb_build_object('price',123,'remark','private'),'expected_row',jsonb_build_object('price',123)))->>'before_row'"));
            assertNull(scalar(db, "SELECT fn_audit_redact_row('goods_operation_history_rows',jsonb_build_object('expected_row',jsonb_build_object('price',123)))->>'expected_row'"));
        }
    }

    @Test void rollbackDoesNotCreateHistoryOrInvalidateTheExistingRedoBranch() throws SQLException {
        UUID actor = UUID.randomUUID();
        UUID id = UUID.randomUUID();
        try (Connection db = database.openConnection()) {
            db.setAutoCommit(false);
            provenance(db, actor, "/api/master/goods", "POST");
            goods(db, id, "stable");
            db.commit();
            execute(db, "UPDATE goods_operation_history SET state='UNDONE',redo_allowed=true WHERE actor_id=?", actor);
            db.commit();

            provenance(db, actor, "/api/master/goods/" + id, "PUT");
            execute(db, "UPDATE goods SET name='rolled back' WHERE id=?", id);
            assertEquals(2, count(db, "SELECT count(*) FROM goods_operation_history WHERE actor_id=?", actor));
            db.rollback();
            assertEquals(1, count(db, "SELECT count(*) FROM goods_operation_history WHERE actor_id=?", actor));
            assertEquals(1, count(db, "SELECT count(*) FROM goods_operation_history WHERE actor_id=? AND redo_allowed", actor));
            assertEquals("stable", scalar(db, "SELECT name FROM goods WHERE id=?", id));
        }
    }

    @Test void missingRequestProvenanceAndReplayNeverCreateAnAccidentalNestedCommand() throws SQLException {
        UUID actor = UUID.randomUUID();
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        try (Connection db = database.openConnection()) {
            db.setAutoCommit(false);
            goods(db, first, "without request");
            db.commit();
            provenance(db, actor, "/api/master/goods", "POST");
            execute(db, "SELECT set_config('app.goods_history_replay','on',true)");
            goods(db, second, "replay");
            db.commit();
            assertEquals(0, count(db, "SELECT count(*) FROM goods_operation_history WHERE actor_id=?", actor));
            assertNotNull(scalar(db, "SELECT name FROM goods WHERE id=?", second));
        }
    }

    @Test void newerCommittedOperationInvalidatesOnlyItsOwnActorsRedoBranch() throws SQLException {
        UUID actor = UUID.randomUUID();
        UUID other = UUID.randomUUID();
        try (Connection db = database.openConnection()) {
            db.setAutoCommit(false);
            for (UUID owner : new UUID[]{actor, other}) {
                provenance(db, owner, "/api/master/goods", "POST");
                goods(db, UUID.randomUUID(), "actor history");
                db.commit();
                execute(db, "UPDATE goods_operation_history SET state='UNDONE',redo_allowed=true WHERE actor_id=?", owner);
                db.commit();
            }
            provenance(db, actor, "/api/master/goods", "POST");
            goods(db, UUID.randomUUID(), "new command");
            db.commit();
            assertEquals(0, count(db, "SELECT count(*) FROM goods_operation_history WHERE actor_id=? AND redo_allowed", actor));
            assertEquals(1, count(db, "SELECT count(*) FROM goods_operation_history WHERE actor_id=? AND redo_allowed", other));
            assertTrue(count(db, "SELECT count(*) FROM flyway_schema_history WHERE success AND version='871'") == 1);
        }
    }

    @Test void twoEditsOnTheSameGoodsUndoAndRedoWithoutRollingBackVersions() throws SQLException {
        UUID actor = UUID.randomUUID();
        UUID id = UUID.randomUUID();
        try (Connection db = database.openConnection()) {
            db.setAutoCommit(false);
            goods(db, id, "original");
            db.commit();
            int initialVersion = count(db, "SELECT version FROM goods WHERE id=?", id);
            UUID first = edit(db, actor, id, "first");
            UUID second = edit(db, actor, id, "second");
            replay(db, actor, second, true);
            assertEquals("first", scalar(db, "SELECT name FROM goods WHERE id=?", id));
            replay(db, actor, first, true);
            assertEquals("original", scalar(db, "SELECT name FROM goods WHERE id=?", id));
            replay(db, actor, first, false);
            assertEquals("first", scalar(db, "SELECT name FROM goods WHERE id=?", id));
            replay(db, actor, second, false);
            assertEquals("second", scalar(db, "SELECT name FROM goods WHERE id=?", id));
            assertEquals(initialVersion + 6, count(db, "SELECT version FROM goods WHERE id=?", id));
            assertEquals(4, count(db, "SELECT count(*) FROM goods_operation_history_events WHERE actor_id=?", actor));
        }
    }

    @Test void aCreationCanBeUndoneAndRedoneRepeatedlyWithTheSameIdentity() throws SQLException {
        UUID actor = UUID.randomUUID();
        UUID id = UUID.randomUUID();
        try (Connection db = database.openConnection()) {
            db.setAutoCommit(false);
            provenance(db, actor, "/api/master/goods", "POST");
            goods(db, id, "created once");
            db.commit();
            UUID operation = latest(db, actor);
            int initialVersion = count(db, "SELECT version FROM goods WHERE id=?", id);
            for (int cycle = 0; cycle < 2; cycle++) {
                replay(db, actor, operation, true);
                assertEquals("true", scalar(db, "SELECT is_deleted::text FROM goods WHERE id=?", id));
                replay(db, actor, operation, false);
                assertEquals("false", scalar(db, "SELECT is_deleted::text FROM goods WHERE id=?", id));
                assertEquals("created once", scalar(db, "SELECT name FROM goods WHERE id=?", id));
            }
            assertEquals(1, count(db, "SELECT count(*) FROM goods WHERE id=?", id));
            assertEquals(initialVersion + 4, count(db, "SELECT version FROM goods WHERE id=?", id));
            assertEquals(4, count(db, "SELECT count(*) FROM goods_operation_history_events WHERE actor_id=?", actor));
        }
    }

    @Test void anOutsideAbaEditCannotBecomeEligibleThroughContentOnlyRebasing() throws SQLException {
        UUID actor = UUID.randomUUID();
        UUID id = UUID.randomUUID();
        try (Connection db = database.openConnection()) {
            db.setAutoCommit(false);
            goods(db, id, "original");
            db.commit();
            UUID operation = edit(db, actor, id, "changed");
            // A separate committed writer changes the name and then puts it back.
            // Its row version still proves that the original history is stale.
            execute(db, "UPDATE goods SET name='outside',version=version+1 WHERE id=?", id);
            db.commit();
            execute(db, "UPDATE goods SET name='changed',version=version+1 WHERE id=?", id);
            db.commit();
            assertThrows(SQLException.class, () -> replay(db, actor, operation, true));
            db.rollback();
            assertEquals("changed", scalar(db, "SELECT name FROM goods WHERE id=?", id));
            assertEquals(0, count(db, "SELECT count(*) FROM goods_operation_history_events WHERE actor_id=?", actor));
        }
    }

    @Test void legacyBinaryImagesAreRepresentedByDigestRatherThanCopiedIntoEachHistoryRow() throws SQLException {
        UUID actor = UUID.randomUUID();
        UUID id = UUID.randomUUID();
        try (Connection db = database.openConnection()) {
            db.setAutoCommit(false);
            goods(db, id, "large image");
            execute(db, "UPDATE goods SET product_graph1=? WHERE id=?", new byte[2 * 1024 * 1024], id);
            db.commit();
            edit(db, actor, id, "renamed");
            assertTrue(count(db, "SELECT max(length(r.after_row::text)) FROM goods_operation_history_rows r JOIN goods_operation_history h ON h.id=r.operation_id WHERE h.actor_id=?", actor) < 50_000);
            assertNotNull(scalar(db, "SELECT r.after_row->'__binary'->>'product_graph1' FROM goods_operation_history_rows r JOIN goods_operation_history h ON h.id=r.operation_id WHERE h.actor_id=?", actor));
        }
    }

    @Test void undoingAnEarlierPriceEditPreservesMaterialCostRecalculatedByALaterBomUndo() throws SQLException {
        UUID actor = UUID.randomUUID();
        UUID parent = UUID.randomUUID();
        UUID component = UUID.randomUUID();
        UUID edge = UUID.randomUUID();
        try (Connection db = database.openConnection()) {
            db.setAutoCommit(false);
            goods(db, parent, "parent");
            goods(db, component, "component");
            execute(db, "UPDATE goods SET price=10 WHERE id=?", component);
            execute(db, "INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty) VALUES(?,?,?,1)", edge, parent, component);
            execute(db, "UPDATE goods SET price=50,source_e=10 WHERE id=?", parent);
            db.commit();

            provenance(db, actor, "/api/master/goods/" + parent, "PUT");
            execute(db, "UPDATE goods SET price=60,version=version+1 WHERE id=?", parent);
            db.commit();
            UUID priceEdit = latest(db, actor);

            provenance(db, actor, "/api/master/goods/" + parent + "/bom/" + edge, "PUT");
            execute(db, "UPDATE goods_bom_items SET qty=2 WHERE id=?", edge);
            execute(db, "UPDATE goods SET source_e=20,version=version+1 WHERE id=?", parent);
            db.commit();
            UUID bomEdit = latest(db, actor);

            // Component pricing can change without writing the parent goods row.
            execute(db, "UPDATE goods SET price=15,version=version+1 WHERE id=?", component);
            db.commit();
            replay(db, actor, bomEdit, true);
            assertEquals(0, new java.math.BigDecimal(scalar(db, "SELECT source_e FROM goods WHERE id=?", parent)).compareTo(new java.math.BigDecimal("15")));
            replay(db, actor, priceEdit, true);
            assertEquals(0, new java.math.BigDecimal(scalar(db, "SELECT source_e FROM goods WHERE id=?", parent)).compareTo(new java.math.BigDecimal("15")));
            assertEquals(0, new java.math.BigDecimal(scalar(db, "SELECT price FROM goods WHERE id=?", parent)).compareTo(new java.math.BigDecimal("50")));
            replay(db, actor, priceEdit, false);
            replay(db, actor, bomEdit, false);
            assertEquals(0, new java.math.BigDecimal(scalar(db, "SELECT source_e FROM goods WHERE id=?", parent)).compareTo(new java.math.BigDecimal("30")));
        }
    }

    private static UUID edit(Connection db, UUID actor, UUID id, String name) throws SQLException {
        provenance(db, actor, "/api/master/goods/" + id, "PUT");
        execute(db, "UPDATE goods SET name=?,version=version+1 WHERE id=?", name, id);
        db.commit();
        return latest(db, actor);
    }

    private static UUID latest(Connection db, UUID actor) throws SQLException {
        return UUID.fromString(scalar(db, "SELECT id FROM goods_operation_history WHERE actor_id=? ORDER BY created_at DESC,id DESC LIMIT 1", actor));
    }

    private static void replay(Connection db, UUID actor, UUID operation, boolean undo) throws SQLException {
        Long version = number(db, "SELECT version FROM goods_operation_history WHERE id=?", operation);
        assertNotNull(version);
        execute(db, "SELECT fn_replay_goods_operation(?,?,?,?)", operation, actor, version, undo);
        db.commit();
    }

    private static String operation(Connection db, String path, String method) throws SQLException {
        return scalar(db, "SELECT fn_goods_history_operation(?,?)", path, method);
    }

    private static void provenance(Connection db, UUID actor, String path, String method) throws SQLException {
        execute(db, "SELECT set_config('app.actor_id',?,true),set_config('app.audit_request_id',?,true),set_config('app.audit_request_path',?,true),set_config('app.audit_request_method',?,true)", actor.toString(), UUID.randomUUID().toString(), path, method);
    }

    private static void goods(Connection db, UUID id, String name) throws SQLException {
        execute(db, "INSERT INTO goods(id,code,name,code_sequence) VALUES(?,?,?,(SELECT COALESCE(max(code_sequence),0)+1 FROM goods))", id, "HISTORY-" + id, name);
    }

    private static void execute(Connection db, String sql, Object... args) throws SQLException {
        try (var statement = db.prepareStatement(sql)) {
            for (int i = 0; i < args.length; i++) statement.setObject(i + 1, args[i]);
            statement.execute();
        }
    }

    private static int count(Connection db, String sql, Object... args) throws SQLException {
        Long result = number(db, sql, args);
        return result == null ? 0 : Math.toIntExact(result);
    }

    private static Long number(Connection db, String sql, Object... args) throws SQLException {
        try (var statement = db.prepareStatement(sql)) {
            for (int i = 0; i < args.length; i++) {
                statement.setObject(i + 1, args[i]);
            }
            try (var result = statement.executeQuery()) {
                return result.next() ? result.getObject(1, Long.class) : null;
            }
        }
    }

    private static String scalar(Connection db, String sql, Object... args) throws SQLException {
        try (var statement = db.prepareStatement(sql)) {
            for (int i = 0; i < args.length; i++) statement.setObject(i + 1, args[i]);
            try (var result = statement.executeQuery()) {
                return result.next() ? result.getString(1) : null;
            }
        }
    }
}
