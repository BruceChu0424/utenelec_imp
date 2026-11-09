package com.uten.imp.features.subcontract.order;

import com.uten.imp.testsupport.FixtureDatabaseProperties;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import com.uten.imp.security.AuthUser;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Real PostgreSQL proof for GET /api/subcontract/orders/goods-stock (委外订货单行级「仓库库存数量」列)。
 *
 * <p>2026-11-08 口径: 委外是我方供料, 成品自身通常从不入库 —— 有可发外直属物料(BOM)的货品显示
 * 直属物料现存量折算的可委外数量(各物料取短板; 直属边/颜色与冻结领料计划、齐套同一判据
 * fn_subcontract_draw_edges, 折套数复用 fn_subcontract_draw_sets 截断到 4 位小数), 与成品颜色无关、
 * 每个货品一桶; 没有可发外直属物料的货品回退自身现存量按颜色分桶, 无余额的桶不返回(前端按 0)。
 * 两条路径现存量同一口径: 仅参与核算仓, 不含不良品仓与线边仓, 货品基本单位。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.MOCK,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.features.goods-owner-scope-enabled=false",
                "uten.jwt.secret=goods-stock-harness-jwt-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=goods-stock-harness-pgp-key-test-only-012345",
                "uten.crypto.hmac-key=goods-stock-harness-hmac-key-test-only",
                "uten.bootstrap.admin-login=goods-stock-bootstrap-admin-test",
                "uten.bootstrap.admin-password=GoodsStockAdminPass-1!"
        })
class SubcontractOrderGoodsStockPostgresTest {

