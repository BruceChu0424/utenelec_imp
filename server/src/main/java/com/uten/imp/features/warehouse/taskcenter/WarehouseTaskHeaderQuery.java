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
                "warehouseName", "warehouse_name", "responsibleName", "responsible_name",
                "makerName", "maker_name").forEach((key, expression) ->
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
        // 生产工单不进列搜索白名单：该值由外层 LATERAL 计算（不在 source_rows CTE 里），
        // 列搜索谓词在 CTE 内求值会引用不存在的列。排序单独放行（见 sortable）。
        return Map.copyOf(fields);
    }

    static SqlColumnSearch.Criteria criteria(Map<String, String> searches, boolean inbound) {
        return SqlColumnSearch.criteria(searches, fields(inbound), "warehouse_header_");
    }

    static boolean sortable(String column) { return sortable(column, false); }

    /** 生产工单仅出库方向可排序（表达式在外层行查询，指向 LATERAL 投影列）。 */
    static boolean sortable(String column, boolean inbound) {
        return fields(inbound).containsKey(column) || (!inbound && "productionOrderNo".equals(column));
    }

    static String orderExpression(String column, boolean inbound) {
        if (column == null || column.isBlank()) return "business_date";
        if (!sortable(column, inbound)) throw new com.uten.imp.common.web.ApiException(
                com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED, "仓库任务排序字段不正确");
        return switch (column) {
            case "goodsName" -> inbound ? "line_data->>'goodsName'" : "goods_name";
            case "goodsCode" -> inbound ? "line_data->>'goodsCode'" : "goods_code";
            case "colorName" -> inbound ? "line_data->>'colorName'" : "color_name";
            case "specification" -> inbound ? "line_data->>'specification'" : "specification";
            case "quantity" -> inbound ? "CAST(line_data->>'quantity' AS numeric)" : "quantity";
            case "billNo" -> "bill_no"; case "sourceDocNo" -> "source_doc_no";
            case "partyName" -> "party_name"; case "warehouseName" -> "warehouse_name";
            case "responsibleName" -> "responsible_name"; case "makerName" -> "maker_name";
            case "productionOrderNo" -> inbound ? "business_date" : "production_orders.production_order_no";
            default -> "business_date";
        };
    }
}
