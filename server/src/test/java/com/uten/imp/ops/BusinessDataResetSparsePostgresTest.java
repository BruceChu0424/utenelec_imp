package com.uten.imp.ops;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Savepoint;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

/** Storage work is reduced without weakening the real PostgreSQL reset contract. */
@Testcontainers(disabledWithoutDocker = true)
class BusinessDataResetSparsePostgresTest {
    @Container
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16.15-alpine")
            .withDatabaseName("uten_sparse_reset").withUsername("uten").withPassword("uten");

    private Connection connection;

    @BeforeAll
    static void migrate() {
        Flyway.configure().dataSource(jdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").load().migrate();
    }

    @BeforeEach
    void begin() throws SQLException {
        connection = DriverManager.getConnection(jdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        connection.setAutoCommit(false);
        connection.createStatement().execute("SET LOCAL jit = off");
        connection.createStatement().execute("SET LOCAL lock_timeout = '2s'");
        connection.createStatement().execute("SET LOCAL statement_timeout = '120s'");
    }

    @AfterEach
    void rollback() throws SQLException {
        connection.rollback();
        connection.close();
    }

    @Test
    void sparseRowsRetainEmptyFilesButTruncateTheTransitiveForeignKeyClosure() throws Exception {
        connection.createStatement().execute("ALTER TABLE stock_balances ADD COLUMN reset_probe_outbox_id uuid REFERENCES business_outbox(id)");
        connection.createStatement().execute("ALTER TABLE stock_reservations ADD COLUMN reset_probe_balance_id uuid REFERENCES stock_balances(id)");
        connection.createStatement().execute("INSERT INTO business_outbox(id,event_type,aggregate_type,dedupe_key,status) VALUES (gen_random_uuid(),'RESET_TEST','RESET_TEST','sparse-reset',1)");
        long untouchedFile = scalar("SELECT pg_relation_filenode('sales_quotes'::regclass)");
        long childFile = scalar("SELECT pg_relation_filenode('stock_reservations'::regclass)");

        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isEqualTo(1);
        assertThat(scalar("SELECT count(*) FROM business_outbox")).isZero();
        assertThat(scalar("SELECT count(*) FROM reset_business_clear_work WHERE table_name IN ('business_outbox','stock_balances','stock_reservations') AND truncate_required")).isEqualTo(3);
        assertThat(scalar("SELECT pg_relation_filenode('sales_quotes'::regclass)")).isEqualTo(untouchedFile);
        assertThat(scalar("SELECT pg_relation_filenode('stock_reservations'::regclass)")).isNotEqualTo(childFile);
        assertThat(scalar("SELECT count(*) FROM reset_business_clear_work WHERE NOT truncate_required")).isGreaterThan(200);

        // An omitted empty table is still locked until the complete reset commits.
        try (Connection other = DriverManager.getConnection(jdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())) {
            other.createStatement().execute("SET lock_timeout = '100ms'");
            other.setAutoCommit(false);
            SQLException blocked = assertThrows(SQLException.class, () -> other.createStatement()
                    .execute("LOCK TABLE sales_quotes IN ROW EXCLUSIVE MODE"));
            assertThat(blocked.getSQLState()).isEqualTo("55P03");
            other.rollback();
        }
    }

    @Test
    void emptyAdvancedOwnedSequenceRestartsAtItsConfiguredStartWithoutRecreatingTable() throws Exception {
        connection.createStatement().execute("ALTER SEQUENCE finance_reconciliations_posting_seq_seq START WITH 17 RESTART WITH 17");
        assertThat(scalar("SELECT nextval('finance_reconciliations_posting_seq_seq')")).isEqualTo(17);
        assertThat(scalar("SELECT nextval('finance_reconciliations_posting_seq_seq')")).isEqualTo(18);
        long tableFile = scalar("SELECT pg_relation_filenode('finance_reconciliations'::regclass)");
        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isZero();
        assertThat(scalar("SELECT pg_relation_filenode('finance_reconciliations'::regclass)")).isEqualTo(tableFile);
        assertThat(scalar("SELECT nextval('finance_reconciliations_posting_seq_seq')")).isEqualTo(17);
    }

    @Test
    void partitionLeafForeignKeyAndOwnedSequenceRetainTheOriginalRecursiveTruncate() throws Exception {
        connection.createStatement().execute("ALTER TABLE business_outbox ADD COLUMN reset_probe_id uuid, ADD COLUMN reset_probe_date date, ADD CONSTRAINT reset_probe_leaf_fk FOREIGN KEY (reset_probe_id,reset_probe_date) REFERENCES production_plan_costs_2026(id,bill_date)");
        connection.createStatement().execute("CREATE SEQUENCE reset_probe_leaf_seq START WITH 23 OWNED BY production_plan_costs_2026.legacy_id");
        assertThat(scalar("SELECT nextval('reset_probe_leaf_seq')")).isEqualTo(23);
        assertThat(scalar("SELECT nextval('reset_probe_leaf_seq')")).isEqualTo(24);
        long leafFile = scalar("SELECT pg_relation_filenode('production_plan_costs_2026'::regclass)");
        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isZero();
        assertThat(scalar("SELECT count(*) FROM reset_business_clear_work WHERE table_name IN ('production_plan_costs','business_outbox') AND truncate_required")).isEqualTo(2);
        assertThat(scalar("SELECT pg_relation_filenode('production_plan_costs_2026'::regclass)")).isNotEqualTo(leafFile);
        assertThat(scalar("SELECT nextval('reset_probe_leaf_seq')")).isEqualTo(23);
    }

    @Test
    void failureAtFinalEpochUpdateRollsBackRowsStorageAndSequenceRestart() throws Exception {
        connection.createStatement().execute("INSERT INTO business_outbox(id,event_type,aggregate_type,dedupe_key,status) VALUES (gen_random_uuid(),'RESET_TEST','RESET_TEST','rollback-reset',1)");
        connection.createStatement().execute("ALTER SEQUENCE finance_reconciliations_posting_seq_seq RESTART WITH 31");
        assertThat(scalar("SELECT nextval('finance_reconciliations_posting_seq_seq')")).isEqualTo(31);
        long originalFile = scalar("SELECT pg_relation_filenode('business_outbox'::regclass)");
        long originalEpoch = scalar("SELECT epoch FROM authorization_state WHERE singleton_id=1");
        Savepoint before = connection.setSavepoint();
        connection.createStatement().execute("CREATE FUNCTION pg_temp.reset_probe_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'reset finalization probe'; END $$");
        connection.createStatement().execute("CREATE TRIGGER reset_probe_failure BEFORE UPDATE ON authorization_state FOR EACH ROW EXECUTE FUNCTION pg_temp.reset_probe_failure()");
        assertThrows(SQLException.class, () -> scalar("SELECT cleared_rows FROM business_data_reset()"));
        connection.rollback(before);
        assertThat(scalar("SELECT count(*) FROM business_outbox")).isEqualTo(1);
        assertThat(scalar("SELECT pg_relation_filenode('business_outbox'::regclass)")).isEqualTo(originalFile);
        assertThat(scalar("SELECT epoch FROM authorization_state WHERE singleton_id=1")).isEqualTo(originalEpoch);
        assertThat(scalar("SELECT nextval('finance_reconciliations_posting_seq_seq')")).isEqualTo(32);
    }

    @Test
    void userTruncateTriggerFallsBackSoItsNewBusinessRowIsAlsoCleared() throws Exception {
        connection.createStatement().execute("CREATE FUNCTION pg_temp.reset_probe_trigger() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN INSERT INTO business_outbox(id,event_type,aggregate_type,dedupe_key,status) VALUES (gen_random_uuid(),'RESET_TEST','RESET_TEST','trigger-reset',1); RETURN NULL; END $$");
        connection.createStatement().execute("CREATE TRIGGER reset_probe_trigger BEFORE TRUNCATE ON sales_quotes FOR EACH STATEMENT EXECUTE FUNCTION pg_temp.reset_probe_trigger()");
        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isZero();
        assertThat(scalar("SELECT count(*) FROM business_outbox")).isZero();
        assertThat(scalar("SELECT count(*) FROM reset_business_clear_work WHERE NOT truncate_required")).isZero();
    }

    @Test
    void traditionalInheritanceFallsBackToTheFullOriginalScope() throws Exception {
        connection.createStatement().execute("CREATE TEMP TABLE reset_probe_inherited () INHERITS (public.business_outbox)");
        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isZero();
        assertThat(scalar("SELECT count(*) FROM reset_business_clear_work WHERE NOT truncate_required")).isZero();
    }

    @Test
    void preservedTableReferencingAPartitionStillRejectsTheReset() throws Exception {
        connection.createStatement().execute("ALTER TABLE goods ADD COLUMN reset_probe_id uuid, ADD COLUMN reset_probe_date date, ADD CONSTRAINT reset_probe_preserve_fk FOREIGN KEY(reset_probe_id,reset_probe_date) REFERENCES production_plan_costs_2026(id,bill_date)");
        SQLException rejected = assertThrows(SQLException.class, () -> scalar("SELECT cleared_rows FROM business_data_reset()"));
        assertThat(rejected.getSQLState()).isEqualTo("UT900");
    }

    @Test
    void externalSchemaForeignKeyToAnEmptySkippedTableStillRejectsTheReset() throws Exception {
        connection.createStatement().execute("CREATE SCHEMA reset_probe_external");
        connection.createStatement().execute("CREATE TABLE reset_probe_external.quote_refs (quote_id uuid REFERENCES public.sales_quotes(id))");
        SQLException rejected = assertThrows(SQLException.class, () -> scalar("SELECT cleared_rows FROM business_data_reset()"));
        assertThat(rejected.getSQLState()).isEqualTo("UT900");
    }

    @Test
    void missingTruncatePrivilegeOnAnEmptySkippedTableStillRejectsTheReset() throws Exception {
        connection.createStatement().execute("CREATE ROLE reset_probe_limited");
        connection.createStatement().execute("GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO reset_probe_limited");
        connection.createStatement().execute("REVOKE TRUNCATE ON sales_quotes FROM reset_probe_limited");
        connection.createStatement().execute("SET LOCAL ROLE reset_probe_limited");
        assertThat(scalar("SELECT has_table_privilege('sales_quotes','TRUNCATE')::integer")).isZero();
        SQLException rejected = assertThrows(SQLException.class, () -> scalar("SELECT cleared_rows FROM business_data_reset()"));
        assertThat(rejected.getSQLState()).isEqualTo("42501");
        assertThat(rejected.getMessage()).contains("TRUNCATE");
    }

    @Test
    void ownerThatRevokedItsOwnTruncatePrivilegeStillRejectsTheReset() throws Exception {
        connection.createStatement().execute("CREATE ROLE reset_probe_owner");
        connection.createStatement().execute("ALTER TABLE sales_quotes OWNER TO reset_probe_owner");
        connection.createStatement().execute("GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO reset_probe_owner");
        connection.createStatement().execute("REVOKE TRUNCATE ON sales_quotes FROM reset_probe_owner");
        connection.createStatement().execute("SET LOCAL ROLE reset_probe_owner");
        assertThat(scalar("SELECT has_table_privilege('sales_quotes','TRUNCATE')::integer")).isZero();
        SQLException rejected = assertThrows(SQLException.class, () -> scalar("SELECT cleared_rows FROM business_data_reset()"));
        assertThat(rejected.getSQLState()).isEqualTo("42501");
        assertThat(rejected.getMessage()).contains("TRUNCATE");
    }

    @Test
    void forcedRowSecurityCannotHideRowsFromThePhysicalReset() throws Exception {
        connection.createStatement().execute("INSERT INTO business_outbox(id,event_type,aggregate_type,dedupe_key,status) VALUES (gen_random_uuid(),'RESET_TEST','RESET_TEST','rls-reset',1)");
        connection.createStatement().execute("CREATE ROLE reset_probe_rls");
        connection.createStatement().execute("GRANT uten TO reset_probe_rls");
        connection.createStatement().execute("ALTER TABLE business_outbox ENABLE ROW LEVEL SECURITY");
        connection.createStatement().execute("ALTER TABLE business_outbox FORCE ROW LEVEL SECURITY");
        connection.createStatement().execute("CREATE POLICY reset_probe_deny ON business_outbox USING (false)");
        connection.createStatement().execute("SET LOCAL ROLE reset_probe_rls");
        assertThat(scalar("SELECT current_setting('is_superuser')::boolean::integer")).isZero();
        assertThat(scalar("SELECT row_security_active('business_outbox'::regclass)::integer")).isEqualTo(1);
        assertThat(scalar("SELECT count(*) FROM business_outbox")).isZero();
        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isZero();
        connection.createStatement().execute("SET LOCAL ROLE uten");
        assertThat(scalar("SELECT count(*) FROM business_outbox")).isZero();
    }

    @Test
    void repeatableReadSnapshotCannotLeaveALaterCommittedRowBehind() throws Exception {
        connection.rollback();
        connection.setTransactionIsolation(Connection.TRANSACTION_REPEATABLE_READ);
        connection.createStatement().execute("SET LOCAL statement_timeout = '120s'");
        connection.createStatement().execute("SET LOCAL lock_timeout = '2s'");
        assertThat(scalar("SELECT count(*) FROM business_outbox")).isZero();
        try (Connection writer = DriverManager.getConnection(jdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())) {
            writer.createStatement().execute("INSERT INTO business_outbox(id,event_type,aggregate_type,dedupe_key,status) VALUES (gen_random_uuid(),'RESET_TEST','RESET_TEST','later-commit-reset',1)");
        }
        assertThat(scalar("SELECT count(*) FROM business_outbox")).isZero();
        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isZero();
        assertThat(scalar("SELECT count(*) FROM reset_business_clear_work WHERE NOT truncate_required")).isZero();
        connection.commit();
        try (Connection reader = DriverManager.getConnection(jdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
             var statement = reader.createStatement(); var result = statement.executeQuery("SELECT count(*) FROM business_outbox")) {
            assertThat(result.next()).isTrue();
            assertThat(result.getLong(1)).isZero();
        }
    }

    @Test
    void operatorAndRuntimeUseTheSameSparseAlgorithm() throws Exception {
        String ops = Files.readString(Path.of("ops", "reset_business_data.sql"));
        String migration = Files.readString(Path.of("src", "main", "resources", "db", "migration", "V558__business_reset_sparse_truncate.sql"));
        assertThat(fragment(ops)).isEqualTo(fragment(migration));
        try (var statement = connection.createStatement(); var result = statement.executeQuery("SELECT pg_get_functiondef('business_data_reset()'::regprocedure)")) {
            assertThat(result.next()).isTrue();
            assertThat(fragment(result.getString(1))).isEqualTo(fragment(ops));
        }
    }

    private static String fragment(String sql) {
        return sql.substring(sql.indexOf("    -- V558 sparse reset:"), sql.indexOf("    -- End V558 sparse reset.")).replace("\r\n", "\n");
    }

    private static String jdbcUrl() {
        String url = POSTGRES.getJdbcUrl();
        return url + (url.contains("?") ? "&" : "?") + "connectTimeout=5&socketTimeout=180";
    }

    private long scalar(String sql) throws SQLException {
        try (var statement = connection.createStatement(); var result = statement.executeQuery(sql)) {
            assertThat(result.next()).isTrue();
            return result.getLong(1);
        }
    }
}
