package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.images.builder.Transferable;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.fail;
import static com.uten.imp.migration.MigrationRehearsalSupport.CURRENT_HEAD_VERSION;
import static com.uten.imp.migration.MigrationRehearsalSupport.CURRENT_MIGRATION_COUNT;

/**
 * Executes the destructive bootstrap SQL against the current Flyway schema with empty staging
 * tables. This is deliberately a schema-compatibility proof, not a real-data reconciliation.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class LegacyBootstrapSchemaCompatibilityPostgresTest {

    private static final Path LEGACY_ROOT = Path.of("legacy_migration");
    private static final Pattern FUNCTION = Pattern.compile(
            "(?ms)^([a-z_][a-z0-9_]*) \\(\\) \\{(.*?)^\\}");
    private static final Pattern RUN_SQL = Pattern.compile(
            "(?m)^\\s*run_sql ([A-Za-z0-9_.-]+[.]sql)\\s*$");
    private static final Pattern BOOTSTRAP_CALL = Pattern.compile(
            "(?m)^\\s*(migrate_[a-z0-9_]+)\\s*$");

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    @BeforeAll
    static void startDatabase() {
        POSTGRES.start();
    }

    @BeforeEach
    void resetDatabase() {
        Flyway flyway = Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .cleanDisabled(false)
                .load();
        flyway.clean();
        flyway.migrate();
    }

    @AfterAll
    static void stopDatabase() {
        POSTGRES.stop();
    }

    @Test
    void bootstrapSqlStillExecutesAgainstTheCurrentSchema() throws Exception {
        List<String> scripts = bootstrapSqlScripts();
        assertFalse(scripts.isEmpty(), "bootstrap-all must resolve at least one SQL script");

        for (String filename : scripts) {
            if ("migrate_currency.sql".equals(filename)) {
                executeScript(filename, Map.of("currency_stage", """
                        INSERT INTO currency_stage(
                            legacy_id,code,name,exchange_rate,status)
                        VALUES
                            (1,'001','人民币',1,'使用'),
                            (3,'002','美金',0,'使用'),
                            (4,'003','港币',0,'使用');
                        """));
            } else {
                executeScript(filename);
            }
        }
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())) {
            assertFlywayHead(connection);
        }
    }

    @Test
    void masterBootstrapPreservesSystemRootsAndResolvesCurrentUuidRelations()
            throws Exception {
        String rootsBefore = scalar("""
                SELECT material_category_id || '|' || client_category_id || '|' ||
                       mould_category_id || '|' || supplier_category_id
                FROM system_master_category_registry
                """);

        executeScript("migrate_goods.sql", Map.of("mc_stage", """
                INSERT INTO mc_stage(legacy_id, parent_legacy, code, name)
                VALUES (101, 0, 'RAW', '原材料');
                """));
        executeScript("migrate_mould.sql", Map.of("mc_stage", """
                INSERT INTO mc_stage(legacy_id, parent_legacy, code, name)
                VALUES (201, 0, 'MOULD', '模具分类');
                """));
        executeScript("migrate_client.sql", Map.of("mc_stage", """
                INSERT INTO mc_stage(legacy_id, parent_legacy, code, name)
                VALUES (301, 0, 'CLIENT', '客户分类');
                """));
        executeScript("migrate_supplier.sql", Map.of("mc_stage", """
                INSERT INTO mc_stage(legacy_id, parent_legacy, code, name)
                VALUES (401, 0, 'SUPPLIER', '供应商分类');
                """));
        executeScript("migrate_color.sql", Map.of("color_stage", """
                INSERT INTO color_stage(legacy_id, code, name, status)
                VALUES (1, 'C1', '红色', '使用');
                """));
        executeScript("migrate_unit.sql", Map.of("unit_stage", """
                INSERT INTO unit_stage(legacy_id, code, name, status)
                VALUES (2, 'U2', '件', '使用');
                """));
        executeScript("migrate_warehouse.sql", Map.of("warehouse_stage", """
                INSERT INTO warehouse_stage(
                    legacy_id, code, name, location, remark,
                    is_accountable, workshop_legacy_id, status)
                VALUES (3, 'W3', '测试仓', '厂内', NULL, FALSE, NULL, '使用');
                """));
        executeScript("migrate_mould_data.sql", Map.of("mould_stage", """
                INSERT INTO mould_stage(legacy_id, parent_legacy, name, code, status)
                VALUES (11, 201, '测试模具', 'M11', '使用');
                """));
        executeScript("migrate_client_data.sql", Map.of("client_stage", """
                INSERT INTO client_stage(legacy_id, parent_legacy, name, code, price_style, status)
                VALUES (12, 301, '测试客户', 'KH000012', 1, '使用');
                """));
        executeScript("migrate_supplier_data.sql", Map.of("supplier_stage", """
                INSERT INTO supplier_stage(legacy_id, parent_legacy, name, code, status)
                VALUES (13, 401, '测试供应商', 'GY000013', '使用');
                """));
        executeScript("migrate_goods_data.sql", Map.of("goods_stage", """
                INSERT INTO goods_stage(
                    legacy_id, code, name, parent_legacy,
                    unit_legacy_id, color_legacy_id, mould_legacy_id,
                    client_legacy_id, vend_legacy_id, vend2_legacy_id, status)
                VALUES (14, 'G000014', '测试货品', 101, 2, 1, 11, 12, 13, 13, '使用');
                """));

        assertEquals(rootsBefore, scalar("""
                SELECT material_category_id || '|' || client_category_id || '|' ||
                       mould_category_id || '|' || supplier_category_id
                FROM system_master_category_registry
                """));
        assertEquals("1", scalar("""
                SELECT count(*)
                FROM goods goods
                JOIN material_categories category ON category.id = goods.category_id
                JOIN units unit_master ON unit_master.id = goods.unit_id
                JOIN colors color_master ON color_master.id = goods.color_id
                JOIN moulds mould ON mould.id = goods.mould_id
                JOIN clients client ON client.id = goods.client_id
                JOIN suppliers supplier ON supplier.id = goods.default_supplier_id
                JOIN suppliers supplier2 ON supplier2.id = goods.secondary_supplier_id
                WHERE goods.legacy_id = 14 AND category.legacy_id = 101
                  AND unit_master.legacy_id = 2 AND color_master.legacy_id = 1
                  AND mould.legacy_id = 11 AND client.legacy_id = 12
                  AND supplier.legacy_id = 13 AND supplier2.legacy_id = 13
                """));
        assertEquals("27300000-0000-4000-8100-000000000001", scalar("""
                SELECT default_settlement_method_id
                FROM clients WHERE legacy_id = 12
                """));

        assertEquals("1", scalar("""
                WITH inserted AS (
                    INSERT INTO stock_balances(warehouse_id, goods_id, color_id, qty)
                    SELECT warehouse.id, goods.id, color_master.id, 1
                    FROM warehouses warehouse
                    CROSS JOIN goods goods
                    CROSS JOIN colors color_master
                    WHERE warehouse.legacy_id = 3
                      AND goods.legacy_id = 14
                      AND color_master.legacy_id = 1
                    RETURNING 1
                )
                SELECT count(*) FROM inserted
                """));
        assertThrows(AssertionError.class, () -> executeScript("migrate_goods_data.sql"));
        assertEquals("1", scalar("SELECT count(*) FROM goods WHERE legacy_id = 14"));
        assertEquals("1", scalar("SELECT count(*) FROM stock_balances WHERE qty = 1"));
    }

    @Test
    void fullBootstrapReconciliationPersistsPassAndFailureEvidence() throws Exception {
        executeScript("migrate_goods.sql", Map.of("mc_stage", """
                INSERT INTO mc_stage(legacy_id, parent_legacy, code, name)
                VALUES (101, 0, 'RAW', '原材料');
                """));
        executeScript("migrate_unit.sql", Map.of("unit_stage", """
                INSERT INTO unit_stage(legacy_id, code, name, status)
                VALUES (2, 'U2', '件', '使用');
                """));
        executeScript("migrate_goods_data.sql", Map.of("goods_stage", """
                INSERT INTO goods_stage(
                    legacy_id, code, name, parent_legacy, unit_legacy_id, status)
                VALUES (14, 'G000014', '测试货品', 101, 2, '使用');
                """));

        Map<String, String> expectations = currentReconciliationExpectations();
        String passedRun = newReconciliationRun();
        executeReconciliation(passedRun, expectations);
        assertEquals("20|0", scalar("""
                SELECT count(*) || '|' || count(*) FILTER (WHERE passed = FALSE)
                FROM legacy_migration_reconciliation_items
                WHERE run_id = '%s'::uuid
                """.formatted(passedRun)));

        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            assertEquals(1, statement.executeUpdate("""
                    UPDATE goods SET unit_id = NULL WHERE legacy_id = 14
                    """));
        }

        String failedRun = newReconciliationRun();
        executeReconciliation(failedRun, expectations);
        assertEquals("20|1", scalar("""
                SELECT count(*) || '|' || count(*) FILTER (WHERE passed = FALSE)
                FROM legacy_migration_reconciliation_items
                WHERE run_id = '%s'::uuid
                """.formatted(failedRun)));
        assertEquals("1", scalar("""
                SELECT count(*)
                FROM legacy_migration_reconciliation_items
                WHERE run_id = '%s'::uuid
                  AND metric = 'unresolved_current_uuid_relations'
                  AND passed = FALSE
                """.formatted(failedRun)));
    }

    private static List<String> bootstrapSqlScripts() throws Exception {
        String shell = Files.readString(LEGACY_ROOT.resolve("migrate.sh"), StandardCharsets.UTF_8);
        Map<String, String> functions = new LinkedHashMap<>();
        Matcher functionMatcher = FUNCTION.matcher(shell);
        while (functionMatcher.find()) {
            Matcher runSql = RUN_SQL.matcher(functionMatcher.group(2));
            if (runSql.find()) {
                functions.put(functionMatcher.group(1), runSql.group(1));
                if (runSql.find()) {
                    fail(functionMatcher.group(1) + " invokes more than one run_sql target");
                }
            }
        }

        int branch = shell.lastIndexOf("--bootstrap-all|--all|-a)");
        if (branch < 0) {
            fail("migrate.sh has no bootstrap-all execution branch");
        }
        int end = shell.indexOf(";;", branch);
        if (end < 0) {
            fail("migrate.sh bootstrap-all execution branch is unterminated");
        }

        List<String> scripts = new ArrayList<>();
        Matcher calls = BOOTSTRAP_CALL.matcher(shell.substring(branch, end));
        while (calls.find()) {
            String function = calls.group(1);
            String script = functions.get(function);
            if (script == null) {
                fail("bootstrap function has no single run_sql target: " + function);
            }
            scripts.add(script);
        }
        return List.copyOf(scripts);
    }

    private static void executeScript(String filename) throws Exception {
        executeScript(filename, Map.of());
    }

    private static void executeScript(String filename, Map<String, String> copyInjections)
            throws Exception {
        Path path = LEGACY_ROOT.resolve(filename);
        StringBuilder jdbcSql = new StringBuilder();
        for (String line : Files.readAllLines(path, StandardCharsets.UTF_8)) {
            String trimmed = line.stripLeading();
            if (trimmed.startsWith("\\copy ")) {
                String target = trimmed.substring("\\copy ".length()).split("[\\s(]", 2)[0];
                String injection = copyInjections.get(target);
                if (injection != null) {
                    jdbcSql.append(injection).append('\n');
                }
                continue;
            }
            if (trimmed.startsWith("\\i ")) {
                continue;
            }
            jdbcSql.append(line).append('\n');
        }
        String sql = jdbcSql.toString()
                .replace(":'pgp_key'", "'legacy-schema-test-key'")
                .replace(":'pgp_ver'", "'test-v1'")
                .replace(":'hmac_key'", "'legacy-schema-test-hmac-key'");
        String remote = "/tmp/uten-legacy-schema-test-" + filename;
        POSTGRES.copyFileToContainer(
                Transferable.of(sql.getBytes(StandardCharsets.UTF_8), 0600), remote);
        var result = POSTGRES.execInContainer(
                "psql", "-v", "ON_ERROR_STOP=1",
                "-U", POSTGRES.getUsername(), "-d", POSTGRES.getDatabaseName(),
                "-f", remote);
        if (result.getExitCode() != 0) {
            fail(filename + " is incompatible with the current Flyway schema:\n"
                    + result.getStderr());
        }
    }

    private static String newReconciliationRun() throws SQLException {
        return scalar("""
                INSERT INTO legacy_migration_runs(target, status)
                VALUES ('--bootstrap-all', 'RUNNING')
                RETURNING run_id
                """);
    }

    private static Map<String, String> currentReconciliationExpectations()
            throws SQLException {
        Map<String, String> values = new LinkedHashMap<>();
        values.put("expected_material_categories", scalar(
                "SELECT count(*) FROM material_categories WHERE legacy_id IS NOT NULL AND legacy_id <> -1"));
        values.put("expected_mould_categories", scalar(
                "SELECT count(*) FROM mould_categories WHERE legacy_id IS NOT NULL AND legacy_id <> -1"));
        values.put("expected_client_categories", scalar(
                "SELECT count(*) FROM client_categories WHERE legacy_id IS NOT NULL AND legacy_id <> -1"));
        values.put("expected_supplier_categories", scalar(
                "SELECT count(*) FROM supplier_categories WHERE legacy_id IS NOT NULL AND legacy_id <> -1"));
        values.put("expected_colors", scalar(
                "SELECT count(*) FROM colors WHERE legacy_id IS NOT NULL"));
        values.put("expected_units", scalar(
                "SELECT count(*) FROM units WHERE legacy_id IS NOT NULL"));
        values.put("expected_currencies", scalar(
                "SELECT count(*) FROM currencies WHERE legacy_id IS NOT NULL"));
        values.put("expected_warehouses", scalar(
                "SELECT count(*) FROM warehouses WHERE legacy_id IS NOT NULL"));
        values.put("expected_moulds", scalar(
                "SELECT count(*) FROM moulds WHERE legacy_id IS NOT NULL"));
        values.put("expected_clients", scalar(
                "SELECT count(*) FROM clients WHERE legacy_id IS NOT NULL"));
        values.put("expected_suppliers", scalar(
                "SELECT count(*) FROM suppliers WHERE legacy_id IS NOT NULL"));
        values.put("expected_goods", scalar(
                "SELECT count(*) FROM goods WHERE legacy_id IS NOT NULL"));
        values.put("expected_csv_files", "0");
        return Map.copyOf(values);
    }

    private static void executeReconciliation(
            String runId, Map<String, String> expectations) throws Exception {
        Path path = LEGACY_ROOT.resolve("migrate_reconciliation.sql");
        String remote = "/tmp/uten-legacy-reconciliation-" + runId + ".sql";
        POSTGRES.copyFileToContainer(
                Transferable.of(Files.readAllBytes(path), 0600), remote);

        List<String> command = new ArrayList<>(List.of(
                "psql", "-v", "ON_ERROR_STOP=1",
                "-v", "run_id=" + runId));
        expectations.forEach((name, value) -> {
            command.add("-v");
            command.add(name + "=" + value);
        });
        command.add("-U");
        command.add(POSTGRES.getUsername());
        command.add("-d");
        command.add(POSTGRES.getDatabaseName());
        command.add("-f");
        command.add(remote);

        var result = POSTGRES.execInContainer(command.toArray(String[]::new));
        if (result.getExitCode() != 0) {
            fail("migrate_reconciliation.sql failed:\n" + result.getStderr());
        }
    }

    private static String scalar(String sql) throws SQLException {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery(sql)) {
            rows.next();
            return rows.getString(1);
        }
    }

    private static void assertFlywayHead(Connection connection) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery("""
                     SELECT COUNT(*), COUNT(DISTINCT version), MAX(version::integer)
                     FROM flyway_schema_history
                     WHERE version IS NOT NULL AND success
                     """)) {
            rows.next();
            assertEquals(CURRENT_MIGRATION_COUNT, rows.getInt(1));
            assertEquals(CURRENT_MIGRATION_COUNT, rows.getInt(2));
            assertEquals(Integer.parseInt(CURRENT_HEAD_VERSION), rows.getInt(3));
        }
    }
}
