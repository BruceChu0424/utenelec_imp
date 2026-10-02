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

/** Historical V777 reset/storage contract. V778 permanent policy separately blocks current reset execution. */
@Testcontainers(disabledWithoutDocker = true)
class BusinessDataResetSparsePostgresTest {
    @Container
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16.15-alpine")
            .withDatabaseName("uten_sparse_reset").withUsername("uten").withPassword("uten");

    private Connection connection;

    @BeforeAll
    static void migrate() throws SQLException {
        Flyway.configure().dataSource(jdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").target("777").load().migrate();
        // V673 起 production_plan_costs 是普通单表, 清单里已没有分区的清空表; 分区路径仍是重置函数的合同。
        // 在这个一次性测试库里把这张 CLEAR 表换成同名的三列按年分区探针(提交后才有真实的分区文件,
        // 同一事务新建的表截断时 PostgreSQL 会原地清空、不换文件节点), 继续钉住分区叶子的行为。
        // 探针先以测试专用名建出再改名顶替, 已在 FixtureSchemaDriftGuardPostgresTest 登记为测试私有关系。
        try (Connection setup = DriverManager.getConnection(jdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())) {
            setup.createStatement().execute("DROP TABLE production_plan_costs");
            setup.createStatement().execute("CREATE TABLE reset_probe_partitioned_costs (id uuid NOT NULL, bill_date date NOT NULL,"
                    + " legacy_id integer, PRIMARY KEY (id, bill_date)) PARTITION BY RANGE (bill_date)");
            setup.createStatement().execute("ALTER TABLE reset_probe_partitioned_costs RENAME TO production_plan_costs");
            setup.createStatement().execute("CREATE TABLE production_plan_costs_2026 PARTITION OF production_plan_costs"
                    + " FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')");
        }
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
    void registeredRetentionTriggersRequireFullTruncateWhileKeepingForeignKeyClosure() throws Exception {
        connection.createStatement().execute("ALTER TABLE stock_balances ADD COLUMN reset_probe_outbox_id uuid REFERENCES business_outbox(id)");
        connection.createStatement().execute("ALTER TABLE stock_reservations ADD COLUMN reset_probe_balance_id uuid REFERENCES stock_balances(id)");
        connection.createStatement().execute("INSERT INTO business_outbox(id,event_type,aggregate_type,dedupe_key,status) VALUES (gen_random_uuid(),'RESET_TEST','RESET_TEST','sparse-reset',1)");
        long untouchedFile = scalar("SELECT pg_relation_filenode('sales_quotes'::regclass)");
        long childFile = scalar("SELECT pg_relation_filenode('stock_reservations'::regclass)");

        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isEqualTo(1);
        assertThat(scalar("SELECT count(*) FROM business_outbox")).isZero();
        assertThat(scalar("SELECT count(*) FROM reset_business_clear_work WHERE table_name IN ('business_outbox','stock_balances','stock_reservations') AND truncate_required")).isEqualTo(3);
        assertThat(scalar("SELECT pg_relation_filenode('sales_quotes'::regclass)")).isNotEqualTo(untouchedFile);
        assertThat(scalar("SELECT pg_relation_filenode('stock_reservations'::regclass)")).isNotEqualTo(childFile);
        assertThat(scalar("SELECT count(*) FROM reset_business_clear_work WHERE NOT truncate_required")).isZero();

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
    void emptySequenceRestartsWithConservativeFullFallbackForRetentionTriggers() throws Exception {
        connection.createStatement().execute("ALTER SEQUENCE finance_reconciliations_posting_seq_seq START WITH 17 RESTART WITH 17");
        assertThat(scalar("SELECT nextval('finance_reconciliations_posting_seq_seq')")).isEqualTo(17);
        assertThat(scalar("SELECT nextval('finance_reconciliations_posting_seq_seq')")).isEqualTo(18);
        long tableFile = scalar("SELECT pg_relation_filenode('finance_reconciliations'::regclass)");
        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isZero();
        assertThat(scalar("SELECT pg_relation_filenode('finance_reconciliations'::regclass)")).isNotEqualTo(tableFile);
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
    void knownTriggerNameWithChangedImplementationStillFallsBack() throws Exception {
        connection.createStatement().execute("CREATE OR REPLACE FUNCTION public.fn_sales_quote_template_candidates_truncate() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN INSERT INTO business_outbox(id,event_type,aggregate_type,dedupe_key,status) VALUES (gen_random_uuid(),'RESET_TEST','RESET_TEST','changed-known-trigger',1); RETURN NULL; END $$");
        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isZero();
        assertThat(scalar("SELECT count(*) FROM business_outbox")).isZero();
        assertThat(scalar("SELECT count(*) FROM reset_business_clear_work WHERE NOT truncate_required")).isZero();
    }

    @Test
    void unknownOutboxInsertTriggerRestoresFullFallbackEvenForEmptyCandidates() throws Exception {
        connection.createStatement().execute("CREATE FUNCTION pg_temp.reset_probe_outbox_insert() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN INSERT INTO business_outbox(id,event_type,aggregate_type,dedupe_key,status) VALUES (gen_random_uuid(),'RESET_TEST','RESET_TEST','outbox-insert-effect',1); RETURN NULL; END $$");
        connection.createStatement().execute("CREATE TRIGGER reset_probe_outbox_insert AFTER INSERT ON attachment_object_outbox FOR EACH STATEMENT EXECUTE FUNCTION pg_temp.reset_probe_outbox_insert()");
        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isZero();
        assertThat(scalar("SELECT count(*) FROM business_outbox")).isZero();
        assertThat(scalar("SELECT count(*) FROM reset_business_clear_work WHERE NOT truncate_required")).isZero();
    }

    @Test
    void changedKnownTriggerConfigurationCannotUseTheSparseException() throws Exception {
        connection.createStatement().execute("ALTER FUNCTION public.fn_sales_quote_template_candidates_truncate() RESET search_path");
        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isZero();
        assertThat(scalar("SELECT count(*) FROM reset_business_clear_work WHERE NOT truncate_required")).isZero();
    }

    @Test
    void customOutboxCheckRoutineRestoresFullFallback() throws Exception {
        connection.createStatement().execute("CREATE FUNCTION pg_temp.reset_probe_check(integer) RETURNS boolean LANGUAGE plpgsql AS $$ BEGIN RETURN true; END $$");
        connection.createStatement().execute("ALTER TABLE attachment_object_outbox ADD CONSTRAINT reset_probe_check CHECK (pg_temp.reset_probe_check(attempts))");
        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isZero();
        assertThat(scalar("SELECT count(*) FROM reset_business_clear_work WHERE NOT truncate_required")).isZero();
    }

    @Test
    void builtinStateChangingOutboxCheckStillRestoresFullFallback() throws Exception {
        connection.createStatement().execute("ALTER TABLE attachment_object_outbox ADD CONSTRAINT reset_probe_builtin_check CHECK (pg_catalog.set_config('app.reset_probe','changed',true) IS NOT NULL)");
        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isZero();
        assertThat(scalar("SELECT count(*) FROM reset_business_clear_work WHERE NOT truncate_required")).isZero();
    }

    @Test
    void restoredPureArrayCastsDoNotOverrideRegisteredRetentionTriggerFallback() throws Exception {
        // pg_dump/restore reparses the IN array coercion as per-element casts.
        // Both exact pure forms are allowed; arbitrary expression normalization is not.
        connection.createStatement().execute("ALTER TABLE attachment_object_outbox DROP CONSTRAINT attachment_object_outbox_operation_chk, ADD CONSTRAINT attachment_object_outbox_operation_chk CHECK ((operation)::text = ANY (ARRAY[('DELETE_STAGING'::varchar)::text,('DELETE_FINAL'::varchar)::text]))");
        connection.createStatement().execute("ALTER TABLE attachment_object_outbox DROP CONSTRAINT attachment_object_outbox_provider_chk, ADD CONSTRAINT attachment_object_outbox_provider_chk CHECK ((storage_provider)::text = ANY (ARRAY[('internal'::varchar)::text,('oss'::varchar)::text,('local'::varchar)::text,('legacy_unknown'::varchar)::text]))");
        connection.createStatement().execute("ALTER TABLE attachment_object_outbox DROP CONSTRAINT attachment_object_outbox_status_chk, ADD CONSTRAINT attachment_object_outbox_status_chk CHECK ((status)::text = ANY (ARRAY[('PENDING'::varchar)::text,('PROCESSING'::varchar)::text,('SUCCEEDED'::varchar)::text,('FAILED'::varchar)::text]))");
        connection.createStatement().execute("DROP INDEX attachment_object_outbox_ready_idx");
        connection.createStatement().execute("CREATE INDEX attachment_object_outbox_ready_idx ON attachment_object_outbox(available_at,created_at) WHERE (status)::text = ANY (ARRAY[('PENDING'::varchar)::text,('FAILED'::varchar)::text])");
        long originalFile = scalar("SELECT pg_relation_filenode('sales_quotes'::regclass)");
        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isZero();
        assertThat(scalar("SELECT pg_relation_filenode('sales_quotes'::regclass)")).isNotEqualTo(originalFile);
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
    void callerWithoutExecuteIsRejectedWhileDefinerPrivilegesCoverMissingTruncate() throws Exception {
        connection.createStatement().execute("CREATE ROLE reset_probe_limited");
        connection.createStatement().execute("GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO reset_probe_limited");
        connection.createStatement().execute("REVOKE TRUNCATE ON sales_quotes FROM reset_probe_limited");
        connection.createStatement().execute("SET LOCAL ROLE reset_probe_limited");
        assertThat(scalar("SELECT has_table_privilege('sales_quotes','TRUNCATE')::integer")).isZero();
        // V625 keeps the entry SECURITY DEFINER with EXECUTE restricted to the
        // owner and the runtime login, so the probe role is rejected at the entry.
        Savepoint entry = connection.setSavepoint();
        SQLException rejected = assertThrows(SQLException.class, () -> scalar("SELECT cleared_rows FROM business_data_reset()"));
        assertThat(rejected.getSQLState()).isEqualTo("42501");
        assertThat(rejected.getMessage()).contains("permission denied for function business_data_reset");
        connection.rollback(entry);
        // With EXECUTE granted, the definer's own privileges complete the reset;
        // the caller no longer needs TRUNCATE on any table in scope.
        connection.createStatement().execute("SET LOCAL ROLE NONE");
        connection.createStatement().execute("GRANT EXECUTE ON FUNCTION public.business_data_reset() TO reset_probe_limited");
        connection.createStatement().execute("SET LOCAL ROLE reset_probe_limited");
        assertThat(scalar("SELECT has_table_privilege('sales_quotes','TRUNCATE')::integer")).isZero();
        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isZero();
    }

    @Test
    void ownerThatRevokedItsOwnTruncatePrivilegeStillRejectsUnauthorizedCallers() throws Exception {
        connection.createStatement().execute("CREATE ROLE reset_probe_owner");
        connection.createStatement().execute("ALTER TABLE sales_quotes OWNER TO reset_probe_owner");
        connection.createStatement().execute("GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO reset_probe_owner");
        connection.createStatement().execute("REVOKE TRUNCATE ON sales_quotes FROM reset_probe_owner");
        connection.createStatement().execute("SET LOCAL ROLE reset_probe_owner");
        assertThat(scalar("SELECT has_table_privilege('sales_quotes','TRUNCATE')::integer")).isZero();
        // Even a table owner that revoked its own TRUNCATE cannot stop the
        // V625 definer reset once EXECUTE is granted for the maintenance entry.
        Savepoint entry = connection.setSavepoint();
        SQLException rejected = assertThrows(SQLException.class, () -> scalar("SELECT cleared_rows FROM business_data_reset()"));
        assertThat(rejected.getSQLState()).isEqualTo("42501");
        assertThat(rejected.getMessage()).contains("permission denied for function business_data_reset");
        connection.rollback(entry);
        connection.createStatement().execute("SET LOCAL ROLE NONE");
        connection.createStatement().execute("GRANT EXECUTE ON FUNCTION public.business_data_reset() TO reset_probe_owner");
        connection.createStatement().execute("SET LOCAL ROLE reset_probe_owner");
        assertThat(scalar("SELECT has_table_privilege('sales_quotes','TRUNCATE')::integer")).isZero();
        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isZero();
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
        // The V625 SECURITY DEFINER reset counts and truncates with the definer
        // identity, so forced row security neither hides the row from the count
        // nor protects it from the physical TRUNCATE.
        assertThat(scalar("SELECT cleared_rows FROM business_data_reset()")).isEqualTo(1);
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
        String forward = Files.readString(Path.of("src", "main", "resources", "db", "migration", "V758__business_reset_bounded_candidate_cleanup.sql")).replace("\r\n", "\n");
        String oldBlock = forward.substring(forward.indexOf("$old$") + 5, forward.indexOf("$old$;"));
        String newBlock = forward.substring(forward.indexOf("$new$") + 5, forward.indexOf("$new$;"));
        assertThat(fragment(migration)).containsOnlyOnce(oldBlock);
        String historicalExpected = fragment(migration).replace(oldBlock, newBlock);
        // Current operator script delegates to the installed authoritative function, not a copied old algorithm.
        assertThat(ops).contains("SELECT * FROM public.business_data_reset();")
                .doesNotContain("    -- V558 sparse reset:");
        try (var statement = connection.createStatement(); var result = statement.executeQuery("SELECT pg_get_functiondef('business_data_reset()'::regprocedure)")) {
            assertThat(result.next()).isTrue();
            assertThat(fragment(result.getString(1))).isEqualTo(historicalExpected);
        }
    }

    private static String fragment(String sql) {
        int start = sql.indexOf("    -- V558 sparse reset:");
        int end = sql.indexOf("    -- End V558 sparse reset.", start);
        assertThat(start).as("Historical sparse reset start marker").isGreaterThanOrEqualTo(0);
        assertThat(end).as("Historical sparse reset end marker").isGreaterThan(start);
        return sql.substring(start, end).replace("\r\n", "\n");
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
