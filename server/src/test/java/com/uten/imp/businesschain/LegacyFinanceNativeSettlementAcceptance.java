package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.features.finance.receipt.FinanceReceiptService;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.payment.dto.FinancePaymentLineInput;
import com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest;
import org.springframework.context.ApplicationContext;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.time.YearMonth;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Invoked against the actual database produced by the complete shell import coordinator. */
public final class LegacyFinanceNativeSettlementAcceptance {
    private LegacyFinanceNativeSettlementAcceptance() { }

    public static UUID verify(ApplicationContext context, JdbcTemplate jdbc) {
        UUID client = id(jdbc, "clients", 900501);
        UUID account = id(jdbc, "accounts", 906001);
        UUID ledger = id(jdbc, "ar_ap_ledger", 906003);
        UUID currency = id(jdbc, "currencies", 1);
        assertThat(jdbc.queryForObject("SELECT source_doc_type FROM ar_ap_ledger WHERE id=?", String.class, ledger))
                .isEqualTo("SALES_SHIPMENT");
        assertThat(jdbc.queryForObject("SELECT source_doc_id FROM ar_ap_ledger WHERE id=?", UUID.class, ledger))
                .as("The import must prove the original shipment identity before this acceptance runs").isNotNull();
        assertThat(amount(jdbc, "SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?", ledger))
                .isEqualByComparingTo("12");
        assertThat(amount(jdbc, "SELECT balance_current FROM accounts WHERE id=?", account)).isEqualByComparingTo("8");
        Map<String, List<String>> originalFacts = historicalFacts(jdbc);
        assertThat(originalFacts.get("finance_receipts")).isNotEmpty();

        // Reuse actual request/authentication fixtures without autowiring the HTTP-only test fields.
        FullChainEndToEndTest fixture = new FullChainEndToEndTest();
        ReflectionTestUtils.setField(fixture, "jdbc", jdbc);
        ReflectionTestUtils.setField(fixture, "permissionResolver", context.getBean(PermissionResolver.class));
        UUID department = jdbc.queryForObject("SELECT id FROM departments WHERE NOT is_deleted ORDER BY id LIMIT 1", UUID.class);
        assertThat(department).isNotNull();
        var world = new FullChainEndToEndTest.World(department, null, null,
                null, null, null, null, null, client, null, null, null, currency, null, 0);
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        UUID maker = fixture.createUserWithPerms(world, "legacy-native-maker-" + suffix,
                "finance_receipt:create", "finance_receipt:edit", "finance_receipt:view", "finance:view:all", "finance_post:execute",
                "finance_payment:create", "finance_payment:edit", "finance_payment:view");
        UUID reviewer = fixture.createUserWithPerms(world, "legacy-native-reviewer-" + suffix,
                "finance_receipt:view", "finance_receipt:approve", "finance:view:all", "finance_payment:view", "finance_payment:approve");
        fixture.seedChartOfAccounts();
        FinanceReceiptService receipts = context.getBean(FinanceReceiptService.class);
        try {
            fixture.loginAs(maker);
            FinanceReceiptSaveRequest request = ReflectionTestUtils.invokeMethod(fixture, "receiptRequest",
                    world, ledger, account, null, "3", "3", "0", "0", BigDecimal.ONE, BusinessTime.today());
            assertThat(request).isNotNull();
            UUID receipt = receipts.create(request).getId();
            fixture.loginAs(reviewer);
            receipts.approve(receipt);
            assertThat(jdbc.queryForObject("SELECT legacy_id FROM finance_receipts WHERE id=?", Integer.class, receipt)).isNull();
            assertThat(amount(jdbc, "SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?", ledger)).isEqualByComparingTo("9");
            assertThat(amount(jdbc, "SELECT amount_received_original FROM ar_ap_ledger WHERE id=?", ledger)).isEqualByComparingTo("11");
            assertThat(amount(jdbc, "SELECT balance_current FROM accounts WHERE id=?", account)).isEqualByComparingTo("11");
            assertThat(amount(jdbc, "SELECT balance_before_original FROM finance_receipt_lines WHERE receipt_id=?", receipt)).isEqualByComparingTo("12");
            assertThat(amount(jdbc, "SELECT balance_after_original FROM finance_receipt_lines WHERE receipt_id=?", receipt)).isEqualByComparingTo("9");
            assertThat(amount(jdbc, "SELECT in_amount FROM finance_reconciliations WHERE source_doc_type='RECEIPT' AND source_doc_id=?", receipt))
                    .isEqualByComparingTo("3");
            List<Map<String, Object>> newVoucher = jdbc.queryForList("""
                    SELECT voucher.id,count(entry.id) AS entries,sum(entry.direction*entry.amount) AS balance,
                           sum(entry.amount) FILTER(WHERE entry.direction=1) AS debit
                    FROM gl_vouchers voucher JOIN gl_entries entry ON entry.voucher_id=voucher.id
                    WHERE voucher.source='AUTO' AND voucher.source_type='RECEIPT' AND voucher.source_doc_id=?
                    GROUP BY voucher.id
                    """, receipt);
            assertThat(newVoucher).hasSize(1);
            assertThat(((Number) newVoucher.getFirst().get("entries")).intValue()).isGreaterThanOrEqualTo(2);
            assertThat((BigDecimal) newVoucher.getFirst().get("balance")).isEqualByComparingTo("0");
            assertThat((BigDecimal) newVoucher.getFirst().get("debit")).isEqualByComparingTo("3");
            UUID voucher = (UUID) newVoucher.getFirst().get("id");
            List<String> nativeEntries = jdbc.queryForList("SELECT to_jsonb(entry)::text FROM gl_entries entry WHERE voucher_id=? ORDER BY id", String.class, voucher);
            fixture.loginAs(maker);
            context.getBean(GlPostingService.class).generate(YearMonth.from(BusinessTime.today()).toString());
            assertThat(jdbc.queryForList("SELECT to_jsonb(entry)::text FROM gl_entries entry WHERE voucher_id=? ORDER BY id", String.class, voucher))
                    .as("Native receipt approval owns its immutable entries; generation must retain them").isEqualTo(nativeEntries);
            assertThat(historicalFacts(jdbc)).as("Original imported cash, details, account flows and pre-existing GL stay byte-identical")
                    .isEqualTo(originalFacts);
            verifyNativePayment(context,jdbc,fixture,maker,reviewer,account,currency);
            assertThat(amount(jdbc, "SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?", ledger)).isEqualByComparingTo("9");
            assertThat(jdbc.queryForList("SELECT to_jsonb(entry)::text FROM gl_entries entry WHERE voucher_id=? ORDER BY id", String.class, voucher))
                    .as("Later AP settlement must not alter the receipt's balanced immutable entries").isEqualTo(nativeEntries);
            assertThat(historicalFacts(jdbc)).as("AP service settlement also preserves every original cash/proof/GL fact")
                    .isEqualTo(originalFacts);
            return receipt;
        } finally {
            SecurityContextHolder.clearContext();
        }
    }

