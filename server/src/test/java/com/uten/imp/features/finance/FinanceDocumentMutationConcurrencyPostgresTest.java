package com.uten.imp.features.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.bank_transfer.FinanceBankTransferService;
import com.uten.imp.features.finance.expense.FinanceExpenseService;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.features.finance.other_income.FinanceOtherIncomeService;
import com.uten.imp.features.finance.receipt.FinanceReceiptService;
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

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** PostgreSQL proof that finance header commands serialize on the document row. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.MOCK,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.policy-intelligence.enabled=false",
                "uten.features.goods-owner-scope-enabled=false",
                "uten.jwt.secret=finance-lock-harness-jwt-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=finance-lock-harness-pgp-key-test-only-0123456789",
                "uten.crypto.hmac-key=finance-lock-harness-hmac-key-test-only",
                "uten.bootstrap.admin-password=FinanceLockHarnessAdminPass-1!"
        })
class FinanceDocumentMutationConcurrencyPostgresTest {

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

    @Autowired private JdbcTemplate jdbc;
    @Autowired private FinanceReceiptService receiptService;
    @Autowired private FinanceOtherIncomeService incomeService;
    @Autowired private FinanceBankTransferService transferService;
    @Autowired private FinanceExpenseService expenseService;
    @Autowired private GlPostingService glPostingService;

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void deleteWinsAndWaitingApprovalsObserveTheSoftDeleteAcrossAllDocuments() throws Exception {
        List<DraftDocument> documents = seedDrafts("DELETE-" + UUID.randomUUID());
        ExecutorService executor = Executors.newFixedThreadPool(2);
        try {
            for (DraftDocument document : documents) {
                try (Connection blocker = jdbc.getDataSource().getConnection()) {
                    blocker.setAutoCommit(false);
                    lockHeader(blocker, document);

                    Future<?> delete = executor.submit(() -> callAsSuperAdmin(
                            document.label() + "-deleter", () -> {
                                document.delete().run();
                                return null;
                            }));
                    assertBlocked(delete);
                    Future<?> approve = executor.submit(() -> callAsSuperAdmin(
                            document.label() + "-waiting-approver", document.approve()));
                    assertBlocked(approve);

                    blocker.commit();
                    delete.get(15, TimeUnit.SECONDS);
                    assertApiFailure(approve, ErrorCode.NOT_FOUND, "不存在");
                }

                Map<String, Object> state = documentState(document);
                assertThat(((Number) state.get("status")).intValue()).as(document.label()).isZero();
                assertThat(state.get("is_deleted")).as(document.label()).isEqualTo(true);
                assertThat(reconciliationCount(document)).as(document.label()).isZero();
            }
        } finally {
            executor.shutdownNow();
        }
    }

    @Test
    void approveWinsAndWaitingDeletesObserveTheApprovedStateAcrossAllDocuments() throws Exception {
        List<DraftDocument> documents = seedDrafts("APPROVE-" + UUID.randomUUID());
        ExecutorService executor = Executors.newFixedThreadPool(2);
        try {
            for (DraftDocument document : documents) {
                try (Connection blocker = jdbc.getDataSource().getConnection()) {
                    blocker.setAutoCommit(false);
                    lockHeader(blocker, document);

                    Future<?> approve = executor.submit(() -> callAsSuperAdmin(
                            document.label() + "-approver", document.approve()));
                    assertBlocked(approve);
                    Future<?> delete = executor.submit(() -> callAsSuperAdmin(
                            document.label() + "-waiting-deleter", () -> {
                                document.delete().run();
                                return null;
                            }));
                    assertBlocked(delete);

                    blocker.commit();
                    approve.get(15, TimeUnit.SECONDS);
                    assertApiFailure(delete, ErrorCode.BUSINESS, "仅草稿单据可删除");
                }

                Map<String, Object> state = documentState(document);
                assertThat(((Number) state.get("status")).intValue()).as(document.label()).isEqualTo(1);
                assertThat(state.get("is_deleted")).as(document.label()).isEqualTo(false);
                assertThat(reconciliationCount(document))
                        .as(document.label())
                        .isEqualTo(document.approvedReconciliationCount());
            }
        } finally {
            executor.shutdownNow();
        }
    }

