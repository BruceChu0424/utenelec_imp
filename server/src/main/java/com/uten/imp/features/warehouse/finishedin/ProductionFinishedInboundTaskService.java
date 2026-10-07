package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.NativeFacets;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;

/** Authoritative two-stage warehouse queue: pre-FQC registration and final count. */
@Service
@RequiredArgsConstructor
public class ProductionFinishedInboundTaskService {

    /** 表头筛选白名单（2026-09-16）：任务步骤与 task_documents.task_stage 同源。 */
    private static final java.util.Set<String> TASK_STAGES = java.util.Set.of(
            "ARRIVAL_REGISTRATION", "FINAL_COUNT");

    private static final String BASE_SQL = """
            WITH arrival_tasks AS (
                SELECT 'ARRIVAL_REGISTRATION'::text AS task_stage,
                       report.id AS task_id,
                       report.id AS report_id,
                       NULL::uuid AS document_id,
                       NULL::text AS document_no,
                       report.bill_date AS document_date,
                       NULL::uuid AS warehouse_id,
                       NULL::text AS warehouse_name,
                       plan.plan_id,
                       plan.plan_no,
                       report.bill_no AS report_nos,
                       string_agg(
                           DISTINCT COALESCE(
                               NULLIF(goods.name, ''),
                               NULLIF(goods.code, ''),
                               '未命名货品')
                               || COALESCE(' (' || NULLIF(concat_ws(' · ',
                                   CASE WHEN NULLIF(goods.name, '') IS NULL
                                        THEN NULL ELSE NULLIF(goods.code, '') END,
                                   NULLIF(line_color.name, '')), '') || ')', ''),
                           '、') AS goods_summary,
                       -- ADR-148：一批实物(同一产出批次、送入仓库的各份)在登记页是一行。
                       COUNT(DISTINCT report_item.output_lot_id)::integer AS line_count,
                       COALESCE(SUM(report_item.qty), 0) AS pending_qty,
                       report.created_at,
                       FALSE AS residual_task,
                       -- 仓库数据范围(ADR-149)的「所在仓」：待登记还没选仓，按成品主档「所属仓库」归属
                       -- (一单多个所属仓时任一仓的负责人都看得到；都没有所属仓 = 未定仓)。
                       COALESCE(array_agg(DISTINCT goods.owning_warehouse_id)
                                    FILTER (WHERE goods.owning_warehouse_id IS NOT NULL),
                                ARRAY[]::uuid[]) AS scope_warehouse_ids,
                       COALESCE(SUM(report_item.qty) FILTER (
                           WHERE report_item.is_public_output AND NOT report_item.is_actual_surplus), 0)
                           AS public_qty,
                       COALESCE(SUM(report_item.qty) FILTER (WHERE report_item.is_actual_surplus), 0)
                           AS actual_surplus_qty
                FROM production_daily_reports report
                JOIN production_daily_report_items report_item
                  ON report_item.report_id = report.id
                -- V548：待登记口径统一走视图（含撤回后重新可登记的行）。
                JOIN v_production_report_items_pending_registration pending
                  ON pending.report_item_id = report_item.id
                JOIN goods goods ON goods.id = report_item.goods_id
                -- 行色优先、主档色兜底（仓库里既有写法）：一单多货品时摘要按
                -- 「名称 (编号 · 颜色)」拼，否则同名不同色的两行会被 DISTINCT 合成一条。
                LEFT JOIN colors line_color
                  ON line_color.id = COALESCE(report_item.color_id, goods.color_id)
                 AND line_color.is_deleted = FALSE
                LEFT JOIN LATERAL (
                    SELECT production_plan.id AS plan_id,
                           production_plan.bill_no AS plan_no
                    FROM production_daily_report_items source_item
                    JOIN production_plan_items plan_item
                      ON plan_item.id = source_item.plan_item_id
                     AND plan_item.is_deleted = FALSE
                    JOIN production_plans production_plan
                      ON production_plan.id = plan_item.plan_id
                     AND production_plan.is_deleted = FALSE
                    WHERE source_item.report_id = report.id
                      AND source_item.is_deleted = FALSE
                    ORDER BY production_plan.bill_no, production_plan.id
                    LIMIT 1
                ) plan ON TRUE
                WHERE report.status = 1
                  AND report.is_deleted = FALSE
                  AND report_item.destination = 'WAREHOUSE'
                GROUP BY report.id, report.bill_no, report.bill_date,
                         plan.plan_id, plan.plan_no, report.created_at
            ), final_count_tasks AS (
                SELECT 'FINAL_COUNT'::text AS task_stage,
                       document.id AS task_id,
                       document.source_daily_report_id AS report_id,
                       document.id AS document_id,
                       document.bill_no AS document_no,
                       document.bill_date AS document_date,
                       document.warehouse_id,
                       warehouse.name AS warehouse_name,
                       plan.plan_id,
                       plan.plan_no,
                       reports.report_nos,
                       string_agg(
                           DISTINCT COALESCE(
                               NULLIF(item.goods_name_snapshot, ''),
                               NULLIF(item.goods_code_snapshot, ''),
                               '未命名货品')
                               || COALESCE(' (' || NULLIF(concat_ws(' · ',
                                   CASE WHEN NULLIF(item.goods_name_snapshot, '') IS NULL
                                        THEN NULL
                                        ELSE NULLIF(item.goods_code_snapshot, '') END,
                                   NULLIF(line_color.name, '')), '') || ')', ''),
                           '、') AS goods_summary,
                       COUNT(DISTINCT COALESCE(lot_source.output_lot_id, item.id))::integer AS line_count,
                       COALESCE(SUM(item.qty), 0) AS pending_qty,
                       document.created_at,
                       EXISTS (
                           SELECT 1
                           FROM production_finished_in_confirmations confirmation
                           WHERE confirmation.residual_stock_document_id =
                                 document.id
                       ) AS residual_task,
                       ARRAY[document.warehouse_id] AS scope_warehouse_ids,
                       COALESCE(SUM(item.qty) FILTER (
                           WHERE lot_source.is_public_output AND NOT lot_source.is_actual_surplus), 0)
                           AS public_qty,
                       COALESCE(SUM(item.qty) FILTER (WHERE lot_source.is_actual_surplus), 0)
                           AS actual_surplus_qty
                FROM stock_documents document
                JOIN stock_document_items item
                  ON item.doc_id = document.id
                 AND item.is_deleted = FALSE
                 AND (
                     item.source_daily_report_item_id IS NOT NULL
                     OR item.execution_segment_id IS NOT NULL
                 )
                LEFT JOIN production_daily_report_items lot_source
                  ON lot_source.id = item.source_daily_report_item_id
                -- 单据行自带颜色（快照口径，不回看主档）：摘要同样按
                -- 「名称 (编号 · 颜色)」拼，同名不同色不再被 DISTINCT 并成一条。
                LEFT JOIN colors line_color
                  ON line_color.id = item.color_id
                 AND line_color.is_deleted = FALSE
                LEFT JOIN warehouses warehouse
                  ON warehouse.id = document.warehouse_id
                 AND warehouse.is_deleted = FALSE
                LEFT JOIN LATERAL (
                    SELECT production_plan.id AS plan_id,
                           production_plan.bill_no AS plan_no
                    FROM stock_document_items source_item
                    JOIN production_plan_items plan_item
                      ON plan_item.id = source_item.upstream_item_id
                     AND plan_item.is_deleted = FALSE
                    JOIN production_plans production_plan
                      ON production_plan.id = plan_item.plan_id
                     AND production_plan.is_deleted = FALSE
                    WHERE source_item.doc_id = document.id
                      AND source_item.is_deleted = FALSE
                    ORDER BY production_plan.bill_no, production_plan.id
                    LIMIT 1
                ) plan ON TRUE
                LEFT JOIN LATERAL (
                    SELECT string_agg(
                               DISTINCT report.bill_no, '、') AS report_nos
                    FROM stock_document_items source_item
                    JOIN production_daily_report_items report_item
                      ON report_item.id =
                         source_item.source_daily_report_item_id
                     AND report_item.is_deleted = FALSE
                    JOIN production_daily_reports report
                      ON report.id = report_item.report_id
                     AND report.is_deleted = FALSE
                    WHERE source_item.doc_id = document.id
                      AND source_item.is_deleted = FALSE
                ) reports ON TRUE
                WHERE document.doc_type = 'FINISHED_IN'
                  AND document.status = 0
                  AND document.is_deleted = FALSE
                GROUP BY document.id, document.source_daily_report_id,
                         document.bill_no,
                         document.bill_date, document.warehouse_id,
                         warehouse.name, plan.plan_id, plan.plan_no,
                         reports.report_nos, document.created_at
            ), task_documents AS (
                SELECT * FROM arrival_tasks
                UNION ALL
                SELECT * FROM final_count_tasks
            )
            """;

