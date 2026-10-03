package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.GlobalExceptionHandler;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** 行动清单必须与总体统计同范围、同事实规则；不能退化成当前页客户端筛选。 */
class InstantInventoryAttentionTest {
    private final EntityManager em = mock(EntityManager.class);
    private final StockCostMasker costMasker = mock(StockCostMasker.class);
    private final StockQueryService service = new StockQueryService(
            mock(StockBalanceRepository.class), em, costMasker);
    private final Map<String, Query> queries = new LinkedHashMap<>();

    @ParameterizedTest
    @CsvSource({
            "NEGATIVE_BALANCE, negative_balance_rows",
            "AWAITING_STOCK_IN, nonpositive_pending_stock_in_rows",
            "AWAITING_INSPECTION, nonpositive_pending_inspection_rows",
            "UNKNOWN_WEIGHT, stocked_weight_unknown_rows",
            "MISSING_UNIT, missing_unit_rows"
    })
    void attentionAppliesToTheCompleteScopeBeforePaginationAndSharesCountAndTotals(
            String attention, String column) {
        UUID category = UUID.randomUUID();
        UUID warehouse = UUID.randomUUID();
        UUID childWarehouse = UUID.randomUUID();
        UUID owningWarehouse = UUID.randomUUID();
        UUID color = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        prepareQueries(List.of(warehouse, childWarehouse));

        var result = service.instantInventory(category, warehouse, false, false, "  螺丝  ",
                owningWarehouse, false, color, "  五金  ", unit, attention, 3, 12, "name", "asc");

        String dataSql = queries.keySet().stream().filter(sql -> sql.contains(" LIMIT :__limit"))
                .findFirst().orElseThrow();
        String exactCore = dataSql.substring(0, dataSql.lastIndexOf(" ORDER BY "));
        String predicate = "attention_scope." + column + " > 0";
        assertThat(exactCore).startsWith("SELECT * FROM (")
                .endsWith(") attention_scope WHERE " + predicate)
                .contains("NOT w.is_defective", "NOT w.is_line_side", "w.is_accountable")
                .contains("base.color_id = :colorId", "g.series = :series", "u.id = :unitId")
                .contains("g.owning_warehouse_id = :ownWh")
                .contains("COALESCE(i.pre_stocked_warehouse_id, i.warehouse_id) IN (:scopeIds)");
        // 原始单仓负余额先计数，货品净额为正也不能漏掉；未称仍排除零库存。
        assertThat(exactCore).contains("SUM(CASE WHEN u.qty < 0 THEN 1 ELSE 0 END)")
                .contains("COALESCE(base.qty, 0) <> 0 AND base.weight IS NULL");
        assertThat(queries).containsKey("SELECT COUNT(*) FROM (" + exactCore + ") t");
        List<String> aggregateSql = queries.keySet().stream()
                .filter(sql -> sql.contains("SUM(t.\"")).toList();
        assertThat(aggregateSql).hasSize(2).allSatisfy(sql -> assertThat(sql)
                .contains("FROM (" + exactCore + "  ) t")
                .doesNotContain("LIMIT", "OFFSET"));
        // 四条查询共用全部筛选绑定，分页参数只属于列表。
        for (var entry : queries.entrySet()) {
            if (!entry.getKey().contains(predicate)) continue;
            Query query = entry.getValue();
            verify(query).setParameter("scopeIds", Set.of(warehouse, childWarehouse));
            verify(query).setParameter("categoryId", category);
            verify(query).setParameter("kw", "%螺丝%");
            verify(query).setParameter("ownWh", owningWarehouse);
            verify(query).setParameter("colorId", color);
            verify(query).setParameter("series", "五金");
            verify(query).setParameter("unitId", unit);
        }
        verify(queries.get(dataSql)).setParameter("__limit", 12);
        verify(queries.get(dataSql)).setParameter("__offset", 24L);
        assertThat(result.getTotal()).isEqualTo(31L);
        assertThat(result.getTotalPages()).isEqualTo(3);
        // 未请求成本权限仍在每条库存 SQL 投影脱敏。
        assertThat(queries.keySet().stream().filter(sql -> !sql.equals(StockWarehouseScope.SUBTREE_SQL)))
                .allSatisfy(sql -> assertThat(sql).contains("CAST(NULL AS NUMERIC)"));

        List<String> facets = queries.keySet().stream()
                .filter(sql -> sql.contains(" AS v,") || sql.contains("WHERE g2.owning_warehouse_id IS NULL"))
                .toList();
        assertThat(facets).hasSize(5).allSatisfy(sql -> {
            assertThat(sql).doesNotContain("attention_scope", ":ownWh", ":colorId", ":series", ":unitId");
            verify(queries.get(sql)).setParameter("scopeIds", Set.of(warehouse, childWarehouse));
            verify(queries.get(sql)).setParameter("categoryId", category);
            verify(queries.get(sql)).setParameter("kw", "%螺丝%");
            verify(queries.get(sql), never()).setParameter(eq("__limit"), any());
        });
    }

