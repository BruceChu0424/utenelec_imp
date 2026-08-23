package com.uten.imp.features.finance.payables;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class SupplierPaymentTermServiceTest {

    private static final LocalDate RECEIPT_DATE = LocalDate.of(2026, 8, 22);

    @Test
    void receiptNetDaysUsesPositiveSupplierOverride() {
        assertThat(due("RECEIPT_DATE", "NET_DAYS", 30, null, null, 45))
                .isEqualTo(LocalDate.of(2026, 10, 6));
    }

    @Test
    void explicitCashIgnoresPositiveSupplierDueDayOverride() {
        assertThat(due("CASH", "RECEIPT_DATE", "NET_DAYS", 0, null, null, 45))
                .isEqualTo(RECEIPT_DATE);
    }

    @Test
    void monthlyRoleKeepsStatementEndAndPositiveSupplierOverride() {
        assertThat(due("MONTHLY", "STATEMENT_END", "NET_DAYS", 30, null, null, 45))
                .isEqualTo(LocalDate.of(2026, 10, 15));
    }

    @Test
    void eomPlusDaysNormalizesReceiptToCalendarMonthEnd() {
        assertThat(due("RECEIPT_DATE", "EOM_PLUS_DAYS", 15, null, null, null))
                .isEqualTo(LocalDate.of(2026, 9, 15));
    }

    @Test
    void fixedDayClampsToTargetMonthLastDay() {
        LocalDate due = SupplierPaymentTermService.calculateDueDate(
                LocalDate.of(2026, 1, 30),
                null,
                "RECEIPT_DATE",
                "FIXED_DAY_OF_MONTH",
                null, 31, 1, null);

        assertThat(due).isEqualTo(LocalDate.of(2026, 2, 28));
    }

    @Test
    void laterEventBasesStayUnscheduledUntilTheEventExists() {
        assertThat(due("QC_ACCEPTANCE_DATE", "NET_DAYS", 30, null, null, null)).isNull();
        assertThat(due("STATEMENT_CONFIRM_DATE", "NET_DAYS", 30, null, null, null)).isNull();
        assertThat(due("INVOICE_DATE", "NET_DAYS", 30, null, null, null)).isNull();
    }

    @Test
    void unknownOrIncompletePoliciesFailClosed() {
        assertThatThrownBy(() -> due("UNKNOWN", "NET_DAYS", 30, null, null, null))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("未知账期基准");
        assertThatThrownBy(() -> due("RECEIPT_DATE", "UNKNOWN", 30, null, null, null))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("未知到期规则");
        assertThatThrownBy(() -> due("INVOICE_DATE", "UNKNOWN", 30, null, null, null))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("未知到期规则");
        assertThatThrownBy(() -> due("RECEIPT_DATE", "NET_DAYS", null, null, null, null))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("到期天数");
    }

    private static LocalDate due(
            String termsBase,
            String dueRule,
            Integer defaultDueDays,
            Integer fixedDay,
            Integer monthsAhead,
            Integer supplierDays) {
        return due(null, termsBase, dueRule, defaultDueDays, fixedDay, monthsAhead, supplierDays);
    }

    private static LocalDate due(
            String systemRole,
            String termsBase,
            String dueRule,
            Integer defaultDueDays,
            Integer fixedDay,
            Integer monthsAhead,
            Integer supplierDays) {
        return SupplierPaymentTermService.calculateDueDate(
                RECEIPT_DATE,
                systemRole,
                termsBase,
                dueRule,
                defaultDueDays,
                fixedDay,
                monthsAhead,
                supplierDays);
    }
}