    private final EntityManager em;
    private final ProductionStockTaskAccessPolicy access;

    @Transactional(readOnly = true)
    public PageResponse<ProductionFinishedInboundTask> list(
            String keyword, int requestedPage, int requestedSize) {
        return list(keyword, null, null, requestedPage, requestedSize);
    }

    /**
     * 表头筛选版列表（2026-09-16）：taskStage=任务步骤（ARRIVAL_REGISTRATION 待登记 /
     * FINAL_COUNT 待最终点收，白名单 fail-closed）；warehouseId=最终点收入库单的成品仓
     * （待登记任务尚无仓库，会被该筛选取自然排除）。全参数绑定。
     */
    @Transactional(readOnly = true)
    public PageResponse<ProductionFinishedInboundTask> list(
            String keyword, String taskStage, UUID warehouseId,
            int requestedPage, int requestedSize) {
        return list(keyword, taskStage, warehouseId, requestedPage, requestedSize, WarehouseTaskScope.ALL);
    }

    /** 同上, 另按仓库数据范围(ADR-149)过滤。 */
    @Transactional(readOnly = true)
    public PageResponse<ProductionFinishedInboundTask> list(
            String keyword, String taskStage, UUID warehouseId,
            int requestedPage, int requestedSize, WarehouseTaskScope warehouseScope) {
        return list(keyword, taskStage, warehouseId, requestedPage, requestedSize,
                warehouseScope, null, null, null, null);
    }

