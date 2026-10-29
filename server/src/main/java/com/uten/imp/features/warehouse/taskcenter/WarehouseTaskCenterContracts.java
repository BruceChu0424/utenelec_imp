package com.uten.imp.features.warehouse.taskcenter;

import java.time.LocalDate;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Physical workflow facts only. Original commands retain their own authorization and locking. */
public final class WarehouseTaskCenterContracts {
    private WarehouseTaskCenterContracts() {}

    /** ALL is reserved for a scope-authorized physical detail lookup. */
    public enum TaskView {
        ACTIVE, HISTORY, ALL;

        public static TaskView requested(String value) {
            String normalized = value == null || value.isBlank() ? "ACTIVE"
                    : value.strip().toUpperCase(java.util.Locale.ROOT);
            if (!normalized.equals("ACTIVE") && !normalized.equals("HISTORY")) {
                throw new com.uten.imp.common.web.ApiException(
                        com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED, "单据视图不正确");
            }
            return valueOf(normalized);
        }
    }

    public record Row(
            String rowKey, UUID id, String sourceType, String recordType,
            String billNo, String sourceDocNo, LocalDate businessDate,
            String partyName, String warehouseName, String responsibleName, String makerName, Integer lineCount,
            String status, String statusLabel, String tone,
            String action, UUID targetId, boolean canHandle, Map<String, Object> actionData, Line line,
            String productionOrderNo) {
        public Row {
            actionData = actionData == null ? Map.of() : Map.copyOf(actionData);
        }

        public Row(String rowKey, UUID id, String sourceType, String recordType,
                   String billNo, String sourceDocNo, LocalDate businessDate,
                   String partyName, String warehouseName, String responsibleName, Integer lineCount,
                   String status, String statusLabel, String tone,
                   String action, UUID targetId, boolean canHandle, Map<String, Object> actionData) {
            this(rowKey, id, sourceType, recordType, billNo, sourceDocNo, businessDate,
                    partyName, warehouseName, responsibleName, null, lineCount, status, statusLabel, tone,
                    action, targetId, canHandle, actionData, null, null);
        }

        public Row withLine(Line item) {
            return new Row(sourceType + ":" + recordType + ":" + id + ":" + item.key(), id,
                    sourceType, recordType, billNo, sourceDocNo, businessDate, partyName, warehouseName,
                    responsibleName, makerName, lineCount, status, statusLabel, tone, action, targetId, canHandle,
                    actionData, item, productionOrderNo);
        }

        public Row withProductionOrderNo(String orderNo) {
            return new Row(rowKey,id,sourceType,recordType,billNo,sourceDocNo,businessDate,partyName,warehouseName,
                    responsibleName,makerName,lineCount,status,statusLabel,tone,action,targetId,canHandle,actionData,line,orderNo);
        }

        public Row withWarehouseName(String name) {
            return new Row(rowKey,id,sourceType,recordType,billNo,sourceDocNo,businessDate,partyName,name,
                    responsibleName,makerName,lineCount,status,statusLabel,tone,action,targetId,canHandle,actionData,line,
                    productionOrderNo);
        }
    }

    /** Stable physical item identity; repeated goods on one document remain separate lines. */
    public record Line(String key, UUID itemId, Integer lineNo, String goodsCode, String goodsName,
                       String specification, String colorName, String unitName,
                       BigDecimal quantity, BigDecimal weight) {
        public String getQuantityText() { return quantity == null ? null : quantity.toPlainString(); }
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
                         int page, int size, String sort, String order, TaskView view, Map<String, String> columnSearch) {
        public Filter {
            view = view == null ? TaskView.ACTIVE : view;
            columnSearch = columnSearch == null ? Map.of() : Map.copyOf(columnSearch);
        }
        public Filter(String source, String status, String keyword, String billNo,
                      LocalDate dateFrom, LocalDate dateTo, UUID scopeWarehouseId,
                      int page, int size, String sort, String order, TaskView view) {
            this(source,status,keyword,billNo,dateFrom,dateTo,scopeWarehouseId,page,size,sort,order,view,Map.of());
        }
        public Filter withColumnSearch(Map<String, String> columns) {
            return new Filter(source,status,keyword,billNo,dateFrom,dateTo,scopeWarehouseId,page,size,sort,order,view,columns);
        }

        public Filter(String source, String status, String keyword, String billNo,
                      LocalDate dateFrom, LocalDate dateTo, UUID scopeWarehouseId,
                      int page, int size, String sort, String order) {
            this(source, status, keyword, billNo, dateFrom, dateTo, scopeWarehouseId,
                    page, size, sort, order, TaskView.ACTIVE);
        }
        public Filter(String source, String status, String keyword, String billNo,
                      LocalDate dateFrom, LocalDate dateTo, UUID scopeWarehouseId,
                      int page, int size) {
            this(source, status, keyword, billNo, dateFrom, dateTo, scopeWarehouseId,
                    page, size, null, null);
        }
    }
}
