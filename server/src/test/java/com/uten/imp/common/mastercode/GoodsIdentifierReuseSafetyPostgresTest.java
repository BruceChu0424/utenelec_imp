package com.uten.imp.common.mastercode;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Independent safety proof: real locks, historical identity, rollback, and retained nonuse evidence. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@Timeout(30)
class GoodsIdentifierReuseSafetyPostgresTest {
    private MigratedSchemaBaseline.ScopedDatabase database;
    private final AtomicLong sequence = new AtomicLong(1_000_000);
    private UUID costingRoot;

    @BeforeEach
    void open() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("goods_reuse_safety");
    }

    @AfterEach
    void close() throws Exception {
        if (database != null) database.close();
    }

    @Test
    void threeGenerationsKeepEveryUuidAndClaimButRetireBothEarlierIdentities() throws Exception {
        String code = code();
        UUID first = createGoods(code);
        deleteGoods(first);
        UUID second = reuse(code);
        deleteGoods(second);
        UUID third = reuse(code);

        try (Connection c = connection()) {
            assertEquals(3, number(c, "SELECT count(*) FROM goods WHERE code=?", code));
            assertEquals(2, number(c, "SELECT count(*) FROM goods WHERE code=? AND is_deleted", code));
            assertEquals(1, number(c, "SELECT count(*) FROM goods WHERE id=? AND NOT is_deleted", third));
            assertEquals(3, number(c, "SELECT count(*) FROM master_code_reservation_members WHERE master_domain='GOODS' AND normalized_code=?", code));
            assertEquals(3, number(c, "SELECT count(*) FROM business_identifier_reservation_members WHERE owner_domain='GOODS' AND normalized_identifier=?", code));
            assertEquals(first, uuid(c, "SELECT first_entity_id FROM master_code_reservations WHERE master_domain='GOODS' AND normalized_code=?", code));
            assertEquals(first, uuid(c, "SELECT first_entity_id FROM business_identifier_reservations WHERE normalized_identifier=?", code));
            assertEquals(2, number(c, "SELECT count(*) FROM goods_code_reuse_releases WHERE normalized_code=?", code));
        }
        for (UUID retired : List.of(first, second)) {
            SQLException restored = assertThrows(SQLException.class, () -> {
                try (Connection c = connection()) {
                    update(c, "UPDATE goods SET is_deleted=false WHERE id=?", retired);
                }
            });
            assertTrue(List.of("23514", "23505").contains(restored.getSQLState()),
                    "The active code constraint or the permanent retirement guard must reject restoration");
            SQLException renamedAndRestored = assertThrows(SQLException.class, () -> {
                try (Connection c = connection()) {
                    update(c, "UPDATE goods SET code=?,is_deleted=false WHERE id=?", code(), retired);
                }
            });
            assertEquals("23514", renamedAndRestored.getSQLState(), "Changing the display code must not revive a retired UUID");
        }
        for (String table : List.of("goods_code_reuse_releases", "master_code_reservation_members", "business_identifier_reservation_members")) {
            SQLException immutable = assertThrows(SQLException.class, () -> {
                try (Connection c = connection()) {
                    update(c, "DELETE FROM " + table);
                }
            });
            assertEquals("55000", immutable.getSQLState(), table);
        }
    }

    @Test
    void aReleaseWithoutTheNewGoodsRollsBackAtCommit() throws Exception {
        String code = code();
        UUID old = createGoods(code);
        deleteGoods(old);
        try (Connection c = connection()) {
            c.setAutoCommit(false);
            assertTrue(claim(c, code, UUID.randomUUID()));
            SQLException incomplete = assertThrows(SQLException.class, c::commit);
            assertTrue(List.of("23514", "23503").contains(incomplete.getSQLState()),
                    "The deferred foreign key or completion guard must reject the incomplete release");
            c.rollback();
        }
        try (Connection c = connection()) {
            assertEquals(old, reusable(c, code));
            assertEquals(0, number(c, "SELECT count(*) FROM goods_code_reuse_releases WHERE normalized_code=?", code));
            assertEquals(1, number(c, "SELECT count(*) FROM business_identifier_reservation_members WHERE normalized_identifier=?", code));
        }
    }

    @Test
    void aCompetingDomainCannotTakeAReleasedCodeDuringGoodsCreation() throws Exception {
        String code = code();
        UUID old = createGoods(code);
        deleteGoods(old);
        try (Connection winner = connection()) {
            winner.setAutoCommit(false);
            UUID next = UUID.randomUUID();
            assertTrue(claim(winner, code, next));
            insertGoods(winner, next, code);
            try (RunningQuery color = start(c -> update(c,
                    "INSERT INTO colors(id,code,name) VALUES(?,?, 'competing color')", UUID.randomUUID(), code))) {
                awaitBlocked(color);
                winner.commit();
                assertEquals("23505", color.result().get(10, TimeUnit.SECONDS));
            }
        }
        try (Connection c = connection()) {
            assertEquals(0, number(c, "SELECT count(*) FROM colors WHERE code=?", code));
            assertEquals(1, number(c, "SELECT count(*) FROM goods WHERE code=? AND NOT is_deleted", code));
        }
    }

    @Test
    void twoSimultaneousClaimsProduceOnlyOneNewIdentity() throws Exception {
        String code = code();
        UUID old = createGoods(code);
        deleteGoods(old);
        try (Connection winner = connection()) {
            winner.setAutoCommit(false);
            UUID next = UUID.randomUUID();
            assertTrue(claim(winner, code, next));
            insertGoods(winner, next, code);
            try (RunningQuery loser = start(c -> {
                UUID candidate = UUID.randomUUID();
                if (!claim(c, code, candidate)) return;
                insertGoods(c, candidate, code);
            })) {
                awaitBlocked(loser);
                winner.commit();
                assertTrue(List.of("23514", "40001", "23505").contains(loser.result().get(10, TimeUnit.SECONDS)),
                        "The second claim must fail after rechecking the committed owner");
            }
        }
        try (Connection c = connection()) {
            assertEquals(2, number(c, "SELECT count(*) FROM goods WHERE code=?", code));
            assertEquals(1, number(c, "SELECT count(*) FROM goods_code_reuse_releases WHERE normalized_code=?", code));
            assertEquals(1, number(c, "SELECT count(*) FROM goods WHERE code=? AND NOT is_deleted", code));
        }
    }

    @Test
    void aBusinessReferenceThatCommitsFirstPreventsAWaitingReuse() throws Exception {
        String code = code();
        UUID old = createGoods(code);
        deleteGoods(old);
        costingRoot = createGoods(code());
        try (Connection reference = connection()) {
            reference.setAutoCommit(false);
            insertBusinessJson(reference, old);
            try (RunningQuery reuse = start(c -> {
                UUID next = UUID.randomUUID();
                if (claim(c, code, next)) insertGoods(c, next, code);
            })) {
                awaitBlocked(reuse);
                reference.commit();
                assertTrue(List.of("23514", "40001").contains(reuse.result().get(10, TimeUnit.SECONDS)));
            }
        }
        try (Connection c = connection()) {
            assertNull(reusable(c, code));
            assertEquals(1, number(c, "SELECT count(*) FROM goods_code_usage_facts WHERE goods_id=?", old));
            assertEquals(0, number(c, "SELECT count(*) FROM goods_code_reuse_releases WHERE normalized_code=?", code));
        }
    }

    @Test
    void aReuseThatCommitsFirstRejectsTheWaitingJsonReferenceEvenWithLegacyRestoreFlags() throws Exception {
        String code = code();
        UUID old = createGoods(code);
        deleteGoods(old);
        costingRoot = createGoods(code());
        UUID next = UUID.randomUUID();
        try (Connection winner = connection()) {
            winner.setAutoCommit(false);
            assertTrue(claim(winner, code, next));
            insertGoods(winner, next, code);
            try (RunningQuery reference = start(c -> {
                update(c, "SELECT set_config('uten.legacy_reference_import','on',true)");
                insertBusinessJson(c, old);
            })) {
                awaitBlocked(reference);
                winner.commit();
                assertEquals("23514", reference.result().get(10, TimeUnit.SECONDS));
            }
        }
        try (Connection c = connection()) {
            assertEquals(0, number(c, "SELECT count(*) FROM goods_code_usage_facts WHERE goods_id=?", old));
            assertEquals(0, number(c, "SELECT count(*) FROM goods_cost_sheets WHERE calculation @> jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('goodsId',CAST(? AS text))))", old));
            insertBusinessJson(c, next);
            assertEquals(1, number(c, "SELECT count(*) FROM goods_code_usage_facts WHERE goods_id=?", next),
                    "Ordinary business may use the newly created goods UUID");
        }
    }

    @Test
    void hardDeletedBusinessKeepsUsageAndAuditProtectionAcrossAllThreeLedgers() throws Exception {
        String usedCode = code();
        UUID used = createGoods(usedCode);
        try (Connection c = connection()) {
            UUID task = UUID.randomUUID();
            update(c, "INSERT INTO rd_tasks(id,task_no,title,category,goods_id,reporter_employee_id) SELECT ?,fixed_prefix||to_char(clock_timestamp() AT TIME ZONE 'Asia/Shanghai','YYYYMMDD')||'999998','historical reference','OTHER',?,? FROM business_identifier_namespaces WHERE namespace_key='RD_TASK'", task, used, UUID.randomUUID());
            update(c, "DELETE FROM rd_tasks WHERE id=?", task);
            assertEquals(0, number(c, "SELECT count(*) FROM rd_tasks WHERE id=?", task));
            SQLException auditProtection = assertThrows(SQLException.class,
                    () -> update(c, "TRUNCATE audit_log,audit_log_archive RESTART IDENTITY"));
            assertTrue(List.of("55000", "42501").contains(auditProtection.getSQLState()),
                    "The append-only guard or current audit privileges must prevent purging");
        }
        deleteGoods(used);
        String reusedCode = code();
        UUID old = createGoods(reusedCode);
        deleteGoods(old);
        UUID next = reuse(reusedCode);
        try (Connection c = connection()) {
            assertNull(reusable(c, usedCode));
            assertEquals(0, number(c, "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='business_data_reset'"));
            assertEquals(1, number(c, "SELECT count(*) FROM goods_code_usage_facts WHERE goods_id=?", used));
            assertEquals(1, number(c, "SELECT count(*) FROM goods_code_reuse_releases WHERE old_goods_id=? AND new_goods_id=?", old, next));
            assertEquals(3, number(c, "SELECT count(*) FROM goods_code_lifecycles WHERE goods_id IN (?,?,?)", used, old, next));
            assertNull(reusable(c, usedCode));
        }
    }

    @Test
    void legacyImportedIdentityNeverAcquiresTrustedNonuseEvidence() throws Exception {
        String code = code();
        UUID id = UUID.randomUUID();
        try (Connection c = connection()) {
            update(c, "INSERT INTO goods(id,legacy_id,code,name,code_sequence) VALUES(?,2099000001,?,'legacy',?)", id, code, sequence.incrementAndGet());
        }
        deleteGoods(id);
        try (Connection c = connection()) {
            assertNull(reusable(c, code));
            assertEquals(0, number(c, "SELECT count(*) FROM goods_code_lifecycles WHERE goods_id=?", id));
            assertFalse(claim(c, code, UUID.randomUUID()));
        }
    }

    @Test
    void recordedOldNewAndRepeatedJsonReferencesDoNotRepeatTheirPermanentWriter() throws Exception {
        UUID a=createGoods(code()),b=createGoods(code());costingRoot=createGoods(code());
        try(Connection c=connection()) {
            insertBusinessJson(c,a);insertBusinessJson(c,b);
            c.setAutoCommit(false);update(c,"SET LOCAL track_functions='all'");
            long capture=functionCalls(c,"fn_capture_goods_code_use()");
            long note=functionCalls(c,"fn_note_goods_code_use(uuid,text)");
            long proof=functionCalls(c,"fn_goods_code_use_recorded(jsonb,jsonb,text[])");
            long facts=number(c,"SELECT count(*) FROM goods_code_usage_facts");
            UUID sheet=UUID.randomUUID(),actor=UUID.randomUUID();
            update(c,"INSERT INTO goods_cost_sheets(id,sheet_no,goods_id,name,input,calculation,created_by,updated_by) VALUES(?,?,?,'permanent proof','{}',jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('goodsId',CAST(? AS text)),jsonb_build_object('goodsId',CAST(? AS text)),jsonb_build_object('goodsId',CAST(? AS text)))),?,?)",
                    sheet,sheet.toString(),costingRoot,a,b,a,actor,actor);
            update(c,"UPDATE goods_cost_sheets SET name='same referenced identities' WHERE id=?",sheet);
            update(c,"UPDATE goods_cost_sheets SET goods_id=goods_id WHERE id=?",sheet);
            assertEquals(0,functionCalls(c,"fn_capture_goods_code_use()")-capture);
            assertEquals(0,functionCalls(c,"fn_note_goods_code_use(uuid,text)")-note);
            assertEquals(3,functionCalls(c,"fn_goods_code_use_recorded(jsonb,jsonb,text[])")-proof);
            assertEquals(facts,number(c,"SELECT count(*) FROM goods_code_usage_facts"));
            assertTrue(recorded(c,a));assertTrue(recorded(c,b));c.rollback();
        }
    }

    @Test
    void anotherUncommittedFirstUseCannotSupplyThisWritersPermanentProof() throws Exception {
        UUID goods=createGoods(code());costingRoot=createGoods(code());
        try(Connection owner=connection()) {
            owner.setAutoCommit(false);insertBusinessJson(owner,goods);
            assertTrue(recorded(owner,goods));
            try(Connection observer=connection()) {assertFalse(recorded(observer,goods));}
            try(RunningQuery contender=start(c->insertBusinessJson(c,goods))) {
                awaitBlocked(contender);owner.rollback();
                assertEquals("OK",contender.result().get(10,TimeUnit.SECONDS));
            }
        }
        try(Connection c=connection()) {
            assertTrue(recorded(c,goods));
            assertEquals(1,number(c,"SELECT count(*) FROM goods_code_usage_facts WHERE goods_id=?",goods));
        }
    }

    @Test
    void savepointRollbackRetiresTheProofBeforeAnotherRealReference() throws Exception {
        UUID goods=createGoods(code());costingRoot=createGoods(code());
        try(Connection c=connection()) {
            c.setAutoCommit(false);var before=c.setSavepoint();insertBusinessJson(c,goods);
            assertTrue(recorded(c,goods));c.rollback(before);assertFalse(recorded(c,goods));
            insertBusinessJson(c,goods);c.commit();assertTrue(recorded(c,goods));
            assertEquals(1,number(c,"SELECT count(*) FROM goods_code_usage_facts WHERE goods_id=?",goods));
        }
    }

    @Test
    void proofKeepsTheOriginalMetadataPrivilegesRlsAndReferenceFreeWrites() throws Exception {
        UUID known=createGoods(code()),fresh=createGoods(code());costingRoot=createGoods(code());
        String role="usage_proof_"+UUID.randomUUID().toString().replace("-","");
        try(Connection c=connection()) {
            insertBusinessJson(c,known);c.setAutoCommit(false);
            try {
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"CREATE ROLE %I NOLOGIN",role);
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"CREATE TABLE uten_goods_usage_privilege_probe(id integer PRIMARY KEY,goods_id uuid REFERENCES goods(id))");
                update(c,"SELECT fn_refresh_goods_code_usage_tracking()");
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"GRANT USAGE ON SCHEMA public TO %I",role);
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"GRANT SELECT,INSERT,UPDATE,DELETE ON uten_goods_usage_privilege_probe TO %I",role);
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"GRANT SELECT,UPDATE ON goods TO %I",role);
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"GRANT SELECT ON goods_code_reuse_releases TO %I",role);
                // A genuine first-use fact retains its original fn_audit write.
                // Isolate only the facts privileges under test, not an unrelated
                // missing audit sink/sequence grant in this synthetic DB role.
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"GRANT INSERT ON audit_log TO %I",role);
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO %I",role);
                assertEquals(0,number(c,"SELECT has_table_privilege(?,'public.goods_code_usage_facts','SELECT')::int",role));
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"SET LOCAL ROLE %I",role);
                update(c,"INSERT INTO uten_goods_usage_privilege_probe VALUES(1,NULL)");
                denied(c,"INSERT INTO uten_goods_usage_privilege_probe VALUES(2,?)",known);
                update(c,"RESET ROLE");
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"GRANT SELECT ON goods_code_usage_facts TO %I",role);
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"SET LOCAL ROLE %I",role);
                update(c,"INSERT INTO uten_goods_usage_privilege_probe VALUES(3,?)",known);
                update(c,"RESET ROLE");
                update(c,"REVOKE EXECUTE ON FUNCTION public.fn_note_goods_code_use(uuid,text) FROM PUBLIC");
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"SET LOCAL ROLE %I",role);
                denied(c,"INSERT INTO uten_goods_usage_privilege_probe VALUES(7,?)",known);
                update(c,"RESET ROLE");
                update(c,"GRANT EXECUTE ON FUNCTION public.fn_note_goods_code_use(uuid,text) TO PUBLIC");
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"SET LOCAL ROLE %I",role);
                denied(c,"INSERT INTO uten_goods_usage_privilege_probe VALUES(4,?)",fresh);
                update(c,"RESET ROLE");
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"GRANT INSERT ON goods_code_usage_facts TO %I",role);
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"SET LOCAL ROLE %I",role);
                update(c,"INSERT INTO uten_goods_usage_privilege_probe VALUES(5,?)",fresh);
                assertTrue(recorded(c,fresh));update(c,"RESET ROLE");
                update(c,"ALTER TABLE goods_code_usage_facts ENABLE ROW LEVEL SECURITY");
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"CREATE POLICY usage_proof_hidden_select ON goods_code_usage_facts FOR SELECT TO %I USING(false)",role);
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"CREATE POLICY usage_proof_denied_insert ON goods_code_usage_facts FOR INSERT TO %I WITH CHECK(false)",role);
                com.uten.imp.support.PostgresFixtureDdl.execute(c,"SET LOCAL ROLE %I",role);
                assertFalse(recorded(c,known));
                denied(c,"INSERT INTO uten_goods_usage_privilege_probe VALUES(6,?)",known);
                update(c,"RESET ROLE");
                assertEquals(1,number(c,"SELECT count(*) FROM goods_code_usage_facts WHERE goods_id=?",fresh));
                assertEquals(1,number(c,"SELECT count(*) FROM uten_goods_usage_privilege_probe WHERE id=1 AND goods_id IS NULL"));
            } finally {c.rollback();}
        }
    }

    private static void denied(Connection c,String sql,Object...values) throws SQLException {
        var before=c.setSavepoint();
        try {assertEquals("42501",assertThrows(SQLException.class,()->update(c,sql,values)).getSQLState());}
        finally {c.rollback(before);}
    }

    private static boolean recorded(Connection c,UUID goods) throws SQLException {
        try(var q=query(c,"SELECT fn_goods_code_use_recorded(NULL,jsonb_build_object('goods_id',CAST(? AS text)),ARRAY['U:goods_id'])",goods);
            var rows=q.executeQuery()) {assertTrue(rows.next());return rows.getBoolean(1);}
    }
    private static long functionCalls(Connection c,String signature) throws SQLException {
        return number(c,"SELECT COALESCE(pg_stat_get_xact_function_calls(CAST(? AS regprocedure)),0)",signature);
    }

    private UUID createGoods(String code) throws SQLException {
        UUID id = UUID.randomUUID();
        try (Connection c = connection()) { insertGoods(c, id, code); }
        try (Connection c = connection()) {
            assertEquals(1, number(c, "SELECT count(*) FROM goods_code_lifecycles WHERE goods_id=?", id));
            assertEquals(0, number(c, "SELECT count(*) FROM goods_code_usage_facts WHERE goods_id=?", id));
        }
        return id;
    }

    private void insertGoods(Connection c, UUID id, String code) throws SQLException {
        update(c, "INSERT INTO goods(id,code,name,code_sequence) VALUES(?,?,'unused goods',?)", id, code, sequence.incrementAndGet());
    }

    private void deleteGoods(UUID id) throws SQLException {
        try (Connection c = connection()) { update(c, "UPDATE goods SET is_deleted=true,deleted_at=clock_timestamp() WHERE id=?", id); }
    }

    private UUID reuse(String code) throws SQLException {
        UUID next = UUID.randomUUID();
        try (Connection c = connection()) {
            c.setAutoCommit(false);
            assertTrue(claim(c, code, next));
            insertGoods(c, next, code);
            c.commit();
        }
        return next;
    }

    private static boolean claim(Connection c, String code, UUID next) throws SQLException {
        try (PreparedStatement q = query(c, "SELECT fn_claim_reusable_goods_code(?,?)", code, next); ResultSet rows = q.executeQuery()) {
            assertTrue(rows.next());
            return rows.getBoolean(1);
        }
    }

    private static UUID reusable(Connection c, String code) throws SQLException {
        return uuid(c, "SELECT fn_goods_code_reusable_owner(?)", code);
    }

    private void insertBusinessJson(Connection c, UUID goods) throws SQLException {
        if (costingRoot == null) costingRoot = createGoods(code());
        UUID sheet = UUID.randomUUID(), actor = UUID.randomUUID();
        update(c, "INSERT INTO goods_cost_sheets(id,sheet_no,goods_id,name,input,calculation,created_by,updated_by) VALUES(?,?,?,'reference safety','{}',jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('goodsId',CAST(? AS text)))),?,?)", sheet, sheet.toString(), costingRoot, goods, actor, actor);
    }

    private Connection connection() throws SQLException { return database.openConnection(); }

    private static String code() { return "REUSE-" + UUID.randomUUID().toString().toUpperCase(); }

    private static PreparedStatement query(Connection c, String sql, Object... params) throws SQLException {
        PreparedStatement q = c.prepareStatement(sql);
        for (int i = 0; i < params.length; i++) q.setObject(i + 1, params[i]);
        return q;
    }

    private static void update(Connection c, String sql, Object... params) throws SQLException {
        try (PreparedStatement q = query(c, sql, params)) { q.execute(); }
    }

    private static long number(Connection c, String sql, Object... params) throws SQLException {
        try (PreparedStatement q = query(c, sql, params); ResultSet rows = q.executeQuery()) {
            assertTrue(rows.next());
            return rows.getLong(1);
        }
    }

    private static UUID uuid(Connection c, String sql, Object... params) throws SQLException {
        try (PreparedStatement q = query(c, sql, params); ResultSet rows = q.executeQuery()) {
            assertTrue(rows.next());
            return rows.getObject(1, UUID.class);
        }
    }

    private RunningQuery start(SqlWork work) throws Exception {
        ExecutorService executor = Executors.newSingleThreadExecutor();
        CompletableFuture<Integer> pid = new CompletableFuture<>();
        CompletableFuture<String> failureDetail = new CompletableFuture<>();
        Future<String> result = executor.submit(() -> {
            try (Connection c = connection()) {
                c.setAutoCommit(false);
                update(c, "SET LOCAL statement_timeout='8s'");
                pid.complete((int) number(c, "SELECT pg_backend_pid()"));
                try {
                    work.execute(c);
                    c.commit();
                    return "OK";
                } catch (SQLException failure) {
                    c.rollback();
                    failureDetail.complete(failure.getMessage());
                    return failure.getSQLState();
                }
            } catch (Exception failure) {
                pid.completeExceptionally(failure);
                throw failure;
            }
        });
        return new RunningQuery(executor, pid.get(10, TimeUnit.SECONDS), result, failureDetail);
    }

    private void awaitBlocked(RunningQuery pending) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        try (Connection observer = connection()) {
            while (System.nanoTime() < deadline) {
                if (number(observer, "SELECT cardinality(pg_blocking_pids(?))", pending.backendPid()) > 0) return;
                if (pending.result().isDone()) throw new AssertionError("Competing write completed before lock wait: "
                        + pending.result().get() + "; " + pending.failureDetail().getNow("no SQL failure"));
                Thread.sleep(25);
            }
        }
        throw new AssertionError("Expected PostgreSQL backend " + pending.backendPid() + " to wait on the competing transaction's real lock");
    }

    @FunctionalInterface
    private interface SqlWork { void execute(Connection c) throws SQLException; }

    private record RunningQuery(ExecutorService executor, int backendPid, Future<String> result,
                                CompletableFuture<String> failureDetail) implements AutoCloseable {
        @Override public void close() { executor.shutdownNow(); }
    }
}
