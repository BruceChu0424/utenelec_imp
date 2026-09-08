package com.uten.imp.features.operations.workbench;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 履约工作台只读查询：仓库走 {@code v_fulfillment_workbench_actions}，
 * 采购/委外走 {@code v_procurement_decomposition_tasks}；
 * 支持状态/关键字/异常筛选，汇总任务计数与状态/异常分布，
 * 并按 {@link FulfillmentWorkbenchAccessPolicy} 对无权限的 action 元数据脱敏。
 */
@Service
@RequiredArgsConstructor
public class FulfillmentWorkbenchQueryService {

    private static final Set<String> DEPARTMENTS =
            Set.of("WAREHOUSE", "PURCHASE", "SUBCONTRACT");
    private static final String PENDING_MAKE =
            "task.status = 'ACTIVE' AND task.notified_qty < task.required_qty";

    private final EntityManager em;
    private final FulfillmentWorkbenchAccessPolicy accessPolicy;

    /**
     * 履约工作台分页查询。状态/异常卡片始终按整个部门×关键字口径统计（不受当前页或
     * 单卡筛选影响），异常可选项按部门×状态×关键字全量枚举；action 单据元数据按
     * {@link FulfillmentWorkbenchAccessPolicy} 对无权限者脱敏（仅保留「有动作」事实）。
     */
    @Transactional(readOnly = true)
    public FulfillmentWorkbenchPage query(
            String department,
            String status,
            String keyword,
            String exception,
            LocalDate dateFrom,
            LocalDate dateTo,
            int page,
            int size) {
        if (!DEPARTMENTS.contains(department)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "工作台部门无效");
        }
        int safePage = Math.max(page, 1);
        int safeSize = Math.min(Math.max(size, 1), 100);
        if ("WAREHOUSE".equals(department)
                && !accessPolicy.canAccessWarehouseTasks()) {
            return emptyPage(safePage, safeSize);
        }
        String normalizedStatus = status == null ? "" : status.strip();
        String normalizedKeyword = keyword == null ? "" : keyword.strip().toLowerCase();
        String normalizedException = exception == null ? "" : exception.strip().toUpperCase();
        // ADR-065 修订（2026-09-03）：采购/委外任务行按「当前执行单据」归组——
        // 申请待分解阶段一行=一张采购/委外申请（多货品合并单只见一行，双击进
        // 详情看逐货品明细）；分解订货后一行=一张订货单（供应商已分好）。
        // 单货品单据保留货品身份与数量列；多货品单据数量列置空，改由
        // goods_count/open_line_count 表达规模。
        // 仓库任务同口径归组（2026-09-03 用户确认）：一行=一张 DRAW 领料单
        // （执行分段开工时已把整段物料合为一张单），状态按整单出库进度
        // （全部行未出库=READY_TO_PICK、出过一部分=PARTIAL、全部出完=DONE）。
        // 尚未挂接领料单的行（action_doc_id 为 NULL）退回行级，不并入同一组。
        String sourceView = "WAREHOUSE".equals(department)
                ? """
                  (SELECT v.department,
                          COALESCE(MIN(v.action_doc_id::text), MIN(v.task_id::text))::uuid
                              AS task_id,
                          MIN(v.package_id::text)::uuid AS package_id,
                          MIN(v.plan_id::text)::uuid AS plan_id,
                          MAX(v.plan_no) AS plan_no,
                          MIN(v.warehouse_id::text)::uuid AS warehouse_id,
                          MAX(v.warehouse_name) AS warehouse_name,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN MIN(v.goods_id::text)::uuid END AS goods_id,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN MAX(v.goods_code) END AS goods_code,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN MAX(v.goods_name) END AS goods_name,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN MAX(v.spec) END AS spec,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN MIN(v.color_id::text)::uuid END AS color_id,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN MAX(v.color_name) END AS color_name,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN MIN(v.unit_id::text)::uuid END AS unit_id,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN MAX(v.unit_name) END AS unit_name,
                          MAX(v.supply_route) AS supply_route,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN SUM(v.required_qty) END AS required_qty,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN SUM(v.allocated_qty) END AS allocated_qty,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN SUM(v.fulfilled_qty) END AS fulfilled_qty,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN SUM(v.supply_pegged_qty) END AS supply_pegged_qty,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN SUM(v.open_qty) END AS open_qty,
                          CASE WHEN COUNT(*) FILTER (WHERE v.open_qty > 0) = 0
                               THEN 'DONE'
                               WHEN COUNT(*) FILTER (
                                        WHERE v.task_status <> 'READY_TO_PICK') > 0
                               THEN 'PARTIAL'
                               ELSE 'READY_TO_PICK' END::text AS task_status,
                          MIN(v.need_date) AS need_date,
                          MIN(v.expected_date) AS expected_date,
                          MAX(v.exception_code) AS exception_code,
                          MAX(v.updated_at) AS updated_at,
                          MAX(v.action_doc_type) AS action_doc_type,
                          MIN(v.action_doc_id::text)::uuid AS action_doc_id,
                          MAX(v.action_doc_no) AS action_doc_no,
                          NULL::UUID AS action_item_id,
                          MAX(v.action_doc_status) AS action_doc_status,
                          COUNT(DISTINCT v.goods_id) AS goods_count,
                          COUNT(*) FILTER (WHERE v.open_qty > 0) AS open_line_count,
                          COALESCE(
                              ARRAY_AGG(v.action_item_id::TEXT ORDER BY v.action_item_id)
                                  FILTER (WHERE v.action_item_id IS NOT NULL),
                              ARRAY[]::TEXT[]
                          ) AS action_item_ids
                   FROM v_fulfillment_workbench_actions v
                   WHERE v.department = 'WAREHOUSE'
                   GROUP BY v.department, COALESCE(v.action_doc_id, v.task_id))
                  """
                : """
                  (SELECT v.department,
                          v.action_doc_id AS task_id,
                          NULL::UUID AS package_id,
                          NULL::UUID AS plan_id,
                          MAX(v.plan_no) AS plan_no,
                          -- PostgreSQL 无 max(uuid)/min(uuid) 聚合；UUID 列经
                          -- text 聚合后 cast 回，保持 mapRow 的 UUID 类型不变。
                          MIN(v.warehouse_id::text)::uuid AS warehouse_id,
                          MAX(v.warehouse_name) AS warehouse_name,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN MIN(v.goods_id::text)::uuid END AS goods_id,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN MAX(v.goods_code) END AS goods_code,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN MAX(v.goods_name) END AS goods_name,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN MAX(v.spec) END AS spec,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN MIN(v.color_id::text)::uuid END AS color_id,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN MAX(v.color_name) END AS color_name,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN MIN(v.unit_id::text)::uuid END AS unit_id,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN MAX(v.unit_name) END AS unit_name,
                          MAX(v.supply_route) AS supply_route,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN SUM(v.required_qty) END AS required_qty,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN SUM(v.allocated_qty) END AS allocated_qty,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN SUM(v.fulfilled_qty) END AS fulfilled_qty,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN SUM(v.supply_pegged_qty) END AS supply_pegged_qty,
                          CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                               THEN SUM(v.open_qty) END AS open_qty,
                          v.task_status,
                          MIN(v.need_date) AS need_date,
                          MIN(v.expected_date) AS expected_date,
                          MAX(v.exception_code) AS exception_code,
                          MAX(v.updated_at) AS updated_at,
                          v.action_doc_type,
                          v.action_doc_id,
                          MAX(v.action_doc_no) AS action_doc_no,
                          NULL::UUID AS action_item_id,
                          MAX(v.action_doc_status) AS action_doc_status,
                          COUNT(DISTINCT v.goods_id) AS goods_count,
                          COUNT(*) FILTER (WHERE v.open_qty > 0) AS open_line_count,
                          COALESCE(
                              ARRAY_AGG(v.action_item_id::TEXT ORDER BY v.action_item_id)
                                  FILTER (WHERE v.action_item_id IS NOT NULL),
                              ARRAY[]::TEXT[]
                          ) AS action_item_ids
                   FROM v_procurement_decomposition_tasks v
                   GROUP BY v.department, v.action_doc_type, v.action_doc_id, v.task_status)
                  """;
        if ("SUBCONTRACT".equals(department) && accessPolicy.canViewSubcontractPreparationTasks()) {
            sourceView = "(" + sourceView + " UNION ALL " + subcontractPreparationRows() + ")";
        }
        String filters = """
                department = :department
                  AND (:status = ''
                       OR (:status = 'OPEN_ANY' AND open_line_count > 0)
                       OR (:status <> 'OPEN_ANY' AND task_status = :status))
                  AND (:exception = ''
                       OR (:exception = 'OVERDUE_ANY' AND exception_code LIKE 'OVERDUE%%')
                       OR (:exception <> 'OVERDUE_ANY' AND exception_code = :exception))
                  AND (:keyword = '' OR LOWER(
                      COALESCE(plan_no,'') || ' ' ||
                      COALESCE(action_doc_no,'') || ' ' ||
                      COALESCE(goods_code,'') || ' ' ||
                      COALESCE(goods_name,'')
                  ) LIKE :keywordLike)
                  -- 历史记录时间门控：仅行/汇总查询传入日期；null = 不过滤
                  -- （状态/异常/待完成计数始终传 null，保持角标全量口径）。
                  -- updated_at 对已完成任务近似完结时间。
                  AND (CAST(:date_from AS date) IS NULL
                       OR updated_at >= CAST(:date_from AS date))
                  AND (CAST(:date_to AS date) IS NULL
                       OR updated_at < CAST(:date_to AS date) + INTERVAL '1 day')
                """;

