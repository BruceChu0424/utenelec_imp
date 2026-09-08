package com.uten.imp.application.concurrency;

import java.util.Collection;
import java.util.HashSet;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/** Immutable, directed lock footprint; discovered without acquiring row locks. */
public record FulfillmentMutationLockPlan(
        Set<CommercialSource> commercialSources,
        Set<InventoryDimension> inventoryDimensions,
        Set<UUID> mainWarehouseIds,
        Set<UUID> analysisIds,
        String fingerprint) {

    public FulfillmentMutationLockPlan {
        commercialSources = Set.copyOf(commercialSources == null ? Set.of() : commercialSources);
        inventoryDimensions = Set.copyOf(inventoryDimensions == null ? Set.of() : inventoryDimensions);
        mainWarehouseIds = Set.copyOf(mainWarehouseIds == null ? Set.of() : mainWarehouseIds);
        analysisIds = Set.copyOf(analysisIds == null ? Set.of() : analysisIds);
        if (fingerprint == null || fingerprint.isBlank()) {
            throw new IllegalArgumentException("A source fingerprint is required for a mutation lock plan");
        }
    }

    /** Stable type order, followed by UUID text order (the PostgreSQL UUID order). */
    public enum CommercialType {
        SALES_ORDER("sales_orders", "sales_order_items", "order_id"),
        PURCHASE_REQUEST("purchase_requests", "purchase_request_items", "request_id"),
        SUBCONTRACT_APPLICATION("subcontract_applications", "subcontract_application_items", "application_id"),
        PURCHASE_ORDER("purchase_orders", "purchase_order_items", "order_id"),
        SUBCONTRACT_ORDER("subcontract_orders", "subcontract_order_items", "order_id");

        final String headerTable;
        final String itemTable;
        final String parentColumn;
        CommercialType(String headerTable, String itemTable, String parentColumn) {
            this.headerTable = headerTable;
            this.itemTable = itemTable;
            this.parentColumn = parentColumn;
        }
    }

    public record CommercialSource(CommercialType type, UUID id) implements Comparable<CommercialSource> {
        public CommercialSource { Objects.requireNonNull(type); Objects.requireNonNull(id); }
        @Override public int compareTo(CommercialSource other) {
            int typeOrder = Integer.compare(type.ordinal(), other.type.ordinal());
            return typeOrder != 0 ? typeOrder : id.toString().compareTo(other.id.toString());
        }
    }

    public record InventoryDimension(UUID goodsId, UUID colorId) implements Comparable<InventoryDimension> {
        public InventoryDimension { Objects.requireNonNull(goodsId); }
        @Override public int compareTo(InventoryDimension other) {
            int goodsOrder = goodsId.toString().compareTo(other.goodsId.toString());
            if (goodsOrder != 0) return goodsOrder;
            String color = colorId == null ? "00000000-0000-0000-0000-000000000000" : colorId.toString();
            String otherColor = other.colorId == null ? "00000000-0000-0000-0000-000000000000" : other.colorId.toString();
            return color.compareTo(otherColor);
        }
    }

    public static FulfillmentMutationLockPlan merge(
            String fingerprint, Collection<FulfillmentMutationLockPlan> parts) {
        Set<CommercialSource> sources = new HashSet<>();
        Set<InventoryDimension> stock = new HashSet<>();
        Set<UUID> warehouses = new HashSet<>();
        Set<UUID> analyses = new HashSet<>();
        for (FulfillmentMutationLockPlan part : parts) {
            sources.addAll(part.commercialSources());
            stock.addAll(part.inventoryDimensions());
            warehouses.addAll(part.mainWarehouseIds());
            analyses.addAll(part.analysisIds());
        }
        return new FulfillmentMutationLockPlan(sources, stock, warehouses, analyses, fingerprint);
    }
}