    private static final PostgreSQLContainer POSTGRES =
            new PostgreSQLContainer("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("fixture_admin")
                    .withPassword("uten");

    @DynamicPropertySource
    static void registerDataSource(DynamicPropertyRegistry registry) {
        POSTGRES.start();
        FixtureDatabaseProperties.bindSameRole(registry, POSTGRES::getJdbcUrl,
                POSTGRES::getUsername, POSTGRES::getPassword);
    }

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private SubcontractOrderService service;

    @Autowired
    private SubcontractOrderController controller;

    @Autowired
    private org.springframework.transaction.PlatformTransactionManager txm;

    @BeforeEach void authenticate() {
        UUID employee = jdbc.queryForObject(
                "SELECT employee_id FROM users WHERE login_account='goods-stock-bootstrap-admin-test'", UUID.class);
        UUID account = jdbc.queryForObject(
                "SELECT id FROM users WHERE employee_id=? AND status='active' LIMIT 1", UUID.class, employee);
        AuthUser user = new AuthUser(account, employee, "goods-stock-reader",
                Set.of("subcontract_order:view"), false, true, false);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
    }

    @AfterEach void clearAuthentication() { SecurityContextHolder.clearContext(); }

    @Test
    void bomGoodsShowComponentStockConvertedToSubcontractableQtyInsteadOfOwnStock() {
        // 用户实测场景: 子件刚完工 11000 入仓, 单耗 1; 成品自身的存量与该列无关。
        UUID pieces = unit("件");
        UUID each = unit("个");
        UUID parent = goods("GSTK-P-" + UUID.randomUUID(), pieces);
        UUID child = goods("GSTK-C-" + UUID.randomUUID(), each);
        bom(parent, child, "1", null);
        UUID normalWarehouse = warehouse("GSTK-N-" + UUID.randomUUID(), false, false);
        UUID defectiveWarehouse = warehouse("GSTK-D-" + UUID.randomUUID(), true, false);
        UUID lineSideWarehouse = warehouse("GSTK-L-" + UUID.randomUUID(), false, true);
        balance(normalWarehouse, child, null, "11000");
        // 子件在不良品仓/线边仓的量与成品自身存量都不计入。
        balance(defectiveWarehouse, child, null, "900");
        balance(lineSideWarehouse, child, null, "800");
        balance(normalWarehouse, parent, null, "7");

        var buckets = service.goodsStockBuckets(Set.of(parent));

        assertThat(buckets).singleElement().satisfies(bucket -> {
            assertThat(bucket.goodsId()).isEqualTo(parent);
            assertThat(bucket.colorId()).isNull();
            assertThat(bucket.qty()).isEqualByComparingTo("11000");
            assertThat(bucket.qtyExact()).isEqualTo("11000");
            // 单位 = 成品(委外件)基本单位, 不是物料单位。
            assertThat(bucket.unitName()).isEqualTo("件");
            assertThat(bucket.basis()).isEqualTo(SubcontractOrderService.GoodsStockBucket.BASIS_BOM_KIT);
        });
        assertThat(controller.goodsStock(parent.toString())).singleElement()
                .satisfies(bucket -> assertThat(bucket.qtyExact()).isEqualTo("11000"));
    }

    @Test
    void kitDividesComponentStockByPerSetUsageAndTruncatesToFourDecimals() {
        UUID unit = unit("件");
        UUID doubleUsage = goods("GSTK-P2-" + UUID.randomUUID(), unit);
        UUID thirdUsage = goods("GSTK-P3-" + UUID.randomUUID(), unit);
        UUID child = goods("GSTK-C-" + UUID.randomUUID(), unit);
        UUID screw = goods("GSTK-S-" + UUID.randomUUID(), unit);
        bom(doubleUsage, child, "2", null);
        bom(thirdUsage, screw, "3", null);
        UUID warehouse = warehouse("GSTK-N-" + UUID.randomUUID(), false, false);
        balance(warehouse, child, null, "11000");
        balance(warehouse, screw, null, "10");

        Map<UUID, SubcontractOrderService.GoodsStockBucket> byGoods = byGoods(
                service.goodsStockBuckets(Set.of(doubleUsage, thirdUsage)));

        assertThat(byGoods).hasSize(2);
        assertThat(byGoods.get(doubleUsage).qty()).isEqualByComparingTo("5500");
        // 与齐套「可下单」同一取整: 物料量 ÷ 每套用量精确截断到 4 位小数(10 ÷ 3 = 3.3333, 不进位)。
        assertThat(byGoods.get(thirdUsage).qtyExact()).isEqualTo("3.3333");
    }

    @Test
    void kitTakesTheShortestDirectComponent() {
        UUID unit = unit("件");
        UUID parent = goods("GSTK-P-" + UUID.randomUUID(), unit);
        UUID shell = goods("GSTK-C1-" + UUID.randomUUID(), unit);
        UUID insert = goods("GSTK-C2-" + UUID.randomUUID(), unit);
        bom(parent, shell, "1", null);
        bom(parent, insert, "2", null);
        UUID first = warehouse("GSTK-N1-" + UUID.randomUUID(), false, false);
        UUID second = warehouse("GSTK-N2-" + UUID.randomUUID(), false, false);
        balance(first, shell, null, "11000");
        // 同一物料多个参与核算仓先合计再折算: 2000 + 1000 = 3000 → 1500 套。
        balance(first, insert, null, "2000");
        balance(second, insert, null, "1000");

        assertThat(service.goodsStockBuckets(Set.of(parent))).singleElement()
                .satisfies(bucket -> assertThat(bucket.qty()).isEqualByComparingTo("1500"));
    }

    @Test
    void componentStockMatchesTheFrozenPlanColorBucketExactly() {
        UUID unit = unit("件");
        UUID red = color("红");
        UUID blue = color("蓝");
        UUID plainChild = goods("GSTK-C-" + UUID.randomUUID(), unit);
        UUID blueDefaultChild = goodsWithDefaultColor("GSTK-CB-" + UUID.randomUUID(), unit, blue);
        UUID redRow = goods("GSTK-PR-" + UUID.randomUUID(), unit);
        UUID colorlessRow = goods("GSTK-PN-" + UUID.randomUUID(), unit);
        UUID defaultColorRow = goods("GSTK-PD-" + UUID.randomUUID(), unit);
        bom(redRow, plainChild, "1", red);
        bom(colorlessRow, plainChild, "1", null);
        bom(defaultColorRow, blueDefaultChild, "1", null);
        UUID warehouse = warehouse("GSTK-N-" + UUID.randomUUID(), false, false);
        balance(warehouse, plainChild, red, "11000");
        balance(warehouse, plainChild, blue, "4000");
        balance(warehouse, plainChild, null, "100");
        balance(warehouse, blueDefaultChild, red, "500");
        balance(warehouse, blueDefaultChild, blue, "4000");

        Map<UUID, SubcontractOrderService.GoodsStockBucket> byGoods = byGoods(
                service.goodsStockBuckets(Set.of(redRow, colorlessRow, defaultColorRow)));

        // BOM 行带颜色 → 该颜色桶。
        assertThat(byGoods.get(redRow).qty()).isEqualByComparingTo("11000");
        // BOM 行无颜色、物料也无默认颜色 → 无色桶, 不把各颜色合计(领料计划冻结同一颜色, 只能领这一桶)。
        assertThat(byGoods.get(colorlessRow).qty()).isEqualByComparingTo("100");
        // BOM 行无颜色 → 物料默认颜色桶(与 fn_subcontract_draw_edges 的 COALESCE 冻结一致)。
        assertThat(byGoods.get(defaultColorRow).qty()).isEqualByComparingTo("4000");
        assertThat(byGoods.values()).allSatisfy(bucket -> {
            assertThat(bucket.colorId()).isNull();
            assertThat(bucket.basis()).isEqualTo(SubcontractOrderService.GoodsStockBucket.BASIS_BOM_KIT);
        });
    }

    @Test
    void goodsWithoutBomFallBackToOwnStockByColorExcludingDefectiveAndLineSideWarehouses() {
        UUID unit = unit("件");
        UUID goods = goods("GSTK-" + UUID.randomUUID(), unit);
        UUID red = color("红");
        UUID normalWarehouse = warehouse("GSTK-N-" + UUID.randomUUID(), false, false);
        UUID defectiveWarehouse = warehouse("GSTK-D-" + UUID.randomUUID(), true, false);
        UUID lineSideWarehouse = warehouse("GSTK-L-" + UUID.randomUUID(), false, true);
        balance(normalWarehouse, goods, red, "7");
        balance(normalWarehouse, goods, null, "3");
        // 不良品仓/线边仓的量不得计入「仓库库存数量」。
        balance(defectiveWarehouse, goods, red, "100");
        balance(lineSideWarehouse, goods, null, "50");

        var buckets = service.goodsStockBuckets(Set.of(goods));

        assertThat(buckets).hasSize(2);
        var byColor = buckets.stream().collect(
                Collectors.toMap(b -> b.colorId(), b -> b));
        assertThat(byColor.get(red).qty()).isEqualByComparingTo("7");
        assertThat(byColor.get(null).qty()).isEqualByComparingTo("3");
        assertThat(byColor.get(red).unitName()).isEqualTo("件");
        assertThat(buckets).allSatisfy(bucket -> assertThat(bucket.basis())
                .isEqualTo(SubcontractOrderService.GoodsStockBucket.BASIS_OWN_STOCK));

        // 控制器契约：逗号分隔 goodsIds → 颜色分桶列表（qtyExact 由 DecimalText 生成）。
        assertThat(controller.goodsStock(goods.toString())).hasSize(2);
    }

    @Test
    void bomWithoutDrawableDirectEdgeFallsBackToOwnStock() {
        UUID unit = unit("件");
        UUID goods = goods("GSTK-R-" + UUID.randomUUID(), unit);
        UUID referenceOnly = goods("GSTK-RC-" + UUID.randomUUID(), unit);
        // 只作参考(REFERENCE)的 BOM 行不是可发外直属物料, 与缺 BOM 判据一致 → 仍显示自身现存量。
        bom(goods, referenceOnly, "1", null, "REFERENCE", false);
        UUID warehouse = warehouse("GSTK-N-" + UUID.randomUUID(), false, false);
        balance(warehouse, referenceOnly, null, "999");
        balance(warehouse, goods, null, "12");

        assertThat(service.goodsStockBuckets(Set.of(goods))).singleElement().satisfies(bucket -> {
            assertThat(bucket.qty()).isEqualByComparingTo("12");
            assertThat(bucket.basis()).isEqualTo(SubcontractOrderService.GoodsStockBucket.BASIS_OWN_STOCK);
        });
    }

    @Test
    void goodsWithoutBomOrBalancesReturnNoBucketWhileBomGoodsReturnZeroKit() {
        UUID unit = unit("件");
        UUID goods = goods("GSTK-E-" + UUID.randomUUID(), unit);
        UUID parent = goods("GSTK-EP-" + UUID.randomUUID(), unit);
        UUID child = goods("GSTK-EC-" + UUID.randomUUID(), unit);
        bom(parent, child, "1", null);

        assertThat(service.goodsStockBuckets(Set.of(goods))).isEmpty();
        assertThat(controller.goodsStock(goods.toString())).isEmpty();
        // 有 BOM 但物料没有现存量: 明确返回 0 套(短板为 0), 不回退成品自身存量。
        assertThat(service.goodsStockBuckets(Set.of(parent))).singleElement().satisfies(bucket -> {
            assertThat(bucket.qty()).isEqualByComparingTo("0");
            assertThat(bucket.basis()).isEqualTo(SubcontractOrderService.GoodsStockBucket.BASIS_BOM_KIT);
        });
    }

    private static Map<UUID, SubcontractOrderService.GoodsStockBucket> byGoods(
            java.util.List<SubcontractOrderService.GoodsStockBucket> buckets) {
        return buckets.stream().collect(Collectors.toMap(
                SubcontractOrderService.GoodsStockBucket::goodsId, bucket -> bucket));
    }

    private UUID unit(String name) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO units(id, code, name) VALUES (?, ?, ?)",
                id, "GSTK-U-" + id, name);
        return id;
    }

    private UUID goods(String code, UUID unit) {
        return goodsWithDefaultColor(code, unit, null);
    }

    private UUID goodsWithDefaultColor(String code, UUID unit, UUID defaultColor) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO goods(id, code, name, unit_id, color_id, code_sequence)
                VALUES (?, ?, ?, ?, ?, (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))
                """, id, code, "库存列测试货品", unit, defaultColor);
        return id;
    }

    private void bom(UUID parent, UUID component, String qty, UUID color) {
        bom(parent, component, qty, color, "START", true);
    }

    private void bom(UUID parent, UUID component, String qty, UUID color, String stage, boolean hardGate) {
        jdbc.update("""
                INSERT INTO goods_bom_items(id, goods_id, component_goods_id, color_id, qty, sort_order,
                                            control_stage, consumption_basis, basis_output_qty, hard_gate)
                VALUES (?, ?, ?, ?, ?, 1, ?, 'PER_UNIT', 1, ?)
                """, UUID.randomUUID(), parent, component, color, new BigDecimal(qty), stage, hardGate);
    }

    private UUID color(String name) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO colors(id, code, name, status) VALUES (?, ?, ?, '使用')",
                id, "GSTK-C-" + id, name);
        return id;
    }

    private UUID warehouse(String code, boolean defective, boolean lineSide) {
        UUID id = UUID.randomUUID();
        // 线边仓库守卫要求：核算、非不良品、叶仓且挂车间归属(fn_guard_warehouse_line_side)；
        // 车间又必须是 DEPT_PROD 的直接下级(fn_guard_warehouse_workshop_department)；且
        // 仓库行与 workshop_bins 开通行同事务提交(fn_assert_warehouse_line_side_opened)。
        UUID workshop = null;
        if (lineSide) {
            workshop = jdbc.query("""
                    SELECT child.id FROM departments child
                    JOIN departments parent ON parent.id = child.parent_id
                    WHERE parent.code = 'DEPT_PROD' AND NOT child.is_deleted
                    LIMIT 1
                    """, (rs, i) -> UUID.fromString(rs.getString(1))).stream().findFirst().orElse(null);
            if (workshop == null) {
                workshop = UUID.randomUUID();
                jdbc.update("""
                        INSERT INTO departments(id, code, name, parent_id, level)
                        SELECT ?, ?, ?, id, '二级班组' FROM departments WHERE code = 'DEPT_PROD'
                        """, workshop, "GSTK-W-" + workshop, "库存列测试车间");
            }
            // 一个车间只有一个未删内料仓(ux_warehouses_line_side_workshop, ADR-145): 本类多个用例
            // 共用同一个库, 已开通就复用(各用例的货品互不相同, 余额不串)。
            UUID opened = jdbc.query("""
                    SELECT w.id FROM warehouses w
                    WHERE w.is_line_side AND NOT w.is_deleted AND w.workshop_department_id = ?
                    """, (rs, i) -> UUID.fromString(rs.getString(1)), workshop).stream().findFirst().orElse(null);
            if (opened != null) {
                return opened;
            }
        }
        final UUID binWorkshop = workshop;
        final UUID binId = id;
        new org.springframework.transaction.support.TransactionTemplate(txm).executeWithoutResult(tx -> {
            jdbc.update("""
                    INSERT INTO warehouses(id, code, name, status, is_accountable, is_defective, is_line_side,
                                           workshop_department_id)
                    VALUES (?, ?, ?, '使用', TRUE, ?, ?, ?)
                    """, binId, code, "库存列测试仓", defective, lineSide, binWorkshop);
            if (lineSide) {
                jdbc.update("""
                        INSERT INTO workshop_bins(workshop_department_id, bin_warehouse_id)
                        VALUES (?, ?)
                        """, binWorkshop, binId);
            }
        });
        return id;
    }

    private void balance(UUID warehouse, UUID goods, UUID color, String qty) {
        jdbc.update("""
                INSERT INTO stock_balances(warehouse_id, goods_id, color_id, qty)
                VALUES (?, ?, ?, ?)
                """, warehouse, goods, color, new BigDecimal(qty));
    }
}
