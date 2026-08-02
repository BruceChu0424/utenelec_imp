package com.uten.imp.features.production.mrp;

import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionExecutionPlanningServiceProductSpecTest {

    @Test
    void previewDtoLoadsProductSpecFromGoods() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        UUID goodsId = UUID.randomUUID();
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{goodsId, "M8 x 30"}));

        ExecutionSegmentPreview preview =
                new ProductionExecutionPlanningService(em)
                        .toPreview(allocation(goodsId))
                        .getFirst();

        assertThat(preview.productSpec()).isEqualTo("M8 x 30");
        verify(query).setParameter("goodsIds", List.of(goodsId));
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue().replaceAll("\\s+", " ").trim())
                .contains("SELECT id, spec FROM goods")
                .contains("AND is_deleted = FALSE");
    }

    @Test
    void emptyAllocationDoesNotQueryGoods() {
        EntityManager em = mock(EntityManager.class);
        ProductionExecutionPlanningService service =
                new ProductionExecutionPlanningService(em);

        assertThat(service.toPreview(new CompleteKitAllocator.Allocation(
                List.of(), Map.of())))
                .isEmpty();

        verify(em, never()).createNativeQuery(anyString());
    }

    private static CompleteKitAllocator.Allocation allocation(UUID goodsId) {
        UUID sourceItemId = UUID.randomUUID();
        CompleteKitAllocator.ProductLine line =
                new CompleteKitAllocator.ProductLine(
                        sourceItemId,
                        1,
                        goodsId,
                        null,
                        UUID.randomUUID(),
                        BigDecimal.ONE,
                        BigDecimal.TEN,
                        LocalDate.of(2026, 8, 2),
                        LocalDate.of(2026, 8, 3),
                        null,
                        null,
                        null,
                        "FG-001",
                        "Finished good",
                        new CompleteKitAllocator.Priority(
                                LocalDate.of(2026, 8, 2), 1, sourceItemId),
                        List.of(),
                        "bom-fingerprint");
        CompleteKitAllocator.SegmentAllocation segment =
                new CompleteKitAllocator.SegmentAllocation(
                        "segment-1",
                        line,
                        ProductionExecutionSegment.STATUS_WAITING,
                        BigDecimal.TEN,
                        List.of());
        return new CompleteKitAllocator.Allocation(
                List.of(segment), Map.of());
    }
}
