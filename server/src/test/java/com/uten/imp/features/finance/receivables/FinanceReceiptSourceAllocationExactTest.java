package com.uten.imp.features.finance.receivables;

import com.uten.imp.features.finance.arap.ArApLedger;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class FinanceReceiptSourceAllocationExactTest {
    @Test void distinctOrderSourcesKeepTheirConfirmedBookPartsInsteadOfUsingTheAggregatedArRatio() {
        EntityManager em=mock(EntityManager.class);Query q=mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(q);when(q.setParameter(anyString(),any())).thenReturn(q);
        when(q.getResultList()).thenReturn(List.of(
            new Object[]{new BigDecimal("1"),new BigDecimal("3.3333")},
            new Object[]{new BigDecimal("2"),new BigDecimal("6.6667")}));
        var service=new FinanceReceiptSourceAllocationService(em,mock(SecurityContextCurrentUser.class));
        var ledger=new ArApLedger();ledger.setId(UUID.randomUUID());ledger.setAmountBalanceOriginal(new BigDecimal("3"));ledger.setAmountBalance(BigDecimal.TEN);
        assertEquals(0,new BigDecimal("3.3333").compareTo(service.plannedBookAmount(ledger,BigDecimal.ONE)));
        assertEquals(0,new BigDecimal("6.66665").compareTo(service.plannedBookAmount(ledger,new BigDecimal("2"))));
        assertEquals(0,BigDecimal.TEN.compareTo(service.plannedBookAmount(ledger,new BigDecimal("3"))));
        assertThrows(com.uten.imp.common.web.ApiException.class,()->service.plannedBookAmount(ledger,new BigDecimal("3.0001")));
    }
}
