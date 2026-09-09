package com.uten.imp.features.production.mrp;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProductionPlanningMainWarehouseBudgetTest {
    private final UUID goods = UUID.randomUUID();
    private final UUID main = UUID.randomUUID();

    @Test void initialPlanningCanUseEightyAcrossTwoLeavesAfterOneTwentyBuffer() {
        assertThat(availability(List.of(leaf("30", "0", "0", true), leaf("70", "0", "0", true))))
                .isEqualByComparingTo("80");
    }

    @Test void qualifiedOwnStockIsProtectedWhilePublicStockKeepsOneBuffer() {
        assertThat(availability(List.of(leaf("0", "30", "30", true), leaf("70", "0", "0", true))))
                .isEqualByComparingTo("80");
    }

    @Test void otherMainOrDefectiveWarehouseContributesOnlyItsQualifiedOwnedQuantity() {
        assertThat(availability(List.of(leaf("100", "40", "30", false), leaf("70", "0", "0", true))))
                .isEqualByComparingTo("80");
    }

    @Test void qualifiedOwnershipCannotExceedPhysicalFreeAfterOtherReservations() {
        assertThat(availability(List.<Object[]>of(leaf("-10", "30", "30", false))))
                .isEqualByComparingTo("20");
    }

    private Object[] leaf(String available, String own, String qualified, boolean publicAllowed) {
        return new Object[]{goods, null, UUID.randomUUID(), new BigDecimal(available),
                new BigDecimal(own), new BigDecimal(qualified), new BigDecimal("20"), publicAllowed};
    }

    private BigDecimal availability(List<Object[]> rows) {
        EntityManager em = mock(EntityManager.class);
        Query identity = query(List.<Object[]>of(new Object[]{UUID.randomUUID(), UUID.randomUUID()}));
        Query stock = query(rows);
        when(em.createNativeQuery(anyString())).thenAnswer(call ->
                call.getArgument(0, String.class).contains("material_analysis_id IS NOT NULL") ? identity : stock);
        var line = mock(CompleteKitAllocator.ProductLine.class);
        when(line.materials()).thenReturn(List.of(new CompleteKitAllocator.MaterialUsage(
                goods, null, UUID.randomUUID(), BigDecimal.ONE, "BUY")));
        Map<CompleteKitAllocator.MaterialKey, BigDecimal> result = ReflectionTestUtils.invokeMethod(
                new ProductionExecutionPlanningService(em), "warehouseAvailability", UUID.randomUUID(), main, List.of(line));
        return result.get(new CompleteKitAllocator.MaterialKey(goods, null));
    }

    private Query query(List<?> rows) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(rows);
        return query;
    }
}