    /** 同上；2026-09-25 单号列统一：sort/order 表头排序（白名单，未知回落默认
     *  进队时间序）、taskNo/planNo 任务单号/生产计划号表头值筛选（等值精确匹配，
     *  仅条件出现才绑定命名参数）。 */
    @Transactional(readOnly = true)
    public PageResponse<ProductionFinishedInboundTask> list(
            String keyword, String taskStage, UUID warehouseId,
            int requestedPage, int requestedSize, WarehouseTaskScope warehouseScope,
            String sort, String order, String taskNo, String planNo) {
        boolean scoped = warehouseScope != null && warehouseScope.active();
        PageRequest pageable = Pageables.of(
                requestedPage, requestedSize);
        int page = pageable.getPageNumber() + 1;
        int size = pageable.getPageSize();
        if (!access.canAccessWarehouseTasks()) {
            return new PageResponse<>(
                    List.of(), page, size, 0, 0);
        }
        String normalized = keyword == null
                ? ""
                : keyword.strip().toLowerCase();
        String normalizedStage = taskStage == null
                ? ""
                : taskStage.strip().toUpperCase();
        if (!normalizedStage.isEmpty() && !TASK_STAGES.contains(normalizedStage)) {
            throw new com.uten.imp.common.web.ApiException(
                    com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,
                    "任务步骤仅支持 ARRIVAL_REGISTRATION 或 FINAL_COUNT");
        }
        String filter = taskFilter(normalized, normalizedStage, warehouseId,
                scoped ? warehouseScope : null, taskNo, planNo);

        Query countQuery = em.createNativeQuery(
                BASE_SQL + " SELECT COUNT(*) FROM task_documents " + filter);
        bindTaskFilters(countQuery, normalized, normalizedStage, warehouseId,
                scoped ? warehouseScope : null, taskNo, planNo);
        long total = ((Number) countQuery.getSingleResult()).longValue();

        Query rowsQuery = em.createNativeQuery(BASE_SQL + """
                SELECT task_stage, task_id, report_id,
                       document_id, document_no, document_date,
                       warehouse_id, warehouse_name, plan_id, plan_no,
                       report_nos, goods_summary, line_count,
                       pending_qty, created_at, residual_task,
                       public_qty, actual_surplus_qty
                FROM task_documents
                """ + filter + "\n" + taskOrderBy(sort, order) + """
                OFFSET :offset LIMIT :limit
                """);
        bindTaskFilters(rowsQuery, normalized, normalizedStage, warehouseId,
                scoped ? warehouseScope : null, taskNo, planNo);
        rowsQuery.setParameter("offset", pageable.getOffset());
        rowsQuery.setParameter("limit", size);
        List<ProductionFinishedInboundTask> items =
                NativeQueryResults.objectArrayRows(rowsQuery).stream()
                        .map(ProductionFinishedInboundTaskService::map)
                        .toList();
        int totalPages = total == 0
                ? 0
                : (int) ((total + size - 1) / size);
        return new PageResponse<>(
                items, page, size, total, totalPages);
    }

