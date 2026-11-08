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
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import com.uten.imp.security.AuthUser;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Real PostgreSQL proof for GET /api/subcontract/orders/goods-stock
 * (2026-11-07 委外订货单行级「仓库库存数量」列): 按货品×颜色聚合的即时库存,
 * 口径与货品资料「库存量」列一致 —— 仅参与核算仓库, 不含不良品仓与线边仓,
 * 基本单位; 无余额的货品×颜色不返回(前端按 0 显示)。
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
    void bucketsAggregateByColorAndExcludeDefectiveAndLineSideWarehouses() {
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

        // 控制器契约：逗号分隔 goodsIds → 颜色分桶列表（qtyExact 由 DecimalText 生成）。
        assertThat(controller.goodsStock(goods.toString())).hasSize(2);
    }

    @Test
    void goodsWithoutBalancesReturnsNoBucket() {
        UUID unit = unit("件");
        UUID goods = goods("GSTK-E-" + UUID.randomUUID(), unit);

        assertThat(service.goodsStockBuckets(Set.of(goods))).isEmpty();
        assertThat(controller.goodsStock(goods.toString())).isEmpty();
    }

    private UUID unit(String name) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO units(id, code, name) VALUES (?, ?, ?)",
                id, "GSTK-U-" + id, name);
        return id;
    }

    private UUID goods(String code, UUID unit) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO goods(id, code, name, unit_id, code_sequence)
                VALUES (?, ?, ?, ?, (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))
                """, id, code, "库存列测试货品", unit);
        return id;
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
