package com.uten.imp.features.finance.accountflow;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.accountbalance.AccountBalanceAdjustmentService;
import com.uten.imp.features.finance.accountbalance.dto.AccountBalanceAdjustmentBatchRequest;
import com.uten.imp.features.finance.accountbalance.dto.AccountBalanceAdjustmentItemRequest;
import com.uten.imp.features.finance.bank_transfer.FinanceBankTransferService;
import com.uten.imp.features.finance.expense.FinanceExpenseService;
import com.uten.imp.features.finance.other_income.FinanceOtherIncomeService;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.payment.dto.FinancePaymentLineInput;
import com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest;
import com.uten.imp.features.finance.receipt.FinanceReceiptService;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * dup-backend-split-04 真库验收(ADR-112): 资金账户过账只经 {@link AccountFlowLedgerService} 一个入口。
 * 费用、其它收入、银行存取款(一出两入)、付款、收款(无费用 / 另付手续费)审核后再红冲, 涉及的每个账户
 * balance_current、receipts_total、payments_total 都回到审核前; 正向与反向流水一一成对,
 * 反向流水收支对调、amount_local 等于原流水。余额校准每个变动账户一笔流水, 校准回原值后余额复原。
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
                "uten.jwt.secret=account-posting-harness-jwt-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=account-posting-harness-pgp-key-test-only-0123456789",
                "uten.crypto.hmac-key=account-posting-harness-hmac-key-test-only",
                "uten.bootstrap.admin-login=account-posting-bootstrap-admin-test",
                "uten.bootstrap.admin-password=AccountPostingHarnessAdminPass-1!"
        })
class AccountPostingReversalPostgresTest {

    private static final AtomicInteger SEQUENCE = new AtomicInteger();

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
    @Autowired private PlatformTransactionManager transactionManager;
    @Autowired private FinanceExpenseService expenses;
    @Autowired private FinanceOtherIncomeService incomes;
    @Autowired private FinanceBankTransferService transfers;
    @Autowired private FinancePaymentService payments;
    @Autowired private FinanceReceiptService receipts;
    @Autowired private AccountBalanceAdjustmentService adjustments;

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    /** 一类资金单据: 涉及的账户、流水来源类型、单据主键, 以及审核与红冲动作。 */
    private record Scenario(List<UUID> accounts, List<String> sourceTypes, UUID documentId,
                            Runnable approve, Runnable reverse) {
    }

