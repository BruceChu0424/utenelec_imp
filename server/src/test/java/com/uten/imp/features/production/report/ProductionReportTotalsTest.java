package com.uten.imp.features.production.report;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

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
 * 生产报表「表格下方合计」声明契约。
 *
 * <p>生产计划明细本来不展示单位列，所以合计靠<b>隐藏分组列</b> {@code __unitName} 分组
 * （只进派生表，不进前端 columns / 导出）；排产数量与完工数量可加，
 * <b>订货数量不可加</b>——它是来源销售订单行的数量快照，拆分出的子计划会把同一个数重复落在多行。
 */
class ProductionReportTotalsTest {

    private final EntityManager em = mock(EntityManager.class);
    private final SystemSettingsService settings = mock(SystemSettingsService.class);

    @Test
    void planDetailTotalsPlannedAndFinishedQuantitiesGroupedByHiddenUnitColumn() {
        Query query = emptyQuery();
        when(em.createNativeQuery(anyString())).thenReturn(query);

        ReportTableResponse response = service().planDetail(
                null, null, null, null, null, null, Map.of(), 1, 50, null, null);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, atLeastOnce()).createNativeQuery(sql.capture());
        String aggregate = sql.getAllValues().stream()
                .filter(s -> s.contains("SUM(t.\""))
                .reduce("", (a, b) -> a + "\n" + b);

        assertThat(aggregate).contains("SUM(t.\"qty\")");
        assertThat(aggregate).contains("SUM(t.\"iqty\")");
        // 绝不跨单位相加：按隐藏的行单位名分组。
        assertThat(aggregate).contains("GROUP BY t.\"__unitName\"");
        // 订货数量是来源订单行的快照，拆分子计划时会重复出现 → 不参与合计。
        assertThat(aggregate).doesNotContain("SUM(t.\"oqty\")");
        // 合计覆盖整个结果集：派生表不带分页。
        assertThat(aggregate).doesNotContain("LIMIT").doesNotContain("OFFSET");

        // 隐藏分组列只服务于合计，不能泄漏成前端的一列（也就不会进导出 Excel）。
        assertThat(response.columns()).extracting(ReportColumn::key)
                .doesNotContain("__unitName", "__srcId");
    }

    @Test
    void planSummaryHasNoNumericColumnSoNoAggregateQueryIsIssued() {
        Query query = emptyQuery();
        when(em.createNativeQuery(anyString())).thenReturn(query);

        service().planSummary(null, null, null, null, null, Map.of(), 1, 50, null, null);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, atLeastOnce()).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).noneMatch(s -> s.contains("SUM(t."));
    }

    private ProductionReportService service() {
        return new ProductionReportService(em, settings);
    }

    private Query emptyQuery() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        org.mockito.Mockito.lenient().when(query.getSingleResult()).thenReturn(0L);
        return query;
    }
}
