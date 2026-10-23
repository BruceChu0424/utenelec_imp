package com.uten.imp.features.finance;

import com.uten.imp.common.time.BusinessTime;
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
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
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
                "uten.features.goods-owner-scope-enabled=false",
                "uten.jwt.secret=finance-lock-harness-jwt-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=finance-lock-harness-pgp-key-test-only-0123456789",
                "uten.crypto.hmac-key=finance-lock-harness-hmac-key-test-only",
                "uten.bootstrap.admin-login=finance-lock-bootstrap-admin-test",
                "uten.bootstrap.admin-password=FinanceLockHarnessAdminPass-1!"
        })
class FinanceDocumentMutationConcurrencyPostgresTest {

    private static final java.util.concurrent.atomic.AtomicInteger BUSINESS_IDENTIFIER_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();
    private static final java.util.concurrent.atomic.AtomicInteger ACTOR_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();

    private static final PostgreSQLContainer POSTGRES =
            new PostgreSQLContainer("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("fixture_admin")
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
    @Autowired private com.uten.imp.features.documents.DocumentStatusCountQueryService statusCounts;
    @Autowired private com.uten.imp.features.workbench.badge.WorkbenchBadgeService badges;

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void pendingExpenseConfirmationStaysActiveAcrossPagingFacetsScopeAndRealConfirmation() throws Exception {
        DraftDocument template = seedDrafts().stream().filter(document -> document.label().equals("expense"))
                .findFirst().orElseThrow();
        Actor owner = seedCurrentActor("expense-lifecycle-owner");
        Actor other = seedCurrentActor("expense-lifecycle-other");
        jdbc.update("UPDATE finance_expenses SET maker_id=? WHERE id=?", owner.employeeId(), template.id());
        UUID pending = template.id();
        UUID closedPending = copyExpenseDraft(template.id(), owner.employeeId());
        UUID confirmed = copyExpenseDraft(template.id(), owner.employeeId());
        UUID reversed = copyExpenseDraft(template.id(), owner.employeeId());
        UUID draft = copyExpenseDraft(template.id(), owner.employeeId());
        UUID deleted = copyExpenseDraft(template.id(), owner.employeeId());
        UUID foreign = copyExpenseDraft(template.id(), other.employeeId());
        for (UUID id : List.of(pending, closedPending, confirmed, reversed, foreign)) {
            callAsSuperAdmin("expense-lifecycle-approver", () -> expenseService.approve(id));
        }
        callAsSuperAdmin("expense-lifecycle-confirmer", () -> expenseService.glConfirm(confirmed));
        callAsSuperAdmin("expense-lifecycle-reverser", () -> expenseService.reverse(reversed));
        callAsSuperAdmin("expense-lifecycle-deleter", () -> { expenseService.delete(deleted); return null; });
        // The old closed flag is not a glConfirm guard.
        jdbc.update("UPDATE finance_expenses SET is_closed=true WHERE id=?", closedPending);

        loginActor(owner, Set.of("finance_expense:view"));
        var active = expenseFilter("ACTIVE", (short) 1);
        var first = expenseService.list(active, 1, 1, "billNo", "asc");
        var second = expenseService.list(active, 2, 1, "billNo", "asc");
        assertThat(first.getTotal()).isEqualTo(2);
        assertThat(first.getTotalPages()).isEqualTo(2);
        assertThat(second.getTotal()).isEqualTo(2);
        assertThat(first.getItems()).hasSize(1);
        assertThat(second.getItems()).hasSize(1);
        assertThat(List.of(first.getItems().getFirst().getId(), second.getItems().getFirst().getId()))
                .containsExactlyInAnyOrder(pending, closedPending);
        assertThat(first.getItems().getFirst().getGlStatus()).isEqualTo((short) 1);
        assertThat(expenseService.facets(active).get("billNo"))
                .extracting(row -> row.get("value"))
                .containsExactlyInAnyOrder(expenseNo(pending), expenseNo(closedPending));
        assertThat(expenseService.facets(active).get("billNo"))
                .extracting(row -> ((Number) row.get("count")).longValue()).containsOnly(1L);
        assertThat(statusCounts.counts("financeExpense", null, null).get("PENDING_GL_CONFIRMATION"))
                .isEqualTo(2L);
        assertThat(expenseService.list(expenseFilter("ACTIVE", null), 1, 20, null, null).getItems())
                .extracting(row -> row.getId()).containsExactlyInAnyOrder(pending, closedPending, draft);

        var history = expenseFilter("HISTORY", null);
        var historyPage = expenseService.list(history, 1, 20, null, null);
        assertThat(historyPage.getTotal()).isEqualTo(2);
        assertThat(historyPage.getItems()).extracting(row -> row.getId())
                .containsExactlyInAnyOrder(confirmed, reversed);
        assertThat(expenseService.facets(history).get("billNo"))
                .extracting(row -> row.get("value"))
                .containsExactlyInAnyOrder(expenseNo(confirmed), expenseNo(reversed));
        assertThat(expenseService.list(history.withHistory(true, false), 1, 20, null, null).getItems())
                .extracting(row -> row.getId()).containsExactlyInAnyOrder(confirmed, reversed, deleted);
        var narrowed = new com.uten.imp.features.finance.expense.dto.FinanceExpenseQueryFilter(
                expenseNo(closedPending), null, null, (short) 1, BusinessTime.today(), BusinessTime.today(), null)
                .withView("ACTIVE");
        assertThat(expenseService.list(narrowed, 1, 1, null, null).getTotal()).isEqualTo(1);
        assertThat(expenseService.facets(narrowed).get("billNo")).hasSize(1);
        assertThatThrownBy(() -> expenseService.detail(foreign)).isInstanceOf(ApiException.class)
                .satisfies(failure -> assertThat(((ApiException) failure).getCode()).isEqualTo(ErrorCode.NOT_FOUND));
        assertThatThrownBy(() -> expenseService.glConfirm(pending))
                .isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
        assertThatThrownBy(() -> expenseService.confirmationCounts())
                .isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
        assertThat(badges.summary(Set.of("financeExpenseConfirmation")).entries())
                .doesNotContainKey("financeExpenseConfirmation");

        loginActor(owner, Set.of("finance_expense:view", "finance_expense:gl_confirm"));
        assertThat(expenseService.confirmationCounts()).containsEntry("count", 2L);
        assertThat(badges.summary(Set.of("financeExpenseConfirmation")).entries()
                .get("financeExpenseConfirmation").todo()).isEqualTo(2L);
        assertThatThrownBy(() -> expenseService.glConfirm(foreign)).isInstanceOf(ApiException.class)
                .satisfies(failure -> assertThat(((ApiException) failure).getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        expenseService.glConfirm(pending);
        assertThat(expenseService.confirmationCounts()).containsEntry("count", 1L);
        assertThat(badges.summary(Set.of("financeExpenseConfirmation")).entries()
                .get("financeExpenseConfirmation").todo()).isEqualTo(1L);
        assertThat(expenseService.list(active, 1, 1, null, null).getItems())
                .extracting(row -> row.getId()).containsExactly(closedPending);
        assertThat(statusCounts.counts("financeExpense", null, null).get("PENDING_GL_CONFIRMATION"))
                .isEqualTo(1L);
        assertThat(expenseService.facets(active).get("billNo"))
                .extracting(row -> row.get("value")).containsExactly(expenseNo(closedPending));
        assertThat(expenseService.list(history, 1, 20, null, null).getItems())
                .extracting(row -> row.getId()).contains(pending).doesNotContain(closedPending, draft, foreign);
        expenseService.glConfirm(closedPending);
        assertThat(expenseService.confirmationCounts()).containsEntry("count", 0L);
        assertThat(badges.summary(Set.of("financeExpenseConfirmation")).entries()
                .get("financeExpenseConfirmation").todo()).isZero();
        assertThat(expenseService.list(active, 1, 1, null, null).getTotal()).isZero();
        assertThat(expenseService.facets(active).get("billNo")).isEmpty();
        assertThat(statusCounts.counts("financeExpense", null, null).get("PENDING_GL_CONFIRMATION"))
                .isZero();
        assertThatThrownBy(() -> expenseFilter("ALL", null)).isInstanceOf(ApiException.class);
    }

    private com.uten.imp.features.finance.expense.dto.FinanceExpenseQueryFilter expenseFilter(String view, Short status) {
        return new com.uten.imp.features.finance.expense.dto.FinanceExpenseQueryFilter(
                null, null, null, status, null, null, null).withView(view);
    }

    private UUID copyExpenseDraft(UUID template, UUID maker) {
        UUID id = UUID.randomUUID();
        String billNo = businessIdentifier("YF", BusinessTime.today());
        jdbc.update("""
                INSERT INTO finance_expenses(id,bill_no,bill_date,account_id,currency_id,exchange_rate,
                    amount_original,amount_local,maker_id,status,gl_status,is_deleted)
                SELECT ?,?,bill_date,account_id,currency_id,exchange_rate,amount_original,amount_local,?,0,0,false
                FROM finance_expenses WHERE id=?
                """, id, billNo, maker, template);
        jdbc.update("""
                INSERT INTO finance_expense_items(id,expense_id,bill_no,bill_date,expense_style_id,
                    amount_original,amount_local,line_no,is_deleted)
                SELECT ?,?,?,bill_date,expense_style_id,amount_original,amount_local,line_no,false
                FROM finance_expense_items WHERE expense_id=?
                """, UUID.randomUUID(), id, billNo, template);
        return id;
    }

    private String expenseNo(UUID id) {
        return jdbc.queryForObject("SELECT bill_no FROM finance_expenses WHERE id=?", String.class, id);
    }

    private static void loginActor(Actor actor, Set<String> permissions) {
        AuthUser user = new AuthUser(actor.userId(), actor.employeeId(), actor.loginAccount(), permissions,
                false, true, false);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
    }

    @Test
    void deleteWinsAndWaitingApprovalsObserveTheSoftDeleteAcrossAllDocuments() throws Exception {
        List<DraftDocument> documents = seedDrafts();
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
        List<DraftDocument> documents = seedDrafts();
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
        DraftDocument expense = seedDrafts().stream()
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
                "confirmed-expense-generator", () -> glPostingService.generate(
                        BusinessTime.today().format(
                                java.time.format.DateTimeFormatter.ofPattern("yyyy-MM")))))
                .isInstanceOf(ApiException.class)
                .satisfies(failure -> assertThat(((ApiException) failure).getCode())
                        .isEqualTo(ErrorCode.CONFLICT))
                .hasMessageContaining("已财务确认")
                .hasMessageContaining("不能直接删除");

        Map<String, Object> expenseAfter = jdbc.queryForMap("""
                SELECT status, gl_status, gl_voucher_id
                FROM finance_expenses
                WHERE id=?
                """, expense.id());
        assertThat(expenseAfter).isEqualTo(expenseBefore);
        assertThat(voucherState(voucherId)).isEqualTo(voucherBefore);
        assertThat(entryState(voucherId)).containsExactlyElementsOf(entriesBefore);
    }

    @Test
    void receiptGlAndAccountFlowsFinalizeThenReverseWithoutMutableBypasses() throws Exception {
        DraftDocument receipt=seedDrafts().stream()
                .filter(document->document.label().equals("receipt"))
                .findFirst().orElseThrow();
        callAsSuperAdmin("receipt-integrity-approver",receipt.approve());

        assertThat(jdbc.queryForObject("""
                SELECT is_consistent FROM v_receipt_gl_integrity WHERE receipt_id=?
                """,Boolean.class,receipt.id())).isTrue();
        assertThat(jdbc.queryForObject("""
                SELECT is_consistent FROM v_receipt_flow_integrity WHERE receipt_id=?
                """,Boolean.class,receipt.id())).isTrue();
        UUID voucherId=jdbc.queryForObject("""
                SELECT id FROM gl_vouchers
                WHERE source='AUTO' AND source_type='RECEIPT'
                  AND source_doc_id=? AND status=1 AND is_deleted=FALSE
                """,UUID.class,receipt.id());
        UUID styleId=jdbc.queryForObject("""
                SELECT style_id FROM gl_entries WHERE voucher_id=? ORDER BY line_no LIMIT 1
                """,UUID.class,voucherId);

        assertThatThrownBy(()->jdbc.update("""
                INSERT INTO gl_entries(
                  voucher_id,line_no,style_id,direction,amount,entry_date,period,
                  source_doc_type,source_doc_id,source_bill_no,summary)
                SELECT ?,9999,?,1,1,voucher_date,period,
                       'RECEIPT',source_doc_id,voucher_no,'非法追加'
                FROM gl_vouchers WHERE id=?
                """,voucherId,styleId,voucherId))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThatThrownBy(()->jdbc.update(
                "UPDATE finance_receipts SET is_deleted=TRUE,deleted_at=now() WHERE id=?",
                receipt.id()))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);

        UUID ordinaryVoucher=UUID.randomUUID();
        UUID ordinaryEntry=UUID.randomUUID();
        String period=BusinessTime.today().toString().substring(0,7);
        jdbc.update("""
                INSERT INTO gl_vouchers(
                  id,voucher_no,period,voucher_date,source,source_type,remark)
                VALUES (?,?,?,?,'MANUAL','MANUAL','不可变绕过测试')
                """,ordinaryVoucher,"MANUAL-"+ordinaryVoucher,period,BusinessTime.today());
        jdbc.update("""
                INSERT INTO gl_entries(
                  id,voucher_id,line_no,style_id,direction,amount,entry_date,period,summary)
                VALUES (?,?,1,?,1,1,?,?,'普通分录')
                """,ordinaryEntry,ordinaryVoucher,styleId,BusinessTime.today(),period);
        // 对方分录让这张手工凭证借贷平衡: CI 全量共用一个库, 单边凭证会让全局"凭证借贷必平"不变量失败。
        jdbc.update("""
                INSERT INTO gl_entries(
                  id,voucher_id,line_no,style_id,direction,amount,entry_date,period,summary)
                VALUES (?,?,2,?,-1,1,?,?,'普通分录对方')
                """,UUID.randomUUID(),ordinaryVoucher,styleId,BusinessTime.today(),period);
        assertThatThrownBy(()->jdbc.update("""
                UPDATE gl_vouchers
                SET source='AUTO',source_type='RECEIPT',source_doc_id=? WHERE id=?
                """,receipt.id(),ordinaryVoucher))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThatThrownBy(()->jdbc.update(
                "UPDATE gl_entries SET voucher_id=? WHERE id=?",voucherId,ordinaryEntry))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        jdbc.update("DELETE FROM gl_vouchers WHERE id=?",ordinaryVoucher);

        callAsSuperAdmin("receipt-integrity-reverser",()->receiptService.reverse(receipt.id()));

        assertThat(jdbc.queryForObject(
                "SELECT status FROM finance_receipts WHERE id=?",Integer.class,receipt.id()))
                .isEqualTo(-1);
        assertThat(jdbc.queryForObject("""
                SELECT is_consistent FROM v_receipt_gl_integrity WHERE receipt_id=?
                """,Boolean.class,receipt.id())).isTrue();
        assertThat(jdbc.queryForObject("""
                SELECT is_consistent FROM v_receipt_flow_integrity WHERE receipt_id=?
                """,Boolean.class,receipt.id())).isTrue();
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM gl_vouchers
                WHERE source_doc_id=? AND source_type IN('RECEIPT','RECEIPT_REV')
                  AND status=1 AND is_deleted=FALSE
                """,Long.class,receipt.id())).isEqualTo(2L);
    }

    @Test
    void multiCurrencyReceiptPostsNetAndReverses() throws Exception {
        DraftDocument seededReceipt=seedDrafts().stream()
                .filter(document->document.label().equals("receipt"))
                .findFirst().orElseThrow();
        Map<String,Object> seed=jdbc.queryForMap("""
                SELECT client_id,account_id,account_currency_id
                FROM finance_receipts WHERE id=?
                """,seededReceipt.id());
        UUID clientId=(UUID)seed.get("client_id");
        UUID accountId=(UUID)seed.get("account_id");
        UUID baseCurrencyId=(UUID)seed.get("account_currency_id");
        String suffix=UUID.randomUUID().toString();
        UUID usdId=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO currencies(id,code,name,exchange_rate,status,is_base_currency)
                VALUES (?,?,'美元测试',7.200000,'使用',FALSE)
                """,usdId,"USD-"+suffix);
        UUID feeStyle=seedLeafStyle("EXPENSE",suffix+"-TRADE-FEE");

