package com.uten.imp.features.finance.asset.application;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchRequests;
import com.uten.imp.features.finance.asset.domain.*;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.time.LocalDate;
import static org.assertj.core.api.Assertions.*;

class AssetOpeningBalanceSupportTest {
    @Test void continuationOnlyDepreciatesTheRemainingAmountAndKeepsLastPeriodRounding() {
        var schedule=StraightLineScheduleCalculator.calculateOpening(new BigDecimal("1200"),new BigDecimal("0.05"),6,
                AssetPeriod.parse("2026-07"),new BigDecimal("540"));
        assertThat(schedule.lines().getFirst().openingAccumulated()).isEqualByComparingTo("540");
        assertThat(schedule.lines()).allSatisfy(line->assertThat(line.amount()).isEqualByComparingTo("100"));
        assertThat(schedule.lines().getLast().closingNetAmount()).isEqualByComparingTo("60");
        var rounding=StraightLineScheduleCalculator.calculateOpening(new BigDecimal("100"),BigDecimal.ZERO,3,
                AssetPeriod.parse("2026-01"),new BigDecimal("10"));
        assertThat(rounding.lines().stream().map(StraightLineScheduleCalculator.ScheduleLine::amount).reduce(BigDecimal.ZERO,BigDecimal::add))
                .isEqualByComparingTo("90");
    }
    @Test void invalidCutoffAccumulationAndRemainingLifeAreRejected() {
        var cutoff=LocalDate.of(2026,6,30);var ready=LocalDate.of(2026,1,1);
        for(var invalid:java.util.List.of(
                new AssetWorkbenchRequests.OpeningBalance(cutoff.minusDays(1),BigDecimal.ZERO,12,null),
                new AssetWorkbenchRequests.OpeningBalance(cutoff,new BigDecimal("1201"),12,null),
                new AssetWorkbenchRequests.OpeningBalance(cutoff,BigDecimal.ZERO,0,null)))
            assertThatThrownBy(()->AssetOpeningBalanceSupport.validate(invalid,new BigDecimal("1200"),BigDecimal.ZERO,ready,"2026-07"))
                    .isInstanceOf(ApiException.class);
        assertThatCode(()->AssetOpeningBalanceSupport.validate(
                new AssetWorkbenchRequests.OpeningBalance(cutoff,new BigDecimal("1200"),0,null),
                new BigDecimal("1200"),BigDecimal.ZERO,ready,"2026-07")).doesNotThrowAnyException();
    }
}
