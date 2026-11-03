package com.uten.imp.features.stock;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.Savepoint;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Real migrated warehouse/measurement rules; every fixture transaction rolls back. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class StockStorageCustodyBudgetPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private Connection connection;
    private JdbcTemplate db;
    private UUID goods, normal, firstBin, secondBin, emptyBin;

    @BeforeAll static void migrate() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("stock_custody_budget");
    }
    @AfterAll static void closeDatabase() throws Exception {
        if (database != null) database.close();
    }
    @BeforeEach void seed() throws Exception {
        connection = database.openConnection();
        connection.setAutoCommit(false);
        db = new JdbcTemplate(new SingleConnectionDataSource(connection, true));
        UUID unit = UUID.randomUUID(), main = UUID.randomUUID();
        goods = UUID.randomUUID();
        normal = UUID.randomUUID();
        db.update("INSERT INTO units(id,code,name) VALUES(?,?,'piece')", unit, "U-" + unit);
        db.update("""
                INSERT INTO goods(id,code,name,min_qty,unit_id,code_sequence)
                VALUES(?,?,'custody budget fixture',10,?,
                  (SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))
                """, goods, "G-" + goods, unit);
        db.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES(?,?,?,'使用',FALSE)",
                main, "ROOT-" + main, "custody main");
        db.update("INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",
                normal, "NORMAL-" + normal, "normal stock", main);
        firstBin = bin(main);
        secondBin = bin(main);
        emptyBin = bin(main);
        balance(normal, "30.0000");
        balance(firstBin, "13.1250");
        balance(secondBin, "7.0001");
        // Global sales promises consume normal public ATP, never named workshop custody.
        db.update("""
                INSERT INTO stock_reservations(id,order_item_id,goods_id,warehouse_id,qty,status,source,source_doc_type)
                VALUES(?,?,?,NULL,5,0,0,'SALES_ORDER')
                """, UUID.randomUUID(), UUID.randomUUID(), goods);
    }
    @AfterEach void rollback() throws Exception {
        if (connection != null) {
            connection.rollback();
            connection.close();
        }
    }

    @Test void namedWorkshopCustodyKeepsItsExactOwnQuantityOutsidePublicAtpAndSafetyStock() {
        assertThat(db.queryForObject("SELECT fn_warehouse_counts_as_usable(?)", Boolean.class, firstBin)).isFalse();
        assertThat(db.queryForObject("SELECT fn_stock_measurement_usable(?,?,NULL)", Boolean.class, firstBin, goods)).isTrue();
        assertThat(movable(firstBin, false)).isEqualByComparingTo("13.1250");
        assertThat(movable(firstBin, true)).isEqualByComparingTo("13.1250");
        assertThat(movable(secondBin, false)).isEqualByComparingTo("7.0001");
    }

    @Test void normalPublicStockAndAnEmptyBinCannotBorrowAnotherWorkshopBinsCustody() {
        assertThat(number("SELECT fn_stock_global_usable(?,NULL)", goods)).isEqualByComparingTo("15.0000");
        assertThat(movable(normal, true)).isEqualByComparingTo("15.0000");
        assertThat(movable(emptyBin, false)).isZero();
        assertThat(db.queryForObject("SELECT fn_stock_storage_same_pool(?,?)", Boolean.class, firstBin, secondBin)).isFalse();
    }

    @Test void actualPositionCountsEvenWhenTheOriginalClaimWasGlobalWithoutRewritingItsOwner() {
        UUID claim = db.queryForObject("SELECT id FROM stock_reservations WHERE goods_id=? AND warehouse_id IS NULL",
                UUID.class, goods);
        UUID orderItem = db.queryForObject("SELECT order_item_id FROM stock_reservations WHERE id=?", UUID.class, claim);
        assertThat(movable(firstBin, false)).isEqualByComparingTo("13.1250");
        db.update("INSERT INTO stock_reservation_storage_positions(reservation_id,warehouse_id,qty) VALUES(?,?,5)", claim, firstBin);
        db.update("INSERT INTO stock_reservation_storage_events(reservation_id,event_type,to_warehouse_id,qty) VALUES(?,'OPEN',?,5)",
                claim, firstBin);
        db.execute("SET CONSTRAINTS trg_check_stock_claim_storage_position IMMEDIATE");
        assertThat(db.queryForObject("SELECT warehouse_id FROM stock_reservations WHERE id=?", UUID.class, claim)).isNull();
        assertThat(movable(firstBin, false)).isEqualByComparingTo("8.1250");
        assertThat(number("SELECT fn_stock_storage_movable(?,?,NULL,CAST(? AS UUID[]),FALSE)",
                firstBin, goods, "{" + orderItem + "}")).isEqualByComparingTo("13.1250");
        assertThat(number("SELECT fn_stock_global_usable(?,NULL)", goods)).isEqualByComparingTo("15.0000");
    }

    @Test void unresolvedMeasurementBlocksCustodyWithoutErasingItsOriginalQuantity() {
        db.update("""
                INSERT INTO stock_measurement_holds(stock_balance_id,warehouse_id,goods_id,color_id,
                  captured_qty,captured_amount_local,captured_weight,captured_weight_estimated)
                SELECT id,warehouse_id,goods_id,color_id,qty,amount_local,weight,COALESCE(weight_estimated,FALSE)
                FROM stock_balances WHERE warehouse_id=? AND goods_id=?
                """, firstBin, goods);
        assertThat(db.queryForObject("SELECT fn_stock_measurement_usable(?,?,NULL)", Boolean.class, firstBin, goods)).isFalse();
        assertThat(movable(firstBin, false)).isZero();
        assertThat(number("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?", firstBin, goods))
                .isEqualByComparingTo("13.1250");
    }

    @Test void defectiveStockStaysOutsideBothStorageChannels() {
        UUID defective = UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,status,is_accountable,is_defective) VALUES(?,?,?,'使用',TRUE,TRUE)",
                defective, "DEFECT-" + defective, "defective stock");
        balance(defective, "99.9999");
        assertThat(movable(defective, false)).isZero();
        assertThat(number("SELECT fn_stock_global_usable(?,NULL)", goods)).isEqualByComparingTo("15.0000");
    }

    @Test void anOpenedWorkshopWithCustodyCannotBeDisabledToBypassItsLifecycleGuard() throws Exception {
        Savepoint beforeAttempt = connection.setSavepoint();
        assertThatThrownBy(() -> db.update("UPDATE warehouses SET status='禁用' WHERE id=?", firstBin))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        connection.rollback(beforeAttempt);
        assertThat(db.queryForObject("SELECT status FROM warehouses WHERE id=?", String.class, firstBin)).isEqualTo("使用");
        assertThat(movable(firstBin, false)).isEqualByComparingTo("13.1250");
    }

    private UUID bin(UUID main) {
        UUID workshop = UUID.randomUUID(), warehouse = UUID.randomUUID();
        UUID production = db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD'", UUID.class);
        db.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES(?,?,?,?,'二级班组')",
                workshop, "W-" + workshop, "custody workshop", production);
        db.update("""
                INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable,is_line_side,workshop_department_id)
                VALUES(?,?,?,?,'使用',TRUE,TRUE,?)
                """, warehouse, "BIN-" + warehouse, "custody bin", main, workshop);
        db.update("INSERT INTO workshop_bins(workshop_department_id,bin_warehouse_id) VALUES(?,?)", workshop, warehouse);
        return warehouse;
    }
    private void balance(UUID warehouse, String qty) {
        db.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES(?,?,?)",
                warehouse, goods, new BigDecimal(qty));
    }
    private BigDecimal movable(UUID warehouse, boolean safety) {
        return number("SELECT fn_stock_storage_movable(?,?,NULL,NULL,?)", warehouse, goods, safety);
    }
    private BigDecimal number(String sql, Object... args) {
        return db.queryForObject(sql, BigDecimal.class, args);
    }
}