    @ParameterizedTest
    @ValueSource(strings = {"SHORTAGE", "negative_balance", "", " ", "NEGATIVE_BALANCE OR 1=1"})
    void invalidAttentionReturnsHttp400BeforeAnyDatabaseWork(String attention) throws Exception {
        var mvc = MockMvcBuilders.standaloneSetup(new StockQueryController(service))
                .setControllerAdvice(new GlobalExceptionHandler()).build();

        for (String path : List.of("/api/stock/instant-inventory", "/api/stock/instant-inventory/attention")) {
            mvc.perform(get(path).param("attention", attention))
                    .andExpect(status().isBadRequest())
                    .andExpect(jsonPath("code").value("MALFORMED_REQUEST"));
        }

        verifyNoInteractions(em, costMasker);
    }

    @Test
    void dedicatedAttentionEndpointRejectsMissingRuleInsteadOfReturningAllInventory() throws Exception {
        var mvc = MockMvcBuilders.standaloneSetup(new StockQueryController(service))
                .setControllerAdvice(new GlobalExceptionHandler()).build();
        mvc.perform(get("/api/stock/instant-inventory/attention"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("code").value("MALFORMED_REQUEST"));
        verifyNoInteractions(em, costMasker);
    }

    @Test
    void dedicatedAttentionEndpointReturnsTheFilteredPage() throws Exception {
        prepareQueries(List.of());
        var mvc = MockMvcBuilders.standaloneSetup(new StockQueryController(service))
                .setControllerAdvice(new GlobalExceptionHandler()).build();
        mvc.perform(get("/api/stock/instant-inventory/attention")
                        .param("attention", "NEGATIVE_BALANCE").param("page", "2").param("size", "12"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("total").value(31))
                .andExpect(jsonPath("page").value(2))
                .andExpect(jsonPath("totalPages").value(3));
        assertThat(queries.keySet()).anySatisfy(sql -> assertThat(sql)
                .contains("WHERE attention_scope.negative_balance_rows > 0"));
    }

    @Test
    void attentionDoesNotPermitCostSortingWithoutCostPermission() {
        assertThatThrownBy(() -> service.instantInventory(null, null, true, false, null,
                null, false, null, null, null, "NEGATIVE_BALANCE", 1, 20, "costAmount", "desc"))
                .isInstanceOfSatisfying(ApiException.class,
                        error -> assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        verifyNoInteractions(em);
    }

    @Test
    void negativeBalanceCountSortKeepsCompensatedWarehouseDeficitsAndStablePageIdentity() {
        prepareQueries(List.of());
        service.instantInventory(null, null, true, true, null,
                null, true, null, null, null, "NEGATIVE_BALANCE", 1, 20,
                "negativeBalanceCount", "desc");

        String sql = queries.keySet().stream().filter(statement -> statement.contains(" LIMIT :__limit"))
                .findFirst().orElseThrow();
        assertThat(sql).contains("g.owning_warehouse_id IS NULL")
                .contains("WHERE attention_scope.negative_balance_rows > 0")
                .contains("ORDER BY negative_balance_rows DESC NULLS LAST, name ASC, goods_id ASC, color_id ASC NULLS FIRST")
                .doesNotContain("NOT w.is_defective", "NOT w.is_line_side");
    }

    private void prepareQueries(List<UUID> warehouseIds) {
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            Query query = mock(Query.class);
            queries.put(sql, query);
            lenient().when(query.setParameter(anyString(), any())).thenReturn(query);
            lenient().when(query.getResultList()).thenReturn(
                    sql.equals(StockWarehouseScope.SUBTREE_SQL) ? warehouseIds : List.of());
            lenient().when(query.getSingleResult()).thenReturn(31L);
            return query;
        });
    }
}
