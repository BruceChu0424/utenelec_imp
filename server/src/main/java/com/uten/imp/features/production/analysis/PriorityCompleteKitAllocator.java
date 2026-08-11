package com.uten.imp.features.production.analysis;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Pure shared-pool allocator used by every persisted pre-plan readiness projection. */
final class PriorityCompleteKitAllocator {

    private PriorityCompleteKitAllocator() {
    }

    static <K> Result<K> allocate(List<Demand<K>> rawDemands, Map<K, BigDecimal> rawStock) {
        List<Demand<K>> demands = new ArrayList<>(rawDemands);
        demands.sort(Comparator.comparingInt(Demand<K>::priority)
                .thenComparing(value -> value.itemId().toString()));
        Map<K, BigDecimal> pool = new LinkedHashMap<>();
        rawStock.forEach((key, value) -> pool.put(
                key, value.max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN)));
        Map<UUID, BigDecimal> ready = new LinkedHashMap<>();

        for (Demand<K> demand : demands) {
            BigDecimal readyQty = demand.blocked()
                    ? BigDecimal.ZERO.setScale(4)
                    : maxReady(demand.quantity(), demand.usage(), pool);
            ready.put(demand.itemId(), readyQty);
            consume(readyQty, demand.usage(), pool);
        }

        Map<UUID, Map<K, BigDecimal>> allocated = new LinkedHashMap<>();
        Map<UUID, Map<K, BigDecimal>> shortage = new LinkedHashMap<>();
        for (Demand<K> demand : demands) {
            Map<K, BigDecimal> itemAllocated = new LinkedHashMap<>();
            Map<K, BigDecimal> itemShortage = new LinkedHashMap<>();
            BigDecimal completeQty = ready.getOrDefault(demand.itemId(), BigDecimal.ZERO);
            for (Map.Entry<K, BigDecimal> entry : demand.usage().entrySet()) {
                BigDecimal required = entry.getValue().multiply(demand.quantity())
                        .setScale(4, RoundingMode.CEILING);
                BigDecimal kitAllocated = entry.getValue().multiply(completeQty)
                        .setScale(4, RoundingMode.CEILING).min(required);
                BigDecimal free = pool.getOrDefault(entry.getKey(), BigDecimal.ZERO);
                BigDecimal extra = required.subtract(kitAllocated)
                        .max(BigDecimal.ZERO).min(free);
                pool.put(entry.getKey(), free.subtract(extra).max(BigDecimal.ZERO));
                BigDecimal totalAllocated = kitAllocated.add(extra).min(required);
                itemAllocated.put(entry.getKey(), totalAllocated);
                itemShortage.put(entry.getKey(), required.subtract(totalAllocated)
                        .max(BigDecimal.ZERO));
            }
            allocated.put(demand.itemId(), Map.copyOf(itemAllocated));
            shortage.put(demand.itemId(), Map.copyOf(itemShortage));
        }
        return new Result<>(Map.copyOf(ready), Map.copyOf(allocated),
                Map.copyOf(shortage), Map.copyOf(pool));
    }

    private static <K> BigDecimal maxReady(
            BigDecimal demand, Map<K, BigDecimal> usage, Map<K, BigDecimal> pool) {
        if (usage.isEmpty()) return demand.setScale(4, RoundingMode.DOWN);
        BigDecimal ready = demand;
        for (Map.Entry<K, BigDecimal> entry : usage.entrySet()) {
            ready = ready.min(pool.getOrDefault(entry.getKey(), BigDecimal.ZERO)
                    .divide(entry.getValue(), 4, RoundingMode.DOWN));
        }
        return ready.max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN);
    }

    private static <K> void consume(
            BigDecimal quantity, Map<K, BigDecimal> usage, Map<K, BigDecimal> pool) {
        for (Map.Entry<K, BigDecimal> entry : usage.entrySet()) {
            BigDecimal consumed = entry.getValue().multiply(quantity)
                    .setScale(4, RoundingMode.CEILING);
            pool.compute(entry.getKey(), (ignored, current) ->
                    (current == null ? BigDecimal.ZERO : current)
                            .subtract(consumed).max(BigDecimal.ZERO));
        }
    }

    record Demand<K>(UUID itemId, int priority, BigDecimal quantity,
                     Map<K, BigDecimal> usage, boolean blocked) {
    }

    record Result<K>(Map<UUID, BigDecimal> readyByItem,
                     Map<UUID, Map<K, BigDecimal>> allocatedByItem,
                     Map<UUID, Map<K, BigDecimal>> shortageByItem,
                     Map<K, BigDecimal> remainingStock) {
    }
}
