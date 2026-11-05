package com.uten.imp.features.finance.receivables;

import com.uten.imp.application.port.*;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import jakarta.persistence.*;
import org.junit.jupiter.api.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class ReceiptOrderSourceAccessTest {
    final UUID order=UUID.randomUUID(),client=UUID.randomUUID(),currency=UUID.randomUUID(),owner=UUID.randomUUID();
    EntityManager em;Query query;CurrentStaffAuthorityPort staff;SalesDocumentReadScopePort scope;ReceiptOrderSourceAccess service;
    @BeforeEach void setup(){
        em=mock(EntityManager.class);query=mock(Query.class);staff=mock(CurrentStaffAuthorityPort.class);scope=mock(SalesDocumentReadScopePort.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);when(query.setParameter(anyString(),any())).thenReturn(query);
        when(staff.currentStaffPermissions()).thenReturn(Set.of("finance_receipt:create","sales_order:view"));
        when(scope.nativeReadScope(anyString(),anyString())).thenReturn(new NativeReadScope("orders.owner_employee_id IN (:owners)","owners",Set.of(owner)));
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[]{order,client,currency,(short)1,false,false,"XD-SOURCE"}));
        service=new ReceiptOrderSourceAccess(em,scope,staff);
    }
    @Test void ordinaryClerkNeedsTheExistingOrderViewPermissionBeforeAnySourceQuery(){
        when(staff.currentStaffPermissions()).thenReturn(Set.of("finance_receipt:create"));
        assertThatThrownBy(()->service.require(order)).isInstanceOf(ApiException.class).hasMessageContaining("查看订货单");
        verifyNoInteractions(em,scope);
    }
    @Test void ordinaryClerkCannotForgeAnOrderOutsideTheAuthoritativeSalesScope(){
        when(query.getResultList()).thenReturn(List.of());
        assertThatThrownBy(()->service.require(order)).isInstanceOf(ApiException.class).hasMessageContaining("无权引用");
        verify(scope).nativeReadScope("orders.owner_employee_id","receiptOrderSourceOwners");verify(query).setParameter("owners",Set.of(owner));
    }
    @Test void ordinaryClerkMayReferenceAVisibleOrderWithTheSameBoundScope(){
        assertThat(service.require(order).id()).isEqualTo(order);
        verify(query).setParameter("owners",Set.of(owner));verify(query).setParameter("orderId",order);
    }
    @Test void globalFinanceKeepsCrossSalesOwnerCollectionWithoutNeedingTheSalesOwnerBypass(){
        when(staff.currentStaffPermissions()).thenReturn(Set.of("finance_receipt:create","finance:view:all"));
        assertThat(service.require(order).clientId()).isEqualTo(client);verifyNoInteractions(scope);
        verify(em).createNativeQuery(endsWith("(TRUE)"));
    }
}
