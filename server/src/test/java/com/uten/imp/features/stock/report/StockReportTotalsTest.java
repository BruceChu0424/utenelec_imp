package com.uten.imp.features.stock.report;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.stock.StockCostMasker;
import com.uten.imp.features.stock.StockQueryService;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.time.LocalDate;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 仓库报表「表格下方合计」声明契约。
 *
 * <p>合计跑在与列表**完全相同**的 FROM/WHERE 上（含默认草稿排除、日期、docType），
 * 且派生表不带 LIMIT/OFFSET —— 所以它是整个结果集的合计，不是当前这一页的。
 *
 * <p>同样重要的是<b>哪些列故意没有合计</b>：领料单的「实发数量」是 base_qty（库存基本单位），
 * 与行上的「单位」列不是一个口径，按单位分组会贴错标签；盘点的「帐面重量」投影是字面量 NULL。
 */
class StockReportTotalsTest {

    private final EntityManager em = mock(EntityManager.class);
    private final SystemSettingsService settings = mock(SystemSettingsService.class);
    private final StockQueryService stockQueryService = mock(StockQueryService.class);
    private final StockCostMasker costMasker = mock(StockCostMasker.class);

    @Test
    void drawDetailTotalsIssuableQuantitiesByUnitAndRefusesBaseUnitColumn() {
        String aggregate = aggregateSqlOf(() -> service().detail(
                StockReportService.DOC_DRAW, null, null, null, null, null,
                LocalDate.of(2026, 1, 1), LocalDate.of(2026, 1, 31), null,
                Map.of(), 1, 50, null, null));

        // 领料数量/已出库都是单据行单位的量 → 按单位分组相加。
        assertThat(aggregate).contains("SUM(t.\"drawQty\")");
        assertThat(aggregate).contains("SUM(t.\"issuedQty\")");
        assertThat(aggregate).contains("GROUP BY t.\"unitName\"");
        // 实发数量 = base_qty（基本单位），与 unitName 不同口径 → 绝不参与合计。
        assertThat(aggregate).doesNotContain("SUM(t.\"actualQty\")");
        // 合计覆盖整个筛选后结果集：派生表里不带分页。
        assertThat(aggregate).doesNotContain("LIMIT").doesNotContain("OFFSET");
        // 与列表同一份 WHERE：docType + 日期 + 「草稿不进报表」默认口径。
        assertThat(aggregate).contains("i.bill_type = 'DRAW'");
        assertThat(aggregate).contains("o.bill_date >= :dateFrom");
        assertThat(aggregate).contains("o.status <> 0");
    }

    @Test
    void checkDetailRefusesBookWeightBecauseItIsProjectedAsNull() {
        String aggregate = aggregateSqlOf(() -> service().detail(
                StockReportService.DOC_CHECK, null, null, null, null, null,
                null, null, null, Map.of(), 1, 50, null, null));

        assertThat(aggregate).contains("SUM(t.\"bookQty\")");
        assertThat(aggregate).contains("SUM(t.\"actualQty\")");
        // 帐面重量投影是字面量 NULL（老库无此列），SUM 恒 NULL，不声明。
        assertThat(aggregate).doesNotContain("SUM(t.\"bookWeight\")");
    }

    @Test
    void summaryReportsHaveNoNumericColumnSoNoAggregateQueryIsIssued() {
        Query query = emptyQuery();
        when(em.createNativeQuery(anyString())).thenReturn(query);

        service().summary(StockReportService.DOC_WDRAW, null, null, null, null, null,
                null, null, null, Map.of(), 1, 50, null, null);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, atLeastOnce()).createNativeQuery(sql.capture());
        // 汇总表一行一单、整张表没有数量/金额列 —— 没有可加的东西就一条聚合查询都不跑。
        assertThat(sql.getAllValues()).noneMatch(s -> s.contains("SUM(t."));
    }

    private String aggregateSqlOf(Runnable call) {
        Query query = emptyQuery();
        when(em.createNativeQuery(anyString())).thenReturn(query);

        call.run();

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, atLeastOnce()).createNativeQuery(sql.capture());
        List<String> aggregates = sql.getAllValues().stream()
                .filter(s -> s.startsWith("SELECT ") && s.contains("SUM(t.\""))
                .toList();
        assertThat(aggregates).isNotEmpty();
        return String.join("\n", aggregates);
    }

    private StockReportService service() {
        return new StockReportService(em, settings, stockQueryService, costMasker);
    }

    private Query emptyQuery() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        org.mockito.Mockito.lenient().when(query.getSingleResult()).thenReturn(0L);
        return query;
    }
}
