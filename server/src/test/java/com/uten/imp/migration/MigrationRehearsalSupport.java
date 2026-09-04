package com.uten.imp.migration;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.HexFormat;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

import static org.assertj.core.api.Assertions.assertThat;

/** Shared, fail-closed reconciliation rules for synthetic and real-clone migration rehearsals. */
final class MigrationRehearsalSupport {

    static final String CURRENT_HEAD_VERSION = "467";
    static final int CURRENT_MIGRATION_COUNT = 429;

    /** Reviewed post-V238 system/evidence row-count mutations on pre-existing tables. */
    private static final Set<String> EXPECTED_ROW_COUNT_MUTATIONS = Set.of(
            "audit_log",
            "client_categories",
            // V403 intentionally seeds one deterministic functional-currency UUID when empty.
            "currencies",
            "department_permissions",
            "manager_permission_delegations",
            "material_categories",
            "mould_categories",
            // V373/V376/V379 有意播种的 GL 科目（索赔应收/委外异常损耗/客户预收），已复核。
            "payment_styles",
            "permissions",
            "role_permissions",
            "supplier_categories",
            "user_permission_overrides");

    private MigrationRehearsalSupport() {
    }

    static Snapshot snapshot(Connection connection) throws SQLException {
        return new Snapshot(
                tableRows(connection),
                scalarText(connection, """
                        SELECT count(*) || '|' ||
                               COALESCE(string_agg(
                                   id::text || ':' || login_account,
                                   ',' ORDER BY id), '')
                        FROM users
                        """),
                groupedCounts(
                        connection,
                        "SELECT scope, count(*) FROM user_data_scopes GROUP BY scope"),
                paymentTotals(connection),
                stockTotals(connection));
    }

    static void assertStableSnapshot(Snapshot before, Snapshot after) {
        assertStableSnapshot(before, after, false);
    }

    /**
     * [auditFreshStartExpected] 在回放窗口跨越 V425（审计日志全新开始，按管理者
     * 决定 TRUNCATE audit_log/audit_log_archive 并重置自增）时必须为 true：
     * 迁移后审计行数合法地小于迁移前，原「只增不减」断言失效，退化为
     * 「不超过截断前峰值」的有界性检查。V425 之后起步的回放仍走原断言。
     */
    static void assertStableSnapshot(
            Snapshot before, Snapshot after, boolean auditFreshStartExpected) {
        assertThat(after.tableRows().keySet())
                .as("candidate migrations must not remove pre-existing business tables")
                .containsAll(before.tableRows().keySet());
        Map<String, String> unexpected = new TreeMap<>();
        for (Map.Entry<String, Long> entry : before.tableRows().entrySet()) {
            Long afterCount = after.tableRows().get(entry.getKey());
            if (!entry.getValue().equals(afterCount)
                    && !EXPECTED_ROW_COUNT_MUTATIONS.contains(entry.getKey())) {
                unexpected.put(entry.getKey(), entry.getValue() + " -> " + afterCount);
            }
        }
        assertThat(unexpected)
                .as("candidate migrations changed row counts outside the reviewed allowlist")
                .isEmpty();
        if (auditFreshStartExpected) {
            assertThat(after.tableRows().get("audit_log"))
                    .as("V425 audit fresh start truncates history; post-fresh-start "
                            + "audit stays bounded by the pre-truncate peak")
                    .isLessThanOrEqualTo(before.tableRows().get("audit_log"));
        } else {
            assertThat(after.tableRows().get("audit_log"))
                    .as("migration audit evidence is append-only")
                    .isGreaterThanOrEqualTo(before.tableRows().get("audit_log"));
        }
        assertThat(after.userIdentity()).isEqualTo(before.userIdentity());
        assertThat(after.scopeRows()).containsExactlyEntriesOf(before.scopeRows());
        assertThat(after.paymentTotals()).isEqualTo(before.paymentTotals());
        assertThat(after.stockTotals()).isEqualTo(before.stockTotals());
    }

