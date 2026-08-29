package com.uten.imp.features.finance.report;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.asset.FixedAssetService;
import com.uten.imp.features.finance.cost.FinanceCostService;
import com.uten.imp.features.finance.gl.GlReportService;
import com.uten.imp.features.finance.statement.FinanceStatementService;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.sql.Date;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class FinanceReportPartyStatementTest {

    @Test
    void dateRangeCarriesPriorFactsIntoOpeningBalanceButOnlyReturnsInRangeRows() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.<Object[]>of(
                row(LocalDate.of(2026, 1, 5), "AR-OLD", "100", "700", "0", "0", "USD"),
                row(LocalDate.of(2026, 2, 10), "SK-NEW", "0", "0", "30", "210", "USD")));

        FinanceReportService service = new FinanceReportService(
                em,
                unrestrictedAccess(),
                mock(SystemSettingsService.class),
                mock(FinanceStatementService.class),
                mock(FinanceCostService.class),
                mock(GlReportService.class),
                mock(FixedAssetService.class));

        ReportTableResponse result = service.partyStatementFlow(
                UUID.randomUUID(), "AR",
                LocalDate.of(2026, 2, 1), LocalDate.of(2026, 2, 28),
                1, 50);

        assertThat(result.rows()).hasSize(1);
        Map<String, Object> row = result.rows().getFirst();
        assertThat(row.get("refNo")).isEqualTo("SK-NEW");
        assertThat((BigDecimal) row.get("balanceOriginal")).isEqualByComparingTo("70");
        assertThat((BigDecimal) row.get("balanceLocal")).isEqualByComparingTo("490");
        verify(query, never()).setParameter("from", LocalDate.of(2026, 2, 1));
    }

    @Test
    void supplierPayableStatementSeparatesCompanyScopePredicateFromAnd() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        List<String> sqlStatements = new ArrayList<>();
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            sqlStatements.add(invocation.getArgument(0));
            return query;
        });

        service(em).partyStatementFlow(
                UUID.randomUUID(), "AP", null, null, 1, 50);

        assertThat(sqlStatements).singleElement().satisfies(sql -> {
            String compact = sql.replaceAll("\\s+", " ").trim();
            assertThat(compact)
                    .contains("AND payment.supplier_id IS NOT NULL AND 1=1")
                    .doesNotContain("AND1=1");
        });
    }

    @Test
    void accountStatementFiltersDisplayRowsWithoutDroppingFactsFromRunningBalance() {
        EntityManager em = mock(EntityManager.class);
        Query rowsQuery = mock(Query.class);
        when(rowsQuery.setParameter(anyString(), any())).thenReturn(rowsQuery);
        when(rowsQuery.getResultList()).thenReturn(List.<Object[]>of(
                accountRow(LocalDate.of(2026, 2, 5), "TARGET-1", "0", "20", "130", "shown", 2L, 2L),
                accountRow(LocalDate.of(2026, 2, 7), "TARGET-2", "0", "5", "135", "shown", 4L, 2L)));
        when(em.createNativeQuery(anyString())).thenReturn(rowsQuery);

        ReportTableResponse result = service(em).accountStatement(
                UUID.randomUUID(), LocalDate.of(2026, 2, 1),
                LocalDate.of(2026, 2, 28), "target", 1, 50);

        assertThat(result.rows()).extracting(row -> row.get("billNo"))
                .containsExactly("TARGET-1", "TARGET-2");
        assertThat((BigDecimal) result.rows().get(0).get("balance")).isEqualByComparingTo("130");
        assertThat((BigDecimal) result.rows().get(1).get("balance")).isEqualByComparingTo("135");
        assertThat(result.rows().getFirst().get("balanceText")).isEqualTo("130");
        verify(rowsQuery).setParameter(eq("toExclusive"), any());
        verify(em, org.mockito.Mockito.atLeastOnce()).createNativeQuery(argThat(sql ->
                sql.contains("AT TIME ZONE 'Asia/Shanghai'")
                        && sql.contains("opening.amount+SUM(flow.in_amount-flow.out_amount) OVER")
                        && sql.contains("FROM windowed")
                        && sql.contains("WHERE CAST(:keyword AS text) IS NULL")
                        && sql.contains("ORDER BY sort_bill_date,sort_posting_seq")));
    }

    @Test
    void financeDocumentPartyFiltersAndOrderPlanUseOriginalCurrencyFacts() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        List<String> sqlStatements = new ArrayList<>();
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        when(query.getSingleResult()).thenReturn(0L);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            sqlStatements.add(invocation.getArgument(0));
            return query;
        });
        FinanceReportService service = service(em);

        service.receiptSummary(null, UUID.randomUUID(), null,
                null, null, null, Map.of(), 1, 50, null, null);
        service.paymentSummary(null, UUID.randomUUID(), null,
                null, null, null, Map.of(), 1, 50, null, null);
        ReportTableResponse orderPlan = service.salesOrderReceivablePlan(null, null, null, null,
                null, 1, 50, null, null);

        String sql = String.join("\n", sqlStatements);
        String orderPlanSql = String.join("\n", sqlStatements.stream()
                .filter(statement -> statement.contains("FROM sales_orders sales_order"))
                .toList());
        assertThat(sql)
                .contains("t.client_id=:pid")
                .contains("t.supplier_id=:pid")
                .doesNotContain("t.client_id=:pid OR t.supplier_id=:pid");
        assertThat(orderPlan.columns()).extracting(ReportColumn::key)
                .contains("currencyCode", "orderOriginal", "recognizedOriginal", "expectedOriginal")
                .doesNotContain("orderLocal", "recognizedLocal", "expectedLocal");
        assertThat(orderPlanSql)
                .contains("source.amount_original")
                .doesNotContain("source.amount_local", "currency.exchange_rate",
                        "汇率待财务维护", "expectedLocal");
    }

    @Test
    void arApDetailUsesChineseSettlementLabelsAndKeepsArApMetadataForBothDirections() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        List<String> sqlStatements = new ArrayList<>();
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        when(query.getSingleResult()).thenReturn(0L);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            sqlStatements.add(invocation.getArgument(0));
            return query;
        });
        FinanceReportService service = service(em);

        ReportTableResponse ar = service.arApDetail(
                "AR", null, null, null, null, null, null,
                Map.of(), 1, 50, null, null);
        ReportTableResponse ap = service.arApDetail(
                "AP", null, null, null, null, null, null,
                Map.of(), 1, 50, null, null);

        assertThat(labelFor(ar, "dueDate")).isEqualTo("收款限期");
        assertThat(labelFor(ap, "dueDate")).isEqualTo("付款限期");
        assertThat(labelFor(ar, "settlementStyle")).isEqualTo("结帐方式");
        assertThat(labelFor(ap, "settlementStyle")).isEqualTo("结帐方式");
        assertThat(labelFor(ar, "remark")).isEqualTo("备注");
        assertThat(labelFor(ap, "remark")).isEqualTo("备注");

        assertThat(String.join("\n", sqlStatements))
                .contains("CASE l.settlement_style_legacy")
                .contains("WHEN 1 THEN '现金'", "WHEN 2 THEN '提货'", "WHEN 3 THEN '代付'")
                .contains("WHEN 4 THEN '支票'", "WHEN 6 THEN '月结'", "WHEN 7 THEN '垫付'")
                .contains("WHEN 8 THEN '汇款'", "WHEN 10 THEN '代收'", "ELSE '未设置'")
                .doesNotContain("CAST(l.settlement_style_legacy AS text)");
    }

    private static FinanceReportService service(EntityManager em) {
        return new FinanceReportService(
                em,
                unrestrictedAccess(),
                mock(SystemSettingsService.class),
                mock(FinanceStatementService.class),
                mock(FinanceCostService.class),
                mock(GlReportService.class),
                mock(FixedAssetService.class));
    }

    private static FinanceDocumentAccessPolicy unrestrictedAccess() {
        FinanceDocumentAccessPolicy access = mock(FinanceDocumentAccessPolicy.class);
        OwnerScope ownerScope = new OwnerScope(true, Set.of());
        when(access.scope()).thenReturn(ownerScope);
        when(access.hasAuthority(anyString())).thenReturn(true);
        when(access.nativeReadScope(anyString(), anyString(), eq(ownerScope)))
                .thenReturn(new NativeReadScope("1=1", null, Set.of()));
        return access;
    }

    private static String labelFor(ReportTableResponse response, String key) {
        return response.columns().stream()
                .filter(column -> key.equals(column.key()))
                .findFirst()
                .orElseThrow()
                .label();
    }

    private static Object[] row(LocalDate date, String billNo,
                                String postedOriginal, String postedLocal,
                                String settledOriginal, String settledLocal,
                                String currency) {
        return new Object[]{
                Date.valueOf(date), billNo,
                new BigDecimal(postedOriginal), new BigDecimal("7"), new BigDecimal(postedLocal),
                new BigDecimal(settledOriginal), new BigDecimal("7"), new BigDecimal(settledLocal),
                "测试", currency, null, UUID.nameUUIDFromBytes(currency.getBytes())
        };
    }

    private static Object[] accountRow(LocalDate date, String billNo,
                                       String inAmount, String outAmount, String balance,
                                       String remark, long postingSeq, long totalCount) {
        return new Object[]{
                Date.valueOf(date), billNo, "", remark, "客户", "销售收款", null,
                new BigDecimal(inAmount), new BigDecimal(outAmount),
                new BigDecimal(balance), "RECEIPT", UUID.nameUUIDFromBytes(billNo.getBytes()),
                "POSTING", null, UUID.nameUUIDFromBytes((billNo + "-entry").getBytes()),
                postingSeq, totalCount
        };
    }
}
