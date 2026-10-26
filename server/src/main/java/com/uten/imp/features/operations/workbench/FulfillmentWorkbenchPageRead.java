package com.uten.imp.features.operations.workbench;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** One request-local candidate projection shared by rows, counts and exclusive column facets. */
final class FulfillmentWorkbenchPageRead {
    private FulfillmentWorkbenchPageRead() { }

    static final String ROW_COLUMNS = """
            department, task_id, package_id, plan_id, plan_no,
            warehouse_id, warehouse_name, goods_id, goods_code,
            goods_name, spec, color_id, color_name, unit_id, unit_name,
            supply_route, required_qty, allocated_qty, fulfilled_qty,
            supply_pegged_qty, open_qty, task_status, need_date,
            expected_date, exception_code, updated_at,
            action_doc_type, action_doc_id, action_doc_no, action_item_id, action_doc_status,
            goods_count, open_line_count, action_item_ids, issued_at, can_create_order,
            display_stage, materials_defined, production_product_code, production_product_name,
            material_request_no, workshop_name, worker_name, draw_batch_no, lines,
            rd_task_no, bom_missing_item_ids, orderable_qty, supplier_name, difference_qty
            """;
    static final int METADATA_OFFSET = 50;
    private static final ObjectMapper JSON = new ObjectMapper();

    static String sql(String source, String baseFilter, String statusFilter,
                      String exceptionFilter, String dateFilter, String orderBy,
                      String department, FulfillmentWorkbenchTableQuery table) {
        String selected = statusFilter + " AND " + exceptionFilter + " AND " + dateFilter;
        String tableFilters = table == null ? "" : table.rangeSql() + table.filterSql(null);
        String statusKey = "SUBCONTRACT".equals(department)
                ? "CASE WHEN display_stage='BOM_MISSING' THEN 'BOM_MISSING' ELSE task_status END"
                : "task_status";
        String facetRows;
        if ("WAREHOUSE".equals(department)) {
            facetRows = """
                    SELECT 'docNo'::text AS key, visible_doc_no AS value,
                           visible_doc_no AS label, COUNT(*) AS task_count
                    FROM candidates WHERE %s%s GROUP BY visible_doc_no
                    """.formatted(selected, table == null ? "" : table.rangeSql() + table.filterSql("docNo"));
        } else if (table != null) {
            String values = FulfillmentWorkbenchTableQuery.FIELDS.entrySet().stream()
                    .sorted(Map.Entry.comparingByKey()).map(entry -> {
                        String label = "goods".equals(entry.getKey())
                                ? "NULLIF(concat_ws(' ',goods_code,goods_name),'')" : entry.getValue();
                        return "('" + entry.getKey() + "'," + entry.getValue() + "," + label
                                + ", (TRUE " + table.filterSql(entry.getKey()) + "))";
                    }).collect(java.util.stream.Collectors.joining(","));
            facetRows = """
                    SELECT facet.key, facet.value, MAX(facet.label) AS label, COUNT(*) AS task_count
                    FROM candidates CROSS JOIN LATERAL (VALUES %s) facet(key,value,label,included)
                    WHERE %s%s AND facet.included
                    GROUP BY facet.key, facet.value
                    """.formatted(values, selected, table.rangeSql());
        } else {
            facetRows = "SELECT NULL::text AS key, NULL::text AS value, NULL::text AS label, 0::bigint AS task_count WHERE FALSE";
        }
        String pageColumns = java.util.Arrays.stream(ROW_COLUMNS.split(","))
                .map(column -> "page_rows." + column.strip())
                .collect(java.util.stream.Collectors.joining(", "));
        return """
                WITH candidates AS MATERIALIZED (SELECT * FROM %s WHERE %s),
                selected_rows AS MATERIALIZED (SELECT * FROM candidates WHERE %s%s),
                page_rows AS (
                    SELECT %s, ROW_NUMBER() OVER (ORDER BY %s) AS page_position
                    FROM selected_rows ORDER BY %s LIMIT :limit OFFSET :offset
                ), page_summary AS (
                    SELECT COUNT(*) AS total,
                           COUNT(*) FILTER (WHERE exception_code LIKE 'OVERDUE%%') AS overdue,
                           COUNT(*) FILTER (WHERE open_line_count>0) AS open_tasks,
                           COALESCE(SUM(open_qty),0) AS open_qty
                    FROM selected_rows
                ), status_rows AS (
                    SELECT %s AS status_key, COUNT(*) AS task_count
                    FROM candidates WHERE %s GROUP BY 1
                ), status_counts AS (
                    SELECT COALESCE(json_object_agg(status_key,task_count ORDER BY status_key),'{}'::json)::text AS counts
                    FROM status_rows
                ), exception_rows AS (
                    SELECT exception_code, COUNT(*) AS task_count
                    FROM candidates WHERE %s AND exception_code IS NOT NULL GROUP BY exception_code
                ), exception_counts AS (
                    SELECT COALESCE(json_object_agg(exception_code,task_count ORDER BY exception_code),'{}'::json)::text AS counts
                    FROM exception_rows
                ), pending_count AS (
                    SELECT COUNT(*) FILTER (WHERE open_line_count>0) AS task_count
                    FROM candidates WHERE %s
                ), facet_rows AS (%s), facet_values AS (
                    SELECT COALESCE(jsonb_agg(jsonb_build_array(key,value,label,task_count)
                           ORDER BY key,value NULLS LAST),'[]'::jsonb)::text AS buckets FROM facet_rows
                )
                SELECT %s, page_summary.total AS page_total, page_summary.overdue AS page_overdue,
                       page_summary.open_tasks AS page_open_tasks, page_summary.open_qty AS page_open_qty,
                       CASE WHEN page_rows.page_position IS NULL OR page_rows.page_position=:offset+1
                            THEN status_counts.counts END AS page_status_counts,
                       CASE WHEN page_rows.page_position IS NULL OR page_rows.page_position=:offset+1
                            THEN exception_counts.counts END AS page_exception_counts,
                       pending_count.task_count AS page_pending_tasks,
                       CASE WHEN page_rows.page_position IS NULL OR page_rows.page_position=:offset+1
                            THEN facet_values.buckets END AS page_facets
                FROM page_summary CROSS JOIN status_counts CROSS JOIN exception_counts
                CROSS JOIN pending_count CROSS JOIN facet_values LEFT JOIN page_rows ON TRUE
                ORDER BY page_rows.page_position NULLS LAST
                """.formatted(source, baseFilter, selected, tableFilters, ROW_COLUMNS, orderBy, orderBy,
                    statusKey, exceptionFilter, statusFilter, exceptionFilter, facetRows, pageColumns);
    }

