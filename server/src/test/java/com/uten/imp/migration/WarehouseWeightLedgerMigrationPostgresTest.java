package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * V743 仓库重量账与单重学习(ADR-135)在非空库上的前向升级: 迁到它的前一版, 按旧口径种入余额/流水/单位,
 * 再迁到 V743 核对存量规整、质量单位播种、新约束、对账视图、履约工作台视图链、IQC 校验函数与退役对象。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WarehouseWeightLedgerMigrationPostgresTest {

    private static final Pattern WEIGHT_LEDGER_FILE =
            Pattern.compile("V(\\d+)__warehouse_weight_ledger_and_learning\\.sql");
    private static final Pattern VERSIONED_FILE = Pattern.compile("V(\\d+)__.*\\.sql");

    private static final UUID WAREHOUSE = UUID.fromString("74500000-0000-4000-8000-000000000001");
    private static final UUID KG_UNIT = UUID.fromString("74500000-0000-4000-8000-000000000011");
    private static final UUID LBS_UNIT = UUID.fromString("74500000-0000-4000-8000-000000000012");
    private static final UUID DELETED_G_UNIT = UUID.fromString("74500000-0000-4000-8000-000000000013");
    private static final UUID PIECE_UNIT = UUID.fromString("74500000-0000-4000-8000-000000000014");
    private static final UUID ZERO_QTY = UUID.fromString("74500000-0000-4000-8000-000000000021");
    private static final UUID NEGATIVE_QTY = UUID.fromString("74500000-0000-4000-8000-000000000022");
    private static final UUID ZERO_WEIGHT = UUID.fromString("74500000-0000-4000-8000-000000000023");
    private static final UUID NEGATIVE_WEIGHT = UUID.fromString("74500000-0000-4000-8000-000000000024");
    private static final UUID KEPT = UUID.fromString("74500000-0000-4000-8000-000000000025");
    private static final UUID KG_GOODS = UUID.fromString("74500000-0000-4000-8000-000000000026");

    @Test
    void upgradeNormalizesStockWeightsAndInstallsTheWarehouseWeightLedger() throws Exception {
        int[] versions = weightLedgerVersionAndPredecessor();
        try (PostgreSQLContainer<?> db = new PostgreSQLContainer<>("postgres:16-alpine")) {
            db.start();
            migrate(db, versions[1]);
            try (Connection connection = connect(db)) {
                seedPreUpgradeStock(connection);
            }

            migrate(db, versions[0]);

            try (Connection connection = connect(db)) {
                // 存量规整: 数量 0 -> 重量 0; 负数量/正数量非正重量 -> 不知道; 质量单位货品 -> 数量 x 系数。
                assertThat(balanceWeight(connection, ZERO_QTY)).isEqualByComparingTo("0");
                assertThat(balanceWeight(connection, NEGATIVE_QTY)).isNull();
                assertThat(balanceWeight(connection, ZERO_WEIGHT)).isNull();
                assertThat(balanceWeight(connection, NEGATIVE_WEIGHT)).isNull();
                assertThat(balanceWeight(connection, KEPT)).isEqualByComparingTo("3.5");
                assertThat(balanceWeight(connection, KG_GOODS)).isEqualByComparingTo("4");
                assertThat(text(connection, "SELECT bool_or(weight_estimated)::text FROM stock_balances"))
                        .isEqualTo("false");

                // 质量单位只按去空白后的精确名称播种(拉丁字母不分大小写), 已删除单位不播种。
                assertThat(text(connection, "SELECT mass_unit_code FROM unit_measurement_profiles WHERE unit_id=?",
                        KG_UNIT)).isEqualTo("KG");
                assertThat(text(connection, "SELECT mass_unit_code FROM unit_measurement_profiles WHERE unit_id=?",
                        LBS_UNIT)).isEqualTo("LB");
                assertThat(count(connection, "SELECT count(*) FROM unit_measurement_profiles WHERE unit_id IN (?,?)",
                        DELETED_G_UNIT, PIECE_UNIT)).isZero();

                // 历史带重量流水保留、无来源(读侧按 MEASURED 读), 记账顺序号已补齐。
                assertThat(text(connection, """
                        SELECT weight::text || '|' || COALESCE(weight_source, '-') || '|' || (ledger_seq IS NOT NULL)::text
                        FROM stock_movements WHERE goods_id=?""", KEPT)).isEqualTo("3.5000|-|true");

                // 新流水: 有重量必须有来源; 余额形状 CHECK。
                assertThatThrownBy(() -> update(connection, """
                        INSERT INTO stock_movements(transaction_date, movement_type, source_doc_type, source_doc_id,
                            source_item_id, goods_id, warehouse_id, direction, qty, unit_rate, weight)
                        VALUES (now(), 11, 'STOCK_DOC', gen_random_uuid(), gen_random_uuid(), ?, ?, 1, 1, 1, 0.5)
                        """, KEPT, WAREHOUSE)).hasMessageContaining("stock_movements_weight_source_presence_chk");
                assertThatThrownBy(() -> update(connection,
                        "UPDATE stock_balances SET weight=0 WHERE goods_id=?", KEPT))
                        .hasMessageContaining("stock_balances_weight_shape_chk");

                // 对账视图: 质量单位货品按数量 x 系数一致; 账链尚未起算的普通货品为 UNKNOWN。
                assertThat(text(connection,
                        "SELECT reconciliation_status FROM v_stock_weight_reconciliation WHERE goods_id=?", KG_GOODS))
                        .isEqualTo("RECONCILED");
                assertThat(text(connection,
                        "SELECT reconciliation_status FROM v_stock_weight_reconciliation WHERE goods_id=?", KEPT))
                        .isEqualTo("UNKNOWN");
                update(connection, """
                        INSERT INTO stock_weight_adjustments(transaction_date, warehouse_id, goods_id, kind,
                            weight_before, weight_after, delta_kg, reason)
                        VALUES (now(), ?, ?, 'MANUAL', 3.5, 3.5, 0, '核重')""", WAREHOUSE, KEPT);
                assertThat(text(connection,
                        "SELECT reconciliation_status FROM v_stock_weight_reconciliation WHERE goods_id=?", KEPT))
                        .isEqualTo("RECONCILED");

                // 履约工作台视图链没有被碰, 仍可查询。
                assertThat(count(connection, "SELECT count(*) FROM v_fulfillment_workbench_actions")).isNotNegative();
                assertThat(count(connection, "SELECT count(*) FROM v_stock_available")).isNotNegative();

                // V442 退役对象消失; 数量来源清单只剩真实表且含称重观测, 不再带行条件。
                for (String retired : List.of("measurement_capture_profiles", "measurement_capture_evidence",
                        "measurement_capture_line_snapshots", "measurement_capture_decision_events",
                        "legacy_measurement_exceptions", "legacy_measurement_profile_snapshots",
                        "legacy_measurement_source_registry", "v_measurement_capture_profile_resolution")) {
                    assertThat(text(connection, "SELECT to_regclass(?)::text", "public." + retired))
                            .as(retired).isNull();
                }
                assertThat(count(connection, """
                        SELECT count(*) FROM fn_goods_quantity_reference_sources()
                        WHERE relation_name = 'goods_weight_observations'""")).isEqualTo(1);
                assertThat(count(connection, """
                        SELECT count(*) FROM fn_goods_quantity_reference_sources()
                        WHERE row_predicate <> 'true' OR to_regclass('public.' || relation_name) IS NULL""")).isZero();

                // 清空业务数据孪生: 重量调整账 CLEAR, 学习三表 PRESERVE。
                String reset = text(connection, "SELECT pg_get_functiondef('business_data_reset()'::regprocedure)");
                assertThat(reset)
                        .contains("('stock_weight_adjustments', 'CLEAR')")
                        .contains("('goods_weight_profiles', 'PRESERVE')")
                        .contains("('goods_weight_observations', 'PRESERVE')")
                        .contains("('goods_weight_estimates', 'PRESERVE')")
                        .doesNotContain("measurement_capture_")
                        .doesNotContain("legacy_measurement_");

                // 权限: 授给已有仓库单据编辑权的部门。
                assertThat(count(connection, """
                        SELECT count(*) FROM department_permissions grant_row
                        JOIN permissions permission ON permission.id = grant_row.permission_id
                        WHERE permission.code = 'stock:weight:manage'""")).isEqualTo(count(connection, """
                        SELECT count(*) FROM department_permissions grant_row
                        JOIN permissions permission ON permission.id = grant_row.permission_id
                        WHERE permission.code = 'stock_doc:edit'"""));
            }

            // IQC 入库校验函数按新列编译并执行到身份校验(临时表形状 = 批次明细表)。
            try (Connection connection = connect(db)) {
                connection.setAutoCommit(false);
                update(connection, "CREATE TEMP TABLE iqc_item_probe (LIKE procurement_iqc_stock_in_batch_items)");
                update(connection, "CREATE TRIGGER probe AFTER INSERT ON iqc_item_probe FOR EACH ROW "
                        + "EXECUTE FUNCTION fn_validate_procurement_iqc_stock_in_item()");
                assertThatThrownBy(() -> update(connection, """
                        INSERT INTO iqc_item_probe(id, batch_id, position, inspection_item_id, pass_event_id,
                            stock_movement_id, warehouse_id, goods_id, expected_remaining_base_qty, base_qty,
                            amount_local, weight, place_snapshot, created_at, stock_sequence)
                        VALUES (gen_random_uuid(), gen_random_uuid(), 1, gen_random_uuid(), gen_random_uuid(),
                            gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 1, 1, 0, NULL, 'A', now(), 1)
                        """)).hasMessageContaining("invalid procurement IQC warehouse stock-in identity or quantity");
                connection.rollback();
            }
        }
    }

    private static void seedPreUpgradeStock(Connection connection) throws SQLException {
        update(connection, "INSERT INTO warehouses(id, code, name, status, is_accountable) VALUES (?, 'V743-W', 'V743 仓', '使用', true)",
                WAREHOUSE);
        update(connection, "INSERT INTO units(id, code, name, status) VALUES (?, 'V743-KG', 'kg', '使用')", KG_UNIT);
        update(connection, "INSERT INTO units(id, code, name, status) VALUES (?, 'V743-LB', ' Lbs ', '使用')", LBS_UNIT);
        update(connection, "INSERT INTO units(id, code, name, status) VALUES (?, 'V743-PC', '只', '使用')", PIECE_UNIT);
        update(connection, "INSERT INTO units(id, code, name, status, is_deleted, deleted_at) "
                + "VALUES (?, 'V743-G', 'g', '禁用', true, now())", DELETED_G_UNIT);
        List<Object[]> balances = new ArrayList<>();
        balances.add(new Object[]{ZERO_QTY, PIECE_UNIT, "0", "5"});
        balances.add(new Object[]{NEGATIVE_QTY, PIECE_UNIT, "-3", "2"});
        balances.add(new Object[]{ZERO_WEIGHT, PIECE_UNIT, "10", "0"});
        balances.add(new Object[]{NEGATIVE_WEIGHT, PIECE_UNIT, "10", "-1"});
        balances.add(new Object[]{KEPT, PIECE_UNIT, "7", "3.5"});
        balances.add(new Object[]{KG_GOODS, KG_UNIT, "4", "9"});
        int sequence = 0;
        for (Object[] row : balances) {
            sequence++;
            update(connection, """
                    INSERT INTO goods(id, code, name, unit_id, code_sequence)
                    VALUES (?, ?, ?, ?, (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))""",
                    row[0], "V743-G" + sequence, "V743 货品 " + sequence, row[1]);
            update(connection, "INSERT INTO stock_balances(warehouse_id, goods_id, qty, weight) VALUES (?, ?, ?, ?)",
                    WAREHOUSE, row[0], new BigDecimal((String) row[2]), new BigDecimal((String) row[3]));
        }
        update(connection, """
                INSERT INTO stock_movements(transaction_date, movement_type, source_doc_type, source_doc_id,
                    source_item_id, goods_id, warehouse_id, direction, qty, unit_rate, amount_local, weight)
                VALUES (now() - interval '1 day', 11, 'STOCK_DOC', gen_random_uuid(), gen_random_uuid(), ?, ?, 1, 7, 1, 0, 3.5)
                """, KEPT, WAREHOUSE);
    }

    /** [V743 实际版本号, 它在目录里的前一个版本号]; 合并重编号后自动跟随。 */
    private static int[] weightLedgerVersionAndPredecessor() throws Exception {
        Path directory = Paths.get(WarehouseWeightLedgerMigrationPostgresTest.class
                .getResource("/db/migration").toURI());
        int ledger = 0;
        List<Integer> versions = new ArrayList<>();
        try (Stream<Path> files = Files.list(directory)) {
            for (Path file : files.toList()) {
                String name = file.getFileName().toString();
                Matcher versioned = VERSIONED_FILE.matcher(name);
                if (!versioned.matches()) {
                    continue;
                }
                versions.add(Integer.parseInt(versioned.group(1)));
                Matcher weight = WEIGHT_LEDGER_FILE.matcher(name);
                if (weight.matches()) {
                    ledger = Integer.parseInt(weight.group(1));
                }
            }
        }
        assertThat(ledger).as("warehouse weight ledger migration on the classpath").isPositive();
        int ledgerVersion = ledger;
        int predecessor = versions.stream().filter(version -> version < ledgerVersion)
                .mapToInt(Integer::intValue).max().orElseThrow();
        return new int[]{ledgerVersion, predecessor};
    }

    private static void migrate(PostgreSQLContainer<?> db, int target) {
        Flyway.configure()
                .dataSource(db.getJdbcUrl(), db.getUsername(), db.getPassword())
                .locations("classpath:db/migration")
                .target(Integer.toString(target))
                .load()
                .migrate();
    }

    private static Connection connect(PostgreSQLContainer<?> db) throws SQLException {
        return DriverManager.getConnection(db.getJdbcUrl(), db.getUsername(), db.getPassword());
    }

    private static int update(Connection connection, String sql, Object... parameters) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            bind(statement, parameters);
            return statement.executeUpdate();
        }
    }

    private static String text(Connection connection, String sql, Object... parameters) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            bind(statement, parameters);
            try (ResultSet result = statement.executeQuery()) {
                assertThat(result.next()).as(sql).isTrue();
                return result.getString(1);
            }
        }
    }

    private static long count(Connection connection, String sql, Object... parameters) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            bind(statement, parameters);
            try (ResultSet result = statement.executeQuery()) {
                assertThat(result.next()).as(sql).isTrue();
                return result.getLong(1);
            }
        }
    }

    private static BigDecimal balanceWeight(Connection connection, UUID goodsId) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(
                "SELECT weight FROM stock_balances WHERE warehouse_id=? AND goods_id=?")) {
            bind(statement, WAREHOUSE, goodsId);
            try (ResultSet result = statement.executeQuery()) {
                assertThat(result.next()).isTrue();
                return result.getBigDecimal(1);
            }
        }
    }

    private static void bind(PreparedStatement statement, Object... parameters) throws SQLException {
        for (int index = 0; index < parameters.length; index++) {
            statement.setObject(index + 1, parameters[index]);
        }
    }
}
