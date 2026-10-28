package com.uten.imp.features.stock;

import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestMethodOrder;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * B2 库存月度汇总在真实 PostgreSQL（完整迁移链，含 V949 触发器）上的证据：
 * 增量维护精确覆盖迟到/跨月流水；重建函数可复现增量状态；完整性断言与
 * 分块核对能抓取直接改写流水（绕过应用路径）造成的投影漂移；每日对账
 * 只聚合月度汇总小表。绝不自动调平——漂移必须可见且可追因。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class StockMonthlySummaryPostgresTest {

    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("b2_stock_monthly")
            .withUsername("fixture_admin")
            .withPassword("uten")
            .withCreateContainerCmdModifier(cmd -> cmd.getHostConfig()
                    .withMemory(768L * 1024 * 1024).withNanoCPUs(1_000_000_000L));

    private static final UUID UNIT = UUID.randomUUID();
    private static final UUID GOODS = UUID.randomUUID();
    private static final UUID GOODS_OTHER = UUID.randomUUID();
    private static final UUID WAREHOUSE = UUID.randomUUID();
    private static final UUID COLOR = UUID.randomUUID();

    private static JdbcTemplate db;
    private static StockReconciliationService reconciliation;
    private static StockMonthlyVerificationScheduler verifier;

    @BeforeAll
    static void migrate() {
        PG.start();
        TestFlyway.configure()
                .dataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
        db = new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()));
        db.update("INSERT INTO units(id,code,name) VALUES(?,'B2-U','B2单位')", UNIT);
        db.update("INSERT INTO goods(id,code,name,unit_id,code_sequence) VALUES(?,'B2-GOODS','B2货品',?,1)", GOODS, UNIT);
        db.update("INSERT INTO goods(id,code,name,unit_id,code_sequence) VALUES(?,'B2-OTHER','B2对照货品',?,2)", GOODS_OTHER, UNIT);
        db.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES(?,'B2-WH','B2仓库','使用',true)", WAREHOUSE);
        db.update("INSERT INTO colors(id,code,name) VALUES(?,'B2-COLOR','B2颜色')", COLOR);
        reconciliation = new StockReconciliationService(db);
        verifier = new StockMonthlyVerificationScheduler(reconciliation, db, 250);
    }

    /** 迁移安装了增量维护、可重建与核对资产。 */
    @Test
    @Order(1)
    void migrationInstallsIncrementalUpkeepAndVerificationAssets() {
        assertThat(db.queryForObject(
                "SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgname='trg_upsert_stock_monthly_summary'",
                Long.class)).isEqualTo(1L);
        assertThat(db.queryForObject(
                "SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgname LIKE 'trg_touch_party_summary%'",
                Long.class)).isGreaterThanOrEqualTo(7L);
        assertThat(db.queryForObject(
                "SELECT count(*) FROM stock_monthly_verification_state WHERE singleton", Long.class)).isEqualTo(1L);
        // 迁移时已完成一次全量重建并通过断言（空库也应通过）。
        db.queryForObject("SELECT fn_assert_stock_monthly_integrity()", String.class);
    }

    /** 触发器增量：正常、跨月、迟到回填、带颜色维度都精确落进各自业务月。 */
    @Test
    @Order(2)
    void insertsMaintainMonthlyCellsExactlyIncludingLateBackdatedRows() {
        movement("2025-11-05", 1, 1, "10", "100");
        movement("2025-11-20", 3, -1, "4", "40");
        movement("2025-12-01", 1, 1, "5", "50");
        // 迟到：业务月早于已存在的 11 月单元格。
        movement("2025-10-02", 1, 1, "3", "30");
        // 同月同类型同仓同货：无色与有色是两个单元格（color_key 派生列）。
        movementWithColor("2025-11-25", 1, 1, "2", "20", COLOR);

        assertThat(cellQty("2025-10-01", 1, GOODS, null)).isEqualByComparingTo("3");
        assertThat(cellCount("2025-10-01", 1, GOODS, null)).isEqualTo(1L);
        assertThat(cellQty("2025-11-01", 1, GOODS, null)).isEqualByComparingTo("10");
        assertThat(cellQty("2025-11-01", 3, GOODS, null)).isEqualByComparingTo("-4");
        assertThat(cellQty("2025-11-01", 1, GOODS, COLOR)).isEqualByComparingTo("2");
        assertThat(cellQty("2025-12-01", 1, GOODS, null)).isEqualByComparingTo("5");
        assertThat(db.queryForObject(
                "SELECT COALESCE(SUM(movement_count),0) FROM stock_monthly_summaries", Long.class)).isEqualTo(5L);
        db.queryForObject("SELECT fn_assert_stock_monthly_integrity()", String.class);
    }

    /** 重建函数在清空后可从原始流水精确复现增量状态（影子等价）。 */
    @Test
    @Order(3)
    void rebuildReproducesTheIncrementalStateExactly() {
        List<Map<String, Object>> before = cells();
        db.update("DELETE FROM stock_monthly_summaries");
        Long rebuilt = db.queryForObject("SELECT fn_rebuild_stock_monthly_summaries()", Long.class);
        assertThat(rebuilt).isEqualTo((long) before.size());
        assertThat(cells()).containsExactlyInAnyOrderElementsOf(before);
        db.queryForObject("SELECT fn_assert_stock_monthly_integrity()", String.class);
    }

    /** 日常对账：余额=Σ汇总时零漂移；改余额表即刻发现（不再全流水 SUM）。 */
    @Test
    @Order(4)
    void reconciliationComparesBalanceAgainstMonthlySummaries() {
        // Σ全部净额 = 10-4+3+5+2(有色) = 16；无色维度 14。
        db.update("INSERT INTO stock_balances(id,warehouse_id,goods_id,color_id,qty) "
                + "VALUES(gen_random_uuid(),?,?,NULL,14)", WAREHOUSE, GOODS);
        db.update("INSERT INTO stock_balances(id,warehouse_id,goods_id,color_id,qty) "
                + "VALUES(gen_random_uuid(),?,?,?,2)", WAREHOUSE, GOODS, COLOR);
        var report = reconciliation.driftReport(50);
        assertThat(report.total()).isZero();
        assertThat(report.rows()).isEmpty();

        db.update("UPDATE stock_balances SET qty=13 WHERE goods_id=? AND color_id IS NULL", GOODS);
        report = reconciliation.driftReport(50);
        assertThat(report.total()).isEqualTo(1L);
        assertThat(report.rows()).hasSize(1);
        assertThat((BigDecimal) report.rows().getFirst().get("balance_qty")).isEqualByComparingTo("13");
        assertThat((BigDecimal) report.rows().getFirst().get("flow_qty")).isEqualByComparingTo("14");
        // 恢复一致。
        db.update("UPDATE stock_balances SET qty=14 WHERE goods_id=? AND color_id IS NULL", GOODS);
        assertThat(reconciliation.driftReport(50).total()).isZero();
    }

    /**
     * 分块完整核对：直接 UPDATE 历史流水（绕过应用写入路径，INSERT 触发器看不到）
     * 造成投影漂移——低峰核对必须发现，且修复途径是重建而不是自动调平。
     */
    @Test
    @Order(5)
    void chunkedVerificationDetectsDirectMovementTampering() {
        assertThat(verifier.runOnce()).isEmpty();

        db.update("UPDATE stock_movements SET qty=99 WHERE goods_id=? AND movement_type=1 "
                + "AND transaction_date<'2025-12-01' AND color_id IS NULL AND qty=10", GOODS);
        db.update("UPDATE stock_movements SET qty=6 WHERE goods_id=? AND movement_type=1 "
                + "AND transaction_date<'2025-11-01' AND qty=3", GOODS);

        assertThatThrownBy(() -> db.queryForObject("SELECT fn_assert_stock_monthly_integrity()", String.class))
                .hasMessageContaining("stock monthly summary differs");
        List<Map<String, Object>> drift = verifier.runOnce();
        assertThat(drift).hasSize(2);
        // 游程状态如实记录漂移，绝不修复。
        assertThat(reconciliation.verificationState().lastDriftCount()).isEqualTo(2L);

        // 修复途径=重建（从权威流水整建），重建后核对恢复干净。
        db.update("DELETE FROM stock_monthly_summaries");
        db.queryForObject("SELECT fn_rebuild_stock_monthly_summaries()", Long.class);
        db.queryForObject("SELECT fn_assert_stock_monthly_integrity()", String.class);
        assertThat(verifier.runOnce()).isEmpty();
    }

    /** 游程滚动：核对完最后一个货品后回绕并累计圈数。 */
    @Test
    @Order(6)
    void verificationCursorWrapsAfterTheLastGoods() {
        verifier.runOnce();
        verifier.runOnce();
        assertThat(reconciliation.verificationState().fullCycles()).isGreaterThanOrEqualTo(1L);
    }

    private static void movement(String date, int type, int direction, String qty, String amount) {
        movementWithColor(date, type, direction, qty, amount, null);
    }

    private static void movementWithColor(String date, int type, int direction, String qty,
                                          String amount, UUID color) {
        db.update("INSERT INTO stock_movements(id,goods_id,color_id,warehouse_id,transaction_date,"
                        + "movement_type,direction,qty,amount_local,source_doc_type) "
                        + "VALUES(gen_random_uuid(),?,?,?,?::date,?,?::int2,?::numeric,?::numeric,'B2_TEST')",
                GOODS, color, WAREHOUSE, date, type, direction, qty, amount);
    }

    private static BigDecimal cellQty(String month, int type, UUID goods, UUID color) {
        return db.queryForObject("SELECT qty_net FROM stock_monthly_summaries "
                + "WHERE month_start=?::date AND movement_type=?::int2 AND goods_id=? "
                + "AND color_id IS NOT DISTINCT FROM ?", BigDecimal.class, month, type, goods, color);
    }

    private static Long cellCount(String month, int type, UUID goods, UUID color) {
        return db.queryForObject("SELECT movement_count FROM stock_monthly_summaries "
                + "WHERE month_start=?::date AND movement_type=?::int2 AND goods_id=? "
                + "AND color_id IS NOT DISTINCT FROM ?", Long.class, month, type, goods, color);
    }

    private static List<Map<String, Object>> cells() {
        return db.queryForList("SELECT month_start,movement_type,goods_id,warehouse_id,color_id,"
                + "qty_net,amt_local_net,movement_count,first_ledger_seq,last_ledger_seq "
                + "FROM stock_monthly_summaries ORDER BY month_start,movement_type,color_id NULLS FIRST");
    }
}
