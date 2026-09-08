package com.uten.imp.features.sales.ret;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.sales.ret.dto.ReturnItemLine;
import com.uten.imp.features.sales.ret.dto.ReturnSaveRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TxSessionVars;
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
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false",
        "uten.jwt.secret=return-authority-harness-jwt-secret-0123456789-tst",
        "uten.crypto.pgp-master-key=return-authority-harness-pgp-key-test-only-0123",
        "uten.crypto.hmac-key=return-authority-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=return-authority-bootstrap-test",
        "uten.bootstrap.admin-password=ReturnAuthorityAdmin-1!"
})
// Historical frozen shipment amounts, including old rounded commercial totals.
// Current V2 sales/finance/warehouse instructions are covered by FullChainEndToEndTest.
class SalesReturnAmountAuthorityPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final AtomicInteger SEQUENCE = new AtomicInteger();
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry properties) {
        POSTGRES.start();
        properties.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        properties.add("spring.datasource.username", POSTGRES::getUsername);
        properties.add("spring.datasource.password", POSTGRES::getPassword);
    }
    @Autowired JdbcTemplate jdbc;
    @Autowired SalesReturnService service;
    @Autowired PermissionResolver permissions;
    @Autowired TransactionTemplate transactions;
    @Autowired TxSessionVars tx;
    @AfterEach void clearAuthentication() { SecurityContextHolder.clearContext(); }

    @Test
    void tamperedDraftAmountsCannotOvercreditAndSplitReturnsExactlyExhaustOriginalDebt() {
        Fixture fixture = seed();
        Long historicalMovementCount = jdbc.queryForObject(
                "SELECT count(*) FROM stock_movements WHERE goods_id = ?", Long.class, fixture.goodsId());
        for (int i = 0; i < 3; i++) {
            ReturnSaveRequest request = request(fixture);
            var created = service.create(request);
            var approved = service.approve(created.getId());
            assertThat(approved.getTotalOriginal()).isLessThan(BigDecimal.ONE);
            assertThat(approved.getItems().getFirst().getPrice()).isEqualByComparingTo("0.5");
            assertThatThrownBy(() -> service.approve(created.getId()))
                    .isInstanceOf(com.uten.imp.common.web.ApiException.class);
        }
        assertThat(jdbc.queryForObject("""
                SELECT SUM(ledger.amount_original) FROM ar_ap_ledger ledger
                JOIN sales_returns returned ON returned.id = ledger.source_doc_id
                WHERE ledger.source_doc_type = 'SALES_RETURN' AND ledger.status = 1
                  AND returned.source_shipment_id = ?
                """, BigDecimal.class, fixture.shipmentId())).isEqualByComparingTo("-1");
        assertThat(jdbc.queryForObject("SELECT returned_amount FROM sales_shipment_items WHERE id = ?",
                BigDecimal.class, fixture.shipmentItemId())).isEqualByComparingTo("7");
        assertThat(jdbc.queryForObject("SELECT SUM(received_base_qty) FROM sales_return_quality_items WHERE goods_id = ?",
                BigDecimal.class, fixture.goodsId())).isEqualByComparingTo("3");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM stock_movements WHERE goods_id = ?",
                Long.class, fixture.goodsId())).isEqualTo(historicalMovementCount);
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM stock_movements WHERE goods_id=? AND source_doc_type='SALES_RETURN'
                """, Long.class, fixture.goodsId())).isZero();
        var pendingCost = jdbc.queryForMap("""
                SELECT authority_type,initial_known_value,initial_complete
                FROM stock_value_acquisition_sources WHERE evidence_id=?
                """, fixture.originalMovementId());
        assertThat(pendingCost.get("authority_type")).isEqualTo("LEGACY_SALES_MOVEMENT");
        assertThat(pendingCost.get("initial_known_value")).isNull();
        assertThat(pendingCost.get("initial_complete")).isEqualTo(false);
        var overReturn = service.create(request(fixture));
        assertThatThrownBy(() -> service.approve(overReturn.getId()))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
    }

    @Test
    void currencyAndRateTamperingFailBeforeQuarantineAndLedgerEffects() {
        Fixture fixture = seed();
        var request = request(fixture);
        request.setExchangeRate(new BigDecimal("99"));
        var created = service.create(request);
        assertThatThrownBy(() -> service.approve(created.getId()))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_return_quality_items WHERE return_id = ?",
                Long.class, created.getId())).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_id = ?",
                Long.class, created.getId())).isZero();
        assertThat(jdbc.queryForObject("SELECT returned_qty FROM sales_shipment_items WHERE id = ?",
                BigDecimal.class, fixture.shipmentItemId())).isZero();
    }

    private ReturnSaveRequest request(Fixture fixture) {
        var request = new ReturnSaveRequest();
        request.setBillDate(LocalDate.of(2026, 9, 7));
        request.setClientId(fixture.clientId());
        request.setWarehouseId(fixture.warehouseId());
        request.setCurrencyId(fixture.currencyId());
        request.setExchangeRate(new BigDecimal("7"));
        request.setTaxRate(new BigDecimal("13"));
        var line = new ReturnItemLine();
        line.setOutItemId(fixture.shipmentItemId());
        line.setGoodsId(fixture.goodsId());
        line.setUnitId(fixture.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.ONE);
        line.setPrice(new BigDecimal("999"));
        line.setAmountOriginal(new BigDecimal("999999"));
        line.setAmountLocal(new BigDecimal("999999"));
        request.setItems(List.of(line));
        return request;
    }

    @Test
    void reversingTheEarlierPartialReturnPreservesLaterCreditAndAllowsFullReturnAgain() {
        Fixture fixture = seed();
        UUID first = service.create(request(fixture)).getId();
        UUID second = service.create(request(fixture)).getId();
        service.approve(first);
        service.approve(second);
        assertThat(service.detail(first).getTotalOriginal()).isEqualByComparingTo("0.3333");
        assertThat(service.detail(second).getTotalOriginal()).isEqualByComparingTo("0.3334");
        service.reverse(first);
        assertThat(jdbc.queryForObject("SELECT returned_qty FROM sales_shipment_items WHERE id=?",
                BigDecimal.class, fixture.shipmentItemId())).isEqualByComparingTo("1");
        assertThat(jdbc.queryForObject("SELECT returned_amount FROM sales_shipment_items WHERE id=?",
                BigDecimal.class, fixture.shipmentItemId())).isEqualByComparingTo("2.3334");
        for (int remaining = 0; remaining < 2; remaining++) {
            UUID replacement = service.create(request(fixture)).getId();
            service.approve(replacement);
        }
        assertThat(service.detail(second).getTotalOriginal()).isEqualByComparingTo("0.3334");
        assertThat(jdbc.queryForObject("""
                SELECT SUM(ledger.amount_original) FROM ar_ap_ledger ledger
                JOIN sales_returns returned ON returned.id=ledger.source_doc_id
                WHERE ledger.source_doc_type='SALES_RETURN' AND ledger.status=1
                  AND returned.source_shipment_id=?
                """, BigDecimal.class, fixture.shipmentId())).isEqualByComparingTo("-1");
        assertThat(jdbc.queryForObject("""
                SELECT SUM(ledger.amount_original_local) FROM ar_ap_ledger ledger
                JOIN sales_returns returned ON returned.id=ledger.source_doc_id
                WHERE ledger.source_doc_type='SALES_RETURN' AND ledger.status=1
                  AND returned.source_shipment_id=?
                """, BigDecimal.class, fixture.shipmentId())).isEqualByComparingTo("-7");
        assertThat(jdbc.queryForObject("SELECT returned_qty FROM sales_shipment_items WHERE id=?",
                BigDecimal.class, fixture.shipmentItemId())).isEqualByComparingTo("3");
        assertThat(jdbc.queryForObject("SELECT amount_original FROM ar_ap_ledger WHERE source_doc_id=?",
                BigDecimal.class, first)).isEqualByComparingTo("-0.3333");
    }

    @Test
    void concurrentReturnsSerializeOnTheShipmentAndCannotExceedOriginalQuantityOrDebt() throws Exception {
        Fixture fixture = seed();
        var request = request(fixture);
        request.getItems().getFirst().setQty(new BigDecimal("2"));
        UUID first = service.create(request).getId();
        UUID second = service.create(request).getId();
        var authentication = SecurityContextHolder.getContext().getAuthentication();
        try (var executor = java.util.concurrent.Executors.newFixedThreadPool(2)) {
            var start = new java.util.concurrent.CountDownLatch(1);
            var futures = List.of(first, second).stream().map(id -> executor.submit(() -> {
                SecurityContextHolder.getContext().setAuthentication(authentication);
                try {
                    start.await();
                    service.approve(id);
                    return true;
                } catch (com.uten.imp.common.web.ApiException expectedConflict) {
                    return false;
                } finally { SecurityContextHolder.clearContext(); }
            })).toList();
            start.countDown();
            int approvals = 0;
            for (var future : futures) if (future.get(30, java.util.concurrent.TimeUnit.SECONDS)) approvals++;
            assertThat(approvals).isEqualTo(1);
        }
        assertThat(jdbc.queryForObject("SELECT returned_qty FROM sales_shipment_items WHERE id = ?",
                BigDecimal.class, fixture.shipmentItemId())).isEqualByComparingTo("2");
        assertThat(jdbc.queryForObject("""
                SELECT SUM(ledger.amount_original) FROM ar_ap_ledger ledger
                JOIN sales_returns returned ON returned.id = ledger.source_doc_id
                WHERE ledger.source_doc_type = 'SALES_RETURN' AND ledger.status = 1
                  AND returned.source_shipment_id = ?
                """, BigDecimal.class, fixture.shipmentId())).isEqualByComparingTo("-0.6667");
    }

    private Fixture seed() {
        Fixture fixture = transactions.execute(ignored -> seedHistoricalSource());
        assertThat(jdbc.queryForObject("SELECT COALESCE(current_setting('uten.legacy_reference_import',true),'')",
                String.class)).isEmpty();
        return fixture;
    }

    private Fixture seedHistoricalSource() {
        UUID employeeId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        String suffix = userId.toString().substring(0, 8);
        UUID departmentId = jdbc.queryForObject("SELECT id FROM departments WHERE code = 'DEPT_FIN' AND NOT is_deleted LIMIT 1", UUID.class);
        jdbc.update("""
                INSERT INTO employees(id, code, full_name, id_type, department_id, hire_date,
                    status, employment_type, version)
                VALUES (?, ?, 'Return authority employee', '身份证', ?, DATE '2026-01-01', 'active', 'regular', 0)
                """, employeeId, "RET-EMP-" + suffix, departmentId);
        jdbc.update("""
                INSERT INTO users(id, employee_id, login_account, password_hash, must_change_password,
                    status, failed_attempts, is_super_admin, auth_version)
                VALUES (?, ?, ?, 'x', FALSE, 'active', 0, TRUE, 0)
                """, userId, employeeId, "ret-" + suffix);
        var authorization = permissions.authorizationSnapshot(userId, employeeId, true);
        AuthUser actor = new AuthUser(userId, employeeId, "ret-" + suffix, authorization.roles(),
                authorization.permissions(), false, true, true);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor, null, actor.getAuthorities()));
        tx.bind();
        UUID client = UUID.randomUUID(), goods = UUID.randomUUID(), unit = UUID.randomUUID(), warehouse = UUID.randomUUID();
        UUID currency = jdbc.queryForObject("SELECT id FROM currencies WHERE status = '使用' AND NOT is_deleted ORDER BY id LIMIT 1", UUID.class);
        jdbc.update("INSERT INTO units(id, code, name, status) VALUES (?, ?, '个', '使用')", unit, "RET-U-" + suffix);
        jdbc.update("INSERT INTO warehouses(id, code, name) VALUES (?, ?, 'Return authority warehouse')", warehouse, "RET-W-" + suffix);
        jdbc.update("""
                INSERT INTO clients(id, code, name, status, code_sequence, sales_payment_type)
                VALUES (?, ?, 'Return authority client', '使用', (SELECT COALESCE(MAX(code_sequence), 0)+1 FROM clients), 'MONTHLY')
                """, client, "RET-C-" + suffix);
        jdbc.update("""
                INSERT INTO goods(id, code, name, unit_id, status, code_sequence)
                VALUES (?, ?, 'Return authority goods', ?, '使用', (SELECT COALESCE(MAX(code_sequence), 0)+1 FROM goods))
                """, goods, "RET-G-" + suffix, unit);
        UUID shipment = UUID.randomUUID(), shipmentItem = UUID.randomUUID();
        int sequence = SEQUENCE.incrementAndGet();
        int legacyShipmentId = 100000 + sequence;
        String billNo = "XC20260907%06d".formatted(sequence);
        // Same transaction-local import contract as legacy_migration/migrate_sales.sql.
        // This is S_Out/S_OutItem history: 3 * .5 * .6667 was frozen as A=1/B=7.
        // Do not recalculate it as a new V2 dispatch or invent historical finance approval.
        jdbc.queryForObject("SELECT set_config('uten.legacy_reference_import','legacy-sales-v273',true)", String.class);
        jdbc.update("""
                INSERT INTO sales_shipments(id, legacy_id, bill_no, bill_date, client_id, currency_id, exchange_rate,
                    tax_rate, owner_employee_id, maker_id, warehouse_id, status, warehouse_work_status,
                    finance_gate_version, finance_audit, handed_over_at, ar_posted, total_original, total_local, remark)
                VALUES (?, ?, ?, DATE '2026-09-07', ?, ?, 7, 13, ?, ?, ?, 1, 'SHIPPED', 0, 0,
                    now(), TRUE, 1, 7, 'Historical S_Out/S_OutItem fixture: preserve original frozen A=1/B=7')
                """, shipment, legacyShipmentId, billNo, client, currency, employeeId, employeeId, warehouse);
        jdbc.update("""
                INSERT INTO sales_shipment_items(id, legacy_id, shipment_id, bill_no, bill_date, line_no,
                    goods_id, unit_id, unit_rate, qty, price, discount, amount_original, amount_local,
                    goods_code_snapshot, goods_name_snapshot, goods_snapshot_source, goods_snapshot_locked_at)
                VALUES (?, ?, ?, ?, DATE '2026-09-07', 1, ?, ?, 1, 3, 0.5, 0.6667, 1, 7,
                    ?, 'Return authority goods', 'LEGACY_IMPORT', now())
                """, shipmentItem, legacyShipmentId, shipment, billNo, goods, unit, "RET-G-" + suffix);
        // V511 classifies preexisting shipments without order lineage as LEGACY.
        // Finish the import before freezing that read-only classification.
        jdbc.update("UPDATE sales_shipments SET shipment_kind='LEGACY' WHERE id=?", shipment);
        jdbc.update("""
                INSERT INTO ar_ap_ledger(id, legacy_id, direction, source_doc_type, source_doc_id, source_doc_no,
                    bill_no, bill_date, client_id, currency_id, exchange_rate, amount_original,
                    amount_original_local, amount_balance, status)
                VALUES (gen_random_uuid(), ?, 'AR', 'SALES_SHIPMENT', ?, ?, ?, DATE '2026-09-07', ?, ?, 7, 1, 7, 7, 1)
                """, 200000 + sequence, shipment, billNo, billNo, client, currency);
        UUID originalMovement = UUID.randomUUID();
        // Historical stock import: the actual outbound quantity/source are known,
        // while its cost is explicitly unknown. The real return value service must
        // acquire LEGACY_SALES_MOVEMENT as pending, never as a confirmed zero cost.
        jdbc.update("""
                INSERT INTO stock_movements(id,transaction_date,movement_type,source_doc_type,source_doc_id,
                    source_item_id,goods_id,warehouse_id,direction,qty,unit_id,unit_rate,amount_local,remark,created_by)
                VALUES(?,TIMESTAMPTZ '2026-09-07 10:00:00+08',3,'SALES_SHIPMENT',?,?,?,?, -1,3,?,1,NULL,
                    'Historical outbound fixture: cost unavailable, retain pending source',?)
                """,originalMovement,shipment,shipmentItem,goods,warehouse,unit,userId);
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM stock_movements WHERE id=? AND source_doc_id=? AND source_item_id=?
                    AND goods_id=? AND warehouse_id=? AND qty=3 AND direction=-1 AND amount_local IS NULL
                """,Long.class,originalMovement,shipment,shipmentItem,goods,warehouse)).isEqualTo(1L);
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM audit_log WHERE target_type='sales_shipments' AND target_id=?
                  AND action='insert' AND actor_id=? AND "after"->>'legacy_id'=?
                """, Long.class, shipment.toString(), userId, Integer.toString(legacyShipmentId))).isEqualTo(1L);
        jdbc.queryForObject("SELECT set_config('uten.legacy_reference_import','',true)", String.class);
        return new Fixture(client, goods, unit, warehouse, currency, shipment, shipmentItem, originalMovement);
    }
    private record Fixture(UUID clientId, UUID goodsId, UUID unitId, UUID warehouseId,
            UUID currencyId, UUID shipmentId, UUID shipmentItemId, UUID originalMovementId) {}
}
