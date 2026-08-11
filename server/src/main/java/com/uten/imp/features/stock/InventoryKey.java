package com.uten.imp.features.stock;

import java.util.UUID;

/**
 * Global inventory/reservation serialization key.
 *
 * <p>The warehouse is deliberately not part of the key: sales reservations can
 * be global ({@code warehouse_id IS NULL}), so a warehouse-local movement must
 * serialize with the same goods/color reservation total.
 */
public record InventoryKey(UUID goodsId, UUID colorId) implements Comparable<InventoryKey> {

    private static final String NO_COLOR = "00000000-0000-0000-0000-000000000000";

    public InventoryKey {
        if (goodsId == null) {
            throw new IllegalArgumentException("goodsId is required for an inventory lock");
        }
    }

    String canonical() {
        return goodsId + ":" + (colorId == null ? NO_COLOR : colorId.toString());
    }

    @Override
    public int compareTo(InventoryKey other) {
        return canonical().compareTo(other.canonical());
    }
}
