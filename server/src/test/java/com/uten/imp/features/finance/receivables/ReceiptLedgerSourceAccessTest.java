package com.uten.imp.features.finance.receivables;

import com.uten.imp.application.port.*;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import jakarta.persistence.*;
import org.junit.jupiter.api.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class ReceiptLedgerSourceAccessTest {
    @Test void newOrdinarySourceUsesTheShipmentScopeAndARealPostedOrVerifiedIndependentAr(){
        var em=mock(EntityManager.class);var scope=mock(SalesDocumentReadScopePort.class);var staff=mock(CurrentStaffAuthorityPort.class);var q=mock(Query.class);
        UUID ledger=UUID.randomUUID(),owner=UUID.randomUUID();when(staff.currentStaffPermissions()).thenReturn(Set.of("finance_receipt:edit"));
        when(scope.nativeReadScope(anyString(),anyString())).thenReturn(new NativeReadScope("shipment.owner_employee_id IN (:owners)","owners",Set.of(owner)));
        when(em.createNativeQuery(anyString())).thenReturn(q);when(q.setParameter(anyString(),any())).thenReturn(q);when(q.getResultList()).thenReturn(List.of());
        var service=new ReceiptLedgerSourceAccess(em,scope,staff);
        assertThatThrownBy(()->service.require(ledger)).hasMessageContaining("无权引用");
        verify(q).setParameter("owners",Set.of(owner));verify(q).setParameter("ledgerId",ledger);
        verify(em).createNativeQuery(argThat(sql->sql.contains("shipment.ar_posted")&&sql.contains("fn_is_verified_legacy_opening_ar")&&sql.contains("ledger.status=1")));
        when(q.getResultList()).thenReturn(List.of(ledger));assertThatCode(()->service.require(ledger)).doesNotThrowAnyException();
    }
    @Test void fullFinanceKeepsLegalCrossOwnerBatchCollectionWithoutRequiringAPhonyOrder(){
        var em=mock(EntityManager.class);var scope=mock(SalesDocumentReadScopePort.class);var staff=mock(CurrentStaffAuthorityPort.class);var q=mock(Query.class);
        UUID ledger=UUID.randomUUID();when(staff.currentStaffPermissions()).thenReturn(Set.of("finance:view:all","finance_receipt:create"));
        when(em.createNativeQuery(anyString())).thenReturn(q);when(q.setParameter(anyString(),any())).thenReturn(q);when(q.getResultList()).thenReturn(List.of(ledger));
        new ReceiptLedgerSourceAccess(em,scope,staff).require(ledger);verifyNoInteractions(scope);
    }
}
