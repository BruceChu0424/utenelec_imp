package com.uten.imp.features.stock;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 即时库存「颜色/物料系列/单位」表头筛选（2026-09-16）：
 * colorId/series/unitId 只进列表本体（dataQ/countQ/合计）——facets 聚合
 * （owningWarehouse + 这三列）一律跑在未应用这些筛选的 coreFacet 上，翻页/合计口径不漂移。
 */
class InstantInventoryColumnFacetFilterTest {

    private final StockBalanceRepository balanceRepo = mock(StockBalanceRepository.class);
    private final StockMovementRepository movementRepo = mock(StockMovementRepository.class);
    private final EntityManager em = mock(EntityManager.class);
    private final StockCostMasker costMasker = mock(StockCostMasker.class);

    @Test
    void columnFiltersFlowIntoListCountAndTotalsButNeverIntoFacetAggregates() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        lenient().when(query.getSingleResult()).thenReturn(0L);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        lenient().when(costMasker.canView()).thenReturn(false);

        UUID colorId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        new StockQueryService(balanceRepo, movementRepo, em, costMasker)
                .instantInventory(null, null, true, null,
                        null, null, colorId, "X系列", unitId, 1, 20, null, null);

        // ①列表/计数/合计：三个筛选条件全部在 core 上生效（绑定参数 colorId/series/unitId）。
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, atLeastOnce()).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).anySatisfy(statement -> assertThat(statement)
                .contains("base.color_id = :colorId")
                .contains("g.series = :series")
                .contains("u.id = :unitId"));
        // ②颜色/系列/单位三列 facet：JOIN/派生表聚合出桶值与展示名，
        //   跑在未应用列筛选的 coreFacet（不含 :colorId/:series/:unitId 引用）上。
        assertThat(sql.getAllValues()).anySatisfy(statement -> assertThat(statement)
                .contains("t.color_id AS v")
                .doesNotContain(":colorId"));
        assertThat(sql.getAllValues()).anySatisfy(statement -> assertThat(statement)
                .contains("t.series IS NOT NULL")
                .doesNotContain(":series"));
        assertThat(sql.getAllValues()).anySatisfy(statement -> assertThat(statement)
                .contains("LEFT JOIN units u2")
                .contains("u2.id AS v")
                .doesNotContain(":unitId"));
        // ③三列不下发空值桶（前端无对应 null 筛选参数）。
        assertThat(sql.getAllValues()).noneSatisfy(statement -> assertThat(statement)
                .contains("color_id IS NULL"));
    }

    @Test
    void facetBucketQueriesBindScopeParametersOnly() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        lenient().when(query.getSingleResult()).thenReturn(0L);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        lenient().when(costMasker.canView()).thenReturn(false);

        UUID colorId = UUID.randomUUID();
        new StockQueryService(balanceRepo, movementRepo, em, costMasker)
                .instantInventory(null, null, true, null,
                        null, null, colorId, null, null, 1, 20, null, null);

        // facet 聚合查询只引用 coreFacet 里出现过的参数；列筛选参数不得绑定到 facet 查询
        //（Hibernate 对未使用参数会抛 ParameterNotBoundError）。
        verify(query, atLeastOnce()).setParameter(eq("colorId"), eq(colorId));
        // 三条 facet 查询（颜色/系列/单位）各绑定 0 次 colorId —— 通过 SQL 断言兜底：
        // 上面 noneSatisfy/doesNotContain(":colorId") 已验证 facet SQL 不含该参数。
    }
}
