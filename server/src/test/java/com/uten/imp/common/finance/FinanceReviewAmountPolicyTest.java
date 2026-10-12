package com.uten.imp.common.finance;

import com.uten.imp.application.port.ProcurementOrderApprovalPort.ReviewAmountEdit;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

class FinanceReviewAmountPolicyTest {
    @Test void rejectsAmbiguousDuplicateNegativeAndUnrepresentableInputs() {
        UUID id = UUID.randomUUID();
        for (var edit : List.of(new ReviewAmountEdit(id, null, null),
                new ReviewAmountEdit(id, BigDecimal.ONE, BigDecimal.ONE),
                new ReviewAmountEdit(id, new BigDecimal("-0.1"), null),
                new ReviewAmountEdit(id, new BigDecimal("0.00000000001"), null),
                new ReviewAmountEdit(id, null, new BigDecimal("1e40")))) {
            assertThatThrownBy(() -> FinanceReviewAmountPolicy.requireEdits(List.of(edit))).isInstanceOf(ApiException.class);
        }
        var edit = new ReviewAmountEdit(id, BigDecimal.ZERO, null);
        assertThatThrownBy(() -> FinanceReviewAmountPolicy.requireEdits(List.of(edit, edit))).isInstanceOf(ApiException.class);
    }

    @Test void preservesTotalInputAndAllowsExplicitZeroPriceWithoutChangingPricingMode() {
        var total = new ReviewAmountEdit(UUID.randomUUID(), null, new BigDecimal("10.123456789123456789"));
        FinanceReviewAmountPolicy.requireEdits(List.of(total));
        FinanceReviewAmountPolicy.requireSamePricingMode(total, BigDecimal.ONE);
        assertThat(MoneyPolicy.orderBaseAmount(new BigDecimal("3"), FinanceReviewAmountPolicy.price(total, new BigDecimal("3")), total.totalAmountInput()))
                .isEqualByComparingTo(total.totalAmountInput());
        assertThatThrownBy(() -> FinanceReviewAmountPolicy.requireSamePricingMode(total, null)).isInstanceOf(ApiException.class);
        var zero = new ReviewAmountEdit(UUID.randomUUID(), BigDecimal.ZERO, null);
        FinanceReviewAmountPolicy.requireEdits(List.of(zero));
        assertThat(FinanceReviewAmountPolicy.price(zero, BigDecimal.ONE)).isZero();
    }
}
