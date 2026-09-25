package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestReporter;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.EnumSource;
import org.junit.jupiter.params.provider.MethodSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.io.IOException;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Savepoint;
import java.util.Arrays;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.*;

/** Executes the shipped SQL sections, not a Java or SQL reimplementation.
 * Unrelated business history guards remain covered by the full-chain suite. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@Timeout(value = 2, unit = TimeUnit.MINUTES)
class AggregateAllocationConstraintSchedulingPostgresTest {
    private static final PostgreSQLContainer<?> DATABASE = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final String ALLOCATION = "trg_check_preplan_supply_action_allocation";
    private static final String HEADER = "trg_check_preplan_supply_action_header_total";
    private static final String MARKER = "-- Aggregate allocation checks: statement-scoped scheduling";
    private Connection db;
    private String schema;
    private UUID analysis;

    enum Scope { ORDINARY, AGGREGATE, CONTINUATION }
    enum Mutation { INSERT, UPDATE, DELETE }
    record Action(UUID id, UUID allocation, UUID application, UUID externalItem, UUID anchor) { }
    record PendingContinuation(Action action, UUID task) { }

    @BeforeAll static void start() { DATABASE.start(); }
    @AfterAll static void stop() { DATABASE.stop(); }

    @BeforeEach void fixture() throws Exception {
        db = DriverManager.getConnection(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword());
        schema = "aggregate_schedule_" + UUID.randomUUID().toString().replace("-", "");
        sql("CREATE SCHEMA " + schema);
        sql("SET search_path TO " + schema + ",public");
        // Full catalog shapes avoid a second hand-written schema. This test
        // applies the actual V712 tail, so first restore its pre-signal shape.
        com.uten.imp.support.MigratedProjectionSchema.createCurrentTables(
                new org.springframework.jdbc.core.JdbcTemplate(new org.springframework.jdbc.datasource.SingleConnectionDataSource(db, true)),
                "production_material_analyses", "preplan_supply_actions", "preplan_supply_action_allocations",
                "preplan_aggregate_batches", "preplan_subcontract_make_tasks", "preplan_subcontract_make_task_batches");
        sql("ALTER TABLE preplan_supply_actions DROP COLUMN aggregate_allocation_check_revision");
        String original = resource("V234__production_material_analysis.sql");
        sql(original.substring(original.indexOf("CREATE OR REPLACE FUNCTION fn_check_preplan_supply_action_allocation()"),
                original.indexOf("-- Generic idempotency ledger")));
        String migration = resource("V712__material_aggregate_batches.sql");
        assertTrue(migration.contains(MARKER), "Run the real V712 scheduling section, never a test-side substitute");
        sql(migration.substring(migration.indexOf(MARKER)));
        analysis = UUID.randomUUID();
        sql("INSERT INTO production_material_analyses(id) VALUES(?)", analysis);
    }

    @AfterEach void close() throws Exception {
        if (db == null) return;
        if (!db.getAutoCommit()) { db.rollback(); db.setAutoCommit(true); }
        sql("DROP SCHEMA " + schema + " CASCADE");
        db.close();
    }

    @Test void originalAndCompanionHaveOneSharedNameAndIndependentHeaderMode() throws Exception {
        assertEquals(2, integer("""
                SELECT COUNT(*) FROM pg_constraint
                WHERE conname=? AND connamespace=CAST(? AS regnamespace)
                  AND condeferrable AND condeferred
                """, ALLOCATION, schema));
        assertEquals(1, integer("""
                SELECT COUNT(*) FROM pg_constraint
                WHERE conname=? AND connamespace=CAST(? AS regnamespace)
                  AND condeferrable AND condeferred
                """, HEADER, schema));
    }

    @ParameterizedTest @EnumSource(Scope.class)
    void headerOnlyImmediateAllowsAllocationThenHeaderRepair(Scope scope) throws Exception {
        Action action = seed(scope);
        db.setAutoCommit(false);
        sql("SET CONSTRAINTS " + HEADER + " IMMEDIATE");
        sql("UPDATE preplan_supply_action_allocations SET allocated_qty=11 WHERE id=?", action.allocation());
        sql("UPDATE preplan_supply_actions SET requested_qty=11 WHERE id=?", action.id());
        db.commit();
        balanced(action, "11");
    }

    @ParameterizedTest @EnumSource(Scope.class)
    void allocationOnlyImmediateAllowsHeaderThenAllocationRepair(Scope scope) throws Exception {
        Action action = seed(scope);
        db.setAutoCommit(false);
        sql("SET CONSTRAINTS " + ALLOCATION + " IMMEDIATE");
        sql("UPDATE preplan_supply_actions SET requested_qty=11 WHERE id=?", action.id());
        sql("UPDATE preplan_supply_action_allocations SET allocated_qty=11 WHERE id=?", action.allocation());
        db.commit();
        balanced(action, "11");
    }

    static Stream<Arguments> mutations() {
        return Arrays.stream(Scope.values()).flatMap(scope -> Arrays.stream(Mutation.values()).map(mutation -> Arguments.of(scope, mutation)));
    }

    @ParameterizedTest @MethodSource("mutations")
    void allImmediateRejectsEachMutationAndSavepointRestoresIt(Scope scope, Mutation mutation) throws Exception {
        Action seeded = seed(scope);
        boolean keepsProof = scope == Scope.CONTINUATION && mutation == Mutation.DELETE;
        // The notification FK protects its proof allocation first. Delete a
        // second, unreferenced slice to reach this quantity guard specifically.
        Action action = keepsProof ? withUnreferencedSlice(seeded) : seeded;
        db.setAutoCommit(false);
        sql("SET CONSTRAINTS ALL IMMEDIATE");
        Savepoint before = db.setSavepoint();
        SQLException failure = assertThrows(SQLException.class, () -> mutate(action, mutation));
        assertEquals("23514", failure.getSQLState());
        db.rollback(before);
        sql("UPDATE preplan_supply_action_allocations SET external_item_id=external_item_id WHERE id=?", action.allocation());
        db.commit();
        balanced(action, keepsProof ? "11" : "10");
    }

    @ParameterizedTest @EnumSource(Scope.class)
    void namedFlushAndLaterImmediateChangeBothRecheckActualRows(Scope scope) throws Exception {
        Action action = seed(scope);
        db.setAutoCommit(false);
        Savepoint before = db.setSavepoint();
        sql("UPDATE preplan_supply_action_allocations SET allocated_qty=11 WHERE id=?", action.allocation());
        assertMismatch(() -> sql("SET CONSTRAINTS " + ALLOCATION + " IMMEDIATE"));
        db.rollback(before);
        sql("UPDATE preplan_supply_action_allocations SET external_item_id=external_item_id WHERE id=?", action.allocation());
        sql("SET CONSTRAINTS " + ALLOCATION + " IMMEDIATE");
        Savepoint afterValidFlush = db.setSavepoint();
        assertMismatch(() -> sql("UPDATE preplan_supply_action_allocations SET allocated_qty=11 WHERE id=?", action.allocation()));
        db.rollback(afterValidFlush);
        db.commit();
        balanced(action, "10");
    }

    @ParameterizedTest @EnumSource(Scope.class)
    void deferredCommitCannotAcceptWrongTotal(Scope scope) throws Exception {
        Action action = seed(scope);
        db.setAutoCommit(false);
        sql("UPDATE preplan_supply_action_allocations SET allocated_qty=11 WHERE id=?", action.allocation());
        assertMismatch(db::commit);
        db.rollback();
        balanced(action, "10");
    }

    @Test void lateAggregateBindingEnqueuesTheNamedConstraintAndRollsBackTogether() throws Exception {
        Action action = seed(Scope.ORDINARY);
        db.setAutoCommit(false);
        Savepoint before = db.setSavepoint();
        sql("UPDATE preplan_supply_action_allocations SET allocated_qty=11 WHERE id=?", action.allocation());
        bind(action);
        assertScope(action, true);
        assertMismatch(() -> sql("SET CONSTRAINTS " + ALLOCATION + " IMMEDIATE"));
        db.rollback(before);
        db.commit();
        assertScope(action, false);
        balanced(action, "10");
        assertEquals(0, integer("SELECT aggregate_allocation_check_revision FROM preplan_supply_actions WHERE id=?", action.id()));
    }

    @Test void lateProvenNotificationBindingEnqueuesNamedConstraintAndSavepointRestoresProof() throws Exception {
        PendingContinuation pending = pendingContinuation();
        Action action = pending.action();
        assertScope(action, false);
        db.setAutoCommit(false);
        Savepoint before = db.setSavepoint();
        sql("UPDATE preplan_supply_action_allocations SET allocated_qty=11 WHERE id=?", action.allocation());
        notify(pending, action.externalItem(), action.allocation());
        assertScope(action, true);
        assertMismatch(() -> sql("SET CONSTRAINTS " + ALLOCATION + " IMMEDIATE"));
        db.rollback(before);
        db.commit();
        assertScope(action, false);
        balanced(action, "10");
        assertEquals(0, integer("SELECT COUNT(*) FROM preplan_subcontract_make_task_batches WHERE task_id=?", pending.task()));
        notify(pending, action.externalItem(), action.allocation());
        assertScope(action, true);
    }

    @Test void applicationNameWithoutExactAllocationProofRemainsOrdinaryAndGuarded() throws Exception {
        PendingContinuation pending = pendingContinuation();
        notify(pending, UUID.randomUUID(), pending.action().allocation());
        assertScope(pending.action(), false);
        db.setAutoCommit(false);
        sql("UPDATE preplan_supply_action_allocations SET allocated_qty=11 WHERE id=?", pending.action().allocation());
        assertMismatch(() -> sql("SET CONSTRAINTS " + ALLOCATION + " IMMEDIATE"));
        db.rollback();
        balanced(pending.action(), "10");
    }

    @Test void publicOnlyContinuationIsStillCheckedAgainstZeroPrivateAllocation() throws Exception {
        PendingContinuation pending = pendingContinuation();
        Action action = pending.action();
        db.setAutoCommit(false);
        sql("DELETE FROM preplan_supply_action_allocations WHERE id=?", action.allocation());
        sql("UPDATE preplan_supply_actions SET requested_qty=0,public_surplus_qty=10,public_surplus_external_item_id=? WHERE id=?", action.externalItem(), action.id());
        notify(pending, action.externalItem(), null);
        db.commit();
        assertScope(action, true);
        db.setAutoCommit(false);
        sql("SET CONSTRAINTS " + ALLOCATION + " IMMEDIATE");
        assertMismatch(() -> mutate(action, Mutation.INSERT));
        db.rollback();
        balanced(action, "0");
    }

    @Test void oneNotificationStatementSignalsEachProvenActionOnlyOnce() throws Exception {
        PendingContinuation pending = pendingContinuation();
        Action action = pending.action();
        UUID secondItem = UUID.randomUUID(), secondAllocation = UUID.randomUUID();
        db.setAutoCommit(false);
        sql("UPDATE preplan_supply_action_allocations SET allocated_qty=5 WHERE id=?", action.allocation());
        sql("INSERT INTO preplan_supply_action_allocations(id,analysis_id,action_id,analysis_material_id,allocated_qty,external_item_id) VALUES(?,?,?,?,5,?)",
                secondAllocation, analysis, action.id(), UUID.randomUUID(), secondItem);
        db.commit();
        int before = integer("SELECT aggregate_allocation_check_revision FROM preplan_supply_actions WHERE id=?", action.id());
        sql("""
                INSERT INTO preplan_subcontract_make_task_batches(task_id,application_id,application_item_id,allocation_id)
                VALUES(?,?,?,?),(?,?,?,?)
                """, pending.task(), action.application(), action.externalItem(), action.allocation(),
                pending.task(), action.application(), secondItem, secondAllocation);
        assertScope(action, true);
        assertEquals(before + 1, integer("SELECT aggregate_allocation_check_revision FROM preplan_supply_actions WHERE id=?", action.id()));
        balanced(action, "10");
    }

    @Test void oneBulkStatementChecksEachActionInsteadOfOnlyTheGrandTotal() throws Exception {
        Action first = seed(Scope.AGGREGATE), second = seed(Scope.AGGREGATE);
        db.setAutoCommit(false);
        sql("UPDATE preplan_supply_action_allocations SET allocated_qty=CASE WHEN action_id=? THEN 11 ELSE 9 END WHERE action_id IN(?,?)", first.id(), first.id(), second.id());
        assertMismatch(db::commit);
        db.rollback();
        balanced(first, "10"); balanced(second, "10");
        db.setAutoCommit(false);
        sql("SET CONSTRAINTS ALL IMMEDIATE");
        sql("""
                WITH changed AS (UPDATE preplan_supply_actions SET requested_qty=11 WHERE id IN(?,?) RETURNING id)
                UPDATE preplan_supply_action_allocations SET allocated_qty=11 WHERE action_id IN(SELECT id FROM changed)
                """, first.id(), second.id());
        db.commit();
        balanced(first, "11"); balanced(second, "11");
    }

    @Test void tenThousandAllocationsUseStatementSignalsAndReportActualCommitCost(TestReporter reporter) throws Exception {
        Action action = action();
        db.setAutoCommit(false);
        header(action, "10000"); bind(action);
        sql("""
                INSERT INTO preplan_supply_action_allocations(analysis_id,action_id,analysis_material_id,allocated_qty)
                SELECT CAST(? AS UUID),CAST(? AS UUID),md5('source-'||i::text)::uuid,1 FROM generate_series(1,10000) i
                """, analysis, action.id());
        sql("UPDATE preplan_supply_action_allocations SET external_item_id=? WHERE action_id=?", action.externalItem(), action.id());
        // Binding + bulk INSERT + bulk UPDATE, independent of the 10000 sources.
        assertEquals(3, integer("SELECT aggregate_allocation_check_revision FROM preplan_supply_actions WHERE id=?", action.id()));
        long started = System.nanoTime();
        db.commit();
        long elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started);
        reporter.publishEntry(Map.of("aggregateAllocationRows", "10000", "commitMillis", Long.toString(elapsed),
                "withinFiveSecondObservation", Boolean.toString(elapsed < 5000)));
        System.out.printf("Aggregate allocation scheduling: 10000 sources, commit=%d ms (5s observation, no flaky wall-clock gate)%n", elapsed);
        balanced(action, "10000");
        assertEquals(10000, integer("SELECT COUNT(*) FROM preplan_supply_action_allocations WHERE action_id=?", action.id()));
        assertEquals(10000, integer("SELECT COUNT(*) FROM preplan_supply_action_allocations WHERE action_id=? AND external_item_id=?", action.id(), action.externalItem()));
    }

    private Action seed(Scope scope) throws Exception {
        if (scope == Scope.CONTINUATION) {
            PendingContinuation pending = pendingContinuation();
            notify(pending, pending.action().externalItem(), pending.action().allocation());
            assertScope(pending.action(), true);
            return pending.action();
        }
        Action action = action();
        db.setAutoCommit(false);
        header(action, "10");
        if (scope == Scope.AGGREGATE) bind(action);
        allocation(action, "10");
        db.commit(); db.setAutoCommit(true);
        assertScope(action, scope == Scope.AGGREGATE);
        return action;
    }

    private PendingContinuation pendingContinuation() throws Exception {
        Action parent = seed(Scope.AGGREGATE);
        Action continuation = seed(Scope.ORDINARY);
        sql("UPDATE preplan_supply_actions SET external_document_type='SUBCONTRACT_APPLICATION',external_document_id=? WHERE id=?", continuation.application(), continuation.id());
        UUID task = UUID.randomUUID();
        sql("INSERT INTO preplan_subcontract_make_tasks(id,analysis_id,supply_action_id,preparation_item_id) VALUES(?,?,?,?)", task, analysis, parent.id(), parent.anchor());
        return new PendingContinuation(continuation, task);
    }

    private Action action() { return new Action(UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID()); }
    private Action withUnreferencedSlice(Action action) throws Exception {
        Action extra = new Action(action.id(), UUID.randomUUID(), action.application(), action.externalItem(), action.anchor());
        db.setAutoCommit(false);
        sql("UPDATE preplan_supply_actions SET requested_qty=11 WHERE id=?", action.id());
        allocation(extra, "1");
        db.commit(); db.setAutoCommit(true);
        return extra;
    }
    private void header(Action action, String qty) throws Exception {
        sql("INSERT INTO preplan_supply_actions(id,analysis_id,requested_qty) VALUES(?,?,?)", action.id(), analysis, new BigDecimal(qty));
    }
    private void allocation(Action action, String qty) throws Exception {
        sql("INSERT INTO preplan_supply_action_allocations(id,analysis_id,action_id,analysis_material_id,allocated_qty,external_item_id) VALUES(?,?,?,?,?,?)",
                action.allocation(), analysis, action.id(), UUID.randomUUID(), new BigDecimal(qty), action.externalItem());
    }
    private void bind(Action action) throws Exception {
        sql("INSERT INTO preplan_aggregate_batches(analysis_id,action_id,anchor_analysis_item_id,route) VALUES(?,?,?,'SUBCONTRACT')", analysis, action.id(), action.anchor());
    }
    private void notify(PendingContinuation pending, UUID item, UUID allocation) throws Exception {
        sql("INSERT INTO preplan_subcontract_make_task_batches(task_id,application_id,application_item_id,allocation_id) VALUES(?,?,?,?)",
                pending.task(), pending.action().application(), item, allocation);
    }
    private void mutate(Action action, Mutation mutation) throws Exception {
        switch (mutation) {
            case INSERT -> sql("INSERT INTO preplan_supply_action_allocations(analysis_id,action_id,analysis_material_id,allocated_qty) VALUES(?,?,?,1)", analysis, action.id(), UUID.randomUUID());
            case UPDATE -> sql("UPDATE preplan_supply_action_allocations SET allocated_qty=11 WHERE id=?", action.allocation());
            case DELETE -> sql("DELETE FROM preplan_supply_action_allocations WHERE id=?", action.allocation());
        }
    }
    private void balanced(Action action, String qty) throws Exception {
        try (var statement = db.prepareStatement("SELECT requested_qty,(SELECT COALESCE(SUM(allocated_qty),0) FROM preplan_supply_action_allocations WHERE action_id=?) FROM preplan_supply_actions WHERE id=?")) {
            statement.setObject(1, action.id()); statement.setObject(2, action.id());
            try (var rows = statement.executeQuery()) {
                assertTrue(rows.next());
                assertEquals(0, new BigDecimal(qty).compareTo(rows.getBigDecimal(1)));
                assertEquals(0, new BigDecimal(qty).compareTo(rows.getBigDecimal(2)));
            }
        }
    }
    private void assertScope(Action action, boolean expected) throws Exception {
        assertEquals(expected ? 1 : 0, integer("SELECT CASE WHEN fn_preplan_aggregate_allocation_scope(?) THEN 1 ELSE 0 END", action.id()));
    }
    @FunctionalInterface interface SqlWork { void run() throws Exception; }
    private void assertMismatch(SqlWork work) { assertEquals("23514", assertThrows(SQLException.class, work::run).getSQLState()); }
    private void sql(String sql, Object... values) throws Exception {
        try (var statement = db.prepareStatement(sql)) {
            for (int i = 0; i < values.length; i++) statement.setObject(i + 1, values[i]);
            statement.execute();
        }
    }
    private int integer(String sql, Object... values) throws Exception {
        try (var statement = db.prepareStatement(sql)) {
            for (int i = 0; i < values.length; i++) statement.setObject(i + 1, values[i]);
            try (var rows = statement.executeQuery()) { assertTrue(rows.next()); return rows.getInt(1); }
        }
    }
    private static String resource(String name) throws IOException {
        try (var stream = AggregateAllocationConstraintSchedulingPostgresTest.class.getResourceAsStream("/db/migration/" + name)) {
            if (stream == null) throw new IOException("Migration resource missing: " + name);
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }
    }
}