    static void assertCurrentAuthority(Connection connection) throws SQLException {
        assertThat(latestSuccessfulVersion(connection)).isEqualTo(CURRENT_HEAD_VERSION);
        assertThat(successfulMigrationCount(connection)).isEqualTo(CURRENT_MIGRATION_COUNT);
        assertThat(scalarLong(connection,
                "SELECT count(*) FROM system_master_category_registry")).isEqualTo(1);
        assertThat(scalarLong(connection, """
                SELECT count(*)
                FROM system_master_category_registry registry
                JOIN material_categories material
                  ON material.id = registry.material_category_id
                JOIN client_categories client
                  ON client.id = registry.client_category_id
                JOIN mould_categories mould
                  ON mould.id = registry.mould_category_id
                JOIN supplier_categories supplier
                  ON supplier.id = registry.supplier_category_id
                WHERE registry.id = '27500000-0000-4000-8000-000000000001'::uuid
                  AND material.legacy_id = -1
                  AND material.legacy_code_snapshot = 'LEGACY_ORPHAN'
                  AND material.is_deleted = FALSE
                  AND client.legacy_id = -1
                  AND client.code = 'SYS_UNCATEGORIZED_CLIENT'
                  AND client.is_deleted = FALSE
                  AND mould.legacy_id = -1
                  AND mould.code = 'SYS_UNCATEGORIZED_MOULD'
                  AND mould.is_deleted = FALSE
                  AND supplier.legacy_id = -1
                  AND supplier.code = 'SYS_UNCATEGORIZED_SUPPLIER'
                  AND supplier.is_deleted = FALSE
                """)).isEqualTo(1);
        assertThat(scalarLong(connection,
                "SELECT count(*) FROM production_material_analysis_borrows")).isZero();
        assertThat(scalarLong(connection, """
                SELECT count(*)
                FROM pg_trigger trigger_row
                JOIN pg_proc trigger_function ON trigger_function.oid = trigger_row.tgfoid
                WHERE trigger_row.tgrelid =
                          'production_material_analysis_borrows'::regclass
                  AND NOT trigger_row.tgisinternal
                  AND trigger_row.tgname LIKE 'trg_audit%'
                  AND trigger_function.proname IN ('fn_audit', 'fn_audit_redacted')
                """)).isEqualTo(1);
        assertThat(scalarLong(connection, """
                SELECT count(*)
                FROM business_identifier_conflicts
                WHERE conflict_kind NOT IN (
                          'IDENTIFIER_DUPLICATE', 'PREFIX_DUPLICATE', 'FORMAT_ANOMALY')
                   OR evidence IS NULL
                """)).isZero();
        assertThat(scalarLong(connection, """
                SELECT count(*)
                FROM client_default_settlement_migration_issues
                WHERE issue_code NOT IN (
                          'MISSING_ACTIVE_METHOD', 'AMBIGUOUS_ACTIVE_METHOD')
                   OR active_match_count < 0
                """)).isZero();
        assertThat(scalarLong(connection, """
                SELECT count(*)
                FROM employee_sensitive
                WHERE (id_card_enc IS NULL
                       AND (id_card_last4 IS NOT NULL OR id_card_hash IS NOT NULL))
                   OR (phone_enc IS NULL AND phone_hash IS NOT NULL)
                """)).isZero();
    }

    static String identifierConflictDigest(Connection connection) throws SQLException {
        return evidenceDigest(connection, """
                SELECT concat_ws(E'\\t',
                           conflict_kind,
                           COALESCE(normalized_value, ''),
                           COALESCE(owner_kind, ''),
                           COALESCE(owner_key, ''),
                           COALESCE(source_table, ''),
                           COALESCE(entity_id::text, ''),
                           COALESCE(legacy_identity, ''),
                           evidence::text) AS evidence_row
                FROM business_identifier_conflicts
                ORDER BY evidence_row
                """);
    }

