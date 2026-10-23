package com.uten.imp.migration;

import com.uten.imp.support.MigratedSchemaBaseline;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.SQLWarning;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** V907: immutable parent bindings remain guarded without a second read on fresh inserts. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class BusinessRecordBindingInsertPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    Connection db;
    String source;

    @BeforeAll static void schema() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("binding_insert");
    }
    @AfterAll static void closeSchema() throws Exception { if (database != null) database.close(); }
    @BeforeEach void start() throws Exception {
        db = database.openConnection();
        db.setAutoCommit(false);
        source = "synthetic_binding_" + UUID.randomUUID();
    }
    @AfterEach void rollback() throws Exception { if (db != null) { db.rollback(); db.close(); } }

    @Test void newAndRepeatedBindingsKeepExactlyOneOriginalParent() throws Exception {
        bind(db, source, "child", "parents", "A");
        bind(db, source, "child", "parents", "A");
        assertThat(bindingCount(db, source, "child", "parents", "A")).isEqualTo(1);
    }

    @Test void parentIdentityAndTableChangesAreStillRejected() throws Exception {
        bind(db, source, "child", "parents", "A");
        expectRejected("23514", () -> bind(db, source, "child", "parents", "B"));
        expectRejected("23514", () -> bind(db, source, "child", "other_parents", "A"));
        assertThat(bindingCount(db, source, "child", "parents", "A")).isEqualTo(1);
    }

    @Test void nullParentsRemainNullAndCannotBeRebound() throws Exception {
        bind(db, source, "null-child", "parents", null);
        bind(db, source, "null-child", "parents", null);
        expectRejected("23514", () -> bind(db, source, "null-child", "parents", "A"));
        bind(db, source, "valued-child", "parents", "A");
        expectRejected("23514", () -> bind(db, source, "valued-child", "parents", null));
        assertThat(bindingCount(db, source, "null-child", "parents", null)).isEqualTo(1);
    }

    @Test void identityMutationAndDeletionRemainImmutable() throws Exception {
        bind(db, source, "child", "parents", "A");
        expectRejected("55000", () -> {
            try (var statement = db.prepareStatement("UPDATE business_record_identities SET parent_id='B' WHERE source_table=?")) {
                statement.setString(1, source); statement.executeUpdate();
            }
        });
        expectRejected("55000", () -> {
            try (var statement = db.prepareStatement("DELETE FROM business_record_identities WHERE source_table=?")) {
                statement.setString(1, source); statement.executeUpdate();
            }
        });
    }

    @Test void freshBindingsDoNotRepeatTheCachedIdentitySelect() throws Exception {
        try (var statement = db.createStatement()) {
            statement.execute("LOAD 'auto_explain'");
            statement.execute("SET LOCAL auto_explain.log_min_duration=0");
            statement.execute("SET LOCAL auto_explain.log_nested_statements=on");
            statement.execute("SET LOCAL auto_explain.log_level='notice'");
            statement.clearWarnings();
            statement.execute("SELECT fn_bind_business_record_identity('synthetic-plan','fresh-'||n,'parents','A') FROM generate_series(1,20) n");
            StringBuilder messages = new StringBuilder();
            for (SQLWarning warning = statement.getWarnings(); warning != null; warning = warning.getNextWarning()) {
                messages.append(warning.getMessage()).append('\n');
            }
            assertThat(messages.toString()).contains("INSERT INTO business_record_identities");
            assertThat(messages.toString()).doesNotContain("SELECT parent_table,parent_id");
        }
    }

    @Test void repeatableReadOldSnapshotCannotAdoptAnInvisibleConcurrentBinding() throws Exception {
        oldSnapshotFailsClosed(Connection.TRANSACTION_REPEATABLE_READ);
    }

    @Test void serializableOldSnapshotCannotAdoptAnInvisibleConcurrentBinding() throws Exception {
        oldSnapshotFailsClosed(Connection.TRANSACTION_SERIALIZABLE);
    }

    @Test void concurrentBindingsRespectTheOriginalParent() throws Exception {
        for (String contenderParent : new String[]{"A", "B"}) {
            String child = UUID.randomUUID().toString();
            try (var writer = database.openConnection(); var executor = Executors.newSingleThreadExecutor()) {
                writer.setAutoCommit(false);
                bind(writer, source, child, "parents", "A");
                CountDownLatch started = new CountDownLatch(1);
                var contender = executor.submit(() -> {
                    try (var connection = database.openConnection()) {
                        connection.setAutoCommit(false);
                        try (var statement = connection.createStatement()) { statement.execute("SET LOCAL statement_timeout='10s'"); }
                        started.countDown();
                        try {
                            bind(connection, source, child, "parents", contenderParent);
                            connection.commit(); return "SUCCESS";
                        } catch (SQLException expected) {
                            connection.rollback(); return expected.getSQLState();
                        }
                    }
                });
                assertThat(started.await(5, TimeUnit.SECONDS)).isTrue();
                writer.commit();
                assertThat(contender.get(15, TimeUnit.SECONDS)).isEqualTo(contenderParent.equals("A") ? "SUCCESS" : "23514");
                assertThat(bindingCount(writer, source, child, "parents", "A")).isEqualTo(1);
                writer.rollback();
            }
        }
    }

    private void oldSnapshotFailsClosed(int isolation) throws Exception {
        String child = UUID.randomUUID().toString();
        try (var snapshot = database.openConnection(); var writer = database.openConnection()) {
            snapshot.setTransactionIsolation(isolation); snapshot.setAutoCommit(false);
            try (var statement = snapshot.createStatement()) { statement.executeQuery("SELECT count(*) FROM business_record_identities").close(); }
            bind(writer, source, child, "parents", "A");
            assertThatThrownBy(() -> bind(snapshot, source, child, "parents", "A"))
                .isInstanceOfSatisfying(SQLException.class, error -> assertThat(error.getSQLState()).isEqualTo("40001"));
            snapshot.rollback();
        }
    }

    private void expectRejected(String state, SqlAction action) throws Exception {
        var point = db.setSavepoint();
        assertThatThrownBy(action::run).isInstanceOfSatisfying(SQLException.class, error -> assertThat(error.getSQLState()).isEqualTo(state));
        db.rollback(point);
    }
    private static void bind(Connection connection, String source, String id, String parent, String parentId) throws SQLException {
        try (var statement = connection.prepareStatement("SELECT fn_bind_business_record_identity(?,?,?,?)")) {
            statement.setString(1, source); statement.setString(2, id); statement.setString(3, parent); statement.setString(4, parentId);
            statement.execute();
        }
    }
    private static long bindingCount(Connection connection, String source, String id, String parent, String parentId) throws SQLException {
        try (var statement = connection.prepareStatement("SELECT count(*) FROM business_record_identities WHERE source_table=? AND source_id=? AND parent_table=? AND parent_id IS NOT DISTINCT FROM CAST(? AS text)")) {
            statement.setString(1, source); statement.setString(2, id); statement.setString(3, parent); statement.setString(4, parentId);
            try (var result = statement.executeQuery()) { result.next(); return result.getLong(1); }
        }
    }
    @FunctionalInterface private interface SqlAction { void run() throws Exception; }
}
