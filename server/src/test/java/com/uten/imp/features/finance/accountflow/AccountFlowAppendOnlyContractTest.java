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
        for (String relative : new String[]{
                "expense/FinanceExpenseService.java",
                "other_income/FinanceOtherIncomeService.java",
                "payables/SubcontractLossClaimService.java"}) {
            String source = Files.readString(FINANCE.resolve(relative));
            assertThat(source)
                    .contains("JOIN currencies currency ON currency.id=account.currency_id")
                    .contains("currency.is_base_currency")
                    .contains("currency.status='使用'")
                    .contains("FOR UPDATE OF account")
                    .doesNotContain("\"CNY\".equalsIgnoreCase", "\"人民币\".equals");
        }
    }

    @Test
    void localOnlyDocumentsAndBankTransfersFailClosedOnCurrencyAuthority() throws Exception {
        for (String relative : new String[]{
                "expense/FinanceExpenseService.java",
                "other_income/FinanceOtherIncomeService.java"}) {
            String source = Files.readString(FINANCE.resolve(relative));
            assertThat(source)
                    .contains("Objects.equals(documentCurrencyId, accountCurrencyId)")
                    .contains("exchangeRate.compareTo(BigDecimal.ONE) != 0")
                    .contains("汇率必须为 1");
        }
        String transfer = Files.readString(
                FINANCE.resolve("bank_transfer/FinanceBankTransferService.java"));
        assertThat(transfer)
                .contains("requireBaseCurrencyTransferAccounts")
                .contains("仅允许转出和全部转入均为同一启用本位币账户")
                .contains("in_amount, out_amount, amount_local")
                .contains(".setParameter(\"amountLocal\", inAmount.signum() > 0 ? inAmount : outAmount)");
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
