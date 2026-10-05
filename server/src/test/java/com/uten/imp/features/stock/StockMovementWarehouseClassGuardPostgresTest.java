package com.uten.imp.features.stock;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * ADR-146 / V801 真实 PostgreSQL: 出入库类别矩阵在 Java({@link WarehouseClassMovementRule}) 与数据库
 * (fn_stock_movement_class_violation) 逐格一致; 流水落仓守卫、调拨类型守卫、不良品仓预留守卫、
 * 可用量单一口径(v_stock_usable / fn_stock_global_usable)与历史导入会话豁免。
 * 每个场景在自己的事务里做完后回滚, 互不影响。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class StockMovementWarehouseClassGuardPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("stock_movement_class").withUsername("uten").withPassword("uten");
    private static final AtomicInteger SEQUENCE = new AtomicInteger(700000);
    private static JdbcTemplate jdbc;

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure().dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").load().migrate();
        jdbc = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void javaAndDatabaseMatricesAgreeCellByCell() {
        List<String> kinds = new ArrayList<>(List.of("NORMAL", "TO_DEFECTIVE", "DEFECT_RELEASE", "BOGUS"));
        kinds.add(null);
        Boolean[] tri = {null, Boolean.TRUE, Boolean.FALSE};
        int cells = 0;
        for (short type = 1; type <= 25; type++) {
            for (boolean warehouseDefective : new boolean[] {false, true}) {
                for (String kind : kinds) {
                    for (Boolean from : tri) {
                        for (Boolean to : tri) {
                            for (boolean end : new boolean[] {false, true}) {
                                String sql = jdbc.queryForObject(
                                        "SELECT fn_stock_movement_class_violation(CAST(? AS smallint),?,?,?,?,?)",
                                        String.class, type, warehouseDefective, kind, from, to, end);
                                String java = WarehouseClassMovementRule.violation(type, warehouseDefective,
                                        kind == null ? null
                                                : new WarehouseClassMovementRule.TransferSide(kind, from, to, end));
                                assertThat(java).as("type=%s defective=%s kind=%s from=%s to=%s end=%s",
                                        type, warehouseDefective, kind, from, to, end).isEqualTo(sql);
                                cells++;
                            }
                        }
                    }
                }
            }
        }
        assertThat(cells).isEqualTo(25 * 2 * 5 * 3 * 3 * 2);
        for (String code : List.of(WarehouseClassMovementRule.DEFECTIVE_REJECTS_GOOD_BUSINESS,
                WarehouseClassMovementRule.NORMAL_TRANSFER_MIXED, WarehouseClassMovementRule.TO_DEFECTIVE_SHAPE,
                WarehouseClassMovementRule.DEFECT_RELEASE_SHAPE, WarehouseClassMovementRule.TRANSFER_END_MISMATCH)) {
            for (short type = 1; type <= 25; type++) {
                assertThat(WarehouseClassMovementRule.message(code, "成品不良品仓", type))
                        .isEqualTo(jdbc.queryForObject(
                                "SELECT fn_stock_movement_class_message(?, ?, CAST(? AS smallint))",
                                String.class, code, "成品不良品仓", type));
            }
        }
    }

    @Test
    void movementGuardKeepsGoodBusinessOutOfDefectiveWarehouses() {
        inTransaction(c -> {
            Fixture f = fixture(c);
            assertThatThrownBy(() -> movement(c, f.defective, f.goods, (short) 11, 1, "STOCK_DOC", null))
                    .hasMessageContaining("「测试不良品仓」是不良品仓, 其它入库不能进出不良品仓");
            for (short type : new short[] {1, 3, 4, 5, 6, 13, 14, 15, 16, 17, 19, 20}) {
                short current = type;
                assertThatThrownBy(() -> movement(c, f.defective, f.goods, current, 1, "STOCK_DOC", null))
                        .as("type %s", type).hasMessageContaining("不能进出不良品仓");
            }
            // 盘盈盘亏、其它出库/报废、采购退货、委外成品退回(以及它们的红冲)可以进出不良品仓。
            for (short type : new short[] {2, 9, 10, 12, 18}) {
                movement(c, f.defective, f.goods, type, 1, "STOCK_DOC", null);
                movement(c, f.defective, f.goods, type, -1, "STOCK_DOC", null);
            }
            // 良品仓照旧。
            movement(c, f.good, f.goods, (short) 11, 1, "STOCK_DOC", null);
        });
    }

    @Test
    void legacyImportSessionCopiesHistoryWithoutTheNewRule() {
        inTransaction(c -> {
            Fixture f = fixture(c);
            execute(c, "SET LOCAL app.legacy_import = 'on'");
            movement(c, f.defective, f.goods, (short) 11, 1, "STOCK_DOC", null);
        });
    }

    @Test
    void transferKindDecidesWhichClassesBothEndsMayHave() {
        inTransaction(c -> {
            Fixture f = fixture(c);
            UUID mixed = transfer(c, f.good, f.defective, "NORMAL", null, 0);
            assertThatThrownBy(() -> movement(c, f.good, f.goods, (short) 8, -1, "STOCK_DOC", mixed))
                    .hasMessageContaining("普通调拨的调出仓和调入仓必须同是良品仓或同是不良品仓");
            UUID toDefective = transfer(c, f.good, f.defective, "TO_DEFECTIVE", "外观划伤, 判不良", 0);
            movement(c, f.good, f.goods, (short) 8, -1, "STOCK_DOC", toDefective);
            movement(c, f.defective, f.goods, (short) 7, 1, "STOCK_DOC", toDefective);
            // 红冲按原类型反向记同一类型, 仍然放行。
            movement(c, f.defective, f.goods, (short) 7, -1, "STOCK_DOC", toDefective);
            movement(c, f.good, f.goods, (short) 8, 1, "STOCK_DOC", toDefective);
            assertThatThrownBy(() -> movement(c, f.secondGood, f.goods, (short) 7, 1, "STOCK_DOC", toDefective))
                    .hasMessageContaining("必须是调拨单上的调出仓或调入仓");
            UUID wrongRelease = transfer(c, f.good, f.defective, "DEFECT_RELEASE", "复判合格", 0);
            assertThatThrownBy(() -> movement(c, f.good, f.goods, (short) 8, -1, "STOCK_DOC", wrongRelease))
                    .hasMessageContaining("不良复判转回只能从不良品仓调出、调入良品仓");
            UUID release = transfer(c, f.defective, f.good, "DEFECT_RELEASE", "复判合格", 0);
            movement(c, f.defective, f.goods, (short) 8, -1, "STOCK_DOC", release);
            movement(c, f.good, f.goods, (short) 7, 1, "STOCK_DOC", release);
            UUID goodPair = transfer(c, f.good, f.secondGood, "NORMAL", null, 0);
            movement(c, f.secondGood, f.goods, (short) 7, 1, "STOCK_DOC", goodPair);
            // 其它来源的 7/8(车间余料直送退回等)只能落良品仓。
            assertThatThrownBy(() -> movement(c, f.defective, f.goods, (short) 7, 1, "STOCK_DOC", null))
                    .hasMessageContaining("调拨调入不能进出不良品仓");
        });
    }

    @Test
    void transferKindAndReasonAreFixedOnceApprovedAndReasonIsRequired() {
        inTransaction(c -> {
            Fixture f = fixture(c);
            assertThatThrownBy(() -> transfer(c, f.good, f.defective, "TO_DEFECTIVE", null, 1))
                    .hasMessageContaining("stock_documents_defect_reason_chk");
            assertThatThrownBy(() -> transfer(c, f.good, f.defective, "NORMAL", "不该有原因", 0))
                    .hasMessageContaining("stock_documents_defect_reason_chk");
            UUID approved = transfer(c, f.good, f.defective, "TO_DEFECTIVE", "外观划伤", 1);
            assertThatThrownBy(() -> execute(c, "UPDATE stock_documents SET transfer_kind='NORMAL', defect_reason=NULL "
                    + "WHERE id='" + approved + "'"))
                    .hasMessageContaining("已审核的调拨单不能再改调拨类型或原因");
            assertThatThrownBy(() -> execute(c, "INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,status,"
                    + "transfer_kind,defect_reason) VALUES (gen_random_uuid(),'OTHER_IN','" + billNo("QR")
                    + "',CURRENT_DATE,0,'TO_DEFECTIVE','x')"))
                    .hasMessageContaining("stock_documents_transfer_kind_doc_type_chk");
        });
    }

    @Test
    void defectiveWarehouseNeverCarriesAPositiveReservation() {
        inTransaction(c -> {
            Fixture f = fixture(c);
            UUID orderItem = UUID.randomUUID();
            assertThatThrownBy(() -> reservation(c, orderItem, f.goods, f.defective, "2"))
                    .hasMessageContaining("「测试不良品仓」是不良品仓, 里面的货不能被任何订单、生产或委外预留");
            UUID kept = reservation(c, orderItem, f.goods, f.good, "2");
            assertThatThrownBy(() -> execute(c, "UPDATE stock_reservations SET warehouse_id='" + f.defective
                    + "' WHERE id='" + kept + "'"))
                    .hasMessageContaining("是不良品仓");
            // 有没结束的预留时, 良品仓不能改成不良品仓。
            assertThatThrownBy(() -> execute(c, "UPDATE warehouses SET is_defective=true WHERE id='" + f.good + "'"))
                    .hasMessageContaining("现在不能改成不良品仓").hasMessageContaining("没结束的库存预留");
            // 释放(未结量变小)不受影响。
            execute(c, "UPDATE stock_reservations SET released_qty=1 WHERE id='" + kept + "'");
        });
    }

    @Test
    void usableQuantityHasOneDefinitionAndCountsGlobalReservationsOnce() {
        inTransaction(c -> {
            Fixture f = fixture(c);
            balance(c, f.good, f.goods, "10");
            balance(c, f.secondGood, f.goods, "5");
            balance(c, f.defective, f.goods, "7");
            assertThat(scalar(c, "SELECT count(*) FROM v_stock_usable WHERE goods_id='" + f.goods + "'"))
                    .isEqualByComparingTo("2");
            assertThat(scalar(c, "SELECT fn_stock_global_usable('" + f.goods + "', NULL)"))
                    .isEqualByComparingTo("15");
            UUID global = UUID.randomUUID();
            reservation(c, global, f.goods, null, "4");
            UUID local = UUID.randomUUID();
            reservation(c, local, f.goods, f.good, "3");
            // 全局预留 4 只扣一次; 指定仓的预留 3 只在该仓扣。
            assertThat(scalar(c, "SELECT fn_stock_global_usable('" + f.goods + "', NULL)"))
                    .isEqualByComparingTo("8");
            assertThat(scalar(c, "SELECT sum(available_qty) FROM v_stock_usable WHERE goods_id='" + f.goods + "'"))
                    .isEqualByComparingTo("12");
            assertThat(scalar(c, "SELECT fn_stock_global_usable('" + f.goods + "', NULL, ARRAY['" + global
                    + "']::uuid[])")).isEqualByComparingTo("12");
            assertThat(bool(c, "SELECT fn_warehouse_counts_as_usable('" + f.defective + "')")).isFalse();
            assertThat(bool(c, "SELECT fn_warehouse_counts_as_usable('" + f.good + "')")).isTrue();
            assertThat(bool(c, "SELECT fn_warehouse_counts_as_usable('" + f.root + "')")).isFalse();
            assertThat(bool(c, "SELECT fn_warehouse_is_defective_leaf('" + f.defective + "')")).isTrue();
            assertThat(bool(c, "SELECT fn_warehouse_is_defective_leaf('" + f.good + "')")).isFalse();
            assertThat(bool(c, "SELECT fn_warehouse_is_good_stock_leaf('" + f.defective + "')")).isFalse();
        });
    }

    @Test
    void channelPermissionsExistAndInboundGuardsUseTheGoodStockLeaf() {
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM permissions
                WHERE code IN ('stock:defective_transfer','stock:defective_release')
                  AND grant_policy = ARRAY['NORMAL']::text[] AND NOT baseline
                """, Integer.class)).isEqualTo(2);
        for (String guard : List.of("fn_guard_iqc_actual_warehouse_selection()",
                "fn_guard_material_return_receiving_confirmation()", "fn_guard_procurement_iqc_pre_stock_mutation()",
                "fn_guard_production_finished_arrival_registration()", "fn_guard_sales_shipment_picking_evidence()",
                "fn_guard_sales_shipment_picking_warehouse()")) {
            String definition = jdbc.queryForObject("SELECT pg_get_functiondef(CAST(? AS regprocedure))",
                    String.class, guard);
            assertThat(definition).as(guard).contains("fn_warehouse_is_good_stock_leaf(")
                    .doesNotContain("fn_warehouse_is_active_accounting_leaf(");
        }
        assertThat(jdbc.queryForObject("""
                SELECT pg_get_functiondef(p.oid) FROM pg_proc p WHERE p.proname = 'fn_workshop_material_bin_position'
                """, String.class)).doesNotContain("fn_warehouse_is_active_accounting_leaf(");
        assertThat(jdbc.queryForObject(
                "SELECT pg_get_functiondef('fn_guard_qualified_origin_reservation_identity()'::regprocedure)",
                String.class)).doesNotContain("is_defective");
        // 委外领料候选仓(精确专属批次 + 公共可用)与草稿占用、锁发现同一个仓谓词。
        for (String drawFunction : List.of("fn_subcontract_component_entitled_lots(uuid)",
                "fn_subcontract_draw_line_stock(uuid)")) {
            assertThat(jdbc.queryForObject("SELECT pg_get_functiondef(CAST(? AS regprocedure))",
                    String.class, drawFunction)).as(drawFunction)
                    .contains("fn_warehouse_counts_as_usable(")
                    .doesNotContain("fn_warehouse_is_operational_leaf(");
        }
    }

    // ------------------------------------------------------------------ fixture

    private record Fixture(UUID root, UUID good, UUID secondGood, UUID defective, UUID goods) {
    }

    private static Fixture fixture(Connection c) throws SQLException {
        UUID root = existingRoot(c);
        if (root == null) root = warehouse(c, "001", "测试主仓", null, false);
        UUID good = warehouse(c, "G" + SEQUENCE.incrementAndGet(), "测试良品仓" + SEQUENCE.get(), root, false);
        UUID second = warehouse(c, "H" + SEQUENCE.incrementAndGet(), "测试良品二仓" + SEQUENCE.get(), root, false);
        UUID defective = warehouse(c, "D" + SEQUENCE.incrementAndGet(), "测试不良品仓", root, true);
        UUID goods = UUID.randomUUID();
        execute(c, "INSERT INTO goods(id,code,name,code_sequence) VALUES ('" + goods + "','V801-" + goods
                + "','测试货品',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))");
        return new Fixture(root, good, second, defective, goods);
    }

    private static UUID existingRoot(Connection c) throws SQLException {
        try (var statement = c.createStatement();
             ResultSet rows = statement.executeQuery("SELECT fn_warehouse_root_id()")) {
            rows.next();
            return rows.getObject(1, UUID.class);
        }
    }

    private static UUID warehouse(Connection c, String code, String name, UUID parent, boolean defective)
            throws SQLException {
        UUID id = UUID.randomUUID();
        try (PreparedStatement statement = c.prepareStatement("""
                INSERT INTO warehouses(id,code,name,status,is_accountable,is_defective,parent_id)
                VALUES (?,?,?,'使用',true,?,?)""")) {
            statement.setObject(1, id);
            statement.setString(2, code);
            statement.setString(3, name);
            statement.setBoolean(4, defective);
            statement.setObject(5, parent);
            statement.executeUpdate();
        }
        return id;
    }

    private static UUID transfer(Connection c, UUID from, UUID to, String kind, String reason, int status)
            throws SQLException {
        UUID id = UUID.randomUUID();
        try (PreparedStatement statement = c.prepareStatement("""
                INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,status,warehouse_id,to_warehouse_id,
                    transfer_kind,defect_reason)
                VALUES (?,'TRANSFER',?,CURRENT_DATE,?,?,?,?,?)""")) {
            statement.setObject(1, id);
            statement.setString(2, billNo("CB"));
            statement.setShort(3, (short) status);
            statement.setObject(4, from);
            statement.setObject(5, to);
            statement.setString(6, kind);
            statement.setString(7, reason);
            statement.executeUpdate();
        }
        return id;
    }

    private static void movement(Connection c, UUID warehouse, UUID goods, short type, int direction,
                                 String sourceType, UUID sourceDoc) throws SQLException {
        try (PreparedStatement statement = c.prepareStatement("""
                INSERT INTO stock_movements(transaction_date,movement_type,source_doc_type,source_doc_id,
                    goods_id,warehouse_id,direction,qty)
                VALUES (now(),?,?,?,?,?,?,1)""")) {
            statement.setShort(1, type);
            statement.setString(2, sourceType);
            statement.setObject(3, sourceDoc == null ? UUID.randomUUID() : sourceDoc);
            statement.setObject(4, goods);
            statement.setObject(5, warehouse);
            statement.setShort(6, (short) direction);
            statement.executeUpdate();
        }
    }

    private static UUID reservation(Connection c, UUID orderItem, UUID goods, UUID warehouse, String qty)
            throws SQLException {
        UUID id = UUID.randomUUID();
        try (PreparedStatement statement = c.prepareStatement("""
                INSERT INTO stock_reservations(id,order_item_id,owner_type,owner_id,purpose,goods_id,warehouse_id,qty)
                VALUES (?,?,'SALES_ORDER_ITEM',?,'SALES_FULFILLMENT',?,?,?)""")) {
            statement.setObject(1, id);
            statement.setObject(2, orderItem);
            statement.setObject(3, orderItem);
            statement.setObject(4, goods);
            statement.setObject(5, warehouse);
            statement.setBigDecimal(6, new BigDecimal(qty));
            statement.executeUpdate();
        }
        return id;
    }

    private static void balance(Connection c, UUID warehouse, UUID goods, String qty) throws SQLException {
        execute(c, "SET LOCAL session_replication_role = replica");
        execute(c, "INSERT INTO stock_balances(goods_id,warehouse_id,qty) VALUES ('" + goods + "','" + warehouse
                + "'," + qty + ")");
        execute(c, "SET LOCAL session_replication_role = origin");
    }

    private static BigDecimal scalar(Connection c, String sql) throws SQLException {
        try (var statement = c.createStatement(); ResultSet rows = statement.executeQuery(sql)) {
            rows.next();
            return rows.getBigDecimal(1);
        }
    }

    private static boolean bool(Connection c, String sql) throws SQLException {
        try (var statement = c.createStatement(); ResultSet rows = statement.executeQuery(sql)) {
            rows.next();
            return rows.getBoolean(1);
        }
    }

    private static void execute(Connection c, String sql) throws SQLException {
        try (var statement = c.createStatement()) {
            statement.execute(sql);
        }
    }

    private static String billNo(String prefix) {
        return prefix + "20261004" + String.format(java.util.Locale.ROOT, "%06d", SEQUENCE.incrementAndGet());
    }

    @FunctionalInterface
    private interface Scenario {
        void run(Connection connection) throws Exception;
    }

    /** 每个场景独占一个事务, 失败的语句用保存点隔开, 最后整体回滚。 */
    private static void inTransaction(Scenario scenario) {
        jdbc.execute((ConnectionCallback<Void>) connection -> {
            connection.setAutoCommit(false);
            try {
                scenario.run(new SavepointConnection(connection).proxy());
            } catch (RuntimeException | Error failure) {
                throw failure;
            } catch (Exception failure) {
                throw new IllegalStateException(failure);
            } finally {
                connection.rollback();
                connection.setAutoCommit(true);
            }
            return null;
        });
    }

    /** 每条语句前设保存点、失败时回到保存点, 让 assertThatThrownBy 之后同一事务还能继续。 */
    private record SavepointConnection(Connection target) {
        Connection proxy() {
            return (Connection) java.lang.reflect.Proxy.newProxyInstance(Connection.class.getClassLoader(),
                    new Class<?>[] {Connection.class}, (ignored, method, args) -> {
                        Object result = method.invoke(target, args);
                        if (result instanceof java.sql.Statement statement) {
                            return guarded(statement);
                        }
                        return result;
                    });
        }

        private Object guarded(java.sql.Statement statement) {
            Class<?>[] interfaces = statement instanceof PreparedStatement
                    ? new Class<?>[] {PreparedStatement.class} : new Class<?>[] {java.sql.Statement.class};
            return java.lang.reflect.Proxy.newProxyInstance(Connection.class.getClassLoader(), interfaces,
                    (ignored, method, args) -> {
                        boolean executes = method.getName().startsWith("execute");
                        java.sql.Savepoint savepoint = executes ? target.setSavepoint() : null;
                        try {
                            Object result = method.invoke(statement, args);
                            if (savepoint != null) target.releaseSavepoint(savepoint);
                            return result;
                        } catch (java.lang.reflect.InvocationTargetException failure) {
                            if (savepoint != null) target.rollback(savepoint);
                            throw failure.getCause();
                        }
                    });
        }
    }
}
