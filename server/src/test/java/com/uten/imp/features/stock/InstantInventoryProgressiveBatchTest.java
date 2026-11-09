package com.uten.imp.features.stock;

import com.uten.imp.common.report.ReportReadPlan;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.TotaledPageResponse;
import com.uten.imp.features.stock.dto.InstantInventoryRow;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 即时库存逐批完整读取(2026-11-08)：首批带整个结果集的合计与表头桶；续批按共享读取计划
 * includeTotals=false&amp;includeFacets=false 只跑同一段行查询与计数，不重算合计/桶。
 */
class InstantInventoryProgressiveBatchTest {

    private final StockBalanceRepository balanceRepo = mock(StockBalanceRepository.class);
    private final StockCostMasker costMasker = mock(StockCostMasker.class);

    private record Run(PageResponse<InstantInventoryRow> page, List<String> sql) { }

    private Run run(ReportReadPlan plan, int page, int size) {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        lenient().when(query.getSingleResult()).thenReturn(0L);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        lenient().when(costMasker.canView()).thenReturn(false);
        PageResponse<InstantInventoryRow> result;
        try (var ignored = ReportReadPlan.open(plan)) {
            result = new StockQueryService(balanceRepo, em, costMasker)
                    .instantInventory(null, null, false, "螺丝", page, size, null, null);
        }
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, atLeastOnce()).createNativeQuery(sql.capture());
        return new Run(result, sql.getAllValues());
    }

    private static String rowsSql(List<String> sql) {
        return sql.stream().filter(s -> s.contains("LIMIT :__limit")).findFirst().orElseThrow();
    }

    @Test
    void continuationBatchesReadTheSameRowsWithoutRecomputingTotalsOrBuckets() {
        Run first = run(ReportReadPlan.ALL, 1, 50);
        Run continuation = run(new ReportReadPlan(true, false, false), 2, 200);

        // 同一段行查询与同一排序：续批只是换了 LIMIT/OFFSET 参数。
        assertThat(rowsSql(continuation.sql())).isEqualTo(rowsSql(first.sql()));
        // 首批：合计 + 4 个表头桶 + 归属空计数 都在服务端算。
        assertThat(first.page()).isInstanceOf(TotaledPageResponse.class);
        assertThat(first.sql()).anyMatch(s -> s.contains("SUM(t.\""));
        assertThat(first.sql().size()).isGreaterThan(continuation.sql().size());
        // 续批：只取行与计数，不聚合合计、不算桶。
        assertThat(continuation.page()).isNotInstanceOf(TotaledPageResponse.class);
        assertThat(continuation.sql()).noneMatch(s -> s.contains("SUM(t.\""));
        assertThat(continuation.sql()).noneMatch(s -> s.contains("GROUP BY ow.id"));
        assertThat(continuation.sql()).anyMatch(s -> s.startsWith("SELECT COUNT(*) FROM ("));
        assertThat(continuation.page().getSize()).isEqualTo(200);
        assertThat(continuation.page().getPage()).isEqualTo(2);
    }

    @Test
    void theDefaultRequestStillCarriesTotalsAndBuckets() {
        Run all = run(ReportReadPlan.ALL, 1, 200);
        assertThat(all.page()).isInstanceOf(TotaledPageResponse.class);
        assertThat(all.page().getSize()).isEqualTo(200);
    }
}
