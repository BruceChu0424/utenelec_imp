package com.uten.imp.features.finance.payables;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ProcurementIqcRejectionDatePolicyTest {
    @Test
    void returnDateMustStayBetweenOpeningAndToday(){
        LocalDate opened=LocalDate.of(2026,8,20);
        LocalDate today=LocalDate.of(2026,8,31);
        assertThatCode(()->ProcurementIqcRejectionService.validateReturnDate(
                opened,opened,today)).doesNotThrowAnyException();
        assertThatThrownBy(()->ProcurementIqcRejectionService.validateReturnDate(
                opened,opened.minusDays(1),today)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->ProcurementIqcRejectionService.validateReturnDate(
                opened,today.plusDays(1),today)).isInstanceOf(ApiException.class);
    }

    @Test
    void creditDateCannotPrecedePhysicalReturnOrExceedToday(){
        LocalDate returned=LocalDate.of(2026,8,25);
        LocalDate today=LocalDate.of(2026,8,31);
        assertThatCode(()->ProcurementIqcRejectionService.validateCreditDate(
                returned,today,today)).doesNotThrowAnyException();
        assertThatThrownBy(()->ProcurementIqcRejectionService.validateCreditDate(
                returned,returned.minusDays(1),today)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->ProcurementIqcRejectionService.validateCreditDate(
                returned,today.plusDays(1),today)).isInstanceOf(ApiException.class);
    }
}
