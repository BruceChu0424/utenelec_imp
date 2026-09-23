package com.uten.imp.migration;

import java.io.IOException;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
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
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;

/** Shared, fail-closed reconciliation rules for synthetic and real-clone migration rehearsals. */
public final class MigrationRehearsalSupport {

    // 迁移头与迁移数：直接从 classpath 的 db/migration 目录推导（2026-09-16 起），
    // 目录本身就是唯一事实源——新增迁移不再需要改这里（历史上"594/551 忘同步"
    // 曾连炸四轮：b971674f/dfb07ebd/6bb5715e 等）。
    // 剩余靠人肉同步的两处（各有自己的闸门测试兜底）：
    //   - ops/reset_business_data.sql 的 (installed_rank, version) fail-closed 白名单
    //     （BusinessDataResetSqlContractTest 会对账目录全量版本对并在漏改时报出该补的行）；
    //   - docs/数据迁移/README.md 的头版本说明（LegacyMigrationSafetyContractTest 锁）。
    public static final String CURRENT_HEAD_VERSION;
    public static final int CURRENT_MIGRATION_COUNT;

    /** Sorted version numbers of every V*__*.sql found on the test classpath. */
    private static final java.util.List<Integer> MIGRATION_FILE_VERSIONS = new java.util.ArrayList<>();

    static {
        try {
            Path migrationDir = Paths.get(
                    MigrationRehearsalSupport.class.getResource("/db/migration").toURI());
            Pattern versioned = Pattern.compile("V(\\d+)__.*\\.sql");
            int head = 0;
            int count = 0;
            try (Stream<Path> files = Files.list(migrationDir)) {
                for (Path file : files.filter(Files::isRegularFile).sorted().toList()) {
                    Matcher matcher = versioned.matcher(file.getFileName().toString());
                    if (!matcher.matches()) {
                        continue;
                    }
                    int version = Integer.parseInt(matcher.group(1));
                    count++;
                    MIGRATION_FILE_VERSIONS.add(version);
                    head = Math.max(head, version);
                }
            } catch (IOException failure) {
                throw new IllegalStateException("无法枚举 db/migration 目录", failure);
            }
            if (head <= 0 || count <= 0) {
                throw new IllegalStateException(
                        "db/migration 下未发现任何 V*__*.sql，无法推导迁移头");
            }
            CURRENT_HEAD_VERSION = Integer.toString(head);
            CURRENT_MIGRATION_COUNT = count;
        } catch (Exception failure) {
            throw new IllegalStateException(
                    "推导迁移头失败：测试 classpath 必须以目录形式暴露 db/migration", failure);
        }
    }

    /**
     * 目录里版本号 {@code <= version} 的迁移文件个数——即 Flyway 迁到
     * {@code version} 后 {@code flyway_schema_history} 里应有的成功条数
     * （跳号版本不存在文件，天然数不进去）。ops 白名单版本对的第二个数、
     * 分段升级的基线条数都以它为准，不再靠人记。
     */
    public static int migrationFileCountUpTo(int version) {
        int total = 0;
        for (int fileVersion : MIGRATION_FILE_VERSIONS) {
            if (fileVersion <= version) {
                total++;
            }
        }
        return total;
    }

