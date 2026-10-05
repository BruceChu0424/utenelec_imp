package com.uten.imp.ops;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.springframework.core.NestedExceptionUtils;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.catchThrowable;

/**
 * The classification lives only in business_data_reset() (ADR-155): the installed function, its
 * parsed read-only view and the executed temp table all equal the independently reviewed oracle,
 * and the in-database re-verification refuses direct calls that would leave test files behind.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class BusinessDataResetCatalogPostgresTest {
    private MigratedSchemaBaseline.ScopedDatabase database;
    private JdbcTemplate jdbc;
    private TransactionTemplate tx;

    @BeforeEach
    void open() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("reset_catalog");
        var source = new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword());
        jdbc = new JdbcTemplate(source);
        tx = new TransactionTemplate(new DataSourceTransactionManager(source));
    }

    @AfterEach
    void close() throws Exception {
        if (database != null) database.close();
    }

    @Test
    void installedClassificationEqualsTheReviewedOracle() throws Exception {
        Map<String, String> expected = BusinessDataResetSqlContractTest.expectedCurrentPolicy();
        assertThat(parsedPolicy()).isEqualTo(expected);
        String definition = jdbc.queryForObject("SELECT pg_get_functiondef('public.business_data_reset()'::regprocedure)", String.class);
        assertThat(BusinessDataResetSqlContractTest.policy(definition)).isEqualTo(expected);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM fn_business_reset_table_policy()", Long.class))
                .as("no duplicate rows").isEqualTo(expected.size());
        assertThat(jdbc.queryForList("SELECT reason_code || ': ' || message FROM fn_business_data_reset_refusals()", String.class))
                .as("a freshly migrated database has nothing to refuse").isEmpty();
    }

    @Test
    void executedClassificationEqualsTheParsedClassification() {
        tx.executeWithoutResult(status -> {
            jdbc.queryForList("SELECT * FROM business_data_reset()");
            Map<String, String> executed = new LinkedHashMap<>();
            jdbc.query("SELECT table_name, disposition FROM reset_business_table_policy ORDER BY table_name",
                    row -> { assertThat(executed.put(row.getString(1), row.getString(2))).isNull(); });
            assertThat(executed).isEqualTo(parsedPolicy());
            status.setRollbackOnly();
        });
    }

    @Test
    void resetFunctionKeepsItsAttributesAndTheIntentChainIsGone() {
        var reset = jdbc.queryForMap("SELECT prosecdef, proconfig::text AS config FROM pg_proc WHERE oid='public.business_data_reset()'::regprocedure");
        assertThat(reset).containsEntry("prosecdef", true).containsEntry("config", "{\"search_path=pg_catalog, public, pg_temp\"}");
        for (String relation : List.of("public.business_test_object_cleanup_intents", "public.v_business_test_object_sources")) {
            assertThat(jdbc.queryForObject("SELECT to_regclass(?) IS NULL", Boolean.class, relation)).as(relation).isTrue();
        }
        for (String function : List.of("public.fn_business_test_object_sources()", "public.fn_assert_business_test_objects_cleared()",
                "public.fn_business_attachment_reset_blockers()", "public.fn_test_object_lock_sources()",
                "public.fn_test_object_intent_guard()", "public.fn_test_object_require_actor(uuid,uuid,bigint)",
                "public.fn_test_object_claim(uuid,uuid,bigint)",
                "public.fn_test_object_complete(uuid,uuid,uuid,bigint,bigint,text,boolean,text)")) {
            assertThat(jdbc.queryForObject("SELECT to_regprocedure(?) IS NULL", Boolean.class, function)).as(function).isTrue();
        }
        assertThat(jdbc.queryForList("""
                SELECT proname FROM pg_proc WHERE pronamespace='public'::regnamespace
                  AND prosrc ~ '(v_business_test_object_sources|fn_business_test_object_sources|business_test_object_cleanup_intents|fn_test_object_|fn_assert_business_test_objects_cleared|fn_business_attachment_reset_blockers)'
                """, String.class)).isEmpty();
        Map<String, Boolean> definer = new LinkedHashMap<>();
        jdbc.query("""
                SELECT proname, prosecdef FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN (
                  'fn_business_test_reset_objects','fn_business_test_reset_object_fingerprint','fn_business_reset_table_policy',
                  'fn_business_data_reset_refusals','fn_business_test_reset_require_caller','fn_business_test_reset_lock_sources',
                  'fn_business_test_reset_verify_purged','fn_clear_business_test_object_metadata')
                """, row -> { definer.put(row.getString(1), row.getBoolean(2)); });
        assertThat(definer).containsOnly(
                Map.entry("fn_business_test_reset_objects", false), Map.entry("fn_business_test_reset_object_fingerprint", false),
                Map.entry("fn_business_reset_table_policy", false), Map.entry("fn_business_data_reset_refusals", false),
                Map.entry("fn_business_test_reset_require_caller", true), Map.entry("fn_business_test_reset_lock_sources", true),
                Map.entry("fn_business_test_reset_verify_purged", false), Map.entry("fn_clear_business_test_object_metadata", false));
        assertThat(jdbc.queryForObject("SELECT pg_get_functiondef('public.business_data_reset()'::regprocedure)", String.class))
                .doesNotContain("business_attachment_reset_prepare", "business_test_object_cleanup_prepare", "psql")
                .contains("fn_business_data_reset_refusals()", "USING ERRCODE = 'XX000'");
    }

    @Test
    void directCallWithTestFilesStillListedIsRefusedAndChangesNothing() {
        String key = listedSelfContainedTicket();
        long generation = generation();
        SQLException refused = sqlFailure(() -> tx.executeWithoutResult(status -> jdbc.queryForList("SELECT * FROM business_data_reset()")));
        assertThat(refused.getSQLState()).isEqualTo("UT901");
        assertThat(serverMessage(refused)).isEqualTo(
                "还有 1 个测试文件没有删除。清空必须从工作台「系统测试 > 清空数据」执行，它会先删除这些文件再清空数据；本次没有清空任何数据。");
        assertThat(generation()).isEqualTo(generation);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox WHERE storage_key=?", Long.class, key)).isEqualTo(1);
    }

    @Test
    void wrongDeclaredFingerprintIsReportedAsAProgramDefect() {
        listedSelfContainedTicket();
        SQLException refused = sqlFailure(() -> tx.executeWithoutResult(status -> {
            jdbc.queryForObject("SELECT set_config('app.business_test_reset_objects', ?, true)", String.class, "5:" + "a".repeat(64));
            jdbc.queryForList("SELECT * FROM business_data_reset()");
        }));
        assertThat(refused.getSQLState()).isEqualTo("UT901");
        assertThat(serverMessage(refused)).isEqualTo(
                "原因：清空前核对的测试文件清单(5 个)和清空时数据库里的清单(1 个)不一致，这是程序缺陷。本次没有清空任何数据，请联系开发人员。");
    }

    @Test
    void matchingFingerprintClearsTheListedMetadataInTheSameLockedTransaction() {
        String key = listedSelfContainedTicket();
        long generation = generation();
        tx.executeWithoutResult(status -> {
            jdbc.queryForObject("SELECT fn_business_test_reset_lock_sources()::text", String.class);
            String fingerprint = jdbc.queryForObject("SELECT fn_business_test_reset_object_fingerprint()", String.class);
            assertThat(fingerprint).startsWith("1:");
            jdbc.queryForObject("SELECT set_config('app.business_test_reset_objects', ?, true)", String.class, fingerprint);
            jdbc.queryForList("SELECT * FROM business_data_reset()");
        });
        assertThat(generation()).isEqualTo(generation + 1);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox WHERE storage_key=?", Long.class, key)).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM fn_business_test_reset_objects()", Long.class)).isZero();
    }

    @Test
    void theRefusalCheckRunsFirstInsideTheResetFunction() {
        jdbc.update("INSERT INTO business_outbox(id,event_type,aggregate_type,dedupe_key,status,available_at) VALUES(gen_random_uuid(),'TEST_EVENT','TEST','catalog-'||gen_random_uuid(),0,now()+interval '150 seconds')");
        SQLException refused = sqlFailure(() -> tx.executeWithoutResult(status -> jdbc.queryForList("SELECT * FROM business_data_reset()")));
        assertThat(refused.getSQLState()).isEqualTo("UT900");
        assertThat(serverMessage(refused)).isEqualTo(
                "后台还有 1 条事件正在排队处理(消息通知、单据联动等)，预计 3 分钟内处理完。现在清空会丢掉这些处理结果，请 3 分钟后点「重新检查」再清空；"
                        + "如果多次重新检查仍在排队，请联系开发人员检查后台事件处理。");
    }

    @Test
    void aMissingSignOutRowIsRefusedBeforeAnyFileIsDeleted() {
        tx.executeWithoutResult(status -> {
            jdbc.execute("ALTER TABLE public.authorization_state DISABLE TRIGGER USER");
            jdbc.update("DELETE FROM public.authorization_state");
            assertThat(jdbc.queryForList("SELECT reason_code || '|' || item_count || '|' || message FROM fn_business_data_reset_refusals()", String.class))
                    .containsExactly("AUTHORIZATION_STATE_MISSING|0|数据库里记录全员登录状态的数据应当正好有 1 条，现在有 0 条，清空最后一步无法让所有人重新登录。"
                            + "这是数据库被人为改动或程序缺陷，请联系开发人员修复后再清空。");
            status.setRollbackOnly();
        });
        assertThat(jdbc.queryForObject("SELECT count(*) FROM authorization_state", Long.class)).as("rolled back").isEqualTo(1);
    }

    private String listedSelfContainedTicket() {
        String key = UUID.randomUUID().toString().replace("-", "") + ".pdf";
        jdbc.update("""
                INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key,status)
                VALUES('DELETE_STAGING','internal',?,NULL,?,'PENDING')
                """, key, "internal|DELETE_STAGING|" + key + "|catalog");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM fn_business_test_reset_objects()", Long.class)).isEqualTo(1);
        return key;
    }

    private Map<String, String> parsedPolicy() {
        Map<String, String> parsed = new LinkedHashMap<>();
        jdbc.query("SELECT table_name, disposition FROM fn_business_reset_table_policy() ORDER BY table_name",
                row -> { assertThat(parsed.put(row.getString(1), row.getString(2))).as("duplicate " + row.getString(1)).isNull(); });
        return parsed;
    }

    private long generation() {
        return jdbc.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1", Long.class);
    }

    private static SQLException sqlFailure(Runnable action) {
        Throwable failure = catchThrowable(action::run);
        assertThat(failure).isNotNull();
        Throwable cause = NestedExceptionUtils.getMostSpecificCause(failure);
        assertThat(cause).isInstanceOf(SQLException.class);
        return (SQLException) cause;
    }

    private static String serverMessage(SQLException error) {
        return error instanceof PSQLException psql && psql.getServerErrorMessage() != null
                ? psql.getServerErrorMessage().getMessage() : error.getMessage();
    }
}
