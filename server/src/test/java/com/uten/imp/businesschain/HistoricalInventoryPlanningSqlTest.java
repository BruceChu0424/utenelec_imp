package com.uten.imp.businesschain;

import com.uten.imp.features.production.analysis.MaterialAnalysisPhysicalStockClaimService;
import com.uten.imp.features.production.analysis.MaterialAnalysisRootSupplyService;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterUtils;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class HistoricalInventoryPlanningSqlTest {
    @Test
    void currentStockReadsMapToTheirOriginalScopeWithoutChangingParameters() throws Exception {
        UUID analysis = UUID.randomUUID();
        EntityManager em = recorder();
        Class<?> sales = Class.forName("com.uten.imp.features.production.analysis.MaterialAnalysisSalesStock");
        ReflectionTestUtils.invokeMethod(sales, "adoptedByRoot", em, analysis);
        ReflectionTestUtils.invokeMethod(sales, "availableByRoot", em, analysis);
        UUID root = UUID.randomUUID();
        ReflectionTestUtils.invokeMethod(sales, "adopt", em, analysis, root, BigDecimal.ONE, "fixture", UUID.randomUUID());
        var claims = mock(MaterialAnalysisPhysicalStockClaimService.class, CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(claims, "em", em);
        claims.adoptedByMaterial(analysis);

        var sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(4)).createNativeQuery(sql.capture());
        var inspector = new HistoricalInventoryPlanningSql();
        var parameters = new MapSqlParameterSource("id", analysis).addValue("analysis", analysis)
                .addValue("root", root).addValue("adopted", true);
        for (String named : sql.getAllValues()) {
            String current = jdbcSql(named, parameters);
            String original = inspector.inspect(current);
            assertThat(original).isNotEqualTo(current)
                    .doesNotContain("preplan_sales_stock_adoptions", "preplan_physical_stock_formalizations");
            assertThat(original.chars().filter(ch -> ch == '?').count())
                    .isEqualTo(current.chars().filter(ch -> ch == '?').count());
        }
    }

    @Test
    void bothCustodyReadsCheckForARealSubcontractActionAndLeaveUnknownStatementsUnchanged() throws Exception {
        UUID analysis = UUID.randomUUID();
        EntityManager em = recorder();
        Class<?> custody = Class.forName("com.uten.imp.features.production.analysis.SubcontractComponentCustodyProjection");
        ReflectionTestUtils.invokeMethod(custody, "coverageForAnalysis", em, analysis);
        ReflectionTestUtils.invokeMethod(custody, "supplyForAnalysis", em, analysis);

        var sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(2)).createNativeQuery(sql.capture());
        var inspector = new HistoricalInventoryPlanningSql.BeforeV1097();
        for (String named : sql.getAllValues()) {
            String current = jdbcSql(named, new MapSqlParameterSource("analysisId", analysis));
            assertThat(inspector.inspect(current)).contains("FROM preplan_supply_actions action",
                    "Unexpected subcontract action", "action.route='SUBCONTRACT'")
                    .doesNotContain("material_consumption_version");
            assertThat(inspector.inspect(current + " LIMIT 1")).isEqualTo(current + " LIMIT 1");
        }
    }

    @Test
    void rootQuantityReadUsesTheRealOutputLedgerBeforeSalesAdoptionExisted() {
        UUID analysis = UUID.randomUUID();
        EntityManager em = recorder();
        var root = mock(MaterialAnalysisRootSupplyService.class, CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(root, "em", em);
        root.projectRootNodes(analysis, Map.of(), Map.of(), Map.of());
        var sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(2)).createNativeQuery(sql.capture());
        var parameters = new MapSqlParameterSource("analysisId", analysis).addValue("overrides", "[]");
        String current = jdbcSql(sql.getValue(), parameters);
        String historical = new HistoricalInventoryPlanningSql().inspect(current);
        assertThat(current).contains("+fn_preplan_adopted_sales_stock_base(item.id)");
        assertThat(historical).isEqualTo(current.replace("+fn_preplan_adopted_sales_stock_base(item.id)", ""));
        assertThat(historical).contains("FROM preplan_root_output_events e WHERE e.analysis_item_id=item.id");
    }

    private static EntityManager recorder() {
        var em = mock(EntityManager.class);
        var query = mock(Query.class, RETURNS_SELF);
        when(query.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(query);
        return em;
    }

    private static String jdbcSql(String sql, MapSqlParameterSource parameters) {
        return NamedParameterUtils.substituteNamedParameters(NamedParameterUtils.parseSqlStatement(sql), parameters);
    }
}
