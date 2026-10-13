package com.uten.imp.common.finance;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

class ProcurementApprovedExchangeRateTest {
    @Test void financialDecisionWinsAndLegacyFactsKeepTheirRecordedRate() {
        UUID approval=UUID.randomUUID();
        var decided=ProcurementApprovedExchangeRate.fromApprovedFacts(approval,new BigDecimal("7.123456"),
                new BigDecimal("71.23456"),BigDecimal.ONE);
        assertThat(decided.caseId()).isEqualTo(approval);
        assertThat(decided.financeDetermined()).isTrue();
        assertThat(decided.local(BigDecimal.TEN,BigDecimal.TEN)).isEqualByComparingTo("71.23456");
        for(UUID oldCase:new UUID[]{null,approval}) {
            var legacy=ProcurementApprovedExchangeRate.fromApprovedFacts(oldCase,null,null,new BigDecimal("6.5"));
            assertThat(legacy.financeDetermined()).isFalse();
            assertThat(legacy.rate()).isEqualByComparingTo("6.5");
            assertThat(legacy.local(BigDecimal.TEN,new BigDecimal("64.99"))).isEqualByComparingTo("64.99");
        }
    }

    @Test void missingOrInvalidEvidenceNeverInventsAnExchangeRate() {
        UUID approval=UUID.randomUUID();
        assertThatThrownBy(()->ProcurementApprovedExchangeRate.fromApprovedFacts(approval,BigDecimal.TEN,null,BigDecimal.ONE)).hasMessageContaining("事实缺失");
        assertThatThrownBy(()->ProcurementApprovedExchangeRate.fromApprovedFacts(approval,null,BigDecimal.TEN,BigDecimal.ONE)).hasMessageContaining("事实不完整");
        assertThatThrownBy(()->ProcurementApprovedExchangeRate.fromApprovedFacts(null,BigDecimal.TEN,BigDecimal.TEN,BigDecimal.ONE)).hasMessageContaining("事实缺失");
        assertThatThrownBy(()->ProcurementApprovedExchangeRate.fromApprovedFacts(null,null,null,null)).hasMessageContaining("不完整");
        assertThatThrownBy(()->ProcurementApprovedExchangeRate.fromApprovedFacts(approval,BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ONE)).hasMessageContaining("不完整");
    }
}
