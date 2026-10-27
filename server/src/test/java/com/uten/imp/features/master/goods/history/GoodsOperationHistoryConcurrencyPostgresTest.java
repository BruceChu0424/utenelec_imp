package com.uten.imp.features.master.goods.history;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.features.master.lifecycle.MasterReferenceGuard;
import com.uten.imp.features.master.reference.MasterReferenceValidationAdapter;
import com.uten.imp.features.master.warehouse.WarehouseMasterRules;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;

import java.sql.Connection;
import java.sql.SQLException;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real independent connections, observed blockers and bounded waits; no timing sleeps. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@Timeout(30)
class GoodsOperationHistoryConcurrencyPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static EntityManagerFactory factory;
    private record Outcome(boolean success, String state, String message, int affected) {}
    private record Operation(UUID actor, UUID id, UUID goods) {}

    @BeforeAll @Timeout(180) static void migrate() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("goods_history_concurrency");
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword()));
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.security");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto", "none", "hibernate.connection.handling_mode", "DELAYED_ACQUISITION_AND_HOLD"));
        bean.afterPropertiesSet(); factory = bean.getObject();
    }
    @AfterAll static void cleanup() throws Exception {
        if (factory != null) factory.close();
        if (database != null) database.close();
    }

    @Test void maintenanceRelationLockReturnsBusyWithoutMutationAndTheSameUndoWorksAfterRelease() throws Exception {
        Operation op=edited("maintenance relation lock");
        var permissions=new AtomicReference<>(Set.of("goods:view","goods:edit"));
        try(Connection maintenance=connection();Connection observer=connection();
            ServiceSession session=serviceSession(op.actor(),permissions,null)) {
            execute(maintenance,"LOCK TABLE goods IN SHARE UPDATE EXCLUSIVE MODE");
            long started=System.nanoTime();
            ApiException busy=assertInstanceOf(ApiException.class,session.undo(op.id()));
            assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT,busy.getCode());
            assertTrue(busy.getMessage().contains("正在由其他操作更新"));
            assertTrue(Duration.ofNanos(System.nanoTime()-started).compareTo(Duration.ofSeconds(2))<0,
                    "NOWAIT must not wait for a maintenance relation lock");
            assertEquals("maintenance relation lock changed",scalar(observer,"SELECT name FROM goods WHERE id=?",op.goods()));
            assertEquals(0,count(observer,"SELECT count(*) FROM goods_operation_history_events WHERE operation_id=?",op.id()));
            maintenance.rollback();
            assertNull(session.undo(op.id()));
            assertEquals("maintenance relation lock",scalar(observer,"SELECT name FROM goods WHERE id=?",op.goods()));
            assertEquals(1,count(observer,"SELECT count(*) FROM goods_operation_history_events WHERE operation_id=?",op.id()));
        }
    }

    @Test void twoRequestsForTheSameActorsSameUndoHaveExactlyOneCommit() throws Exception {
        Operation op = edited("double undo");
        try (Connection first = connection(); Connection second = connection(); Connection observer = connection();
             ExecutorService worker = Executors.newVirtualThreadPerTaskExecutor()) {
            prepare(first, op.actor(), historyPath(op.id(), true), "POST", true);
            replay(first, op.id(), op.actor(), 0, true);
            int holder = pid(first), waiter = pid(second);
            CountDownLatch started = new CountDownLatch(1);
            Future<Outcome> competing = submit(worker, second, started, () -> {
                prepare(second, op.actor(), historyPath(op.id(), true), "POST", true);
                replay(second, op.id(), op.actor(), 0, true); return 1;
            });
            assertTrue(started.await(2, TimeUnit.SECONDS));
            awaitBlocked(observer, waiter, holder);
            first.commit();
            assertRejected(competing.get(8, TimeUnit.SECONDS), "P0001");
            assertEquals("double undo", scalar(observer, "SELECT name FROM goods WHERE id=?", op.goods()));
            assertEquals(1, count(observer, "SELECT count(*) FROM goods_operation_history_events WHERE operation_id=?", op.id()));
            assertEquals(1, count(observer, "SELECT version FROM goods_operation_history WHERE id=?", op.id()));
        }
    }

    @Test void aForwardCommitFromEitherAccountMakesAnOlderUndoStaleWithoutOverwritingIt() throws Exception {
        for (boolean sameActor : List.of(false, true)) {
            Operation op = edited("writer first " + sameActor);
            UUID writerActor = sameActor ? op.actor() : UUID.randomUUID();
            try (Connection writer = connection(); Connection undo = connection(); Connection observer = connection();
                 ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor()) {
                prepare(writer, writerActor, goodsPath(op.goods()), "PUT", true);
                execute(writer, "UPDATE goods SET name='newer committed edit',version=version+1 WHERE id=?", op.goods());
                int writerPid = pid(writer), undoPid = pid(undo);
                CountDownLatch started = new CountDownLatch(1);
                Future<Outcome> attempt = submit(executor, undo, started, () -> {
                    prepare(undo, op.actor(), historyPath(op.id(), true), "POST", true);
                    replay(undo, op.id(), op.actor(), 0, true); return 1;
                });
                assertTrue(started.await(2, TimeUnit.SECONDS));
                if (sameActor) {
                    awaitBlocked(observer, undoPid, writerPid);
                    writer.commit();
                    assertRejected(attempt.get(8, TimeUnit.SECONDS), "P0001");
                } else {
                    assertRejected(attempt.get(8, TimeUnit.SECONDS), "55P03");
                    writer.commit();
                    assertThrows(SQLException.class, () -> replay(undo, op.id(), op.actor(), 0, true));
                    undo.rollback();
                }
                assertEquals("newer committed edit", scalar(observer, "SELECT name FROM goods WHERE id=?", op.goods()));
                assertEquals(0, count(observer, "SELECT count(*) FROM goods_operation_history_events WHERE operation_id=?", op.id()));
            }
        }
    }

    @Test void anEditorLoadedBeforeUndoCannotSaveItsOldVersionAfterUndoCommits() throws Exception {
        Operation op = edited("undo first");
        try (Connection undo = connection(); Connection editor = connection(); Connection observer = connection();
             ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor()) {
            int loadedVersion = count(editor, "SELECT version FROM goods WHERE id=?", op.goods());
            editor.commit();
            prepare(undo, op.actor(), historyPath(op.id(), true), "POST", true);
            replay(undo, op.id(), op.actor(), 0, true);
            int editorPid = pid(editor), undoPid = pid(undo);
            CountDownLatch started = new CountDownLatch(1);
            Future<Outcome> save = submit(executor, editor, started, () -> {
                prepare(editor, UUID.randomUUID(), goodsPath(op.goods()), "PUT", true);
                return execute(editor, "UPDATE goods SET name='stale editor',version=version+1 WHERE id=? AND version=?", op.goods(), loadedVersion);
            });
            assertTrue(started.await(2, TimeUnit.SECONDS));
            awaitBlocked(observer, editorPid, undoPid);
            undo.commit();
            Outcome result = save.get(8, TimeUnit.SECONDS);
            assertTrue(result.success()); assertEquals(0, result.affected());
            assertEquals("undo first", scalar(observer, "SELECT name FROM goods WHERE id=?", op.goods()));
        }
    }

    @Test void aNewActionCommittingBeforeARedoClearsOnlyThatActorsRedoBranch() throws Exception {
        Operation op = edited("redo branch"); UUID otherGoods = goods("new action");
        try (Connection initial = connection()) { replay(initial, op.id(), op.actor(), 0, true); initial.commit(); }
        try (Connection forward = connection(); Connection redo = connection(); Connection observer = connection();
             ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor()) {
            prepare(forward, op.actor(), goodsPath(otherGoods), "PUT", true);
            execute(forward, "UPDATE goods SET name='new action committed',version=version+1 WHERE id=?", otherGoods);
            int redoPid = pid(redo), forwardPid = pid(forward);
            CountDownLatch started = new CountDownLatch(1);
            Future<Outcome> attempt = submit(executor, redo, started, () -> {
                prepare(redo, op.actor(), historyPath(op.id(), false), "POST", true);
                replay(redo, op.id(), op.actor(), 1, false); return 1;
            });
            assertTrue(started.await(2, TimeUnit.SECONDS));
            awaitBlocked(observer, redoPid, forwardPid);
            forward.commit();
            assertRejected(attempt.get(8, TimeUnit.SECONDS), "P0001");
            assertEquals("false", scalar(observer, "SELECT redo_allowed::text FROM goods_operation_history WHERE id=?", op.id()));
            assertEquals("redo branch", scalar(observer, "SELECT name FROM goods WHERE id=?", op.goods()));
        }
    }

    @Test void crossAccountLineageRebasesOnlyAnExactlyRestoredAncestorAndNeverAnActiveForeignEdit() throws Exception {
        Operation first = edited("shared goods"); UUID other = UUID.randomUUID(), second;
        try (Connection db = connection()) {
            prepare(db, other, goodsPath(first.goods()), "PUT", true);
            execute(db, "UPDATE goods SET price=60,version=version+1 WHERE id=?", first.goods());
            second = latest(db, other); db.commit();
            assertThrows(SQLException.class, () -> replay(db, first.id(), first.actor(), 0, true)); db.rollback();
            assertThrows(SQLException.class, () -> replay(db, second, first.actor(), 0, true)); db.rollback();
        }
        try (Connection b = connection(); Connection a = connection(); Connection observer = connection()) {
            replay(b, second, other, 0, true); b.commit();
            replay(a, first.id(), first.actor(), 0, true); a.commit();
            assertEquals("shared goods", scalar(observer, "SELECT name FROM goods WHERE id=?", first.goods()));
            assertThrows(SQLException.class, () -> replay(b, second, other, 1, false)); b.rollback();
            replay(a, first.id(), first.actor(), 1, false); a.commit();
            replay(b, second, other, 1, false); b.commit();
            assertEquals("shared goods changed", scalar(observer, "SELECT name FROM goods WHERE id=?", first.goods()));
            assertEquals(0, new java.math.BigDecimal("60").compareTo(new java.math.BigDecimal(scalar(observer, "SELECT price FROM goods WHERE id=?", first.goods()))));
            assertEquals(2, count(observer, "SELECT count(*) FROM goods_operation_history_events WHERE actor_id=?", first.actor()));
            assertEquals(2, count(observer, "SELECT count(*) FROM goods_operation_history_events WHERE actor_id=?", other));
        }
    }

    @Test void anotherAccountsIndependentActionPreservesRedoButItsConflictingActionBlocksItTemporarily() throws Exception {
        Operation op = edited("personal redo"); UUID other = UUID.randomUUID(), independent = goods("independent other goods");
        try (Connection db = connection()) { replay(db, op.id(), op.actor(), 0, true); db.commit(); }
        try (Connection writer = connection(); Connection redo = connection(); Connection observer = connection();
             ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor()) {
            prepare(writer, other, goodsPath(independent), "PUT", true);
            execute(writer, "UPDATE goods SET name='other account independent change',version=version+1 WHERE id=?", independent);
            CountDownLatch started = new CountDownLatch(1);
            Future<Outcome> attempt = submit(executor, redo, started, () -> {
                prepare(redo, op.actor(), historyPath(op.id(), false), "POST", true);
                replay(redo, op.id(), op.actor(), 1, false); return 1;
            });
            assertTrue(started.await(2, TimeUnit.SECONDS)); assertRejected(attempt.get(4, TimeUnit.SECONDS), "55P03");
            writer.commit();
            assertEquals("true", scalar(observer, "SELECT redo_allowed::text FROM goods_operation_history WHERE id=?", op.id()));
            replay(redo, op.id(), op.actor(), 1, false); redo.commit();
            assertEquals("personal redo changed", scalar(observer, "SELECT name FROM goods WHERE id=?", op.goods()));
            replay(redo, op.id(), op.actor(), 2, true); redo.commit();
            prepare(writer, other, goodsPath(op.goods()), "PUT", true);
            execute(writer, "UPDATE goods SET name='other account conflicting change',version=version+1 WHERE id=?", op.goods());
            UUID foreignEdit = latest(writer, other); writer.commit();
            assertThrows(SQLException.class, () -> replay(redo, op.id(), op.actor(), 3, false)); redo.rollback();
            assertEquals("true", scalar(observer, "SELECT redo_allowed::text FROM goods_operation_history WHERE id=?", op.id()));
            replay(writer, foreignEdit, other, 0, true); writer.commit();
            replay(redo, op.id(), op.actor(), 3, false); redo.commit();
            assertEquals("personal redo changed", scalar(observer, "SELECT name FROM goods WHERE id=?", op.goods()));
        }
    }

    @Test void requestPreparationSerializesAnActorBeforeEitherRequestCanHoldTheOthersGoodsRow() throws Exception {
        UUID actor = UUID.randomUUID(), category = category(), id = goods("category reconcile");
        try (Connection categoryWriter = connection(); Connection goodsWriter = connection(); Connection observer = connection();
             ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor()) {
            prepare(categoryWriter, actor, "/api/master/material-categories/" + category, "PUT", true);
            execute(categoryWriter, "UPDATE material_categories SET name='category changed',version=version+1 WHERE id=?", category);
            int goodsPid = pid(goodsWriter), categoryPid = pid(categoryWriter);
            CountDownLatch started = new CountDownLatch(1);
            Future<Outcome> second = submit(executor, goodsWriter, started, () -> {
                prepare(goodsWriter, actor, goodsPath(id), "PUT", true);
                return execute(goodsWriter, "UPDATE goods SET name='second request',version=version+1 WHERE id=?", id);
            });
            assertTrue(started.await(2, TimeUnit.SECONDS));
            awaitBlocked(observer, goodsPid, categoryPid);
            // This is the category command's later numbering/goods phase. The
            // second request has no goods row lock yet, so there is no cycle.
            execute(categoryWriter, "UPDATE goods SET name='category reconcile phase',version=version+1 WHERE id=?", id);
            categoryWriter.commit();
            assertTrue(second.get(8, TimeUnit.SECONDS).success());
            assertEquals("second request", scalar(observer, "SELECT name FROM goods WHERE id=?", id));
            assertEquals("GOODS_EDIT", scalar(observer, "SELECT operation_type FROM goods_operation_history WHERE actor_id=? ORDER BY created_at DESC LIMIT 1", actor));
        }
    }

    @Test void anOlderPhysicalTransactionThatWritesLaterIsListedAfterTheAlreadyCommittedShortRequest() throws Exception {
        UUID actor = UUID.randomUUID(), longGoods = goods("long transaction"), shortGoods = goods("short transaction");
        try (Connection older = connection(); Connection shortRequest = connection(); Connection observer = connection()) {
            // Force an older transaction timestamp before the short request
            // reaches request preparation. Capture must use actual write order,
            // rather than current_timestamp/txid ordering.
            scalar(older, "SELECT txid_current()::text");
            prepare(shortRequest, actor, goodsPath(shortGoods), "PUT", true);
            execute(shortRequest, "UPDATE goods SET name='short committed',version=version+1 WHERE id=?", shortGoods);
            UUID shortOperation = latest(shortRequest, actor); shortRequest.commit();
            prepare(older, actor, goodsPath(longGoods), "PUT", true);
            execute(older, "UPDATE goods SET name='older transaction committed last',version=version+1 WHERE id=?", longGoods);
            UUID lastOperation = latest(older, actor); older.commit();
            assertEquals(lastOperation, latest(observer, actor));
            assertEquals("true", scalar(observer, "SELECT (a.created_at>b.created_at)::text FROM goods_operation_history a,goods_operation_history b WHERE a.id=? AND b.id=?", lastOperation, shortOperation));
            assertEquals("true", scalar(observer, "SELECT (a.updated_at<b.updated_at)::text FROM goods a,goods b WHERE a.id=? AND b.id=?", longGoods, shortGoods));
        }
    }

    @Test void aLegacyCallerHoldingARowNeverWaitsForTheActorLockAndCannotCreateALockCycle() throws Exception {
        UUID actor = UUID.randomUUID(), category = category(), id = goods("legacy row holder");
        try (Connection owner = connection(); Connection legacy = connection(); Connection observer = connection();
             ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor()) {
            prepare(owner, actor, "/api/master/material-categories/" + category, "PUT", true);
            execute(owner, "UPDATE material_categories SET name='first phase',version=version+1 WHERE id=?", category);
            int ownerPid = pid(owner), legacyPid = pid(legacy);
            CountDownLatch rowHeld = new CountDownLatch(1), mayCapture = new CountDownLatch(1), started = new CountDownLatch(1);
            Future<Outcome> second = submit(executor, legacy, started, () -> {
                prepare(legacy, actor, goodsPath(id), "PUT", false);
                scalar(legacy, "SELECT id::text FROM goods WHERE id=? FOR UPDATE", id);
                rowHeld.countDown();
                assertTrue(mayCapture.await(6, TimeUnit.SECONDS));
                return execute(legacy, "UPDATE goods SET name='must roll back',version=version+1 WHERE id=?", id);
            });
            assertTrue(started.await(2, TimeUnit.SECONDS)); assertTrue(rowHeld.await(2, TimeUnit.SECONDS));
            CountDownLatch reconcileStarted = new CountDownLatch(1);
            Future<Outcome> reconcile = submit(executor, owner, reconcileStarted,
                    () -> execute(owner, "UPDATE goods SET name='first request completes',version=version+1 WHERE id=?", id));
            assertTrue(reconcileStarted.await(2, TimeUnit.SECONDS));
            awaitBlocked(observer, ownerPid, legacyPid);
            mayCapture.countDown();
            assertRejected(second.get(4, TimeUnit.SECONDS), "55P03");
            assertTrue(reconcile.get(8, TimeUnit.SECONDS).success());
            assertEquals("first request completes", scalar(observer, "SELECT name FROM goods WHERE id=?", id));
        }
    }

    @Test void replayNeverWaitsHoldingColorsWhileAnImportHoldsCategoriesAndNeedsColorsNext() throws Exception {
        Operation op = edited("replay import inversion"); UUID category = UUID.randomUUID(), color = UUID.randomUUID();
        try (Connection importing = connection(); Connection undo = connection(); Connection observer = connection();
             ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor()) {
            prepare(importing, UUID.randomUUID(), "/api/master/goods/import/commit", "POST", true);
            execute(importing, "INSERT INTO material_categories(id,code,name) VALUES(?,?,'import category')", category, "IMPORT-" + category);
            int undoPid = pid(undo), importPid = pid(importing);
            CountDownLatch started = new CountDownLatch(1);
            Future<Outcome> attempt = submit(executor, undo, started, () -> {
                prepare(undo, op.actor(), historyPath(op.id(), true), "POST", true);
                replay(undo, op.id(), op.actor(), 0, true); return 1;
            });
            assertTrue(started.await(2, TimeUnit.SECONDS));
            awaitDoneOrBlocked(observer, attempt, undoPid, importPid);
            // If replay had retained a partial colors lock while waiting for
            // categories, this second import phase would deadlock.
            execute(importing, "INSERT INTO colors(id,code,name) VALUES(?,?,'import color')", color, "COLOR-" + color);
            importing.commit();
            assertRejected(attempt.get(4, TimeUnit.SECONDS), "55P03");
            prepare(undo, op.actor(), historyPath(op.id(), true), "POST", true);
            replay(undo, op.id(), op.actor(), 0, true); undo.commit();
            assertEquals("replay import inversion", scalar(observer, "SELECT name FROM goods WHERE id=?", op.goods()));
        }
    }

    @Test void currentPrincipalPermissionsAreEvaluatedAfterWaitingForTheSameAccountsEarlierTransaction() throws Exception {
        Operation op = edited("permission while waiting");
        AtomicReference<Set<String>> permissions = new AtomicReference<>(Set.of("goods:view", "goods:edit"));
        try (Connection holder = connection(); Connection observer = connection();
             ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor()) {
            prepare(holder, op.actor(), goodsPath(op.goods()), "PUT", true);
            ServiceSession session = serviceSession(op.actor(), permissions, null);
            CountDownLatch started = new CountDownLatch(1);
            Future<Throwable> attempt = executor.submit(() -> {
                try (session) { started.countDown(); return session.undo(op.id()); }
            });
            assertTrue(started.await(2, TimeUnit.SECONDS));
            awaitBlocked(observer, session.pid, pid(holder));
            // Deliberately replace the principal supplied to the service. This
            // proves guard timing; it does not model revoking an already
            // authenticated HTTP principal by changing database grants midflight.
            permissions.set(Set.of("goods:view"));
            holder.commit();
            assertInstanceOf(ApiException.class, attempt.get(8, TimeUnit.SECONDS));
            assertEquals("permission while waiting changed", scalar(observer, "SELECT name FROM goods WHERE id=?", op.goods()));
            assertEquals(0, count(observer, "SELECT count(*) FROM goods_operation_history_events WHERE operation_id=?", op.id()));
        }
    }

    @Test void aClientHandoverCommittedWhileUndoWaitsCannotReintroduceAnInvisibleClient() throws Exception {
        UUID actor = UUID.randomUUID(), allowedOwner = employee(), otherOwner = employee();
        UUID previous = client(allowedOwner), current = client(allowedOwner), id = goods("client handover"), operation;
        try (Connection setup = connection()) {
            execute(setup, "UPDATE goods SET client_id=? WHERE id=?", previous, id); setup.commit();
            prepare(setup, actor, goodsPath(id), "PUT", true);
            execute(setup, "UPDATE goods SET client_id=?,version=version+1 WHERE id=?", current, id);
            operation = latest(setup, actor); setup.commit();
        }
        try (Connection holder = connection(); Connection handover = connection(); Connection observer = connection();
             ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor()) {
            prepare(holder, actor, goodsPath(id), "PUT", true);
            ServiceSession session = serviceSession(actor, new AtomicReference<>(Set.of("goods:view", "goods:edit")), allowedOwner);
            CountDownLatch started = new CountDownLatch(1);
            Future<Throwable> attempt = executor.submit(() -> { try (session) { started.countDown(); return session.undo(operation); } });
            assertTrue(started.await(2, TimeUnit.SECONDS)); awaitBlocked(observer, session.pid, pid(holder));
            execute(handover, "UPDATE clients SET owner_employee_id=?,version=version+1 WHERE id=?", otherOwner, previous); handover.commit();
            holder.commit();
            assertInstanceOf(ApiException.class, attempt.get(8, TimeUnit.SECONDS));
            assertEquals(current.toString(), scalar(observer, "SELECT client_id::text FROM goods WHERE id=?", id));
            assertEquals(0, count(observer, "SELECT count(*) FROM goods_operation_history_events WHERE operation_id=?", operation));
        }
    }

    @Test void legacyImportUndoAndHistoryUndoShareOneActorOrderAndCommitOnlyOnce() throws Exception {
        UUID actor = UUID.randomUUID(), id = UUID.randomUUID(), batch = UUID.randomUUID(), operation;
        try (Connection setup = connection()) {
            prepare(setup, actor, "/api/master/goods/import/commit", "POST", true);
            execute(setup, "INSERT INTO goods(id,code,name,code_sequence) VALUES(?,?,'import concurrency',(SELECT coalesce(max(code_sequence),0)+1 FROM goods))", id, "CIMPORT-" + id);
            execute(setup, "INSERT INTO goods_import_batches(id,created_by,filename,row_count,status) VALUES(?,?,'concurrent.xlsx',1,'IMPORTED')", batch, actor);
            execute(setup, "INSERT INTO goods_import_creations(batch_id,entity_type,entity_id) VALUES(?,'GOODS',?)", batch, id);
            operation = latest(setup, actor); setup.commit();
        }
        AtomicReference<Set<String>> permissions = new AtomicReference<>(Set.of("goods:view", "goods:import", "goods:import:undo"));
        try (Connection observer = connection(); ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor()) {
            ServiceSession importing = serviceSession(actor, permissions, null, "/api/master/goods/import/" + batch, "DELETE");
            ServiceSession history = serviceSession(actor, permissions, null);
            CountDownLatch applied = new CountDownLatch(1), release = new CountDownLatch(1), started = new CountDownLatch(1);
            Future<Throwable> legacy = executor.submit(() -> { try (importing) { return importing.importUndo(batch, applied, release); } });
            assertTrue(applied.await(6, TimeUnit.SECONDS), "legacy import undo did not reach its commit barrier");
            Future<Throwable> duplicate = executor.submit(() -> { try (history) { started.countDown(); return history.undo(operation); } });
            assertTrue(started.await(2, TimeUnit.SECONDS)); awaitBlocked(observer, history.pid, importing.pid);
            release.countDown();
            assertNull(legacy.get(8, TimeUnit.SECONDS));
            assertInstanceOf(ApiException.class, duplicate.get(8, TimeUnit.SECONDS));
            assertEquals("UNDONE", scalar(observer, "SELECT status FROM goods_import_batches WHERE id=?", batch));
            assertEquals("true", scalar(observer, "SELECT is_deleted::text FROM goods WHERE id=?", id));
            assertEquals(1, count(observer, "SELECT count(*) FROM goods_operation_history_events WHERE operation_id=?", operation));
        }
    }

    @Test void aWarehouseDisabledWhileUndoWaitsCannotBeRestoredAsANewGoodsOwnership() throws Exception {
        UUID actor = UUID.randomUUID(), oldWarehouse = warehouse(), newWarehouse = warehouse(), id = goods("warehouse race"), operation;
        try (Connection setup = connection()) {
            execute(setup, "UPDATE goods SET owning_warehouse_id=? WHERE id=?", oldWarehouse, id); setup.commit();
            prepare(setup, actor, goodsPath(id), "PUT", true);
            execute(setup, "UPDATE goods SET owning_warehouse_id=?,version=version+1 WHERE id=?", newWarehouse, id);
            operation = latest(setup, actor); setup.commit();
        }
        try (Connection holder = connection(); Connection disabling = connection(); Connection observer = connection();
             ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor()) {
            prepare(holder, actor, goodsPath(id), "PUT", true);
            ServiceSession session = serviceSession(actor, new AtomicReference<>(Set.of("goods:view", "goods:edit")), null);
            CountDownLatch started = new CountDownLatch(1);
            Future<Throwable> attempt = executor.submit(() -> { try (session) { started.countDown(); return session.undo(operation); } });
            assertTrue(started.await(2, TimeUnit.SECONDS)); awaitBlocked(observer, session.pid, pid(holder));
            execute(disabling, "UPDATE warehouses SET status='禁用' WHERE id=?", oldWarehouse); disabling.commit();
            holder.commit();
            assertInstanceOf(ApiException.class, attempt.get(8, TimeUnit.SECONDS));
            assertEquals(newWarehouse.toString(), scalar(observer, "SELECT owning_warehouse_id::text FROM goods WHERE id=?", id));
            assertEquals(0, count(observer, "SELECT count(*) FROM goods_operation_history_events WHERE operation_id=?", operation));
        }
    }

    private static ServiceSession serviceSession(UUID actor, AtomicReference<Set<String>> permissions, UUID clientOwner) {
        return serviceSession(actor, permissions, clientOwner, "/api/master/goods/history/" + UUID.randomUUID() + "/undo", "POST");
    }
    private static ServiceSession serviceSession(UUID actor, AtomicReference<Set<String>> permissions, UUID clientOwner, String path, String method) {
        EntityManager em = factory.createEntityManager();
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        when(current.requireId()).thenReturn(actor);
        when(current.get()).thenAnswer(call -> Optional.of(new AuthUser(actor, UUID.randomUUID(), "concurrency", permissions.get(), false, true, false)));
        OwnerVisibility visibility = mock(OwnerVisibility.class);
        when(visibility.evaluate(anyString(), anyString())).thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(), Set.of()));
        TxSessionVars tx = mock(TxSessionVars.class);
        doAnswer(call -> {
            em.createNativeQuery("SELECT set_config('app.actor_id',:actor,true),set_config('app.audit_request_id',:request,true),set_config('app.audit_request_path',:path,true),set_config('app.audit_request_method',:method,true)")
                    .setParameter("actor", actor.toString()).setParameter("request", UUID.randomUUID().toString()).setParameter("path", path).setParameter("method", method).getSingleResult();
            em.createNativeQuery("SELECT fn_begin_goods_history_request()").getSingleResult(); return null;
        }).when(tx).bind();
        MasterObjectAccess access = mock(MasterObjectAccess.class); when(access.readableLabelOwner(anyString())).thenReturn(owner -> true);
        GoodsOperationHistoryService service = new GoodsOperationHistoryService(em, new ObjectMapper(), current, tx, new MasterReferenceGuard(em, access), visibility, mock(BusinessEventPublisher.class));
        ClientAccessPolicy clients = mock(ClientAccessPolicy.class);
        when(clients.evaluate()).thenReturn(mock(ClientAccessPolicy.ClientScope.class));
        when(clients.canRead(any(UUID.class), nullable(UUID.class), any())).thenAnswer(call -> Objects.equals(clientOwner, call.getArgument(1)));
        ReflectionTestUtils.setField(service, "masterReferences", new MasterReferenceValidationAdapter(em, visibility, clients));
        ReflectionTestUtils.setField(service, "warehouseRules", new WarehouseMasterRules(em));
        em.getTransaction().begin();
        int backendPid = ((Number) em.createNativeQuery("SELECT pg_backend_pid()").getSingleResult()).intValue();
        em.createNativeQuery("SET LOCAL lock_timeout='4s'").executeUpdate();
        em.createNativeQuery("SET LOCAL statement_timeout='8s'").executeUpdate();
        em.getTransaction().commit();
        return new ServiceSession(em, service, backendPid);
    }
    private record ServiceSession(EntityManager em, GoodsOperationHistoryService service, int pid) implements AutoCloseable {
        Throwable undo(UUID operation) {
            em.getTransaction().begin();
            em.createNativeQuery("SET LOCAL lock_timeout='4s'").executeUpdate();
            em.createNativeQuery("SET LOCAL statement_timeout='8s'").executeUpdate();
            try { service.undo(operation, 0); em.getTransaction().commit(); return null; }
            catch (Throwable failure) {
                if (em.getTransaction().isActive()) {
                    em.getTransaction().rollback();
                }
                return failure;
            }
        }
        Throwable importUndo(UUID batch, CountDownLatch applied, CountDownLatch release) {
            em.getTransaction().begin();
            em.createNativeQuery("SET LOCAL lock_timeout='4s'").executeUpdate();
            em.createNativeQuery("SET LOCAL statement_timeout='8s'").executeUpdate();
            try {
                service.undoImport(batch); applied.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS));
                em.getTransaction().commit(); return null;
            } catch (Throwable failure) {
                if (em.getTransaction().isActive()) {
                    em.getTransaction().rollback();
                }
                return failure;
            }
        }
        @Override public void close() {
            if (em.getTransaction().isActive()) {
                em.getTransaction().rollback();
            }
            em.close();
        }
    }

    private static Operation edited(String name) throws SQLException {
        UUID actor = UUID.randomUUID(), id = goods(name);
        try (Connection db = connection()) {
            prepare(db, actor, goodsPath(id), "PUT", true);
            execute(db, "UPDATE goods SET name=?,version=version+1 WHERE id=?", name + " changed", id);
            UUID operation = latest(db, actor); db.commit(); return new Operation(actor, operation, id);
        }
    }
    private static UUID goods(String name) throws SQLException {
        UUID id = UUID.randomUUID();
        try (Connection db = connection()) {
            execute(db, "INSERT INTO goods(id,code,name,code_sequence) VALUES(?,?,?,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))", id, "CONCURRENT-" + id, name);
            db.commit(); return id;
        }
    }
    private static UUID category() throws SQLException {
        UUID id = UUID.randomUUID(); try (Connection db = connection()) {
            execute(db, "INSERT INTO material_categories(id,code,name) VALUES(?,?,'concurrent category')", id, "CCAT-" + id); db.commit(); return id;
        }
    }
    private static UUID employee() throws SQLException {
        UUID id = UUID.randomUUID(); try (Connection db = connection()) {
            execute(db, "INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,'concurrent owner',id_type,department_id,current_date,'active','regular' FROM employees WHERE code='ADMIN'", id, "CEMP-" + id); db.commit(); return id;
        }
    }
    private static UUID client(UUID owner) throws SQLException {
        UUID id = UUID.randomUUID(); try (Connection db = connection()) {
            execute(db, "INSERT INTO clients(id,code,name,owner_employee_id,status,code_sequence) VALUES(?,?,'concurrent client',?,'使用',(SELECT coalesce(max(code_sequence),0)+1 FROM clients))", id, "CCLIENT-" + id, owner); db.commit(); return id;
        }
    }
    private static UUID warehouse() throws SQLException {
        try (Connection db = connection()) {
            String rootValue = scalar(db, "SELECT fn_warehouse_root_id()::text");
            UUID root;
            if (rootValue == null) {
                root = UUID.randomUUID();
                execute(db, "INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES(?,'001','concurrent root','使用',false)", root);
            } else root = UUID.fromString(rootValue);
            UUID id = UUID.randomUUID();
            execute(db, "INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable) VALUES(?,?,?,?,'使用',true)", id, "CWH-" + id, "concurrent leaf " + id, root);
            db.commit(); return id;
        }
    }
    private static Connection connection() throws SQLException {
        Connection db = database.openConnection(); db.setAutoCommit(false);
        execute(db, "SET LOCAL lock_timeout='4s'"); execute(db, "SET LOCAL statement_timeout='8s'"); execute(db, "SET LOCAL deadlock_timeout='100ms'");
        return db;
    }
    private static void prepare(Connection db, UUID actor, String path, String method, boolean prelock) throws SQLException {
        limits(db);
        execute(db, "SELECT set_config('app.actor_id',?,true),set_config('app.audit_request_id',?,true),set_config('app.audit_request_path',?,true),set_config('app.audit_request_method',?,true)", actor.toString(), UUID.randomUUID().toString(), path, method);
        if (prelock) execute(db, "SELECT fn_begin_goods_history_request()");
    }
    private static String goodsPath(UUID id) { return "/api/master/goods/" + id; }
    private static String historyPath(UUID id, boolean undo) { return "/api/master/goods/history/" + id + (undo ? "/undo" : "/redo"); }
    private static UUID latest(Connection db, UUID actor) throws SQLException { return UUID.fromString(scalar(db, "SELECT id FROM goods_operation_history WHERE actor_id=? ORDER BY created_at DESC,id DESC LIMIT 1", actor)); }
    private static void replay(Connection db, UUID id, UUID actor, long version, boolean undo) throws SQLException { limits(db); execute(db, "SELECT fn_replay_goods_operation(?,?,?,?)", id, actor, version, undo); }
    private static void limits(Connection db) throws SQLException { execute(db, "SET LOCAL lock_timeout='4s'"); execute(db, "SET LOCAL statement_timeout='8s'"); execute(db, "SET LOCAL deadlock_timeout='100ms'"); }
    @FunctionalInterface private interface SqlWork { int run() throws Exception; }
    private static Future<Outcome> submit(ExecutorService executor, Connection db, CountDownLatch started, SqlWork work) {
        return executor.submit(() -> {
            started.countDown();
            try { int affected = work.run(); db.commit(); return new Outcome(true, null, null, affected); }
            catch (SQLException error) { db.rollback(); return new Outcome(false, error.getSQLState(), error.getMessage(), 0); }
            catch (Throwable error) { db.rollback(); throw error; }
        });
    }
    private static void awaitBlocked(Connection observer, int waiter, int holder) {
        assertTimeoutPreemptively(Duration.ofSeconds(3), () -> {
            while (!"true".equals(scalar(observer, "SELECT (?=ANY(pg_blocking_pids(?)))::text", holder, waiter))) Thread.onSpinWait();
        }, "expected backend " + waiter + " to wait for backend " + holder);
    }
    private static void awaitDoneOrBlocked(Connection observer, Future<?> task, int waiter, int holder) {
        assertTimeoutPreemptively(Duration.ofSeconds(3), () -> {
            while (!task.isDone() && !"true".equals(scalar(observer, "SELECT (?=ANY(pg_blocking_pids(?)))::text", holder, waiter))) Thread.onSpinWait();
        });
    }
    private static void assertRejected(Outcome outcome, String state) { assertFalse(outcome.success(), outcome.toString()); assertEquals(state, outcome.state(), outcome.message()); }
    private static int pid(Connection db) throws SQLException { return count(db, "SELECT pg_backend_pid()"); }
    private static int count(Connection db, String sql, Object... args) throws SQLException {
        try (var statement = db.prepareStatement(sql)) {
            for (int i = 0; i < args.length; i++) {
                statement.setObject(i + 1, args[i]);
            }
            try (var result = statement.executeQuery()) {
                assertTrue(result.next(), "Expected an integer scalar row");
                long value = result.getLong(1);
                assertFalse(result.wasNull(), "Expected a non-null integer scalar");
                return Math.toIntExact(value);
            }
        }
    }
    private static int execute(Connection db, String sql, Object... args) throws SQLException {
        try (var statement = db.prepareStatement(sql)) {
            for (int i = 0; i < args.length; i++) {
                statement.setObject(i + 1, args[i]);
            }
            statement.execute();
            return statement.getUpdateCount();
        }
    }
    private static String scalar(Connection db, String sql, Object... args) throws SQLException {
        try (var statement = db.prepareStatement(sql)) {
            for (int i = 0; i < args.length; i++) {
                statement.setObject(i + 1, args[i]);
            }
            try (var result = statement.executeQuery()) {
                return result.next() ? result.getString(1) : null;
            }
        }
    }
}
