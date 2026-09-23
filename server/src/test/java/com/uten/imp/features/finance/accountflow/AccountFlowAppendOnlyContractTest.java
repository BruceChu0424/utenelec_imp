package com.uten.imp.features.finance.accountflow;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class AccountFlowAppendOnlyContractTest {

    private static final Path FINANCE = Path.of(
            "src/main/java/com/uten/imp/features/finance");

    @Test
    void financialReversalsDelegateToTheAppendOnlyAccountFlowLedger() throws Exception {
        assertAppendOnlyCaller("payment/FinancePaymentService.java", "PAYMENT");
        assertAppendOnlyCaller("expense/FinanceExpenseService.java", "EXPENSE");
        assertAppendOnlyCaller("other_income/FinanceOtherIncomeService.java", "INCOME");
        assertAppendOnlyCaller("bank_transfer/FinanceBankTransferService.java", "BANK_TRANSFER");
        assertAppendOnlyCaller(
                "payables/SubcontractLossClaimService.java",
                "SUPPLIER_CLAIM_RECEIPT");
    }

    @Test
    void localOnlyCashWritersRequireTheImmutableBaseCurrencyAuthority() throws Exception {
        // ADR-112: 账户锁、启用校验与本位币规则只在账本里写一次, 业务服务只声明规则。
        for (String relative : new String[]{
                "expense/FinanceExpenseService.java",
                "other_income/FinanceOtherIncomeService.java",
                "payables/SubcontractLossClaimService.java"}) {
            String source = Files.readString(FINANCE.resolve(relative));
            assertThat(source)
                    .contains("AccountPosting.CurrencyRule.BASE_ONLY")
                    .doesNotContain("UPDATE accounts", "INSERT INTO finance_reconciliations",
                            "\"CNY\".equalsIgnoreCase", "\"人民币\".equals");
        }
        String ledger = Files.readString(FINANCE.resolve("accountflow/AccountFlowLedgerService.java"));
        assertThat(ledger)
                .contains("JOIN currencies currency ON currency.id = account.currency_id")
                .contains("currency.status = '使用'")
                .contains("FOR UPDATE OF account")
                .contains("if (!account.baseCurrency()");
    }

    @Test
    void localOnlyDocumentsAndBankTransfersFailClosedOnCurrencyAuthority() throws Exception {
        for (String relative : new String[]{
                "expense/FinanceExpenseService.java",
                "other_income/FinanceOtherIncomeService.java"}) {
            String source = Files.readString(FINANCE.resolve(relative));
            assertThat(source)
                    .contains("getExchangeRate().compareTo(BigDecimal.ONE) != 0")
                    .contains("汇率必须为 1");
        }
        String transfer = Files.readString(
                FINANCE.resolve("bank_transfer/FinanceBankTransferService.java"));
        assertThat(transfer)
                .contains("requireBaseCurrencyTransferAccounts")
                .contains("仅允许转出和全部转入均为同一启用本位币账户")
                .contains("AccountPosting.CurrencyRule.BASE_ONLY");
        String ledger = Files.readString(FINANCE.resolve("accountflow/AccountFlowLedgerService.java"));
        assertThat(ledger)
                .contains("if (account.baseCurrency()) local = accountAmount;")
                .contains("in_amount, out_amount, amount_local");
    }

    @Test
    void accountBalancesAndFlowsHaveOneWriter() throws Exception {
        // dup-backend-split-04 验收: 全仓只有账本服务写 accounts 余额与 finance_reconciliations。
        Path main = Path.of("src/main/java/com/uten/imp");
        try (var files = Files.walk(main)) {
            var writers = files.filter(path -> path.toString().endsWith(".java"))
                    .filter(path -> {
                        try {
                            String source = Files.readString(path);
                            return source.contains("UPDATE accounts")
                                    || source.contains("INSERT INTO finance_reconciliations");
                        } catch (java.io.IOException e) {
                            throw new java.io.UncheckedIOException(e);
                        }
                    })
                    .map(path -> path.getFileName().toString())
                    .toList();
            assertThat(writers).containsExactly("AccountFlowLedgerService.java");
        }
    }

    private static void assertAppendOnlyCaller(
            String relative,
            String sourceType) throws Exception {
        String source = Files.readString(FINANCE.resolve(relative));
        assertThat(source)
                .contains("accountFlowLedger.reverse(")
                .contains(sourceType)
                .doesNotContain(
                        "DELETE FROM finance_reconciliations",
                        "UPDATE finance_reconciliations SET is_deleted");
    }
}
