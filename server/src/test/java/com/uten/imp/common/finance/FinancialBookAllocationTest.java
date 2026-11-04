package com.uten.imp.common.finance;

import java.math.BigDecimal;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class FinancialBookAllocationTest {
    @Test void successiveNonfinitePartsPreserveExactRemainderAndExhaustTheirOneSource() throws Exception {
        try(var choice=BusinessPrecisionContext.use(java.util.Map.of("money.book-share",new BusinessPrecisionContext.Choice(30,"DOWN")))){
        BigDecimal beforeA=new BigDecimal("3"),beforeB=BigDecimal.TEN,assigned=BigDecimal.ZERO;
        for(int i=0;i<3;i++) {
            BigDecimal part=FinancialBookAllocation.part(BigDecimal.ONE,beforeA,beforeB);
            assertEquals(new BigDecimal(i==2?"3.333333333333333333333333333334":"3.333333333333333333333333333333"),part);
            beforeA=beforeA.subtract(BigDecimal.ONE);beforeB=beforeB.subtract(part);assigned=assigned.add(part);
        }
        assertEquals(0,beforeB.signum());assertEquals(0,assigned.compareTo(BigDecimal.TEN));
        }
    }
    @Test void tinyAndZeroBookPartsKeepTheirSourceBalanceUntilTheFinalOriginalAmount() throws Exception {
        BigDecimal tiny=new BigDecimal("1e-30");
        assertThrows(BusinessPrecisionRequiredException.class,()->FinancialBookAllocation.part(BigDecimal.ONE,new BigDecimal("3"),tiny));
        try(var choice=BusinessPrecisionContext.use(java.util.Map.of("money.book-share",new BusinessPrecisionContext.Choice(30,"DOWN")))){
        assertEquals(0,FinancialBookAllocation.part(BigDecimal.ONE,new BigDecimal("3"),tiny).signum());
        assertEquals(tiny,FinancialBookAllocation.part(new BigDecimal("3"),new BigDecimal("3"),tiny));
        assertEquals(0,FinancialBookAllocation.part(BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ZERO).signum());
        assertThrows(com.uten.imp.common.web.ApiException.class,()->FinancialBookAllocation.part(new BigDecimal("2"),BigDecimal.ONE,BigDecimal.TEN));
        }
    }
}