    /** 产成品入库任务 facets（2026-09-25 单号列统一）：{taskNo:[各任务单号],
     *  planNo:[各生产计划号]}——与列表/计数同一过滤基座（不含单号列自身值筛选），
     *  按单号分组计数、单号升序，上限 500 桶。 */
    @Transactional(readOnly = true)
    public java.util.Map<String, List<java.util.Map<String, Object>>> facets(
            String keyword, String taskStage, UUID warehouseId,
            WarehouseTaskScope warehouseScope) {
        if (!access.canAccessWarehouseTasks()) {
            return java.util.Map.of(
                    "taskNo", List.of(), "planNo", List.of());
        }
        String normalized = keyword == null ? "" : keyword.strip().toLowerCase();
        String normalizedStage = taskStage == null ? "" : taskStage.strip().toUpperCase();
        boolean scoped = warehouseScope != null && warehouseScope.active();
        String filter = taskFilter(normalized, normalizedStage, warehouseId,
                scoped ? warehouseScope : null, null, null);
        List<java.util.Map<String, Object>> taskNoBuckets = billBuckets(
                "SELECT " + TASK_NO_EXPR + ", COUNT(*) FROM task_documents " + filter
                        + " GROUP BY 1 ORDER BY 1",
                normalized, normalizedStage, warehouseId, scoped ? warehouseScope : null);
        List<java.util.Map<String, Object>> planNoBuckets = billBuckets(
                "SELECT COALESCE(plan_no, ''), COUNT(*) FROM task_documents " + filter
                        + " GROUP BY 1 ORDER BY 1",
                normalized, normalizedStage, warehouseId, scoped ? warehouseScope : null);
        return java.util.Map.of("taskNo", taskNoBuckets, "planNo", planNoBuckets);
    }

    /** 单号桶查询 + 行映射（value/count/label，label=value；上限 500 桶）。
     *  task_documents 是 BASE_SQL 里的 CTE，桶查询必须同样带上 CTE 前缀。 */
    private List<java.util.Map<String, Object>> billBuckets(
            String sql, String normalized, String normalizedStage, UUID warehouseId,
            WarehouseTaskScope warehouseScope) {
        Query query = em.createNativeQuery(BASE_SQL + sql).setMaxResults(500);
        bindTaskFilters(query, normalized, normalizedStage, warehouseId, warehouseScope, null, null);
        return NativeFacets.rowsOf(query);
    }

    /** 任务单号列展示口径（待登记=报工单号、待点收=入库单号，兜底任务 id）。 */
    private static final String TASK_NO_EXPR =
            "COALESCE(NULLIF(document_no, ''), NULLIF(report_nos, ''), task_id::text)";

