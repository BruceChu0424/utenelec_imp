package com.uten.imp.features.expenseclaim;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class ExpenseClaimSubmissionSnapshotTest {
    @Test
    void retainsExactCommercialFactsWithoutTurningReviewStateIntoAnApplicantChange() throws Exception {
        var claim=new ExpenseClaim();
        claim.setTitle("出差");
        claim.setTotalAmount(new BigDecimal("9999999999999999.99"));
        var item=new ExpenseClaimItem();
        item.setId(UUID.randomUUID()); item.setLineNo(1); item.setCategory("TRAVEL");
        item.setAmount(new BigDecimal("9999999999999999.99")); item.setExpenseDate(LocalDate.of(2026,9,23));
        item.setDescription("原用途");
        var invoice=new ExpenseClaimInvoice();
        invoice.setId(UUID.randomUUID()); invoice.setLineNo(1); invoice.setInvoiceNo("原票号");
        invoice.setTotalAmount(new BigDecimal("9999999999999999.99"));
        invoice.setCheckState("VERIFIED_MANUAL"); invoice.setVerificationRemark("审批核对");
        var json=new ObjectMapper();
        var before=json.readTree(ExpenseClaimSubmissionSnapshot.capture(claim,List.of(item),List.of(invoice)));
        assertThat(before.path("totalAmount").asText()).isEqualTo("9999999999999999.99");
        assertThat(before.path("items").get(0).path("amount").asText()).isEqualTo("9999999999999999.99");
        assertThat(before.path("items").get(0).path("date").asText()).isEqualTo("2026-09-23");
        invoice.setCheckState("UNCHECKED"); invoice.setVerificationRemark(null);
        assertThat(json.readTree(ExpenseClaimSubmissionSnapshot.capture(claim,List.of(item),List.of(invoice))))
                .isEqualTo(before);
        item.setDescription("新用途"); invoice.setInvoiceNo("新票号");
        assertThat(before.path("items").get(0).path("description").asText()).isEqualTo("原用途");
        assertThat(before.path("invoices").get(0).path("invoiceNo").asText()).isEqualTo("原票号");
    }
}
