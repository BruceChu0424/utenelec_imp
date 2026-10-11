package com.uten.imp.common.production;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import static org.junit.jupiter.api.Assertions.*;

class ProductionOutputQuantityTest {
    @Test void subQuantumOutputIsRejectedWithoutChangingTheDeclaredQuantity() {
        var qty=new BigDecimal("0.0001");var rate=new BigDecimal("0.4");
        var failure=assertThrows(ApiException.class,()->ProductionOutputQuantity.requirePositiveBaseQuantity(qty,rate));
        assertTrue(failure.getMessage().contains("基本量不足0.0001"));assertEquals(new BigDecimal("0.0001"),qty);
    }
    @Test void halfUpBoundaryAndIndividualSliceQuantizationRemainUnchanged() {
        assertEquals(new BigDecimal("0.0001"),ProductionOutputQuantity.requirePositiveBaseQuantity(new BigDecimal("0.0001"),new BigDecimal("0.5")));
        assertEquals(new BigDecimal("0.0002"),ProductionOutputQuantity.requirePositiveBaseQuantity(new BigDecimal("0.0001"),new BigDecimal("1.5")));
        assertEquals(new BigDecimal("1.0000"),ProductionOutputQuantity.requirePositiveBaseQuantity(new BigDecimal("3"),new BigDecimal("0.333333")));
        assertEquals(new BigDecimal("0.0001"),ProductionOutputQuantity.requirePositiveBaseQuantity(new BigDecimal("0.0001"),null));
        assertEquals(new BigDecimal("9999999999999.9999"),ProductionOutputQuantity.requirePositiveBaseQuantity(new BigDecimal("9999999999999.9999"),BigDecimal.ONE));
    }
    @Test void maximumNominalAndConvertedBaseBoundsRejectBeforeNativeNumericOverflow() {
        var maximum=new BigDecimal("99999999999999.9999");
        assertEquals(maximum,ProductionOutputQuantity.requirePositiveBaseQuantity(maximum,BigDecimal.ONE));
        var failure=assertThrows(ApiException.class,()->ProductionOutputQuantity.requirePositiveBaseQuantity(maximum,new BigDecimal("10")));
        assertTrue(failure.getMessage().contains("换算后的基本量"));
        assertThrows(ApiException.class,()->ProductionOutputQuantity.requirePositiveBaseQuantity(new BigDecimal("100000000000000"),new BigDecimal("0.1")));
        assertThrows(ApiException.class,()->ProductionOutputQuantity.requirePositiveBaseQuantity(new BigDecimal("1E+1000000000"),BigDecimal.ONE));
        assertThrows(ApiException.class,()->ProductionOutputQuantity.requirePositiveBaseQuantity(BigDecimal.ONE,new BigDecimal("0.0000001")));
        assertEquals(maximum,new BigDecimal("99999999999999.9999"));
    }
}
