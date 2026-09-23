package com.uten.imp.features.master.lifecycle;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 主档引用目录与真库逐列对账(ADR-111 评审 major 回归)。
 *
 * <p>2026-09-22 的事故是「删主档不查引用」；第一轮修复又漏了应收应付、草稿退货、委外发料等
 * 在办业务。根因是「查哪些表」靠人记。这里把迁移后的真实库结构当事实：所有指向七种主档的外键列，
 * 加上按命名约定(…goods_id / …color_id / …warehouse_ids 等)却没有外键的 uuid 列，每一列都必须
 * 在 {@link MasterReferenceCatalog} 里要么登记为引用(带在办口径)、要么登记为豁免(带理由)。
 * 以后谁新加一张引用主档的表而没归类，这个测试直接失败并点名该列。
 *
 * <p>同时把七种主档的整条检查语句在真库上各跑一遍，保证目录里每一段 SQL 都能执行，并记录
 * 空库上的耗时(语句只有一条，与批量条数无关)。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MasterReferenceCatalogCoverageTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("master_reference_catalog")
                    .withUsername("uten")
                    .withPassword("uten");

    private static final Map<String, MasterEntityKind> MASTER_TABLES = Map.of(
            "goods", MasterEntityKind.GOODS,
            "colors", MasterEntityKind.COLOR,
            "units", MasterEntityKind.UNIT,
            "warehouses", MasterEntityKind.WAREHOUSE,
            "clients", MasterEntityKind.CLIENT,
            "suppliers", MasterEntityKind.SUPPLIER,
            "moulds", MasterEntityKind.MOULD);

    private static final Map<String, MasterEntityKind> NAMING = Map.of(
            "goods", MasterEntityKind.GOODS,
            "color", MasterEntityKind.COLOR,
            "unit", MasterEntityKind.UNIT,
            "warehouse", MasterEntityKind.WAREHOUSE,
            "client", MasterEntityKind.CLIENT,
            "supplier", MasterEntityKind.SUPPLIER,
            "mould", MasterEntityKind.MOULD);

    private static final Pattern NAMED = Pattern.compile("(?:^|_)(goods|color|unit|warehouse|client|supplier|mould)_ids?$");

    @BeforeAll
    static void migrateRealSchema() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void everyColumnPointingAtAMasterIsEitherCheckedOrExemptedWithAReason() throws SQLException {
        Map<String, MasterEntityKind> inventory = inventory();
        Map<String, MasterEntityKind> covered = new TreeMap<>();
        for (MasterReferenceCatalog.Reference reference : MasterReferenceCatalog.references()) {
            covered.put(reference.table() + "." + reference.column(), reference.target());
        }
        Set<String> exempt = new TreeSet<>();
        for (MasterReferenceCatalog.Exemption exemption : MasterReferenceCatalog.exemptions()) {
            assertThat(exempt.add(exemption.table() + "." + exemption.column()))
                    .as("豁免重复登记 %s.%s", exemption.table(), exemption.column()).isTrue();
            assertThat(exemption.note()).as("豁免必须写理由").isNotBlank();
        }

        Set<String> unclassified = new TreeSet<>(inventory.keySet());
        unclassified.removeAll(covered.keySet());
        unclassified.removeAll(exempt);
        assertThat(unclassified)
                .as("这些列指向主档，但 MasterReferenceCatalog 既没登记引用口径也没登记豁免理由")
                .isEmpty();

        Set<String> both = new TreeSet<>(covered.keySet());
        both.retainAll(exempt);
        assertThat(both).as("同一列不能既检查又豁免").isEmpty();

        Set<String> stale = new TreeSet<>(covered.keySet());
        stale.addAll(exempt);
        stale.removeAll(inventory.keySet());
        assertThat(stale).as("目录里登记了库里并不存在(或不指向主档)的列").isEmpty();

        List<String> wrongTarget = new ArrayList<>();
        covered.forEach((column, target) -> {
            if (inventory.get(column) != target) {
                wrongTarget.add(column + " 实际指向 " + inventory.get(column) + "，目录写成 " + target);
            }
        });
        assertThat(wrongTarget).as("引用目录的主档种类与外键不一致").isEmpty();
        record("inventory", inventory.size(), "covered", covered.size(), "exempt", exempt.size());
    }

    @Test
    void everyKindsWholeReferenceQueryRunsOnTheMigratedSchema() throws SQLException {
        try (Connection connection = connection()) {
            for (MasterEntityKind kind : MasterEntityKind.values()) {
                String sql = MasterReferenceGuard.sql(kind)
                        .replace(":ids", "?")
                        .replace(":excluded", "?");
                String ids = UUID.randomUUID() + "," + UUID.randomUUID();
                long started = System.nanoTime();
                try (PreparedStatement statement = connection.prepareStatement(sql)) {
                    statement.setString(1, ids);
                    statement.setString(2, "");
                    try (ResultSet rows = statement.executeQuery()) {
                        assertThat(rows.next()).as(kind + " 随机 id 不应命中任何引用").isFalse();
                    }
                }
                double millis = (System.nanoTime() - started) / 1_000_000.0;
                record("kind", kind.name(),
                        "branches", MasterReferenceCatalog.references(kind).size(),
                        "emptySchemaMillis", Math.round(millis * 10) / 10.0);
            }
        }
    }

    /** 库里所有指向七种主档的列：外键列(分区子表并到父表) + 按命名约定却没外键的 uuid 列。 */
    private static Map<String, MasterEntityKind> inventory() throws SQLException {
        Map<String, MasterEntityKind> out = new TreeMap<>();
        try (Connection connection = connection();
             PreparedStatement statement = connection.prepareStatement("""
                     SELECT DISTINCT t.relname, a.attname, rt.relname
                     FROM pg_constraint c
                     JOIN pg_class t ON t.oid = c.conrelid
                     JOIN pg_namespace n ON n.oid = t.relnamespace AND n.nspname = 'public'
                     JOIN pg_class rt ON rt.oid = c.confrelid
                     JOIN LATERAL unnest(c.conkey) k(attnum) ON TRUE
                     JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
                     WHERE c.contype = 'f' AND NOT t.relispartition
                       AND rt.relname IN ('goods', 'colors', 'units', 'warehouses', 'clients', 'suppliers', 'moulds')
                     """);
             ResultSet rows = statement.executeQuery()) {
            while (rows.next()) {
                out.put(rows.getString(1) + "." + rows.getString(2), MASTER_TABLES.get(rows.getString(3)));
            }
        }
        try (Connection connection = connection();
             PreparedStatement statement = connection.prepareStatement("""
                     SELECT c.relname, a.attname
                     FROM pg_class c
                     JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
                     JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                     WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
                       AND format_type(a.atttypid, a.atttypmod) IN ('uuid', 'uuid[]')
                       AND NOT EXISTS (
                           SELECT 1 FROM pg_constraint k
                           WHERE k.conrelid = c.oid AND k.contype IN ('f', 'p') AND a.attnum = ANY(k.conkey))
                     """);
             ResultSet rows = statement.executeQuery()) {
            while (rows.next()) {
                String column = rows.getString(2);
                Matcher matcher = NAMED.matcher(column);
                if (!matcher.find()) continue;
                out.putIfAbsent(rows.getString(1) + "." + column, NAMING.get(matcher.group(1)));
            }
        }
        return out;
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private static void record(Object... pairs) {
        Map<String, Object> line = new LinkedHashMap<>();
        for (int i = 0; i + 1 < pairs.length; i += 2) line.put(String.valueOf(pairs[i]), pairs[i + 1]);
        try {
            java.nio.file.Path output = java.nio.file.Path.of(
                    System.getProperty("uten.build.directory", "target"), "master-reference-catalog.jsonl");
            java.nio.file.Files.createDirectories(output.toAbsolutePath().getParent());
            java.nio.file.Files.writeString(output, new com.fasterxml.jackson.databind.ObjectMapper()
                            .writeValueAsString(line) + System.lineSeparator(),
                    java.nio.file.StandardOpenOption.CREATE, java.nio.file.StandardOpenOption.APPEND);
        } catch (java.io.IOException error) {
            throw new AssertionError(error);
        }
    }
}
