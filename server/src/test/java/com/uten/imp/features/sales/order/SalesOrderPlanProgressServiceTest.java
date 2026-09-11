package com.uten.imp.features.sales.order;

import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.order.dto.PlanProgressLine;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SalesOrderPlanProgressServiceTest {

    @Test
    void keepsDraftApprovedReleasedAndReversedBatchesWithoutApprovedDuplicate() {
        UUID orderId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        UUID analysisId = UUID.randomUUID();
        UUID approvedFormalLinkId = UUID.randomUUID();
        UUID draftPlanId = UUID.randomUUID();
        UUID approvedPlanId = UUID.randomUUID();
        UUID reversedPlanId = UUID.randomUUID();
        UUID releasedPlanId = UUID.randomUUID();

        SalesOrder order = new SalesOrder();
        order.setId(orderId);
        order.setOwnerEmployeeId(UUID.randomUUID());
        SalesOrderRepository orderRepo = mock(SalesOrderRepository.class);
        when(orderRepo.findById(orderId)).thenReturn(Optional.of(order));
        SalesDocumentAccessPolicy accessPolicy = mock(SalesDocumentAccessPolicy.class);

        Query orderLines = queryReturning(Collections.singletonList(new Object[]{
                orderItemId, 1, "FG-001", "Finished product", "Spec", null, "pcs",
                new BigDecimal("20.0000"), BigDecimal.ZERO,
                new BigDecimal("7.0000"), new BigDecimal("2.0000"), BigDecimal.ZERO,
                (short) 4,
                // V545 剩余未排量列：20 − 0 − max(7−2,0) = 15
                new BigDecimal("15.0000")
        }));
        Query executionSegments = queryReturning(List.of());
        Query formalPlans = queryReturning(List.of(
                new Object[]{
                        null, orderItemId, draftPlanId, "PP-DRAFT", (short) 0,
                        false, LocalDate.of(2026, 8, 10), new BigDecimal("2.0000"),
                        BigDecimal.ZERO, BigDecimal.ZERO, "SUBMITTED"
                },
                new Object[]{
                        approvedFormalLinkId, orderItemId, approvedPlanId,
                        "PP-APPROVED", (short) 1, false,
                        LocalDate.of(2026, 8, 9), new BigDecimal("7.0000"),
                        new BigDecimal("2.0000"), new BigDecimal("2.0000"),
                        "APPROVED"
                },
                new Object[]{
                        null, orderItemId, reversedPlanId, "PP-REVERSED", (short) -1,
                        false, LocalDate.of(2026, 8, 8), new BigDecimal("4.0000"),
                        BigDecimal.ZERO, BigDecimal.ZERO, "REVERSED"
                },
                new Object[]{
                        null, orderItemId, releasedPlanId, "PP-RELEASED", (short) 0,
                        false, LocalDate.of(2026, 8, 7), new BigDecimal("3.0000"),
                        BigDecimal.ZERO, BigDecimal.ZERO, "RELEASED"
                }));
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("FROM sales_order_items i") && sql.contains("JOIN goods g")) {
                return orderLines;
            }
            if (sql.contains("FROM execution_segment_sales_allocations allocation")) {
                return executionSegments;
            }
            if (sql.contains("FROM plan_order_item_links l")) {
                return formalPlans;
            }
            throw new AssertionError("Unexpected SQL: " + sql);
        });

        PlanProgressLine.MaterialAnalysisProgress analysis =
                new PlanProgressLine.MaterialAnalysisProgress(
                        analysisId, "PARTIALLY_PLANNED",
                        OffsetDateTime.of(2026, 8, 8, 10, 0, 0, 0,
                                ZoneOffset.ofHours(8)),
                        new BigDecimal("10.0000"), new BigDecimal("2.0000"),
                        new BigDecimal("3.0000"), new BigDecimal("5.0000"),
                        new BigDecimal("4.0000"), new BigDecimal("5.0000"),
                        LocalDate.of(2026, 8, 12), List.of());
        SalesOrderPlanProgressQuery projection = mock(SalesOrderPlanProgressQuery.class);
        when(projection.load(List.of(orderItemId)))
                .thenReturn(Map.of(orderItemId, List.of(analysis)));

        SalesOrderService service = new SalesOrderService(
                orderRepo,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                accessPolicy,
                null,
                null,
                null,
                null,
                em,
                projection,
                null,
                null,
                null,
                null,
                null,
                org.mockito.Mockito.mock(com.uten.imp.features.sales.SalesMutationFootprintService.class));

        PlanProgressLine line = service.planProgress(orderId).getFirst();

        assertThat(line.plannedQty()).isEqualByComparingTo("7");
        assertThat(line.unplannedQty()).isEqualByComparingTo("15");
        assertThat(line.materialAnalyses()).containsExactly(analysis);
        assertThat(line.materialAnalyses().getFirst().submittedQty())
                .isEqualByComparingTo("2");
        assertThat(line.materialAnalyses().getFirst().approvedQty())
                .isEqualByComparingTo("3");
        assertThat(line.links()).extracting(PlanProgressLine.PlanLink::planId)
                .containsExactly(draftPlanId, approvedPlanId, reversedPlanId, releasedPlanId);
        assertThat(line.links()).extracting(PlanProgressLine.PlanLink::allocationStatus)
                .containsExactly("SUBMITTED", "APPROVED", "REVERSED", "RELEASED");
        assertThat(line.links()).filteredOn(link -> link.planId().equals(approvedPlanId))
                .singleElement()
                .satisfies(link -> {
                    assertThat(link.allocatedQty()).isEqualByComparingTo("7");
                    assertThat(link.producedQty()).isEqualByComparingTo("2");
                    assertThat(link.inboundQty()).isEqualByComparingTo("2");
                });

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, atLeastOnce()).createNativeQuery(sql.capture());
        String childSql = sql.getAllValues().stream()
                .filter(value -> value.contains("production_material_analysis_plan_links"))
                .findFirst().orElseThrow();
        assertThat(childSql)
                .contains("UNION ALL")
                .contains("analysis_link.allocation_status")
                .contains("formal_link.is_deleted = FALSE")
                .contains("NOT EXISTS")
                .doesNotContain("supplier")
                .doesNotContain("price")
                .doesNotContain("maker_id");
    }

    private static Query queryReturning(List<?> rows) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(rows);
        return query;
    }
}