        var request=new com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest();
        request.setReceiptKind("CUSTOMER_PREPAYMENT");
        request.setBillDate(BusinessTime.today());
        request.setClientId(clientId);
        request.setAccountId(accountId);
        request.setCurrencyId(usdId);
        request.setExchangeRate(new BigDecimal("7.200000"));
        request.setAmountOriginal(new BigDecimal("1000.0000"));
        request.setSettlementChannel("DIRECT_ACCOUNT");
        request.setExchangeRateSource("BANK_STATEMENT");
        request.setExchangeRateEffectiveAt(BusinessTime.startOfDay(BusinessTime.today()).plusHours(9));
        request.setBankBookedAt(BusinessTime.startOfDay(BusinessTime.today()).plusHours(10));
        request.setBankReference("BANK-FX-"+suffix);
        request.setAccountCurrencyId(baseCurrencyId);
        request.setAccountAmount(new BigDecimal("7128.0000"));
        request.setBankFeeAccountAmount(BigDecimal.ZERO);
        request.setOtherFeeAccountAmount(new BigDecimal("72.0000"));
        request.setOtherFeeStyleId(feeStyle);
        request.setFeeSettlementMode("DEDUCTED_FROM_PROCEEDS");
        request.setFeeBearer("COMPANY");
        request.setCreateIdempotencyKey("receipt-fx-"+suffix);
        request.setItems(List.of());
        var draft=(com.uten.imp.features.finance.receipt.dto.FinanceReceiptDetail)
                callAsSuperAdmin("receipt-fx-maker",()->receiptService.create(request));
        callAsSuperAdmin("receipt-fx-approver",()->receiptService.approve(draft.getId()));

