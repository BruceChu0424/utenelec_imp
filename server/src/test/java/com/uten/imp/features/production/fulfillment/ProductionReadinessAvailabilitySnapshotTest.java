package com.uten.imp.features.production.fulfillment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.allocation.ProductionMaterialAllocationFacade;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Exercises the real promotion decision up to the unchanged allocation boundary. */
class ProductionReadinessAvailabilitySnapshotTest {
    @Test
    void continuousPromotionReadsAvailabilityOnceAfterItsDimensionLock() {
        var fixture = new Fixture(true);
        fixture.promoteToAllocation();
        assertEquals(1, fixture.availabilityReads);
        assertEquals(1, fixture.anomalyReads);
        assertEquals(List.of(new BigDecimal("5")), fixture.allocatedQuantities());
    }

    @Test
    void anotherPromotionReadsTheChangedBalanceAgain() {
        var fixture = new Fixture(true);
        fixture.promoteToAllocation();
        fixture.physical = new BigDecimal("2");
        fixture.promoteToAllocation();
        assertEquals(2, fixture.availabilityReads);
        assertEquals(2, fixture.anomalyReads);
        assertEquals(List.of(new BigDecimal("5"), new BigDecimal("2")), fixture.allocatedQuantities());
    }

    @Test
    void repeatedMaterialDemandsShareOnePublicBudget() {
        var fixture = new Fixture(true);
        fixture.demands.add(UUID.randomUUID());
        fixture.required = new BigDecimal("7");
        fixture.physical = new BigDecimal("10");
        fixture.promoteToAllocation();
        assertEquals(List.of(new BigDecimal("7"), new BigDecimal("3")), fixture.allocatedQuantities());
        assertEquals(1, fixture.availabilityReads);
    }

    @Test
    void fullKitStillRequiresEveryDemandAndDoesNotAllocatePartialStock() {
        var fixture = new Fixture(false);
        fixture.promote();
        assertTrue(fixture.allocations.isEmpty());
        assertEquals(1, fixture.availabilityReads);
        assertEquals(1, fixture.anomalyReads);
    }

    @Test
    void legacyLineSideAnomalyStillFailsBeforeAllocation() {
        var fixture = new Fixture(true);
        fixture.anomaly = true;
        ApiException failure = assertThrows(ApiException.class, fixture::promote);
        assertTrue(failure.getMessage().contains("历史非来源库存流水"));
        assertTrue(fixture.allocations.isEmpty());
        assertEquals(0, fixture.availabilityReads);
        assertEquals(1, fixture.anomalyReads);
    }

    private static final class AllocationReached extends RuntimeException {}

    private static final class Fixture {
        private final UUID warehouse = UUID.randomUUID();
        private final UUID segment = UUID.randomUUID();
        private final UUID goods = UUID.randomUUID();
        private final UUID unit = UUID.randomUUID();
        private final List<UUID> demands = new ArrayList<>(List.of(UUID.randomUUID()));
        private final List<ProductionMaterialAllocationFacade.AllocationRequest> allocations = new ArrayList<>();
        private final ProductionExecutionReadinessService service = mock(
                ProductionExecutionReadinessService.class, CALLS_REAL_METHODS);
        private BigDecimal physical = new BigDecimal("5");
        private BigDecimal required = new BigDecimal("10");
        private boolean anomaly;
        private boolean locked;
        private int availabilityReads;
        private int anomalyReads;

        Fixture(boolean continuous) {
            EntityManager em = mock(EntityManager.class);
            var allocation = mock(ProductionMaterialAllocationFacade.class);
            var actor = mock(SecurityContextCurrentUser.class);
            when(actor.requireId()).thenReturn(UUID.randomUUID());
            when(actor.requireEmployeeId()).thenReturn(UUID.randomUUID());
            ReflectionTestUtils.setField(service, "em", em);
            ReflectionTestUtils.setField(service, "stockAllocation", allocation);
            ReflectionTestUtils.setField(service, "currentUser", actor);
            doAnswer(call -> { locked = true; return null; }).when(allocation).lockMaterialDimensions(anyCollection());
            when(allocation.allocate(anyList(), anyBoolean())).thenAnswer(call -> {
                allocations.addAll(call.getArgument(0));
                throw new AllocationReached();
            });
            when(em.createNativeQuery(anyString())).thenAnswer(call -> {
                String sql = call.getArgument(0);
                Query query = mock(Query.class, RETURNS_SELF);
                if (sql.contains("SELECT segment.package_id")) {
                    when(query.getResultList()).thenReturn(Collections.singletonList(new Object[]{
                            UUID.randomUUID(), UUID.randomUUID(), "PLAN", warehouse,
                            continuous ? "IN_PROGRESS" : "WAITING", null, null,
                            UUID.randomUUID(), UUID.randomUUID(), 1L, continuous}));
                } else if (sql.contains("SELECT DISTINCT goods_id, color_id")) {
                    when(query.getResultList()).thenReturn(Collections.singletonList(new Object[]{goods, null}));
                } else if (sql.contains("SELECT id, goods_id, color_id")) {
                    when(query.getResultList()).thenAnswer(ignored -> demands.stream().map(id ->
                            new Object[]{id, goods, null, unit, required, false}).toList());
                } else if (sql.contains("SUM(r.qty-r.released_qty)")) {
                    when(query.getResultList()).thenAnswer(ignored -> demands.stream().map(id ->
                            new Object[]{id, BigDecimal.ZERO, BigDecimal.ZERO}).toList());
                } else if (sql.contains("production_workshop_direct_legacy_anomalies")) {
                    anomalyReads++;
                    assertTrue(locked, "availability must follow the actual dimension-lock call");
                    when(query.getResultList()).thenReturn(anomaly ? List.of("Legacy rack") : List.of());
                } else if (sql.contains(" AS public_allowed")) {
                    availabilityReads++;
                    assertTrue(locked);
                    when(query.getResultList()).thenAnswer(ignored -> demands.stream().map(id -> new Object[]{
                            id, warehouse, physical, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                            BigDecimal.ZERO, true, true, "G", "Goods", "Warehouse", false, null, BigDecimal.ZERO}).toList());
                } else {
                    when(query.getResultList()).thenReturn(List.of());
                    when(query.getSingleResult()).thenReturn(sql.contains("SELECT fn_warehouse_same_main"));
                }
                return query;
            });
        }

        void promote() {
            locked = false;
            ReflectionTestUtils.invokeMethod(service, "tryPromote", segment, segment, warehouse,
                    ProductionExecutionReadinessService.ReceiptKind.RECHECK, null, true, false, false);
        }

        void promoteToAllocation() {
            assertThrows(AllocationReached.class, this::promote);
        }

        List<BigDecimal> allocatedQuantities() {
            return allocations.stream().map(ProductionMaterialAllocationFacade.AllocationRequest::requiredQty).toList();
        }
    }
}