    @Test
    void confirmedExpenseSurvivesRejectedPeriodRegenerationByteForByte() throws Exception {
        DraftDocument expense = seedDrafts("CONFIRMED-" + UUID.randomUUID()).stream()
                .filter(document -> document.label().equals("expense"))
                .findFirst()
                .orElseThrow();
        callAsSuperAdmin("confirmed-expense-approver", expense.approve());
        callAsSuperAdmin("confirmed-expense-finance", () -> expenseService.glConfirm(expense.id()));

        Map<String, Object> expenseBefore = jdbc.queryForMap("""
                SELECT status, gl_status, gl_voucher_id
                FROM finance_expenses
                WHERE id=?
                """, expense.id());
        UUID voucherId = (UUID) expenseBefore.get("gl_voucher_id");
        Map<String, Object> voucherBefore = voucherState(voucherId);
        List<Map<String, Object>> entriesBefore = entryState(voucherId);
        assertThat(((Number) expenseBefore.get("status")).intValue()).isEqualTo(1);
        assertThat(((Number) expenseBefore.get("gl_status")).intValue()).isEqualTo(2);
        assertThat(voucherId).isNotNull();
        assertThat(entriesBefore).hasSizeGreaterThanOrEqualTo(2);

        assertThatThrownBy(() -> callAsSuperAdmin(
                "confirmed-expense-generator", () -> glPostingService.generate("2042-02")))
                .isInstanceOf(ApiException.class)
                .satisfies(failure -> assertThat(((ApiException) failure).getCode())
                        .isEqualTo(ErrorCode.CONFLICT))
                .hasMessageContaining("已财务确认")
                .hasMessageContaining("禁止物理删除");

        Map<String, Object> expenseAfter = jdbc.queryForMap("""
                SELECT status, gl_status, gl_voucher_id
                FROM finance_expenses
                WHERE id=?
                """, expense.id());
        assertThat(expenseAfter).isEqualTo(expenseBefore);
        assertThat(voucherState(voucherId)).isEqualTo(voucherBefore);
        assertThat(entryState(voucherId)).containsExactlyElementsOf(entriesBefore);
    }

