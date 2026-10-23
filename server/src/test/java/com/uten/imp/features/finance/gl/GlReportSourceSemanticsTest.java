package com.uten.imp.features.finance.gl;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Propagation;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.times;

/** Fixed report arithmetic and configured row bindings remain independent of current display codes. */
class GlReportSourceSemanticsTest {
    @Test
    void groupedReportProxyEntrypointsHaveTheirOwnRepeatableReadSnapshotIncludingExportCalls() {
        Set<String> grouped = Set.of("balanceSheet", "profitAnnual", "profitMonthly", "adminExpense", "operatingPl");
        int found = 0;
        for (var method : GlReportService.class.getDeclaredMethods()) {
            Transactional tx = method.getAnnotation(Transactional.class);
            if (grouped.contains(method.getName())) {
                found++;
                assertThat(java.lang.reflect.Modifier.isPublic(method.getModifiers())).isTrue();
                assertThat(tx).isNotNull();
                assertThat(tx.readOnly()).isTrue();
                assertThat(tx.isolation()).isEqualTo(Isolation.REPEATABLE_READ);
                assertThat(tx.propagation()).isEqualTo(Propagation.REQUIRES_NEW);
            } else if (tx != null) {
                assertThat(tx.isolation()).isEqualTo(Isolation.DEFAULT);
                assertThat(tx.propagation()).isEqualTo(Propagation.REQUIRED);
            }
        }
        assertThat(found).isEqualTo(grouped.size());
    }
    @Test
    void balanceSheetConsumesQualifiedRootKeysAndPreservesSignsAndProfitCarryForward() {
        EntityManager em = mock(EntityManager.class);
        Query roots = mock(Query.class);
        Query profit = mock(Query.class);
        Query scope = mock(Query.class);
        when(scope.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(scope, roots, roots, profit, profit);
        List<Object[]> rows = new ArrayList<>();
        int amount = 1;
        for (GlReportSourceScopes.Root root : GlReportSourceScopes.Root.values()) {
            rows.add(new Object[]{root.name(), BigDecimal.valueOf(amount++)});
        }
        when(roots.getResultList()).thenReturn(rows);
        when(profit.getSingleResult()).thenReturn(new BigDecimal("7"));

        var report = new GlReportService(em, mock(GlReportLineSource.class))
                .balanceSheet(LocalDate.of(2032, 6, 30));
        assertAmount(report.rows(), "货币资金", "periodEnd", "3");
        assertAmount(report.rows(), "资产总计", "periodEnd", "36");
        assertAmount(report.rows(), "流动负债合计", "periodEnd", "42");
        assertAmount(report.rows(), "未分配利润", "periodEnd", "21");
        assertAmount(report.rows(), "所有者权益合计", "periodEnd", "34");
        verify(roots).setParameter("d", LocalDate.of(2032, 6, 30));
        verify(roots).setParameter("d", LocalDate.of(2031, 12, 31));
    }

    @Test
    void profitRowsKeepExplicitExpenseBindingsAndSourceScopedRevenueSeparate() {
        EntityManager em = mock(EntityManager.class);
        Query income = queryWithMonth("110");
        Query cost = queryWithMonth("40");
        Query nonOperating = queryWithMonth("5");
        Query scope = mock(Query.class);
        when(scope.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(scope, income, cost, nonOperating);
        GlReportLineSource lines = mock(GlReportLineSource.class);
        List<String> keys = List.of("PL_TAX", "SALES_FEE", "PL_FINANCE");
        LocalDate from = LocalDate.of(2032, 1, 1), to = LocalDate.of(2032, 12, 31);
        when(lines.bindings(keys)).thenReturn(new GlReportLineSource.Bindings(Map.of(
                "PL_TAX", List.of("configured tax"), "SALES_FEE", List.of("configured sales"),
                "PL_FINANCE", List.of("configured finance"))));
        when(lines.styleMonthly(keys, "EXPENSE", from, to)).thenReturn(Map.of(
                "PL_TAX", months("2"), "SALES_FEE", months("3"), "PL_FINANCE", months("4")));
        when(lines.adminMonthly(keys, from, to)).thenReturn(months("12"));
        var report = new GlReportService(em, lines).profitMonthly(2032, 2);
        assertAmount(report.rows(), "一、营业收入", "monthAmount", "110");
        assertAmount(report.rows(), "管理费用", "monthAmount", "12");
        assertAmount(report.rows(), "销售费用", "monthAmount", "3");
        assertAmount(report.rows(), "四、净利润", "monthAmount", "54");
        assertAmount(report.rows(), "四、净利润", "yearAmount", "54");
        verify(income).setParameter("cat", "INCOME");
        verify(cost).setParameter("cat", "EXPENSE");
        verify(nonOperating).setParameter("cat", "INCOME");
    }

    @Test
    void ambiguousCrossGroupRoleConfigurationStopsBeforeReadingFinancialAmounts() {
        EntityManager em = mock(EntityManager.class);
        Query conflict = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(conflict);
        when(conflict.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{"SK000200", "冲突科目", "BANK,RECEIVABLES"}));
        GlReportLineSource lines = mock(GlReportLineSource.class);
        assertThatThrownBy(() -> new GlReportService(em, lines).balanceSheet(LocalDate.of(2032, 6, 30)))
                .isInstanceOfSatisfying(ApiException.class, failure -> {
                    assertThat(failure.getCode()).isEqualTo(ErrorCode.CONFLICT);
                    assertThat(failure.getMessage()).contains("SK000200", "冲突科目", "银行存款", "应收账款");
                });
        verify(em, times(1)).createNativeQuery(anyString());
        verifyNoInteractions(lines);
    }

    private static Query queryWithMonth(String amount) {
        Query query = mock(Query.class);
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[]{2, new BigDecimal(amount)}));
        return query;
    }

    private static BigDecimal[] months(String amount) {
        BigDecimal[] result = new BigDecimal[13];
        result[2] = new BigDecimal(amount);
        return result;
    }

    private static void assertAmount(List<Map<String, Object>> rows, String label, String column, String expected) {
        Map<String, Object> row = rows.stream().filter(value -> label.equals(value.get("item")))
                .findFirst().orElseThrow();
        assertThat((BigDecimal) row.get(column)).isEqualByComparingTo(expected);
    }
}