    static String clientSettlementIssueDigest(Connection connection) throws SQLException {
        return evidenceDigest(connection, """
                SELECT concat_ws(E'\\t',
                           client_id::text,
                           legacy_price_style::text,
                           issue_code,
                           active_match_count::text,
                           (resolved_at IS NOT NULL)::text,
                           COALESCE(resolved_by::text, ''),
                           COALESCE(resolution_note, '')) AS evidence_row
                FROM client_default_settlement_migration_issues
                ORDER BY evidence_row
                """);
    }

    static int successfulMigrationCount(Connection connection) throws SQLException {
        return Math.toIntExact(scalarLong(connection, """
                SELECT count(*) FROM flyway_schema_history WHERE success
                """));
    }

    static String latestSuccessfulVersion(Connection connection) throws SQLException {
        return scalarText(connection, """
                SELECT version
                FROM flyway_schema_history
                WHERE success
                ORDER BY installed_rank DESC
                LIMIT 1
                """);
    }

    static long scalarLong(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertThat(result.next()).as("query returned a row: %s", sql).isTrue();
            return result.getLong(1);
        }
    }

    private static String scalarText(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertThat(result.next()).as("query returned a row: %s", sql).isTrue();
            return result.getString(1);
        }
    }

    private static String evidenceDigest(Connection connection, String sql) throws SQLException {
        MessageDigest digest;
        try {
            digest = MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            while (result.next()) {
                digest.update(result.getString(1).getBytes(StandardCharsets.UTF_8));
                digest.update((byte) '\n');
            }
        }
        return HexFormat.of().formatHex(digest.digest());
    }

    private static Map<String, Long> tableRows(Connection connection) throws SQLException {
        Map<String, Long> rows = new TreeMap<>();
        try (Statement tables = connection.createStatement();
             ResultSet result = tables.executeQuery("""
                     SELECT table_name
                     FROM information_schema.tables
                     WHERE table_schema = 'public'
                       AND table_type = 'BASE TABLE'
                       AND table_name <> 'flyway_schema_history'
                     ORDER BY table_name
                     """)) {
            while (result.next()) {
                String table = result.getString(1);
                try (Statement count = connection.createStatement();
                     ResultSet countResult = count.executeQuery(
                             "SELECT count(*) FROM \"" + table.replace("\"", "\"\"") + "\"")) {
                    countResult.next();
                    rows.put(table, countResult.getLong(1));
                }
            }
        }
        return Map.copyOf(rows);
    }

    private static Map<String, Long> groupedCounts(Connection connection, String sql)
            throws SQLException {
        Map<String, Long> counts = new TreeMap<>();
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            while (result.next()) {
                counts.put(result.getString(1), result.getLong(2));
            }
        }
        return Map.copyOf(counts);
    }

    private static PaymentTotals paymentTotals(Connection connection) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery("""
                     SELECT count(*),
                            COALESCE(sum(amount_original), 0),
                            COALESCE(sum(amount_local), 0)
                     FROM finance_payments
                     WHERE COALESCE(is_deleted, FALSE) = FALSE
                     """)) {
            result.next();
            return new PaymentTotals(
                    result.getLong(1), result.getBigDecimal(2), result.getBigDecimal(3));
        }
    }

    private static StockTotals stockTotals(Connection connection) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery("""
                     SELECT count(*), COALESCE(sum(qty), 0)
                     FROM stock_balances
                     """)) {
            result.next();
            return new StockTotals(result.getLong(1), result.getBigDecimal(2));
        }
    }

    record Snapshot(
            Map<String, Long> tableRows,
            String userIdentity,
            Map<String, Long> scopeRows,
            PaymentTotals paymentTotals,
            StockTotals stockTotals) {
    }

    record PaymentTotals(long activeCount, BigDecimal amountOriginal, BigDecimal amountLocal) {
    }

    record StockTotals(long rowCount, BigDecimal quantity) {
    }
}
