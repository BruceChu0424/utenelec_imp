package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.common.util.SqlColumnSearch;
import java.util.LinkedHashMap;
import java.util.Map;

/** The same physical-line header contract for both authorized task-center relations. */
final class WarehouseTaskHeaderQuery {
    private WarehouseTaskHeaderQuery() { }

    static Map<String, SqlColumnSearch.Field> fields(boolean inbound) {
        Map<String, SqlColumnSearch.Field> fields = new LinkedHashMap<>();
        Map.of("billNo", "bill_no", "sourceDocNo", "source_doc_no", "partyName", "party_name",
                "warehouseName", "warehouse_name", "responsibleName", "responsible_name").forEach((key, expression) ->
                fields.put(key, SqlColumnSearch.Field.text("coalesce(" + expression + ",'"
                        + (key.equals("warehouseName") ? "未确定" : "—") + "')")));
        Map.of("goodsName", "goods_name", "goodsCode", "goods_code", "colorName", "color_name",
                "specification", "specification").forEach((key, expression) -> {
            String value = inbound ? "line_data->>'" + key + "'" : expression;
            fields.put(key, SqlColumnSearch.Field.text("coalesce(" + value + ",'—')"));
        });
        fields.put("quantity", SqlColumnSearch.Field.decimal(inbound
                ? "CAST(line_data->>'quantity' AS numeric)" : "quantity"));
        fields.put("businessDate", SqlColumnSearch.Field.calendarDate("business_date"));
        return Map.copyOf(fields);
    }

    static SqlColumnSearch.Criteria criteria(Map<String, String> searches, boolean inbound) {
        return SqlColumnSearch.criteria(searches, fields(inbound), "warehouse_header_");
    }

    static boolean sortable(String column) { return fields(false).containsKey(column); }

    static String orderExpression(String column, boolean inbound) {
        if (column == null || column.isBlank()) return "business_date";
        if (!sortable(column)) throw new com.uten.imp.common.web.ApiException(
                com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED, "仓库任务排序字段不正确");
        return switch (column) {
            case "goodsName", "goodsCode", "colorName", "specification" -> inbound
                    ? "line_data->>'" + column + "'" : switch (column) {
                        case "goodsName" -> "goods_name"; case "goodsCode" -> "goods_code";
                        case "colorName" -> "color_name"; default -> "specification";
                    };
            case "quantity" -> inbound ? "CAST(line_data->>'quantity' AS numeric)" : "quantity";
            case "billNo" -> "bill_no"; case "sourceDocNo" -> "source_doc_no";
            case "partyName" -> "party_name"; case "warehouseName" -> "warehouse_name";
            case "responsibleName" -> "responsible_name"; default -> "business_date";
        };
    }
}
