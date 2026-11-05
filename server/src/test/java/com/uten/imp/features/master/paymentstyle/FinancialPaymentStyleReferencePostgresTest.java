package com.uten.imp.features.master.paymentstyle;

import com.uten.imp.testsupport.BoundTestSql;
import com.uten.imp.testsupport.TestFlyway;
import org.flywaydb.core.api.MigrationVersion;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Real financial aliases prove the forward policy, historical tolerance and both lock layers. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class FinancialPaymentStyleReferencePostgresTest {
    private static final PostgreSQLContainer DB = new PostgreSQLContainer("postgres:16-alpine");
    private static final AtomicLong CODES = new AtomicLong(910610000000L);
    private static final String EXCLUSIVE_LOCK =
            "SELECT pg_advisory_xact_lock(hashtextextended('PAYMENT_STYLE_HIERARCHY',0))";
    private static final Map<String, String> FINANCIAL_ROLES = Map.ofEntries(
            Map.entry("finance_chart_codes.native_style_id", ""),
            Map.entry("finance_chart_code_styles.style_id", ""),
            Map.entry("finance_chart_owned_bindings.style_id", ""),
            Map.entry("finance_asset_opening_members.cost_style_id", "ACCOUNT"),
            Map.entry("finance_asset_opening_members.accumulated_style_id", "ACCOUNT"),
            Map.entry("finance_gl_settlement_scopes.style_id", ""),
            Map.entry("finance_native_posting_configurations.style_id", ""),
            Map.entry("finance_payable_statement_adjustment_lines.counterpart_style_id", ""),
            Map.entry("finance_payroll_accruals.wage_style_id", "LIABILITY"),
            Map.entry("finance_payroll_accrual_lines.expense_style_id", ""),
            Map.entry("finance_payroll_payment_attempts.fee_style_id", "EXPENSE"),
            Map.entry("finance_procurement_payable_candidates.inventory_style_id", "ACCOUNT"),
            Map.entry("finance_procurement_payable_candidates.pending_style_id", ""),
            Map.entry("finance_supplier_advances.style_id", "ACCOUNT"),
            Map.entry("finance_supplier_advance_refunds.bank_style_id", "ACCOUNT"),
            Map.entry("finance_supplier_advance_refunds.fee_style_id", "EXPENSE"),
            Map.entry("finance_supplier_advance_refunds.fx_style_id", ""));
    private static UUID actor;
    private static UUID historicalStyle;
    private static String historicalCode;
    private static String factsBefore, factsAfter, auditBefore, auditAfter, historyBefore, historyAfter;

    @BeforeAll
    static void upgradeNonemptyReferences() throws Exception {
        DB.start();
        var configuration = TestFlyway.configure()
                .dataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword())
                .locations("classpath:db/migration");
        MigrationVersion forward = MigrationVersion.fromVersion("1061");
        MigrationVersion previous = Arrays.stream(configuration.load().info().all())
                .map(info -> info.getVersion()).filter(Objects::nonNull)
                .filter(version -> version.compareTo(forward) < 0)
                .max(MigrationVersion::compareTo).orElseThrow();
        configuration.target(previous).load().migrate();
        try (Connection connection = connection()) {
            actor = actor(connection);
            historicalStyle = style(connection, "ACCOUNT", "禁用", true, null);
            historicalCode = code(connection, historicalStyle);
            factsBefore = historicalFacts(connection);
            auditBefore = auditHistory(connection);
            historyBefore = migrationHistory(connection);
        }
        var migrated = TestFlyway.configure()
                .dataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword())
                .locations("classpath:db/migration").target("1061").load().migrate();
        assertEquals(1, migrated.migrationsExecuted, "Only the forward reference policy is under test");
        try (Connection connection = connection()) {
            factsAfter = historicalFacts(connection);
            auditAfter = auditHistory(connection);
            historyAfter = migrationHistory(connection);
        }
    }

    @AfterAll
    static void stop() { DB.stop(); }

    @Test
    void ddlInventoryEqualsTheLiveUuidForeignKeysAndAllSeventeenUseTheSharedGuard() throws Exception {
        try (Connection connection = connection(); var statement = connection.createStatement()) {
            Set<String> actual = new TreeSet<>();
            try (ResultSet rows = statement.executeQuery("""
                    SELECT DISTINCT source.relname||'.'||attribute.attname
                    FROM pg_constraint constraint_row
                    JOIN pg_class source ON source.oid=constraint_row.conrelid
                    JOIN pg_namespace namespace ON namespace.oid=source.relnamespace
                    CROSS JOIN LATERAL unnest(constraint_row.conkey) key(attnum)
                    JOIN pg_attribute attribute ON attribute.attrelid=source.oid AND attribute.attnum=key.attnum
                    WHERE constraint_row.contype='f' AND constraint_row.confrelid='public.payment_styles'::regclass
                      AND namespace.nspname='public' AND NOT source.relispartition
                      AND source.relname<>'payment_styles' AND attribute.atttypid='uuid'::regtype
                    """)) {
                while (rows.next()) actual.add(rows.getString(1));
            }
            assertEquals(PaymentStyleReferenceGuardMigrationContractTest.findPaymentStyleUuidReferences(), actual,
                    "Compact SQL and financial subversions must match the real migrated schema");
            List<String> guarded = new ArrayList<>();
            try (ResultSet rows = statement.executeQuery("""
                    SELECT source.relname||'.'||attribute.attname,encode(trigger_row.tgargs,'escape'),
                           trigger_row.tgtype::integer,trigger_row.tgenabled::text,trigger_row.tgnargs::integer
                    FROM pg_trigger trigger_row JOIN pg_class source ON source.oid=trigger_row.tgrelid
                    CROSS JOIN LATERAL unnest(trigger_row.tgattr::smallint[]) key(attnum)
                    JOIN pg_attribute attribute ON attribute.attrelid=source.oid AND attribute.attnum=key.attnum
                    WHERE trigger_row.tgfoid='public.fn_guard_payment_style_reference()'::regprocedure
                      AND trigger_row.tgname LIKE 'trg_psref_fin_%' AND NOT trigger_row.tgisinternal
                    """)) {
                while (rows.next()) {
                    String key = rows.getString(1);
                    assertTrue(FINANCIAL_ROLES.containsKey(key), key);
                    String column = key.substring(key.indexOf('.') + 1);
                    assertEquals(column + "\\000" + FINANCIAL_ROLES.get(key)
                            + "\\000false\\000false\\000false\\000false\\000", rows.getString(2), key);
                    assertEquals(23, rows.getInt(3), "Immediate BEFORE ROW INSERT/UPDATE guard: " + key);
                    assertEquals("O", rows.getString(4), "Retain the existing reference-guard execution protocol");
                    assertEquals(6, rows.getInt(5));
                    guarded.add(key);
                }
            }
            assertEquals(FINANCIAL_ROLES.keySet(), Set.copyOf(guarded));
            assertEquals(17, guarded.size(), "Exactly one forward guard per financial UUID relation");
        }
    }

    @Test
    void theForwardMigrationPreservesExistingFactsAuditAndFlywayHistory() {
        assertEquals(factsBefore, factsAfter);
        assertEquals(auditBefore, auditAfter);
        assertEquals(historyBefore, historyAfter);
    }

    @Test
    void newAndChangedReferencesRejectMissingOrSoftDeletedTargetsWithoutRewritingTheOriginal() throws Exception {
        try (Connection connection = connection()) {
            UUID valid = style(connection, "EXPENSE", "使用", false, null);
            UUID deleted = style(connection, "EXPENSE", "禁用", true, null);
            SQLException missing = assertThrows(SQLException.class, () -> code(connection, UUID.randomUUID()));
            assertEquals("23503", missing.getSQLState());
            assertTrue(missing.getMessage().contains("不存在或已删除"));
            SQLException removed = assertThrows(SQLException.class, () -> code(connection, deleted));
            assertEquals("23503", removed.getSQLState());
            String original = code(connection, valid);
            SQLException changed = assertThrows(SQLException.class, () -> execute(connection,
                    "UPDATE finance_chart_codes SET native_style_id=? WHERE code=?", deleted, original));
            assertEquals("23503", changed.getSQLState());
            assertEquals(valid, scalar(connection,
                    "SELECT native_style_id FROM finance_chart_codes WHERE code=?", UUID.class, original));
        }
    }

    @Test
    void mappedParentsAndDisabledHistoricalStylesRetainTheirExistingMeaning() throws Exception {
        try (Connection connection = connection()) {
            UUID parent = style(connection, "EQUITY", "禁用", false, null);
            style(connection, "EQUITY", "禁用", false, parent);
            String mapped = code(connection, parent);
            assertEquals(parent, scalar(connection,
                    "SELECT native_style_id FROM finance_chart_codes WHERE code=?", UUID.class, mapped));
        }
    }

    @Test
    void anUnchangedHistoricalReferenceDoesNotWaitForOrRevalidateTheHierarchy() {
        assertTimeoutPreemptively(Duration.ofSeconds(20), () -> {
            try (Connection hierarchy = connection(); var executor = Executors.newSingleThreadExecutor()) {
                hierarchy.setAutoCommit(false);
                execute(hierarchy, EXCLUSIVE_LOCK);
                Future<Boolean> update = executor.submit(() -> {
                    try (Connection writer = connection()) {
                        execute(writer, """
                                UPDATE finance_chart_codes SET name='Historical metadata retained',native_style_id=native_style_id
                                WHERE code=?
                                """, historicalCode);
                        return historicalStyle.equals(scalar(writer,
                                "SELECT native_style_id FROM finance_chart_codes WHERE code=?", UUID.class, historicalCode));
                    }
                });
                try {
                    assertTrue(update.get(3, TimeUnit.SECONDS), "The unchanged old UUID must bypass reference locks and live checks");
                } finally {
                    hierarchy.rollback();
                }
            }
        });
    }

    @Test
    void newReferencesShareTheHierarchyKeyAndHoldTheActualTargetTupleUntilBothCommit() {
        assertTimeoutPreemptively(Duration.ofSeconds(30), () -> {
            UUID target;
            String source;
            try (Connection seed = connection()) {
                target = style(seed, "ACCOUNT", "使用", false, null);
                source = code(seed, null);
            }
            try (Connection first = connection(); Connection second = connection();
                 var executor = Executors.newFixedThreadPool(2)) {
                first.setAutoCommit(false);
                second.setAutoCommit(false);
                execute(first, "INSERT INTO finance_chart_owned_bindings(code,style_id,line_key) VALUES(?,?,'first')", source, target);
                execute(second, "INSERT INTO finance_chart_owned_bindings(code,style_id,line_key) VALUES(?,?,'second')", source, target);
                int firstPid = scalar(first, "SELECT pg_backend_pid()", Integer.class);
                int secondPid = scalar(second, "SELECT pg_backend_pid()", Integer.class);
                try (Connection inspector = connection()) {
                    assertTrue(scalar(inspector, """
                            SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND granted AND mode='ShareLock'
                              AND ((classid::bigint<<32)|objid::bigint)=hashtextextended('PAYMENT_STYLE_HIERARCHY',0)
                            """, Long.class) >= 2, "Reference writers must not queue behind each other");
                }
                CountDownLatch hierarchyStarted = new CountDownLatch(1), targetStarted = new CountDownLatch(1);
                AtomicInteger hierarchyPid = new AtomicInteger(), targetPid = new AtomicInteger();
                Future<Boolean> hierarchy = executor.submit(() -> {
                    try (Connection change = connection()) {
                        change.setAutoCommit(false);
                        hierarchyPid.set(scalar(change, "SELECT pg_backend_pid()", Integer.class));
                        hierarchyStarted.countDown();
                        execute(change, EXCLUSIVE_LOCK);
                        change.commit();
                        return true;
                    }
                });
                Future<Boolean> tuple = executor.submit(() -> {
                    try (Connection change = connection()) {
                        change.setAutoCommit(false);
                        targetPid.set(scalar(change, "SELECT pg_backend_pid()", Integer.class));
                        targetStarted.countDown();
                        scalar(change, "SELECT id FROM payment_styles WHERE id=? FOR NO KEY UPDATE", UUID.class, target);
                        change.commit();
                        return true;
                    }
                });
                try {
                    assertTrue(hierarchyStarted.await(5, TimeUnit.SECONDS));
                    assertTrue(targetStarted.await(5, TimeUnit.SECONDS));
                    awaitBlockedBy(hierarchyPid.get(), Set.of(firstPid, secondPid));
                    awaitBlockedBy(targetPid.get(), Set.of(firstPid, secondPid));
                    assertThrows(TimeoutException.class, () -> hierarchy.get(300, TimeUnit.MILLISECONDS));
                    assertThrows(TimeoutException.class, () -> tuple.get(300, TimeUnit.MILLISECONDS));
                    first.commit();
                    awaitBlockedBy(hierarchyPid.get(), Set.of(secondPid));
                    awaitBlockedBy(targetPid.get(), Set.of(secondPid));
                    assertThrows(TimeoutException.class, () -> hierarchy.get(200, TimeUnit.MILLISECONDS));
                    assertThrows(TimeoutException.class, () -> tuple.get(200, TimeUnit.MILLISECONDS));
                } finally {
                    first.rollback();
                    second.commit();
                }
                assertTrue(hierarchy.get(5, TimeUnit.SECONDS));
                assertTrue(tuple.get(5, TimeUnit.SECONDS));
            }
        });
    }

    @Test
    void aConcurrentSoftDeleteIsRecheckedAfterTheHierarchyTransactionReleases() {
        assertTimeoutPreemptively(Duration.ofSeconds(25), () -> {
            UUID target;
            try (Connection seed = connection()) { target = style(seed, "ACCOUNT", "使用", false, null); }
            try (Connection hierarchy = connection(); var executor = Executors.newSingleThreadExecutor()) {
                hierarchy.setAutoCommit(false);
                execute(hierarchy, EXCLUSIVE_LOCK);
                execute(hierarchy, "UPDATE payment_styles SET is_deleted=true WHERE id=?", target);
                int hierarchyPid = scalar(hierarchy, "SELECT pg_backend_pid()", Integer.class);
                CountDownLatch started = new CountDownLatch(1);
                AtomicInteger writerPid = new AtomicInteger();
                Future<String> reference = executor.submit(() -> {
                    try (Connection writer = connection()) {
                        writerPid.set(scalar(writer, "SELECT pg_backend_pid()", Integer.class));
                        started.countDown();
                        try { code(writer, target); return "ACCEPTED"; }
                        catch (SQLException rejected) { return rejected.getSQLState(); }
                    }
                });
                try {
                    assertTrue(started.await(5, TimeUnit.SECONDS));
                    awaitBlockedBy(writerPid.get(), Set.of(hierarchyPid));
                    assertThrows(TimeoutException.class, () -> reference.get(400, TimeUnit.MILLISECONDS));
                    hierarchy.commit();
                    assertEquals("23503", reference.get(5, TimeUnit.SECONDS));
                } finally {
                    hierarchy.rollback();
                }
            }
        });
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
    }

    /** Proves real PostgreSQL lock waiting; a worker merely delayed after countDown cannot satisfy it. */
    private static void awaitBlockedBy(int waitingPid, Set<Integer> expectedOwners) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        try (Connection inspector = connection()) {
            while (System.nanoTime() < deadline) {
                try (var statement = inspector.createStatement(); var query = BoundTestSql.prepare(statement,
                        "SELECT wait_event_type,pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid=?", waitingPid);
                     ResultSet state = query.executeQuery()) {
                    if (state.next() && "Lock".equals(state.getString(1))) {
                        Integer[] owners = (Integer[]) state.getArray(2).getArray();
                        if (Arrays.stream(owners).anyMatch(expectedOwners::contains)) return;
                    }
                }
                Thread.sleep(10);
            }
        }
        throw new AssertionError("Session " + waitingPid + " never waited on reference owners " + expectedOwners);
    }

    private static void execute(Connection connection, String sql, Object... values) throws SQLException {
        try (var statement = connection.createStatement()) { BoundTestSql.execute(statement, sql, values); }
    }

    private static <T> T scalar(Connection connection, String sql, Class<T> type, Object... values) throws SQLException {
        try (var statement = connection.createStatement(); var query = BoundTestSql.prepare(statement, sql, values);
             ResultSet rows = query.executeQuery()) {
            assertTrue(rows.next());
            return rows.getObject(1, type);
        }
    }

    private static UUID actor(Connection connection) throws SQLException {
        UUID employee = UUID.randomUUID(), user = UUID.randomUUID();
        execute(connection, """
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,?,'其他',(SELECT id FROM departments WHERE code='DEPT_FIN'),DATE '2026-01-01','active','regular')
                """, employee, "PSREF-" + employee,
                com.uten.imp.support.SyntheticEmployeeIdentity.name("financial reference", employee));
        execute(connection, "INSERT INTO users(id,employee_id,login_account,password_hash,status) VALUES(?,?,?,'test-not-used','active')",
                user, employee, "psref-" + user);
        return user;
    }

    private static UUID style(Connection connection, String category, String status, boolean deleted, UUID parent) throws SQLException {
        UUID id = UUID.randomUUID();
        execute(connection, """
                INSERT INTO payment_styles(id,code,name,category,parent_id,level,sort_order,status,is_deleted)
                VALUES(?,?,?,?,?,?,0,?,?)
                """, id, "PSREF-" + id, "Synthetic financial style " + id, category, parent, parent == null ? 0 : 1, status, deleted);
        return id;
    }

    private static String code(Connection connection, UUID style) throws SQLException {
        String code = Long.toString(CODES.incrementAndGet());
        execute(connection, """
                INSERT INTO finance_chart_codes(code,name,sort_order,native_style_id,source_row,source_kind,source_reference,updated_by)
                VALUES(?,'Synthetic original chart',0,?,1,'MANUAL','V1061 synthetic source',?)
                """, code, style, actor);
        return code;
    }

    private static String historicalFacts(Connection connection) throws SQLException {
        return scalar(connection, """
                SELECT jsonb_build_object('style',(SELECT to_jsonb(style) FROM payment_styles style WHERE id=?),
                       'chart',(SELECT to_jsonb(chart) FROM finance_chart_codes chart WHERE code=?))::text
                """, String.class, historicalStyle, historicalCode);
    }

    private static String auditHistory(Connection connection) throws SQLException {
        return scalar(connection, "SELECT md5(coalesce(string_agg(to_jsonb(a)::text,'' ORDER BY id,created_at),'')) FROM audit_log a", String.class);
    }

    private static String migrationHistory(Connection connection) throws SQLException {
        return scalar(connection, "SELECT md5(string_agg(to_jsonb(h)::text,'' ORDER BY installed_rank)) FROM flyway_schema_history h WHERE version<>'1061'", String.class);
    }
}
