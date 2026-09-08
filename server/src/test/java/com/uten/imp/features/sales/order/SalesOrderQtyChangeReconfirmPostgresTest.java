package com.uten.imp.features.sales.order;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.sales.order.dto.OrderChangeQtyRequest;
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
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V482 行为链（真实 PostgreSQL）：财务确认后的销售订单允许改量——改后
 * finance_confirmed 置回 FALSE 重新入队、改量事实落 sales_order_qty_change_logs、
 * 财务队列标注 changeCount、审核详情展示「以前→现在」修改清单；重新确认后
 * （finance_confirmed_at 前进）清单归档隐藏。
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
                "uten.jwt.secret=qty-reconfirm-harness-jwt-secret-0123456789-tst",
                "uten.crypto.pgp-master-key=qty-reconfirm-harness-pgp-key-test-only-0123",
                "uten.crypto.hmac-key=qty-reconfirm-harness-hmac-key-test-only",
                "uten.bootstrap.admin-login=qty-reconfirm-bootstrap-admin-test",
                "uten.bootstrap.admin-password=QtyReconfirmAdminPass-1!"
        })
class SalesOrderQtyChangeReconfirmPostgresTest {

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

    /** 类级共享：号段触发器要求 XD+日期+6 位序号注册格式，序号不重复。 */
    private static final AtomicInteger BILL_SEQUENCE = new AtomicInteger();

    private static String billNo() {
        return "XD20260905%06d".formatted(BILL_SEQUENCE.incrementAndGet());
    }

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private SalesOrderService service;

    @Autowired
    private SalesOrderFinanceConfirmService financeService;

    @Autowired
    private PermissionResolver permissionResolver;

    @Autowired
    private com.uten.imp.features.common.taskclaim.TaskClaimService claims;

    @AfterEach
    void clearAuth() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void fullCommercialRevisionPreservesLineIdentityAndRequeuesOnlyCurrentReviewVersion() {
        loginAsSuperAdmin("commercial");
        UUID goodsId = goods();
        jdbc.update("UPDATE goods SET price = 10 WHERE id = ?", goodsId);
        UUID unitId = jdbc.queryForObject("SELECT unit_id FROM goods WHERE id = ?", UUID.class, goodsId);
        UUID currencyId = jdbc.queryForObject("""
                SELECT id FROM currencies WHERE status = '使用' AND NOT is_deleted
                ORDER BY is_base_currency DESC, id LIMIT 1
                """, UUID.class);
        var request = new com.uten.imp.features.sales.order.dto.OrderSaveRequest();
        request.setBillDate(LocalDate.of(2026, 9, 5));
        request.setClientId(client());
        request.setCurrencyId(currencyId);
        request.setShipmentPolicy("ALLOW_PARTIAL");
        request.setRemark("原备注");
        var item = new com.uten.imp.features.sales.order.dto.OrderItemLine();
        item.setGoodsId(goodsId);
        item.setUnitId(unitId);
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(BigDecimal.TEN);
        item.setDiscount(BigDecimal.ONE);
        request.setItems(List.of(item));
        var created = service.create(request);
        UUID orderId = created.getId();
        UUID itemId = created.getItems().getFirst().getId();
        service.approve(orderId);
        var initialClaim=claims.claim("SALES_ORDER_FINANCE_CONFIRM",orderId.toString());
        financeService.confirm(orderId,new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,0L,initialClaim.claimId()));
        item.setId(itemId);
        request.setRemark("修改后的备注");
        item.setDiscount(new BigDecimal("0.9"));
        var revised = service.update(orderId, request);
        assertThat(revised.getStatus()).isEqualTo((short) 1);
        assertThat(revised.isFinanceConfirmed()).isFalse();
        assertThat(revised.getItems().getFirst().getId()).isEqualTo(itemId);
        assertThat(revised.getTotalOriginal()).isEqualByComparingTo("90");
        var review = financeService.review(orderId);
        assertThat(review.financeReviewRevision()).isEqualTo(1);
        assertThat(review.commercialChanges()).anyMatch(change -> change.field().contains("备注")
                && change.beforeValue().equals("原备注") && change.afterValue().equals("修改后的备注"));
        assertThat(review.commercialChanges()).anyMatch(change -> change.field().endsWith("折扣"));
        assertThat(financeService.pending(1, 50, false, null, false).getItems())
                .noneMatch(row -> row.orderId().equals(orderId));
        assertThat(financeService.pending(1, 50, false, null, true).getItems())
                .anyMatch(row -> row.orderId().equals(orderId));

