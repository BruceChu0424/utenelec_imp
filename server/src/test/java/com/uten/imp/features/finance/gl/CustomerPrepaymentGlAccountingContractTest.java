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
                .contains("t.receipt_kind='CUSTOMER_PREPAYMENT'")
                .contains("system_posting_style_id('CUSTOMER_ADVANCE')")
                .contains("'AUTO','CUSTOMER_PREPAYMENT_OFFSET',batch.id")
                .contains("voucher.id,1,advance_style.id,1,SUM(allocation.source_amount_local)")
                .contains("voucher.id,2,ar_style.id,-1,SUM(allocation.target_amount_local)")
                .contains("CASE WHEN SUM(allocation.exchange_difference)>0 THEN -1 ELSE 1 END")
                .contains("HAVING SUM(allocation.exchange_difference)<>0")
                .contains("assertCustomerPrepaymentPostingConfiguration(period)")
                .contains("assertCustomerPrepaymentProjectionOwnership(period)");
    }
}