    /** 列表 / 计数 / facets 共用 WHERE 片段（同一过滤基座，2026-09-25 单号列统一）；
     *  命名参数按条件出现，未出现的条件不绑定（Hibernate 6 校验未知命名参数）。 */
    private static String taskFilter(String keyword, String taskStage, UUID warehouseId,
            WarehouseTaskScope activeScope, String taskNo, String planNo) {
        return """
                 WHERE (
                     :keyword = ''
                     OR LOWER(
                         COALESCE(document_no, '') || ' ' ||
                         COALESCE(plan_no, '') || ' ' ||
                         COALESCE(report_nos, '') || ' ' ||
                         COALESCE(goods_summary, '')
                     ) LIKE :keyword_like
                 )
                """ + (taskStage.isEmpty()
                        ? ""
                        : " AND task_stage = :task_stage\n")
                + (warehouseId == null
                        ? ""
                        : " AND warehouse_id = :warehouse_id\n")
                + (activeScope == null
                        ? ""
                        : " AND " + activeScope.predicateAny("scope_warehouse_ids", ":warehouse_scope") + "\n")
                + (isBlank(taskNo)
                        ? ""
                        : " AND " + TASK_NO_EXPR + " = :task_no\n")
                + (isBlank(planNo)
                        ? ""
                        : " AND COALESCE(plan_no, '') = :plan_no\n");
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    /** 绑定共用过滤参数（与 [taskFilter] 的条件一一对应）。 */
    private static void bindTaskFilters(Query query, String keyword, String taskStage,
            UUID warehouseId, WarehouseTaskScope activeScope, String taskNo, String planNo) {
        query.setParameter("keyword", keyword);
        query.setParameter("keyword_like", "%" + keyword + "%");
        if (!taskStage.isEmpty()) query.setParameter("task_stage", taskStage);
        if (warehouseId != null) query.setParameter("warehouse_id", warehouseId);
        if (activeScope != null) query.setParameter("warehouse_scope", activeScope.idsCsv());
        if (!isBlank(taskNo)) query.setParameter("task_no", taskNo.strip());
        if (!isBlank(planNo)) query.setParameter("plan_no", planNo.strip());
    }

    /** 排序 ORDER BY（2026-09-25 单号列统一）：白名单映射前端列 key→SQL 表达式；
     *  未知/空→默认（进队时间升序, 任务 id 稳定序）。 */
    private static String taskOrderBy(String sort, String order) {
        String dir = "desc".equalsIgnoreCase(order) ? "DESC" : "ASC";
        return switch (sort == null ? "" : sort) {
            case "taskNo" -> "ORDER BY " + TASK_NO_EXPR + " " + dir
                    + " NULLS LAST, created_at ASC, task_id ASC\n";
            case "planNo" -> "ORDER BY plan_no " + dir
                    + " NULLS LAST, created_at ASC, task_id ASC\n";
            default -> "ORDER BY created_at ASC, task_id ASC\n";
        };
    }

    @Transactional(readOnly = true)
    public long countPending() {
        return countPending(WarehouseTaskScope.ALL);
    }

    /** 待办数(ADR-149): 与列表同一过滤基座与仓库范围(目标仓, 未登记按成品所属仓), 徽章 = 列表 total。 */
    @Transactional(readOnly = true)
    public long countPending(WarehouseTaskScope warehouseScope) {
        if (!access.canAccessWarehouseTasks()) return 0;
        WarehouseTaskScope activeScope = warehouseScope != null && warehouseScope.active() ? warehouseScope : null;
        Query query = em.createNativeQuery(BASE_SQL + " SELECT COUNT(*) FROM task_documents "
                + taskFilter("", "", null, activeScope, null, null));
        bindTaskFilters(query, "", "", null, activeScope, null, null);
        Number count = (Number) query.getSingleResult();
        return count == null ? 0 : count.longValue();
    }

    private static ProductionFinishedInboundTask map(Object[] row) {
        return new ProductionFinishedInboundTask(
                (String) row[0],
                (java.util.UUID) row[1],
                (java.util.UUID) row[2],
                (java.util.UUID) row[3],
                (String) row[4],
                NativeValueConverters.toLocalDate(row[5]),
                (java.util.UUID) row[6],
                (String) row[7],
                (java.util.UUID) row[8],
                (String) row[9],
                (String) row[10],
                (String) row[11],
                ((Number) row[12]).intValue(),
                NativeValueConverters.toBigDecimal(row[13]),
                offsetDateTime(row[14]),
                Boolean.TRUE.equals(row[15]),
                NativeValueConverters.toBigDecimal(row[16]),
                NativeValueConverters.toBigDecimal(row[17]),
                com.uten.imp.common.production.OutputLotText.actualSurplusNote(NativeValueConverters.toBigDecimal(row[17])));
    }

    private static OffsetDateTime offsetDateTime(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime valueWithOffset) {
            return valueWithOffset.withOffsetSameInstant(ZoneOffset.UTC);
        }
        if (value instanceof Instant instant) {
            return instant.atOffset(ZoneOffset.UTC);
        }
        if (value instanceof Timestamp timestamp) {
            return timestamp.toInstant().atOffset(ZoneOffset.UTC);
        }
        throw new IllegalStateException(
                "Unsupported task timestamp: " + value.getClass());
    }
}