        claims.claim("SALES_ORDER_FINANCE_CONFIRM", orderId.toString());
        request.setRemark("审核时不允许修改");
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> service.update(orderId, request))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> service.cancel(orderId))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
        claims.release("SALES_ORDER_FINANCE_CONFIRM", orderId.toString());
        service.update(orderId, request);
        var revisedClaim=claims.claim("SALES_ORDER_FINANCE_CONFIRM",orderId.toString());
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> financeService.confirm(orderId,
                new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,1L,revisedClaim.claimId())))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
        UUID otherOrderId = service.create(request).getId();
        service.approve(otherOrderId);
        var otherClaim=claims.claim("SALES_ORDER_FINANCE_CONFIRM",otherOrderId.toString());
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> financeService.confirmBatch(
                new SalesOrderFinanceConfirmService.FinanceBatchConfirmRequest(
                        List.of(orderId,otherOrderId),null,Map.of(orderId,1L,otherOrderId,0L),
                        Map.of(orderId,revisedClaim.claimId(),otherOrderId,otherClaim.claimId()))))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_orders WHERE id IN (?, ?) AND finance_confirmed",
                Long.class, orderId, otherOrderId)).isZero();
        var batch = financeService.confirmBatch(new SalesOrderFinanceConfirmService.FinanceBatchConfirmRequest(
                List.of(orderId,otherOrderId),null,Map.of(orderId,2L,otherOrderId,0L),
                Map.of(orderId,revisedClaim.claimId(),otherOrderId,otherClaim.claimId())));
        assertThat(batch.newlyConfirmedCount()).isEqualTo(2);
        assertThat(financeService.review(orderId).commercialChanges()).isEmpty();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_order_revision_logs WHERE order_id = ?",
                Long.class, orderId)).isEqualTo(2);
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> jdbc.update(
                "UPDATE sales_order_revision_logs SET after_snapshot = '{}'::jsonb WHERE order_id = ?", orderId))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
    }

    @Test
    void confirmedOrderQtyChangeRequeuesFinanceAndKeepsAnOldToNewLedger() {
        UUID actor = loginAsSuperAdmin("qtyreconfirm");
        UUID clientId = client();
        UUID goodsId = goods();
        UUID orderId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        OffsetDateTimeLike confirmedAt = OffsetDateTimeLike.hoursAgo(1);

        jdbc.update("""
                INSERT INTO sales_orders(
                    id, bill_no, bill_date, client_id, status,
                    owner_employee_id, maker_id,
                    finance_confirmed, finance_confirmed_at, finance_confirmed_by,
                    created_at, updated_at)
                VALUES (?, ?, DATE '2026-09-05', ?, 1,
                        (SELECT employee_id FROM users WHERE id = ?),
                        (SELECT employee_id FROM users WHERE id = ?),
                        TRUE, ?, ?,
                        now(), now())
                """, orderId, billNo(), clientId, actor, actor,
                confirmedAt.value, actorEmployeeOf(actor));
        jdbc.update("""
                INSERT INTO sales_order_items(
                    id, bill_no, bill_date, order_id, goods_id,
                    goods_code_snapshot, goods_name_snapshot,
                    goods_snapshot_source, goods_snapshot_locked_at,
                    qty, chain_status)
                VALUES (?, ?, DATE '2026-09-05', ?, ?,
                        'QTY-RC-001', '改量复核测试货品',
                        'MASTER_AT_APPROVAL', now(),
                        10, 0)
                """, itemId, billNo(), orderId, goodsId);

        // 改量：10 → 6。
        OrderChangeQtyRequest request = new OrderChangeQtyRequest();
        OrderChangeQtyRequest.Line line = new OrderChangeQtyRequest.Line();
        line.setOrderItemId(itemId);
        line.setNewQty(new BigDecimal("6"));
        request.setItems(List.of(line));
        service.changeQty(orderId, request);

        // 1) 置回待确认（重新进入财务队列）。
        Boolean requeued = jdbc.queryForObject(
                "SELECT finance_confirmed FROM sales_orders WHERE id = ?",
                Boolean.class, orderId);
        assertThat(requeued).isFalse();
        // 上次确认时间保留为对照基线。
        var baselineAt = jdbc.queryForObject(
                "SELECT finance_confirmed_at FROM sales_orders WHERE id = ?",
                java.sql.Timestamp.class, orderId);
        assertThat(baselineAt).isNotNull();

        // 2) 事实账：old 10 → new 6。
        List<Map<String, Object>> logs = jdbc.queryForList(
                "SELECT old_qty, new_qty FROM sales_order_qty_change_logs"
                        + " WHERE order_id = ? AND order_item_id = ?",
                orderId, itemId);
        assertThat(logs).hasSize(1);
        assertThat(((BigDecimal) logs.get(0).get("old_qty")).stripTrailingZeros())
                .isEqualByComparingTo("10");
        assertThat(((BigDecimal) logs.get(0).get("new_qty")).stripTrailingZeros())
                .isEqualByComparingTo("6");

        // 3) 财务队列标注「改后待确认 · 1 处」。
        var page = financeService.pending(1, 50, false, null);
        var row = page.getItems().stream()
                .filter(item -> item.orderId().equals(orderId))
                .findFirst().orElseThrow();
        assertThat(row.changeCount()).isEqualTo(1);

        // 4) 审核详情展示修改清单（以前→现在）。
        var review = financeService.review(orderId);
        assertThat(review.qtyChanges()).hasSize(1);
        assertThat(review.qtyChanges().get(0).oldQty().stripTrailingZeros())
                .isEqualByComparingTo("10");
        assertThat(review.qtyChanges().get(0).newQty().stripTrailingZeros())
                .isEqualByComparingTo("6");

        // 5) 重新确认后（finance_confirmed_at 前进到改量之后）清单归档隐藏。
        var firstReconfirmationClaim=claims.claim("SALES_ORDER_FINANCE_CONFIRM",orderId.toString());
        financeService.confirm(orderId,new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,1L,firstReconfirmationClaim.claimId()));
        var afterReconfirm = financeService.review(orderId);
        assertThat(afterReconfirm.qtyChanges()).isEmpty();

        // Reducing the remaining commitment to the shipped quantity closes the order,
        // but the changed commercial amount still requires finance review.
        // Imported historical shipped quantity is this projection fixture's input; it is not shipment-chain acceptance.
        jdbc.update("UPDATE sales_order_items SET shipped_qty = 5 WHERE id = ?", itemId);
        line.setNewQty(new BigDecimal("5"));
        service.changeQty(orderId, request);
        assertThat(jdbc.queryForObject("SELECT is_closed FROM sales_orders WHERE id = ?", Boolean.class, orderId)).isTrue();
        assertThat(financeService.pending(1, 50, false, null, true).getItems())
                .anyMatch(itemRow -> itemRow.orderId().equals(orderId));
        var finalClaim=claims.claim("SALES_ORDER_FINANCE_CONFIRM",orderId.toString());
        financeService.confirm(orderId,new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,2L,finalClaim.claimId()));
        assertThat(financeService.review(orderId).financeConfirmed()).isTrue();
    }

    // ---- 夹具 -------------------------------------------------------------

    private UUID actorEmployeeOf(UUID userId) {
        return jdbc.queryForObject(
                "SELECT employee_id FROM users WHERE id = ?", UUID.class, userId);
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
                VALUES (?, ?, '改量复核测试员工', '身份证', ?, DATE '2026-01-01',
                        'active', 'regular', now(), now(), FALSE, 0)
                """, employeeId, "EMP-QRC-" + suffix + "-" + employeeId
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
                """, userId, employeeId, "qrc-" + suffix + "-" + userId
                .toString().substring(0, 8));
        PermissionResolver.AuthorizationSnapshot snapshot =
                permissionResolver.authorizationSnapshot(userId, employeeId, true);
        AuthUser authUser = new AuthUser(
                userId, employeeId, "qrc-" + suffix,
                snapshot.roles(), snapshot.permissions(), false, true, true);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(
                        authUser, null, authUser.getAuthorities()));
        return userId;
    }

    private UUID client() {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO clients (id, code, name, status, code_sequence, sales_payment_type)
                VALUES (?, ?, '改量复核测试客户', '使用',
                        (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM clients), 'MONTHLY')
                """, id, "CLI-QRC-" + id.toString().substring(0, 8));
        return id;
    }

    private UUID goods() {
        UUID unitId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO units (id, code, name, status, created_at, updated_at, is_deleted)
                VALUES (?, ?, '个', '使用', now(), now(), FALSE)
                """, unitId, "U-QRC-" + unitId.toString().substring(0, 8));
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO goods (id, code, name, unit_id, status, code_sequence,
                                   created_at, updated_at, is_deleted)
                VALUES (?, ?, '改量复核测试货品', ?, '使用',
                        (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods),
                        now(), now(), FALSE)
                """, id, "G-QRC-" + id.toString().substring(0, 8), unitId);
        return id;
    }

    /** confirmed_at 值载体（避免测试类直接依赖时区细节）。 */
    private record OffsetDateTimeLike(java.sql.Timestamp value) {
        static OffsetDateTimeLike hoursAgo(long hours) {
            return new OffsetDateTimeLike(
                    java.sql.Timestamp.from(java.time.Instant.now()
                            .minus(java.time.Duration.ofHours(hours))));
        }
    }
}