    private static UUID id(JdbcTemplate jdbc, String table, int legacyId) {
        return jdbc.queryForObject("SELECT id FROM " + table + " WHERE legacy_id=?", UUID.class, legacyId);
    }

    private static BigDecimal amount(JdbcTemplate jdbc, String sql, UUID id) {
        return jdbc.queryForObject(sql, BigDecimal.class, id);
    }

    private static void verifyNativePayment(ApplicationContext context,JdbcTemplate jdbc,FullChainEndToEndTest fixture,
                                            UUID maker,UUID reviewer,UUID account,UUID currency) {
        UUID supplier=id(jdbc,"suppliers",900601), ledger=id(jdbc,"ar_ap_ledger",906004);
        assertThat(amount(jdbc,"SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",ledger)).isEqualByComparingTo("25");
        assertThat(amount(jdbc,"SELECT balance_current FROM accounts WHERE id=?",account)).isEqualByComparingTo("11");
        FinancePaymentLineInput line=new FinancePaymentLineInput();
        line.setAppliedLedgerId(ledger);line.setSupplierId(supplier);line.setAmountOriginal(new BigDecimal("3"));
        FinancePaymentSaveRequest request=new FinancePaymentSaveRequest();
        request.setBillDate(BusinessTime.today());request.setSupplierId(supplier);request.setAccountId(account);
        request.setCurrencyId(currency);request.setExchangeRate(BigDecimal.ONE);
        request.setAccountCurrencyId(currency);request.setAccountAmount(new BigDecimal("3"));
        request.setBankFeeAccountAmount(BigDecimal.ZERO);request.setBankBookedAt(java.time.OffsetDateTime.now());
        request.setBankReference("LEGACY-NATIVE-PAYMENT-"+UUID.randomUUID());
        request.setCreateIdempotencyKey(UUID.randomUUID().toString());request.setItems(List.of(line));
        FinancePaymentService payments=context.getBean(FinancePaymentService.class);
        fixture.loginAs(maker);
        UUID payment=payments.create(request).getId();
        fixture.loginAs(reviewer);
        payments.approve(payment);
        assertThat(jdbc.queryForObject("SELECT legacy_id FROM finance_payments WHERE id=?",Integer.class,payment)).isNull();
        assertThat(jdbc.queryForObject("SELECT amount_authority_version FROM finance_payments WHERE id=?",Integer.class,payment)).isEqualTo(2);
        assertThat(amount(jdbc,"SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",ledger)).isEqualByComparingTo("22");
        assertThat(amount(jdbc,"SELECT amount_received_original FROM ar_ap_ledger WHERE id=?",ledger)).isEqualByComparingTo("3");
        assertThat(amount(jdbc,"SELECT balance_current FROM accounts WHERE id=?",account)).isEqualByComparingTo("8");
        assertThat(amount(jdbc,"SELECT balance_before_original FROM finance_payment_lines WHERE payment_id=?",payment)).isEqualByComparingTo("25");
        assertThat(amount(jdbc,"SELECT balance_after_original FROM finance_payment_lines WHERE payment_id=?",payment)).isEqualByComparingTo("22");
        assertThat(amount(jdbc,"SELECT out_amount FROM finance_reconciliations WHERE source_doc_type='PAYMENT' AND source_doc_id=?",payment)).isEqualByComparingTo("3");
        UUID voucher=jdbc.queryForObject("SELECT id FROM gl_vouchers WHERE source='AUTO' AND source_type='PAYMENT' AND source_doc_id=?",UUID.class,payment);
        assertThat(amount(jdbc,"SELECT sum(direction*amount) FROM gl_entries WHERE voucher_id=?",voucher)).isEqualByComparingTo("0");
        assertThat(amount(jdbc,"SELECT sum(amount) FROM gl_entries WHERE voucher_id=? AND direction=1",voucher)).isEqualByComparingTo("3");
        List<String> entries=jdbc.queryForList("SELECT to_jsonb(entry)::text FROM gl_entries entry WHERE voucher_id=? ORDER BY id",String.class,voucher);
        assertThat(entries).hasSizeGreaterThanOrEqualTo(2);
        fixture.loginAs(maker);
        context.getBean(GlPostingService.class).generate(YearMonth.from(BusinessTime.today()).toString());
        assertThat(jdbc.queryForList("SELECT to_jsonb(entry)::text FROM gl_entries entry WHERE voucher_id=? ORDER BY id",String.class,voucher))
                .as("Version2 payment owns its exact approved GL even after period generation").isEqualTo(entries);
    }