        Query rowsQuery = em.createNativeQuery("""
                SELECT department, task_id, package_id, plan_id, plan_no,
                       warehouse_id, warehouse_name, goods_id, goods_code,
                       goods_name, spec, color_id, color_name, unit_id, unit_name,
                       supply_route, required_qty, allocated_qty, fulfilled_qty,
                       supply_pegged_qty, open_qty, task_status, need_date,
                       expected_date, exception_code, updated_at,
                       action_doc_type, action_doc_id, action_doc_no, action_item_id, action_doc_status,
                       goods_count, open_line_count, action_item_ids
                FROM %s
                WHERE %s
                ORDER BY need_date NULLS LAST, task_id
                OFFSET :offset LIMIT :limit
                """.formatted(sourceView, filters));
        bind(rowsQuery, department, normalizedStatus, normalizedKeyword,
                normalizedException, dateFrom, dateTo);
        rowsQuery.setParameter("offset", (long) (safePage - 1) * safeSize);
        rowsQuery.setParameter("limit", safeSize);
        List<FulfillmentTaskRow> items =
                NativeQueryResults.objectArrayRows(rowsQuery).stream()
                        .map(FulfillmentWorkbenchQueryService::mapRow)
                        .map(this::applyActionAccess)
                        .toList();

        Query summaryQuery = em.createNativeQuery("""
                SELECT COUNT(*),
                       COUNT(*) FILTER (WHERE exception_code LIKE 'OVERDUE%%'),
                       COUNT(*) FILTER (WHERE open_line_count > 0),
                       COALESCE(SUM(open_qty), 0)
                FROM %s
                WHERE %s
                """.formatted(sourceView, filters));
        bind(summaryQuery, department, normalizedStatus, normalizedKeyword,
                normalizedException, dateFrom, dateTo);
        Object[] summary = (Object[]) summaryQuery.getSingleResult();
        long total = ((Number) summary[0]).longValue();