    /**
     * 从 {@code fromVersion}（含）升级到当前目录头应执行的迁移条数。
     * PreplanFutureTransferForwardMigrationPostgresTest 的计数断言用它推导，
     * 新增迁移时不再需要"+1"（目录变了，推导值自动跟着变）。
     */
    public static int expectedMigrationsAfter(int fromVersion) {
        return CURRENT_MIGRATION_COUNT - migrationFileCountUpTo(fromVersion);
    }

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
            // V543 下架 production.* 面上的停用码并补齐我的车间任务面三码（有意的增删）。
            "permission_surface_permissions",
            "role_permissions",
            // V582 把在途拣货任务拨回待出库时，按追加式事件账补一条
            // PICKING/PICKED/EXCEPTION -> PENDING_PICK 的留证行(只在真实克隆库里
            // 有在途单时才增行；空库与合成库为 0 行)。
            "sales_shipment_warehouse_events",
            "supplier_categories",
            // V659 按 SystemSettingKey 登记补齐 7 个设置行 (ON CONFLICT DO NOTHING, 不改已有值; ADR-110)。
            "system_settings",
            "user_permission_overrides");

    private MigrationRehearsalSupport() {
    }

    static Snapshot snapshot(Connection connection) throws SQLException {
        return new Snapshot(
                Integer.parseInt(latestSuccessfulVersion(connection)),
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
        // 有意整表废弃（升级到当前目录后合法消失），点名豁免；其余任何被删表仍然算红。
        Set<String> intentionallyDropped = Set.of(
                // V590 车间偏好表废弃删除，学习数据搬进货品表随 goods 保留。
                "production_goods_workshop_preferences");
        Set<String> requiredTables = new java.util.HashSet<>(before.tableRows().keySet());
        requiredTables.removeAll(intentionallyDropped);
        assertThat(after.tableRows().keySet())
                .as("candidate migrations must not remove pre-existing business tables")
                .containsAll(requiredTables);
        Map<String, String> unexpected = new TreeMap<>();
        for (Map.Entry<String, Long> entry : before.tableRows().entrySet()) {
            Long afterCount = after.tableRows().get(entry.getKey());
            if (!entry.getValue().equals(afterCount)
                    && !EXPECTED_ROW_COUNT_MUTATIONS.contains(entry.getKey())
                    && !reviewedExpenseNamespaceAddition(before, after, entry.getKey(),
                            entry.getValue(), afterCount)
                    // 整表废弃后行数 0 -> null 同样合法（表已点名豁免删除）。
                    && !intentionallyDropped.contains(entry.getKey())) {
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

    private static boolean reviewedExpenseNamespaceAddition(
            Snapshot before, Snapshot after, String table, long oldCount, Long newCount) {
        // V608 registers exactly one BX namespace and its two prefix ownership rows.
        // A later migration or any other quantity difference remains a failure.
        return before.schemaVersion() < 608 && after.schemaVersion() >= 608
                && Set.of("business_identifier_namespaces", "business_prefix_reservations",
                        "business_prefix_reservation_members").contains(table)
                && newCount != null && newCount == oldCount + 1;
    }

    static void assertCurrentAuthority(Connection connection) throws SQLException {
        assertThat(latestSuccessfulVersion(connection)).isEqualTo(CURRENT_HEAD_VERSION);
        assertThat(successfulMigrationCount(connection)).isEqualTo(CURRENT_MIGRATION_COUNT);
        assertThat(scalarLong(connection, """
                SELECT count(*) FROM business_identifier_namespaces namespace
                JOIN business_prefix_reservations reservation
                  ON reservation.normalized_prefix = namespace.fixed_prefix
                 AND reservation.first_owner_kind = 'NAMESPACE'
                 AND reservation.first_owner_key = namespace.namespace_key
                JOIN business_prefix_reservation_members member
                  ON member.normalized_prefix = namespace.fixed_prefix
                 AND member.owner_kind = 'NAMESPACE'
                 AND member.owner_key = namespace.namespace_key
                WHERE namespace.namespace_key = 'EXPENSE_CLAIM'
                  AND namespace.identifier_family = 'DOCUMENT'
                  AND namespace.fixed_prefix = 'BX'
                  AND namespace.source_table = 'expense_claims'
                  AND namespace.identifier_column = 'claim_no'
                  AND namespace.discriminator_value IS NULL
                """))
                .as("V608 must register the exact expense namespace and prefix ownership")
                .isEqualTo(1);
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

    public static int successfulMigrationCount(Connection connection) throws SQLException {
        return Math.toIntExact(scalarLong(connection, """
                SELECT count(*) FROM flyway_schema_history WHERE success
                """));
    }

    public static String latestSuccessfulVersion(Connection connection) throws SQLException {
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
            int schemaVersion,
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
