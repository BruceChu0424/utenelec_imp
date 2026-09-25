package com.uten.imp.features.sales.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 2026-09-24 修复锁定（真实 PostgreSQL）：取消物料分析只把分析头置 CANCELLED、
 * 来源行留作历史事实；订单修订守卫必须联头表排除已取消分析——否则用户
 * 「分析后取消、再换产品重提」永远被「订单已有物料分析事实」409 拦死。
 * 同时锁定有效分析（ACTIVE）仍然拦截修订。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.MOCK,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.policy-intelligence.enabled=false",
                "uten.features.goods-owner-scope-enabled=false",
                "uten.jwt.secret=cancelled-analysis-revision-harness-jwt-0123456-tst",
                "uten.crypto.pgp-master-key=cancelled-analysis-revision-pgp-key-tst",
                "uten.crypto.hmac-key=cancelled-analysis-revision-hmac-key-tst",
                "uten.bootstrap.admin-login=cxa-revision-bootstrap-admin-test",
                "uten.bootstrap.admin-password=CxaRevisionAdminPass-1!"
        })
class SalesOrderCancelledAnalysisRevisionPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @DynamicPropertySource
    static void registerDataSource(DynamicPropertyRegistry registry) {
        POSTGRES.start();
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private SalesOrderService service;

    @Autowired
    private PermissionResolver permissionResolver;

    @AfterEach
    void clearAuth() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void cancelledAnalysisNoLongerBlocksRevisionWhileActiveAnalysisStillBlocks() {
        UUID userId = loginAsSuperAdmin("cxa");
        UUID employeeId = jdbc.queryForObject(
                "SELECT employee_id FROM users WHERE id = ?", UUID.class, userId);
        UUID goodsA = goods("A");
        UUID goodsB = goods("B");
        UUID unitId = jdbc.queryForObject(
                "SELECT unit_id FROM goods WHERE id = ?", UUID.class, goodsA);
        UUID currencyId = jdbc.queryForObject("""
                SELECT id FROM currencies WHERE status = '使用' AND NOT is_deleted
                ORDER BY is_base_currency DESC, id LIMIT 1
                """, UUID.class);

        // 下单 → 销售审核（status=APPROVED 后 update 走受控修订路径）。
        var request = orderRequest(currencyId, line(goodsA, unitId, BigDecimal.TEN));
        var created = service.create(request);
        UUID orderId = created.getId();
        UUID itemId = created.getItems().getFirst().getId();
        service.approve(orderId);

        // 有效分析（ACTIVE）：守卫仍然拦截换货修订。
        UUID analysisId = insertAnalysisHeader("ACTIVE", employeeId);
        insertAnalysisSourceItem(analysisId, itemId, goodsA, unitId, BigDecimal.TEN);
        assertThatThrownBy(() -> service.update(orderId,
                orderRequest(currencyId, line(goodsB, unitId, BigDecimal.ONE))))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("物料分析事实");

        // 取消分析（头置 CANCELLED，来源行保留）：同一守卫放行换货修订。
        jdbc.update("""
                UPDATE production_material_analyses
                SET status = 'CANCELLED', cancelled_by = ?, cancelled_at = now(),
                    cancellation_reason = '测试取消分析'
                WHERE id = ?
                """, userId, analysisId);
        var revised = service.update(orderId,
                orderRequest(currencyId, line(goodsB, unitId, BigDecimal.ONE)));
        // 受控修订后自动重新送财务：回到已审核、财务确认标志清零。
        assertThat(revised.getStatus()).isEqualTo((short) 1);
        assertThat(revised.isFinanceConfirmed()).isFalse();
        assertThat(revised.getItems()).singleElement().satisfies(line -> {
            assertThat(line.getGoodsId()).isEqualTo(goodsB);
            assertThat(line.getQty()).isEqualByComparingTo(BigDecimal.ONE);
        });
        // 历史来源行软删留痕，指向它的旧分析 items 不悬空。
        Boolean oldLineDeleted = jdbc.queryForObject(
                "SELECT is_deleted FROM sales_order_items WHERE id = ?",
                Boolean.class, itemId);
        assertThat(oldLineDeleted).isTrue();
    }

    private com.uten.imp.features.sales.order.dto.OrderSaveRequest orderRequest(
            UUID currencyId, com.uten.imp.features.sales.order.dto.OrderItemLine item) {
        var request = new com.uten.imp.features.sales.order.dto.OrderSaveRequest();
        request.setBillDate(LocalDate.of(2026, 9, 24));
        request.setClientId(client());
        request.setCurrencyId(currencyId);
        request.setShipmentPolicy("ALLOW_PARTIAL");
        request.setItems(List.of(item));
        return request;
    }

    private com.uten.imp.features.sales.order.dto.OrderItemLine line(
            UUID goodsId, UUID unitId, BigDecimal qty) {
        var item = new com.uten.imp.features.sales.order.dto.OrderItemLine();
        item.setGoodsId(goodsId);
        item.setUnitId(unitId);
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(qty);
        item.setDiscount(BigDecimal.ONE);
        return item;
    }

    private UUID insertAnalysisHeader(String status, UUID makerEmployeeId) {
        // 分析头触发器要求有效主仓（is_accountable 默认 TRUE）；测试自插避开环境差异。
        UUID warehouseId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO warehouses (id, code, name, status)
                VALUES (?, ?, '取消分析修订测试仓', '使用')
                """, warehouseId, "WH-CXA-" + warehouseId.toString().substring(0, 8));
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO production_material_analyses(
                    id, status, fingerprint, initial_idempotency_key, maker_id,
                    warehouse_id)
                VALUES (?, ?, ?, ?, ?, ?)
                """, id, status, "ab".repeat(32),
                "cxa-idem-" + id, makerEmployeeId, warehouseId);
        return id;
    }

    private void insertAnalysisSourceItem(
            UUID analysisId, UUID orderItemId, UUID goodsId, UUID unitId, BigDecimal qty) {
        jdbc.update("""
                INSERT INTO production_material_analysis_items(
                    id, analysis_id, source_type, sales_order_item_id,
                    goods_id, unit_id, requested_qty)
                VALUES (?, ?, 'SALES_ORDER_ITEM', ?, ?, ?, ?)
                """, UUID.randomUUID(), analysisId, orderItemId, goodsId, unitId, qty);
    }

    /** 超管账号 + 安全上下文（@PreAuthorize 与 owner 写权限全通）。 */
    private UUID loginAsSuperAdmin(String suffix) {
        UUID employeeId = UUID.randomUUID();
        UUID departmentId = jdbc.queryForObject(
                "SELECT id FROM departments WHERE code = 'DEPT_FIN' AND is_deleted = FALSE LIMIT 1",
                UUID.class);
        jdbc.update("""
                INSERT INTO employees(
                    id, code, full_name, id_type, department_id, hire_date,
                    status, employment_type, created_at, updated_at, is_deleted, version)
                VALUES (?, ?, '取消分析修订测试员工', '身份证', ?, DATE '2026-01-01',
                        'active', 'regular', now(), now(), FALSE, 0)
                """, employeeId, "EMP-CXA-" + suffix + "-" + employeeId
                .toString().substring(0, 8), departmentId);
        UUID userId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO users(
                    id, employee_id, login_account, password_hash,
                    must_change_password, status, failed_attempts,
                    created_at, updated_at, is_deleted, is_super_admin, auth_version)
                VALUES (?, ?, ?, 'x',
                        FALSE, 'active', 0,
                        now(), now(), FALSE, TRUE, 0)
                """, userId, employeeId, "cxa-" + suffix + "-" + userId
                .toString().substring(0, 8));
        PermissionResolver.AuthorizationSnapshot snapshot =
                permissionResolver.authorizationSnapshot(userId, employeeId, true);
        AuthUser authUser = new AuthUser(
                userId, employeeId, "cxa-" + suffix, snapshot.permissions(), false, true, true);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(
                        authUser, null, authUser.getAuthorities()));
        return userId;
    }

    private UUID client() {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO clients (id, code, name, status, code_sequence)
                VALUES (?, ?, '取消分析修订测试客户', '使用',
                        (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM clients))
                """, id, "CLI-CXA-" + id.toString().substring(0, 8));
        return id;
    }

    private UUID goods(String tag) {
        UUID unitId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO units (id, code, name, status, created_at, updated_at, is_deleted)
                VALUES (?, ?, '个', '使用', now(), now(), FALSE)
                """, unitId, "U-CXA-" + tag + "-" + unitId.toString().substring(0, 8));
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO goods (id, code, name, unit_id, price, status, code_sequence,
                                   created_at, updated_at, is_deleted)
                VALUES (?, ?, '取消分析修订测试货品', ?, 10, '使用',
                        (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods),
                        now(), now(), FALSE)
                """, id, "G-CXA-" + tag + "-" + id.toString().substring(0, 8), unitId);
        return id;
    }
}
