package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.stock.dto.InstantInventoryRow;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Actual Hibernate/PG binding against all migrations; every seeded row lives in a disposable container. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000", "uten.workshop-material.auto-close.enabled=false",
        "uten.ai.job-poll-initial-delay-ms=3600000", "uten.ai.housekeeping-initial-delay-ms=3600000",
        "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=inventory-ai-pg-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=inventory-ai-pg-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=inventory-ai-pg-hmac-key-test-only",
        "uten.bootstrap.admin-login=inventory-ai-pg-admin-test",
        "uten.bootstrap.admin-password=InventoryAiPg-1!"
})
class StockAiInventoryScopePostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("uten_ai_inventory_scope").withUsername("uten").withPassword("uten");

    @DynamicPropertySource static void database(DynamicPropertyRegistry properties) {
        POSTGRES.start();
        properties.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        properties.add("spring.datasource.username", POSTGRES::getUsername);
        properties.add("spring.datasource.password", POSTGRES::getPassword);
    }

    @Autowired DataSource dataSource;
    @Autowired StockQueryService stock;
    @Autowired StockReservationRepository reservations;

    @BeforeEach void stockReader() {
        var actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "inventory-ai-read-test",
                Set.of("stock:view"), false, true, false);
        SecurityContextHolder.getContext().setAuthentication(
                UsernamePasswordAuthenticationToken.authenticated(actor, null, actor.getAuthorities()));
    }

    @AfterEach void cleanup() { SecurityContextHolder.clearContext(); }

    record World(UUID parent, UUID first, UUID second, UUID sibling, UUID outside,
                 UUID goods, UUID otherGoods, UUID unit, UUID red) {}

    @Test void singleAuthorizedChildBindsItsOwnBalanceAndInspectionSourcesRatherThanRequestedParent() throws Exception {
        World w = world();
        try (var seed = new StockReadSideSeed(dataSource)) {
            inspection(seed, w.first(), w, 9, 3, 2);
            inspection(seed, w.sibling(), w, 900, 300, 200);
            inspection(seed, w.outside(), w, 9000, 3000, 2000);
        }
        var page = query(w, w.parent(), Set.of(w.first()), w.red(), false);
        assertEquals(1, page.getTotal());
        var row = page.getItems().getFirst();
        assertEquals(w.goods(), row.getGoodsId());
        assertEquals(w.red(), row.getColorId());
        decimal(row.getQty(), "10");
        decimal(row.getPendingQty(), "4");
        decimal(row.getPendingStockInQty(), "3");
        assertTrue(row.isCostMasked());
        assertNull(row.getCostAmount());
    }

    @Test void twoWarehouseBindingIntersectsSubtreeAndEmptyOrDisjointAuthorityNeverMeansAllWarehouses() throws Exception {
        World w = world();
        var both = query(w, w.parent(), Set.of(w.first(), w.second(), w.outside()), w.red(), false);
        assertEquals(1, both.getTotal());
        decimal(both.getItems().getFirst().getQty(), "35");
        decimal(query(w, null, Set.of(w.first(), w.second()), w.red(), false)
                .getItems().getFirst().getQty(), "35");
        var disjoint = query(w, w.outside(), Set.of(w.first(), w.second()), w.red(), false);
        assertEquals(0, disjoint.getTotal());
        assertTrue(disjoint.getItems().isEmpty());
        var empty = query(w, null, Set.of(), w.red(), false);
        assertEquals(0, empty.getTotal());
        assertTrue(empty.getItems().isEmpty());
        assertThrows(ApiException.class, () -> query(w, null, null, w.red(), false));
    }

    @Test void exactNullableColorKeepsDifferentColorsAndOtherWarehouseQuantitiesOut() throws Exception {
        World w = world();
        var own = query(w, w.parent(), Set.of(w.first()), null, true);
        assertEquals(1, own.getTotal());
        assertNull(own.getItems().getFirst().getColorId());
        decimal(own.getItems().getFirst().getQty(), "5");
        var both = query(w, null, Set.of(w.first(), w.second()), null, true);
        assertEquals(1, both.getTotal());
        assertNull(both.getItems().getFirst().getColorId());
        decimal(both.getItems().getFirst().getQty(), "11");
    }

    @Test void effectiveReservationIncludesGlobalAndOwnWarehouseNetClaimsWithExactNullableColor() throws Exception {
        World w = world();
        UUID global;
        UUID first;
        try (var seed = new StockReadSideSeed(dataSource)) {
            global = reserve(seed, null, w.goods(), null, 12, 2, 3, 0, false); // 7 global
            first = reserve(seed, w.first(), w.goods(), null, 9, 1, 2, 0, false); // 6 own
            reserve(seed, w.second(), w.goods(), null, 19, 4, 5, 0, false); // 10 elsewhere
            reserve(seed, w.first(), w.goods(), null, 100, 100, 0, 1, false);
            reserve(seed, w.first(), w.goods(), null, 50, 0, 0, 0, true);
            reserve(seed, w.first(), w.otherGoods(), null, 70, 0, 0, 0, false);
            reserve(seed, null, w.goods(), w.red(), 8, 1, 2, 0, false); // 5 other color global
            reserve(seed, w.first(), w.goods(), w.red(), 6, 1, 1, 0, false); // 4 other color own
        }
        decimal(reservations.warehouseEffectiveReservedBase(w.first(), w.goods(), null), "13");
        decimal(reservations.warehouseEffectiveReservedBase(w.second(), w.goods(), null), "17");
        decimal(reservations.warehouseEffectiveReservedBase(w.outside(), w.goods(), null), "7");
        decimal(reservations.warehouseEffectiveReservedBase(w.first(), w.goods(), w.red()), "9");
        decimal(reservations.warehouseEffectiveReservedBase(w.second(), w.goods(), w.red()), "5");
        decimal(reservations.warehouseEffectiveReservedBase(w.first(), w.goods(), UUID.randomUUID()), "0");
        try (var seed = new StockReadSideSeed(dataSource)) {
            seed.jdbc().update("UPDATE stock_reservations SET released_qty=7 WHERE id=?", global);
            seed.jdbc().update("UPDATE stock_reservations SET consumed_qty=5 WHERE id=?", first);
        }
        decimal(reservations.warehouseEffectiveReservedBase(w.first(), w.goods(), null), "5");
        decimal(reservations.warehouseEffectiveReservedBase(w.second(), w.goods(), null), "13");
    }

    private PageResponse<InstantInventoryRow> query(World w, UUID requestedWarehouse, Set<UUID> allowed,
                                                   UUID color, boolean nullColor) {
        var filter = new StockQueryService.InstantInventoryFilter(null, requestedWarehouse, true, false,
                null, null, null, color, null, null, null, w.goods(), nullColor, true);
        return stock.instantInventoryRowsInWarehouseScope(filter, allowed, 1, 20, "name", "asc");
    }

    private World world() throws Exception {
        try (var seed = new StockReadSideSeed(dataSource)) {
            UUID parent = seed.warehouse("父仓", null);
            UUID first = seed.warehouse("负责仓一", parent), second = seed.warehouse("负责仓二", parent);
            UUID sibling = seed.warehouse("未授权兄弟仓", parent), outside = seed.warehouse("其他仓", null);
            UUID unit = seed.unit("个", null), goods = seed.goods("库存隔离材料", unit, null);
            UUID other = seed.goods("另一材料", unit, null), red = UUID.randomUUID();
            seed.jdbc().update("INSERT INTO colors(id,code,name,status) VALUES(?,?,?,'使用')",
                    red, "AI-INV-C-" + red, "红");
            balance(seed, first, goods, red, "10");
            balance(seed, second, goods, red, "25");
            balance(seed, sibling, goods, red, "91");
            balance(seed, outside, goods, red, "1000");
            balance(seed, first, goods, null, "5");
            balance(seed, second, goods, null, "6");
            balance(seed, sibling, goods, null, "92");
            balance(seed, outside, goods, null, "2000");
            return new World(parent, first, second, sibling, outside, goods, other, unit, red);
        }
    }

    private void balance(StockReadSideSeed seed, UUID warehouse, UUID goods, UUID color, String qty) {
        seed.balance(warehouse, goods, qty, "1", false, "10", LocalDate.of(2026, 10, 3));
        if (color != null) seed.jdbc().update(
                "UPDATE stock_balances SET color_id=? WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",
                color, warehouse, goods);
    }

    private void inspection(StockReadSideSeed seed, UUID warehouse, World w, int received, int passed, int failed) {
        seed.jdbc().update("""
                INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,receipt_item_id,warehouse_id,
                    goods_id,color_id,unit_id,unit_rate,received_base_qty,passed_base_qty,failed_base_qty,status)
                VALUES(?,'PURCHASE',?,?,?,?,?,?,1,?,?,?,'PARTIAL')
                """, UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(), warehouse,
                w.goods(), w.red(), w.unit(), received, passed, failed);
    }

    private UUID reserve(StockReadSideSeed seed, UUID warehouse, UUID goods, UUID color,
                         int qty, int consumed, int released, int status, boolean deleted) {
        UUID id = UUID.randomUUID(), orderItem = UUID.randomUUID();
        seed.jdbc().update("""
                INSERT INTO stock_reservations(id,order_item_id,goods_id,color_id,warehouse_id,qty,
                    consumed_qty,released_qty,status,source,source_doc_type,is_deleted,owner_type,owner_id,purpose)
                VALUES(?,?,?,?,?,?,?,?,?,0,'SALES_ORDER',?,'SALES_ORDER_ITEM',?,'SALES_FULFILLMENT')
                """, id, orderItem, goods, color, warehouse, qty, consumed, released, status, deleted, orderItem);
        return id;
    }

    private static void decimal(BigDecimal actual, String expected) {
        assertNotNull(actual);
        assertEquals(0, actual.compareTo(new BigDecimal(expected)), actual + " != " + expected);
    }
}
