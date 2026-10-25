package com.uten.imp.common.history;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.other_income.*;
import com.uten.imp.features.purchase.request.*;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.SalesMutationFootprintService;
import com.uten.imp.features.sales.order.*;
import com.uten.imp.features.sales.order.dto.OrderPriorityRequest;
import com.uten.imp.features.sales.order.dto.OrderYieldRequest;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.util.Optional;
import java.util.UUID;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.test.util.ReflectionTestUtils;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Exercise real command bodies: an out-of-scope identifier must not reveal origin. */
class ImportedCommandVisibilityOrderTest {
    @ParameterizedTest @ValueSource(booleans={false,true})
    void salesPriorityAndYieldKeepTheSameScopeDenialForNativeAndArchivedItems(boolean archived) {
        UUID orderId=UUID.randomUUID(), itemId=UUID.randomUUID(), ownerId=UUID.randomUUID();
        SalesOrder order=new SalesOrder();order.setId(orderId);order.setOwnerEmployeeId(ownerId);
        SalesOrderItem item=new SalesOrderItem();item.setId(itemId);item.setOrderId(orderId);
        item.setLegacyId(archived?123:null);item.setPriority((short)3);item.setReservedQty(BigDecimal.ONE);
        var repository=mock(SalesOrderRepository.class);
        when(repository.findById(orderId)).thenReturn(Optional.of(order));
        var em=entityManager();when(em.find(SalesOrderItem.class,itemId,LockModeType.PESSIMISTIC_WRITE)).thenReturn(item);
        var footprint=mock(SalesMutationFootprintService.class);when(footprint.lockOrderItem(itemId)).thenReturn(orderId);
        var access=mock(SalesDocumentAccessPolicy.class);
        ApiException denied=new ApiException(ErrorCode.FORBIDDEN,"outside current object scope");
        doThrow(denied).when(access).requireWritable(eq(ownerId),anyString(),any(String[].class));
        var service=mock(SalesOrderService.class,CALLS_REAL_METHODS);
        inject(service,"tx",mock(TxSessionVars.class));inject(service,"em",em);
        inject(service,"orderRepo",repository);inject(service,"mutationFootprint",footprint);inject(service,"accessPolicy",access);
        var priority=new OrderPriorityRequest();priority.setPriority((short)2);
        assertSame(denied,assertThrows(ApiException.class,()->service.setLinePriority(itemId,priority)));
        var yield=new OrderYieldRequest();yield.setQty(BigDecimal.ONE);yield.setReason("scope regression fixture");
        assertSame(denied,assertThrows(ApiException.class,()->service.yieldReservation(itemId,yield)));
        assertEquals((short)3,item.getPriority());assertEquals(BigDecimal.ONE,item.getReservedQty());
        verify(repository,never()).save(any());
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void otherIncomeReversalChecksCurrentScopeBeforeOrigin(boolean archived) {
        UUID id=UUID.randomUUID(), maker=UUID.randomUUID();
        var income=new FinanceOtherIncome();income.setId(id);income.setMakerId(maker);
        income.setLegacyId(archived?123:null);income.setStatus((short)1);
        var repository=mock(FinanceOtherIncomeRepository.class);when(repository.findById(id)).thenReturn(Optional.of(income));
        var access=mock(FinanceDocumentAccessPolicy.class);
        ApiException denied=new ApiException(ErrorCode.FORBIDDEN,"outside current object scope");
        doThrow(denied).when(access).requireScopedOperationWritable(eq(maker),anyString(),anyString());
        var service=mock(FinanceOtherIncomeService.class,CALLS_REAL_METHODS);
        inject(service,"tx",mock(TxSessionVars.class));inject(service,"em",entityManager());
        inject(service,"incomeRepo",repository);inject(service,"access",access);
        assertSame(denied,assertThrows(ApiException.class,()->service.reverse(id)));
        assertEquals((short)1,income.getStatus());verify(repository,never()).save(any());
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void foreignPurchaseRequestItemDoesNotDiscloseItsOrigin(boolean archived) {
        UUID requestId=UUID.randomUUID(), itemId=UUID.randomUUID();
        var request=new PurchaseRequest();request.setId(requestId);
        var item=new PurchaseRequestItem();item.setId(itemId);item.setRequestId(UUID.randomUUID());
        item.setLegacyId(archived?123:null);item.setQty(new BigDecimal("7"));
        var requests=mock(PurchaseRequestRepository.class);when(requests.findById(requestId)).thenReturn(Optional.of(request));
        var items=mock(PurchaseRequestItemRepository.class);when(items.findById(itemId)).thenReturn(Optional.of(item));
        var service=mock(PurchaseRequestService.class,CALLS_REAL_METHODS);var em=entityManager();
        inject(service,"tx",mock(TxSessionVars.class));inject(service,"em",em);
        inject(service,"requestRepo",requests);inject(service,"itemRepo",items);
        ApiException denied=assertThrows(ApiException.class,()->service.adjustItemQty(requestId,itemId,BigDecimal.ONE,0L));
        assertEquals(ErrorCode.NOT_FOUND,denied.getCode());assertEquals("申请明细不存在",denied.getMessage());
        assertEquals(new BigDecimal("7"),item.getQty());verify(items,never()).save(any());
        verify(em,never()).refresh(any());
    }

    private static EntityManager entityManager() {
        var em=mock(EntityManager.class);var query=mock(Query.class,RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(query);when(query.getSingleResult()).thenReturn(false);
        return em;
    }
    private static void inject(Object target,String field,Object value) {ReflectionTestUtils.setField(target,field,value);}
}
