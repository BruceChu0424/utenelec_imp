package com.uten.imp.features.stock;

import com.uten.imp.features.stock.dto.InstantInventoryRow;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.*;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/** Executes the production query, including pagination, facets, date bounds and masking. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class InstantInventoryPeriodPostgresTest {
    static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine");
    static JdbcTemplate db;
    static NamedParameterJdbcTemplate named;
    final UUID goods = UUID.randomUUID(), color = UUID.randomUUID(), parent = UUID.randomUUID();
    final UUID one = UUID.randomUUID(), two = UUID.randomUUID(), defective = UUID.randomUUID();
    EntityManager em;
    StockCostMasker masker;
    StockQueryService service;

    @BeforeAll static void start() {
        PG.start();
        var source = new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword());
        db = new JdbcTemplate(source); named = new NamedParameterJdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db, "goods", "colors", "units", "warehouses", "material_categories",
                "stock_balances", "stock_movements", "stock_measurement_holds", "procurement_inspection_items",
                "goods_weight_estimates", "production_plan_items", "production_plans");
    }
    @AfterAll static void stop() { PG.stop(); }

    @BeforeEach void fixture() {
        db.execute("TRUNCATE goods,colors,units,warehouses,material_categories,stock_balances,stock_movements,"
                + "stock_measurement_holds,procurement_inspection_items,goods_weight_estimates,production_plan_items,production_plans");
        em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> query(call.getArgument(0)));
        masker = mock(StockCostMasker.class); when(masker.canView()).thenReturn(true);
        service = new StockQueryService(mock(StockBalanceRepository.class), em, masker);
        UUID unit = UUID.randomUUID();
        db.update("INSERT INTO units(id,name) VALUES(?,'个')", unit);
        db.update("INSERT INTO goods(id,code,name,unit_id) VALUES(?,'PERIOD','日期测试货品',?)", goods, unit);
        db.update("INSERT INTO colors(id,name) VALUES(?,'红色')", color);
        warehouse(parent, null, false); warehouse(one, parent, false); warehouse(two, parent, false);
        warehouse(defective, parent, true);
        balance(one, color, "130", "650"); balance(two, color, "40", "200");
        balance(defective, color, "1000", "5000");
        // China date boundary: before the first day is excluded; the last day's last second is included.
        movement(one, color, 1, 1, "2026-10-01T00:00:00+08:00", "30", "150", null, null);
        movement(one, color, 1, 1, "2026-09-30T23:59:59+08:00", "999", "4995", null, null);
        movement(one, color, 3, -1, "2026-10-31T23:59:59+08:00", "10", "50", null, null);
        // Sales reversal reduces issues instead of inflating receipts.
        movement(one, color, 3, 1, "2026-10-15T12:00:00+08:00", "2", "10", null, null);
        movement(one, color, 1, 1, "2026-11-01T00:00:00+08:00", "8", "40", null, null);
        UUID doc = UUID.randomUUID(), item = UUID.randomUUID();
        movement(one, color, 8, -1, "2026-10-20T12:00:00+08:00", "5", "25", doc, item);
        movement(two, color, 7, 1, "2026-10-20T12:00:00+08:00", "5", "25", doc, item);
        movement(defective, color, 1, 1, "2026-10-10T12:00:00+08:00", "1000", "5000", null, null);
    }

    @Test void parentScopeUsesNetMovementsAndHistoricalLedgerCostInsteadOfCurrentQuantity() {
        var response = service.instantInventory(filter(parent, true, null), 1, 20, "closingQty", "desc");
        var row = response.getItems().getFirst();
        assertThat(row.getQty()).isEqualByComparingTo("170");
        assertThat(row.getPeriodInQty()).isEqualByComparingTo("30");
        assertThat(row.getPeriodOutQty()).isEqualByComparingTo("8");
        assertThat(row.getClosingQty()).isEqualByComparingTo("162");
        assertThat(row.getPeriodCostAmount()).isEqualByComparingTo("810");
        assertThat(row.getCostPrice()).isEqualByComparingTo("5");
        assertThat(row.isPeriodSelected()).isTrue();
        assertThat(response.getTotal()).isEqualTo(1);
    }

    @ParameterizedTest
    @ValueSource(strings = {"/api/stock/instant-inventory", "/api/stock/instant-inventory/attention"})
    void httpDatesReachTheDatabaseAndSerializeThePeriodContract(String path) throws Exception {
        var http = MockMvcBuilders.standaloneSetup(new StockQueryController(service)).build();
        http.perform(get(path).param("warehouseId", parent.toString())
                        .param("attention", "UNKNOWN_WEIGHT")
                        .param("dateFrom", "2026-10-01").param("dateTo", "2026-10-31"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("items[0].periodSelected").value(true))
                .andExpect(jsonPath("items[0].periodInQty").value(30))
                .andExpect(jsonPath("items[0].periodOutQty").value(8))
                .andExpect(jsonPath("items[0].closingQty").value(162))
                .andExpect(jsonPath("items[0].periodCostAmount").value(810))
                .andExpect(jsonPath("items[0].costPrice").value(5));

        // A later range must change both flow and the historical closing balance.
        // The present balance alone cannot satisfy this assertion.
        when(masker.canView()).thenReturn(false);
        http.perform(get(path).param("warehouseId", parent.toString())
                        .param("attention", "UNKNOWN_WEIGHT")
                        .param("dateFrom", "2026-11-01").param("dateTo", "2026-11-01"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("items[0].periodSelected").value(true))
                .andExpect(jsonPath("items[0].periodInQty").value(8))
                .andExpect(jsonPath("items[0].periodOutQty").value(0))
                .andExpect(jsonPath("items[0].closingQty").value(170))
                .andExpect(jsonPath("items[0].costMasked").value(true))
                .andExpect(jsonPath("items[0].periodCostAmount").isEmpty())
                .andExpect(jsonPath("items[0].costPrice").isEmpty());
    }

    @Test void explicitLeafIncludesCrossBoundaryTransferAndEmptyAllowedScopeCannotExpand() {
        var row = service.instantInventoryRows(filter(one, true, null), 1, 20, null, null).getItems().getFirst();
        assertThat(row.getPeriodOutQty()).isEqualByComparingTo("13");
        assertThat(row.getClosingQty()).isEqualByComparingTo("122");
        assertThat(service.instantInventoryRowsInWarehouseScope(filter(parent, true, null), Set.of(), 1, 20, null, null)
                .getItems()).isEmpty();
    }

    @Test void missingRangeNeverReturnsInventedZerosAndZeroClosingHasNoInventedPrice() {
        var noPeriod = service.instantInventoryRows(filter(parent, false, null), 1, 20, null, null).getItems().getFirst();
        assertThat(noPeriod.isPeriodSelected()).isFalse();
        assertThat(noPeriod.getClosingQty()).isNull();
        assertThat(noPeriod.getCostPrice()).isNull();
        db.update("UPDATE stock_balances SET qty=8,amount_local=40 WHERE warehouse_id=?", one);
        db.update("UPDATE stock_balances SET qty=0,amount_local=0 WHERE warehouse_id=?", two);
        var zero = service.instantInventoryRows(filter(parent, true, null), 1, 20, null, null).getItems().getFirst();
        assertThat(zero.getClosingQty()).isEqualByComparingTo("0");
        assertThat(zero.getCostPrice()).isNull();
    }

    @Test void maskingAlsoRejectsCostSortAndNullColorAndSearchKeepTheirOwnPeriodValues() {
        balance(one, null, "4", "28");
        movement(one, null, 1, 1, "2026-10-10T12:00:00+08:00", "4", "28", null, null);
        when(masker.canView()).thenReturn(false);
        var response = service.instantInventoryRows(filter(parent, true, "日期"), 1, 1, "closingQty", "asc");
        var row = response.getItems().getFirst();
        assertThat(row.getColorId()).isNull();
        assertThat(row.getPeriodInQty()).isEqualByComparingTo("4");
        assertThat(row.getClosingQty()).isEqualByComparingTo("4");
        assertThat(row.getPeriodCostAmount()).isNull();
        assertThat(row.getCostPrice()).isNull();
        assertThat(row.isCostMasked()).isTrue();
        assertThat(response.getTotal()).isEqualTo(2);
        assertThat(service.instantInventoryRows(filter(parent, true, "日期"), 2, 1, "closingQty", "asc")
                .getItems().getFirst().getColorId()).isEqualTo(color);
        for (String sort : List.of("costPrice", "periodCostAmount")) {
            assertThatThrownBy(() -> service.instantInventoryRows(filter(parent, true, null), 1, 20, sort, "asc"))
                    .isInstanceOf(com.uten.imp.common.web.ApiException.class);
        }
    }

    @Test void largeMovementHistoryIsAggregatedBeforePagingAndPartialDatesFailClosed() {
        db.update("INSERT INTO stock_movements(id,goods_id,color_id,warehouse_id,movement_type,direction,transaction_date,qty,amount_local,source_doc_type)"
                + " SELECT gen_random_uuid(),?,?,?,1,1,'2026-10-12T12:00:00+08:00'::timestamptz,1,5,'TEST' FROM generate_series(1,25000)",
                goods, color, one);
        db.update("UPDATE stock_balances SET qty=qty+25000,amount_local=amount_local+125000 WHERE warehouse_id=?", one);
        var row = service.instantInventory(filter(parent,true,null),1,1,"periodInQty","desc").getItems().getFirst();
        assertThat(row.getPeriodInQty()).isEqualByComparingTo("25030");
        assertThat(row.getClosingQty()).isEqualByComparingTo("25162");
        assertThat(row.getPeriodCostAmount()).isEqualByComparingTo("125810");
        assertThatThrownBy(() -> new StockQueryService.InstantInventoryFilter(null,null,false,false,null,
                null,null,null,null,null,null,null,false,true,false,false,LocalDate.of(2026,10,1),null))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThatThrownBy(() -> new StockQueryService.InstantInventoryFilter(null,null,false,false,null,
                null,null,null,null,null,null,null,false,true,false,false,LocalDate.of(2026,11,1),LocalDate.of(2026,10,1)))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
    }

    StockQueryService.InstantInventoryFilter filter(UUID warehouse, boolean selected, String keyword) {
        return new StockQueryService.InstantInventoryFilter(null, warehouse, false, false, keyword, null,
                null, null, null, null, null, null, false, true, false, false,
                selected ? LocalDate.of(2026,10,1) : null, selected ? LocalDate.of(2026,10,31) : null);
    }
    void warehouse(UUID id, UUID parentId, boolean bad) {
        db.update("INSERT INTO warehouses(id,code,name,parent_id,is_accountable,is_defective,is_line_side) VALUES(?,?,?, ?,true,?,false)",
                id, id.toString(), "仓库", parentId, bad);
    }
    void balance(UUID warehouse, UUID colorId, String qty, String amount) {
        db.update("INSERT INTO stock_balances(id,goods_id,color_id,warehouse_id,qty,amount_local) VALUES(?,?,?,?,?,?)",
                UUID.randomUUID(), goods, colorId, warehouse, new BigDecimal(qty), new BigDecimal(amount));
    }
    void movement(UUID warehouse, UUID colorId, int type, int direction, String date, String qty, String amount, UUID doc, UUID item) {
        db.update("INSERT INTO stock_movements(id,goods_id,color_id,warehouse_id,movement_type,direction,transaction_date,qty,amount_local,source_doc_type,source_doc_id,source_item_id)"
                + " VALUES(?,?,?,?,?,?,?,?,?,'TEST',?,?)", UUID.randomUUID(), goods, colorId, warehouse, type, direction,
                OffsetDateTime.parse(date), new BigDecimal(qty), new BigDecimal(amount), doc, item);
    }
    Query query(String sql) {
        Map<String,Object> parameters = new LinkedHashMap<>();
        return mock(Query.class, call -> {
            String method = call.getMethod().getName();
            if (method.equals("setParameter")) { parameters.put(call.getArgument(0),call.getArgument(1)); return call.getMock(); }
            if (method.equals("getResultList")) return named.query(sql, parameters, (rs, row) -> {
                if (rs.getMetaData().getColumnCount() == 1) return rs.getObject(1);
                Object[] values = new Object[rs.getMetaData().getColumnCount()];
                for (int column=0; column<values.length; column++) values[column] = rs.getObject(column+1);
                return values;
            });
            if (method.equals("getSingleResult")) return named.queryForObject(sql, parameters, Object.class);
            if (call.getMethod().getReturnType().isAssignableFrom(Query.class)) return call.getMock();
            return org.mockito.Answers.RETURNS_DEFAULTS.answer(call);
        });
    }
}
