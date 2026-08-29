package com.uten.imp.features.sales.order;

import com.uten.imp.features.sales.order.dto.PlanProgressLine;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SalesOrderPlanProgressQueryTest {

    @Test
    void noAnalysisRowsIsBackwardCompatibleAndDoesNotReadFormalPlanningLedgers() {
        EntityManager em = mock(EntityManager.class);
        Query sourceQuery = queryReturning(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(sourceQuery);

        Map<UUID, List<PlanProgressLine.MaterialAnalysisProgress>> result =
                new SalesOrderPlanProgressQuery(em).load(List.of(UUID.randomUUID()));

        assertThat(result).isEmpty();
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue())
                .contains("production_material_analysis_items")
                .doesNotContain("production_material_demands")
                .doesNotContain("stock_reservations")
                .doesNotContain("supply_pegs");
    }

    @Test
    void projectsSharedReadinessSeparateSubmittedApprovedAndSafeSupplyStatus() {
        UUID analysisId = UUID.randomUUID();
        UUID hiddenAnalysisItemId = UUID.randomUUID();
        UUID firstAnalysisItemId = UUID.randomUUID();
        UUID secondAnalysisItemId = UUID.randomUUID();
        UUID hiddenSalesItemId = UUID.randomUUID();
        UUID firstSalesItemId = UUID.randomUUID();
        UUID secondSalesItemId = UUID.randomUUID();
        UUID materialGoodsId = UUID.randomUUID();
        UUID materialUnitId = UUID.randomUUID();
        UUID actionId = UUID.randomUUID();
        OffsetDateTime analyzedAt = OffsetDateTime.of(
                2026, 8, 8, 9, 30, 0, 0, ZoneOffset.ofHours(8));
        LocalDate inboundDate = LocalDate.of(2026, 8, 15);

        Query sourceQuery = queryReturning(List.of(
                sourceRow(analysisId, hiddenAnalysisItemId, hiddenSalesItemId,
                        analyzedAt, "2", "0", "0", LocalDate.of(2026, 8, 9), 0,
                        "2", "2", null),
                sourceRow(analysisId, firstAnalysisItemId, firstSalesItemId,
                        analyzedAt, "10", "2", "3", LocalDate.of(2026, 8, 18), 1,
                        "5", "5", null),
                sourceRow(analysisId, secondAnalysisItemId, secondSalesItemId,
                        analyzedAt, "10", "0", "0", LocalDate.of(2026, 8, 20), 2,
                        "3", "10", inboundDate)));
        Query materialQuery = queryReturning(List.of(
                materialRow(analysisId, hiddenAnalysisItemId, materialGoodsId,
                        materialUnitId, inboundDate),
                materialRow(analysisId, firstAnalysisItemId, materialGoodsId,
                        materialUnitId, inboundDate),
                materialRow(analysisId, secondAnalysisItemId, materialGoodsId,
                        materialUnitId, inboundDate)));
        Query actionQuery = queryReturning(Collections.singletonList(new Object[]{
                secondAnalysisItemId, actionId, "BUY", "IN_PROGRESS",
                new BigDecimal("14.0000"), LocalDate.of(2026, 8, 14)
        }));
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("FROM production_material_analysis_items ai")) {
                return sourceQuery;
            }
            if (sql.contains("FROM production_material_analysis_materials material")) {
                return materialQuery;
            }
            if (sql.contains("FROM preplan_supply_action_allocations allocation")) {
                return actionQuery;
            }
            throw new AssertionError("Unexpected SQL: " + sql);
        });

        Map<UUID, List<PlanProgressLine.MaterialAnalysisProgress>> result =
                new SalesOrderPlanProgressQuery(em).load(
                        List.of(firstSalesItemId, secondSalesItemId));

        assertThat(result).containsOnlyKeys(firstSalesItemId, secondSalesItemId);
        PlanProgressLine.MaterialAnalysisProgress first = result.get(firstSalesItemId).getFirst();
        assertThat(first.status()).isEqualTo("ACTIVE");
        assertThat(first.analyzedAt()).isEqualTo(analyzedAt);
        assertThat(first.requestedQty()).isEqualByComparingTo("10");
        assertThat(first.submittedQty()).isEqualByComparingTo("2");
        assertThat(first.approvedQty()).isEqualByComparingTo("3");
        assertThat(first.remainingQty()).isEqualByComparingTo("5");
        assertThat(first.readyNowQty()).isEqualByComparingTo("5");
        assertThat(first.readyByDateQty()).isEqualByComparingTo("5");
        assertThat(first.expectedReadyDate()).isNull();

        PlanProgressLine.MaterialAnalysisProgress second =
                result.get(secondSalesItemId).getFirst();
        assertThat(second.readyNowQty()).isEqualByComparingTo("3");
        assertThat(second.readyByDateQty()).isEqualByComparingTo("10");
        assertThat(second.expectedReadyDate()).isEqualTo(inboundDate);
        assertThat(second.supplyActions()).containsExactly(
                new PlanProgressLine.SupplyActionProgress(
                        actionId, "BUY", "IN_PROGRESS", new BigDecimal("14.0000"),
                        LocalDate.of(2026, 8, 14)));

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, atLeastOnce()).createNativeQuery(sql.capture());
        String allSql = String.join("\n", sql.getAllValues()).toLowerCase();
        assertThat(allSql)
                .doesNotContain("supplier")
                .doesNotContain("price")
                .doesNotContain("external_document_no")
                .doesNotContain("maker_id")
                .doesNotContain("created_by");
    }

    @Test
    void priorityReorderMovesSharedReadyQuantityWithoutDoubleCounting() {
        UUID analysisId = UUID.randomUUID();
        UUID firstAnalysisItemId = UUID.randomUUID();
        UUID secondAnalysisItemId = UUID.randomUUID();
        UUID firstSalesItemId = UUID.randomUUID();
        UUID secondSalesItemId = UUID.randomUUID();
        UUID materialGoodsId = UUID.randomUUID();
        UUID materialUnitId = UUID.randomUUID();
        OffsetDateTime analyzedAt = OffsetDateTime.of(
                2026, 8, 8, 9, 30, 0, 0, ZoneOffset.ofHours(8));

        List<Object[]> materials = List.of(
                materialRow(analysisId, firstAnalysisItemId, materialGoodsId,
                        materialUnitId, null, "1", "6", "0"),
                materialRow(analysisId, secondAnalysisItemId, materialGoodsId,
                        materialUnitId, null, "1", "6", "0"));
        List<UUID> selected = List.of(firstSalesItemId, secondSalesItemId);

        EntityManager firstPriorityEm = projectionEntityManager(List.of(
                sourceRow(analysisId, firstAnalysisItemId, firstSalesItemId,
                        analyzedAt, "10", "0", "0", LocalDate.of(2026, 8, 20), 0,
                        "6", "6", null),
                sourceRow(analysisId, secondAnalysisItemId, secondSalesItemId,
                        analyzedAt, "10", "0", "0", LocalDate.of(2026, 8, 19), 1,
                        "0", "0", null)),
                materials);
        Map<UUID, List<PlanProgressLine.MaterialAnalysisProgress>> firstPriority =
                new SalesOrderPlanProgressQuery(firstPriorityEm).load(selected);
        assertThat(firstPriority.get(firstSalesItemId).getFirst().readyNowQty())
                .isEqualByComparingTo("6");
        assertThat(firstPriority.get(secondSalesItemId).getFirst().readyNowQty())
                .isZero();

        EntityManager secondPriorityEm = projectionEntityManager(List.of(
                sourceRow(analysisId, secondAnalysisItemId, secondSalesItemId,
                        analyzedAt, "10", "0", "0", LocalDate.of(2026, 8, 19), 0,
                        "6", "6", null),
                sourceRow(analysisId, firstAnalysisItemId, firstSalesItemId,
                        analyzedAt, "10", "0", "0", LocalDate.of(2026, 8, 20), 1,
                        "0", "0", null)),
                materials);
        Map<UUID, List<PlanProgressLine.MaterialAnalysisProgress>> secondPriority =
                new SalesOrderPlanProgressQuery(secondPriorityEm).load(selected);
        assertThat(secondPriority.get(firstSalesItemId).getFirst().readyNowQty())
                .isZero();
        assertThat(secondPriority.get(secondSalesItemId).getFirst().readyNowQty())
                .isEqualByComparingTo("6");
        assertThat(secondPriority.values().stream()
                        .map(List::getFirst)
                        .map(PlanProgressLine.MaterialAnalysisProgress::readyNowQty)
                        .reduce(BigDecimal.ZERO, BigDecimal::add))
                .isEqualByComparingTo("6");

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(firstPriorityEm, atLeastOnce()).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues().getFirst())
                .contains("ORDER BY ai.analysis_id, ai.line_priority,")
                .contains("ai.delivery_date NULLS LAST, ai.id");
    }

    @Test
    void dtoSurfaceDoesNotExposeCommercialOrInternalIdentityFields() {
        String fields = Arrays.stream(PlanProgressLine.MaterialAnalysisProgress.class
                        .getRecordComponents())
                .map(component -> component.getName().toLowerCase())
                .collect(Collectors.joining(" "))
                + " "
                + Arrays.stream(PlanProgressLine.SupplyActionProgress.class
                                .getRecordComponents())
                        .map(component -> component.getName().toLowerCase())
                        .collect(Collectors.joining(" "));

        assertThat(fields)
                .doesNotContain("supplier")
                .doesNotContain("price")
                .doesNotContain("employee")
                .doesNotContain("maker")
                .doesNotContain("documentno");
    }

    private static Object[] sourceRow(
            UUID analysisId,
            UUID analysisItemId,
            UUID salesItemId,
            OffsetDateTime analyzedAt,
            String requested,
            String submitted,
            String approved,
            LocalDate deliveryDate,
            int priority,
            String readyNow,
            String readyByDate,
            LocalDate expectedReadyDate) {
        return new Object[]{
                analysisId, analysisItemId, salesItemId, "ACTIVE", analyzedAt,
                new BigDecimal(requested), new BigDecimal(submitted),
                new BigDecimal(approved), deliveryDate, priority,
                new BigDecimal(readyNow), new BigDecimal(readyByDate), expectedReadyDate
        };
    }

    private static Object[] materialRow(
            UUID analysisId,
            UUID analysisItemId,
            UUID goodsId,
            UUID unitId,
            LocalDate expectedReadyDate) {
        return materialRow(analysisId, analysisItemId, goodsId, unitId,
                expectedReadyDate, "2", "20", "20");
    }

    private static Object[] materialRow(
            UUID analysisId,
            UUID analysisItemId,
            UUID goodsId,
            UUID unitId,
            LocalDate expectedReadyDate,
            String perProductQty,
            String availableQty,
            String inboundQty) {
        return new Object[]{
                analysisId, analysisItemId, goodsId, null, unitId, 1,
                new BigDecimal(perProductQty), new BigDecimal(availableQty),
                new BigDecimal(inboundQty), expectedReadyDate
        };
    }

    private static EntityManager projectionEntityManager(
            List<Object[]> sourceRows,
            List<Object[]> materialRows) {
        Query sourceQuery = queryReturning(sourceRows);
        Query materialQuery = queryReturning(materialRows);
        Query actionQuery = queryReturning(List.of());
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("FROM production_material_analysis_items ai")) {
                return sourceQuery;
            }
            if (sql.contains("FROM production_material_analysis_materials material")) {
                return materialQuery;
            }
            if (sql.contains("FROM preplan_supply_action_allocations allocation")) {
                return actionQuery;
            }
            throw new AssertionError("Unexpected SQL: " + sql);
        });
        return em;
    }

    private static Query queryReturning(List<?> rows) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(rows);
        return query;
    }
}
