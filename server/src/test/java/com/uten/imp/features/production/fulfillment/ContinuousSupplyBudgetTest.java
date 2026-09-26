package com.uten.imp.features.production.fulfillment;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import static org.assertj.core.api.Assertions.assertThat;

class ContinuousSupplyBudgetTest {
    private static BigDecimal n(String value) { return new BigDecimal(value); }

    @Test void publicStockCannotDisplaceAnUnreceivedFutureCommitment() {
        var result=ContinuousSupplyBudget.calculate(n("100"),n("20"),n("30"),n("200"),n("0"),n("0"),n("0"),n("0"),false);
        assertThat(result.quantity()).isEqualByComparingTo("50");
        assertThat(result.sharedQuantity()).isEqualByComparingTo("50");
    }

    @Test void repeatedMaterialDemandsShareOnePhysicalBudget() {
        var first=ContinuousSupplyBudget.calculate(n("70"),n("0"),n("0"),n("100"),n("0"),n("0"),n("0"),n("0"),false);
        var second=ContinuousSupplyBudget.calculate(n("70"),n("0"),n("0"),n("100"),first.sharedQuantity(),n("0"),n("0"),n("0"),false);
        assertThat(first.quantity()).isEqualByComparingTo("70");
        assertThat(second.quantity()).isEqualByComparingTo("30");
    }

    @Test void privateReturnedMaterialNeedsExplicitReclaimAndDoesNotSpendSharedStock() {
        var ordinary=ContinuousSupplyBudget.calculate(n("100"),n("20"),n("30"),n("100"),n("0"),n("20"),n("0"),n("0"),false);
        var reclaim=ContinuousSupplyBudget.calculate(n("100"),n("20"),n("30"),n("100"),n("0"),n("20"),n("0"),n("0"),true);
        assertThat(ordinary.quantity()).isEqualByComparingTo("30");
        assertThat(reclaim.quantity()).isEqualByComparingTo("50");
        assertThat(reclaim.sharedQuantity()).isEqualByComparingTo("30");
    }

    @Test void anExactReceivedContributionReplacesOnlyItsOwnFutureAmount() {
        var result=ContinuousSupplyBudget.calculate(n("100"),n("20"),n("80"),n("100"),n("0"),n("0"),n("25"),n("0"),false);
        assertThat(result.quantity()).isEqualByComparingTo("25");
    }
}
