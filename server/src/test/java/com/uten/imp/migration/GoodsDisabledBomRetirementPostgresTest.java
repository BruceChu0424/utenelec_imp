package com.uten.imp.migration;

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
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Full migrated PostgreSQL schema: disabled components retire recipes atomically without erasing evidence. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsDisabledBomRetirementPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private Connection db;
    private UUID unit;

    @BeforeAll
    static void schema() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("disabled_bom");
    }

    @AfterAll
    static void closeSchema() throws Exception {
        if (database != null) database.close();
    }

    @BeforeEach
    void transaction() throws Exception {
        db = database.openConnection();
        db.setAutoCommit(false);
        unit = unit(db);
    }

    @AfterEach
    void rollback() throws Exception {
        if (db != null) {
            db.rollback();
            db.close();
        }
    }

    @Test
    void disablesEveryDirectReferenceButKeepsOtherBranchesAndAncestorRecipes() throws Exception {
        UUID leaf = goods("leaf"), other = goods("other"), semi = goods("semi"), root = goods("root");
        UUID second = goods("second parent"), disabledParent = goods("disabled parent");
        UUID semiLeaf = edge(semi, leaf, 2), rootLeaf = edge(root, leaf, 3);
        UUID secondLeaf = edge(second, leaf, 4), disabledLeaf = edge(disabledParent, leaf, 5);
        UUID rootSemi = edge(root, semi, 1), rootOther = edge(root, other, 6);
        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", disabledParent);

        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", leaf);

        for (UUID retired : new UUID[]{semiLeaf, rootLeaf, secondLeaf, disabledLeaf}) assertRetired(retired);
        for (UUID retained : new UUID[]{rootSemi, rootOther}) assertActive(retained);
        assertEquals(4, number(db, "SELECT count(*) FROM goods_bom_items WHERE component_goods_id=?", leaf));
        assertEquals(0, number(db, "SELECT count(*) FROM goods_bom_items WHERE component_goods_id=? AND NOT is_deleted", leaf));
        assertEquals("禁用", text(db, "SELECT status FROM goods WHERE id=?", disabledParent));
    }

    @Test
    void disablingAnAssemblyRetiresItsIncomingEdgesAndKeepsItsOwnRecipe() throws Exception {
        UUID root = goods("root"), semi = goods("semi"), material = goods("material");
        UUID incoming = edge(root, semi, 2), outgoing = edge(semi, material, 3);

        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", semi);

        assertRetired(incoming);
        assertActive(outgoing);
        execute(db, "UPDATE goods SET status='使用' WHERE id=?", semi);
        assertRetired(incoming);
        assertActive(outgoing);
    }

    @Test
    void oneBulkStatementCanDisableParentsAndChildrenAndBumpAffectedParentsOnlyOnce() throws Exception {
        UUID root = goods("root"), semi = goods("semi"), leaf = goods("leaf");
        UUID rootSemi = edge(root, semi, 1), rootLeaf = edge(root, leaf, 2), semiLeaf = edge(semi, leaf, 3);
        long rootVersion = number(db, "SELECT version FROM goods WHERE id=?", root);
        long semiVersion = number(db, "SELECT version FROM goods WHERE id=?", semi);

        execute(db, "UPDATE goods SET status='禁用',version=version+1 WHERE id IN(?,?,?)", root, semi, leaf);

        for (UUID retired : new UUID[]{rootSemi, rootLeaf, semiLeaf}) assertRetired(retired);
        assertEquals(rootVersion + 2, number(db, "SELECT version FROM goods WHERE id=?", root));
        assertEquals(semiVersion + 2, number(db, "SELECT version FROM goods WHERE id=?", semi));
        assertEquals(1, retirementEvents(root));
        assertEquals(1, retirementEvents(semi));
    }

    @Test
    void nullLegacyStatusAlsoRetiresReferencesWhenItBecomesDisabled() throws Exception {
        UUID parent = goods("parent"), child = goods("legacy null status");
        execute(db, "UPDATE goods SET status=NULL WHERE id=?", child);
        UUID bom = edge(parent, child, 1);

        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", child);

        assertRetired(bom);
    }

    @Test
    void replacingTheLastDisabledMaterialResolvesRetirementAndLaterManualDeletionKeepsThatFact() throws Exception {
        UUID parent = goods("parent"), disabled = goods("last material"), replacement = goods("new material");
        UUID retired = edge(parent, disabled, 1);
        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", disabled);
        assertRetired(retired);
        assertUnresolved(retired);

        UUID newRecipe = edge(parent, replacement, 2);
        String resolved = resolution(retired);
        assertNotNull(resolved);
        execute(db, "UPDATE goods_bom_items SET is_deleted=true,deleted_at=clock_timestamp() WHERE id=?", newRecipe);

        assertEquals(resolved, resolution(retired));
        assertEquals("COMPONENT_DISABLED", text(db, "SELECT retirement_reason FROM goods_bom_items WHERE id=?", retired));
        assertEquals(0, number(db, "SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted", parent));
    }

    @Test
    void retiringOnlyPartOfAProductionRecipeIsImmediatelyResolvedByTheRemainingMaterials() throws Exception {
        UUID parent = goods("parent"), disabled = goods("removed material"), remaining = goods("remaining material");
        UUID retired = edge(parent, disabled, 1), kept = edge(parent, remaining, 2);

        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", disabled);

        assertRetired(retired);
        assertNotNull(resolution(retired));
        assertActive(kept);
        assertNull(text(db, "SELECT retirement_reason FROM goods_bom_items WHERE id=?", kept));
    }

    @Test
    void referenceShippingOptionalAndPeriodicEdgesDoNotResolveMissingProductionMaterials() throws Exception {
        UUID parent = goods("parent"), disabled = goods("removed material");
        UUID retired = edge(parent, disabled, 1);
        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", disabled);
        assertUnresolved(retired);

        UUID reference = goods("reference material"), shipping = goods("shipping material");
        UUID optional = goods("optional material"), periodic = UUID.randomUUID(), massUnit = UUID.randomUUID();
        execute(db, "INSERT INTO units(id,code,name,status) VALUES(?,?,'kg','使用')", massUnit, "DISABLED-BOM-KG-" + massUnit);
        execute(db, "INSERT INTO unit_measurement_profiles(unit_id,measurement_dimension,mass_unit_code,provenance) VALUES(?,'MASS','KG','MANUAL_GOVERNANCE')", massUnit);
        execute(db, """
                INSERT INTO goods(id,code,name,unit_id,status,source_type,price,source_e,version,code_sequence,issue_method,periodic_cost_basis)
                VALUES(?,?,'periodic material',?,'使用','采购',0,0,0,
                    (SELECT coalesce(max(code_sequence),0)+1 FROM goods),'PERIODIC','OWN')
                """, periodic, "DISABLED-BOM-" + periodic, massUnit);
        execute(db, "INSERT INTO goods_bom_items(goods_id,component_goods_id,qty,control_stage,hard_gate) VALUES(?,?,1,'REFERENCE',false)", parent, reference);
        assertUnresolved(retired);
        execute(db, "INSERT INTO goods_bom_items(goods_id,component_goods_id,qty,control_stage,hard_gate) VALUES(?,?,1,'SHIP',false)", parent, shipping);
        assertUnresolved(retired);
        execute(db, "INSERT INTO goods_bom_items(goods_id,component_goods_id,qty,control_stage,hard_gate) VALUES(?,?,1,'START',false)", parent, optional);
        assertUnresolved(retired);
        execute(db, "INSERT INTO goods_bom_items(goods_id,component_goods_id,qty,control_stage,hard_gate,consumption_basis,basis_output_qty) VALUES(?,?,1,'START',false,'PER_UNIT',1)", parent, periodic);
        assertUnresolved(retired);
        assertEquals("COMPONENT_DISABLED", text(db, "SELECT retirement_reason FROM goods_bom_items WHERE id=?", retired));
    }

    @Test
    void restoringAValidProductionEdgeResolvesAnOutstandingRetirement() throws Exception {
        UUID parent = goods("parent"), disabled = goods("removed material"), replacement = goods("restored material");
        UUID retired = edge(parent, disabled, 1), restored = UUID.randomUUID();
        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", disabled);
        execute(db, "INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty,is_deleted,deleted_at) VALUES(?,?,?,2,true,clock_timestamp())", restored, parent, replacement);
        assertUnresolved(retired);

        execute(db, "UPDATE goods_bom_items SET is_deleted=false,deleted_at=NULL WHERE id=?", restored);

        assertNotNull(resolution(retired));
        assertRetired(retired);
        assertActive(restored);
    }

    @Test
    void disablingARestoredComponentAgainStartsANewUnresolvedRetirementWhenItIsLast() throws Exception {
        UUID parent = goods("parent"), child = goods("repeat material"), other = goods("other material");
        UUID retired = edge(parent, child, 1), remaining = edge(parent, other, 1);
        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", child);
        assertNotNull(resolution(retired));
        execute(db, "UPDATE goods SET status='使用' WHERE id=?", child);
        execute(db, "UPDATE goods_bom_items SET is_deleted=false,deleted_at=NULL WHERE id=?", retired);
        execute(db, "UPDATE goods_bom_items SET is_deleted=true,deleted_at=clock_timestamp() WHERE id=?", remaining);

        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", child);

        assertRetired(retired);
        assertUnresolved(retired);
    }

    @Test
    void retirementRecalculatesCostInvalidatesVersionAndPublishesOneIdempotentEvent() throws Exception {
        UUID parent = goods("parent"), retired = goods("retired"), kept = goods("kept");
        execute(db, "UPDATE goods SET price=10 WHERE id=?", retired);
        execute(db, "UPDATE goods SET price=7 WHERE id=?", kept);
        edge(parent, retired, 2);
        edge(parent, kept, 3);
        execute(db, "UPDATE goods SET source_e=41 WHERE id=?", parent);
        long version = number(db, "SELECT version FROM goods WHERE id=?", parent);

        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", retired);

        assertEquals(0, decimal(db, "SELECT source_e FROM goods WHERE id=?", parent).compareTo(new BigDecimal("21")));
        assertEquals(version + 1, number(db, "SELECT version FROM goods WHERE id=?", parent));
        assertEquals(1, retirementEvents(parent));
        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", retired);
        execute(db, "SELECT fn_retire_disabled_goods_bom(?)", retired);
        assertEquals(version + 1, number(db, "SELECT version FROM goods WHERE id=?", parent));
        assertEquals(1, retirementEvents(parent));
    }

    @Test
    void rollbackRestoresStatusRecipesCostsVersionsAndOutboxTogether() throws Exception {
        UUID parent = goods("parent"), child = goods("child");
        execute(db, "UPDATE goods SET price=5 WHERE id=?", child);
        UUID bom = edge(parent, child, 2);
        execute(db, "UPDATE goods SET source_e=10 WHERE id=?", parent);
        long version = number(db, "SELECT version FROM goods WHERE id=?", parent);
        var savepoint = db.setSavepoint();

        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", child);
        assertRetired(bom);
        assertEquals(1, retirementEvents(parent));
        db.rollback(savepoint);

        assertEquals("使用", text(db, "SELECT status FROM goods WHERE id=?", child));
        assertActive(bom);
        assertNull(text(db, "SELECT deleted_at::text FROM goods_bom_items WHERE id=?", bom));
        assertNull(text(db, "SELECT learning_released_at::text FROM goods_bom_items WHERE id=?", bom));
        assertEquals(version, number(db, "SELECT version FROM goods WHERE id=?", parent));
        assertEquals(0, decimal(db, "SELECT source_e FROM goods WHERE id=?", parent).compareTo(BigDecimal.TEN));
        assertEquals(0, retirementEvents(parent));
    }

    @Test
    void databaseRejectsDisabledComponentInsertionRestorationAndRetargetingButAllowsHistoricalEdits() throws Exception {
        UUID parent = goods("parent"), disabled = goods("disabled"), enabled = goods("enabled");
        UUID retired = edge(parent, disabled, 1), active = edge(parent, enabled, 2);
        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", disabled);

        rejectsDisabled("INSERT INTO goods_bom_items(goods_id,component_goods_id,qty) VALUES(?,?,1)", parent, disabled);
        rejectsDisabled("UPDATE goods_bom_items SET is_deleted=false,deleted_at=NULL WHERE id=?", retired);
        rejectsDisabled("UPDATE goods_bom_items SET component_goods_id=? WHERE id=?", disabled, active);
        execute(db, "UPDATE goods_bom_items SET summary='retained original evidence',qty=9 WHERE id=?", retired);
        assertRetired(retired);
        assertEquals("retained original evidence", text(db, "SELECT summary FROM goods_bom_items WHERE id=?", retired));
        assertActive(active);
    }

    @Test
    void disabledParentCanKeepAndMaintainARecipeWithEnabledComponents() throws Exception {
        UUID parent = goods("disabled parent"), material = goods("material");
        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", parent);
        UUID bom = edge(parent, material, 2);
        execute(db, "UPDATE goods_bom_items SET qty=3 WHERE id=?", bom);
        assertActive(bom);
        assertEquals(0, decimal(db, "SELECT qty FROM goods_bom_items WHERE id=?", bom).compareTo(new BigDecimal("3")));
    }

    @Test
    void backfillRetiresLegacyDisabledReferencesEvenInLearningWriteModeAndIsRepeatable() throws Exception {
        UUID parent = goods("legacy parent"), child = goods("already disabled");
        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", child);
        UUID legacyEdge = UUID.randomUUID();
        // Recreate pre-V903 input only; normal writes below must use all real guards.
        execute(db, "SET LOCAL session_replication_role=replica");
        execute(db, "INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty) VALUES(?,?,?,2)", legacyEdge, parent, child);
        execute(db, "SET LOCAL session_replication_role=origin");
        execute(db, "SELECT set_config('app.bom_learning_write','on',true)");

        execute(db, "SELECT fn_retire_disabled_goods_bom(?)", child);
        assertRetired(legacyEdge);
        long version = number(db, "SELECT version FROM goods WHERE id=?", parent);
        execute(db, "SELECT fn_retire_disabled_goods_bom(?)", child);
        assertEquals(version, number(db, "SELECT version FROM goods WHERE id=?", parent));
        assertEquals(1, retirementEvents(parent));
    }

    @Test
    void learningSkipsDisabledCandidatesKeepsObservationsAndCannotRestoreRetiredComponentsAfterReenable() throws Exception {
        UUID parent = goods("parent"), disabled = goods("disabled candidate"), enabled = goods("enabled candidate");
        execute(db, "INSERT INTO goods_bom_learning_profiles(goods_id,output_unit_id,total_output_qty,sample_count) VALUES(?,?,10,1)", parent, unit);
        usage(parent, disabled);
        usage(parent, enabled);
        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", disabled);

        execute(db, "SELECT fn_publish_learned_bom(?,true)", parent);

        assertEquals(0, number(db, "SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted", parent, disabled));
        assertEquals(1, number(db, "SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted", parent, enabled));
        UUID learned = UUID.fromString(text(db, "SELECT id::text FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted", parent, enabled));
        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", enabled);
        assertRetired(learned);
        execute(db, "UPDATE goods SET status='使用' WHERE id=?", enabled);
        execute(db, "SELECT fn_publish_learned_bom(?,true)", parent);
        assertRetired(learned);
        assertEquals(0, number(db, "SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted", parent));
        assertEquals(2, number(db, "SELECT count(*) FROM goods_bom_actual_usages WHERE goods_id=? AND net_qty=20 AND exposure_output_qty=10 AND sample_count=1", parent));
    }

    @Test
    void aDisabledParentNeverPublishesALearnedRecipe() throws Exception {
        UUID parent = goods("disabled learned parent"), component = goods("enabled material");
        execute(db, "INSERT INTO goods_bom_learning_profiles(goods_id,output_unit_id,total_output_qty,sample_count) VALUES(?,?,10,1)", parent, unit);
        usage(parent, component);
        execute(db, "UPDATE goods SET status='禁用' WHERE id=?", parent);

        execute(db, "SELECT fn_publish_learned_bom(?,true)", parent);

        assertEquals(0, number(db, "SELECT count(*) FROM goods_bom_items WHERE goods_id=?", parent));
        assertEquals(1, number(db, "SELECT count(*) FROM goods_bom_actual_usages WHERE goods_id=? AND net_qty=20", parent));
    }

    @Test
    void statusHistoryCapturesOneCoherentOperationAndExplicitUndoRedoPreservesTokens() throws Exception {
        UUID parent = goods("parent"), child = goods("child"), actor = UUID.randomUUID(), request = UUID.randomUUID();
        execute(db, "UPDATE goods SET price=5 WHERE id=?", child);
        UUID bom = edge(parent, child, 2);
        execute(db, "UPDATE goods SET source_e=10 WHERE id=?", parent);
        execute(db, "SELECT set_config('app.actor_id',?,true),set_config('app.audit_request_id',?,true),set_config('app.audit_request_path',?,true),set_config('app.audit_request_method','PATCH',true)", actor.toString(), request.toString(), "/api/master/goods/" + child + "/status");
        execute(db, "SELECT fn_begin_goods_history_request()");

        execute(db, "UPDATE goods SET status='禁用',version=version+1 WHERE id=?", child);

        assertEquals(1, number(db, "SELECT count(*) FROM goods_operation_history WHERE actor_id=? AND request_id=? AND operation_type='GOODS_STATUS'", actor, request));
        UUID operation = UUID.fromString(text(db, "SELECT id::text FROM goods_operation_history WHERE actor_id=? AND request_id=?", actor, request));
        assertEquals(3, number(db, "SELECT count(*) FROM goods_operation_history_rows WHERE operation_id=?", operation));
        assertEquals(2, number(db, "SELECT count(*) FROM goods_operation_history_rows history JOIN goods current ON current.id=history.row_id WHERE history.operation_id=? AND history.table_name='goods' AND history.after_row=fn_goods_history_snapshot('goods'::regclass,current) AND history.expected_row=history.after_row", operation));
        assertEquals(1, number(db, "SELECT count(*) FROM goods_operation_history_rows history JOIN goods_bom_items current ON current.id=history.row_id WHERE history.operation_id=? AND history.table_name='goods_bom_items' AND current.id=? AND history.after_row=fn_goods_history_snapshot('goods_bom_items'::regclass,current) AND history.before_row->>'is_deleted'='false' AND history.after_row->>'is_deleted'='true'", operation, bom));

        execute(db, "SELECT fn_replay_goods_operation(?,?,0,true)", operation, actor);
        assertEquals("使用", text(db, "SELECT status FROM goods WHERE id=?", child));
        assertActive(bom);
        assertEquals(0, decimal(db, "SELECT source_e FROM goods WHERE id=?", parent).compareTo(BigDecimal.TEN));
        assertEquals("UNDONE", text(db, "SELECT state FROM goods_operation_history WHERE id=?", operation));

        execute(db, "SELECT fn_replay_goods_operation(?,?,1,false)", operation, actor);
        assertEquals("禁用", text(db, "SELECT status FROM goods WHERE id=?", child));
        assertRetired(bom);
        assertEquals(0, decimal(db, "SELECT source_e FROM goods WHERE id=?", parent).compareTo(BigDecimal.ZERO));
        assertEquals("APPLIED", text(db, "SELECT state FROM goods_operation_history WHERE id=?", operation));
        assertEquals(1, number(db, "SELECT count(*) FROM goods_operation_history WHERE actor_id=?", actor));
        assertEquals(2, number(db, "SELECT count(*) FROM goods_operation_history_rows history JOIN goods current ON current.id=history.row_id WHERE history.operation_id=? AND history.table_name='goods' AND history.expected_row=fn_goods_history_snapshot('goods'::regclass,current)", operation));
        assertEquals(1, number(db, "SELECT count(*) FROM goods_operation_history_rows history JOIN goods_bom_items current ON current.id=history.row_id WHERE history.operation_id=? AND history.table_name='goods_bom_items' AND history.expected_row=fn_goods_history_snapshot('goods_bom_items'::regclass,current)", operation));
    }

    @Test
    void preMigrationBomHistoryWithoutNewNullKeysCanUndoRedoWithoutRewritingOriginalSnapshots() throws Exception {
        UUID parent = goods("parent"), child = goods("child"), actor = UUID.randomUUID(), request = UUID.randomUUID();
        execute(db, "UPDATE goods SET price=5 WHERE id=?", child);
        UUID bom = edge(parent, child, 1);
        execute(db, "UPDATE goods SET source_e=5 WHERE id=?", parent);
        execute(db, "SELECT set_config('app.actor_id',?,true),set_config('app.audit_request_id',?,true),set_config('app.audit_request_path',?,true),set_config('app.audit_request_method','PUT',true)", actor.toString(), request.toString(), "/api/master/goods/" + parent + "/bom/" + bom);
        execute(db, "SELECT fn_begin_goods_history_request()");
        execute(db, "UPDATE goods_bom_items SET qty=2 WHERE id=?", bom);
        execute(db, "UPDATE goods SET source_e=10,version=version+1 WHERE id=?", parent);
        UUID operation = UUID.fromString(text(db, "SELECT id::text FROM goods_operation_history WHERE actor_id=? AND request_id=? AND operation_type='BOM_EDIT'", actor, request));
        // Model exact historical JSON written before V903 added the two nullable columns.
        execute(db, """
                UPDATE goods_operation_history_rows SET
                    before_row=before_row-'retirement_reason'-'retirement_resolved_at',
                    after_row=after_row-'retirement_reason'-'retirement_resolved_at',
                    expected_row=expected_row-'retirement_reason'-'retirement_resolved_at',
                    before_token=before_token-'retirement_reason'-'retirement_resolved_at',
                    after_token=after_token-'retirement_reason'-'retirement_resolved_at'
                WHERE operation_id=? AND table_name='goods_bom_items'
                """, operation);
        String originals = text(db, "SELECT jsonb_build_array(before_row,after_row)::text FROM goods_operation_history_rows WHERE operation_id=? AND table_name='goods_bom_items'", operation);

        execute(db, "SELECT fn_replay_goods_operation(?,?,0,true)", operation, actor);
        assertEquals(0, decimal(db, "SELECT qty FROM goods_bom_items WHERE id=?", bom).compareTo(BigDecimal.ONE));
        assertEquals(0, decimal(db, "SELECT source_e FROM goods WHERE id=?", parent).compareTo(new BigDecimal("5")));
        assertEquals(originals, text(db, "SELECT jsonb_build_array(before_row,after_row)::text FROM goods_operation_history_rows WHERE operation_id=? AND table_name='goods_bom_items'", operation));

        execute(db, "SELECT fn_replay_goods_operation(?,?,1,false)", operation, actor);
        assertEquals(0, decimal(db, "SELECT qty FROM goods_bom_items WHERE id=?", bom).compareTo(new BigDecimal("2")));
        assertEquals(0, decimal(db, "SELECT source_e FROM goods WHERE id=?", parent).compareTo(BigDecimal.TEN));
        assertEquals(originals, text(db, "SELECT jsonb_build_array(before_row,after_row)::text FROM goods_operation_history_rows WHERE operation_id=? AND table_name='goods_bom_items'", operation));
        assertEquals(1, number(db, "SELECT count(*) FROM goods_operation_history_rows WHERE operation_id=? AND table_name='goods_bom_items' AND NOT jsonb_exists(before_row,'retirement_reason') AND NOT jsonb_exists(before_row,'retirement_resolved_at') AND NOT jsonb_exists(after_row,'retirement_reason') AND NOT jsonb_exists(after_row,'retirement_resolved_at')", operation));
    }

    @Test
    void insertCannotSurviveAConcurrentDisableWhichAlreadyHoldsTheStatusFence() throws Exception {
        try (var isolated = MigratedSchemaBaseline.openDatabase("disabled_bom_insert_race");
             var writer = isolated.openConnection();
             var executor = Executors.newSingleThreadExecutor()) {
            UUID raceUnit = unit(writer), parent = goods(writer, raceUnit, "parent"), child = goods(writer, raceUnit, "child");
            writer.setAutoCommit(false);
            execute(writer, "UPDATE goods SET status='禁用' WHERE id=?", child);
            var started = new CountDownLatch(1);
            Future<String> attempt = executor.submit(() -> {
                try (var contender = isolated.openConnection()) {
                    contender.setAutoCommit(false);
                    execute(contender, "SET LOCAL lock_timeout='5s'");
                    started.countDown();
                    return transactionResult(contender, "INSERT INTO goods_bom_items(goods_id,component_goods_id,qty) VALUES(?,?,1)", parent, child);
                }
            });
            assertTrue(started.await(10, TimeUnit.SECONDS));
            String immediate = resultBeforeCommit(attempt);
            writer.commit();
            String result = immediate == null ? attempt.get(10, TimeUnit.SECONDS) : immediate;
            assertTrue(result.equals("23514") || result.equals("55P03"), result);
            assertEquals(0, number(writer, "SELECT count(*) FROM goods_bom_items edge JOIN goods component ON component.id=edge.component_goods_id WHERE NOT edge.is_deleted AND component.status='禁用'"));
        }
    }

    @Test
    void concurrentDisableEitherRetriesOrWaitsForAnEarlierBomWriteThenRetiresIt() throws Exception {
        try (var isolated = MigratedSchemaBaseline.openDatabase("disabled_bom_status_race");
             var writer = isolated.openConnection();
             var executor = Executors.newSingleThreadExecutor()) {
            UUID raceUnit = unit(writer), parent = goods(writer, raceUnit, "parent"), child = goods(writer, raceUnit, "child");
            writer.setAutoCommit(false);
            execute(writer, "INSERT INTO goods_bom_items(goods_id,component_goods_id,qty) VALUES(?,?,1)", parent, child);
            var started = new CountDownLatch(1);
            Future<String> attempt = executor.submit(() -> {
                try (var contender = isolated.openConnection()) {
                    contender.setAutoCommit(false);
                    execute(contender, "SET LOCAL lock_timeout='5s'");
                    started.countDown();
                    return transactionResult(contender, "UPDATE goods SET status='禁用' WHERE id=?", child);
                }
            });
            assertTrue(started.await(10, TimeUnit.SECONDS));
            String immediate = resultBeforeCommit(attempt);
            writer.commit();
            String result = immediate == null ? attempt.get(10, TimeUnit.SECONDS) : immediate;
            assertTrue(result.equals("COMMITTED") || result.equals("55P03"), result);
            if (result.equals("55P03")) {
                execute(writer, "UPDATE goods SET status='禁用' WHERE id=?", child);
                writer.commit();
            }
            assertEquals("禁用", text(writer, "SELECT status FROM goods WHERE id=?", child));
            assertEquals(0, number(writer, "SELECT count(*) FROM goods_bom_items WHERE component_goods_id=? AND NOT is_deleted", child));
            assertEquals(1, number(writer, "SELECT count(*) FROM goods_bom_items WHERE component_goods_id=? AND is_deleted AND deleted_at IS NOT NULL AND learning_released_at IS NOT NULL", child));
        }
    }

    private void usage(UUID parent, UUID component) throws SQLException {
        execute(db, "INSERT INTO goods_bom_actual_usages(goods_id,component_goods_id,unit_id,output_unit_id,net_qty,exposure_output_qty,sample_count) VALUES(?,?,?,?,20,10,1)", parent, component, unit, unit);
    }

    private void rejectsDisabled(String sql, Object... args) throws SQLException {
        var point = db.setSavepoint();
        SQLException rejected = assertThrows(SQLException.class, () -> execute(db, sql, args));
        assertEquals("23514", rejected.getSQLState());
        db.rollback(point);
    }

    private void assertRetired(UUID edge) throws SQLException {
        assertEquals("true", text(db, "SELECT is_deleted::text FROM goods_bom_items WHERE id=?", edge));
        assertNotNull(text(db, "SELECT deleted_at::text FROM goods_bom_items WHERE id=?", edge));
        assertNotNull(text(db, "SELECT learning_released_at::text FROM goods_bom_items WHERE id=?", edge));
        assertEquals("COMPONENT_DISABLED", text(db, "SELECT retirement_reason FROM goods_bom_items WHERE id=?", edge));
    }

    private void assertUnresolved(UUID edge) throws SQLException {
        assertNull(resolution(edge));
    }

    private String resolution(UUID edge) throws SQLException {
        return text(db, "SELECT retirement_resolved_at::text FROM goods_bom_items WHERE id=?", edge);
    }

    private void assertActive(UUID edge) throws SQLException {
        assertEquals("false", text(db, "SELECT is_deleted::text FROM goods_bom_items WHERE id=?", edge));
    }

    private long retirementEvents(UUID parent) throws SQLException {
        return number(db, "SELECT count(*) FROM business_outbox WHERE event_type='GOODS_BOM_UPDATED' AND aggregate_type='GOODS_BOM' AND aggregate_id=? AND payload->>'reason'='COMPONENT_DISABLED'", parent);
    }

    private UUID goods(String name) throws SQLException {
        return goods(db, unit, name);
    }

    private static UUID goods(Connection connection, UUID unit, String name) throws SQLException {
        UUID id = UUID.randomUUID();
        execute(connection, "INSERT INTO goods(id,code,name,unit_id,status,source_type,price,source_e,version,code_sequence) VALUES(?,?,?,?,'使用','采购',0,0,0,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))", id, "DISABLED-BOM-" + id, name, unit);
        return id;
    }

    private UUID edge(UUID parent, UUID component, int quantity) throws SQLException {
        UUID id = UUID.randomUUID();
        execute(db, "INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty) VALUES(?,?,?,?)", id, parent, component, quantity);
        return id;
    }

    private static UUID unit(Connection connection) throws SQLException {
        UUID id = UUID.randomUUID();
        execute(connection, "INSERT INTO units(id,code,name,status) VALUES(?,?,'件','使用')", id, "DISABLED-BOM-U-" + id);
        return id;
    }

    private static String resultBeforeCommit(Future<String> attempt) throws Exception {
        try {
            return attempt.get(300, TimeUnit.MILLISECONDS);
        } catch (TimeoutException stillBlockedOnTheFence) {
            return null;
        }
    }

    private static String transactionResult(Connection connection, String sql, Object... args) throws SQLException {
        try {
            execute(connection, sql, args);
            connection.commit();
            return "COMMITTED";
        } catch (SQLException failure) {
            connection.rollback();
            return failure.getSQLState();
        }
    }

    private static void execute(Connection connection, String sql, Object... args) throws SQLException {
        try (var statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < args.length; index++) statement.setObject(index + 1, args[index]);
            statement.execute();
        }
    }

    private static long number(Connection connection, String sql, Object... args) throws SQLException {
        try (var statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < args.length; index++) statement.setObject(index + 1, args[index]);
            try (var result = statement.executeQuery()) {
                assertTrue(result.next());
                return result.getLong(1);
            }
        }
    }

    private static String text(Connection connection, String sql, Object... args) throws SQLException {
        try (var statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < args.length; index++) statement.setObject(index + 1, args[index]);
            try (var result = statement.executeQuery()) {
                assertTrue(result.next());
                return result.getString(1);
            }
        }
    }

    private static BigDecimal decimal(Connection connection, String sql, Object... args) throws SQLException {
        try (var statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < args.length; index++) statement.setObject(index + 1, args[index]);
            try (var result = statement.executeQuery()) {
                assertTrue(result.next());
                return result.getBigDecimal(1);
            }
        }
    }
}
