package com.uten.imp.features.master.goods;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Full migration, capture and replay coverage in a disposable PostgreSQL database. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsClientGoodsNamePostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private Connection db;
    private UUID actor;

    @BeforeAll static void migrate() throws SQLException {
        database = MigratedSchemaBaseline.openDatabase("goods_client_name");
    }

    @AfterAll static void stop() throws SQLException { if (database != null) database.close(); }

    @BeforeEach void open() throws SQLException {
        db = database.openConnection(); db.setAutoCommit(false); actor = UUID.randomUUID();
    }

    @AfterEach void close() throws SQLException { if (db != null) { db.rollback(); db.close(); } }

    @Test void oldInsertDefaultsToNullAndSameCustomerNameIsIndependentForEachGoodsUuid() throws SQLException {
        assertEquals("text", text("SELECT data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='goods' AND column_name='client_goods_name'"));
        assertEquals("YES", text("SELECT is_nullable FROM information_schema.columns WHERE table_schema='public' AND table_name='goods' AND column_name='client_goods_name'"));
        assertNull(text("SELECT column_default FROM information_schema.columns WHERE table_schema='public' AND table_name='goods' AND column_name='client_goods_name'"));
        UUID first = goods("内部货品甲"), second = goods("内部货品乙");
        assertNull(text("SELECT client_goods_name FROM goods WHERE id=?", first));
        execute("UPDATE goods SET client_goods_name='客户共用名称',model='OWN-A',c_number='CLIENT-A' WHERE id=?", first);
        execute("UPDATE goods SET client_goods_name='客户共用名称',model='OWN-B',c_number='CLIENT-B' WHERE id=?", second);
        assertEquals(2, number("SELECT count(*) FROM goods WHERE id IN (?,?) AND client_goods_name='客户共用名称'", first, second));
        execute("UPDATE goods SET client_goods_name='客户甲新名称' WHERE id=?", first);
        assertEquals("客户共用名称", text("SELECT client_goods_name FROM goods WHERE id=?", second));
        assertEquals("内部货品甲", text("SELECT name FROM goods WHERE id=?", first));
        assertEquals("OWN-A", text("SELECT model FROM goods WHERE id=?", first));
        assertEquals("CLIENT-A", text("SELECT c_number FROM goods WHERE id=?", first));
        assertEquals("CLIENT-B", text("SELECT c_number FROM goods WHERE id=?", second));
        assertEquals(0, number("SELECT count(*) FROM goods WHERE id IN (?,?) AND client_id IS NOT NULL", first, second));
    }

    @Test void newCustomerNameIsCapturedAndUndoRedoRestoresOnlyItsOwnField() throws SQLException {
        UUID id = goods("内部名称");
        execute("UPDATE goods SET model='OWN-MODEL',c_number='CLIENT-MODEL' WHERE id=?", id);
        db.commit();
        UUID operation = edit(id, "UPDATE goods SET client_goods_name='客户名称',version=version+1 WHERE id=?");
        assertEquals("true", text("SELECT jsonb_exists(before_row,'client_goods_name')::text FROM goods_operation_history_rows WHERE operation_id=? AND table_name='goods'", operation));
        assertNull(text("SELECT before_row->>'client_goods_name' FROM goods_operation_history_rows WHERE operation_id=? AND table_name='goods'", operation));
        assertEquals("客户名称", text("SELECT after_row->>'client_goods_name' FROM goods_operation_history_rows WHERE operation_id=? AND table_name='goods'", operation));
        replay(operation, true);
        assertNull(text("SELECT client_goods_name FROM goods WHERE id=?", id));
        replay(operation, false);
        assertEquals("客户名称", text("SELECT client_goods_name FROM goods WHERE id=?", id));
        assertEquals("内部名称", text("SELECT name FROM goods WHERE id=?", id));
        assertEquals("OWN-MODEL", text("SELECT model FROM goods WHERE id=?", id));
        assertEquals("CLIENT-MODEL", text("SELECT c_number FROM goods WHERE id=?", id));
        assertEquals(2, number("SELECT count(*) FROM goods_operation_history_events WHERE operation_id=?", operation));
    }

    @Test void legacyMissingCustomerNameKeysCompareAsNullAndReplayWithoutRewritingRetainedEvidence() throws SQLException {
        UUID id = goods("原名称"); db.commit();
        UUID operation = edit(id, "UPDATE goods SET name='修改名称',version=version+1 WHERE id=?");
        stripHistoryKey(operation, "goods", "client_goods_name"); db.commit();
        String before = text("SELECT before_row::text FROM goods_operation_history_rows WHERE operation_id=? AND table_name='goods'", operation);
        String after = text("SELECT after_row::text FROM goods_operation_history_rows WHERE operation_id=? AND table_name='goods'", operation);
        assertEquals("true", text("SELECT (fn_goods_history_snapshot('goods'::regclass,g)=fn_goods_bom_history_schema(r.expected_row,'goods'))::text FROM goods g JOIN goods_operation_history_rows r ON r.row_id=g.id WHERE r.operation_id=?", operation));

        replay(operation, true);
        assertEquals("原名称", text("SELECT name FROM goods WHERE id=?", id));
        assertNull(text("SELECT client_goods_name FROM goods WHERE id=?", id));
        replay(operation, false);
        assertEquals("修改名称", text("SELECT name FROM goods WHERE id=?", id));
        assertNull(text("SELECT client_goods_name FROM goods WHERE id=?", id));
        assertEquals(before, text("SELECT before_row::text FROM goods_operation_history_rows WHERE operation_id=? AND table_name='goods'", operation));
        assertEquals(after, text("SELECT after_row::text FROM goods_operation_history_rows WHERE operation_id=? AND table_name='goods'", operation));
        assertEquals("false", text("SELECT (jsonb_exists(before_row,'client_goods_name') OR jsonb_exists(after_row,'client_goods_name'))::text FROM goods_operation_history_rows WHERE operation_id=? AND table_name='goods'", operation));
    }

    @Test void legacyNullCompatibilityCannotHideALaterNonNullCustomerNameEvenWithoutAVersionBump() throws SQLException {
        UUID id = goods("原名称"); db.commit();
        UUID operation = edit(id, "UPDATE goods SET name='历史名称',version=version+1 WHERE id=?");
        stripHistoryKey(operation, "goods", "client_goods_name"); db.commit();
        long version = number("SELECT version FROM goods WHERE id=?", id);
        // Deliberately keep the version: this proves content CAS, rather than only version CAS, protects the new field.
        execute("UPDATE goods SET client_goods_name='后续客户名称' WHERE id=?", id); db.commit();
        assertEquals(version, number("SELECT version FROM goods WHERE id=?", id));
        assertEquals("后续客户名称", text("SELECT fn_goods_bom_history_schema(jsonb_build_object('client_goods_name','后续客户名称'),'goods')->>'client_goods_name'"));
        assertEquals("false", text("SELECT (fn_goods_history_snapshot('goods'::regclass,g)=fn_goods_bom_history_schema(r.expected_row,'goods'))::text FROM goods g JOIN goods_operation_history_rows r ON r.row_id=g.id WHERE r.operation_id=?", operation));

        SQLException failure = assertThrows(SQLException.class, () -> replay(operation, true));
        assertEquals("P0001", failure.getSQLState());
        db.rollback();
        assertEquals("历史名称", text("SELECT name FROM goods WHERE id=?", id));
        assertEquals("后续客户名称", text("SELECT client_goods_name FROM goods WHERE id=?", id));
        assertEquals(0, number("SELECT count(*) FROM goods_operation_history_events WHERE operation_id=?", operation));
    }

    @Test void extendingGoodsHistoryRetainsLegacyBomRetirementCompatibilityAndActualReplay() throws SQLException {
        UUID parent = goods("BOM产品"), component = goods("BOM材料"), edge = UUID.randomUUID();
        execute("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty) VALUES(?,?,?,1)", edge, parent, component);
        db.commit();
        provenance("/api/master/goods/" + parent + "/bom/" + edge, "PUT");
        execute("UPDATE goods_bom_items SET qty=2 WHERE id=?", edge); db.commit();
        UUID operation = latest();
        stripHistoryKey(operation, "goods_bom_items", "retirement_reason");
        stripHistoryKey(operation, "goods_bom_items", "retirement_resolved_at"); db.commit();
        String retained = text("SELECT after_row::text FROM goods_operation_history_rows WHERE operation_id=? AND table_name='goods_bom_items'", operation);

        assertEquals("true", text("SELECT (fn_goods_bom_history_schema('{}'::jsonb,'goods_bom_items') = '{\"retirement_reason\":null,\"retirement_resolved_at\":null}'::jsonb)::text"));
        assertEquals("DISABLED_COMPONENT", text("SELECT fn_goods_bom_history_schema('{\"retirement_reason\":\"DISABLED_COMPONENT\"}'::jsonb,'goods_bom_items')->>'retirement_reason'"));
        replay(operation, true);
        assertEquals(0, new BigDecimal("1").compareTo(new BigDecimal(text("SELECT qty::text FROM goods_bom_items WHERE id=?", edge))));
        replay(operation, false);
        assertEquals(0, new BigDecimal("2").compareTo(new BigDecimal(text("SELECT qty::text FROM goods_bom_items WHERE id=?", edge))));
        assertEquals(retained, text("SELECT after_row::text FROM goods_operation_history_rows WHERE operation_id=? AND table_name='goods_bom_items'", operation));
    }

    private UUID goods(String name) throws SQLException {
        UUID id = UUID.randomUUID();
        execute("INSERT INTO goods(id,code,name,code_sequence) VALUES(?,?,?,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))", id, "CLIENT-NAME-" + id, name);
        return id;
    }

    private UUID edit(UUID id, String sql) throws SQLException {
        provenance("/api/master/goods/" + id, "PUT"); execute(sql, id); db.commit(); return latest();
    }

    private UUID latest() throws SQLException {
        return UUID.fromString(text("SELECT id FROM goods_operation_history WHERE actor_id=? ORDER BY created_at DESC,id DESC LIMIT 1", actor));
    }

    private void stripHistoryKey(UUID operation, String table, String key) throws SQLException {
        execute("""
                UPDATE goods_operation_history_rows SET before_row=before_row-?,after_row=after_row-?,
                  expected_row=expected_row-?,before_token=before_token-?,after_token=after_token-?
                WHERE operation_id=? AND table_name=?
                """, key, key, key, key, key, operation, table);
    }

    private void replay(UUID operation, boolean undo) throws SQLException {
        long version = number("SELECT version FROM goods_operation_history WHERE id=?", operation);
        execute("SELECT fn_replay_goods_operation(?,?,?,?)", operation, actor, version, undo); db.commit();
    }

    private void provenance(String path, String method) throws SQLException {
        execute("SELECT set_config('app.actor_id',?,true),set_config('app.audit_request_id',?,true),set_config('app.audit_request_path',?,true),set_config('app.audit_request_method',?,true)",
                actor.toString(), UUID.randomUUID().toString(), path, method);
    }

    private void execute(String sql, Object... args) throws SQLException {
        try (var statement = db.prepareStatement(sql)) {
            for (int i = 0; i < args.length; i++) statement.setObject(i + 1, args[i]);
            statement.execute();
        }
    }

    private String text(String sql, Object... args) throws SQLException {
        try (var statement = db.prepareStatement(sql)) {
            for (int i = 0; i < args.length; i++) statement.setObject(i + 1, args[i]);
            try (var result = statement.executeQuery()) { return result.next() ? result.getString(1) : null; }
        }
    }

    private long number(String sql, Object... args) throws SQLException {
        try (var statement = db.prepareStatement(sql)) {
            for (int i = 0; i < args.length; i++) statement.setObject(i + 1, args[i]);
            try (var result = statement.executeQuery()) {
                assertTrue(result.next(), "Expected a numeric result row");
                long value = result.getLong(1);
                assertFalse(result.wasNull(), "Expected a non-null numeric result");
                return value;
            }
        }
    }
}
