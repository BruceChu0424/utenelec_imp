package com.uten.imp.features.sales.order;

import com.uten.imp.common.web.TableFacets;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Selector prices obey the same permission authority as list/detail/report/export. */
@ExtendWith(MockitoExtension.class)
class SalesOrderReadProjectionSecurityTest {
    @Mock EntityManager em;
    @Mock SalesDocumentAccessPolicy accessPolicy;
    @Mock SalesPriceMasker priceMasker;
    @InjectMocks SalesOrderService service;
    private final UUID owner = UUID.randomUUID();
    private final OwnerScope scope = new OwnerScope(false, Set.of(owner));
    private final NativeReadScope nativeScope = new NativeReadScope("o.owner_employee_id IN (:salesOwners)", "salesOwners", Set.of(owner));

    @ParameterizedTest @ValueSource(booleans = {false, true})
    void shippableSelectorMasksPriceWithoutChangingQuantitySourceOrWriteEligibility(boolean canViewPrice) {
        Query query = mock(Query.class, RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(accessPolicy.scope()).thenReturn(scope);
        when(accessPolicy.nativeReadScope("o.owner_employee_id", "salesOwners", scope)).thenReturn(nativeScope);
        when(accessPolicy.hasAuthority("sales_shipment:create")).thenReturn(true);
        when(accessPolicy.canWrite(owner, scope)).thenReturn(true);
        when(priceMasker.canView()).thenReturn(canViewPrice);
        UUID item = UUID.randomUUID(), order = UUID.randomUUID(), goods = UUID.randomUUID();
        BigDecimal rawPrice = new BigDecimal("123456789.1234");
        Object[] row = {item, order, "SO0001", UUID.randomUUID(), LocalDate.of(2026, 1, 1), goods,
                null, UUID.randomUUID(), new BigDecimal("1.25"), new BigDecimal("5.0001"),
                new BigDecimal("1.0001"), new BigDecimal("4.0000"), rawPrice, owner};
        when(query.getResultList()).thenReturn(java.util.Collections.singletonList(row));

        var result = service.shippableLines().getFirst();

        assertThat(result.orderItemId()).isEqualTo(item);
        assertThat(result.orderId()).isEqualTo(order);
        assertThat(result.goodsId()).isEqualTo(goods);
        assertThat(result.qty()).isEqualByComparingTo("5.0001");
        assertThat(result.shippedQty()).isEqualByComparingTo("1.0001");
        assertThat(result.reservedQty()).isEqualByComparingTo("4.0000");
        assertThat(result.unitRate()).isEqualByComparingTo("1.25");
        assertThat(result.writable()).isTrue();
        if (canViewPrice) assertThat(result.price()).isSameAs(rawPrice);
        else assertThat(result.price()).isNull();
        verify(query).setParameter("salesOwners", Set.of(owner));
        verify(em).createNativeQuery(argThat(sql -> sql.contains("o.finance_confirmed = true")
                && sql.contains("COALESCE(s.rejected,false) = false") && sql.endsWith(", i.id")));
    }

    @Test void orderReadPermissionDoesNotCreateShipmentWriteEligibility() {
        Query query = mock(Query.class, RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(accessPolicy.scope()).thenReturn(scope);
        when(accessPolicy.nativeReadScope("o.owner_employee_id", "salesOwners", scope)).thenReturn(nativeScope);
        Object[] row = new Object[14]; row[0] = UUID.randomUUID(); row[1] = UUID.randomUUID(); row[13] = owner;
        when(query.getResultList()).thenReturn(java.util.Collections.singletonList(row));
        assertThat(service.shippableLines().getFirst().writable()).isFalse();
        verify(accessPolicy, never()).canWrite(any(), any(OwnerScope.class));
    }

    @Test void progressBillNumberBucketsKeepScopeAndExactCountsWithinSharedBound() {
        Query query = mock(Query.class, RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(accessPolicy.nativeReadScope("o.owner_employee_id", "salesOwners")).thenReturn(nativeScope);
        when(query.getResultList()).thenReturn(List.of(new Object[]{"SO0001", 7L}, new Object[]{"SO0002", 2L}));

        var result = service.progressFacets("OPEN", "旧单", LocalDate.of(2001, 1, 1), LocalDate.of(2026, 1, 1));

        assertThat(result.get("billNo")).extracting(row -> row.get("value")).containsExactly("SO0001", "SO0002");
        assertThat(result.get("billNo")).extracting(row -> row.get("count")).containsExactly(7L, 2L);
        verify(query).setMaxResults(TableFacets.DEFAULT_LIMIT);
        verify(query).setParameter("salesOwners", Set.of(owner));
    }
}
