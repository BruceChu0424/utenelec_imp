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
import java.util.Set;
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

    @Test
    void parentSupplyCoverageLosesOnlyTheReceiptPriorityProjection() throws Exception {
        String current = (String) ReflectionTestUtils.getField(Class.forName(
                "com.uten.imp.features.production.analysis.MaterialAnalysisService"), "ACTIVE_FUTURE_COVERAGE_SQL");
        String jdbc = jdbcSql(current, new MapSqlParameterSource("analysisId", UUID.randomUUID()));
        String historical = new HistoricalInventoryPlanningSql().inspect(jdbc);
        assertThat(historical).isNotEqualTo(jdbc)
                .doesNotContain("fn_preplan_receipt_priority", "planning_qty")
                // uncapped 别名必须保留：retained_pending 仍引用它，且 planning 等于 uncapped 时
                // 恒走原 pending 分支，正好恢复 9a73f9584 之前的承诺口径。
                .contains("pending_qty.qty AS uncapped_qty,pending_qty.qty,")
                .contains("CASE WHEN raw.qty=raw.uncapped_qty THEN retained.pending_qty");
        assertThat(historical.chars().filter(ch -> ch == '?').count())
                .isEqualTo(jdbc.chars().filter(ch -> ch == '?').count());
    }

    @Test
    void aggregatePrivateIntentDropsOnlyTheReceiptPriorityPendingCap() throws Exception {
        EntityManager em = recorder();
        var constructor = Class.forName("com.uten.imp.features.production.analysis.AggregatePrivateIntentReader")
                .getDeclaredConstructor(EntityManager.class);
        constructor.setAccessible(true);
        Object reader = constructor.newInstance(em);
        ReflectionTestUtils.invokeMethod(reader, "read", UUID.randomUUID());
        var sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        String jdbc = jdbcSql(sql.getValue(), new MapSqlParameterSource("analysis", UUID.randomUUID()));
        String historical = new HistoricalInventoryPlanningSql().inspect(jdbc);
        assertThat(historical).isNotEqualTo(jdbc)
                .doesNotContain("fn_preplan_receipt_priority")
                .contains("raw.pending_qty AS pending_qty");
        assertThat(historical.chars().filter(ch -> ch == '?').count())
                .isEqualTo(jdbc.chars().filter(ch -> ch == '?').count());
    }

    @Test
    void inboundAllocationCandidatesKeepTheirShapeWithoutPriorityHeadroom() throws Exception {
        EntityManager em = recorder();
        Object projection = mock(Class.forName(
                "com.uten.imp.features.production.analysis.PreplanInboundAllocationProjectionService"), CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(projection, "em", em);
        UUID externalItem = UUID.randomUUID();
        ReflectionTestUtils.invokeMethod(projection, "preplanCandidates", Set.of(externalItem), false);
        var sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        String jdbc = jdbcSql(sql.getValue(), new MapSqlParameterSource("externalItemIds", externalItem)
                .addValue("includeIqcContinuations", false));
        String historical = new HistoricalInventoryPlanningSql().inspect(jdbc);
        assertThat(historical).isNotEqualTo(jdbc)
                .doesNotContain("fn_preplan_receipt_priority")
                .contains("NULL::numeric AS priority_headroom");
        assertThat(historical.chars().filter(ch -> ch == '?').count())
                .isEqualTo(jdbc.chars().filter(ch -> ch == '?').count());
    }

    @Test
    void receiptPriorityBlockedGuardsDisappearBeforeThePriorityTableExisted() throws Exception {
        String fragment = (String) ReflectionTestUtils.getField(Class.forName(
                "com.uten.imp.features.production.analysis.AggregateMaterialOrderWriteService"),
                "PRIORITY_BLOCKED_MATERIAL_SQL");
        var inspector = new HistoricalInventoryPlanningSql();
        String cancelled = inspector.inspect("SELECT BOOL_OR(fn_preplan_material_has_qualified_receipt(child.id)),MIN(\n"
                + fragment + "\n)\nFROM production_material_analysis_materials child");
        assertThat(cancelled.replaceAll("\\s+", " ")).isEqualTo(
                "SELECT BOOL_OR(fn_preplan_material_has_qualified_receipt(child.id)),MIN( NULL::text )"
                        + " FROM production_material_analysis_materials child");
        String blocked = inspector.inspect("SELECT child.id,\n" + fragment
                + "\nAS priority_blocked_goods_code FROM production_material_analysis_materials child");
        assertThat(blocked.replaceAll("\\s+", " ")).isEqualTo(
                "SELECT child.id, NULL::text AS priority_blocked_goods_code"
                        + " FROM production_material_analysis_materials child");
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
