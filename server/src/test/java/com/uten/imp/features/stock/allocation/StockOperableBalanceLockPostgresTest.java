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
import org.junit.jupiter.api.BeforeEach;
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
 * The isolated projection fixture uses the real V928 predicates/view, not a full business schema. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class StockOperableBalanceLockPostgresTest {
    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("operable_lock_fixture");
    private static final String PASSWORD = "runtime-lock-fixture-only";
    private static final UUID WAREHOUSE = UUID.randomUUID(), GOODS = UUID.randomUUID();
    private static final UUID BALANCE = UUID.randomUUID(), UNIT = UUID.randomUUID();

    @BeforeAll static void createIsolatedProjection() throws Exception {
        PG.start();
        try (Connection admin = admin()) {
            execute(admin, """
                    CREATE ROLE lock_migrator NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
                    CREATE ROLE uten LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
                      NOBYPASSRLS PASSWORD 'runtime-lock-fixture-only';
                    REVOKE CREATE ON SCHEMA public FROM PUBLIC, uten;
                    GRANT USAGE, CREATE ON SCHEMA public TO lock_migrator;
                    SET ROLE lock_migrator;
                    CREATE TABLE units(id uuid PRIMARY KEY, legacy_id integer, name text, is_deleted boolean DEFAULT false);
                    CREATE TABLE goods(id uuid PRIMARY KEY, unit_id uuid, unit_legacy_id integer,
                      auto_created boolean DEFAULT false, is_deleted boolean DEFAULT false, min_qty numeric DEFAULT 0);
                    CREATE TABLE stock_balances(id uuid PRIMARY KEY, warehouse_id uuid NOT NULL,
                      goods_id uuid NOT NULL, color_id uuid, qty numeric NOT NULL);
                    CREATE TABLE stock_measurement_holds(id uuid PRIMARY KEY, warehouse_id uuid,
                      goods_id uuid, color_id uuid, released_at timestamptz);
                    CREATE TABLE stock_reservations(warehouse_id uuid, goods_id uuid, color_id uuid,
                      qty numeric, consumed_qty numeric DEFAULT 0, released_qty numeric DEFAULT 0,
                      is_deleted boolean DEFAULT false, status integer DEFAULT 0);
                    CREATE FUNCTION fn_warehouse_main_id(uuid) RETURNS uuid LANGUAGE sql IMMUTABLE AS 'SELECT $1';
                    """);
            String migration;
            try (var resource = StockOperableBalanceLockPostgresTest.class.getResourceAsStream(
                    "/db/migration/V928__stock_unresolved_unit_operability.sql")) {
                migration = new String(resource.readAllBytes(), StandardCharsets.UTF_8);
            }
            execute(admin, definition(migration, "CREATE FUNCTION fn_stock_has_resolved_base_unit(", "$$;"));
            execute(admin, definition(migration, "CREATE FUNCTION fn_stock_measurement_usable(", "$$;"));
            execute(admin, definition(migration, "CREATE VIEW v_stock_operable_balances AS", ";"));
            execute(admin, """
                    GRANT USAGE ON SCHEMA public TO uten;
                    GRANT SELECT ON goods, units, stock_balances, stock_measurement_holds, stock_reservations TO uten;
                    GRANT UPDATE ON stock_balances TO uten;
                    REVOKE ALL ON v_stock_operable_balances FROM PUBLIC, uten;
                    GRANT SELECT ON v_stock_operable_balances TO uten;
                    REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
                    GRANT EXECUTE ON FUNCTION fn_stock_has_resolved_base_unit(uuid),
                      fn_stock_measurement_usable(uuid,uuid,uuid), fn_warehouse_main_id(uuid) TO uten;
                    RESET ROLE;
                    """);
        }
    }

    @AfterAll static void stop() { PG.stop(); }

    @BeforeEach void seed() throws Exception {
        try (Connection admin = admin()) {
            execute(admin, "TRUNCATE stock_balances, stock_measurement_holds, stock_reservations, goods, units");
            execute(admin, "INSERT INTO units(id,name) VALUES ('" + UNIT + "','piece')");
            execute(admin, "INSERT INTO goods(id,unit_id) VALUES ('" + GOODS + "','" + UNIT + "')");
            execute(admin, "INSERT INTO stock_balances VALUES ('" + BALANCE + "','" + WAREHOUSE
                    + "','" + GOODS + "',NULL,500)");
        }
    }

    @Test void realRuntimeCanReadButFormerViewRowLockIsDenied() throws Exception {
        try (Connection runtime = runtime()) {
            assertEquals("uten/uten", scalar(runtime, "SELECT session_user||'/'||current_user"));
            assertEquals("f", scalar(runtime, "SELECT rolsuper FROM pg_roles WHERE rolname=current_user"));
            assertEquals("f", scalar(runtime, "SELECT has_schema_privilege(current_user,'public','CREATE')"));
            assertEquals("t", scalar(runtime, "SELECT has_table_privilege(current_user,'stock_balances','UPDATE')"));
            assertEquals("t", scalar(runtime, "SELECT has_table_privilege(current_user,'v_stock_operable_balances','SELECT')"));
            assertEquals("f", scalar(runtime, "SELECT has_table_privilege(current_user,'v_stock_operable_balances','UPDATE')"));
            assertEquals(BALANCE.toString(), scalar(runtime, "SELECT id FROM v_stock_operable_balances"));
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
            assertEquals(List.of(BALANCE), query.ids(runtime));
            SQLException conflict = assertThrows(SQLException.class,
                    () -> execute(competing, "SELECT id FROM stock_balances WHERE id='" + BALANCE + "' FOR UPDATE NOWAIT"));
            assertEquals("55P03", conflict.getSQLState(), "The actual physical balance must be locked");
            competing.rollback();
            runtime.rollback();
            execute(competing, "SELECT id FROM stock_balances WHERE id='" + BALANCE + "' FOR UPDATE NOWAIT");
            competing.rollback();
            assertEquals("f", scalar(runtime, "SELECT has_table_privilege(current_user,'v_stock_operable_balances','UPDATE')"));
            runtime.rollback();
        }
    }

    @ParameterizedTest(name = "{0}: pending original measurement stays excluded until fixture release")
    @MethodSource("serviceQueries")
    void actualServiceSqlPreservesPendingMeasurementFilter(CapturedSql query) throws Exception {
        UUID hold = UUID.randomUUID();
        try (Connection admin = admin()) {
            execute(admin, "INSERT INTO stock_measurement_holds VALUES ('" + hold + "','" + WAREHOUSE
                    + "','" + GOODS + "',NULL,NULL)");
        }
        try (Connection runtime = runtime(); Connection competing = runtime()) {
            assertEquals(List.of(), query.ids(runtime));
            // An excluded row is not accidentally locked by the base-table query.
            execute(competing, "SELECT id FROM stock_balances WHERE id='" + BALANCE + "' FOR UPDATE NOWAIT");
            competing.rollback();
            runtime.rollback();
        }
        try (Connection admin = admin()) {
            // This only seeds the isolated predicate oracle; production evidence verification is not bypassed.
            execute(admin, "UPDATE stock_measurement_holds SET released_at=now() WHERE id='" + hold + "'");
        }
        try (Connection runtime = runtime()) {
            assertEquals(List.of(BALANCE), query.ids(runtime));
            runtime.rollback();
        }
        try (Connection admin = admin()) {
            assertEquals("500", scalar(admin, "SELECT qty FROM stock_balances WHERE id='" + BALANCE + "'"));
            assertEquals("1", scalar(admin, "SELECT count(*) FROM stock_measurement_holds WHERE id='" + hold + "'"));
        }
    }

    @ParameterizedTest(name = "{0}: unresolved master unit is excluded")
    @MethodSource("serviceQueries")
    void actualServiceSqlPreservesResolvedUnitRequirement(CapturedSql query) throws Exception {
        try (Connection admin = admin()) { execute(admin, "UPDATE goods SET unit_id=NULL WHERE id='" + GOODS + "'"); }
        try (Connection runtime = runtime()) {
            assertEquals(List.of(), query.ids(runtime));
            runtime.rollback();
        }
    }

    static Stream<CapturedSql> serviceQueries() {
        List<CapturedSql> captured = new ArrayList<>();
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> capture(call.getArgument(0), captured, false));
        when(em.createNativeQuery(anyString(), eq(UUID.class)))
                .thenAnswer(call -> capture(call.getArgument(0), captured, true));
        var facade = new ProductionMaterialAllocationFacade(em,
                mock(InventoryMutationLock.class), mock(TxSessionVars.class));
        var request = new ProductionMaterialAllocationFacade.AllocationRequest(
                UUID.randomUUID(), UUID.randomUUID(), GOODS, null, WAREHOUSE,
                BigDecimal.ONE, "operable-lock-oracle", UUID.randomUUID());
        ReflectionTestUtils.invokeMethod(facade, "allocationBatch", List.of(request), Map.of());
        var purchase = new ProductionPurchaseSupplyTransitionService(em,
                null, null, null, null, null, null, null, null, null);
        ReflectionTestUtils.invokeMethod(purchase, "lockBalance", WAREHOUSE, GOODS, null);
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
                        new LinkedHashMap<>(parameters)));
                return typed ? List.of(BALANCE) : List.of();
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

    private record CapturedSql(String operation, String sql, Map<String,Object> parameters) {
        List<UUID> ids(Connection connection) {
            var jdbc = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
            return jdbc.query(sql, parameters, (rows,index) -> rows.getObject(1, UUID.class));
        }
        @Override public String toString() { return operation; }
    }

    private static String definition(String source, String marker, String terminator) {
        int start = source.indexOf(marker), end = source.indexOf(terminator, start);
        assertTrue(start >= 0 && end > start, "Real migration definition missing: " + marker);
        return source.substring(start, end + terminator.length());
    }

    private static Connection admin() throws SQLException {
        return DriverManager.getConnection(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword());
    }
    private static Connection runtime() throws SQLException {
        Connection connection = DriverManager.getConnection(PG.getJdbcUrl(), "uten", PASSWORD);
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
