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
        Set<String> grouped = Set.of("balanceSheet", "profitAnnual", "profitMonthly", "adminExpense", "operatingPl", "operatingPlPage");
        int found = 0;
        for (var method : GlReportService.class.getDeclaredMethods()) {
            Transactional tx = method.getAnnotation(Transactional.class);
            if (grouped.contains(method.getName())) {
                found++;
                assertThat(java.lang.reflect.Modifier.isPublic(method.getModifiers())).isTrue();
                Transactional snapshot = java.util.Objects.requireNonNull(
                        tx, "Missing @Transactional on grouped report " + method.getName());
                assertThat(snapshot.readOnly()).isTrue();
                assertThat(snapshot.isolation()).isEqualTo(Isolation.REPEATABLE_READ);
                assertThat(snapshot.propagation()).isEqualTo(Propagation.REQUIRES_NEW);
            } else if (tx != null) {
                assertThat(tx.isolation()).isIn(Isolation.DEFAULT,Isolation.REPEATABLE_READ);
                assertThat(tx.propagation()).isEqualTo(Propagation.REQUIRED);
            }
        }
        assertThat(found).isEqualTo(14); // Both original and typed overloads retain the same snapshot boundary;
        // 14 = 11 + finance reproduction batch's profitAnnual(int,int), profitAnnual(int,int,options), adminExpense(int,int,options).
    }
    @Test
    void balanceSheetConsumesAllocatedFactsAndUsesOpeningAndClosingSnapshots() {
        EntityManager em = statementQueries("BALANCE", List.<Object[]>of(
                new Object[]{"BS_18",1,new BigDecimal("100000")},
                new Object[]{"BS_19",1,new BigDecimal("20000")},
                new Object[]{"BS_48",1,new BigDecimal("100000")},
                new Object[]{"__PL",1,new BigDecimal("-20000")}));
        var report = new GlReportService(em,mock(GlReportLineSource.class),
                com.uten.imp.support.FinanceReportTestAccess.company()).balanceSheet(LocalDate.of(2032,6,30));
        assertThat(report.rows()).hasSize(53);
        assertAmount(report.rows(),"资产总计","periodEnd","80000");
        assertAmount(report.rows(),"固定资产账面价值","periodEnd","80000");
        assertAmount(report.rows(),"资产总计","yearStart","0");
    }

    @Test
    void profitMonthlyIncludesNonOperatingExpensesAndTaxAndKeepsYearToDate() {
        EntityManager em = statementQueries("PROFIT",List.<Object[]>of(
                new Object[]{"PL_1",1,new BigDecimal("100")},new Object[]{"PL_1",2,new BigDecimal("110")},
                new Object[]{"PL_2",2,new BigDecimal("40")},new Object[]{"PL_24",2,new BigDecimal("5")},
                new Object[]{"PL_31",2,new BigDecimal("7")}));
        var report=new GlReportService(em,mock(GlReportLineSource.class),
                com.uten.imp.support.FinanceReportTestAccess.company()).profitMonthly(2032,2);
        assertThat(report.rows()).hasSize(20);
        String originalLabel=FinancialStatementCatalog.lines("PROFIT").stream().filter(line->line.key().equals("PL_32")).findFirst().orElseThrow().label();
        assertAmount(report.rows(),originalLabel,"monthAmount","58");
        assertAmount(report.rows(),originalLabel,"yearAmount","158");
    }

    private static EntityManager statementQueries(String sheet,List<Object[]> amounts) {
        EntityManager em=mock(EntityManager.class);
        Query scope=mock(Query.class),conflicts=mock(Query.class),metadata=mock(Query.class),facts=mock(Query.class);
        when(scope.getResultList()).thenReturn(List.of());when(conflicts.getResultList()).thenReturn(List.of());
        List<Object[]> configuration=FinancialStatementCatalog.lines(sheet).stream()
                .filter(FinancialStatementCatalog.Line::direct).map(l->new Object[]{l.key(),false}).toList();
        when(metadata.getResultList()).thenReturn(configuration);when(facts.getResultList()).thenReturn(amounts);
        when(facts.setParameter(anyString(),org.mockito.ArgumentMatchers.any())).thenReturn(facts);
        when(em.createNativeQuery(anyString())).thenReturn(scope,conflicts,metadata,facts);
        return em;
    }

    @Test
    void ambiguousCrossGroupRoleConfigurationStopsBeforeReadingFinancialAmounts() {
        EntityManager em = mock(EntityManager.class);
        Query conflict = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(conflict);
        when(conflict.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{"SK000200", "冲突科目", "BANK,RECEIVABLES"}));
        GlReportLineSource lines = mock(GlReportLineSource.class);
        assertThatThrownBy(() -> new GlReportService(em, lines,com.uten.imp.support.FinanceReportTestAccess.company()).balanceSheet(LocalDate.of(2032, 6, 30)))
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
