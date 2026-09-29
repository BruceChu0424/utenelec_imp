package com.uten.imp.features.stock.ledger;

import com.uten.imp.features.stock.StockCostMasker;
import com.uten.imp.features.stock.StockReadSideSeed;
import com.uten.imp.features.stock.ledger.dto.StockLedgerPage;
import com.uten.imp.features.stock.ledger.dto.StockLedgerRow;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 货品出入库流水在真实 schema (迁到最新) 上的倒推结存 (ADR-135 §7.1 / §9): 最新一行的结存 = 当前余额,
 * 最早一行之前 = 0; 未知重量让更早的结存重量未知; 范围内部调拨不计本期收发; 类型/日期筛选不改结存;
 * 单号/往来方按登记表关联, 往来方按来源单据权限遮挡。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class StockLedgerQueryPostgresTest {

    private static final LocalDate D1 = LocalDate.of(2026, 8, 1);
    private static final LocalDate D2 = LocalDate.of(2026, 8, 5);
    private static final LocalDate D3 = LocalDate.of(2026, 8, 10);
    private static final LocalDate D4 = LocalDate.of(2026, 8, 15);
    private static final LocalDate D5 = LocalDate.of(2026, 8, 20);
    private static final LocalDate D6 = LocalDate.of(2026, 8, 25);
    private static final LocalDate D7 = LocalDate.of(2026, 9, 1);

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

    /** 造数: 父仓 P 下两个子仓 C1/C2; 其它入 100、销售出 30、调拨 C1→C2 20、销售出红冲 30、其它出 10 (未称)、盘点定重、其它入 5。 */
    record World(UUID parent, UUID c1, UUID c2, UUID goods, UUID exactGoods, UUID supplier, UUID client,
                 String otherInBill, String shipmentBill) {
    }

    static World seed(DataSource ds) throws Exception {
        try (StockReadSideSeed seed = new StockReadSideSeed(ds)) {
            UUID parent = seed.warehouse("流水父仓", null);
            UUID c1 = seed.warehouse("流水子仓一", parent);
            UUID c2 = seed.warehouse("流水子仓二", parent);
            UUID pieces = seed.unit("个", null);
            UUID kilograms = seed.unit("kg", "KG");
            UUID goods = seed.goods("流水螺丝", pieces, null);
            UUID exactGoods = seed.goods("流水铜料", kilograms, null);
            UUID supplier = seed.supplier("流水供应商");
            UUID client = seed.client("流水客户");

            UUID otherIn = seed.stockDoc("OTHER_IN", "LQ-IN-", D1, c1, supplier, null, 1);
            UUID shipment = seed.salesShipment("LQ-SS-", D2, client);
            UUID transfer = seed.stockDoc("TRANSFER", "LQ-TR-", D3, c1, null, null, 1);
            UUID otherOut = seed.stockDoc("OTHER_OUT", "LQ-OUT-", D5, c1, null, null, 1);
            UUID check = seed.stockDoc("CHECK", "LQ-CK-", D6, c1, null, null, 1);
            UUID laterIn = seed.stockDoc("OTHER_IN", "LQ-IN2-", D7, c1, supplier, null, 1);
            UUID transferItem = UUID.randomUUID();
            UUID shipmentItem = UUID.randomUUID();

            seed.movement(D1, 11, "STOCK_DOC", otherIn, UUID.randomUUID(), goods, c1, 1, "100", "10.0000", null, "1000");
            seed.movement(D2, 3, "SALES_SHIPMENT", shipment, shipmentItem, goods, c1, -1, "30", "3.0000", null, "300");
            seed.movement(D3, 8, "STOCK_DOC", transfer, transferItem, goods, c1, -1, "20", "2.0000", null, "200");
            seed.movement(D3, 7, "STOCK_DOC", transfer, transferItem, goods, c2, 1, "20", "2.0000", null, "200");
            seed.movement(D4, 3, "SALES_SHIPMENT", shipment, shipmentItem, goods, c1, 1, "30", "3.0000", null, "300");
            seed.movement(D5, 12, "STOCK_DOC", otherOut, UUID.randomUUID(), goods, c1, -1, "10", null, null, "100");
            seed.adjustment(D6, "COUNT", goods, c1, null, "9.0000", "STOCK_DOC", check, null);
            seed.movement(D7, 11, "STOCK_DOC", laterIn, UUID.randomUUID(), goods, c1, 1, "5", "0.5000", null, "50");
            seed.balance(c1, goods, "75", "9.5000", false, "750", D7);
            seed.balance(c2, goods, "20", "2.0000", false, "200", D3);

            seed.movement(D1, 11, "STOCK_DOC", otherIn, UUID.randomUUID(), exactGoods, c1, 1, "12.34567", "12.3457",
                    "EXACT", "10");
            seed.balance(c1, exactGoods, "12.34567", "12.3457", false, "10", D1);

            String otherInBill = seed.jdbc().queryForObject("SELECT bill_no FROM stock_documents WHERE id = ?",
                    String.class, otherIn);
            String shipmentBill = seed.jdbc().queryForObject("SELECT bill_no FROM sales_shipments WHERE id = ?",
                    String.class, shipment);
            return new World(parent, c1, c2, goods, exactGoods, supplier, client, otherInBill, shipmentBill);
        }
    }

    @Test
    void runningBalancesStartFromCurrentBalancesAndReachZeroBeforeTheFirstRow() throws Exception {
        World world = seed(dataSource);
        StockLedgerPage page = service(false, Set.of()).ledger(world.goods(), null, null, false, null, null, null,
                null, false, 1, 50);

        assertThat(page.getTotal()).isEqualTo(7);
        List<StockLedgerRow> rows = page.getItems();
        // 业务日期倒序, 同日按记账顺序倒序 (调拨入在调拨出之后记, 所以排在前面)。
        assertThat(rows).extracting(StockLedgerRow::balanceQtyAfter).extracting(BigDecimal::stripTrailingZeros)
                .containsExactly(dec("95"), dec("90"), dec("100"), dec("70"), dec("50"), dec("70"), dec("100"));
        assertThat(rows.getFirst().balanceWeightKgAfter()).isEqualByComparingTo("11.5");
        // 盘点定重 (之前重量未知) 与未称的其它出之前, 结存重量都不知道。
        assertThat(rows.get(1).balanceWeightKgAfter()).isNull();
        assertThat(rows.getLast().balanceWeightKgAfter()).isNull();
        assertThat(page.getSummary().openingQty()).isEqualByComparingTo("0");
        assertThat(page.getSummary().closingQty()).isEqualByComparingTo("95");
        assertThat(page.getSummary().closingWeightKg()).isEqualByComparingTo("11.5");
        assertThat(page.getSummary().openingWeightKg()).isNull();
        assertThat(page.getSummary().inQty()).isEqualByComparingTo("105");
        assertThat(page.getSummary().outQty()).isEqualByComparingTo("10");
        assertThat(page.getSummary().internalTransferQty()).isEqualByComparingTo("20");
        assertThat(page.getSummary().inWeightKg()).isEqualByComparingTo("10.5");
        assertThat(page.getSummary().outWeightUnknownRows()).isEqualTo(1);

        // 显示重量调整: 盘点定重行夹在其它入 (9-01) 与其它出 (8-20) 之间, 结存 = 当时重量 11.0。
        StockLedgerPage withAdjustments = service(false, Set.of()).ledger(world.goods(), null, null, false, null, null,
                null, null, true, 1, 50);
        assertThat(withAdjustments.getTotal()).isEqualTo(8);
        StockLedgerRow count = withAdjustments.getItems().get(1);
        assertThat(count.rowKind()).isEqualTo("W");
        assertThat(count.typeLabel()).isEqualTo("盘点定重");
        assertThat(count.balanceQtyAfter()).isEqualByComparingTo("90");
        assertThat(count.balanceWeightKgAfter()).isEqualByComparingTo("11.0");
        assertThat(count.weightKgSigned()).isNull();
    }

    @Test
    void warehouseScopeDecidesWhatCountsAsAnInternalTransfer() throws Exception {
        World world = seed(dataSource);

        StockLedgerPage child = service(false, Set.of()).ledger(world.goods(), world.c1(), null, false, null, null,
                null, null, false, 1, 50);
        assertThat(child.getTotal()).isEqualTo(6);
        assertThat(child.getItems().getFirst().balanceQtyAfter()).isEqualByComparingTo("75");
        assertThat(child.getSummary().openingQty()).isEqualByComparingTo("0");
        // 调往 C2 对子仓一来说是发出。
        assertThat(child.getSummary().outQty()).isEqualByComparingTo("30");
        assertThat(child.getSummary().internalTransferQty()).isEqualByComparingTo("0");

        StockLedgerPage parent = service(false, Set.of()).ledger(world.goods(), world.parent(), null, false, null, null,
                null, null, false, 1, 50);
        assertThat(parent.getTotal()).isEqualTo(7);
        assertThat(parent.getSummary().outQty()).isEqualByComparingTo("10");
        assertThat(parent.getSummary().internalTransferQty()).isEqualByComparingTo("20");
    }

    @Test
    void typeAndDateFiltersSelectRowsWithoutChangingBalances() throws Exception {
        World world = seed(dataSource);

        StockLedgerPage sales = service(false, Set.of()).ledger(world.goods(), null, null, false, null, null, "3",
                null, false, 1, 50);
        assertThat(sales.getItems()).extracting(StockLedgerRow::typeLabel)
                .containsExactly("销售出库(红冲)", "销售出库");
        assertThat(sales.getItems()).extracting(StockLedgerRow::balanceQtyAfter).extracting(BigDecimal::stripTrailingZeros)
                .containsExactly(dec("100"), dec("70"));
        assertThat(sales.getSummary().closingQty()).isEqualByComparingTo("95");
        assertThat(sales.getSummary().outQty()).isEqualByComparingTo("0");

        StockLedgerPage window = service(false, Set.of()).ledger(world.goods(), null, null, false, D3, D5, null, null,
                false, 1, 50);
        assertThat(window.getTotal()).isEqualTo(4);
        assertThat(window.getItems().getFirst().balanceQtyAfter()).isEqualByComparingTo("90");
        assertThat(window.getSummary().openingQty()).isEqualByComparingTo("70");
        assertThat(window.getSummary().closingQty()).isEqualByComparingTo("90");

        StockLedgerPage second = service(false, Set.of()).ledger(world.goods(), null, null, false, null, null, null,
                null, false, 2, 3);
        assertThat(second.getItems()).extracting(StockLedgerRow::balanceQtyAfter).extracting(BigDecimal::stripTrailingZeros)
                .containsExactly(dec("70"), dec("50"), dec("70"));
        assertThat(second.getTotalPages()).isEqualTo(3);

        assertThat(second.getFacets().get("movementType")).extracting(b -> b.value() + ":" + b.count())
                .containsExactly("3:2", "7:1", "8:1", "11:2", "12:1", "W:1");
        assertThat(second.getFacets().get("warehouse")).extracting(b -> b.value() + ":" + b.count())
                .containsExactly(world.c1() + ":7", world.c2() + ":1");
    }

    @Test
    void billNumbersCounterpartsAndMaskingFollowTheSourceRegistry() throws Exception {
        World world = seed(dataSource);

        List<StockLedgerRow> masked = service(false, Set.of("stock:view")).ledger(world.goods(), null, null, false,
                null, null, null, null, false, 1, 50).getItems();
        StockLedgerRow firstIn = masked.getLast();
        assertThat(firstIn.billNo()).isEqualTo(world.otherInBill());
        assertThat(firstIn.sourceDocCode()).isEqualTo("OTHER_IN");
        assertThat(firstIn.counterpartKind()).isEqualTo("SUPPLIER");
        assertThat(firstIn.counterpartName()).isNull();
        assertThat(firstIn.counterpartMasked()).isTrue();
        assertThat(firstIn.amountLocal()).isNull();
        assertThat(firstIn.weightSource()).isEqualTo("MEASURED");
        StockLedgerRow transferOut = masked.get(4);
        assertThat(transferOut.typeLabel()).isEqualTo("调拨出");
        assertThat(transferOut.counterpartKind()).isEqualTo("WAREHOUSE");
        assertThat(transferOut.counterpartName()).startsWith("流水子仓二");
        assertThat(transferOut.counterpartMasked()).isFalse();

        List<StockLedgerRow> visible = service(true, Set.of("stock:view", "stock_doc:view", "sales_shipment:view"))
                .ledger(world.goods(), null, null, false, null, null, null, null, false, 1, 50).getItems();
        assertThat(visible.getLast().counterpartName()).isEqualTo("流水供应商");
        assertThat(visible.getLast().amountLocal()).isEqualByComparingTo("1000");
        StockLedgerRow sale = visible.get(5);
        assertThat(sale.billNo()).isEqualTo(world.shipmentBill());
        assertThat(sale.counterpartName()).isEqualTo("流水客户");
    }

    @Test
    void massUnitGoodsDeriveBalanceWeightFromQuantity() throws Exception {
        World world = seed(dataSource);

        StockLedgerPage page = service(false, Set.of()).ledger(world.exactGoods(), null, null, false, null, null, null,
                null, false, 1, 50);

        assertThat(page.getItems()).singleElement().satisfies(row -> {
            assertThat(row.weightSource()).isEqualTo("EXACT");
            assertThat(row.balanceWeightKgAfter()).isEqualByComparingTo("12.3457");
        });
        assertThat(page.getSummary().openingWeightKg()).isEqualByComparingTo("0");
    }

    private static StockLedgerQueryService service(boolean canViewCost, Set<String> authorities) {
        StockCostMasker masker = mock(StockCostMasker.class);
        when(masker.canView()).thenReturn(canViewCost);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        AuthUser user = mock(AuthUser.class);
        when(user.getPermissions()).thenReturn(authorities);
        when(currentUser.get()).thenReturn(Optional.of(user));
        return new StockLedgerQueryService(new NamedParameterJdbcTemplate(dataSource), masker,
                new StockLedgerSourceAccess(currentUser));
    }

    private static BigDecimal dec(String value) {
        return new BigDecimal(value).stripTrailingZeros();
    }
}
