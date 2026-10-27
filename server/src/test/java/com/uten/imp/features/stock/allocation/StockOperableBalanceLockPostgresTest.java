package com.uten.imp.features.stock.allocation;

import com.uten.imp.features.production.fulfillment.ProductionPurchaseSupplyTransitionService;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Stream;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.postgresql.PostgreSQLContainer;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real PG16 authorization/locking oracle for the SQL emitted by both production services.
 *
 * <p>The database is the real migration directory at its current head — no hand-written
 * fixture DDL to drift (the reason this class exists: its former 6-column {@code goods}
 * projection rotted against the real schema). Cluster-wide login roles cannot share
 * {@link com.uten.imp.support.MigratedSchemaBaseline}'s pool (its javadoc reserves
 * dedicated containers for role scenarios), so this class owns its server with the
 * deployment split-role topology: {@code uten_migrator} migrates and owns the schema,
 * and the canonical {@code db/local-runtime-privileges.sql} installs the runtime ACL
 * for {@code uten} — ordinary tables carry UPDATE, views stay SELECT-only.
 *
 * <p>Each parameterized invocation seeds its own goods/balance dimension inside the
 * capture factory, so the actual service SQL is bound to invocation-private rows and
 * the immutable released evidence of {@code stock_measurement_holds} (unique per
 * warehouse/goods/color, never deletable) never collides between invocations. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class StockOperableBalanceLockPostgresTest {
    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("operable_lock_fixture");
    private static final String PASSWORD = "runtime-lock-fixture-" + UUID.randomUUID();
    private static final UUID WAREHOUSE = UUID.randomUUID(), UNIT = UUID.randomUUID();
    private static final UUID REVIEWER = UUID.randomUUID();

    /** The dimension the service-query capture factory is currently binding to. */
    private static UUID captureGoods, captureBalance;

    @BeforeAll static void migrateRealSchemaAndInstallCanonicalRuntimeAcl() throws Exception {
        PG.start();
        try (Connection admin = admin()) {
            try (var password = admin.prepareStatement(
                    "SELECT set_config('uten.fixture_role_password',?,false)")) {
                password.setString(1, PASSWORD);
                password.execute();
            }
            execute(admin, """
                    DO $fixture$
                    BEGIN
                      EXECUTE format('CREATE ROLE uten_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD %L',
                                     current_setting('uten.fixture_role_password'));
                      EXECUTE format('CREATE ROLE uten LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD %L',
                                     current_setting('uten.fixture_role_password'));
                    END $fixture$;
                    """);
            // local-runtime-privileges.sql pins its dev boundary to this exact database name.
            execute(admin, "CREATE DATABASE uten_imp OWNER uten_migrator TEMPLATE template0");
        }
        try (Connection bootstrap = DriverManager.getConnection(url(), PG.getUsername(), PG.getPassword())) {
            // Provenance migrations read the cluster identity as the migration owner.
            execute(bootstrap, "GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO uten_migrator");
        }
        com.uten.imp.testsupport.TestFlyway.configure()
                .dataSource(url(), "uten_migrator", PASSWORD)
                .locations("classpath:db/migration").load().migrate();
        seedSharedMasterRows();
        try (Connection owner = owner()) {
            String privileges;
            try (var resource = StockOperableBalanceLockPostgresTest.class.getResourceAsStream(
                    "/db/local-runtime-privileges.sql")) {
                privileges = new String(resource.readAllBytes(), StandardCharsets.UTF_8);
            }
            execute(owner, privileges);
        }
    }

    private static void seedSharedMasterRows() throws Exception {
        try (Connection owner = owner()) {
            owner.setAutoCommit(false);
            execute(owner, "SELECT set_config('app.legacy_import','on',true)");
            execute(owner, "INSERT INTO units(id,code,name) VALUES('" + UNIT + "','OPERABLE-LOCK-UNIT','lock fixture unit')");
            String root = scalar(owner, "SELECT fn_warehouse_root_id()");
            if (root == null) {
                root = UUID.randomUUID().toString();
                execute(owner, "INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES('"
                        + root + "','001','lock fixture root','使用',true)");
            }
            execute(owner, "INSERT INTO warehouses(id,code,name,status,is_accountable,parent_id) VALUES('"
                    + WAREHOUSE + "','OPERABLE-LOCK-W','lock fixture warehouse','使用',true,'" + root + "')");
            execute(owner, "INSERT INTO users(id,employee_id,login_account,password_hash) SELECT '" + REVIEWER
                    + "',id,'operable-lock-reviewer','fixture-only' FROM employees WHERE code='ADMIN'");
            assertEquals("1", scalar(owner, "SELECT count(*) FROM users WHERE id='" + REVIEWER + "'"),
                    "the V08 ADMIN employee must provide the fixture reviewer login");
            owner.commit();
        }
    }

    /** Seeds one invocation-private goods+balance pair; the resolved unit lets the real
     * V928 INSERT guard accept a non-zero quantity row, and weight stays NULL per
     * stock_balances_weight_shape_chk (qty>0 needs weight>0 or NULL). */
    private static void seedDimension(UUID goods, UUID balance) throws Exception {
        try (Connection owner = owner()) {
            execute(owner, "INSERT INTO goods(id,code,name,code_sequence,unit_id) VALUES('" + goods
                    + "','OPERABLE-LOCK-" + goods.toString().substring(0, 8) + "','lock fixture goods',"
                    + "(SELECT COALESCE(max(code_sequence),0)+1 FROM goods),'" + UNIT + "')");
            execute(owner, "INSERT INTO stock_balances(id,warehouse_id,goods_id,qty,amount_local,weight,weight_estimated)"
                    + " VALUES('" + balance + "','" + WAREHOUSE + "','" + goods + "',500,0,NULL,false)");
        }
    }

    @AfterAll static void stop() { PG.stop(); }

    @Test void realRuntimeCanReadButFormerViewRowLockIsDenied() throws Exception {
        UUID goods = UUID.randomUUID(), balance = UUID.randomUUID();
        seedDimension(goods, balance);
        try (Connection runtime = runtime()) {
            assertEquals("uten/uten", scalar(runtime, "SELECT session_user||'/'||current_user"));
            assertEquals("f", scalar(runtime, "SELECT rolsuper FROM pg_roles WHERE rolname=current_user"));
            assertEquals("f", scalar(runtime, "SELECT has_schema_privilege(current_user,'public','CREATE')"));
            assertEquals("t", scalar(runtime, "SELECT has_table_privilege(current_user,'stock_balances','UPDATE')"));
            assertEquals("t", scalar(runtime, "SELECT has_table_privilege(current_user,'v_stock_operable_balances','SELECT')"));
            assertEquals("f", scalar(runtime, "SELECT has_table_privilege(current_user,'v_stock_operable_balances','UPDATE')"));
            assertEquals(balance.toString(), scalar(runtime,
                    "SELECT id FROM v_stock_operable_balances WHERE goods_id='" + goods + "'"));
            SQLException denied = assertThrows(SQLException.class,
                    () -> execute(runtime, "SELECT id FROM v_stock_operable_balances FOR UPDATE"));
            assertEquals("42501", denied.getSQLState());
            runtime.rollback();
        }
    }

    @ParameterizedTest(name = "{0}: locks the physical balance without view UPDATE authority")
    @MethodSource("serviceQueries")
    void actualServiceSqlLocksTheBaseRowAndReleasesItOnRollback(CapturedSql query) throws Exception {
        try (Connection runtime = runtime(); Connection competing = runtime()) {
            assertEquals(List.of(query.balance()), query.ids(runtime));
            SQLException conflict = assertThrows(SQLException.class,
                    () -> execute(competing, "SELECT id FROM stock_balances WHERE id='" + query.balance() + "' FOR UPDATE NOWAIT"));
            assertEquals("55P03", conflict.getSQLState(), "The actual physical balance must be locked");
            competing.rollback();
            runtime.rollback();
            execute(competing, "SELECT id FROM stock_balances WHERE id='" + query.balance() + "' FOR UPDATE NOWAIT");
            competing.rollback();
            assertEquals("f", scalar(runtime, "SELECT has_table_privilege(current_user,'v_stock_operable_balances','UPDATE')"));
            runtime.rollback();
        }
    }

    @ParameterizedTest(name = "{0}: pending original measurement stays excluded until reviewed release")
    @MethodSource("serviceQueries")
    void actualServiceSqlPreservesPendingMeasurementFilter(CapturedSql query) throws Exception {
        UUID hold;
        try (Connection owner = owner()) {
            // Offline-restore-style fixture ingestion of the pending cohort; the production
            // capture function itself is covered by StockMeasurementOperabilityPostgresTest.
            // The captured snapshot mirrors the balance row exactly as fn_verify requires.
            execute(owner, """
                    INSERT INTO stock_measurement_holds(stock_balance_id,warehouse_id,goods_id,color_id,
                      captured_qty,captured_amount_local,captured_weight,captured_weight_estimated)
                    VALUES ('%s','%s','%s',NULL,500,0,NULL,false)"""
                    .formatted(query.balance(), WAREHOUSE, query.goods()));
            hold = UUID.fromString(scalar(owner,
                    "SELECT id FROM stock_measurement_holds WHERE goods_id='" + query.goods() + "'"));
        }
        try (Connection runtime = runtime(); Connection competing = runtime()) {
            assertEquals(List.of(), query.ids(runtime));
            // An excluded row is not accidentally locked by the base-table query.
            execute(competing, "SELECT id FROM stock_balances WHERE id='" + query.balance() + "' FOR UPDATE NOWAIT");
            competing.rollback();
            runtime.rollback();
        }
        try (Connection owner = owner()) {
            // The real reviewed release path (reviewer + immutable evidence + unchanged
            // original snapshot) is the only sanctioned way this cohort stops excluding.
            execute(owner, "SELECT fn_verify_stock_original_measurement_basis('" + hold + "','" + UNIT + "','"
                    + REVIEWER + "','fixture://operable-lock/original-basis','" + "a".repeat(64)
                    + "','Fixture release of the synthetic pending original measurement cohort.')");
        }
        try (Connection runtime = runtime()) {
            assertEquals(List.of(query.balance()), query.ids(runtime));
            runtime.rollback();
        }
        try (Connection owner = owner()) {
            assertEquals("500.0000", scalar(owner, "SELECT qty FROM stock_balances WHERE id='" + query.balance() + "'"));
            assertEquals("1", scalar(owner, "SELECT count(*) FROM stock_measurement_holds WHERE id='" + hold + "'"));
        }
    }

    @ParameterizedTest(name = "{0}: unresolved master unit is excluded")
    @MethodSource("serviceQueries")
    void actualServiceSqlPreservesResolvedUnitRequirement(CapturedSql query) throws Exception {
        // Fixture-only bypass of the V675 in-use unit guard (the goods already carries a
        // balance); production reconciles the original basis, it never NULLs the unit.
        String triggerState;
        try (Connection owner = owner()) {
            triggerState = scalar(owner, "SELECT tgenabled FROM pg_trigger WHERE tgrelid='goods'::regclass"
                    + " AND tgname='trg_goods_quantity_unit_immutable'");
            execute(owner, "ALTER TABLE goods DISABLE TRIGGER trg_goods_quantity_unit_immutable");
            execute(owner, "UPDATE goods SET unit_id=NULL WHERE id='" + query.goods() + "'");
        }
        try {
            try (Connection runtime = runtime()) {
                assertEquals(List.of(), query.ids(runtime));
                runtime.rollback();
            }
        } finally {
            try (Connection owner = owner()) {
                execute(owner, "UPDATE goods SET unit_id='" + UNIT + "' WHERE id='" + query.goods() + "'");
                execute(owner, "ALTER TABLE goods " + ("A".equals(triggerState) ? "ENABLE ALWAYS" : "ENABLE")
                        + " TRIGGER trg_goods_quantity_unit_immutable");
            }
        }
    }

    static Stream<CapturedSql> serviceQueries() throws Exception {
        List<CapturedSql> captured = new ArrayList<>();
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> capture(call.getArgument(0), captured, false));
        when(em.createNativeQuery(anyString(), eq(UUID.class)))
                .thenAnswer(call -> capture(call.getArgument(0), captured, true));
        // One fresh dimension per captured service query: each parameterized invocation
        // then owns a private goods/balance pair (and a private hold dimension).
        captureGoods = UUID.randomUUID();
        captureBalance = UUID.randomUUID();
        seedDimension(captureGoods, captureBalance);
        var facade = new ProductionMaterialAllocationFacade(em,
                mock(InventoryMutationLock.class), mock(TxSessionVars.class));
        var request = new ProductionMaterialAllocationFacade.AllocationRequest(
                UUID.randomUUID(), UUID.randomUUID(), captureGoods, null, WAREHOUSE,
                BigDecimal.ONE, "operable-lock-oracle", UUID.randomUUID());
        ReflectionTestUtils.invokeMethod(facade, "allocationBatch", List.of(request), Map.of());
        captureGoods = UUID.randomUUID();
        captureBalance = UUID.randomUUID();
        seedDimension(captureGoods, captureBalance);
        var purchase = new ProductionPurchaseSupplyTransitionService(em,
                null, null, null, null, null, null, null, null, null);
        ReflectionTestUtils.invokeMethod(purchase, "lockBalance", WAREHOUSE, captureGoods, null);
        assertEquals(2, captured.size(), "Both actual production methods must emit their balance-lock query");
        return captured.stream();
    }

    private static Query capture(String sql, List<CapturedSql> captured, boolean typed) {
        Map<String,Object> parameters = new LinkedHashMap<>();
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), nullable(Object.class))).thenAnswer(call -> {
            parameters.put(call.getArgument(0), call.getArgument(1));
            return query;
        });
        when(query.getResultList()).thenAnswer(call -> {
            if (sql.contains("v_stock_operable_balances") && sql.contains("FOR UPDATE")) {
                captured.add(new CapturedSql(typed ? "purchase receipt reservation" : "production allocation", sql,
                        new LinkedHashMap<>(parameters), captureGoods, captureBalance));
                return typed ? List.of(captureBalance) : List.of();
            }
            if (sql.contains("SELECT id,fn_warehouse_main_id(id)"))
                return Collections.singletonList(new Object[]{WAREHOUSE, WAREHOUSE});
            if (sql.contains("SELECT warehouse.id,fn_warehouse_main_id"))
                return Collections.singletonList(new Object[]{WAREHOUSE, WAREHOUSE, false});
            if (sql.contains("FROM stock_reservations")) return List.of();
            throw new AssertionError("Unexpected service query: " + sql);
        });
        return query;
    }

    private record CapturedSql(String operation, String sql, Map<String,Object> parameters,
                               UUID goods, UUID balance) {
        List<UUID> ids(Connection connection) {
            var jdbc = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
            return jdbc.query(sql, parameters, (rows,index) -> rows.getObject(1, UUID.class));
        }
        @Override public String toString() { return operation; }
    }

    private static String url() {
        return "jdbc:postgresql://" + PG.getHost() + ":" + PG.getMappedPort(5432) + "/uten_imp";
    }
    private static Connection admin() throws SQLException {
        return DriverManager.getConnection(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword());
    }
    private static Connection owner() throws SQLException {
        return DriverManager.getConnection(url(), "uten_migrator", PASSWORD);
    }
    private static Connection runtime() throws SQLException {
        Connection connection = DriverManager.getConnection(url(), "uten", PASSWORD);
        connection.setAutoCommit(false);
        return connection;
    }
    private static void execute(Connection connection, String sql) throws SQLException {
        try (var statement = connection.createStatement()) { statement.execute(sql); }
    }
    private static String scalar(Connection connection, String sql) throws SQLException {
        try (var statement = connection.createStatement(); var result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getString(1);
        }
    }
}
