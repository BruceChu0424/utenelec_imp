package com.uten.imp.features.finance.receivables;

import com.uten.imp.application.port.*;
import com.uten.imp.common.web.ApiException;
import jakarta.persistence.*;
import org.junit.jupiter.api.*;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class SalesOrderCollectionPreviewTest {
    final UUID order=UUID.randomUUID(),client=UUID.randomUUID(),currency=UUID.randomUUID();
    EntityManager em;Query partsQuery;CustomerPrepaymentQueryService summaries;ReceiptOrderSourceAccess orderSources;
    CurrentStaffAuthorityPort staff;SalesOrderCollectionPreviewService service;
    CustomerPrepaymentContracts.SalesOrderMoneySummary summary;
    @BeforeEach void setup(){
        em=mock(EntityManager.class);partsQuery=query();
        summaries=mock(CustomerPrepaymentQueryService.class);staff=mock(CurrentStaffAuthorityPort.class);
        orderSources=mock(ReceiptOrderSourceAccess.class);
        when(orderSources.require(order)).thenReturn(new ReceiptOrderSourceAccess.Source(order,client,currency,(short)1,false,false,"XD-TEST"));
        when(staff.currentStaffPermissions()).thenReturn(Set.of("customer_prepayment:view","finance:view:all"));
        when(em.createNativeQuery(anyString())).thenReturn(partsQuery);
        when(partsQuery.getResultList()).thenReturn(List.of());
        summary=mock(CustomerPrepaymentContracts.SalesOrderMoneySummary.class);
        when(summary.clientId()).thenReturn(client);when(summary.currencyId()).thenReturn(currency);
        when(summary.orderBillNo()).thenReturn("XD-TEST");when(summary.positionComplete()).thenReturn(true);
        when(summary.plannedRemainingOriginal()).thenReturn("100");
        when(summaries.salesOrderSummary(order)).thenReturn(summary);
        service=new SalesOrderCollectionPreviewService(em,summaries,orderSources,staff);
    }
    @Test void optionalOrderAttributionRequiresTheChosenShipmentBatchAndNeverSplitsAcrossTwoAr(){
        UUID first=UUID.randomUUID(),second=UUID.randomUUID();
        when(partsQuery.getResultList()).thenReturn(List.of(new Object[]{first,"AR1","XC1",new BigDecimal("30.123456789012345678901234"),false},
                new Object[]{second,"AR2","XC2",new BigDecimal("50"),false}));
        assertThatThrownBy(()->service.preview(order,new BigDecimal("20"))).hasMessageContaining("不能自动跨批");
        var result=service.preview(order,new BigDecimal("20.123456789012345678901234"),second);
        assertThat(result.receiptKind()).isEqualTo("AR_SETTLEMENT");
        assertThat(result.items()).singleElement().satisfies(part->{
            assertThat(part.ledgerId()).isEqualTo(second);
            assertThat(new BigDecimal(part.amountOriginal())).isEqualByComparingTo("20.123456789012345678901234");
        });
        assertThatThrownBy(()->service.preview(order,BigDecimal.ONE,UUID.randomUUID())).hasMessageContaining("不属于");
    }
    @Test void settledOrderCannotSilentlyAcceptAnotherAdvance(){
        when(summary.plannedRemainingOriginal()).thenReturn("0");
        assertThatThrownBy(()->service.preview(order,BigDecimal.ONE)).isInstanceOf(ApiException.class).hasMessageContaining("已无待收金额");
    }
    @Test void zeroSumCannotHideAnOverusedSource(){
        when(partsQuery.getResultList()).thenReturn(List.of(new Object[]{UUID.randomUUID(),"A","A",new BigDecimal("-1"),true},new Object[]{UUID.randomUUID(),"B","B",BigDecimal.ONE,false}));
        assertThatThrownBy(()->service.preview(order,BigDecimal.ONE)).isInstanceOf(ApiException.class).hasMessageContaining("超额使用");
    }
    @Test void positiveLedgerTotalCannotHideOneNegativeSourceWithinThatLedger(){
        when(partsQuery.getResultList()).thenReturn(List.<Object[]>of(new Object[]{UUID.randomUUID(),"A","A",BigDecimal.TEN,true}));
        assertThatThrownBy(()->service.preview(order,BigDecimal.ONE)).hasMessageContaining("超额使用");
    }
    @Test void noFormalArCreatesBoundAdvanceOnlyWithinNetOutstandingAndWithItsOwnPermission(){
        var value=service.preview(order,new BigDecimal("80"));
        assertThat(value.receiptKind()).isEqualTo("CUSTOMER_PREPAYMENT");assertThat(value.salesOrderId()).isEqualTo(order);
        assertThatThrownBy(()->service.preview(order,new BigDecimal("100.0001"))).hasMessageContaining("超过本订单当前待收");
        when(staff.currentStaffPermissions()).thenReturn(Set.of("finance_receipt:create","sales_order:view"));
        assertThatThrownBy(()->service.preview(order,BigDecimal.ONE)).hasMessageContaining("登记订单预收需要");
    }
    @Test void normalCollectionClerkCanPreviewVisibleOrderArWithoutCustomerGlobalAdvancePermission(){
        when(staff.currentStaffPermissions()).thenReturn(Set.of("finance_receipt:create","sales_order:view"));
        when(partsQuery.getResultList()).thenReturn(List.<Object[]>of(new Object[]{UUID.randomUUID(),"A","A",BigDecimal.TEN,false}));
        assertThat(service.preview(order,BigDecimal.ONE).receiptKind()).isEqualTo("AR_SETTLEMENT");
        assertThatThrownBy(()->service.preview(order,new BigDecimal("11"))).hasMessageContaining("不能把余额分给其他订单");
    }
    @Test void sourceScopeDenialDoesNotReadFinanceSummary(){
        doThrow(new ApiException(com.uten.imp.common.web.ErrorCode.NOT_FOUND,"订货单不存在或无权引用")).when(orderSources).require(order);
        assertThatThrownBy(()->service.preview(order,BigDecimal.ONE)).hasMessageContaining("无权引用");
        verifyNoInteractions(summaries);
    }
    static Query query(){Query q=mock(Query.class);when(q.setParameter(anyString(),any())).thenReturn(q);return q;}
}
