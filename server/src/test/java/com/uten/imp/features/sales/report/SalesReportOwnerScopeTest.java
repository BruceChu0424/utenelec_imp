package com.uten.imp.features.sales.report;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.order.SalesPriceMasker;
import com.uten.imp.security.OwnerVisibility;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class SalesReportOwnerScopeTest {

    @Mock private EntityManager em;
    @Mock private SystemSettingsService settings;
    @Mock private SalesPriceMasker priceMasker;
    @Mock private SalesDocumentAccessPolicy accessPolicy;

    @Test
    void scopedMonthlyReportUsesOwnerDimensionInMaterializedView() {
        UUID owner = UUID.randomUUID();
        UUID legacyOwner = new UUID(0L, 0L);
        OwnerVisibility.OwnerScope scope =
                new OwnerVisibility.OwnerScope(false, Set.of(owner));
        when(accessPolicy.scope()).thenReturn(scope);
        when(accessPolicy.nativeReadScopeWithLegacySentinel(
                "owner_employee_id", "salesOwners", legacyOwner, scope))
                .thenReturn(new SalesDocumentAccessPolicy.NativeReadScope(
                        "(owner_employee_id = '00000000-0000-0000-0000-000000000000'::uuid "
                                + "OR owner_employee_id IN (:salesOwners))",
                        "salesOwners",
                        Set.of(owner)));
        Query query = emptyQuery();
        when(em.createNativeQuery(anyString())).thenReturn(query);

        service().monthly(null, null, null, null, null, 200);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertTrue(sql.getValue().contains("FROM sales_monthly_mv"));
        assertTrue(sql.getValue().contains("owner_employee_id IN (:salesOwners)"));
        assertFalse(sql.getValue().contains("FROM sales_quote_items"));
        verify(query).setParameter("salesOwners", Set.of(owner));
    }

    @Test
    void scopedPendingReportReaggregatesOrdersWithOwnerPredicate() {
        UUID owner = UUID.randomUUID();
        OwnerVisibility.OwnerScope scope =
                new OwnerVisibility.OwnerScope(false, Set.of(owner));
        when(accessPolicy.scope()).thenReturn(scope);
        when(accessPolicy.nativeReadScope("o.owner_employee_id", "salesOwners", scope))
                .thenReturn(new SalesDocumentAccessPolicy.NativeReadScope(
                        "(o.owner_employee_id IS NULL OR o.owner_employee_id IN (:salesOwners))",
                        "salesOwners",
                        Set.of(owner)));
        Query query = emptyQuery();
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(priceMasker.canView()).thenReturn(true);

        service().pending(null, 200);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertTrue(sql.getValue().contains("JOIN sales_orders o"));
        assertTrue(sql.getValue().contains("o.owner_employee_id IN (:salesOwners)"));
        assertFalse(sql.getValue().contains("sales_order_pending_v"));
        verify(query).setParameter("salesOwners", Set.of(owner));
    }

    private SalesReportService service() {
        return new SalesReportService(em, settings, priceMasker, accessPolicy);
    }

    private Query emptyQuery() {
        Query query = org.mockito.Mockito.mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        return query;
    }
}
