package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

class ProcurementReceiptHeaderAuthorityTest {
    private final UUID first = UUID.randomUUID(), second = UUID.randomUUID();
    private final UUID currency = UUID.randomUUID(), settlement = UUID.randomUUID();

    private EntityManager source(List<Object[]> rows) {
        EntityManager em = mock(EntityManager.class); Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(eq("ids"), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(rows); return em;
    }
    private Object[] row(UUID id, UUID curr, String tax, UUID method) {
        return new Object[]{id, curr, tax == null ? null : new BigDecimal(tax), method};
    }
    private ProcurementReceiptHeaderAuthority.Header omitted(EntityManager em, String kind, List<UUID> ids) {
        return ProcurementReceiptHeaderAuthority.deriveIfMissing(em, kind, ids, null, null, null);
    }
    @Test void omittedReadonlyTermsComeFromPurchaseSource() {
        var h = omitted(source(List.<Object[]>of(row(first,currency,"13.00",settlement))),"PURCHASE",List.of(first));
        assertEquals(currency,h.currencyId()); assertEquals(0,new BigDecimal("13").compareTo(h.taxRate())); assertEquals(settlement,h.settlementMethodId());
    }
    @Test void subcontractMultiSourceSameTermsAcceptsNumericScaleAndDuplicateReference() {
        var h=omitted(source(List.of(row(first,currency,"13.00",settlement),row(second,currency,"13",settlement))),"SUBCONTRACT",List.of(first,second,first));
        assertEquals(currency,h.currencyId()); assertEquals(settlement,h.settlementMethodId());
    }
    @Test void differentCurrenciesTaxAndMethodsEachReject() {
        for(Object[] changed:List.of(row(second,UUID.randomUUID(),"13",settlement),row(second,currency,"12",settlement),row(second,currency,"13",UUID.randomUUID())))
            assertThrows(ApiException.class,()->omitted(source(List.of(row(first,currency,"13",settlement),changed)),"PURCHASE",List.of(first,second)));
    }
    @Test void incompleteSourceDoesNotGuessZeroOrDefaultCurrency() {
        for(Object[] changed:List.of(row(first,null,"13",settlement),row(first,currency,null,settlement),row(first,currency,"13",null)))
            assertThrows(ApiException.class,()->omitted(source(List.<Object[]>of(changed)),"PURCHASE",List.of(first)));
    }
    @Test void missingSourceAndWrongSourceIdentityReject() {
        assertThrows(ApiException.class,()->omitted(source(List.<Object[]>of(row(first,currency,"13",settlement))),"PURCHASE",List.of(first,second)));
        assertThrows(ApiException.class,()->omitted(source(List.<Object[]>of(row(second,currency,"13",settlement))),"PURCHASE",List.of(first)));
    }
    @Test void suppliedPartialHeaderCannotDisagreeWithSource() {
        assertThrows(ApiException.class,()->ProcurementReceiptHeaderAuthority.deriveIfMissing(source(List.<Object[]>of(row(first,currency,"13",settlement))),"PURCHASE",List.of(first),UUID.randomUUID(),null,null));
        assertThrows(ApiException.class,()->ProcurementReceiptHeaderAuthority.deriveIfMissing(source(List.<Object[]>of(row(first,currency,"13",settlement))),"PURCHASE",List.of(first),null,new BigDecimal("14"),null));
    }
    @Test void standaloneDraftRetainsUnknownsAndExplicitHeaderUsesExistingApprovalGuard() {
        EntityManager em=mock(EntityManager.class);
        assertNull(omitted(em,"PURCHASE",List.of()).currencyId());
        assertEquals(settlement,ProcurementReceiptHeaderAuthority.deriveIfMissing(em,"PURCHASE",List.of(first),currency,BigDecimal.ZERO,settlement).settlementMethodId());
        verifyNoInteractions(em);
    }
}
