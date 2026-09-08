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

import static org.assertj.core.api.Assertions.assertThat;
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
        assertThat(new BigDecimal(summary.actualLossQty())).isEqualByComparingTo("5");
        assertThat(new BigDecimal(summary.allowedLossQty())).isEqualByComparingTo("1");
        assertThat(new BigDecimal(summary.excessLossQty())).isEqualByComparingTo("4");
        assertNull(summary.lossBookValueLocal());
        assertNull(summary.claimAmountLocal());
    }

    @Test
    void financeSummaryKeepsExactBookAndClaimAmountsAndUnknownBookValue() {
        when(commercialPriceVisibility.canViewFinance()).thenReturn(true);
        Object[] row = new Object[]{
                UUID.randomUUID(), UUID.randomUUID(), "SW-2", UUID.randomUUID(),
                "S-1", "供应商", "AWAITING_FULFILLMENT",
                new BigDecimal("5"), BigDecimal.ONE, new BigDecimal("4"),
                new BigDecimal("40.000000000000000000000000000001"),
                new BigDecimal("30.000000000000000000000001"), 2L, OffsetDateTime.now()
        };
        SubcontractLossClaimContracts.CaseSummary summary =
                ReflectionTestUtils.invokeMethod(service, "summary", (Object) row);
        assertThat(summary.priceMasked()).isFalse();
        assertThat(new BigDecimal(summary.lossBookValueLocal()))
                .isEqualByComparingTo("40.000000000000000000000000000001");
        assertThat(new BigDecimal(summary.claimAmountLocal()))
                .isEqualByComparingTo("30.000000000000000000000001");

        row[10] = null;
        summary = ReflectionTestUtils.invokeMethod(service, "summary", (Object) row);
        assertNull(summary.lossBookValueLocal());
        assertThat(new BigDecimal(summary.claimAmountLocal()))
                .isEqualByComparingTo("30.000000000000000000000001");
    }
}
