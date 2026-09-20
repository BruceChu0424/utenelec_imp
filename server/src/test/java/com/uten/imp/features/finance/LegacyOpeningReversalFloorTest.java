package com.uten.imp.features.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.arap.ArApLedger;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class LegacyOpeningReversalFloorTest {
    @Test void nativeLedgerKeepsZeroFloorWithoutAHistoryQuery() {
        EntityManager em=mock(EntityManager.class);ArApLedger nativeLedger=new ArApLedger();nativeLedger.setId(UUID.randomUUID());
        assertThat(LegacyOpeningReversalFloor.load(em,List.of(nativeLedger),"AP")).isEmpty();
        assertThat(LegacyOpeningReversalFloor.ZERO.settledLocal()).isEqualByComparingTo("0");
        verifyNoInteractions(em);
    }

    @Test void verifiedNegativeSourceTotalsRemainExactAndAreReadInOneBatch() {
        EntityManager em=mock(EntityManager.class);Query query=mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);when(query.setParameter(anyString(),any())).thenReturn(query);
        ArApLedger first=historical(),second=historical();BigDecimal exact=new BigDecimal("-0.000000000000000000000001");
        when(query.getResultList()).thenReturn(List.of(new Object[]{first.getId(),true,exact,exact,exact},new Object[]{second.getId(),true,new BigDecimal("-8"),new BigDecimal("-8"),new BigDecimal("-8")}));
        var floors=LegacyOpeningReversalFloor.load(em,List.of(first,second),"AR");
        assertThat(floors.get(first.getId()).receivedOriginal()).isEqualTo(exact);
        assertThat(floors.get(second.getId()).settledLocal()).isEqualByComparingTo("-8");
        verify(em,times(1)).createNativeQuery(anyString());
    }

    @Test void missingUnknownOrUnverifiedHistoryNeverReceivesAZeroOrNegativeFallback() {
        EntityManager em=mock(EntityManager.class);Query query=mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);when(query.setParameter(anyString(),any())).thenReturn(query);
        ArApLedger ledger=historical();
        for(List<Object[]> rows:List.of(List.<Object[]>of(),List.<Object[]>of(new Object[]{ledger.getId(),false,BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO}),
                List.<Object[]>of(new Object[]{ledger.getId(),true,null,BigDecimal.ZERO,BigDecimal.ZERO}))) {
            when(query.getResultList()).thenReturn(rows);
            assertThatThrownBy(()->LegacyOpeningReversalFloor.load(em,List.of(ledger),"AP")).isInstanceOf(ApiException.class).hasMessageContaining("来源证明");
        }
    }
    private static ArApLedger historical(){ArApLedger ledger=new ArApLedger();ledger.setId(UUID.randomUUID());ledger.setLegacyId(9001);return ledger;}
}
