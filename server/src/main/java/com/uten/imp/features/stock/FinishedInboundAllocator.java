package com.uten.imp.features.stock;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * Pure two-layer FIFO allocator for finished-goods inbound quantities.
 *
 * <p>Layer one always allocates to production-plan items. Layer two is optional:
 * only plan items that have {@code plan_order_item_links} allocate their chunk
 * to sales-order items. A self-made/manual plan without links therefore still
 * advances {@code production_plan_items.iqty}, while a linked plan can never
 * credit more than an individual order allocation.
 */
public final class FinishedInboundAllocator {

    private FinishedInboundAllocator() {
    }

    record PlanItemCandidate(
            UUID planItemId,
            UUID unitId,
            BigDecimal unitRate,
            BigDecimal remaining) {
        PlanItemCandidate {
            unitRate = positiveRate(unitRate);
            remaining = positive(remaining);
        }
    }

    record PlanItemAllocation(
            UUID planItemId,
            UUID unitId,
            BigDecimal unitRate,
            BigDecimal quantity) {
        PlanItemAllocation {
            unitRate = positiveRate(unitRate);
            quantity = positive(quantity);
        }

        BigDecimal baseQuantity() {
            return toBase(quantity);
        }

        BigDecimal toBase(BigDecimal lineQuantity) {
            return positive(lineQuantity).multiply(positiveRate(unitRate));
        }
    }

    record LinkCandidate(UUID linkId, UUID orderItemId, BigDecimal remaining) {
    }

    record LinkAllocation(UUID linkId, UUID orderItemId, BigDecimal quantity) {
    }

    record Result<T>(List<T> allocations, BigDecimal unallocated) {
        Result {
            allocations = List.copyOf(allocations);
            unallocated = positive(unallocated);
        }

        boolean fullyAllocated() {
            return unallocated.signum() == 0;
        }
    }

    /** Only approved good production that has not already been inbound is eligible. */
    public static BigDecimal reportedRemaining(BigDecimal finishedQty, BigDecimal inboundQty) {
        BigDecimal finished = positive(finishedQty);
        BigDecimal inbound = positive(inboundQty);
        return positive(finished.subtract(inbound));
    }

    static Result<PlanItemAllocation> allocatePlanItems(
            BigDecimal requested, List<PlanItemCandidate> candidates) {
        BigDecimal remaining = positive(requested);
        if (remaining.signum() == 0) {
            return new Result<>(List.of(), BigDecimal.ZERO);
        }
        if (candidates == null || candidates.isEmpty()) {
            return new Result<>(List.of(), remaining);
        }

        List<PlanItemAllocation> allocations = new ArrayList<>();
        for (PlanItemCandidate candidate : candidates) {
            if (remaining.signum() == 0) {
                break;
            }
            BigDecimal chunk = remaining.min(positive(candidate.remaining()));
            if (chunk.signum() == 0) {
                continue;
            }
            allocations.add(new PlanItemAllocation(
                    candidate.planItemId(),
                    candidate.unitId(),
                    positiveRate(candidate.unitRate()),
                    chunk));
            remaining = remaining.subtract(chunk);
        }
        return new Result<>(allocations, remaining);
    }

    static Result<LinkAllocation> allocateLinks(
            BigDecimal requested, List<LinkCandidate> candidates) {
        BigDecimal remaining = positive(requested);
        if (remaining.signum() == 0) {
            return new Result<>(List.of(), BigDecimal.ZERO);
        }
        if (candidates == null || candidates.isEmpty()) {
            return new Result<>(List.of(), remaining);
        }

        List<LinkAllocation> allocations = new ArrayList<>();
        for (LinkCandidate candidate : candidates) {
            if (remaining.signum() == 0) {
                break;
            }
            BigDecimal chunk = remaining.min(positive(candidate.remaining()));
            if (chunk.signum() == 0) {
                continue;
            }
            allocations.add(new LinkAllocation(
                    candidate.linkId(),
                    candidate.orderItemId(),
                    chunk));
            remaining = remaining.subtract(chunk);
        }
        return new Result<>(allocations, remaining);
    }

    private static BigDecimal positive(BigDecimal value) {
        return value == null || value.signum() <= 0 ? BigDecimal.ZERO : value;
    }

    private static BigDecimal positiveRate(BigDecimal value) {
        BigDecimal rate = value == null ? BigDecimal.ONE : value;
        if (rate.signum() <= 0) {
            throw new IllegalArgumentException("unitRate must be greater than zero");
        }
        return rate;
    }
}