        Map<String,Object> receipt=jdbc.queryForMap("""
                SELECT amount_original,amount_local,account_amount,account_amount_local,
                       other_fee,fee_bearer
                FROM finance_receipts WHERE id=?
                """,draft.getId());
        assertThat((BigDecimal)receipt.get("amount_original")).isEqualByComparingTo("1000");
        assertThat((BigDecimal)receipt.get("amount_local")).isEqualByComparingTo("7200");
        assertThat((BigDecimal)receipt.get("account_amount")).isEqualByComparingTo("7128");
        assertThat((BigDecimal)receipt.get("account_amount_local")).isEqualByComparingTo("7128");
        assertThat((BigDecimal)receipt.get("other_fee")).isEqualByComparingTo("72");
        assertThat(receipt.get("fee_bearer")).isEqualTo("COMPANY");
        assertThat(jdbc.queryForObject("""
                SELECT is_consistent FROM v_receipt_flow_integrity WHERE receipt_id=?
                """,Boolean.class,draft.getId())).isTrue();
        assertThat(jdbc.queryForObject("""
                SELECT is_consistent FROM v_receipt_gl_integrity WHERE receipt_id=?
                """,Boolean.class,draft.getId())).isTrue();

        callAsSuperAdmin("receipt-fx-reverser",()->receiptService.reverse(draft.getId()));
        assertThat(jdbc.queryForObject("""
                SELECT is_consistent FROM v_receipt_flow_integrity WHERE receipt_id=?
                """,Boolean.class,draft.getId())).isTrue();
        assertThat(jdbc.queryForObject("""
                SELECT is_consistent FROM v_receipt_gl_integrity WHERE receipt_id=?
                """,Boolean.class,draft.getId())).isTrue();
    }

    @Test
    void localOnlyExpenseAndIncomeRejectAnActiveForeignCurrencyAccount() throws Exception {
        List<DraftDocument> documents = seedDrafts();
        String suffix = UUID.randomUUID().toString();
        UUID foreignCurrencyId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO currencies(id,code,name,exchange_rate,status,is_base_currency)
                VALUES (?,?,'外币测试',7.000000,'使用',FALSE)
                """, foreignCurrencyId, "FX-" + suffix);
        UUID foreignAccountId = seedAccount(foreignCurrencyId, suffix + "-FOREIGN");

        for (DraftDocument document : documents.stream()
                .filter(item -> item.label().equals("expense")
                        || item.label().equals("income"))
                .toList()) {
            jdbc.update("UPDATE " + document.table()
                            + " SET account_id=?,currency_id=? WHERE id=?",
                    foreignAccountId, foreignCurrencyId, document.id());

            assertThatThrownBy(() -> callAsSuperAdmin(
                    document.label() + "-foreign-account-approver",
                    document.approve()))
                    .isInstanceOf(ApiException.class)
                    .hasMessageContaining("本位币账户");
            assertThat(((Number) documentState(document).get("status")).intValue()).isZero();
            assertThat(reconciliationCount(document)).isZero();
        }
    }

    @Test
    void localOnlyExpenseAndIncomeRejectHeaderCurrencyOrRateContradictingTheBaseAccount()
            throws Exception {
        List<DraftDocument> documents = seedDrafts().stream()
                .filter(item -> item.label().equals("expense")
                        || item.label().equals("income"))
                .toList();
        String suffix = UUID.randomUUID().toString();
        UUID foreignCurrencyId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO currencies(id,code,name,exchange_rate,status,is_base_currency)
                VALUES (?,?,'单头外币测试',7.000000,'使用',FALSE)
                """, foreignCurrencyId, "HDR-FX-" + suffix);

        for (DraftDocument document : documents) {
            UUID accountCurrencyId = jdbc.queryForObject(
                    "SELECT account.currency_id FROM " + document.table()
                            + " doc JOIN accounts account ON account.id=doc.account_id WHERE doc.id=?",
                    UUID.class, document.id());
            jdbc.update("UPDATE " + document.table()
                            + " SET currency_id=?,exchange_rate=1 WHERE id=?",
                    foreignCurrencyId, document.id());

            assertThatThrownBy(() -> callAsSuperAdmin(
                    document.label() + "-header-currency-approver", document.approve()))
                    .isInstanceOf(ApiException.class)
                    .hasMessageContaining("单头币种必须等于真实")
                    .hasMessageContaining("汇率必须为 1");

            jdbc.update("UPDATE " + document.table()
                            + " SET currency_id=?,exchange_rate=2 WHERE id=?",
                    accountCurrencyId, document.id());
            assertThatThrownBy(() -> callAsSuperAdmin(
                    document.label() + "-header-rate-approver", document.approve()))
                    .isInstanceOf(ApiException.class)
                    .hasMessageContaining("汇率必须为 1");
            assertThat(((Number) documentState(document).get("status")).intValue()).isZero();
            assertThat(reconciliationCount(document)).isZero();
        }
    }

    private List<DraftDocument> seedDrafts() throws Exception {
        String suffix = UUID.randomUUID().toString();
        seedCoreStyle("102", "银行存款", "ACCOUNT", "/102/");
        UUID currencyId = jdbc.queryForObject("""
                SELECT id FROM currencies
                WHERE is_base_currency AND status='使用'
                  AND COALESCE(is_deleted,FALSE)=FALSE
                """, UUID.class);
        UUID clientId = UUID.randomUUID();
        UUID makerId = seedCurrentActor("concurrency-direct-maker").employeeId();
        jdbc.update("""
                INSERT INTO clients (id, code, name, status, code_sequence)
                VALUES (?, ?, '财务并发测试客户', '使用',
                        (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM clients))
                """, clientId, "CLI-" + suffix);

        UUID receiptAccount = seedAccount(currencyId, suffix + "-RECEIPT");
        UUID incomeAccount = seedAccount(currencyId, suffix + "-INCOME");
        UUID expenseAccount = seedAccount(currencyId, suffix + "-EXPENSE");
        UUID transferOutAccount = seedAccount(currencyId, suffix + "-TRANSFER-OUT");
        UUID transferInAccount = seedAccount(currencyId, suffix + "-TRANSFER-IN");
        UUID incomeStyle = seedLeafStyle("INCOME", suffix + "-INCOME-STYLE");
        UUID expenseStyle = seedLeafStyle("EXPENSE", suffix + "-EXPENSE-STYLE");

        // 当期日期：审核/财务确认会触碰 GL 自动投影的跨期间红冲守卫，
        // 固定未来日期会被「跨会计期间红冲」拒绝。
        LocalDate billDate = BusinessTime.today();
        // V379 起无核销明细的收款是客户预收且必须走服务创建（AR_SETTLEMENT 必须带行，
        // 预收立账的金额/元数据由服务端权威写入），不再用裸 SQL 伪造表头。
        com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest receiptReq =
                new com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest();
        receiptReq.setReceiptKind("CUSTOMER_PREPAYMENT");
        receiptReq.setBillDate(billDate);
        receiptReq.setClientId(clientId);
        receiptReq.setAccountId(receiptAccount);
        receiptReq.setCurrencyId(currencyId);
        receiptReq.setExchangeRate(BigDecimal.ONE);
        receiptReq.setAmountOriginal(new BigDecimal("10"));
        // V2 records the actual same-currency bank credit, independently of the quote.
        receiptReq.setAccountAmount(new BigDecimal("10"));
        receiptReq.setBankFeeAccountAmount(BigDecimal.ZERO);
        receiptReq.setOtherFeeAccountAmount(BigDecimal.ZERO);
        receiptReq.setFeeSettlementMode("NONE");
        receiptReq.setFeeBearer("NONE");
        receiptReq.setSettlementChannel("DIRECT_ACCOUNT");
        receiptReq.setExchangeRateSource("BANK_STATEMENT");
        receiptReq.setExchangeRateEffectiveAt(
                BusinessTime.startOfDay(billDate).plusHours(9));
        receiptReq.setBankBookedAt(
                BusinessTime.startOfDay(billDate).plusHours(10));
        receiptReq.setBankReference("BANK-CONCURRENCY-" + suffix);
        receiptReq.setAccountCurrencyId(currencyId);
        receiptReq.setCreateIdempotencyKey("receipt-concurrency-" + suffix);
        receiptReq.setItems(List.of());
        var receiptDetail = (com.uten.imp.features.finance.receipt.dto.FinanceReceiptDetail)
                callAsSuperAdmin("concurrency-receipt-seeder",
                        () -> receiptService.create(receiptReq));
        UUID receiptId = receiptDetail.getId();

        UUID incomeId = UUID.randomUUID();
        String incomeNo = businessIdentifier("QS", billDate);
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
        String transferNo = businessIdentifier("YC", billDate);
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
        String expenseNo = businessIdentifier("YF", billDate);
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
        UUID accountStyleId = jdbc.queryForObject("""
                SELECT id FROM payment_styles
                WHERE path='/102/' AND category='ACCOUNT'
                  AND status='使用' AND COALESCE(is_deleted,false)=false
                """, UUID.class);
        jdbc.update("""
                INSERT INTO accounts (
                    id, code, name, account_type, currency_id,
                    init_balance, receipts_total, payments_total, balance_current,
                    status, style_id)
                VALUES (?, ?, ?, 'BANK', ?, 100.0000, 0, 0, 100.0000, '使用', ?)
                """, id, "ACC-" + suffix, "并发财务账户-" + suffix,
                currencyId, accountStyleId);
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

    private Object callAsSuperAdmin(String login, Callable<?> action) throws Exception {
        Actor actor = seedCurrentActor(login);
        loginAsSuperAdmin(actor.userId(), actor.employeeId(), actor.loginAccount());
        try {
            return action.call();
        } finally {
            SecurityContextHolder.clearContext();
        }
    }

    private Actor seedCurrentActor(String label) {
        int sequence = ACTOR_SEQUENCE.incrementAndGet();
        UUID employeeId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        UUID departmentId = jdbc.queryForObject(
                "SELECT id FROM departments WHERE code='DEPT_FIN'", UUID.class);
        String login = label + "-" + sequence + "-" + userId;
        jdbc.update("""
                INSERT INTO employees(
                    id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES (?,?,?,'其他',?,DATE '2026-01-01','active','regular')
                """, employeeId, "EMP-FIN-" + sequence,
                "财务并发测试员工-" + sequence, departmentId);
        jdbc.update("""
                INSERT INTO users(
                    id,employee_id,login_account,password_hash,
                    must_change_password,is_super_admin,status)
                VALUES (?,?,?,'argon2-test-not-used',false,false,'active')
                """, userId, employeeId, login);
        return new Actor(userId, employeeId, login);
    }

    private static void loginAsSuperAdmin(UUID userId, UUID employeeId, String loginAccount) {
        // hasAuthority 不看 superAdmin 标志：收款/付款/其他收入/银行存取/费用五族
        // 全按钮 + GL finance_post:execute。
        AuthUser user = new AuthUser(
                userId, employeeId, loginAccount,
                Set.of("finance_post:execute", "finance:view:all",
                        "customer_prepayment:view",
                        "finance_payment:create", "finance_payment:edit",
                        "finance_payment:delete", "finance_payment:approve",
                        "finance_payment:reverse",
                        "finance_receipt:create", "finance_receipt:edit",
                        "finance_receipt:delete", "finance_receipt:approve",
                        "finance_receipt:reverse",
                        "finance_other_income:create", "finance_other_income:edit",
                        "finance_other_income:delete", "finance_other_income:approve",
                        "finance_other_income:reverse",
                        "finance_bank_transfer:create", "finance_bank_transfer:edit",
                        "finance_bank_transfer:delete", "finance_bank_transfer:approve",
                        "finance_bank_transfer:reverse",
                        "finance_expense:create", "finance_expense:edit",
                        "finance_expense:delete", "finance_expense:approve",
                        "finance_expense:reverse", "finance_expense:gl_confirm"), false, true, true);
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

    private static String businessIdentifier(String prefix, LocalDate date) {
        int sequence = BUSINESS_IDENTIFIER_SEQUENCE.incrementAndGet();
        if (sequence > 999_999) {
            throw new IllegalStateException("test business identifier sequence exhausted");
        }
        return prefix + date.toString().replace("-", "") + "%06d".formatted(sequence);
    }

    private record Actor(UUID userId, UUID employeeId, String loginAccount) {
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
