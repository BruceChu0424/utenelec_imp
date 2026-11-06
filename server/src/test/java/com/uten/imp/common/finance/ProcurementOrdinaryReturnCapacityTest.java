package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ProcurementOrdinaryReturnCapacityTest {
    @Test void unknownOrdinaryReturnAmountsCannotReleaseKnownQuantityAtZeroCredit() {
        var service=fixture(new Object[]{new BigDecimal("100"),new BigDecimal("100"),BigDecimal.ZERO,BigDecimal.ZERO,1L});
        assertThatThrownBy(()->service.releasedCapacityWithOrdinaryReturns("SUBCONTRACT",UUID.randomUUID()))
                .isInstanceOf(ApiException.class).hasMessageContaining("金额依据不完整");
    }

    @Test void actualRecordedReturnCreditIsSharedByDraftAndPostingAuthority() {
        var service=fixture(new Object[]{new BigDecimal("100"),new BigDecimal("100"),new BigDecimal("250"),new BigDecimal("250"),0L});
        var released=service.releasedCapacityWithOrdinaryReturns("SUBCONTRACT",UUID.randomUUID());
        assertThat(released.qty()).isEqualByComparingTo("100");
        assertThat(released.amountOriginal()).isEqualByComparingTo("250");
        assertThat(released.amountLocal()).isEqualByComparingTo("250");
    }

    private static ProcurementIqcReplacementAllocationService fixture(Object[] ordinary) {
        var em=mock(EntityManager.class);var iqc=mock(Query.class);var returns=mock(Query.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call->((String)call.getArgument(0)).contains("FROM procurement_iqc_rejection_cases")?iqc:returns);
        when(iqc.setParameter(anyString(),any())).thenReturn(iqc);when(returns.setParameter(anyString(),any())).thenReturn(returns);
        when(iqc.getSingleResult()).thenReturn(new Object[]{BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO});
        when(returns.getSingleResult()).thenReturn(ordinary);
        return new ProcurementIqcReplacementAllocationService(em,mock(SecurityContextCurrentUser.class));
    }
}
