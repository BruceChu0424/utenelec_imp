package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SalesDeliveryOrderClaimServiceTest {
    private final UUID component=UUID.randomUUID(),shipment=UUID.randomUUID(),orderItem=UUID.randomUUID(),
            goods=UUID.randomUUID(),unit=UUID.randomUUID(),warehouse=UUID.randomUUID(),request=UUID.randomUUID();

    @Test void allocationSubtractsBothGlobalClaimsAndTheActualWarehouseShare() {
        assertThat(SalesDeliveryOrderClaimService.availableClaim(n("10"),n("7"),n("4"),n("2"))).isEqualByComparingTo("5");
        assertThat(SalesDeliveryOrderClaimService.availableClaim(n("10"),n("7"),n("9"),BigDecimal.ZERO)).isEqualByComparingTo("1");
        assertThat(SalesDeliveryOrderClaimService.availableClaim(n("2"),n("7"),n("4"),BigDecimal.ZERO)).isZero();
    }
    @Test void adoptedWholeSourceConsumesItsActualRowCapAndExactMixedSourceRetainsItsOwnCredit() {
        assertThat(SalesDeliveryOrderClaimService.rowCredit(n(".0001"),n(".0001"),n(".06"),n(".001"),BigDecimal.ZERO,BigDecimal.ZERO,true))
                .isEqualByComparingTo(".06");
        assertThat(SalesDeliveryOrderClaimService.rowCredit(n(".0001"),n(".0001"),n(".1"),n(".001"),BigDecimal.ZERO,BigDecimal.ZERO,true))
                .isEqualByComparingTo(".1");
        assertThat(SalesDeliveryOrderClaimService.rowCredit(n(".0001"),n(".0002"),n(".2"),n(".001"),BigDecimal.ZERO,BigDecimal.ZERO,false))
                .isEqualByComparingTo(".1");
    }
    @Test void nonlinearPartialOrAmbiguousSourceAndInexactLinearPartialAreRejected() {
        assertThatThrownBy(()->SalesDeliveryOrderClaimService.rowCredit(n(".0001"),n(".0002"),n(".16"),n(".001"),BigDecimal.ZERO,BigDecimal.ZERO,true))
                .isInstanceOf(ApiException.class).hasMessageContaining("尾差");
        assertThatThrownBy(()->SalesDeliveryOrderClaimService.rowCredit(n(".0001"),n(".0001"),n(".06"),n(".001"),BigDecimal.ZERO,BigDecimal.ZERO,false))
                .isInstanceOf(ApiException.class).hasMessageContaining("多笔供给");
        assertThatThrownBy(()->SalesDeliveryOrderClaimService.rowCredit(n("1"),n("3"),n("1"),n("3"),BigDecimal.ZERO,BigDecimal.ZERO,true))
                .isInstanceOf(ApiException.class).hasMessageContaining("无损换算");
    }
    @Test void publicStockInAnotherWarehouseCannotReplaceTheOrdersExistingPrivateSource() {
        var em=mock(EntityManager.class);var stock=mock(StockService.class);var tx=mock(TxSessionVars.class);
        var source=query(Collections.singletonList(source("ASSEMBLED","[]")));
        var empty=query(List.of());List<String> writes=new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(call->{String sql=call.getArgument(0);
            if(sql.contains("FROM sales_shipment_delivery_components component"))return source;
            if(sql.contains("FROM stock_reservations reservation WHERE reservation.order_item_id"))return scalar("10");
            if(sql.contains("fn_stock_storage_movable"))return scalar("10");
            if(sql.contains("FROM stock_reservations")&&!sql.contains("FROM stock_reservations reservation"))return scalar("0");
            if(sql.contains("SELECT COALESCE(sum(active.quantity)"))return scalar("0");
            if(sql.stripLeading().startsWith("INSERT")||sql.stripLeading().startsWith("UPDATE"))writes.add(sql);
            return empty;});
        var service=new SalesDeliveryOrderClaimService(em,stock,tx);
        assertThatThrownBy(()->service.prepare(component,warehouse,n("2"),request)).isInstanceOf(ApiException.class)
                .hasMessageContaining("不能改用公共库存替代");
        assertThat(writes).isEmpty();
    }
    @Test void bomChildrenNeverClaimRootReservationsAndForeignIdentityIsRejected() {
        var em=mock(EntityManager.class);var stock=mock(StockService.class);var tx=mock(TxSessionVars.class);
        var source=query(Collections.singletonList(source("BOM","[]")));
        when(em.createNativeQuery(anyString())).thenReturn(source);
        var service=new SalesDeliveryOrderClaimService(em,stock,tx);
        service.prepare(component,warehouse,n("2"),request);verifyNoInteractions(stock);
        Object[] wrong=source("ASSEMBLED","[]");wrong[11]=UUID.randomUUID();
        when(source.getResultList()).thenReturn(Collections.singletonList(wrong));
        assertThatThrownBy(()->service.prepare(component,warehouse,n("2"),request)).isInstanceOf(ApiException.class)
                .hasMessageContaining("原销售订单");
        verify(source,never()).executeUpdate();
    }
    @Test void retryReturnsTheOriginalClaimWithoutReleasingOrDuplicatingAnyReservation() {
        var em=mock(EntityManager.class);var stock=mock(StockService.class);var tx=mock(TxSessionVars.class);
        var source=query(Collections.singletonList(source("ASSEMBLED","[]")));
        var prior=query(Collections.singletonList(new Object[]{warehouse,n("2")}));
        when(em.createNativeQuery(anyString())).thenAnswer(call->call.<String>getArgument(0).contains("sales_delivery_order_claim_requests")?prior:source);
        var service=new SalesDeliveryOrderClaimService(em,stock,tx);
        service.prepare(component,warehouse,n("2"),request);
        verify(source,never()).executeUpdate();verify(prior,never()).executeUpdate();
        assertThatThrownBy(()->service.prepare(component,UUID.randomUUID(),n("2"),request)).isInstanceOf(ApiException.class)
                .hasMessageContaining("同一认领请求");
    }
    @Test void actualConsumptionUpdatesOnlyTheOriginalConsumedCounterAndAppendsExactRowEvidence() {
        var em=mock(EntityManager.class);var stock=mock(StockService.class);var tx=mock(TxSessionVars.class);
        var source=query(Collections.singletonList(source("ASSEMBLED","[]")));
        UUID claim=UUID.randomUUID(),reservation=UUID.randomUUID();
        var active=query(Collections.singletonList(new Object[]{claim,reservation,warehouse,n("2"),n("2"),n("2"),BigDecimal.ZERO,BigDecimal.ONE,true}));
        var cumulative=query(Collections.singletonList(new Object[]{BigDecimal.ZERO,BigDecimal.ZERO}));
        Map<String,Query> writes=new LinkedHashMap<>();
        when(em.createNativeQuery(anyString())).thenAnswer(call->{String sql=call.getArgument(0);
            if(sql.contains("FROM sales_shipment_delivery_components component"))return source;
            if(sql.contains("FROM v_sales_delivery_order_claim_active"))return active;
            if(sql.contains("FROM sales_delivery_order_claim_row_events"))return cumulative;
            Query q=mock(Query.class,RETURNS_SELF);when(q.executeUpdate()).thenReturn(1);writes.put(sql,q);return q;});
        var service=new SalesDeliveryOrderClaimService(em,stock,tx);service.consume(component);
        String mutation=writes.keySet().stream().filter(sql->sql.contains("UPDATE stock_reservations")).findFirst().orElseThrow();
        assertThat(mutation).contains("SET consumed_qty=consumed_qty+:quantity")
                .doesNotContain("SET qty=","SET released_qty=","SET owner_type=",",qty=",",released_qty=",",owner_type=");
        verify(writes.get(mutation)).setParameter("id",reservation);verify(writes.get(mutation)).setParameter("quantity",n("2"));
        String rowEvent=writes.keySet().stream().filter(sql->sql.contains("INSERT INTO sales_delivery_order_claim_row_events")).findFirst().orElseThrow();
        verify(writes.get(rowEvent)).setParameter("row",n("2"));verify(writes.get(rowEvent)).setParameter("base",n("2"));
        assertThat(writes.keySet()).noneMatch(sql->sql.contains("INSERT INTO stock_reservations"));
    }
    private Object[] source(String mode,String path) {
        return new Object[]{component,shipment,orderItem,goods,null,unit,n("2"),BigDecimal.ONE,warehouse,path,mode,goods,null,unit,false,false};
    }
    private static Query query(List<Object[]> rows){var q=mock(Query.class,RETURNS_SELF);when(q.getResultList()).thenReturn(rows);return q;}
    private static Query scalar(String value){var q=mock(Query.class,RETURNS_SELF);when(q.getSingleResult()).thenReturn(n(value));return q;}
    private static BigDecimal n(String value){return new BigDecimal(value);}
}
