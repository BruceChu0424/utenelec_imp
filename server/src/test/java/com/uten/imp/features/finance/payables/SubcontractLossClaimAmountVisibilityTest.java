package com.uten.imp.features.finance.payables;

import com.uten.imp.security.CommercialPriceVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class SubcontractLossClaimAmountVisibilityTest {

    @Mock private SecurityContextCurrentUser currentUser;
    @Mock private CommercialPriceVisibility commercialPriceVisibility;
    @InjectMocks private SubcontractLossClaimService service;

    @Test
    void warehouseSummaryKeepsLossQuantitiesButMasksBookAndClaimAmounts() {
        when(commercialPriceVisibility.canViewFinance()).thenReturn(false);
        Object[] row = new Object[]{
                UUID.randomUUID(), UUID.randomUUID(), "SW-1", UUID.randomUUID(),
                "S-1", "供应商", "AWAITING_FULFILLMENT",
                new BigDecimal("5"), new BigDecimal("1"), new BigDecimal("4"),
                new BigDecimal("40"), new BigDecimal("30"), 2L, OffsetDateTime.now()
        };

        SubcontractLossClaimContracts.CaseSummary summary =
                ReflectionTestUtils.invokeMethod(service, "summary", (Object) row);

        assertTrue(summary.priceMasked());
        assertEquals("5.0000", summary.actualLossQty());
        assertEquals("4.0000", summary.excessLossQty());
        assertNull(summary.lossBookValueLocal());
        assertNull(summary.claimAmountLocal());
    }
}
