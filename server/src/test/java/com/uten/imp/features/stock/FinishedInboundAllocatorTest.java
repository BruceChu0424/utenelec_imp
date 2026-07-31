package com.uten.imp.features.stock;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class FinishedInboundAllocatorTest {

    @Test
    void mergedPlanItemChunkIsSplitAcrossItsOrderLinks() {
        UUID firstOrder = UUID.randomUUID();
        UUID secondOrder = UUID.randomUUID();

        FinishedInboundAllocator.Result<FinishedInboundAllocator.LinkAllocation> result =
                FinishedInboundAllocator.allocateLinks(new BigDecimal("120"), List.of(
                        linkCandidate(firstOrder, "100"),
                        linkCandidate(secondOrder, "50")));

        assertTrue(result.fullyAllocated());
        assertEquals(2, result.allocations().size());
        assertEquals(firstOrder, result.allocations().get(0).orderItemId());
        assertEquals(new BigDecimal("100"), result.allocations().get(0).quantity());
        assertEquals(secondOrder, result.allocations().get(1).orderItemId());
        assertEquals(new BigDecimal("20"), result.allocations().get(1).quantity());
    }

    @Test
    void planOnlySubplanStillAllocatesAtThePlanItemLayer() {
        UUID firstPlanItem = UUID.randomUUID();
        UUID secondPlanItem = UUID.randomUUID();

        FinishedInboundAllocator.Result<FinishedInboundAllocator.PlanItemAllocation> result =
                FinishedInboundAllocator.allocatePlanItems(new BigDecimal("80"), List.of(
                        new FinishedInboundAllocator.PlanItemCandidate(
                                firstPlanItem, UUID.randomUUID(), BigDecimal.ONE, new BigDecimal("50")),
                        new FinishedInboundAllocator.PlanItemCandidate(
                                secondPlanItem, UUID.randomUUID(), BigDecimal.ONE, new BigDecimal("50"))));

        assertTrue(result.fullyAllocated());
        assertEquals(List.of(new BigDecimal("50"), new BigDecimal("30")),
                result.allocations().stream()
                        .map(FinishedInboundAllocator.PlanItemAllocation::quantity)
                        .toList());
    }

    @Test
    void insufficientPlanCapacityIsExposedBeforeAnyWrite() {
        FinishedInboundAllocator.Result<FinishedInboundAllocator.PlanItemAllocation> result =
                FinishedInboundAllocator.allocatePlanItems(new BigDecimal("80"), List.of(
                        new FinishedInboundAllocator.PlanItemCandidate(
                                UUID.randomUUID(), UUID.randomUUID(),
                                BigDecimal.ONE, new BigDecimal("40"))));

        assertEquals(new BigDecimal("40"), result.unallocated());
        assertEquals(new BigDecimal("40"), result.allocations().getFirst().quantity());
    }


    @Test
    void planLineQuantityKeepsItsUnitRateForInventoryReservation() {
        FinishedInboundAllocator.Result<FinishedInboundAllocator.PlanItemAllocation> result =
                FinishedInboundAllocator.allocatePlanItems(new BigDecimal("2"), List.of(
                        new FinishedInboundAllocator.PlanItemCandidate(
                                UUID.randomUUID(), UUID.randomUUID(),
                                new BigDecimal("12"), new BigDecimal("5"))));

        assertEquals(new BigDecimal("2"), result.allocations().getFirst().quantity());
        assertEquals(new BigDecimal("24"), result.allocations().getFirst().baseQuantity());
    }

    @Test
    void insufficientLinkCapacityIsExposedBeforeAnyWrite() {
        FinishedInboundAllocator.Result<FinishedInboundAllocator.LinkAllocation> result =
                FinishedInboundAllocator.allocateLinks(new BigDecimal("80"), List.of(
                        linkCandidate(UUID.randomUUID(), "15"),
                        linkCandidate(UUID.randomUUID(), "25")));

        assertEquals(new BigDecimal("40"), result.unallocated());
        assertEquals(List.of(new BigDecimal("15"), new BigDecimal("25")),
                result.allocations().stream()
                        .map(FinishedInboundAllocator.LinkAllocation::quantity)
                        .toList());
    }

    @Test
    void smallestStoredTailIsNeverTreatedAsFullyAllocated() {
        FinishedInboundAllocator.Result<FinishedInboundAllocator.PlanItemAllocation> result =
                FinishedInboundAllocator.allocatePlanItems(new BigDecimal("1.0000"), List.of(
                        new FinishedInboundAllocator.PlanItemCandidate(
                                UUID.randomUUID(), UUID.randomUUID(),
                                BigDecimal.ONE, new BigDecimal("0.9999"))));

        assertEquals(new BigDecimal("0.0001"), result.unallocated());
        assertFalse(result.fullyAllocated());
    }

    @Test
    void inboundCapacityIsLimitedToApprovedGoodReports() {
        assertEquals(new BigDecimal("30"),
                FinishedInboundAllocator.reportedRemaining(
                        new BigDecimal("80"), new BigDecimal("50")));
    }

    @Test
    void noReportMeansNoFinishedInboundCapacity() {
        assertEquals(BigDecimal.ZERO,
                FinishedInboundAllocator.reportedRemaining(
                        BigDecimal.ZERO, BigDecimal.ZERO));
    }

    @Test
    void historicalInboundAboveReportedQtyCannotCreateMoreInbound() {
        assertEquals(BigDecimal.ZERO,
                FinishedInboundAllocator.reportedRemaining(
                        new BigDecimal("40"), new BigDecimal("50")));
    }

    @Test
    void zeroUnitRateFailsFast() {
        assertThrows(IllegalArgumentException.class,
                () -> new FinishedInboundAllocator.PlanItemCandidate(
                        UUID.randomUUID(), UUID.randomUUID(),
                        BigDecimal.ZERO, BigDecimal.ONE));
    }

    @Test
    void negativeUnitRateFailsFast() {
        assertThrows(IllegalArgumentException.class,
                () -> new FinishedInboundAllocator.PlanItemCandidate(
                        UUID.randomUUID(), UUID.randomUUID(),
                        new BigDecimal("-1"), BigDecimal.ONE));
    }

    private static FinishedInboundAllocator.LinkCandidate linkCandidate(
            UUID orderItemId, String linkRemaining) {
        return new FinishedInboundAllocator.LinkCandidate(
                UUID.randomUUID(),
                orderItemId,
                new BigDecimal(linkRemaining));
    }
}
