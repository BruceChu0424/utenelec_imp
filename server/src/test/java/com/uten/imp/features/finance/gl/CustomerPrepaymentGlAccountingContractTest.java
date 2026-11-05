package com.uten.imp.features.finance.gl;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class CustomerPrepaymentGlAccountingContractTest {
    @Test
    void receiptCreditsAdvanceAndApplicationUsesDedicatedBalancedProjection() throws IOException {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/gl/GlPostingService.java"),
                StandardCharsets.UTF_8).replaceAll("\\s+", " ");

        assertThat(source)
                .contains("SELECT :voucher,2,receipt.gl_counter_style_id")
                .contains("SELECT :voucher,1,receipt.gl_account_style_id,1,")
                .contains("SELECT :voucher,2,receipt.gl_counter_style_id, -1,")
                .contains("system_posting_style_id('CUSTOMER_ADVANCE')")
                .contains("'AUTO','CUSTOMER_PREPAYMENT_OFFSET',batch.id")
                .contains("voucher.id,1,advance_style.id,1,SUM(allocation.source_amount_local)")
                .contains("voucher.id,2,ar_style.id,-1,SUM(allocation.target_amount_local)")
                .contains("CASE WHEN SUM(allocation.exchange_difference)>0 THEN -1 ELSE 1 END")
                .contains("HAVING SUM(allocation.exchange_difference)<>0")
                .contains("ABS(SUM(allocation.exchange_difference))")
                .contains("(native.source_account->>'styleId')::uuid,1,allocation.source_amount_local")
                .contains("(native.target_account->>'styleId')::uuid,-1,allocation.target_amount_local")
                .contains("assertCustomerPrepaymentPostingConfiguration(period)")
                .contains("assertCustomerPrepaymentProjectionOwnership(period)");
        String receipt = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/receipt/FinanceReceiptService.java"),
                StandardCharsets.UTF_8).replaceAll("\\s+", " ");
        // Formatting is not an accounting contract. Keep the actual role,
        // original currency/party/day binding and frozen-header flow explicit.
        assertThat(receipt)
                .contains("fn_finance_native_cash_counter_style('RECEIPT',:id,:role,:currency,'CUSTOMER',:party,:day)")
                .containsPattern("\"CUSTOMER_PREPAYMENT\"\\.equals\\(receipt\\.getReceiptKind\\(\\)\\)\\s*\\?\\s*\"CUSTOMER_ADVANCE\"\\s*:\\s*\"AR_CONTROL\"")
                .contains(".setParameter(\"role\",")
                .contains(".setParameter(\"currency\",receipt.getCurrencyId())")
                .contains(".setParameter(\"party\",receipt.getClientId())")
                .contains(".setParameter(\"day\",receipt.getBillDate())")
                .contains("var postingIdentity=resolveDraftPostingIdentity(receipt,")
                .contains("applyDraftPostingIdentity(receipt,postingIdentity,")
                .contains("receipt.setGlCounterStyleId(identity.counterStyle())")
                .contains("r.setGlCounterStyleId(nativePostingAccounts.prepareCash(\"RECEIPT\",r.getId()))");
    }
}
