package com.uten.imp.features.finance.receivables;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class CustomerPrepaymentQueryExactTest {
    @Test void pickerAndSummaryRetainActualNativeAndThirtyDigitBookValuesWithoutTurningUnknownHistoryIntoZero() {
        EntityManager em=mock(EntityManager.class);Query count=query(),items=query(),summary=query();
        when(count.getSingleResult()).thenReturn(2L);
        BigDecimal a=new BigDecimal("0.000000000000000000000001"),b=new BigDecimal("0.000000000000000000000007000001");
        Object[] complete={UUID.randomUUID(),UUID.randomUUID(),"XS-EXACT",LocalDate.of(2026,9,7),null,UUID.randomUUID(),"客户",UUID.randomUUID(),"USD","美元",new BigDecimal("7.000001"),a,b,BigDecimal.ZERO,BigDecimal.ZERO,a,b,null};
        Object[] legacy=complete.clone();legacy[0]=UUID.randomUUID();legacy[11]=null;legacy[15]=null;
        when(items.getResultList()).thenReturn(List.of(complete,legacy));
        when(summary.getSingleResult()).thenReturn(new Object[]{a,b,BigDecimal.ZERO,BigDecimal.ZERO,a,b});
        when(em.createNativeQuery(anyString())).thenAnswer(invocation->{String sql=invocation.getArgument(0);return sql.startsWith("SELECT COUNT(*)")?count:sql.contains("COALESCE(SUM(ledger.amount_received_original)")?summary:items;});
        var service=new CustomerPrepaymentQueryService(em,mock(SalesOrderMoneyPositionQuery.class));
        var page=service.list(null,null,null,1,20);
        assertEquals(a.toPlainString(),page.items().getFirst().availableOriginal());
        assertEquals(b.toPlainString(),page.items().getFirst().availableLocal());
        assertEquals(b.toPlainString(),page.summary().availableLocal());
        assertNull(page.items().get(1).availableOriginal());assertNull(page.items().get(1).receivedOriginal());
    }
    private static Query query(){Query q=mock(Query.class);when(q.setParameter(anyString(),any())).thenReturn(q);when(q.setFirstResult(anyInt())).thenReturn(q);when(q.setMaxResults(anyInt())).thenReturn(q);return q;}
}
