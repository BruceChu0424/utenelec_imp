package com.uten.imp.features.warehouse.taskcenter;

import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Physical workflow facts only. Original commands retain their own authorization and locking. */
public final class WarehouseTaskCenterContracts {
    private WarehouseTaskCenterContracts() {}

    public record Row(
            String rowKey, UUID id, String sourceType, String recordType,
            String billNo, String sourceDocNo, LocalDate businessDate,
            String partyName, String warehouseName, String responsibleName, Integer lineCount,
            String status, String statusLabel, String tone,
            String action, UUID targetId, boolean canHandle, Map<String, Object> actionData) {
        public Row {
            actionData = actionData == null ? Map.of() : Map.copyOf(actionData);
        }
    }

    public record StatusFacet(String value, String label, long count) {}

    public record Page(List<Row> items, int page, int size, long total, int totalPages,
                       Map<String, List<StatusFacet>> facets) {
        public Page {
            items = List.copyOf(items);
            facets = Map.copyOf(facets);
        }
    }

    public record Filter(String source, String status, String keyword, String billNo,
                         LocalDate dateFrom, LocalDate dateTo, UUID scopeWarehouseId,
                         int page, int size, String sort, String order) {
        public Filter(String source, String status, String keyword, String billNo,
                      LocalDate dateFrom, LocalDate dateTo, UUID scopeWarehouseId,
                      int page, int size) {
            this(source, status, keyword, billNo, dateFrom, dateTo, scopeWarehouseId,
                    page, size, null, null);
        }
    }
}
