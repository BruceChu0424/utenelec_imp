package com.uten.imp.features.production.analysis;
import java.math.BigDecimal;
import java.math.RoundingMode;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;
class PreplanMakePublicSupplyServiceTest {
    @Test void adoptedBaseAndRemainingProductionStayExactlyRepresentableInBothUnits() {
        for(String rateText:new String[]{"3","20","1.25","0.03"}) {
            BigDecimal rate=new BigDecimal(rateText),available=new BigDecimal("0.0012");
            BigDecimal quantum=PreplanMakePublicSupplyService.baseQuantum(rate);
            BigDecimal adopted=available.divide(quantum,0,RoundingMode.DOWN).multiply(quantum);
            BigDecimal units=adopted.divide(rate,24,RoundingMode.UNNECESSARY);
            BigDecimal remaining=BigDecimal.ONE.subtract(units);
            assertThat(adopted).isLessThanOrEqualTo(available);
            assertThat(adopted.add(remaining.multiply(rate))).isEqualByComparingTo(rate);
            assertThat(adopted.stripTrailingZeros().scale()).isLessThanOrEqualTo(24);
            assertThat(adopted).isPositive();
        }
    }
    @Test void nativeMicroSupplyIsNotSilentlyDiscardedByTheFormerFourPlaceQuantum(){
        assertThat(PreplanMakePublicSupplyService.baseQuantum(BigDecimal.ONE)).isEqualByComparingTo("1e-24");
        assertThat(new BigDecimal("1e-24").divide(PreplanMakePublicSupplyService.baseQuantum(BigDecimal.ONE),0,RoundingMode.DOWN).multiply(PreplanMakePublicSupplyService.baseQuantum(BigDecimal.ONE))).isEqualByComparingTo("1e-24");
    }
}
