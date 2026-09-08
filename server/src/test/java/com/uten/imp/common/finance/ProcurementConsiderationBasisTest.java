package com.uten.imp.common.finance;

import java.math.BigDecimal;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ProcurementConsiderationBasisTest {
    @Test void retainsUnknownNonFiniteSharesWithoutZeroOrRoundedResidue(){
        assertNull(ProcurementConsiderationBasis.finitePortion(new BigDecimal("1.0001"),BigDecimal.ONE,new BigDecimal("3")));
        assertEquals(new BigDecimal("1.0001"),ProcurementConsiderationBasis.finitePortion(new BigDecimal("1.0001"),new BigDecimal("3"),new BigDecimal("3")));
        assertNull(ProcurementConsiderationBasis.add(null,BigDecimal.ZERO));
    }
    @Test void retainsTheFullFiniteSourceAndRejectsUnrepresentableProjection(){
        assertEquals(new BigDecimal("0.000000000000000000000001"),ProcurementConsiderationBasis.finitePortion(
                new BigDecimal("0.000000000000000000000003"),BigDecimal.ONE,new BigDecimal("3")));
        assertNull(ProcurementConsiderationBasis.finitePortion(new BigDecimal("0.000000000000000000000001"),BigDecimal.ONE,new BigDecimal("10")));
    }
    @Test void reviewedCaseBookAllocationsRetainEveryLastSourceUnit(){
        var ten=new BigDecimal("10");var three=new BigDecimal("3");
        var first=ProcurementConsiderationBasis.bookAllocation(ten,BigDecimal.ONE,three);
        var second=ProcurementConsiderationBasis.bookAllocation(ten.subtract(first),BigDecimal.ONE,new BigDecimal("2"));
        var last=ProcurementConsiderationBasis.bookAllocation(ten.subtract(first).subtract(second),BigDecimal.ONE,BigDecimal.ONE);
        assertEquals(new BigDecimal("3.333333333333333333333333333333"),first);
        assertEquals(0,ten.compareTo(first.add(second).add(last)));
        assertEquals(new BigDecimal("3.333333333333333333333333333334"),last);
        assertEquals(new BigDecimal("0.000000000000000000000000000001"),
                ProcurementConsiderationBasis.finiteBookPortion(new BigDecimal("0.000000000000000000000000000001"),BigDecimal.ONE,BigDecimal.ONE));
    }
}