    @ParameterizedTest(name = "{0}")
    @ValueSource(strings = {"EXPENSE", "OTHER_INCOME", "BANK_TRANSFER", "PAYMENT",
            "RECEIPT", "RECEIPT_FEE_PAID_SEPARATELY"})
    void approvingThenReversingRestoresEveryAccountAndPairsEveryFlow(String kind) {
        seedCoreStyles();
        login("posting-maker-" + kind);
        Scenario scenario = switch (kind) {
            case "EXPENSE" -> expense();
            case "OTHER_INCOME" -> otherIncome();
            case "BANK_TRANSFER" -> bankTransfer();
            case "PAYMENT" -> payment();
            case "RECEIPT" -> receipt(false);
            case "RECEIPT_FEE_PAID_SEPARATELY" -> receipt(true);
            default -> throw new IllegalArgumentException(kind);
        };
        Map<UUID, List<BigDecimal>> before = balances(scenario.accounts());

        login("posting-approver-" + kind);
        scenario.approve().run();
        Map<UUID, List<BigDecimal>> approved = balances(scenario.accounts());
        assertThat(approved).as("审核后每个涉及账户都有变动").allSatisfy((account, values) ->
                assertThat(values.getFirst()).isNotEqualByComparingTo(before.get(account).getFirst()));
        assertThat(flowCount(scenario, "POSTING")).isEqualTo(scenario.accounts().size());

        scenario.reverse().run();
        Map<UUID, List<BigDecimal>> reversed = balances(scenario.accounts());
        for (UUID account : scenario.accounts()) {
            List<BigDecimal> expected = before.get(account);
            List<BigDecimal> actual = reversed.get(account);
            for (int column = 0; column < expected.size(); column++) {
                assertThat(actual.get(column)).as("%s 账户 %s 第 %d 列红冲后复原", kind, account, column)
                        .isEqualByComparingTo(expected.get(column));
            }
        }
        assertThat(flowCount(scenario, "REVERSAL")).as("反向流水与正向一一对应")
                .isEqualTo(flowCount(scenario, "POSTING"));
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM finance_reconciliations reversal
                JOIN finance_reconciliations posting ON posting.id = reversal.reversal_of_id
                WHERE reversal.source_doc_type = ANY(?) AND reversal.source_doc_id = ?
                  AND reversal.entry_kind = 'REVERSAL' AND posting.entry_kind = 'POSTING'
                  AND reversal.account_id = posting.account_id
                  AND reversal.in_amount = posting.out_amount
                  AND reversal.out_amount = posting.in_amount
                  AND reversal.amount_local IS NOT DISTINCT FROM posting.amount_local
                """, Long.class, sourceTypes(scenario), scenario.documentId()))
                .as("反向流水收支对调、本币金额等于原流水").isEqualTo((long) scenario.accounts().size());
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM v_account_balance_integrity
                WHERE account_id = ANY(?) AND balance_difference <> 0
                """, Long.class, (Object) scenario.accounts().toArray(UUID[]::new)))
                .as("账户余额与流水合计一致").isZero();
    }

    @Test
    void balanceAdjustmentWritesOneFlowPerChangedAccountAndAdjustingBackRestoresTheBalance() {
        seedCoreStyles();
        UUID currency = baseCurrency();
        UUID first = account(currency, "ADJ-A", "1000");
        UUID second = account(currency, "ADJ-B", "1000");
        login("posting-adjuster");
        Map<UUID, List<BigDecimal>> before = balances(List.of(first, second));

        adjustments.adjust(new AccountBalanceAdjustmentBatchRequest("SELECTED", BusinessTime.today(),
                "银行对账校准", "adjust-up-" + first, List.of(
                new AccountBalanceAdjustmentItemRequest(first, new BigDecimal("1000"), new BigDecimal("1012.5"), null),
                new AccountBalanceAdjustmentItemRequest(second, new BigDecimal("1000"), new BigDecimal("1000"), null))));
        assertThat(balances(List.of(first)).get(first).getFirst()).isEqualByComparingTo("1012.5");
        assertThat(balances(List.of(second)).get(second).getFirst()).as("没变动的账户不写流水").isEqualByComparingTo("1000");
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM finance_reconciliations
                WHERE source_doc_type = 'BALANCE_ADJUSTMENT' AND account_id = ANY(?)
                """, Long.class, (Object) new UUID[]{first, second})).isEqualTo(1L);

        adjustments.adjust(new AccountBalanceAdjustmentBatchRequest("SELECTED", BusinessTime.today(),
                "校准回原值", "adjust-back-" + first, List.of(
                new AccountBalanceAdjustmentItemRequest(first, new BigDecimal("1012.5"), new BigDecimal("1000"), null))));
        assertThat(balances(List.of(first)).get(first).getFirst())
                .isEqualByComparingTo(before.get(first).getFirst());
        assertThat(jdbc.queryForObject("""
                SELECT SUM(in_amount - out_amount) FROM finance_reconciliations
                WHERE source_doc_type = 'BALANCE_ADJUSTMENT' AND account_id = ?
                """, BigDecimal.class, first)).isEqualByComparingTo("0");
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM v_account_balance_integrity
                WHERE account_id = ANY(?) AND balance_difference <> 0
                """, Long.class, (Object) new UUID[]{first, second})).isZero();
    }

    // ------------------------------------------------------------------ scenarios

    private Scenario expense() {
        UUID currency = baseCurrency();
        UUID account = account(currency, "EXP", "1000");
        UUID style = leafStyle("EXPENSE", "EXP");
        UUID id = UUID.randomUUID();
        LocalDate billDate = BusinessTime.today();
        String billNo = identifier("YF", billDate);
        jdbc.update("""
                INSERT INTO finance_expenses (
                    id, bill_no, bill_date, account_id, currency_id, exchange_rate,
                    amount_original, amount_local, maker_id, status, gl_status, is_deleted)
                VALUES (?, ?, ?, ?, ?, 1.000000, 12.3456, 12.3456, ?, 0, 0, false)
                """, id, billNo, billDate, account, currency, currentEmployee());
        jdbc.update("""
                INSERT INTO finance_expense_items (
                    id, expense_id, bill_no, bill_date, expense_style_id,
                    amount_original, amount_local, line_no, is_deleted)
                VALUES (?, ?, ?, ?, ?, 12.3456, 12.3456, 1, false)
                """, UUID.randomUUID(), id, billNo, billDate, style);
        return new Scenario(List.of(account), List.of("EXPENSE"), id,
                () -> expenses.approve(id), () -> expenses.reverse(id));
    }

    private Scenario otherIncome() {
        UUID currency = baseCurrency();
        UUID account = account(currency, "INC", "1000");
        UUID style = leafStyle("INCOME", "INC");
        UUID id = UUID.randomUUID();
        LocalDate billDate = BusinessTime.today();
        String billNo = identifier("QS", billDate);
        jdbc.update("""
                INSERT INTO finance_other_incomes (
                    id, bill_no, bill_date, account_id, currency_id, exchange_rate,
                    amount_original, amount_local, maker_id, status, is_deleted)
                VALUES (?, ?, ?, ?, ?, 1.000000, 7.0001, 7.0001, ?, 0, false)
                """, id, billNo, billDate, account, currency, currentEmployee());
        jdbc.update("""
                INSERT INTO finance_other_income_items (
                    id, income_id, bill_no, bill_date, income_style_id,
                    amount_original, amount_local, line_no, is_deleted)
                VALUES (?, ?, ?, ?, ?, 7.0001, 7.0001, 1, false)
                """, UUID.randomUUID(), id, billNo, billDate, style);
        return new Scenario(List.of(account), List.of("INCOME"), id,
                () -> incomes.approve(id), () -> incomes.reverse(id));
    }

    private Scenario bankTransfer() {
        UUID currency = baseCurrency();
        UUID out = account(currency, "OUT", "1000");
        UUID firstIn = account(currency, "IN1", "1000");
        UUID secondIn = account(currency, "IN2", "1000");
        UUID id = UUID.randomUUID();
        LocalDate billDate = BusinessTime.today();
        String billNo = identifier("YC", billDate);
        jdbc.update("""
                INSERT INTO finance_bank_transfers (
                    id, bill_no, bill_date, out_account_id, currency_id, exchange_rate,
                    amount_original, amount_local, maker_id, status, is_deleted)
                VALUES (?, ?, ?, ?, ?, 1.000000, 30.0000, 30.0000, ?, 0, false)
                """, id, billNo, billDate, out, currency, currentEmployee());
        jdbc.update("""
                INSERT INTO finance_bank_transfer_lines (
                    id, transfer_id, bill_no, bill_date, in_account_id,
                    amount_original, amount_local, line_no, is_deleted)
                VALUES (?, ?, ?, ?, ?, 10.0000, 10.0000, 1, false),
                       (?, ?, ?, ?, ?, 20.0000, 20.0000, 2, false)
                """, UUID.randomUUID(), id, billNo, billDate, firstIn,
                UUID.randomUUID(), id, billNo, billDate, secondIn);
        return new Scenario(List.of(out, firstIn, secondIn), List.of("BANK_TRANSFER"), id,
                () -> transfers.approve(id), () -> transfers.reverse(id));
    }

    private Scenario payment() {
        UUID currency = UUID.randomUUID();
        UUID supplier = UUID.randomUUID();
        UUID ledger = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO currencies (id, code, name, exchange_rate, status)
                VALUES (?, ?, '美元', 7.000000, '使用')
                """, currency, "USD-POST-" + currency);
        UUID account = account(currency, "PAY", "1000");
        jdbc.update("""
                INSERT INTO suppliers (id, code, name, status, code_sequence)
                VALUES (?, ?, '资金过账验收供应商', '使用',
                        (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM suppliers))
                """, supplier, "SUP-POST-" + supplier);
        seedPayable(currency, supplier, ledger);
        FinancePaymentLineInput line = new FinancePaymentLineInput();
        line.setAppliedLedgerId(ledger);
        line.setSupplierId(supplier);
        line.setAmountOriginal(new BigDecimal("30.0000"));
        FinancePaymentSaveRequest request = new FinancePaymentSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setSupplierId(supplier);
        request.setAccountId(account);
        request.setAccountCurrencyId(currency);
        request.setAccountAmount(new BigDecimal("30.0000"));
        request.setBankFeeAccountAmount(BigDecimal.ZERO);
        request.setBankReference("POSTING-PAY-" + ledger);
        request.setBankBookedAt(java.time.OffsetDateTime.now());
        request.setCurrencyId(currency);
        request.setExchangeRate(new BigDecimal("7.200000"));
        request.setAmountOriginal(new BigDecimal("30.0000"));
        request.setCreateIdempotencyKey(UUID.randomUUID().toString());
        request.setItems(List.of(line));
        UUID id = payments.create(request).getId();
        return new Scenario(List.of(account), List.of("PAYMENT"), id,
                () -> payments.approve(id), () -> payments.reverse(id));
    }

    private Scenario receipt(boolean feePaidSeparately) {
        UUID currency = baseCurrency();
        UUID receiving = account(currency, "RCV", "1000");
        UUID feeAccount = feePaidSeparately ? account(currency, "FEE", "1000") : null;
        UUID client = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO clients (id, code, name, status, code_sequence)
                VALUES (?, ?, '资金过账验收客户', '使用',
                        (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM clients))
                """, client, "CLI-POST-" + client);
        LocalDate billDate = BusinessTime.today();
        FinanceReceiptSaveRequest request = new FinanceReceiptSaveRequest();
        request.setReceiptKind("CUSTOMER_PREPAYMENT");
        request.setBillDate(billDate);
        request.setClientId(client);
        request.setAccountId(receiving);
        request.setCurrencyId(currency);
        request.setExchangeRate(BigDecimal.ONE);
        request.setAmountOriginal(new BigDecimal("50"));
        request.setAccountAmount(new BigDecimal("50"));
        request.setBankFeeAccountAmount(feePaidSeparately ? new BigDecimal("1.25") : BigDecimal.ZERO);
        request.setOtherFeeAccountAmount(BigDecimal.ZERO);
        request.setFeeSettlementMode(feePaidSeparately ? "PAID_SEPARATELY" : "NONE");
        request.setFeeBearer(feePaidSeparately ? "COMPANY" : "NONE");
        request.setFeePaymentAccountId(feeAccount);
        request.setSettlementChannel("DIRECT_ACCOUNT");
        request.setExchangeRateSource("BANK_STATEMENT");
        request.setExchangeRateEffectiveAt(BusinessTime.startOfDay(billDate).plusHours(9));
        request.setBankBookedAt(BusinessTime.startOfDay(billDate).plusHours(10));
        request.setBankReference("POSTING-RCV-" + client);
        request.setAccountCurrencyId(currency);
        request.setCreateIdempotencyKey("posting-receipt-" + client);
        request.setItems(List.of());
        UUID id = receipts.create(request).getId();
        List<UUID> accounts = feePaidSeparately ? List.of(receiving, feeAccount) : List.of(receiving);
        List<String> sources = feePaidSeparately ? List.of("RECEIPT", "RECEIPT_FEE") : List.of("RECEIPT");
        return new Scenario(accounts, sources, id, () -> receipts.approve(id), () -> receipts.reverse(id));
    }

    // ------------------------------------------------------------------ fixtures

    /** 每个账户: 余额、累计收入、累计支出。 */
    private Map<UUID, List<BigDecimal>> balances(List<UUID> accounts) {
        Map<UUID, List<BigDecimal>> result = new LinkedHashMap<>();
        for (UUID account : accounts) {
            Map<String, Object> row = jdbc.queryForMap(
                    "SELECT balance_current, receipts_total, payments_total FROM accounts WHERE id=?", account);
            result.put(account, List.of((BigDecimal) row.get("balance_current"),
                    (BigDecimal) row.get("receipts_total"), (BigDecimal) row.get("payments_total")));
        }
        return result;
    }

    private long flowCount(Scenario scenario, String kind) {
        return jdbc.queryForObject("""
                SELECT count(*) FROM finance_reconciliations
                WHERE source_doc_type = ANY(?) AND source_doc_id = ? AND entry_kind = ?
                """, Long.class, sourceTypes(scenario), scenario.documentId(), kind);
    }

    private static String[] sourceTypes(Scenario scenario) {
        return scenario.sourceTypes().toArray(String[]::new);
    }

    private void seedPayable(UUID currency, UUID supplier, UUID ledger) {
        UUID receiptId = UUID.randomUUID(), receiptItemId = UUID.randomUUID(), unitId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID(), warehouseId = UUID.randomUUID();
        String receiptNo = "CJ20260801%06d".formatted(SEQUENCE.incrementAndGet());
        new TransactionTemplate(transactionManager).executeWithoutResult(transaction -> {
            jdbc.update("INSERT INTO units(id,code,name) VALUES(?,?,'过账验收单位')", unitId, "U-POST-" + unitId);
            jdbc.update("INSERT INTO goods(id,code,name,unit_id,code_sequence) VALUES(?,?,'过账验收物料',?,"
                    + "(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))", goodsId, "G-POST-" + goodsId, unitId);
            jdbc.update("INSERT INTO warehouses(id,code,name) VALUES(?,?,'过账验收仓')", warehouseId, "WH-POST-" + warehouseId);
            jdbc.update("INSERT INTO purchase_receipts(id,bill_no,bill_date,supplier_id,currency_id,exchange_rate,"
                    + "total_original,total_local,warehouse_id,status) VALUES(?,?,DATE '2026-08-01',?,?,7,100,700,?,1)",
                    receiptId, receiptNo, supplier, currency, warehouseId);
            jdbc.update("INSERT INTO purchase_receipt_items(id,bill_no,bill_date,receipt_id,goods_id,unit_id,unit_rate,qty,"
                    + "price,amount_original,amount_local,replacement_intent,goods_snapshot_source) "
                    + "VALUES(?,?,DATE '2026-08-01',?,?,?,1,100,1,100,700,'NORMAL','MASTER_AT_SAVE')",
                    receiptItemId, receiptNo, receiptId, goodsId, unitId);
            jdbc.update("INSERT INTO procurement_receipt_consideration_parts(id,receipt_type,receipt_id,receipt_item_id,"
                    + "billing_mode,base_qty,nominal_original,nominal_local,payable_original,payable_local,created_by) "
                    + "SELECT ?,'PURCHASE',?,?,'STANDARD',100,100,700,100,700,id FROM users "
                    + "WHERE is_super_admin AND status='active' ORDER BY id LIMIT 1",
                    UUID.randomUUID(), receiptId, receiptItemId);
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
                    VALUES (?, 'AP', 'PURCHASE', 'PAYABLE', 'PURCHASE_RECEIPT', ?, ?, ?, DATE '2026-08-01', ?, ?,
                            7.000000, 100.0000, 700.0000, 0, 0, 0, 0, 100.0000, 0, 700.0000, false, 1, false)
                    """, ledger, receiptId, receiptNo, receiptNo, supplier, currency);
        });
    }

    private void seedCoreStyles() {
        coreStyle("123", "库存商品", "ACCOUNT", "/123/");
        coreStyle("203", "应付账款", "LIABILITY", "/203/");
        coreStyle("102", "银行存款", "ACCOUNT", "/102/");
        Long fx = jdbc.queryForObject("""
                SELECT count(*) FROM payment_styles
                WHERE category='EXPENSE' AND name='汇兑损益' AND status='使用' AND COALESCE(is_deleted,false)=false
                """, Long.class);
        if (fx == null || fx == 0) {
            jdbc.update("""
                    INSERT INTO payment_styles (id, code, name, category, status, auto_created)
                    VALUES (?, 'FX-POSTING-TEST', '汇兑损益', 'EXPENSE', '使用', true)
                    """, UUID.randomUUID());
        }
        jdbc.update("""
                UPDATE system_posting_style_roles role SET style_id = source.id
                FROM payment_styles source
                WHERE (role.role_key, source.path) IN (('AP_CONTROL', '/203/'), ('INVENTORY_ASSET', '/123/'))
                  AND source.status='使用' AND COALESCE(source.is_deleted,false)=false
                """);
        jdbc.update("""
                UPDATE system_posting_style_roles role SET style_id = source.id
                FROM payment_styles source
                WHERE role.role_key='FX_GAIN_LOSS' AND source.category='EXPENSE' AND source.name='汇兑损益'
                  AND source.status='使用' AND COALESCE(source.is_deleted,false)=false
                """);
    }

    private void coreStyle(String code, String name, String category, String path) {
        Long count = jdbc.queryForObject("""
                SELECT count(*) FROM payment_styles
                WHERE path=? AND status='使用' AND COALESCE(is_deleted,false)=false
                """, Long.class, path);
        if (count == null || count == 0) {
            jdbc.update("INSERT INTO payment_styles (id, code, name, category, status) VALUES (?, ?, ?, ?, '使用')",
                    UUID.randomUUID(), code, name, category);
        }
    }

    private UUID baseCurrency() {
        return jdbc.queryForObject("""
                SELECT id FROM currencies WHERE is_base_currency AND status='使用' AND COALESCE(is_deleted,FALSE)=FALSE
                """, UUID.class);
    }

    private UUID account(UUID currency, String label, String opening) {
        UUID id = UUID.randomUUID();
        int sequence = SEQUENCE.incrementAndGet();
        jdbc.update("""
                INSERT INTO accounts (id, code, name, account_type, currency_id,
                    init_balance, receipts_total, payments_total, balance_current, status, style_id)
                VALUES (?, ?, ?, 'BANK', ?, ?, 0, 0, ?, '使用',
                        (SELECT id FROM payment_styles WHERE path='/102/' AND category='ACCOUNT'
                           AND status='使用' AND COALESCE(is_deleted,false)=false))
                """, id, "ACC-POST-" + label + "-" + sequence, "过账验收账户-" + label + "-" + sequence,
                currency, new BigDecimal(opening), new BigDecimal(opening));
        return id;
    }

    private UUID leafStyle(String category, String label) {
        UUID id = UUID.randomUUID();
        int sequence = SEQUENCE.incrementAndGet();
        jdbc.update("INSERT INTO payment_styles (id, code, name, category, status) VALUES (?, ?, ?, ?, '使用')",
                id, "STYLE-POST-" + label + "-" + sequence, "过账验收科目-" + label + "-" + sequence, category);
        return id;
    }

    private static String identifier(String prefix, LocalDate date) {
        return prefix + date.toString().replace("-", "") + "%06d".formatted(SEQUENCE.incrementAndGet());
    }

    private UUID currentEmployee() {
        return ((AuthUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal()).getEmployeeId();
    }

    private void login(String label) {
        int sequence = SEQUENCE.incrementAndGet();
        UUID userId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        UUID department = jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_FIN'", UUID.class);
        String login = label + "-" + sequence;
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES (?,?,?,'其他',?,DATE '2026-01-01','active','regular')
                """, employeeId, "EMP-POST-" + sequence, "过账验收员工-" + sequence, department);
        jdbc.update("""
                INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status)
                VALUES (?,?,?,'argon2-test-not-used',false,false,'active')
                """, userId, employeeId, login);
        List<String> permissions = new ArrayList<>(List.of("finance_post:execute", "finance:view:all",
                "customer_prepayment:view", "account:view", "account:balance:view", "account:balance:adjust"));
        for (String document : List.of("finance_payment", "finance_receipt", "finance_other_income",
                "finance_bank_transfer", "finance_expense")) {
            for (String action : List.of("create", "edit", "delete", "approve", "reverse")) {
                permissions.add(document + ":" + action);
            }
        }
        AuthUser user = new AuthUser(userId, employeeId, login, Set.of(), Set.copyOf(permissions), false, true, true);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
    }
}
