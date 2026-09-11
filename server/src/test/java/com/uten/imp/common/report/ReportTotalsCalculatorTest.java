package com.uten.imp.common.report;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 「表格下方合计」聚合器契约。
 *
 * <p>盯死两件最容易退化的事：
 * <ol>
 *   <li>合计覆盖<b>整个筛选后结果集</b>——派生表里绝不能出现 LIMIT/OFFSET；</li>
 *   <li>数量/金额<b>绝不跨单位、跨币种相加</b>——声明了分组列就必须 GROUP BY 它。</li>
 * </ol>
 */
class ReportTotalsCalculatorTest {

    // ==================== SQL 版（服务端分页的报表） ====================

    @Test
    void aggregateWrapsListQueryAndNeverPaginates() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);

        ReportTotalsCalculator.compute(
                em,
                "SELECT i.qty AS \"qty\", un.name AS \"unitName\"",
                "FROM items i JOIN units un ON un.id = i.unit_id",
                "WHERE i.is_deleted = false AND i.maker_id IN (:owners)",
                Map.of("owners", List.of(1)),
                List.of(new ReportTotalsCalculator.Spec("qty", "合计数量", "number", "unitName")));

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        org.mockito.Mockito.verify(em).createNativeQuery(sql.capture());
        String aggregate = sql.getValue();

        // 与列表同一段 SELECT/FROM/WHERE（含对象级授权谓词）——口径天生一致。
        assertThat(aggregate).contains("FROM (SELECT i.qty AS \"qty\", un.name AS \"unitName\" "
                + "FROM items i JOIN units un ON un.id = i.unit_id "
                + "WHERE i.is_deleted = false AND i.maker_id IN (:owners)) t");
        // 覆盖整个结果集：派生表里不带分页。
        assertThat(aggregate).doesNotContain("LIMIT").doesNotContain("OFFSET");
        // 按单位分组，绝不跨单位相加。
        assertThat(aggregate).contains("GROUP BY t.\"unitName\"");
        // 列表查询用的参数原样绑定到聚合查询（否则合计会比列表多算/少算）。
        org.mockito.Mockito.verify(query).setParameter("owners", List.of(1));
    }

    @Test
    void oneAggregateQueryPerGroupingDimensionRegardlessOfColumnCount() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);

        ReportTotalsCalculator.compute(
                em, "SELECT 1", "FROM t", "WHERE 1=1", Map.of(),
                List.of(
                        new ReportTotalsCalculator.Spec("qty", "合计数量", "number", "unitName"),
                        new ReportTotalsCalculator.Spec("returnedQty", "合计退货数量", "number", "unitName"),
                        new ReportTotalsCalculator.Spec("weight", "合计重量", "number", null)));

        // 3 个合计列、2 个分组维度 → 2 条聚合查询，不是 3 条（与列数无关，无 N+1）。
        org.mockito.Mockito.verify(em, org.mockito.Mockito.times(2)).createNativeQuery(anyString());
    }

    @Test
    void illegalColumnKeyIsDroppedInsteadOfConcatenatedIntoSql() {
        EntityManager em = mock(EntityManager.class);

        List<ReportTotal> totals = ReportTotalsCalculator.compute(
                em, "SELECT 1", "FROM t", "", Map.of(),
                List.of(new ReportTotalsCalculator.Spec("qty\"); DROP TABLE goods; --", "x", "number", null)));

        assertThat(totals).isEmpty();
        org.mockito.Mockito.verify(em, org.mockito.Mockito.never()).createNativeQuery(anyString());
    }

    // ==================== 内存版（Java 端分页的报表） ====================

    @Test
    void inMemoryTotalCoversEveryRowNotJustThePage() {
        // 50 行，但页面一次只显示 2 行：合计必须是 50 行的和。
        List<Map<String, Object>> all = new java.util.ArrayList<>();
        for (int i = 0; i < 50; i++) all.add(row("个", new BigDecimal("2")));

        List<ReportTotal> totals = ReportTotalsCalculator.computeFromRows(
                all, List.of(new ReportTotalsCalculator.Spec("qty", "合计数量", "number", "unitName")));

        assertThat(totals).singleElement().satisfies(total -> {
            assertThat(total.groups()).singleElement()
                    .satisfies(group -> assertThat(group.value()).isEqualByComparingTo("100"));
        });
    }

    @Test
    void inMemoryTotalKeepsUnitsApartAndPutsUnmaintainedUnitLast() {
        List<Map<String, Object>> all = List.of(
                row("箱", new BigDecimal("3")),
                row("个", new BigDecimal("10")),
                row(null, new BigDecimal("7")),
                row("个", new BigDecimal("5")));

        List<ReportTotal> totals = ReportTotalsCalculator.computeFromRows(
                all, List.of(new ReportTotalsCalculator.Spec("qty", "合计数量", "number", "unitName")));

        assertThat(totals).singleElement().satisfies(total -> {
            assertThat(total.groupKey()).isEqualTo("unitName");
            // 单位名排序稳定，「单位未维护」（null）恒排最后。
            assertThat(total.groups()).extracting(ReportTotalGroup::unit)
                    .containsExactly("个", "箱", null);
            assertThat(total.groups()).extracting(ReportTotalGroup::value)
                    .containsExactly(new BigDecimal("15"), new BigDecimal("3"), new BigDecimal("7"));
        });
    }

    @Test
    void inMemoryTotalIsOmittedEntirelyWhenNothingIsNumeric() {
        List<Map<String, Object>> all = List.of(row("个", null), row("箱", null));

        List<ReportTotal> totals = ReportTotalsCalculator.computeFromRows(
                all, List.of(new ReportTotalsCalculator.Spec("qty", "合计数量", "number", "unitName")));

        // 宁可整项不显示，也不伪造一个 0。
        assertThat(totals).isEmpty();
    }

    private static Map<String, Object> row(String unit, BigDecimal qty) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("unitName", unit);
        row.put("qty", qty);
        return row;
    }
}
