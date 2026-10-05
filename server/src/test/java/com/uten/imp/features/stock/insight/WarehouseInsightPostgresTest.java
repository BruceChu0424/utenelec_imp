package com.uten.imp.features.stock.insight;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.stock.StockCostMasker;
import com.uten.imp.features.stock.StockReadSideSeed;
import com.uten.imp.features.stock.insight.dto.CycleCountRow;
import com.uten.imp.features.stock.insight.dto.GoodsInsight;
import com.uten.imp.features.stock.insight.dto.HealthRow;
import com.uten.imp.features.stock.insight.dto.LearningRow;
import com.uten.imp.features.stock.insight.dto.WarehouseHealthPage;
import com.uten.imp.features.stock.insight.dto.WeightAlertPage;
import com.uten.imp.features.stock.insight.dto.WeightAlertRow;
import com.uten.imp.features.stock.weight.GoodsWeightEstimateService;
import com.uten.imp.features.stock.weight.GoodsWeightFactsStore;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 库存分析查询在真实 schema (迁到最新) 与造数上的口径 (ADR-135 §7.4 / §9): 先进先出库龄 (红冲按来源行冲减、
 * 范围内部调拨不重置库龄)、呆滞、消耗含调往范围外的调拨出、ABC、盘点建议 (仓库 × 货品 × 颜色)、「我的仓库」范围、
 * 称重异常与汇总、单重学习清单、单货品指标条。as-of 固定为 2026-09-28。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WarehouseInsightPostgresTest {

    private static final LocalDate AS_OF = LocalDate.of(2026, 9, 28);

    private static PostgreSQLContainer<?> container;
    static DataSource dataSource;

    @BeforeAll
    static void start() {
        container = new PostgreSQLContainer<>("postgres:16-alpine");
        container.start();
        Flyway.configure()
                .dataSource(container.getJdbcUrl(), container.getUsername(), container.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
        dataSource = new DriverManagerDataSource(container.getJdbcUrl(), container.getUsername(),
                container.getPassword());
    }

    @AfterAll
    static void stop() {
        if (container != null) {
            container.stop();
        }
    }

    /**
     * 父仓 P 下子仓 A/B。X: 1 月采购 100 + 9-20 其它入 50 - 9-25 销售 70 (另有一笔 8 月采购被整笔红冲);
     * Y: 只有期初余额 40 (没有流水、重量未知); Z: 2025-06 其它入 30 到 A, 9-10 从 A 调 20 到 B。
     */
    record World(String tag, UUID parent, UUID a, UUID b, UUID x, UUID y, UUID z, UUID supplier, UUID workshop) {
    }

    static World seed(DataSource ds) throws Exception {
        try (StockReadSideSeed seed = new StockReadSideSeed(ds)) {
            UUID parent = seed.warehouse("分析父仓", null);
            UUID a = seed.warehouse("分析仓A", parent);
            UUID b = seed.warehouse("分析仓B", parent);
            UUID pieces = seed.unit("个", null);
            UUID x = seed.goods("分析螺丝", pieces, null);
            UUID y = seed.goods("分析垫片", pieces, null);
            UUID z = seed.goods("分析弹簧", pieces, null);
            UUID supplier = seed.supplier("分析供应商");
            UUID client = seed.client("分析客户");
            UUID workshop = UUID.randomUUID();

            UUID receipt = UUID.randomUUID();
            seed.movement(LocalDate.of(2026, 1, 10), 1, "PURCHASE_RECEIPT", receipt, UUID.randomUUID(), x, a, 1,
                    "100", null, null, "100");
            UUID reversedItem = UUID.randomUUID();
            seed.movement(LocalDate.of(2026, 8, 1), 1, "PURCHASE_RECEIPT", receipt, reversedItem, x, a, 1,
                    "10", null, null, "10");
            seed.movement(LocalDate.of(2026, 8, 2), 1, "PURCHASE_RECEIPT", receipt, reversedItem, x, a, -1,
                    "10", null, null, "10");
            UUID otherIn = seed.stockDoc("OTHER_IN", "IN-", LocalDate.of(2026, 9, 20), a, null, null, 1);
            seed.movement(LocalDate.of(2026, 9, 20), 11, "STOCK_DOC", otherIn, UUID.randomUUID(), x, a, 1,
                    "50", "5.0000", null, "50");
            UUID shipment = seed.salesShipment("SS-", LocalDate.of(2026, 9, 25), client);
            seed.movement(LocalDate.of(2026, 9, 25), 3, "SALES_SHIPMENT", shipment, UUID.randomUUID(), x, a, -1,
                    "70", "7.0000", null, "70");
            seed.balance(a, x, "80", "8.0000", false, "80", LocalDate.of(2026, 9, 25));

            seed.balance(a, y, "40", null, false, "40", null);

            UUID zIn = seed.stockDoc("OTHER_IN", "ZIN-", LocalDate.of(2025, 6, 1), a, null, null, 1);
            seed.movement(LocalDate.of(2025, 6, 1), 11, "STOCK_DOC", zIn, UUID.randomUUID(), z, a, 1, "30", null,
                    null, "30");
            UUID transfer = seed.stockDoc("TRANSFER", "ZTR-", LocalDate.of(2026, 9, 10), a, null, null, 1);
            UUID transferItem = UUID.randomUUID();
            seed.movement(LocalDate.of(2026, 9, 10), 8, "STOCK_DOC", transfer, transferItem, z, a, -1, "20", null,
                    null, "20");
            seed.movement(LocalDate.of(2026, 9, 10), 7, "STOCK_DOC", transfer, transferItem, z, b, 1, "20", null,
                    null, "20");
            seed.balance(a, z, "10", "1.0000", true, "10", LocalDate.of(2026, 9, 10));
            seed.balance(b, z, "20", "2.0000", false, "20", LocalDate.of(2026, 9, 10));

            // X 盘过一次 (9-01, 已审); 单重学到但还没学准 (RED)。
            UUID check = seed.stockDoc("CHECK", "CK-", LocalDate.of(2026, 9, 1), a, null, null, 1);
            seed.stockDocItem(check, "CHECK", LocalDate.of(2026, 9, 1), x, new BigDecimal("80"));
            seed.estimate(x, "REFERENCE", "0.1", "RED", null);
            seed.estimate(z, "REFERENCE", "0.1", "GREEN", OffsetDateTime.parse("2026-09-15T02:00:00Z"));

            // 称重: 来料少数 (告警), 正常来料, 领料超发 (告警)。
            seed.observation(LocalDate.of(2026, 9, 20), x, a, "RECEIPT", supplier, null, null, "50", "4.8",
                    "0.1", "5.0", "-4.0", "WARN", "STOCK_DOC", otherIn);
            seed.observation(LocalDate.of(2026, 9, 21), x, a, "RECEIPT", supplier, null, null, "50", "5.0",
                    "0.1", "5.0", "0", "NONE", null, null);
            seed.observation(LocalDate.of(2026, 9, 25), x, a, "DRAW", null, "WORKSHOP", workshop, "70", "7.35",
                    "0.1", "7.0", "5.0", "ALERT", null, null);
            return new World(seed.tag(), parent, a, b, x, y, z, supplier, workshop);
        }
    }

    @Test
    void healthAgesStockFirstInFirstOutAndFlagsDeadStock() throws Exception {
        World w = seed(dataSource);

        WarehouseHealthPage page = service(true).health(w.parent(), null, null, null, false, false, 1, 50,
                "code", "asc", AS_OF);

        assertThat(page.getItems()).hasSize(3);
        HealthRow x = row(page.getItems(), w.x());
        // 新批次先分: 9-20 的 50 在 30 天内, 剩 30 落在 1 月那批 (181-365 天); 被整笔红冲的 8 月批次不算。
        assertThat(x.qty()).isEqualByComparingTo("80");
        assertThat(x.age0_30()).isEqualByComparingTo("50");
        assertThat(x.age181_365()).isEqualByComparingTo("30");
        assertThat(x.ageUnknown()).isEqualByComparingTo("0");
        assertThat(x.out90()).isEqualByComparingTo("70");
        assertThat(x.picks90()).isEqualTo(1);
        assertThat(x.abc()).isEqualTo("A");
        assertThat(x.dead()).isFalse();
        assertThat(x.amountLocal()).isEqualByComparingTo("80");

        HealthRow y = row(page.getItems(), w.y());
        assertThat(y.ageUnknown()).isEqualByComparingTo("40");
        assertThat(y.weightKg()).isNull();
        assertThat(y.dead()).isTrue();
        assertThat(y.abc()).isEqualTo("N");

        // 范围内部调拨既不重置库龄也不算消耗。
        HealthRow z = row(page.getItems(), w.z());
        assertThat(z.qty()).isEqualByComparingTo("30");
        assertThat(z.ageOver365()).isEqualByComparingTo("30");
        assertThat(z.out90()).isEqualByComparingTo("0");
        assertThat(z.dead()).isTrue();

        assertThat(page.getOverview().skuWithStock()).isEqualTo(3);
        assertThat(page.getOverview().deadSku()).isEqualTo(2);
        assertThat(page.getOverview().weightUnknownRows()).isEqualTo(1);
        assertThat(page.getOverview().knownWeightKg()).isEqualByComparingTo("11");
        // 近 30 天称重异常 2 条: 来料少数 1 (9-20) + 领料超发 1 (9-25); 正常来料不算。
        assertThat(page.getOverview().alerts30d()).isEqualTo(2);
        assertThat(page.getOverview().receiptShort30d()).isEqualTo(1);
        assertThat(page.getOverview().drawOver30d()).isEqualTo(1);

        // 只看 A 仓: 调往 B 的 20 对 A 是消耗, Z 不再呆滞。
        WarehouseHealthPage onlyA = service(true).health(w.a(), null, null, null, false, false, 1, 50, null,
                null, AS_OF);
        HealthRow zInA = row(onlyA.getItems(), w.z());
        assertThat(zInA.qty()).isEqualByComparingTo("10");
        assertThat(zInA.out90()).isEqualByComparingTo("20");
        assertThat(zInA.dead()).isFalse();

        // 子仓负责人的默认范围(ADR-149): 只负责 B 仓的账号只看到 B 仓的 Z。
        WarehouseHealthPage mine = service(true, List.of(w.b())).health(null, null, null, null, false,
                false, 1, 50, null, null, AS_OF);
        assertThat(mine.getItems()).extracting(HealthRow::goodsId).containsExactly(w.z());
        assertThat(mine.getOverview().skuWithStock()).isEqualTo(1);
        // 登记了负责人、本账号却不负责任何仓: 一个仓也没有 (不退回全部仓库, 也不绑定空的 IN 列表)。
        WarehouseHealthPage none = service(true, List.of()).health(null, null, null, null, false, false,
                1, 50, null, null, AS_OF);
        assertThat(none.getItems()).isEmpty();
        assertThat(none.getOverview().alerts30d()).isZero();

        WarehouseHealthPage dead = service(false).health(w.parent(), null, null, null, true, false, 1, 50,
                null, null, AS_OF);
        assertThat(dead.getItems()).extracting(HealthRow::goodsId).containsExactlyInAnyOrder(w.y(), w.z());
        assertThat(dead.getItems()).allSatisfy(r -> assertThat(r.amountLocal()).isNull());
        assertThat(dead.getTotals()).extracting(t -> t.key()).contains("weightKg", "weightKg_unknown_rows")
                .doesNotContain("amountLocal");
    }

    @Test
    void cycleCountRanksDueUnknownAndRedTierLinesPerColor() throws Exception {
        World w = seed(dataSource);
        // X 另有白色: B 仓 5 个 (9-20 建账、重量未知); 白色在 A 仓 9-15 单独盘过, 不算无颜色那一行的上次盘点。
        UUID white = UUID.randomUUID();
        try (StockReadSideSeed more = new StockReadSideSeed(dataSource)) {
            more.jdbc().update("INSERT INTO colors(id, code, name, status) VALUES (?, ?, ?, '使用')",
                    white, "C-" + more.tag(), "分析白" + more.tag());
            more.jdbc().update("""
                    INSERT INTO stock_balances(warehouse_id, goods_id, color_id, qty, weight, weight_estimated,
                        amount_local, created_at)
                    VALUES (?, ?, ?, 5, NULL, false, 0, ?)""",
                    w.b(), w.x(), white, StockReadSideSeed.at(LocalDate.of(2026, 9, 20)));
            UUID whiteCheck = more.stockDoc("CHECK", "CKW-", LocalDate.of(2026, 9, 15), w.a(), null, null, 1);
            UUID whiteItem = more.stockDocItem(whiteCheck, "CHECK", LocalDate.of(2026, 9, 15), w.x(),
                    new BigDecimal("0"));
            more.jdbc().update("UPDATE stock_document_items SET color_id = ? WHERE id = ?", white, whiteItem);
        }

        PageResponse<CycleCountRow> page = service(true).cycleCount(w.parent(), true, 1, 50, AS_OF);

        assertThat(page.getItems()).extracting(r -> r.goodsId() + "@" + r.warehouseId() + "/" + r.colorId())
                .containsExactly(w.z() + "@" + w.a() + "/null", w.x() + "@" + w.a() + "/null",
                        w.x() + "@" + w.b() + "/" + white, w.y() + "@" + w.a() + "/null");
        CycleCountRow z = page.getItems().get(0);
        assertThat(z.reasons()).contains("DUE", "ESTIMATED_WEIGHT");
        assertThat(z.lastCountedOn()).isNull();
        CycleCountRow x = page.getItems().get(1);
        assertThat(x.lastCountedOn()).isEqualTo(LocalDate.of(2026, 9, 1));
        assertThat(x.daysSince()).isEqualTo(27);
        assertThat(x.reasons()).containsExactly("RED_TIER");
        // 白色那一行: 按 9-20 建账起算 8 天 (A 类 30 天周期, 未到期), 重量未知; 没有自己的近期流水, 不因单重未学准加分。
        CycleCountRow xWhite = page.getItems().get(2);
        assertThat(xWhite.colorName()).startsWith("分析白");
        assertThat(xWhite.lastCountedOn()).isNull();
        assertThat(xWhite.daysSince()).isEqualTo(8);
        assertThat(xWhite.reasons()).containsExactly("UNKNOWN_WEIGHT");
        assertThat(page.getItems().get(3).reasons()).containsExactly("UNKNOWN_WEIGHT");

        // 子仓负责人的默认范围 = B 仓: 只剩 B 仓的行。
        PageResponse<CycleCountRow> mine = service(true, List.of(w.b())).cycleCount(null, true, 1, 50,
                AS_OF);
        assertThat(mine.getItems()).extracting(CycleCountRow::warehouseId).containsOnly(w.b());
        assertThat(mine.getItems()).extracting(CycleCountRow::colorId).contains(white);
    }

    @Test
    void weightAlertsListCaptureTimeSnapshotsRegimeChangesAndPartySummaries() throws Exception {
        World w = seed(dataSource);

        WeightAlertPage page = service(true).weightAlerts(30, null, null, 1, 100, AS_OF);
        List<WeightAlertRow> ours = page.getItems().stream()
                .filter(r -> Set.of(w.x(), w.z()).contains(r.goodsId())).toList();
        assertThat(ours).extracting(WeightAlertRow::alertKind)
                .containsExactly("DRAW_OVER", "RECEIPT_SHORT", "REGIME_CHANGE");
        WeightAlertRow receipt = ours.get(1);
        assertThat(receipt.supplierName()).isEqualTo("分析供应商");
        assertThat(receipt.estimatedQty()).isEqualByComparingTo("48");
        assertThat(receipt.deviationQty()).isEqualByComparingTo("-2");
        assertThat(receipt.sourceDocCode()).isEqualTo("OTHER_IN");
        assertThat(receipt.billNo()).startsWith("IN-");

        assertThat(page.getSupplierSummary()).filteredOn(s -> w.supplier().equals(s.partyId())).singleElement()
                .satisfies(s -> {
                    assertThat(s.events()).isEqualTo(2);
                    assertThat(s.flagged()).isEqualTo(1);
                    assertThat(s.kg()).isEqualByComparingTo("0.2");
                });
        assertThat(page.getWorkshopSummary()).filteredOn(s -> w.workshop().equals(s.partyId())).singleElement()
                .satisfies(s -> {
                    assertThat(s.flagged()).isEqualTo(1);
                    assertThat(s.kg()).isEqualByComparingTo("0.35");
                });

        WeightAlertPage receipts = service(true).weightAlerts(30, "RECEIPT", w.supplier(), 1, 50, AS_OF);
        assertThat(receipts.getItems()).extracting(WeightAlertRow::alertKind).containsExactly("RECEIPT_SHORT");
        WeightAlertPage regimes = service(true).weightAlerts(30, "REGIME", null, 1, 100, AS_OF);
        assertThat(regimes.getItems()).filteredOn(r -> w.z().equals(r.goodsId())).singleElement()
                .extracting(WeightAlertRow::alertLabel).isEqualTo("单重可能已变化(换批/换料?)");
    }

    @Test
    void learningWorklistAndGoodsStripUseTheWeightParamsResolution() throws Exception {
        World w = seed(dataSource);

        PageResponse<LearningRow> needs = service(true).learning(null, w.tag(), 1, 50, AS_OF);
        assertThat(needs.getItems()).extracting(LearningRow::goodsId).contains(w.x()).doesNotContain(w.z());
        LearningRow x = needs.getItems().stream().filter(r -> w.x().equals(r.goodsId())).findFirst().orElseThrow();
        assertThat(x.basis()).isEqualTo("LEARNED");
        assertThat(x.tier()).isEqualTo("RED");
        assertThat(x.observations()).isEqualTo(3);
        assertThat(x.movements90d()).isEqualTo(4);
        assertThat(x.nRef()).isEqualTo(5);
        assertThat(x.nDraw()).isEqualTo(0);

        PageResponse<LearningRow> all = service(true).learning("ALL", w.tag(), 1, 50, AS_OF);
        assertThat(all.getItems()).extracting(LearningRow::goodsId).contains(w.x(), w.z());

        GoodsInsight strip = service(false).goods(w.x(), AS_OF);
        assertThat(strip.qty()).isEqualByComparingTo("80");
        assertThat(strip.weightKg()).isEqualByComparingTo("8");
        assertThat(strip.age0_30()).isEqualByComparingTo("50");
        assertThat(strip.out90()).isEqualByComparingTo("70");
        assertThat(strip.unitWeightKg()).isEqualByComparingTo("0.1");
        assertThat(strip.tier()).isEqualTo("RED");
        assertThat(strip.unitName()).isEqualTo("个");
    }

    private static HealthRow row(List<HealthRow> rows, UUID goodsId) {
        return rows.stream().filter(r -> goodsId.equals(r.goodsId())).findFirst().orElseThrow();
    }

    private static WarehouseInsightService service(boolean canViewCost) {
        return service(canViewCost, null);
    }

    /**
     * @param mine 子仓负责人的默认仓库数据范围(ADR-149, 由仓库主档的端口给); null = 主管/不限。
     *             选了某个仓时端口给该仓子树(fn_warehouse_scope_ids)。
     */
    private static WarehouseInsightService service(boolean canViewCost, List<UUID> mine) {
        StockCostMasker masker = mock(StockCostMasker.class);
        when(masker.canView()).thenReturn(canViewCost);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenReturn(Optional.empty());
        NamedParameterJdbcTemplate db = new NamedParameterJdbcTemplate(dataSource);
        WarehouseTaskScopePort scopes = mock(WarehouseTaskScopePort.class);
        when(scopes.current(any())).thenAnswer(call -> {
            UUID requested = call.getArgument(0);
            if (requested != null) {
                return new WarehouseTaskScopePort.WarehouseTaskScope(true, db.queryForList(
                        "SELECT unnest(fn_warehouse_scope_ids(ARRAY[CAST(:id AS uuid)]))",
                        java.util.Map.of("id", requested), UUID.class), false);
            }
            return mine == null ? WarehouseTaskScopePort.WarehouseTaskScope.ALL
                    : new WarehouseTaskScopePort.WarehouseTaskScope(true, mine, false);
        });
        GoodsWeightEstimateService weights = new GoodsWeightEstimateService(db, new GoodsWeightFactsStore(db),
                currentUser, new ObjectMapper(), new DataSourceTransactionManager(dataSource), 0.00005);
        return new WarehouseInsightService(db, masker, weights, scopes);
    }
}