    private List<DraftDocument> seedDrafts(String suffix) {
        seedCoreStyle("102", "银行存款", "ACCOUNT", "/102/");
        UUID currencyId = UUID.randomUUID();
        UUID clientId = UUID.randomUUID();
        UUID makerId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO currencies (id, code, name, exchange_rate, status)
                VALUES (?, ?, '人民币', 1.000000, '使用')
                """, currencyId, "CUR-" + suffix);
        jdbc.update("""
                INSERT INTO clients (id, code, name, status)
                VALUES (?, ?, '财务并发测试客户', '使用')
                """, clientId, "CLI-" + suffix);

        UUID receiptAccount = seedAccount(currencyId, suffix + "-RECEIPT");
        UUID incomeAccount = seedAccount(currencyId, suffix + "-INCOME");
        UUID expenseAccount = seedAccount(currencyId, suffix + "-EXPENSE");
        UUID transferOutAccount = seedAccount(currencyId, suffix + "-TRANSFER-OUT");
        UUID transferInAccount = seedAccount(currencyId, suffix + "-TRANSFER-IN");
        UUID incomeStyle = seedLeafStyle("INCOME", suffix + "-INCOME-STYLE");
        UUID expenseStyle = seedLeafStyle("EXPENSE", suffix + "-EXPENSE-STYLE");

        LocalDate billDate = LocalDate.of(2042, 2, 12);
        UUID receiptId = UUID.randomUUID();
        String receiptNo = "XS-" + suffix;
        jdbc.update("""
                INSERT INTO finance_receipts (
                    id, bill_no, bill_date, client_id, account_id, currency_id,
                    exchange_rate, amount_original, amount_local, bank_fee, other_fee,
                    maker_id, status, is_deleted)
                VALUES (?, ?, ?, ?, ?, ?, 1.000000, 10.0000, 10.0000, 0, 0, ?, 0, false)
                """, receiptId, receiptNo, billDate, clientId, receiptAccount, currencyId, makerId);

        UUID incomeId = UUID.randomUUID();
        String incomeNo = "QS-" + suffix;
        jdbc.update("""
                INSERT INTO finance_other_incomes (
                    id, bill_no, bill_date, account_id, currency_id, exchange_rate,
                    amount_original, amount_local, maker_id, status, is_deleted)
                VALUES (?, ?, ?, ?, ?, 1.000000, 10.0000, 10.0000, ?, 0, false)
                """, incomeId, incomeNo, billDate, incomeAccount, currencyId, makerId);
        jdbc.update("""
                INSERT INTO finance_other_income_items (
                    id, income_id, bill_no, bill_date, income_style_id,
                    amount_original, amount_local, line_no, is_deleted)
                VALUES (?, ?, ?, ?, ?, 10.0000, 10.0000, 1, false)
                """, UUID.randomUUID(), incomeId, incomeNo, billDate, incomeStyle);

        UUID transferId = UUID.randomUUID();
        String transferNo = "YC-" + suffix;
        jdbc.update("""
                INSERT INTO finance_bank_transfers (
                    id, bill_no, bill_date, out_account_id, currency_id, exchange_rate,
                    amount_original, amount_local, maker_id, status, is_deleted)
                VALUES (?, ?, ?, ?, ?, 1.000000, 10.0000, 10.0000, ?, 0, false)
                """, transferId, transferNo, billDate, transferOutAccount, currencyId, makerId);
        jdbc.update("""
                INSERT INTO finance_bank_transfer_lines (
                    id, transfer_id, bill_no, bill_date, in_account_id,
                    amount_original, amount_local, line_no, is_deleted)
                VALUES (?, ?, ?, ?, ?, 10.0000, 10.0000, 1, false)
                """, UUID.randomUUID(), transferId, transferNo, billDate, transferInAccount);

        UUID expenseId = UUID.randomUUID();
        String expenseNo = "YF-" + suffix;
        jdbc.update("""
                INSERT INTO finance_expenses (
                    id, bill_no, bill_date, account_id, currency_id, exchange_rate,
                    amount_original, amount_local, maker_id, status, gl_status, is_deleted)
                VALUES (?, ?, ?, ?, ?, 1.000000, 10.0000, 10.0000, ?, 0, 0, false)
                """, expenseId, expenseNo, billDate, expenseAccount, currencyId, makerId);
        jdbc.update("""
                INSERT INTO finance_expense_items (
                    id, expense_id, bill_no, bill_date, expense_style_id,
                    amount_original, amount_local, line_no, is_deleted)
                VALUES (?, ?, ?, ?, ?, 10.0000, 10.0000, 1, false)
                """, UUID.randomUUID(), expenseId, expenseNo, billDate, expenseStyle);

        return List.of(
                new DraftDocument(
                        "receipt", "finance_receipts", "RECEIPT", 1, receiptId,
                        () -> receiptService.delete(receiptId), () -> receiptService.approve(receiptId)),
                new DraftDocument(
                        "income", "finance_other_incomes", "INCOME", 1, incomeId,
                        () -> incomeService.delete(incomeId), () -> incomeService.approve(incomeId)),
                new DraftDocument(
                        "bank-transfer", "finance_bank_transfers", "BANK_TRANSFER", 2, transferId,
                        () -> transferService.delete(transferId), () -> transferService.approve(transferId)),
                new DraftDocument(
                        "expense", "finance_expenses", "EXPENSE", 1, expenseId,
                        () -> expenseService.delete(expenseId), () -> expenseService.approve(expenseId)));
    }

    private UUID seedAccount(UUID currencyId, String suffix) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO accounts (
                    id, code, name, account_type, currency_id,
                    init_balance, receipts_total, payments_total, balance_current, status)
                VALUES (?, ?, ?, 'BANK', ?, 100.0000, 0, 0, 100.0000, '使用')
                """, id, "ACC-" + suffix, "并发财务账户-" + suffix, currencyId);
        return id;
    }

    private UUID seedLeafStyle(String category, String suffix) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO payment_styles (id, code, name, category, status)
                VALUES (?, ?, ?, ?, '使用')
                """, id, "STYLE-" + suffix, "并发测试科目-" + suffix, category);
        return id;
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

    private static void lockHeader(Connection connection, DraftDocument document) throws Exception {
        try (PreparedStatement lock = connection.prepareStatement(
                "SELECT id FROM " + document.table() + " WHERE id=? FOR UPDATE")) {
            lock.setObject(1, document.id());
            lock.executeQuery().close();
        }
    }

    private Map<String, Object> documentState(DraftDocument document) {
        return jdbc.queryForMap(
                "SELECT status, is_deleted FROM " + document.table() + " WHERE id=?",
                document.id());
    }

    private long reconciliationCount(DraftDocument document) {
        Long count = jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM finance_reconciliations
                WHERE source_doc_type=? AND source_doc_id=?
                """, Long.class, document.sourceType(), document.id());
        return count == null ? 0 : count;
    }

    private Map<String, Object> voucherState(UUID voucherId) {
        return jdbc.queryForMap("""
                SELECT id, voucher_no, period, voucher_date, source, source_type,
                       remark, status, is_deleted
                FROM gl_vouchers
                WHERE id=?
                """, voucherId);
    }

    private List<Map<String, Object>> entryState(UUID voucherId) {
        return jdbc.queryForList("""
                SELECT id, voucher_id, line_no, style_id, direction, amount,
                       entry_date, period, source_doc_type, source_doc_id,
                       source_bill_no, summary, is_deleted
                FROM gl_entries
                WHERE voucher_id=?
                ORDER BY line_no, id
                """, voucherId);
    }

    private static Object callAsSuperAdmin(String login, Callable<?> action) throws Exception {
        loginAsSuperAdmin(UUID.randomUUID(), UUID.randomUUID(), login);
        try {
            return action.call();
        } finally {
            SecurityContextHolder.clearContext();
        }
    }

    private static void loginAsSuperAdmin(UUID userId, UUID employeeId, String loginAccount) {
        AuthUser user = new AuthUser(
                userId, employeeId, loginAccount,
                Set.of(), Set.of("finance_post:execute"), false, true, true);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
    }

    private static void assertBlocked(Future<?> future) {
        assertThatThrownBy(() -> future.get(300, TimeUnit.MILLISECONDS))
                .isInstanceOf(TimeoutException.class);
    }

    private static void assertApiFailure(Future<?> future, ErrorCode code, String message) {
        try {
            future.get(15, TimeUnit.SECONDS);
            throw new AssertionError("concurrent operation unexpectedly succeeded");
        } catch (ExecutionException failure) {
            assertThat(failure.getCause()).isInstanceOf(ApiException.class);
            ApiException api = (ApiException) failure.getCause();
            assertThat(api.getCode()).isEqualTo(code);
            assertThat(api.getMessage()).contains(message);
        } catch (Exception failure) {
            throw new AssertionError("concurrent operation did not fail as expected", failure);
        }
    }

    private record DraftDocument(
            String label,
            String table,
            String sourceType,
            int approvedReconciliationCount,
            UUID id,
            Runnable delete,
            Callable<?> approve) {}
}
