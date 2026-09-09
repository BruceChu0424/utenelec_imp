package com.uten.imp.common.inventory;

import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Base-unit public buffer is held once per main warehouse, goods and color. */
public final class MainWarehouseStockBudget {
    private MainWarehouseStockBudget() {}

    public static BigDecimal publicBudget(BigDecimal unprotectedFree, BigDecimal safety) {
        return positive(unprotectedFree).subtract(positive(safety)).max(BigDecimal.ZERO);
    }

    public static BigDecimal safetyGap(BigDecimal safety, BigDecimal publicFree, BigDecimal openSupply) {
        return positive(safety).subtract(positive(publicFree)).subtract(positive(openSupply)).max(BigDecimal.ZERO);
    }

    public record Leaf<K>(K key, BigDecimal publicFree, BigDecimal owned, BigDecimal qualifiedOwned) {}

    /** Stable caller order; legacy owned slices precede shared stock, qualified slices are protected. */
    public static <K> Map<K, BigDecimal> distribute(List<Leaf<K>> leaves, BigDecimal safety) {
        Map<K, BigDecimal> usable = new LinkedHashMap<>();
        BigDecimal unprotected = BigDecimal.ZERO;
        for (Leaf<K> leaf : leaves) {
            BigDecimal qualified = positive(leaf.qualifiedOwned()).min(positive(leaf.owned()));
            if (usable.putIfAbsent(java.util.Objects.requireNonNull(leaf.key()), qualified) != null)
                throw new IllegalArgumentException("Duplicate physical warehouse/material key in stock budget");
            unprotected = unprotected.add(positive(leaf.publicFree()))
                    .add(positive(leaf.owned()).subtract(qualified));
        }
        BigDecimal remaining = publicBudget(unprotected, safety);
        for (Leaf<K> leaf : leaves) {
            BigDecimal legacyOwned = positive(leaf.owned()).subtract(usable.get(leaf.key()));
            BigDecimal take = legacyOwned.min(remaining);
            usable.merge(leaf.key(), take, BigDecimal::add);
            remaining = remaining.subtract(take);
        }
        for (Leaf<K> leaf : leaves) {
            BigDecimal take = positive(leaf.publicFree()).min(remaining);
            usable.merge(leaf.key(), take, BigDecimal::add);
            remaining = remaining.subtract(take);
        }
        return Map.copyOf(usable);
    }

    private static BigDecimal positive(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value.max(BigDecimal.ZERO);
    }
}