        Query statusQuery = em.createNativeQuery("""
                SELECT task_status, COUNT(*)
                FROM %s
                WHERE %s
                GROUP BY task_status
                ORDER BY task_status
                """.formatted(sourceView, filters));
        // Status cards always describe the whole department/keyword result so
        // selecting one card never makes the other card counts disappear.
        bind(statusQuery, department, "", normalizedKeyword, normalizedException, null, null);
        Map<String, Long> statusCounts = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(statusQuery)) {
            statusCounts.put((String) row[0], ((Number) row[1]).longValue());
        }

        Query exceptionQuery = em.createNativeQuery("""
                SELECT exception_code, COUNT(*)
                FROM %s
                WHERE %s
                  AND exception_code IS NOT NULL
                GROUP BY exception_code
                ORDER BY exception_code
                """.formatted(sourceView, filters));
        // Exception options are server-wide for the active department/status/keyword,
        // never inferred from the current page.
        bind(exceptionQuery, department, normalizedStatus, normalizedKeyword, "", null, null);
        Map<String, Long> exceptionCounts = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(exceptionQuery)) {
            exceptionCounts.put((String) row[0], ((Number) row[1]).longValue());
        }

        // 「待完成」卡计数：open_line_count > 0，部门×关键字全量口径（与状态卡一致，
        // 不受当前状态卡筛选影响——否则选中「已完成」时待完成卡会被错误清零）。
        // 采购/委外按单据归组后即「仍有未完成明细的单据数」。
        Query pendingQuery = em.createNativeQuery("""
                SELECT COUNT(*) FILTER (WHERE open_line_count > 0)
                FROM %s
                WHERE %s
                """.formatted(sourceView, filters));
        bind(pendingQuery, department, "", normalizedKeyword, normalizedException, null, null);
        long pendingTasks = ((Number) pendingQuery.getSingleResult()).longValue();

        return new FulfillmentWorkbenchPage(
                items,
                safePage,
                safeSize,
                total,
                (int) Math.ceil(total / (double) safeSize),
                new FulfillmentWorkbenchPage.Summary(
                        total,
                        ((Number) summary[1]).longValue(),
                        ((Number) summary[2]).longValue(),
                        decimal(summary[3]),
                        statusCounts,
                        exceptionCounts,
                        pendingTasks),
                new FulfillmentWorkbenchPage.Capabilities(
                        "PURCHASE".equals(department)
                                && accessPolicy.canCreatePurchaseOrder(),
                        "SUBCONTRACT".equals(department)
                                && accessPolicy.canCreateSubcontractOrder()));
    }

    @Transactional(readOnly = true)
    public long countPending(String department) {
        if (!DEPARTMENTS.contains(department)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "工作台部门无效");
        }
        if ("WAREHOUSE".equals(department)
                && !accessPolicy.canAccessWarehouseTasks()) {
            return 0;
        }
        boolean decomposition = "PURCHASE".equals(department)
                || "SUBCONTRACT".equals(department);
        // 与列表同口径：采购/委外按单据归组计数（一张申请/订货单=一个待办）；
        // 仓库按领料单张数计数（一张 DRAW=一个待办，未挂单的行退回行级）。
        boolean includePreparation = "SUBCONTRACT".equals(department)
                && accessPolicy.canViewSubcontractPreparationTasks();
        String preparation = includePreparation
                ? " UNION ALL SELECT task.id FROM preplan_subcontract_make_tasks task WHERE " + PENDING_MAKE
                : "";
        Query query = em.createNativeQuery(decomposition
                ? """
                    SELECT COUNT(*) FROM (
                        SELECT DISTINCT action_doc_id
                        FROM v_procurement_decomposition_tasks
                        WHERE department = :department AND open_qty > 0
                        %s
                    ) documents
                    """.formatted(preparation)
                : """
                    SELECT COUNT(*) FROM (
                        SELECT DISTINCT COALESCE(action_doc_id, task_id)
                        FROM v_fulfillment_workbench_actions
                        WHERE department = :department AND open_qty > 0
                    ) documents
                    """);
        query.setParameter("department", department);
        return ((Number) query.getSingleResult()).longValue();
    }

    /** Pending preparation is a server-paged read-only task, never a client-side extra row. */
    private static String subcontractPreparationRows() {
        return """
                SELECT 'SUBCONTRACT'::text AS department, task.id AS task_id,
                       NULL::uuid AS package_id, NULL::uuid AS plan_id,
                       COALESCE(item.source_ref, '') AS plan_no,
                       task.warehouse_id, warehouse.name AS warehouse_name,
                       task.goods_id, goods.code AS goods_code, goods.name AS goods_name,
                       ''::text AS spec, task.color_id, color.name AS color_name,
                       task.unit_id, unit.name AS unit_name, 'SUBCONTRACT'::text AS supply_route,
                       task.required_qty, 0::numeric AS allocated_qty,
                       task.produced_qty AS fulfilled_qty, task.notified_qty AS supply_pegged_qty,
                       task.required_qty - task.notified_qty AS open_qty,
                       'WAITING_ORDER'::text AS task_status, item.delivery_date AS need_date,
                       NULL::date AS expected_date, NULL::text AS exception_code, task.updated_at,
                       'SUBCONTRACT_MAKE_TASK'::text AS action_doc_type,
                       task.id AS action_doc_id, COALESCE(item.source_ref, '') AS action_doc_no,
                       NULL::uuid AS action_item_id,
                       CASE WHEN task.produced_qty > 0 THEN 'PRODUCED'
                            WHEN EXISTS (
                                SELECT 1 FROM production_plans plan
                                JOIN production_execution_segments segment ON segment.plan_id = plan.id
                                WHERE plan.material_analysis_item_id = task.preparation_item_id
                                  AND NOT plan.is_deleted AND NOT plan.is_canceled
                                  AND NOT segment.is_deleted AND segment.status NOT IN ('CANCELLED','REVERSED')
                            ) THEN 'IN_PRODUCTION' ELSE 'NOTIFYING_WORKSHOP' END AS action_doc_status,
                       1::bigint AS goods_count, 1::bigint AS open_line_count,
                       ARRAY[]::text[] AS action_item_ids
                FROM preplan_subcontract_make_tasks task
                JOIN goods ON goods.id = task.goods_id
                LEFT JOIN colors color ON color.id = task.color_id
                LEFT JOIN units unit ON unit.id = task.unit_id
                LEFT JOIN warehouses warehouse ON warehouse.id = task.warehouse_id
                LEFT JOIN production_material_analysis_items item ON item.id = task.preparation_item_id
                WHERE %s
                """.formatted(PENDING_MAKE);
    }

    private static FulfillmentWorkbenchPage emptyPage(int page, int size) {
        return new FulfillmentWorkbenchPage(
                List.of(), page, size, 0, 0,
                new FulfillmentWorkbenchPage.Summary(
                        0, 0, 0, BigDecimal.ZERO,
                        Map.of(), Map.of(), 0),
                new FulfillmentWorkbenchPage.Capabilities(false, false));
    }

    private static void bind(
            Query query,
            String department,
            String status,
            String keyword,
            String exception,
            LocalDate dateFrom,
            LocalDate dateTo) {
        query.setParameter("department", department);
        query.setParameter("status", status);
        query.setParameter("exception", exception);
        query.setParameter("keyword", keyword);
        query.setParameter("keywordLike", "%" + keyword + "%");
        query.setParameter("date_from", dateFrom);
        query.setParameter("date_to", dateTo);
    }

    private static FulfillmentTaskRow mapRow(Object[] row) {
        return new FulfillmentTaskRow(
                (String) row[0],
                (UUID) row[1],
                (UUID) row[2],
                (UUID) row[3],
                (String) row[4],
                (UUID) row[5],
                (String) row[6],
                (UUID) row[7],
                (String) row[8],
                (String) row[9],
                (String) row[10],
                (UUID) row[11],
                (String) row[12],
                (UUID) row[13],
                (String) row[14],
                (String) row[15],
                decimal(row[16]),
                decimal(row[17]),
                decimal(row[18]),
                decimal(row[19]),
                decimal(row[20]),
                (String) row[21],
                localDate(row[22]),
                localDate(row[23]),
                (String) row[24],
                offsetDateTime(row[25]),
                (String) row[26],
                (UUID) row[27],
                (String) row[28],
                (UUID) row[29],
                (String) row[30],
                false,
                false,
                false,
                row[31] == null ? 0 : ((Number) row[31]).longValue(),
                row[32] == null ? 0 : ((Number) row[32]).longValue(),
                stringArray(row[33]));
    }

    /** text[] 聚合列（归组行的明细 id 集合）→ 不可变字符串列表；空值回空表。 */
    static List<String> stringArray(Object value) {
        if (value == null) return List.of();
        try {
            if (value instanceof java.sql.Array array) {
                return stringifyArray((Object[]) array.getArray());
            }
        } catch (java.sql.SQLException ignored) {
            // 聚合列读取失败按空集处理，不阻断列表展示。
        }
        // Hibernate 6 原生查询常把 text[] 直接映射为 String[]/Object[]（不经过
        // java.sql.Array）：只认 Array 会让归组行的明细 id 集恒为空，前端
        // 误报「先生成/挂接采购申请」且批量生成订货单永远不可用（2026-09-05
        // 实测修复——按单据归组后 action_item_id 恒 NULL，明细集只走本列）。
        if (value instanceof Object[] elements) {
            return stringifyArray(elements);
        }
        if (value instanceof java.util.Collection<?> collection) {
            return stringifyArray(collection.toArray());
        }
        return List.of();
    }

    private static List<String> stringifyArray(Object[] elements) {
        if (elements.length == 0) return List.of();
        List<String> ids = new java.util.ArrayList<>(elements.length);
        for (Object element : elements) {
            if (element != null) ids.add(element.toString());
        }
        return List.copyOf(ids);
    }

    private FulfillmentTaskRow applyActionAccess(FulfillmentTaskRow row) {
        if (row.actionDocId() == null || row.actionDocType() == null) return row;
        FulfillmentWorkbenchAccessPolicy.DocumentAccess access =
                accessPolicy.documentAccess(row.department(), row.actionDocType());
        if (!access.canView()) {
            // Retain only the fact that an action exists. IDs, numbers, item IDs,
            // status and type are business-document metadata and must not leak.
            return copyAction(row, null, null, null, null, null,
                    false, false, true);
        }
        return copyAction(
                row,
                row.actionDocType(),
                row.actionDocId(),
                row.actionDocNo(),
                row.actionDocItemId(),
                row.actionDocStatus(),
                true,
                access.canEdit(),
                false);
    }

    private static FulfillmentTaskRow copyAction(
            FulfillmentTaskRow row,
            String actionDocType,
            UUID actionDocId,
            String actionDocNo,
            UUID actionDocItemId,
            String actionDocStatus,
            boolean canView,
            boolean canEdit,
            boolean restricted) {
        return new FulfillmentTaskRow(
                row.department(), row.taskId(), row.packageId(), row.planId(), row.planNo(),
                row.warehouseId(), row.warehouseName(), row.goodsId(), row.goodsCode(),
                row.goodsName(), row.spec(), row.colorId(), row.colorName(), row.unitId(),
                row.unitName(), row.supplyRoute(), row.requiredQty(), row.allocatedQty(),
                row.fulfilledQty(), row.supplyPeggedQty(), row.openQty(), row.taskStatus(),
                row.needDate(), row.expectedDate(), row.exceptionCode(), row.updatedAt(),
                actionDocType, actionDocId, actionDocNo, actionDocItemId, actionDocStatus,
                canView, canEdit, restricted,
                row.goodsCount(), row.openLineCount(),
                restricted ? List.of() : row.actionItemIds());
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private static LocalDate localDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate date) return date;
        return ((java.sql.Date) value).toLocalDate();
    }

    static OffsetDateTime offsetDateTime(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime dateTime) {
            return dateTime.withOffsetSameInstant(ZoneOffset.UTC);
        }
        if (value instanceof Instant instant) {
            return instant.atOffset(ZoneOffset.UTC);
        }
        if (value instanceof Timestamp timestamp) {
            return timestamp.toInstant().atOffset(ZoneOffset.UTC);
        }
        throw new ApiException(ErrorCode.CONFLICT, "工作台更新时间类型异常");
    }
}
