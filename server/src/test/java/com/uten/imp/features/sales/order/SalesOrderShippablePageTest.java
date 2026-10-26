package com.uten.imp.features.sales.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.order.dto.ShippableLineFilter;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.util.Collections;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class SalesOrderShippablePageTest {
    @Mock EntityManager em;
    @Mock SalesDocumentAccessPolicy accessPolicy;
    @Mock SalesPriceMasker priceMasker;
    @InjectMocks SalesOrderService service;
    private final UUID writer = UUID.randomUUID(), readOnly = UUID.randomUUID();
    private final OwnerScope scope = new OwnerScope(false, Set.of(writer, readOnly), Set.of(writer));

    @Test void countAndRowsUseTheSameLiteralSearchClientAndSourcePredicateWithBoundedLongOffset() {
        scope(); Query count = query(), rows = query(); UUID client = UUID.randomUUID();
        when(em.createNativeQuery(anyString())).thenReturn(count, rows);
        when(count.getSingleResult()).thenReturn(205L);
        when(rows.getResultList()).thenReturn(Collections.singletonList(row(writer)));
        when(accessPolicy.hasAuthority("sales_shipment:create")).thenReturn(true);
        when(accessPolicy.canWrite(writer, scope)).thenReturn(true);

        var result = service.shippableLinesPage(new ShippableLineFilter("螺丝 A%_B", client), 2, 1000);

        assertThat(result.getPage()).isEqualTo(2); assertThat(result.getSize()).isEqualTo(100);
        assertThat(result.getTotal()).isEqualTo(205); assertThat(result.getTotalPages()).isEqualTo(3);
        assertThat(result.getItems().getFirst().price()).isNull();
        verify(rows).setParameter("shippableLimit", 100); verify(rows).setParameter("shippableOffset", 100L);
        for (Query query : List.of(count, rows)) {
            verify(query).setParameter("salesOwners", Set.of(writer, readOnly));
            verify(query).setParameter("shippableClientId", client);
            verify(query).setParameter("shippableKeyword", "螺丝 a%_b");
        }
        var sql = ArgumentCaptor.forClass(String.class); verify(em, times(2)).createNativeQuery(sql.capture());
        String rowSql = sql.getAllValues().get(1);
        String common = rowSql.substring(0, rowSql.indexOf(" ORDER BY o.client_id"));
        assertThat(sql.getAllValues().getFirst()).isEqualTo("SELECT COUNT(*) FROM (" + common + ") shippable_count");
        assertThat(rowSql).contains("POSITION(", "o.finance_confirmed = true", "fn_imported_business_document", ", i.id LIMIT :shippableLimit OFFSET :shippableOffset");
    }

    @Test void emptyNormalizesThePageWithoutLoadingRowsOrPrices() {
        scope(); Query count = query(); when(em.createNativeQuery(anyString())).thenReturn(count);
        when(count.getSingleResult()).thenReturn(0L);
        var result = service.shippableLinesPage(null, -10, 0);
        assertThat(result.getItems()).isEmpty(); assertThat(result.getPage()).isEqualTo(1); assertThat(result.getSize()).isEqualTo(1);
        verify(em).createNativeQuery(anyString()); verifyNoInteractions(priceMasker);
    }

    @Test void selectAllUsesOnlyWritableOwnersAndReturnsEveryLegalRow() {
        scope(); Query rows = query(); when(em.createNativeQuery(anyString())).thenReturn(rows);
        when(accessPolicy.hasAuthority("sales_shipment:create")).thenReturn(true);
        when(accessPolicy.canWrite(writer, scope)).thenReturn(true);
        when(rows.getResultList()).thenReturn(Collections.nCopies(500, row(writer)));
        var result = service.shippableLinesSelection(new ShippableLineFilter(null, null));
        assertThat(result.getItems()).hasSize(500).allSatisfy(line -> assertThat(line.writable()).isTrue());
        assertThat(result.getPage()).isEqualTo(1); assertThat(result.getSize()).isEqualTo(500);
        assertThat(result.getTotal()).isEqualTo(500); assertThat(result.getTotalPages()).isEqualTo(1);
        verify(rows).setMaxResults(501); verify(rows).setParameter("shippableWritableOwners", Set.of(writer));
        verify(em).createNativeQuery(argThat(sql -> sql.contains("o.owner_employee_id IS NOT NULL")
                && sql.contains("o.owner_employee_id IN (:shippableWritableOwners)")));
    }

    @Test void selectAllOverTheBusinessLimitRefusesTheWholeSelectionRatherThanReturningFiveHundred() {
        scope(); Query rows = query(); when(em.createNativeQuery(anyString())).thenReturn(rows);
        when(accessPolicy.hasAuthority("sales_shipment:create")).thenReturn(true);
        when(rows.getResultList()).thenReturn(Collections.nCopies(501, row(writer)));
        assertThatThrownBy(() -> service.shippableLinesSelection(null)).isInstanceOf(ApiException.class)
                .hasMessage("可发行超过单批500行，请按客户或关键词收窄后再全选");
        verify(rows).setMaxResults(501); verifyNoInteractions(priceMasker);
    }

    @Test void selectAllWithoutShipmentCreateDoesNotDiscoverOrReadAnyRows() {
        assertThat(service.shippableLinesSelection(null).getItems()).isEmpty();
        verifyNoInteractions(em, priceMasker); verify(accessPolicy, never()).scope();
    }

    @Test void legacyListIsBoundedAndRefusesAnOversizedResult() {
        scope(); Query rows = query(); when(em.createNativeQuery(anyString())).thenReturn(rows);
        when(rows.getResultList()).thenReturn(Collections.nCopies(501, row(writer)));
        assertThatThrownBy(service::shippableLines).isInstanceOf(ApiException.class).hasMessageContaining("分页选择");
        verify(rows).setMaxResults(501); verifyNoInteractions(priceMasker);
    }

    @Test void keywordLimitIsCheckedBeforeAnyDatabaseQuery() {
        when(accessPolicy.scope()).thenReturn(scope);
        assertThatThrownBy(() -> service.shippableLinesPage(new ShippableLineFilter("x".repeat(201), null), 1, 100))
                .isInstanceOf(ApiException.class).hasMessageContaining("200");
        verifyNoInteractions(em);
    }

    private void scope() {
        when(accessPolicy.scope()).thenReturn(scope);
        when(accessPolicy.nativeReadScope("o.owner_employee_id", "salesOwners", scope))
                .thenReturn(new NativeReadScope("o.owner_employee_id IN (:salesOwners)", "salesOwners", scope.visibleOwners()));
    }
    private static Query query() { return mock(Query.class, RETURNS_SELF); }
    private static Object[] row(UUID owner) {
        Object[] row = new Object[14]; row[0] = UUID.randomUUID(); row[1] = UUID.randomUUID();
        row[9] = new BigDecimal("1.0001"); row[11] = new BigDecimal("0.0001"); row[12] = new BigDecimal("10.0001"); row[13] = owner;
        return row;
    }
}
