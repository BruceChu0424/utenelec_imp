package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.time.LocalDate;

import static org.assertj.core.api.Assertions.assertThat;

class SupplierPaymentTermBoundaryContractTest {

    @Test
    void fixedDayWithoutExplicitMonthOffsetNeverPredatesTheTermsBase() {
        LocalDate receiptDate = LocalDate.of(2026, 8, 22);

        LocalDate dueDate = SupplierPaymentTermService.calculateDueDate(
                receiptDate,
                null,
                "RECEIPT_DATE",
                "FIXED_DAY_OF_MONTH",
                null,
                15,
                0,
                null);

        assertThat(dueDate)
                .as("a fixed monthly pay day already passed must roll forward, not create an overdue item")
                .isEqualTo(LocalDate.of(2026, 9, 15));
    }

    @Test
    void fixedDayStillUsesTheCurrentMonthWhenItHasNotPassed() {
        LocalDate receiptDate = LocalDate.of(2026, 8, 10);

        LocalDate dueDate = SupplierPaymentTermService.calculateDueDate(
                receiptDate,
                null,
                "RECEIPT_DATE",
                "FIXED_DAY_OF_MONTH",
                null,
                15,
                0,
                null);

        assertThat(dueDate).isEqualTo(LocalDate.of(2026, 8, 15));
    }
}