    private static Map<String, List<String>> historicalFacts(JdbcTemplate jdbc) {
        Map<String, List<String>> result = new LinkedHashMap<>();
        for (String table : List.of("finance_receipts", "finance_payments", "finance_expenses", "finance_other_incomes", "finance_bank_transfers", "finance_reconciliations")) {
            result.put(table, jdbc.queryForList("SELECT to_jsonb(fact)::text FROM " + table + " fact WHERE legacy_id IS NOT NULL ORDER BY id", String.class));
        }
        for (var relation : List.of(new String[]{"finance_receipt_lines", "receipt_id", "finance_receipts"},
                new String[]{"finance_payment_lines", "payment_id", "finance_payments"},
                new String[]{"finance_expense_items", "expense_id", "finance_expenses"},
                new String[]{"finance_other_income_items", "income_id", "finance_other_incomes"},
                new String[]{"finance_bank_transfer_lines", "transfer_id", "finance_bank_transfers"})) {
            result.put(relation[0], jdbc.queryForList("SELECT to_jsonb(fact)::text FROM " + relation[0] + " fact JOIN " + relation[2]
                    + " head ON head.id=fact." + relation[1] + " WHERE head.legacy_id IS NOT NULL ORDER BY fact.id", String.class));
        }
        String source = """
                SELECT id FROM finance_receipts WHERE legacy_id IS NOT NULL
                UNION ALL SELECT id FROM finance_payments WHERE legacy_id IS NOT NULL
                UNION ALL SELECT id FROM finance_expenses WHERE legacy_id IS NOT NULL
                UNION ALL SELECT id FROM finance_other_incomes WHERE legacy_id IS NOT NULL
                UNION ALL SELECT id FROM finance_bank_transfers WHERE legacy_id IS NOT NULL
                """;
        result.put("gl_vouchers", jdbc.queryForList("SELECT to_jsonb(fact)::text FROM gl_vouchers fact WHERE source_doc_id IN (" + source + ") ORDER BY id", String.class));
        result.put("gl_entries", jdbc.queryForList("SELECT to_jsonb(fact)::text FROM gl_entries fact JOIN gl_vouchers head ON head.id=fact.voucher_id WHERE head.source_doc_id IN (" + source + ") ORDER BY fact.id", String.class));
        result.put("source_proofs",jdbc.queryForList("SELECT to_jsonb(proof)::text FROM legacy_finance_import_sources proof ORDER BY id",String.class));
        return result;
    }
}
