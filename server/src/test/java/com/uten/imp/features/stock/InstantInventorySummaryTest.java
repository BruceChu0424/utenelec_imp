package com.uten.imp.features.stock;

import com.uten.imp.common.report.ReportTotal;
import com.uten.imp.common.web.TotaledPageResponse;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** 即时库存详情必须基于完整筛选结果，不能用当前页或跨仓净额掩盖事实。 */
class InstantInventorySummaryTest {
    private final EntityManager em = mock(EntityManager.class);
    private final StockQueryService service = new StockQueryService(
            mock(StockBalanceRepository.class), em, mock(StockCostMasker.class));
    private final Map<String, Query> queries = new LinkedHashMap<>();

    @Test
    void summarySharesTheExistingWeightAggregateAndEveryListFilter() {
        UUID category = UUID.randomUUID();
        UUID warehouse = UUID.randomUUID();
        UUID childWarehouse = UUID.randomUUID();
        UUID owningWarehouse = UUID.randomUUID();
        UUID color = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        prepareQueries(List.of(warehouse, childWarehouse), Map.of(), 0);

        service.instantInventory(category, warehouse, false, false, "  螺丝  ",
                owningWarehouse, false, color, "  五金  ", unit, 4, 20, "qty", "desc");

        String aggregate = summarySql();
        String pageSql = queries.keySet().stream().filter(sql -> sql.contains(" LIMIT :__limit"))
                .findFirst().orElseThrow();
        String exactListCore = pageSql.substring(0, pageSql.lastIndexOf(" ORDER BY "));
        assertThat(aggregate).contains("FROM (" + exactListCore + "  ) t")
                .contains("NOT w.is_defective", "NOT w.is_line_side", "w.is_accountable")
                .contains("base.color_id = :colorId", "g.series = :series", "u.id = :unitId")
                .doesNotContain("LIMIT", "OFFSET");
        Query query = queries.get(aggregate);
        verify(query).setParameter("scopeIds", Set.of(warehouse, childWarehouse));
        verify(query).setParameter("categoryId", category);
        verify(query).setParameter("kw", "%螺丝%");
        verify(query).setParameter("ownWh", owningWarehouse);
        verify(query).setParameter("colorId", color);
        verify(query).setParameter("series", "五金");
        verify(query).setParameter("unitId", unit);
        verify(query, never()).setParameter(org.mockito.ArgumentMatchers.eq("__limit"), any());
        verify(query, never()).setParameter(org.mockito.ArgumentMatchers.eq("__offset"), any());
        // 仍只有原有的两条合计 SQL：一条重量/计数，一条分单位数量。
        assertThat(queries.keySet().stream().filter(sql -> sql.startsWith("SELECT ")
                && sql.contains("SUM(t.\""))).hasSize(2);
        assertThat(queries).hasSize(10); // 仓库范围 + 列表/计数 + 两条合计 + 五条 facet。
    }

    @Test
    void returnedCountsComeFromTheFullAggregateAndPreserveZeroValues() {
        Map<String, BigDecimal> totals = new LinkedHashMap<>();
        totals.put("weight", new BigDecimal("21.2"));
        totals.put("weight_unknown_rows", new BigDecimal("2"));
        totals.put("weight_estimated_rows", BigDecimal.ONE);
        totals.put("inventory_rows", new BigDecimal("500"));
        totals.put("positive_stock_rows", new BigDecimal("6"));
        totals.put("negative_stock_rows", BigDecimal.ONE);
        totals.put("zero_stock_rows", new BigDecimal("493"));
        totals.put("stocked_weight_known_rows", new BigDecimal("5"));
        totals.put("stocked_weight_unknown_rows", new BigDecimal("2"));
        totals.put("stocked_weight_estimated_rows", BigDecimal.ONE);
        totals.put("negative_balance_rows", new BigDecimal("3"));
        prepareQueries(List.of(), totals, 500);

        var result = service.instantInventory(null, null, false, null, 26, 20, null, null);

        // 当前页为空，但统计仍覆盖全部 500 项；换页不能把统计清零。
        assertThat(result.getItems()).isEmpty();
        assertThat(result.getTotal()).isEqualTo(500);
        List<ReportTotal> responseTotals = ((TotaledPageResponse<?>) result).getTotals();
        for (Map.Entry<String, BigDecimal> entry : totals.entrySet()) {
            assertThat(total(responseTotals, entry.getKey()).groups().getFirst().value())
                    .isEqualByComparingTo(entry.getValue());
        }
        ReportTotal noPending = total(responseTotals, "pending_inspection_rows");
        assertThat(noPending.type()).isEqualTo("count");
        assertThat(noPending.groupKey()).isNull();
        assertThat(noPending.groups().getFirst().unit()).isNull();
        assertThat(noPending.groups().getFirst().value()).isZero();
        assertThat(total(responseTotals, "qty").groups()).hasSize(2);
        assertThat(total(responseTotals, "qty").groupKey()).isEqualTo("unit_name");
    }

