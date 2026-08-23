package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.Set;
import java.util.TreeSet;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** PostgreSQL catalog/replay proof for the V309-V314 entitlement schema, guards and audit sweep. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class CrossAnalysisReallocationMigrationPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp_reallocation")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .validateMigrationNaming(true)
                .target("314")
                .load()
                .migrate();
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void schemaExposesStableHeaderEventAndFormalBridgeColumns() throws Exception {
        try (Connection connection = connection()) {
            assertEquals(Set.of(
                    "from_analysis_id", "from_analysis_material_id",
                    "to_analysis_id", "to_analysis_material_id",
                    "priority_fulfilled_qty",
                    "close_idempotency_key", "close_request_hash",
                    "source_version", "source_fingerprint",
                    "target_version", "target_fingerprint", "lock_version"),
                    columns(connection, "preplan_material_reallocations", Set.of(
                            "from_analysis_id", "from_analysis_material_id",
                            "to_analysis_id", "to_analysis_material_id",
                            "priority_fulfilled_qty",
                            "close_idempotency_key", "close_request_hash",
                            "source_version", "source_fingerprint",
                            "target_version", "target_fingerprint", "lock_version")));
            assertEquals(Set.of(
                    "stock_reservation_id", "beneficiary_analysis_id",
                    "beneficiary_analysis_material_id", "event_type", "qty",
                    "source_entitlement_event_id", "reallocation_id",
                    "source_exact_peg_id", "target_package_id",
                    "target_demand_id", "target_stock_reservation_id",
                    "counter_event_id", "idempotency_key"),
                    columns(connection, "preplan_stock_entitlement_events", Set.of(
                            "stock_reservation_id", "beneficiary_analysis_id",
                            "beneficiary_analysis_material_id", "event_type", "qty",
                            "source_entitlement_event_id", "reallocation_id",
                            "source_exact_peg_id", "target_package_id",
                            "target_demand_id", "target_stock_reservation_id",
                            "counter_event_id", "idempotency_key")));
        }
    }

    @Test
    void bothBalanceViewsExistAndLegacyRowsWereNotInvented() throws Exception {
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            try (ResultSet result = statement.executeQuery("""
                    SELECT count(*)
                    FROM pg_views
                    WHERE schemaname = 'public'
                      AND viewname IN (
                          'v_preplan_stock_entitlement_lot_balance',
                          'v_preplan_stock_entitlement_beneficiary_balance')
                    """)) {
                assertTrue(result.next());
                assertEquals(2, result.getInt(1));
            }
            try (ResultSet result = statement.executeQuery("""
                    SELECT count(*) FROM preplan_stock_entitlement_events
                    """)) {
                assertTrue(result.next());
                assertEquals(0, result.getInt(1));
            }
        }
    }

    @Test
    void bothNewTablesHaveExactlyOneEnabledStandardAuditTrigger() throws Exception {
        try (Connection connection = connection()) {
            assertAuditTrigger(connection, "preplan_material_reallocations");
            assertAuditTrigger(connection, "preplan_stock_entitlement_events");
        }
    }

    @Test
    void exactPegNowHasMutuallyExclusiveMakeProvenanceColumns() throws Exception {
        try (Connection connection = connection()) {
            assertEquals(Set.of(
                    "source_disposition_event_id",
                    "source_stock_document_id",
                    "source_stock_document_item_id"),
                    columns(connection, "preplan_analysis_stock_exact_pegs", Set.of(
                            "source_disposition_event_id",
                            "source_stock_document_id",
                            "source_stock_document_item_id")));
            try (Statement statement = connection.createStatement();
                 ResultSet result = statement.executeQuery("""
                         SELECT is_nullable
                         FROM information_schema.columns
                         WHERE table_schema = 'public'
                           AND table_name = 'preplan_analysis_stock_exact_pegs'
                           AND column_name = 'source_disposition_event_id'
                         """)) {
                assertTrue(result.next());
                assertEquals("YES", result.getString(1));
            }
        }
    }

    @Test
    void installedOriginGuardUsesNullSafeReceiptIdentityComparisons()
            throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement();
             ResultSet function = statement.executeQuery("""
                     SELECT pg_get_functiondef(procedure_row.oid)
                     FROM pg_proc procedure_row
                     JOIN pg_namespace namespace_row
                       ON namespace_row.oid = procedure_row.pronamespace
                     WHERE namespace_row.nspname = 'public'
                       AND procedure_row.proname =
                           'fn_check_preplan_stock_entitlement_event'
                     """)) {
            assertTrue(function.next());
            // pg_get_functiondef 保留迁移里的换行；空白归一化后再做文本契约匹配。
            String definition = function.getString(1).toLowerCase()
                    .replaceAll("\\s+", " ");
            assertTrue(definition.contains(
                    "new.source_receipt_type is distinct from exact.source_receipt_type"));
            assertTrue(definition.contains(
                    "new.source_receipt_id is distinct from exact.source_receipt_id"));
            // V337 起 ORIGIN_IQC 只允许来自采购/委外收货（原 'is distinct from make' 收紧为白名单）。
            assertTrue(definition.contains(
                    "exact.source_receipt_type not in ('purchase', 'subcontract')"));
        }
        try (Connection connection = connection();
             Statement statement = connection.createStatement();
             ResultSet nullCases = statement.executeQuery("""
                     SELECT NULL::text IS DISTINCT FROM 'PURCHASE'::text,
                            NULL::uuid IS DISTINCT FROM gen_random_uuid(),
                            NULL::text IS DISTINCT FROM 'MAKE'::text
                     """)) {
            assertTrue(nullCases.next());
            assertTrue(nullCases.getBoolean(1));
            assertTrue(nullCases.getBoolean(2));
            assertTrue(nullCases.getBoolean(3));
        }
    }

    private static Set<String> columns(
            Connection connection, String table, Set<String> selected) throws Exception {
        Set<String> result = new TreeSet<>();
        try (var statement = connection.prepareStatement("""
                SELECT column_name
                FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = ?
                ORDER BY ordinal_position
                """)) {
            statement.setString(1, table);
            try (ResultSet rows = statement.executeQuery()) {
                while (rows.next()) {
                    String column = rows.getString(1);
                    if (selected.contains(column)) result.add(column);
                }
            }
        }
        return result;
    }

    private static void assertAuditTrigger(Connection connection, String table)
            throws Exception {
        try (var statement = connection.prepareStatement("""
                SELECT count(*) AS prefixed_count,
                       count(*) FILTER (WHERE
                           trigger_row.tgenabled IN ('O', 'A')
                           AND (trigger_row.tgtype::integer & 1) = 1
                           AND (trigger_row.tgtype::integer & 2) = 0
                           AND (trigger_row.tgtype::integer & 4) = 4
                           AND (trigger_row.tgtype::integer & 8) = 8
                           AND (trigger_row.tgtype::integer & 16) = 16
                           AND function_schema.nspname = 'public'
                           AND trigger_function.proname IN (
                               'fn_audit', 'fn_audit_redacted')) AS valid_count
                FROM pg_trigger trigger_row
                JOIN pg_proc trigger_function
                  ON trigger_function.oid = trigger_row.tgfoid
                JOIN pg_namespace function_schema
                  ON function_schema.oid = trigger_function.pronamespace
                WHERE trigger_row.tgrelid = to_regclass('public.' || ?)
                  AND NOT trigger_row.tgisinternal
                  AND trigger_row.tgname LIKE 'trg_audit%'
                """)) {
            statement.setString(1, table);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                assertEquals(1, result.getInt("prefixed_count"));
                assertEquals(1, result.getInt("valid_count"));
            }
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
}
