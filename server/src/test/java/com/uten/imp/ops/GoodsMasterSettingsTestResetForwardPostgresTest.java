package com.uten.imp.ops;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.math.BigDecimal;
import java.sql.*;
import java.util.*;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

/** Actual V783 -> V784, with nonzero, zero and NULL master settings. No real business database. */
@Testcontainers(disabledWithoutDocker = true)
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsMasterSettingsTestResetForwardPostgresTest {
    @Container
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("goods_master_reset_forward").withUsername("fixture_admin");
    private static String predecessor;
    private static String forward;
    private static String securityBefore;
    private Connection connection;

    @BeforeAll static void migrateActualPredecessorAndForward() throws Exception {
        try (var connection = connect(); var sql = connection.createStatement()) {
            // A real restricted runtime role exercises the existing V625 authorization contract.
            sql.execute("CREATE ROLE uten NOLOGIN NOSUPERUSER NOINHERIT");
        }
        Flyway.configure().dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").target("783").load().migrate();
        try (var connection = connect(); var sql = connection.createStatement()) {
            predecessor = function(sql);
            securityBefore = security(sql);
        }
        assertThat(Flyway.configure().dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").target("784").load().migrate().migrationsExecuted).isEqualTo(1);
        try (var connection = connect(); var sql = connection.createStatement()) {
            forward = function(sql);
            assertThat(security(sql)).isEqualTo(securityBefore);
            assertThat(withoutGoodsRules(forward)).as("all other installed reset function bytes").isEqualTo(withoutGoodsRules(predecessor));
            assertThat(forward).contains("PERFORM public.fn_require_runtime_maintenance(true);",
                    "PERFORM public.fn_clear_business_test_object_metadata();",
                    "business_reset_generation = business_reset_generation + 1");
            assertThat(forward).doesNotContain("min_qty = 0", "source_e = 0", "g_total = 0",
                    "货品安全库存/成本预算归零校验失败");
        }
    }

    @BeforeEach void begin() throws Exception {
        connection = connect();
        connection.setAutoCommit(false);
        try (var sql = connection.createStatement()) {
            sql.execute("SET LOCAL jit = off; SET LOCAL statement_timeout = '120s'");
        }
    }
    @AfterEach void rollback() throws Exception {
        if (connection != null) { connection.rollback(); connection.close(); }
    }

    @Test void actualOldResetChangesNullAndNonzeroMasterSettingsButForwardKeepsEveryOtherColumn() throws Exception {
        UUID nulls = seed(null, true), zeros = seed(BigDecimal.ZERO, true), nonzeros = seed(new BigDecimal("1.2345"), true);
        var before = snapshots(nulls, zeros, nonzeros);
        try (var sql = connection.createStatement()) {
            sql.execute(predecessor);
            Savepoint beforeOldReset = connection.setSavepoint();
            sql.execute("SELECT * FROM public.business_data_reset()");
            assertThat(snapshot(nulls, true)).as("old NULL -> zero mutation is genuinely reproduced").isNotEqualTo(before.get(nulls));
            assertThat(snapshot(nonzeros, true)).as("old nonzero configuration is genuinely lost").isNotEqualTo(before.get(nonzeros));
            connection.rollback(beforeOldReset);
            sql.execute(forward);
            sql.execute("SELECT * FROM public.business_data_reset()");
            for (UUID id : List.of(nulls, zeros, nonzeros)) {
                assertThat(snapshot(id, true)).as("all non-opening columns, including the 21 master parameters").isEqualTo(before.get(id));
                try (var row = sql.executeQuery("SELECT init_stock,init_count,init_weight,version,updated_at > TIMESTAMPTZ '2001-01-01 00:00:00+00' FROM goods WHERE id='" + id + "'")) {
                    assertThat(row.next()).isTrue();
                    assertThat(row.getInt(1)).isZero();
                    assertThat(row.getBigDecimal(2)).isEqualByComparingTo(BigDecimal.ZERO);
                    assertThat(row.getBigDecimal(3)).isEqualByComparingTo(BigDecimal.ZERO);
                    assertThat(row.getLong(4)).isEqualTo(8);
                    assertThat(row.getBoolean(5)).isTrue();
                }
            }
            String afterFirst = snapshot(nonzeros, false);
            sql.execute("SELECT * FROM public.business_data_reset()");
            assertThat(snapshot(nonzeros, false)).as("a second reset must not churn goods version/time").isEqualTo(afterFirst);
        }
    }

    @Test void zeroOrNullOpeningsDoNotUpdateNullZeroOrNonzeroMasterSettingsVersionOrTimestamp() throws Exception {
        UUID nulls = seed(null, false), zeros = seed(BigDecimal.ZERO, false), nonzeros = seed(new BigDecimal("2.3456"), false);
        try (var sql = connection.createStatement()) {
            sql.execute("UPDATE goods SET init_stock=NULL,init_count=NULL,init_weight=NULL WHERE id='" + nulls + "'");
        }
        Map<UUID, String> before = new LinkedHashMap<>();
        for (UUID id : List.of(nulls, zeros, nonzeros)) before.put(id, snapshot(id, false));
        try (var sql = connection.createStatement()) { sql.execute("SELECT * FROM public.business_data_reset()"); }
        for (var row : before.entrySet()) assertThat(snapshot(row.getKey(), false)).isEqualTo(row.getValue());
    }

    @Test void authorizationAndFailureRollbackRemainIntactAfterTheGoodsOnlyPatch() throws Exception {
        UUID id = seed(new BigDecimal("3.4567"), true);
        String before = snapshot(id, false);
        long generation = scalar("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1");
        try (var sql = connection.createStatement()) {
            Savepoint unauthorized = connection.setSavepoint();
            sql.execute("SET SESSION AUTHORIZATION uten");
            SQLException refusal = assertThrows(SQLException.class, () -> sql.execute("SELECT * FROM public.business_data_reset()"));
            assertThat(refusal.getSQLState()).isEqualTo("42501");
            assertThat((Throwable) refusal).hasMessageContaining("authenticated active super-admin");
            connection.rollback(unauthorized);
            assertThat(snapshot(id, false)).isEqualTo(before);
            assertThat(scalar("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1")).isEqualTo(generation);
            sql.execute("INSERT INTO business_outbox(id,event_type,aggregate_type,dedupe_key,status) VALUES(gen_random_uuid(),'RESET_TEST','RESET_TEST','goods-master-guard',0)");
            Savepoint unsettled = connection.setSavepoint();
            SQLException pending = assertThrows(SQLException.class, () -> sql.execute("SELECT * FROM public.business_data_reset()"));
            assertThat(pending.getSQLState()).isEqualTo("UT900");
            connection.rollback(unsettled);
            assertThat(snapshot(id, false)).isEqualTo(before);
            assertThat(scalar("SELECT count(*) FROM business_outbox WHERE dedupe_key='goods-master-guard'")).isEqualTo(1);
            assertThat(scalar("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1")).isEqualTo(generation);
        }
    }

    private UUID seed(BigDecimal settings, boolean opening) throws Exception {
        UUID id = UUID.randomUUID();
        try (var insert = connection.prepareStatement("""
                INSERT INTO goods(id,code,name,code_sequence,init_stock,init_count,init_weight,
                    min_qty,source_e,work_e,lacquer_e,incidental_e,plating_e,casing_e,manage_e,polish_e,
                    electric_e,machining_e,lost_e,rent_e,make_e,work_rate,lost_rate,make_rate,rent_rate,total,c_total,g_total,
                    price,a_price,price2,max_qty,version,updated_at)
                SELECT ?,?,'goods master preservation',(SELECT COALESCE(max(code_sequence),0)+1 FROM goods),?,?,?,
                    ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,11.2233,22.3344,33.4455,44.5566,7,TIMESTAMPTZ '2001-01-01 00:00:00+00'
                """)) {
            insert.setObject(1, id); insert.setString(2, "GRESET-" + id);
            insert.setInt(3, opening ? 17 : 0);
            insert.setBigDecimal(4, opening ? new BigDecimal("2.5000") : BigDecimal.ZERO);
            insert.setBigDecimal(5, opening ? new BigDecimal("3.7500") : BigDecimal.ZERO);
            for (int parameter = 6; parameter <= 26; parameter++) {
                if (settings == null) insert.setNull(parameter, Types.NUMERIC); else insert.setBigDecimal(parameter, settings);
            }
            assertThat(insert.executeUpdate()).isEqualTo(1);
        }
        return id;
    }
    private Map<UUID, String> snapshots(UUID... ids) throws Exception {
        Map<UUID, String> result = new LinkedHashMap<>();
        for (UUID id : ids) result.put(id, snapshot(id, true));
        return result;
    }
    private String snapshot(UUID id, boolean excludeOpeningAndTracking) throws Exception {
        String expression = excludeOpeningAndTracking
                ? "to_jsonb(g)-ARRAY['init_stock','init_count','init_weight','version','updated_at']" : "to_jsonb(g)";
        try (var query = connection.prepareStatement("SELECT (" + expression + ")::text FROM goods g WHERE id=?")) {
            query.setObject(1, id);
            try (var row = query.executeQuery()) { assertThat(row.next()).isTrue(); return row.getString(1); }
        }
    }
    private long scalar(String query) throws Exception {
        try (var sql = connection.createStatement(); var row = sql.executeQuery(query)) { assertThat(row.next()).isTrue(); return row.getLong(1); }
    }
    private static Connection connect() throws SQLException {
        return DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
    private static String function(Statement sql) throws SQLException {
        try (var row = sql.executeQuery("SELECT pg_get_functiondef('public.business_data_reset()'::regprocedure)")) { row.next(); return row.getString(1); }
    }
    private static String withoutGoodsRules(String source) {
        String result = source.replace("\r\n", "\n");
        int update = result.indexOf("    UPDATE goods\n");
        int payment = result.indexOf("    UPDATE payment_styles\n", update);
        assertThat(update).isGreaterThanOrEqualTo(0); assertThat(payment).isGreaterThan(update);
        result = result.substring(0, update) + result.substring(payment);
        int check = result.indexOf("    SELECT count(*)\n    INTO n\n    FROM goods\n    WHERE min_qty IS DISTINCT FROM 0");
        if (check >= 0) {
            int next = result.indexOf("    FOR t IN\n", check);
            assertThat(next).isGreaterThan(check);
            result = result.substring(0, check) + result.substring(next);
        }
        return result.replace("    -- Goods safety stock and cost settings remain master configuration.\n\n", "");
    }
    private static String security(Statement sql) throws SQLException {
        try (var row = sql.executeQuery("SELECT jsonb_build_array(proowner,proacl,prosecdef,proconfig)::text FROM pg_proc WHERE oid='public.business_data_reset()'::regprocedure")) { row.next(); return row.getString(1); }
    }
}
