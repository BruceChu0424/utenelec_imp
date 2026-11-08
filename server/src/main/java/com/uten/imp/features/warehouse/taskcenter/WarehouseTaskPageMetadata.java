package com.uten.imp.features.warehouse.taskcenter;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Shared, amount-free metadata shape for inbound and outbound task pages. */
record WarehouseTaskPageMetadata(long total, Map<String,Long> statuses,
        List<WarehouseTaskCenterContracts.StatusFacet> bills) {
    static WarehouseTaskPageMetadata from(List<Object[]> rows) {
        Long total = null;
        Map<String,Long> statuses = new LinkedHashMap<>();
        Map<String,Long> bills = new LinkedHashMap<>();
        for (Object[] row : rows) {
            long count = ((Number)row[2]).longValue();
            switch (String.valueOf(row[0])) {
                case "TOTAL" -> {
                    if (total != null || count < 0) throw new IllegalStateException("Invalid warehouse total");
                    total = count;
                }
                case "STATUS" -> statuses.put(String.valueOf(row[1]), count);
                case "BILL" -> bills.put(String.valueOf(row[1]), count);
                default -> throw new IllegalStateException("Invalid warehouse metadata bucket");
            }
        }
        if (total == null) throw new IllegalStateException("Missing warehouse total");
        return new WarehouseTaskPageMetadata(total, java.util.Collections.unmodifiableMap(statuses),
                bills.entrySet().stream().map(entry -> new WarehouseTaskCenterContracts.StatusFacet(
                        entry.getKey(),entry.getKey(),entry.getValue())).toList());
    }

    /** Buckets arrive as one JSON array on the first row of the merged page statement. */
    static WarehouseTaskPageMetadata fromJson(String buckets) {
        List<Object[]> rows = new java.util.ArrayList<>();
        try {
            for (var bucket : new com.fasterxml.jackson.databind.ObjectMapper().readTree(buckets)) {
                rows.add(new Object[]{bucket.get(0).asText(),
                        bucket.get(1).isNull() ? null : bucket.get(1).asText(),
                        bucket.get(2).asLong()});
            }
        } catch (java.io.IOException failure) {
            throw new IllegalStateException("Invalid warehouse page metadata", failure);
        }
        return from(rows);
    }
}