    @Test
    void singleWarehouseDeficitsRemainVisibleEvenWhenAnotherWarehouseOffsetsThem() {
        prepareQueries(List.of(), Map.of(), 0);
        service.instantInventory(null, null, false, null, 1, 20, null, null);

        String sql = summarySql();
        // 原始余额负数先计数，再按货品×颜色汇总；+10/-5 的两个仓仍有一处负库存。
        assertThat(sql).contains("SUM(CASE WHEN u.qty < 0 THEN 1 ELSE 0 END) AS negative_balance_rows")
                .contains("COALESCE(base.negative_balance_rows, 0) AS negative_balance_rows")
                .contains("SUM(t.\"negative_balance_rows\")")
                .contains("CASE WHEN COALESCE(base.qty, 0) < 0 THEN 1 ELSE 0 END AS negative_stock_rows")
                .contains("CASE WHEN COALESCE(base.qty, 0) = 0 THEN 1 ELSE 0 END AS zero_stock_rows");
        // 待检/待入库只形成补充提示，不增加现存数量或伪造需求缺货量。
        assertThat(sql).contains("COALESCE(base.qty, 0) <= 0 AND COALESCE(iqc.pending_qty, 0) > 0")
                .contains("AS nonpositive_pending_stock_in_rows")
                .doesNotContain("AS shortage", "SUM(t.\"cost_amount\")", "SUM(t.\"more_qty\")");
    }

    @Test
    void weightCoverageExcludesZeroInventoryAndEstimatedIsASubsetOfKnown() {
        prepareQueries(List.of(), Map.of(), 0);
        service.instantInventory(null, null, true, null, 1, 20, null, null);

        String sql = summarySql();
        assertThat(sql).contains("COALESCE(base.qty, 0) <> 0 AND base.weight IS NOT NULL")
                .contains("COALESCE(base.qty, 0) <> 0 AND base.weight IS NULL")
                .contains("AND COALESCE(base.weight_estimated, false)")
                .contains("THEN 1 ELSE 0 END AS stocked_weight_estimated_rows")
                .contains("u.id IS NULL OR NULLIF(BTRIM(u.name), '') IS NULL");
        // 原重量守恒规则继续生效：跨仓任一有量余额未称，整项就未知。
        assertThat(sql).contains("CASE WHEN bool_or(u.qty <> 0 AND u.weight IS NULL) THEN NULL")
                .doesNotContain("COALESCE(base.weight, 0)");
    }

    private ReportTotal total(List<ReportTotal> totals, String key) {
        return totals.stream().filter(total -> total.key().equals(key)).findFirst().orElseThrow();
    }

    private String summarySql() {
        return queries.keySet().stream().filter(sql -> sql.startsWith("SELECT SUM(t.\"weight\")"))
                .findFirst().orElseThrow();
    }

    private void prepareQueries(List<UUID> warehouseIds, Map<String, BigDecimal> summary, long total) {
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            Query query = mock(Query.class);
            queries.put(sql, query);
            lenient().when(query.setParameter(anyString(), any())).thenReturn(query);
            lenient().when(query.getSingleResult()).thenReturn(total);
            List<?> rows = List.of();
            if (sql.equals(StockWarehouseScope.SUBTREE_SQL)) {
                rows = warehouseIds;
            } else if (sql.startsWith("SELECT SUM(t.\"weight\")") && !summary.isEmpty()) {
                String projection = sql.substring("SELECT ".length(), sql.indexOf(" FROM ("));
                Object[] aggregate = Arrays.stream(projection.split(", "))
                        .map(column -> column.substring("SUM(t.\"".length(), column.length() - 2))
                        .map(key -> summary.getOrDefault(key, BigDecimal.ZERO)).toArray();
                rows = java.util.Collections.singletonList(aggregate);
            } else if (sql.startsWith("SELECT t.\"unit_name\" AS __grp") && !summary.isEmpty()) {
                rows = List.of(
                        new Object[]{"个", new BigDecimal("3000.5"), BigDecimal.ZERO, BigDecimal.ZERO},
                        new Object[]{"kg", BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO});
            }
            lenient().when(query.getResultList()).thenReturn(new ArrayList<>(rows));
            return query;
        });
    }
}
