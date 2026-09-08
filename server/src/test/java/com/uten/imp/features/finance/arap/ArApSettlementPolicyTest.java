package com.uten.imp.features.finance.arap;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import static org.junit.jupiter.api.Assertions.*;

class ArApSettlementPolicyTest {
    @Test void eitherCurrencyRemainingKeepsTheItemOpen() {
        for(String balance:new String[]{"0.0001","-0.0001","100","-100"}) {
            assertFalse(ArApSettlementPolicy.isSettled(new BigDecimal(balance),BigDecimal.ZERO));
            assertFalse(ArApSettlementPolicy.isSettled(BigDecimal.ZERO,new BigDecimal(balance)));
        }
    }
    @Test void bothZeroIsSettledAndLegacyUnknownOriginalIsPreserved() {
        assertTrue(ArApSettlementPolicy.isSettled(BigDecimal.ZERO,BigDecimal.ZERO));
        assertTrue(ArApSettlementPolicy.isSettled(null,BigDecimal.ZERO));
        assertFalse(ArApSettlementPolicy.isSettled(null,BigDecimal.ONE));
        assertFalse(ArApSettlementPolicy.isSettled(BigDecimal.ZERO,null));
    }
}
