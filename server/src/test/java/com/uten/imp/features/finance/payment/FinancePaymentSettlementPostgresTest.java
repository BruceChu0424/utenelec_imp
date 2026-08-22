package com.uten.imp.features.finance.payment;

import com.uten.imp.features.finance.payment.dto.FinancePaymentDetail;
import com.uten.imp.features.finance.payment.dto.FinancePaymentLineInput;
import com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.common.web.ApiException;
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
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.time.LocalDate;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Real PostgreSQL proof for authoritative purchase-payment settlement amounts. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.MOCK,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.policy-intelligence.enabled=false",
                "uten.features.goods-owner-scope-enabled=false",
                "uten.jwt.secret=payment-harness-jwt-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=payment-harness-pgp-key-test-only-0123456789",
                "uten.crypto.hmac-key=payment-harness-hmac-key-test-only",
                "uten.bootstrap.admin-login=payment-bootstrap-admin-test",
                "uten.bootstrap.admin-password=PaymentHarnessAdminPass-1!"
        })
class FinancePaymentSettlementPostgresTest {

    private static final java.util.concurrent.atomic.AtomicInteger BUSINESS_IDENTIFIER_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();

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
    private FinancePaymentService service;

    @Autowired
    private GlPostingService glPostingService;

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void authoritativeAmountsDriveLedgerAccountAndReconciliation() {
        UUID currencyId = UUID.randomUUID();
        UUID supplierId = UUID.randomUUID();
        UUID accountId = UUID.randomUUID();
        UUID ledgerId = UUID.randomUUID();
        seedPayable(currencyId, supplierId, accountId, ledgerId);

        UUID makerEmployeeId = UUID.randomUUID();
        loginAsSuperAdmin(UUID.randomUUID(), makerEmployeeId, "payment-maker");
        FinancePaymentDetail draft = service.create(request(
                currencyId, supplierId, accountId, ledgerId));

        Map<String, Object> savedLine = jdbc.queryForMap("""
                SELECT amount_original, amount_local, exchange_diff
                FROM finance_payment_lines
                WHERE payment_id = ?
                """, draft.getId());
        assertMoney(savedLine.get("amount_original"), "30.0000");
        assertMoney(savedLine.get("amount_local"), "216.0000");
        assertMoney(savedLine.get("exchange_diff"), "6.0000");
        assertMoney(draft.getAmountOriginal(), "30.0000");
        assertMoney(draft.getAmountLocal(), "216.0000");
        assertMoney(draft.getItems().getFirst().getAppliedAmountLocal(), "210.0000");
        assertThat(jdbc.queryForObject("""
                SELECT amount_authority_version FROM finance_payments WHERE id=?
                """, Short.class, draft.getId())).isEqualTo((short) 1);

        loginAsSuperAdmin(UUID.randomUUID(), UUID.randomUUID(), "payment-approver");
        service.approve(draft.getId());

        Map<String, Object> ledger = jdbc.queryForMap("""
                SELECT amount_received_original, amount_received_local,
                       amount_settled, amount_balance_original, amount_balance
                FROM ar_ap_ledger
                WHERE id = ?
                """, ledgerId);
        assertMoney(ledger.get("amount_received_original"), "30.0000");
        assertMoney(ledger.get("amount_received_local"), "216.0000");
        assertMoney(ledger.get("amount_settled"), "210.0000");
        assertMoney(ledger.get("amount_balance_original"), "70.0000");
        assertMoney(ledger.get("amount_balance"), "490.0000");

        Map<String, Object> account = jdbc.queryForMap("""
                SELECT balance_current, payments_total
                FROM accounts
                WHERE id = ?
                """, accountId);
        assertMoney(account.get("balance_current"), "970.0000");
        assertMoney(account.get("payments_total"), "30.0000");
        assertMoney(jdbc.queryForObject("""
                SELECT out_amount
                FROM finance_reconciliations
                WHERE source_doc_type = 'PAYMENT' AND source_doc_id = ?
                """, BigDecimal.class, draft.getId()), "30.0000");

        glPostingService.generate("2026-08");
        var entries = jdbc.queryForList("""
                SELECT entry.line_no, entry.direction, entry.amount
                FROM gl_entries entry
                JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id
                WHERE voucher.source='AUTO'
                  AND voucher.source_type='PAYMENT'
                  AND entry.source_doc_id=?
                ORDER BY entry.line_no
                """, draft.getId());
        assertThat(entries).hasSize(3);
        assertThat(((Number) entries.get(0).get("direction")).intValue()).isEqualTo(1);
        assertMoney(entries.get(0).get("amount"), "210.0000");
        assertThat(((Number) entries.get(1).get("direction")).intValue()).isEqualTo(-1);
        assertMoney(entries.get(1).get("amount"), "216.0000");
        assertThat(((Number) entries.get(2).get("direction")).intValue()).isEqualTo(1);
        assertMoney(entries.get(2).get("amount"), "6.0000");
        assertMoney(jdbc.queryForObject("""
                SELECT SUM(entry.direction*entry.amount)
                FROM gl_entries entry
                JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id
                WHERE voucher.source_type='PAYMENT' AND entry.source_doc_id=?
                """, BigDecimal.class, draft.getId()), "0.0000");

        service.reverse(draft.getId());

        Map<String, Object> reversedLedger = jdbc.queryForMap("""
                SELECT amount_received_original, amount_received_local,
                       amount_settled, amount_balance_original, amount_balance
                FROM ar_ap_ledger
                WHERE id = ?
                """, ledgerId);
        assertMoney(reversedLedger.get("amount_received_original"), "0.0000");
        assertMoney(reversedLedger.get("amount_received_local"), "0.0000");
        assertMoney(reversedLedger.get("amount_settled"), "0.0000");
        assertMoney(reversedLedger.get("amount_balance_original"), "100.0000");
        assertMoney(reversedLedger.get("amount_balance"), "700.0000");
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM finance_reconciliations
                WHERE source_doc_type = 'PAYMENT' AND source_doc_id = ?
                """, Long.class, draft.getId())).isZero();
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM gl_vouchers
                WHERE source='AUTO' AND source_type='PAYMENT' AND voucher_no=?
                """, Long.class, draft.getBillNo())).isZero();
        assertThatThrownBy(() -> service.delete(draft.getId()))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("仅草稿单据可删除");
        assertThat(jdbc.queryForObject("""
                SELECT is_deleted FROM finance_payments WHERE id=?
                """, Boolean.class, draft.getId())).isFalse();
    }

    @Test
    void historicalUnverifiedPaymentBlocksGlRegenerationAndReverse() {
        UUID paymentId = UUID.randomUUID();
        String billNo = businessIdentifier("CF", LocalDate.of(2036, 3, 1));
        jdbc.update("""
                INSERT INTO finance_payments (
                    id, bill_no, bill_date, exchange_rate,
                    amount_original, amount_local, status, is_deleted)
                VALUES (?, ?, DATE '2036-03-01', 1, 10, 10, 1, false)
                """, paymentId, billNo);
        jdbc.update("""
                INSERT INTO gl_vouchers (
                    id, voucher_no, period, voucher_date, source, source_type, source_doc_id)
                VALUES (?, ?, '2036-03', DATE '2036-03-01', 'AUTO', 'PAYMENT', ?)
                """, UUID.randomUUID(), billNo, paymentId);
        loginAsSuperAdmin(UUID.randomUUID(), UUID.randomUUID(), "historical-payment-auditor");

        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM finance_payments
                WHERE status=1 AND COALESCE(is_deleted,false)=false
                  AND amount_authority_version=0
                """, Long.class)).isPositive();
        assertThatThrownBy(() -> glPostingService.generate("2036-03"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("历史付款")
                .hasMessageContaining("禁止重生成总账凭证");
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM gl_vouchers
                WHERE voucher_no=? AND source_type='PAYMENT'
                """, Long.class, billNo)).isEqualTo(1L);
        assertThatThrownBy(() -> service.reverse(paymentId))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("历史付款金额尚未经过服务端核验");
    }

    @Test
    void approveWinsTheHeaderLockBeforeConcurrentUpdateAndDelete() throws Exception {
        UUID currencyId = UUID.randomUUID();
        UUID supplierId = UUID.randomUUID();
        UUID accountId = UUID.randomUUID();
        UUID ledgerId = UUID.randomUUID();
        seedPayable(currencyId, supplierId, accountId, ledgerId);
        UUID makerEmployeeId = UUID.randomUUID();
        loginAsSuperAdmin(UUID.randomUUID(), makerEmployeeId, "concurrent-payment-maker");
        FinancePaymentSaveRequest saveRequest = request(
                currencyId, supplierId, accountId, ledgerId);
        saveRequest.setBillDate(LocalDate.of(2035, 1, 1));
        FinancePaymentDetail draft = service.create(saveRequest);

        ExecutorService executor = Executors.newFixedThreadPool(3);
        try (Connection blocker = jdbc.getDataSource().getConnection()) {
            blocker.setAutoCommit(false);
            try (PreparedStatement lock = blocker.prepareStatement(
                    "SELECT id FROM finance_payments WHERE id=? FOR UPDATE")) {
                lock.setObject(1, draft.getId());
                lock.executeQuery().close();
            }

            Future<FinancePaymentDetail> approve = executor.submit(() -> {
                loginAsSuperAdmin(UUID.randomUUID(), UUID.randomUUID(), "concurrent-payment-approver");
                try {
                    return service.approve(draft.getId());
                } finally {
                    SecurityContextHolder.clearContext();
                }
            });
            assertBlocked(approve);

            Future<?> update = executor.submit(() -> {
                loginAsSuperAdmin(UUID.randomUUID(), UUID.randomUUID(), "concurrent-payment-editor");
                try {
                    return service.update(draft.getId(), saveRequest);
                } finally {
                    SecurityContextHolder.clearContext();
                }
            });
            Future<?> delete = executor.submit(() -> {
                loginAsSuperAdmin(UUID.randomUUID(), UUID.randomUUID(), "concurrent-payment-deleter");
                try {
                    service.delete(draft.getId());
                    return null;
                } finally {
                    SecurityContextHolder.clearContext();
                }
            });
            assertBlocked(update);
            assertBlocked(delete);

            blocker.commit();
            assertThat(approve.get(10, TimeUnit.SECONDS).getStatus()).isEqualTo((short) 1);
            assertApiFailure(update, "仅草稿单据可编辑");
            assertApiFailure(delete, "仅草稿单据可删除");
        } finally {
            executor.shutdownNow();
        }
        assertThat(jdbc.queryForObject("""
                SELECT status FROM finance_payments WHERE id=?
                """, Short.class, draft.getId())).isEqualTo((short) 1);
    }

    @Test
    void deleteWinsTheHeaderLockAndWaitingCommandsObserveTheSoftDelete() throws Exception {
        UUID currencyId = UUID.randomUUID();
        UUID supplierId = UUID.randomUUID();
        UUID accountId = UUID.randomUUID();
        UUID ledgerId = UUID.randomUUID();
        seedPayable(currencyId, supplierId, accountId, ledgerId);
        loginAsSuperAdmin(UUID.randomUUID(), UUID.randomUUID(), "delete-wins-maker");
        FinancePaymentSaveRequest saveRequest = request(
                currencyId, supplierId, accountId, ledgerId);
        saveRequest.setBillDate(LocalDate.of(2038, 5, 1));
        FinancePaymentDetail draft = service.create(saveRequest);

        ExecutorService executor = Executors.newFixedThreadPool(3);
        try (Connection blocker = jdbc.getDataSource().getConnection()) {
            blocker.setAutoCommit(false);
            lockPayment(blocker, draft.getId());

            Future<?> delete = executor.submit(() -> {
                loginAsSuperAdmin(UUID.randomUUID(), UUID.randomUUID(), "delete-wins-deleter");
                try {
                    service.delete(draft.getId());
                    return null;
                } finally {
                    SecurityContextHolder.clearContext();
                }
            });
            assertBlocked(delete);
            Future<?> approve = executor.submit(() -> {
                loginAsSuperAdmin(UUID.randomUUID(), UUID.randomUUID(), "delete-wins-approver");
                try {
                    return service.approve(draft.getId());
                } finally {
                    SecurityContextHolder.clearContext();
                }
            });
            Future<?> update = executor.submit(() -> {
                loginAsSuperAdmin(UUID.randomUUID(), UUID.randomUUID(), "delete-wins-editor");
                try {
                    return service.update(draft.getId(), saveRequest);
                } finally {
                    SecurityContextHolder.clearContext();
                }
            });
            assertBlocked(approve);
            assertBlocked(update);

            blocker.commit();
            delete.get(10, TimeUnit.SECONDS);
            assertApiFailure(approve, "采购付款单不存在");
            assertApiFailure(update, "采购付款单不存在");
        } finally {
            executor.shutdownNow();
        }
        Map<String, Object> state = jdbc.queryForMap("""
                SELECT status, is_deleted FROM finance_payments WHERE id=?
                """, draft.getId());
        assertThat(((Number) state.get("status")).intValue()).isZero();
        assertThat(state.get("is_deleted")).isEqualTo(true);
    }

    @Test
    void reverseAndPeriodRegenerationSerializeToNoPaymentVoucher() throws Exception {
        UUID currencyId = UUID.randomUUID();
        UUID supplierId = UUID.randomUUID();
        UUID accountId = UUID.randomUUID();
        UUID ledgerId = UUID.randomUUID();
        seedPayable(currencyId, supplierId, accountId, ledgerId);
        loginAsSuperAdmin(UUID.randomUUID(), UUID.randomUUID(), "projection-race-maker");
        FinancePaymentSaveRequest saveRequest = request(
                currencyId, supplierId, accountId, ledgerId);
        saveRequest.setBillDate(LocalDate.of(2037, 4, 2));
        FinancePaymentDetail draft = service.create(saveRequest);
        loginAsSuperAdmin(UUID.randomUUID(), UUID.randomUUID(), "projection-race-approver");
        service.approve(draft.getId());
        glPostingService.generate("2037-04");
        assertThat(paymentVoucherCount(draft.getBillNo())).isEqualTo(1L);

        ExecutorService executor = Executors.newFixedThreadPool(2);
        try (Connection blocker = jdbc.getDataSource().getConnection()) {
            blocker.setAutoCommit(false);
            try (PreparedStatement lock = blocker.prepareStatement(
                    "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))")) {
                lock.setString(1, "uten:gl:auto-period:2037-04");
                lock.executeQuery().close();
            }

            Future<?> reverse = executor.submit(() -> {
                loginAsSuperAdmin(UUID.randomUUID(), UUID.randomUUID(), "projection-race-reverser");
                try {
                    return service.reverse(draft.getId());
                } finally {
                    SecurityContextHolder.clearContext();
                }
            });
            assertBlocked(reverse);
            Future<?> regenerate = executor.submit(() -> {
                loginAsSuperAdmin(UUID.randomUUID(), UUID.randomUUID(), "projection-race-generator");
                try {
                    return glPostingService.generate("2037-04");
                } finally {
                    SecurityContextHolder.clearContext();
                }
            });
            assertBlocked(regenerate);

            blocker.commit();
            reverse.get(10, TimeUnit.SECONDS);
            regenerate.get(10, TimeUnit.SECONDS);
        } finally {
            executor.shutdownNow();
        }
        assertThat(jdbc.queryForObject("""
                SELECT status FROM finance_payments WHERE id=?
                """, Short.class, draft.getId())).isEqualTo((short) -1);
        assertThat(paymentVoucherCount(draft.getBillNo())).isZero();
    }

    private void seedPayable(
            UUID currencyId,
            UUID supplierId,
            UUID accountId,
            UUID ledgerId) {
        seedAccountingStyles();
        jdbc.update("""
                INSERT INTO currencies (id, code, name, exchange_rate, status)
                VALUES (?, ?, '美元', 7.000000, '使用')
                """, currencyId, "USD-PAY-" + currencyId);
        jdbc.update("""
                INSERT INTO suppliers (id, code, name, status, code_sequence)
                VALUES (?, ?, '付款结算测试供应商', '使用',
                        (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM suppliers))
                """, supplierId, "SUP-PAY-" + supplierId);
        jdbc.update("""
                INSERT INTO accounts (
                    id, code, name, account_type, currency_id,
                    init_balance, receipts_total, payments_total, balance_current,
                    status, style_id)
                VALUES (?, ?, '付款结算测试美元账户', 'BANK', ?, 1000, 0, 0, 1000, '使用',
                        (SELECT id FROM payment_styles WHERE path='/102/' AND category='ACCOUNT'
                           AND status='使用' AND COALESCE(is_deleted,false)=false))
                """, accountId, "ACC-PAY-" + accountId, currencyId);
        jdbc.update("""
                INSERT INTO ar_ap_ledger (
                    id, direction, business_type, open_item_kind,
                    source_doc_type, source_doc_id, source_doc_no,
                    bill_no, bill_date, supplier_id, currency_id, exchange_rate,
                    amount_original, amount_original_local,
                    amount_received_original, amount_received_local,
                    amount_write_off_original, amount_write_off_local,
                    amount_balance_original, amount_settled, amount_balance,
                    is_settled, status, is_deleted)
                VALUES (
                    ?, 'AP', 'PURCHASE', 'PAYABLE',
                    'PURCHASE_RECEIPT', ?, 'CJ-PAYMENT-TEST',
                    ?, DATE '2026-08-01', ?, ?, 7.000000,
                    100.0000, 700.0000,
                    0, 0, 0, 0, 100.0000, 0, 700.0000,
                    false, 1, false)
                """, ledgerId, UUID.randomUUID(),
                "CJ-PAYMENT-" + ledgerId, supplierId, currencyId);
    }

    private void seedAccountingStyles() {
        seedCoreStyle("123", "库存商品", "ACCOUNT", "/123/");
        seedCoreStyle("203", "应付账款", "LIABILITY", "/203/");
        seedCoreStyle("102", "银行存款", "ACCOUNT", "/102/");
        Long fxCount = jdbc.queryForObject("""
                SELECT COUNT(*) FROM payment_styles
                WHERE category='EXPENSE' AND name='汇兑损益'
                  AND status='使用' AND COALESCE(is_deleted,false)=false
                """, Long.class);
        if (fxCount == null || fxCount == 0) {
            jdbc.update("""
                    INSERT INTO payment_styles (id, code, name, category, status, auto_created)
                    VALUES (?, ?, '汇兑损益', 'EXPENSE', '使用', true)
                    """, UUID.randomUUID(), "FX-PAYMENT-TEST");
        }
        jdbc.update("""
                UPDATE system_posting_style_roles role
                SET style_id = source.id
                FROM payment_styles source
                WHERE (role.role_key, source.path) IN (
                    ('AP_CONTROL', '/203/'),
                    ('INVENTORY_ASSET', '/123/'))
                  AND source.status='使用' AND COALESCE(source.is_deleted,false)=false
                """);
        jdbc.update("""
                UPDATE system_posting_style_roles role
                SET style_id = source.id
                FROM payment_styles source
                WHERE role.role_key='FX_GAIN_LOSS'
                  AND source.category='EXPENSE' AND source.name='汇兑损益'
                  AND source.status='使用' AND COALESCE(source.is_deleted,false)=false
                """);
    }

    private void seedCoreStyle(String code, String name, String category, String path) {
        Long count = jdbc.queryForObject("""
                SELECT COUNT(*) FROM payment_styles
                WHERE path=? AND status='使用' AND COALESCE(is_deleted,false)=false
                """, Long.class, path);
        if (count == null || count == 0) {
            jdbc.update("""
                    INSERT INTO payment_styles (id, code, name, category, status)
                    VALUES (?, ?, ?, ?, '使用')
                    """, UUID.randomUUID(), code, name, category);
        }
    }

    private FinancePaymentSaveRequest request(
            UUID currencyId,
            UUID supplierId,
            UUID accountId,
            UUID ledgerId) {
        FinancePaymentLineInput line = new FinancePaymentLineInput();
        line.setAppliedLedgerId(ledgerId);
        line.setAppliedBillNo("CLIENT-CONTROLLED");
        line.setSupplierId(supplierId);
        line.setAmountOriginal(new BigDecimal("30.0000"));
        line.setAmountLocal(new BigDecimal("9999.0000"));
        line.setExchangeDiff(new BigDecimal("-8888.0000"));

        FinancePaymentSaveRequest request = new FinancePaymentSaveRequest();
        request.setBillDate(LocalDate.of(2026, 8, 9));
        request.setSupplierId(supplierId);
        request.setAccountId(accountId);
        request.setCurrencyId(currencyId);
        request.setExchangeRate(new BigDecimal("7.200000"));
        request.setAmountOriginal(new BigDecimal("999.0000"));
        request.setAmountLocal(new BigDecimal("9999.0000"));
        request.setItems(java.util.List.of(line));
        return request;
    }

    private static void loginAsSuperAdmin(UUID userId, UUID employeeId, String loginAccount) {
        AuthUser user = new AuthUser(
                userId, employeeId, loginAccount,
                Set.of(), Set.of("finance_post:execute"), false, true, true);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
    }

    private static void assertBlocked(Future<?> future) {
        assertThatThrownBy(() -> future.get(250, TimeUnit.MILLISECONDS))
                .isInstanceOf(TimeoutException.class);
    }

    private static void lockPayment(Connection connection, UUID paymentId) throws Exception {
        try (PreparedStatement lock = connection.prepareStatement(
                "SELECT id FROM finance_payments WHERE id=? FOR UPDATE")) {
            lock.setObject(1, paymentId);
            lock.executeQuery().close();
        }
    }

    private static String businessIdentifier(String prefix, LocalDate date) {
        int sequence = BUSINESS_IDENTIFIER_SEQUENCE.incrementAndGet();
        if (sequence > 999_999) {
            throw new IllegalStateException("test business identifier sequence exhausted");
        }
        return prefix + date.toString().replace("-", "") + "%06d".formatted(sequence);
    }

    private long paymentVoucherCount(String billNo) {
        Long count = jdbc.queryForObject("""
                SELECT COUNT(*) FROM gl_vouchers
                WHERE source='AUTO' AND source_type='PAYMENT' AND voucher_no=?
                """, Long.class, billNo);
        return count == null ? 0 : count;
    }

    private static void assertApiFailure(Future<?> future, String message) {
        try {
            future.get(10, TimeUnit.SECONDS);
            throw new AssertionError("concurrent operation unexpectedly succeeded");
        } catch (ExecutionException failure) {
            assertThat(failure.getCause()).isInstanceOf(ApiException.class);
            assertThat(failure.getCause().getMessage()).contains(message);
        } catch (Exception failure) {
            throw new AssertionError("concurrent operation did not fail as expected", failure);
        }
    }

    private static void assertMoney(Object actual, String expected) {
        assertThat(actual).isInstanceOf(BigDecimal.class);
        assertThat(((BigDecimal) actual).compareTo(new BigDecimal(expected))).isZero();
    }
}