    static Map<String, Long> counts(Object value) {
        Map<String, Long> result = new LinkedHashMap<>();
        JsonNode node = json(value);
        node.properties().forEach(entry -> result.put(entry.getKey(), entry.getValue().longValue()));
        return result;
    }

    record Facets(Map<String, List<FulfillmentWorkbenchPage.Facet>> values, Map<String, Long> nullCounts) { }

    static Facets facets(Object value) {
        Map<String, List<FulfillmentWorkbenchPage.Facet>> values = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        for (JsonNode bucket : json(value)) {
            String key = bucket.get(0).textValue();
            long count = bucket.get(3).longValue();
            if (bucket.get(1).isNull()) nullCounts.put(key, count);
            else values.computeIfAbsent(key, ignored -> new ArrayList<>()).add(
                    new FulfillmentWorkbenchPage.Facet(bucket.get(1).textValue(),
                            bucket.get(2).isNull() ? null : bucket.get(2).textValue(), count));
        }
        return new Facets(values, nullCounts);
    }

    private static JsonNode json(Object value) {
        try {
            if (value == null) throw new IllegalArgumentException("Missing workbench metadata");
            return JSON.readTree(value.toString());
        } catch (java.io.IOException failure) {
            throw new IllegalStateException("Invalid workbench metadata", failure);
        }
    }
}
