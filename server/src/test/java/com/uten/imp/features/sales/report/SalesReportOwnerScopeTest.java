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
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.math.BigDecimal;
import java.util.LinkedHashMap;
import com.uten.imp.common.report.ReportTotal;
import com.uten.imp.common.report.ReportTotalGroup;
import org.springframework.test.util.ReflectionTestUtils;

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
    void hiddenPricesCannotLeakThroughDecimalTextOrLocalAndOriginalTotals() {
        when(priceMasker.canView()).thenReturn(false);
        Map<String, Object> row = new LinkedHashMap<>(Map.of(
                "amount", new BigDecimal("37.28"), "amountExact", "37.2800",
                "billedLocalAmount", new BigDecimal("260.96"), "billedLocalAmountExact", "260.9600"));
        var group = List.of(new ReportTotalGroup("美金", new BigDecimal("37.28")));
        var response = new ReportTableResponse(List.of(), List.of(row), Map.of(), 1, 50, 1, 1,
                List.of(new ReportTotal("amount", "金额", "money", "currencyCode", group),
                        new ReportTotal("billedLocalAmount", "已出货人民币", "money", null, group),
                        new ReportTotal("qty", "数量", "number", "unitName", group)));
        ReportTableResponse masked = ReflectionTestUtils.invokeMethod(service(), "maskOrderPricesIfNeeded", response);
        org.junit.jupiter.api.Assertions.assertNotNull(masked);
        row.values().forEach(org.junit.jupiter.api.Assertions::assertNull);
        org.junit.jupiter.api.Assertions.assertEquals(List.of("qty"),
                masked.totals().stream().map(ReportTotal::key).toList());
    }

    @Test
    void scopedMonthlyReportUsesOwnerDimensionInMaterializedView() {
        UUID owner = UUID.randomUUID();
        OwnerVisibility.OwnerScope scope =
                new OwnerVisibility.OwnerScope(false, Set.of(owner));
        when(accessPolicy.scope()).thenReturn(scope);
        // 物化视图里空归属存成 NIL 哨兵，哨兵永远不在可见归属人里，只对全量范围可见。
        when(accessPolicy.nativeReadScope("owner_employee_id", "salesOwners", scope))
                .thenReturn(new SalesDocumentAccessPolicy.NativeReadScope(
                        "owner_employee_id IN (:salesOwners)",
                        "salesOwners",
                        Set.of(owner)));
        Query query = emptyQuery();
        when(em.createNativeQuery(anyString())).thenReturn(query);

        service().monthly(null, null, null, null, null, 200);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertTrue(sql.getValue().contains("FROM sales_monthly_mv"));
        assertTrue(sql.getValue().contains("owner_employee_id IN (:salesOwners)"));
        assertTrue(sql.getValue().contains("currency_id"));
        assertTrue(sql.getValue().contains("doc_type = 'ORDER' THEN amt_original"));
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
                        "o.owner_employee_id IN (:salesOwners)",
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
        assertTrue(sql.getValue().contains("o.currency_id"));
        assertTrue(sql.getValue().contains("i.amount_original"));
        assertFalse(sql.getValue().contains("sales_order_pending_v"));
        verify(query).setParameter("salesOwners", Set.of(owner));
    }

    @Test
    void orderReportsUseOriginalAmountsAndKeepSameClientCurrenciesSeparate() {
        when(accessPolicy.nativeReadScope("o.owner_employee_id", "salesOwners"))
                .thenReturn(new SalesDocumentAccessPolicy.NativeReadScope(
                        "1=1", null, Set.of()));
        Query query = emptyQuery();
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(priceMasker.canView()).thenReturn(true);
        UUID currencyId = UUID.randomUUID();

        service().orderDetail(null, null, currencyId, null, null, null, null,
                Map.of(), 1, 50, null, null);
        ReportTableResponse summary = service().orderSummary(
                null, null, null, null, null, null,
                Map.of(), 1, 50, null, null);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, org.mockito.Mockito.atLeastOnce()).createNativeQuery(sql.capture());
        String allSql = String.join("\n", sql.getAllValues());
        assertTrue(allSql.contains("o.total_original AS \"totalAmount\""));
        assertTrue(allSql.contains("i.amount_original AS \"amount\""));
        assertTrue(allSql.contains("SUM(amount_original) END AS amount"));
        assertTrue(allSql.contains("FILTER(WHERE amount_original IS NULL)>0"));
        assertTrue(allSql.contains("GROUP BY o.client_id, o.currency_id"));
        assertTrue(allSql.contains("o.currency_id=:currencyId"));
        assertTrue(allSql.contains("o.currency_id AS \"__currencyId\""));
        assertTrue(allSql.contains("t.\"__clientId\", t.\"__currencyId\""));
        assertTrue(allSql.contains("BTRIM(currency.name)"));
        assertTrue(allSql.contains("E'USD' THEN E'美金'"));
        assertFalse(allSql.contains("currency.code AS \"currencyCode\""));
        assertTrue(allSql.contains("shipment.warehouse_work_status = 'SHIPPED'"));
        assertTrue(allSql.contains("SUM(shipped.amount_local)"));
        assertTrue(summary.columns().stream().anyMatch(column ->
                "billedLocalTotal".equals(column.key()) && "元".equals(column.unitLabel())));
        assertFalse(allSql.contains("o.total_local AS \"totalAmount\""));
        assertFalse(allSql.contains("i.amount_local AS \"amount\""));
        // Hidden drilldown metadata lives in each row map; execute intentionally
        // omits "__" keys from the visible column list.
        assertFalse(summary.columns().stream()
                .anyMatch(column -> "__currencyId".equals(column.key())));
        verify(query, org.mockito.Mockito.atLeastOnce())
                .setParameter("currencyId", currencyId);
    }

    private SalesReportService service() {
        return new SalesReportService(em, settings, priceMasker, accessPolicy);
    }

    private Query emptyQuery() {
        Query query = org.mockito.Mockito.mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        org.mockito.Mockito.lenient().when(query.getSingleResult()).thenReturn(0L);
        return query;
    }
}
