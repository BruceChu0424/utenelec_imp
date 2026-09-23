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
    /**
     * 「进行中」= 订货单提交财务到结案之间的三档：ADR-098 先在委外任务中心落地，
     * ADR-100 把同一范式铺到采购任务工作台——分段栏只留「申请待分解」(红) 与
     * 「进行中」(黄) 两段，三档降级为表格里可筛的状态列。
     */
    static final List<String> IN_PROGRESS_STATUSES =
            List.of("ORDER_PENDING_APPROVAL", "FINANCE_APPROVED", "FINANCE_REJECTED");
    /**
     * 上面三档的 SQL 字面量。列表筛选、分段合计、黄徽章计数三处都从这一个常量展开，
     * 免得有人只在其中一处加档，让黄数与列表行数对不上。
     */
    private static final String IN_PROGRESS_STATUS_SQL = IN_PROGRESS_STATUSES.stream()
            .map(code -> "'" + code + "'")
            .collect(java.util.stream.Collectors.joining(", "));
    /**
     * 低于允许下限待判定(含分批等待逾期)的回厂短交案件 → 该订货单在任务中心标红、计入红徽章。
     * 容差内 / 未设允许损耗的中性案件不在此列(状态列另显「容差内待结案」, 不计红)。
     */
    static final String SHORT_DELIVERY_PENDING_EXISTS = """
            EXISTS (SELECT 1 FROM subcontract_short_delivery_cases short_case
                    WHERE short_case.order_id = %s
                      AND ((short_case.status = 'PENDING_OWNER'
                            AND short_case.severity IN ('SEVERE', 'BELOW_FLOOR'))
                           OR (short_case.status = 'WAITING_MORE'
                               AND short_case.expected_complete_by < CURRENT_DATE)))""";
    static final String SHORT_DELIVERY_TOLERANT_EXISTS = """
            EXISTS (SELECT 1 FROM subcontract_short_delivery_cases tolerant_case
                    WHERE tolerant_case.order_id = %s
                      AND tolerant_case.status = 'PENDING_OWNER'
                      AND tolerant_case.severity IN ('WITHIN_TOLERANCE', 'UNSET_TOLERANCE'))""";
    /**
     * ADR-103 路线 B (只有一个子层物料的委外件) 的锁判据, 全系统唯一口径——与
     * SubcontractMaterialPlanService.countTasks / draftLineCappedByStock 的 SQL 逐字同口径:
     * 子件 (goods_id, color_id) 在作业叶仓 (排除已删 / 不良品仓 / 线边仓) 的可动用合计;
     * 合计 > 0 即解锁, 否则锁. 两个 %s 依次是子件 goods_id / color_id 表达式.
     */
    static final String COMPONENT_STOCK_AVAILABLE_SQL = """
            (SELECT COALESCE(SUM(GREATEST(sa.available_qty, 0)), 0)
             FROM v_stock_available sa
             JOIN warehouses w ON w.id = sa.warehouse_id
             WHERE sa.goods_id = %s
               AND sa.color_id IS NOT DISTINCT FROM %s
               AND NOT w.is_deleted AND NOT w.is_defective AND NOT w.is_line_side
               AND fn_warehouse_is_operational_leaf(w.id))""";
    /**
     * ADR-103: 一张委外申请里「单一子件」明细 (fn_subcontract_sole_component_goods 为真) 且还有
     * 未下单量的行, 一行一明细, 带该明细子件的可动用合计. BOM 边取法与
     * SubcontractMaterialPlanService.soleOutboundComponent 一致——判据本体在 V581 函数里, 这里只取
     * 那唯一一条活动边的子件身份 (component_goods_id + edge.color_id). 已订满的明细
     * (qty <= ordered_qty) 已经不归申请行管, 不再参与锁定. 普通委外件 (无 BOM) 与多子件先自制的
     * 委外件不出行. %s = 申请 id 表达式.
     */
    static final String APPLICATION_SOLE_COMPONENT_ROWS = """
            SELECT sole_item.id AS application_item_id,
                   %s AS available_qty
            FROM subcontract_application_items sole_item
            JOIN goods_bom_items sole_edge ON sole_edge.goods_id = sole_item.goods_id
             AND sole_edge.is_deleted = FALSE
            JOIN goods sole_child ON sole_child.id = sole_edge.component_goods_id
             AND sole_child.is_deleted = FALSE
             AND COALESCE(sole_child.auto_created, FALSE) = FALSE
            WHERE sole_item.application_id = %s
              AND NOT sole_item.is_deleted
              AND COALESCE(sole_item.qty, 0) > COALESCE(sole_item.ordered_qty, 0)
              AND fn_subcontract_sole_component_goods(sole_item.goods_id)""".formatted(
            COMPONENT_STOCK_AVAILABLE_SQL.formatted("sole_edge.component_goods_id", "sole_edge.color_id"), "%s");

    /**
     * 仓库待领任务的单据归组行（一行=一张 DRAW 领料单；未挂单的行退回行级）。
     * 列表 {@link #query}、状态卡片与 {@link #warehouseStatusBreakdown} 子分类徽章
     * 都从这同一段 SQL 取 task_status，保证三处口径永不分叉：整单状态按全部行
     *（含已出完的 DONE 行）判定——无 open 行=DONE、任一行≠READY_TO_PICK=PARTIAL、
     * 否则 READY_TO_PICK。
     */
    static final String WAREHOUSE_DOCUMENT_ROWS = """
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
                         THEN SUM(request.fulfilled_qty) END AS fulfilled_qty,
                    CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                         THEN SUM(v.supply_pegged_qty) END AS supply_pegged_qty,
                    CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                         THEN SUM(request.open_qty) END AS open_qty,
                    CASE WHEN COUNT(*) FILTER (WHERE request.open_qty > 0) = 0
                         THEN 'DONE'
                         WHEN COUNT(*) FILTER (
                                  WHERE request.fulfilled_qty > 0) > 0
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
                    COUNT(*) FILTER (WHERE request.open_qty > 0) AS open_line_count,
                    COALESCE(
                        ARRAY_AGG(v.action_item_id::TEXT ORDER BY v.action_item_id)
                            FILTER (WHERE v.action_item_id IS NOT NULL),
                        ARRAY[]::TEXT[]
                    ) AS action_item_ids
             FROM v_fulfillment_workbench_actions v
             JOIN stock_document_items draw_item ON draw_item.id=v.action_item_id AND NOT draw_item.is_deleted
             CROSS JOIN LATERAL (SELECT
               COALESCE(draw_item.issued_qty,0)*COALESCE(draw_item.unit_rate,1) AS fulfilled_qty,
               GREATEST(fn_production_draw_item_requested_qty(draw_item.id)-COALESCE(draw_item.issued_qty,0),0)
                 *COALESCE(draw_item.unit_rate,1) AS open_qty) request
             WHERE v.department = 'WAREHOUSE'
               AND fn_production_draw_requested(v.action_doc_id)
               AND fn_production_draw_item_requested_qty(draw_item.id)>0
             GROUP BY v.department, COALESCE(v.action_doc_id, v.task_id))
            """;

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
        return query(department, status, keyword, exception, dateFrom, dateTo, page, size, null);
    }

    @Transactional(readOnly = true)
    public FulfillmentWorkbenchPage query(
            String department, String status, String keyword, String exception,
            LocalDate dateFrom, LocalDate dateTo, int page, int size,
            FulfillmentWorkbenchTableQuery table) {
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
                ? WAREHOUSE_DOCUMENT_ROWS
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
        sourceView = enrichTableRows(sourceView, department);
        // ADR-103 (2026-09-22 用户实机纠偏): 路线 B 被锁的申请行(display_stage = WAITING_COMPONENT_STOCK)
        // **留在「待处理」段**, 与路线 A 的前置自制合成行同款——用户口径「两个都是刚刚下单的, 都是待处理;
        // 等采购件到了再下委外订货单」。锁只体现在行上(不可勾选、阶段文案), 分段归属与计数一个不动。
        String statusBranches = """
                       OR (:status = 'IN_PROGRESS' AND task_status IN (%s))
                       OR (:status NOT IN ('OPEN_ANY', 'IN_PROGRESS') AND task_status = :status)""";
        String filters = """
                department = :department
                  AND (:status = ''
                       OR (:status = 'OPEN_ANY' AND open_line_count > 0)
                %s)
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
                """.formatted(statusBranches.formatted(IN_PROGRESS_STATUS_SQL));
        String tableFilters = table == null ? "" : table.rangeSql() + table.filterSql(null);
        String priority = "CASE WHEN can_create_order THEN 0 WHEN open_line_count > 0 THEN 1 ELSE 2 END, ";
        String orderBy = priority + (table == null ? "need_date NULLS LAST, task_id" : table.orderSql());

        Query rowsQuery = em.createNativeQuery("""
                SELECT department, task_id, package_id, plan_id, plan_no,
                       warehouse_id, warehouse_name, goods_id, goods_code,
                       goods_name, spec, color_id, color_name, unit_id, unit_name,
                       supply_route, required_qty, allocated_qty, fulfilled_qty,
                       supply_pegged_qty, open_qty, task_status, need_date,
                       expected_date, exception_code, updated_at,
                       action_doc_type, action_doc_id, action_doc_no, action_item_id, action_doc_status,
                       goods_count, open_line_count, action_item_ids, issued_at, can_create_order,
                       display_stage, component_available_qty
                FROM %s
                WHERE %s
                ORDER BY %s
                OFFSET :offset LIMIT :limit
                """.formatted(sourceView, filters + tableFilters, orderBy));
        bind(rowsQuery, department, normalizedStatus, normalizedKeyword,
                normalizedException, dateFrom, dateTo);
        if (table != null) table.bind(rowsQuery);
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
                """.formatted(sourceView, filters + tableFilters));
        bind(summaryQuery, department, normalizedStatus, normalizedKeyword,
                normalizedException, dateFrom, dateTo);
        if (table != null) table.bind(summaryQuery);
        Object[] summary = (Object[]) summaryQuery.getSingleResult();
        long total = ((Number) summary[0]).longValue();

        // ADR-103: 分段计数仍按 task_status 分桶(锁行留在 WAITING_ORDER 桶里, 与路线 A 合成行同款);
        // 第三列只是顺带数一下其中有多少行在等子件, 以 WAITING_COMPONENT_STOCK 键给前端做说明用,
        // 不参与任何分段徽章、也不从 WAITING_ORDER 里减掉。
        Query statusQuery = em.createNativeQuery("""
                SELECT task_status, COUNT(*),
                       COUNT(*) FILTER (WHERE display_stage = 'WAITING_COMPONENT_STOCK')
                FROM %s
                WHERE %s
                GROUP BY task_status
                ORDER BY task_status
                """.formatted(sourceView, filters));
        // Status cards always describe the whole department/keyword result so
        // selecting one card never makes the other card counts disappear.
        bind(statusQuery, department, "", normalizedKeyword, normalizedException, null, null);
        Map<String, Long> statusCounts = new LinkedHashMap<>();
        long waitingComponent = 0;
        for (Object[] row : NativeQueryResults.objectArrayRows(statusQuery)) {
            statusCounts.put((String) row[0], ((Number) row[1]).longValue());
            if (row.length > 2 && row[2] != null) {
                waitingComponent += ((Number) row[2]).longValue();
            }
        }
        if (usesDecompositionProjection(department)) {
            // 采购与委外的任务中心都把等待财务审核 / 财务已通过 / 财务已退回合并成「进行中」
            // 一段(ADR-100 的黄色在办数); 三档各自的计数保留给可筛的状态列与异常小类行。
            // 合并只发生在分段栏这一层, 逐档明细一个都没丢。
            statusCounts.put("IN_PROGRESS", IN_PROGRESS_STATUSES.stream()
                    .mapToLong(code -> statusCounts.getOrDefault(code, 0L)).sum());
            if ("SUBCONTRACT".equals(department)) {
                statusCounts.put("WAITING_COMPONENT_STOCK", waitingComponent);
            }
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
        Map<String, List<FulfillmentWorkbenchPage.Facet>> facets = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        if (table != null) {
            // One materialized candidate set; each column excludes its own filter, while
            // retaining all other columns and the real date/category/keyword predicates.
            String values = FulfillmentWorkbenchTableQuery.FIELDS.entrySet().stream()
                    .sorted(Map.Entry.comparingByKey()).map(entry -> {
                        String label = "goods".equals(entry.getKey())
                                ? "NULLIF(concat_ws(' ',goods_code,goods_name),'')" : entry.getValue();
                        return "('" + entry.getKey() + "'," + entry.getValue() + "," + label
                                + ", (TRUE " + table.filterSql(entry.getKey()) + "))";
                    }).collect(java.util.stream.Collectors.joining(","));
            Query facetQuery = em.createNativeQuery("""
                    WITH candidates AS MATERIALIZED (SELECT * FROM %s WHERE %s)
                    SELECT facet.key, facet.value, MAX(facet.label), COUNT(*)
                    FROM candidates CROSS JOIN LATERAL (VALUES %s) facet(key,value,label,included)
                    WHERE facet.included
                    GROUP BY facet.key,facet.value ORDER BY facet.key,facet.value NULLS LAST
                    """.formatted(sourceView, filters + table.rangeSql(), values));
            bind(facetQuery, department, normalizedStatus, normalizedKeyword, normalizedException, dateFrom, dateTo);
            table.bind(facetQuery);
            for (Object[] row : NativeQueryResults.objectArrayRows(facetQuery)) {
                String key = (String) row[0];
                long count = ((Number) row[3]).longValue();
                if (row[1] == null) {
                    nullCounts.put(key, count);
                } else {
                    facets.computeIfAbsent(key, ignored -> new java.util.ArrayList<>()).add(
                            new FulfillmentWorkbenchPage.Facet(row[1].toString(), (String) row[2], count));
                }
            }
        }

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
                                && accessPolicy.canCreateSubcontractOrder()), facets, nullCounts);
    }

    /**
     * 任务中心红徽章数（工作台模块卡 → hub → 任务中心逐级累加的叶子值）。
     *
     * <p><b>只数「等本部门动手」的阶段</b>（2026-09-11 用户反馈：采购任务中心的
     * 通知合计里混进了「财务已通过」）。采购/委外五档里，申请待分解
     * {@code WAITING_ORDER} 与财务驳回 {@code FINANCE_REJECTED} 才要本部门去办；
     * 等待财务审核 {@code ORDER_PENDING_APPROVAL} 与财务已通过·待采购完成
     * {@code FINANCE_APPROVED} 下一步在别人手上，是监控数——前端
     * operations_workbench_page 的 {@code _stageCountForm} 早已把这两档判为
     * browsing（中性括号、不累加），这里同步收敛，红徽章合计=各红色分段之和。
     * {@code COMPLETED} 是终态，本就被 {@code open_qty > 0} 挡掉。
     *
     * <p>口径依据 docs/00-项目准则/14-徽章与计数口径.md。
     */
    @Transactional(readOnly = true)
    public long countPending(String department) {
        if (!DEPARTMENTS.contains(department)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "工作台部门无效");
        }
        if ("WAREHOUSE".equals(department)
                && !accessPolicy.canAccessWarehouseTasks()) {
            return 0;
        }
        boolean decomposition = usesDecompositionProjection(department);
        // 与列表同口径：采购/委外按单据归组计数（一张申请/订货单=一个待办）；
        // 仓库按单张领料单计数（一张 DRAW=一个待办，未挂单的行退回行级）。
        boolean includePreparation = "SUBCONTRACT".equals(department)
                && accessPolicy.canViewSubcontractPreparationTasks();
        String preparation = includePreparation
                ? " UNION ALL SELECT task.id FROM preplan_subcontract_make_tasks task WHERE " + PENDING_MAKE
                : "";
        // ADR-098：委外还要数「回厂短交待判定」的订货单(财务已通过但有待判定案件), 与列表异常行同源。
        String shortDelivery = "SUBCONTRACT".equals(department)
                ? " OR (decomposition.task_status = 'FINANCE_APPROVED'"
                        + " AND decomposition.action_doc_type = 'SUBCONTRACT_ORDER' AND "
                        + SHORT_DELIVERY_PENDING_EXISTS.formatted("decomposition.action_doc_id") + ")"
                : "";
        // ADR-103 (2026-09-22 用户实机纠偏): 路线 B 被锁的申请行照样计入红数——与路线 A 的前置自制
        // 合成行同款, 用户口径「刚下单的都是待处理」; 锁只体现在行上, 不改分段与角标口径。
        Query query = em.createNativeQuery(decomposition
                ? """
                    SELECT COUNT(*) FROM (
                        SELECT DISTINCT decomposition.action_doc_id
                        FROM v_procurement_decomposition_tasks decomposition
                        WHERE decomposition.department = :department AND decomposition.open_qty > 0
                          AND (decomposition.task_status IN ('WAITING_ORDER', 'FINANCE_REJECTED')%s)
                        %s
                    ) documents
                    """.formatted(shortDelivery, preparation)
                : """
                    SELECT COUNT(*) FROM (
                        SELECT DISTINCT COALESCE(action_doc_id, task_id)
                        FROM v_fulfillment_workbench_actions
                        WHERE department = :department AND open_qty > 0
                          AND fn_production_draw_pending(action_doc_id)
                    ) documents
                    """);
        query.setParameter("department", department);
        return ((Number) query.getSingleResult()).longValue();
    }

    /**
     * 任务中心黄徽章数 (ADR-100「我手上还有多少在跑」)：采购/委外的「进行中」合计，
     * 与分段栏 {@code summary.statusCounts.IN_PROGRESS} 同一口径——等待财务审核 /
     * 财务已通过 / 财务已退回三档，球都不在本部门手上，但单子还在流程里没结束。
     *
     * <p>分组键与列表的归组完全一致 (action_doc_type + action_doc_id + task_status)，
     * 所以黄数与「进行中」列表的行数逐条相等；这与红数 {@link #countPending} 的
     * {@code DISTINCT action_doc_id} 是两个量纲，ADR-100 §2.6 已写明不要拿两个数对账。
     *
     * <p>刻意不套 {@code open_qty > 0}：回厂净量已到齐、订货单还没关闭的单子仍在
     * 进行中列表里看得见，黄数漏掉它就会与列表行数对不上。
     *
     * <p>仓库备料只有「待备料 / 部分领取」两档，都是等本部门动手的红色待办，没有在办态，
     * 故恒为 0 且不查库。
     */
    @Transactional(readOnly = true)
    public long countInProgress(String department) {
        if (!DEPARTMENTS.contains(department)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "工作台部门无效");
        }
        if (!usesDecompositionProjection(department)) {
            return 0;
        }
        Query query = em.createNativeQuery("""
                SELECT COUNT(*) FROM (
                    SELECT decomposition.action_doc_type, decomposition.action_doc_id,
                           decomposition.task_status
                    FROM v_procurement_decomposition_tasks decomposition
                    WHERE decomposition.department = :department
                      AND decomposition.task_status IN (%s)
                    GROUP BY decomposition.action_doc_type, decomposition.action_doc_id,
                             decomposition.task_status
                ) documents
                """.formatted(IN_PROGRESS_STATUS_SQL));
        query.setParameter("department", department);
        return ((Number) query.getSingleResult()).longValue();
    }

    /** 采购/委外读订货分解投影，仓库读领料投影——两边的归组键与状态集合都不通用。 */
    private static boolean usesDecompositionProjection(String department) {
        return "PURCHASE".equals(department) || "SUBCONTRACT".equals(department);
    }

    /**
     * 仓库领料任务分状态计数（2026-09-09 子分类徽章；2026-09-10 改为与列表同源）：
     * 直接复用列表的单据归组行 {@link #WAREHOUSE_DOCUMENT_ROWS} 取 task_status——
     * 一张 DRAW=一个待办（未挂单行退回行级），整单状态按全部行判定（含已出完的
     * DONE 行：任一行≠READY_TO_PICK 即 PARTIAL），与列表分段「待备料/部分领取」
     * 及列表返回的 summary.statusCounts 逐条相等；OPEN_ANY = READY_TO_PICK + PARTIAL；
     * DONE 为终态不计数。此前独立写的一段 SQL 只看 open_qty>0 的行，与列表口径
     * 分叉（部分领取单会被记成待备料），故删除。
     */
    @Transactional(readOnly = true)
    public Map<String, Long> warehouseStatusBreakdown() {
        if (!accessPolicy.canAccessWarehouseTasks()) {
            return Map.of("READY_TO_PICK", 0L, "PARTIAL", 0L, "OPEN_ANY", 0L);
        }
        Query query = em.createNativeQuery("""
                SELECT task_status, COUNT(*)
                FROM %s document_rows
                WHERE task_status IN ('READY_TO_PICK', 'PARTIAL')
                GROUP BY task_status
                """.formatted(WAREHOUSE_DOCUMENT_ROWS));
        long ready = 0;
        long partial = 0;
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) {
            String status = String.valueOf(row[0]);
            long count = ((Number) row[1]).longValue();
            if ("READY_TO_PICK".equals(status)) ready = count;
            else if ("PARTIAL".equals(status)) partial = count;
        }
        return Map.of(
                "READY_TO_PICK", ready,
                "PARTIAL", partial,
                "OPEN_ANY", ready + partial);
    }

    /** Pending preparation is a server-paged read-only task, never a client-side extra row. */
    private String enrichTableRows(String source, String department) {
        boolean subcontract = "SUBCONTRACT".equals(department);
        boolean purchase = "PURCHASE".equals(department);
        boolean canCreate = subcontract ? accessPolicy.canCreateSubcontractOrder()
                : purchase && accessPolicy.canCreatePurchaseOrder();
        String requestType = subcontract ? "SUBCONTRACT_APPLICATION" : "PURCHASE_REQUEST";
        List<String> types = "WAREHOUSE".equals(department) ? List.of("DRAW")
                : subcontract ? List.of("SUBCONTRACT_APPLICATION", "SUBCONTRACT_ORDER", "SUBCONTRACT_MAKE_TASK")
                : List.of("PURCHASE_REQUEST", "PURCHASE_ORDER");
        String readable = types.stream().filter(type -> accessPolicy.documentAccess(department, type) != null
                        && accessPolicy.documentAccess(department, type).canView())
                .map(type -> "'" + type + "'").collect(java.util.stream.Collectors.joining(","));
        String visibleDoc = readable.isEmpty() ? "NULL::text"
                : "CASE WHEN base.action_doc_type IN (" + readable + ") THEN NULLIF(base.action_doc_no,'') END";
        String issueJoin = subcontract ? """
                LEFT JOIN LATERAL (
                    WITH source_items AS (
                        SELECT item::uuid AS application_item_id
                        FROM unnest(base.action_item_ids) item
                        WHERE base.action_doc_type='SUBCONTRACT_APPLICATION'
                        UNION
                        SELECT source.application_item_id
                        FROM unnest(base.action_item_ids) item
                        JOIN subcontract_order_item_sources source ON source.order_item_id=item::uuid
                        WHERE base.action_doc_type='SUBCONTRACT_ORDER' AND source.alloc_qty > 0
                    ), origin_actions AS (
                        SELECT task.supply_action_id AS id
                        FROM preplan_subcontract_make_tasks task
                        WHERE base.action_doc_type='SUBCONTRACT_MAKE_TASK' AND task.id=base.action_doc_id
                        UNION
                        SELECT task.supply_action_id
                        FROM source_items source
                        JOIN preplan_subcontract_make_task_batches batch ON batch.application_item_id=source.application_item_id
                        JOIN preplan_subcontract_make_tasks task ON task.id=batch.task_id
                        UNION
                        SELECT allocation.action_id
                        FROM source_items source
                        JOIN preplan_supply_action_allocations allocation ON allocation.external_item_id=source.application_item_id
                        JOIN preplan_supply_actions action ON action.id=allocation.action_id
                          AND action.external_document_type='SUBCONTRACT_APPLICATION' AND action.route='SUBCONTRACT'
                        WHERE NOT EXISTS(SELECT 1 FROM preplan_subcontract_make_task_batches batch
                                         WHERE batch.application_item_id=source.application_item_id)
                    )
                    SELECT MIN(action.created_at) AS issued_at
                    FROM origin_actions origin JOIN preplan_supply_actions action ON action.id=origin.id
                ) issue ON TRUE
                """ : "";
        // ADR-103 路线 B: 申请行 (下单前) 按「单一子件的子件仓里有没有货」加锁. 归组行一张申请
        // 多明细 (base.goods_id 可能为 NULL), 所以按申请 id 展开到 subcontract_application_items,
        // 任一单一子件明细无货即整张申请锁 (BOOL_OR); available_qty 取各单一子件明细可动用量的 MIN,
        // 给前端提示「可发数量」. 非申请行把关联键置 NULL, 一行都不扫.
        String componentJoin = subcontract ? """
                LEFT JOIN LATERAL (
                    SELECT BOOL_OR(sole.available_qty <= 0) AS locked,
                           MIN(sole.available_qty) AS available_qty
                    FROM (%s) sole
                ) component ON TRUE
                """.formatted(APPLICATION_SOLE_COMPONENT_ROWS.formatted(
                "CASE WHEN base.action_doc_type = 'SUBCONTRACT_APPLICATION' THEN base.action_doc_id END")) : "";
        // ADR-098：委外订货单在「进行中」里的执行状态(状态列/表头筛选/排序都走 display_stage)：
        // 回厂短交待判定 > 分批等待中 > 容差内待结案 > 已回厂待入库(回厂净量已到齐, 只差质检入库)
        // > 部分回厂 > 委外加工中(已发料/已出仓) > 出仓等子件到货 (ADR-103) > 待发料出仓；
        // 财务已退回与短交待判定同时写进 exception_code, 让异常小类行挂红徽章。
        String progressJoin = subcontract ? """
                LEFT JOIN LATERAL (
                    SELECT %s AS short_pending,
                           %s AS tolerant_pending,
                           EXISTS (SELECT 1 FROM subcontract_material_plan_items waiting_item
                                   JOIN subcontract_material_plans waiting_plan
                                     ON waiting_plan.id = waiting_item.plan_id
                                    AND waiting_plan.status = 'OPEN' AND NOT waiting_plan.is_deleted
                                   WHERE waiting_plan.order_id = base.action_doc_id
                                     AND NOT waiting_item.is_deleted
                                     AND waiting_item.flow_mode = 'COMPONENT_OUTBOUND'
                                     AND LEAST(waiting_item.planned_qty, waiting_item.prepared_qty)
                                         - waiting_item.issued_qty > 0
                                     AND NOT EXISTS (SELECT 1 FROM subcontract_material_issue_items draft_item
                                                     JOIN subcontract_material_issues draft_doc
                                                       ON draft_doc.id = draft_item.issue_id
                                                     WHERE draft_item.plan_item_id = waiting_item.id
                                                       AND draft_doc.status = 0 AND NOT draft_doc.is_deleted)
                                     AND %s <= 0) AS waiting_component,
                           EXISTS (SELECT 1 FROM subcontract_short_delivery_cases waiting_case
                                   WHERE waiting_case.order_id = base.action_doc_id
                                     AND waiting_case.status = 'WAITING_MORE'
                                     AND waiting_case.expected_complete_by >= CURRENT_DATE) AS waiting_more,
                           EXISTS (SELECT 1 FROM subcontract_order_items received_item
                                   WHERE received_item.order_id = base.action_doc_id
                                     AND NOT received_item.is_deleted
                                     AND COALESCE(received_item.received_qty, 0) > 0) AS any_received,
                           NOT EXISTS (SELECT 1 FROM subcontract_order_items pending_item
                                       WHERE pending_item.order_id = base.action_doc_id
                                         AND NOT pending_item.is_deleted
                                         AND COALESCE(pending_item.received_qty, 0)
                                             - COALESCE(pending_item.returned_qty, 0)
                                             < COALESCE(pending_item.qty, 0)) AS all_received,
                           EXISTS (SELECT 1 FROM subcontract_material_issue_items issued_item
                                   JOIN subcontract_material_issues issued_doc
                                     ON issued_doc.id = issued_item.issue_id
                                    AND issued_doc.status = 1 AND NOT issued_doc.is_deleted
                                   JOIN subcontract_order_items issued_order_item
                                     ON issued_order_item.id = issued_item.order_item_id
                                   WHERE issued_order_item.order_id = base.action_doc_id
                                     AND NOT issued_item.is_deleted) AS any_issued
                    WHERE base.action_doc_type = 'SUBCONTRACT_ORDER'
                ) progress ON TRUE
                """.formatted(SHORT_DELIVERY_PENDING_EXISTS.formatted("base.action_doc_id"),
                        SHORT_DELIVERY_TOLERANT_EXISTS.formatted("base.action_doc_id"),
                        COMPONENT_STOCK_AVAILABLE_SQL.formatted("waiting_item.goods_id", "waiting_item.color_id")) : "";
        // ADR-100：采购侧的执行状态就是 task_status 本身(等待财务审核 / 财务已通过 /
        // 财务已退回三档), 下面的 ELSE 分支已经把它落进 display_stage —— 采购与委外因此
        // 共用同一列做状态列、表头筛选与排序, 采购不另算一遍。
        // ADR-103: 申请行两档——锁住 WAITING_COMPONENT_STOCK (等子件到货, 黄) / 解锁 COMPONENT_STOCK_READY
        // (子件有货可下委外订货, 红, 行带 component_available_qty); 普通委外件仍是 WAITING_ORDER.
        // 财务已通过的订货单: 计划行还有余量、没有未审草稿、子件仓里又一件都没有 → OUTBOUND_WAITING_COMPONENT,
        // 排在 AT_SUPPLIER 之前——分批发了一部分、其余还在等子件时, 委外部门要看到的是「还有货发不出去」,
        // 而不是被「委外加工中」盖住(2026-09-22 8081 冒烟: 发出 6 剩 4994 等料, 原排序显示成 AT_SUPPLIER)。
        String stageExpression = subcontract ? """
                CASE WHEN base.action_doc_type='SUBCONTRACT_MAKE_TASK' THEN base.action_doc_status
                     WHEN base.action_doc_type='SUBCONTRACT_APPLICATION' AND base.task_status='WAITING_ORDER'
                          AND COALESCE(component.locked, FALSE) THEN 'WAITING_COMPONENT_STOCK'
                     WHEN base.action_doc_type='SUBCONTRACT_APPLICATION' AND base.task_status='WAITING_ORDER'
                          AND component.available_qty > 0 THEN 'COMPONENT_STOCK_READY'
                     WHEN base.action_doc_type='SUBCONTRACT_ORDER' AND base.task_status='FINANCE_APPROVED' THEN
                          CASE WHEN progress.short_pending THEN 'SHORT_DELIVERY'
                               WHEN progress.waiting_more THEN 'WAITING_MORE_BATCH'
                               WHEN progress.tolerant_pending THEN 'TOLERANT_SHORT'
                               WHEN progress.any_received AND progress.all_received THEN 'RECEIVED_PENDING_STOCK'
                               WHEN progress.any_received THEN 'PARTIAL_RECEIVED'
                               WHEN progress.waiting_component THEN 'OUTBOUND_WAITING_COMPONENT'
                               WHEN progress.any_issued THEN 'AT_SUPPLIER'
                               ELSE 'AWAITING_OUTBOUND' END
                     ELSE base.task_status END""" : """
                CASE WHEN base.action_doc_type='SUBCONTRACT_MAKE_TASK' THEN base.action_doc_status
                     ELSE base.task_status END""";
        // 采购的财务已退回也写进 exception_code(与委外同构)：分段栏虽把它并进了「进行中」,
        // 但改单重报是本部门要动手的活, 必须继续以异常小类行挂红徽章;
        // countPending 走的是 task_status, 不受这里改写影响, 红数一个不少。
        String exceptionExpression = subcontract ? """
                CASE WHEN base.action_doc_type='SUBCONTRACT_ORDER' AND progress.short_pending THEN 'SHORT_DELIVERY'
                     WHEN base.action_doc_type='SUBCONTRACT_ORDER' AND base.task_status='FINANCE_REJECTED'
                          THEN 'FINANCE_REJECTED'
                     ELSE base.exception_code END""" : purchase ? """
                CASE WHEN base.action_doc_type='PURCHASE_ORDER' AND base.task_status='FINANCE_REJECTED'
                          THEN 'FINANCE_REJECTED'
                     ELSE base.exception_code END""" : "base.exception_code";
        // A grouped order can contain several real source issues. Its earliest source issue
        // remains the displayed date; later preparation/app creation never substitutes for it.
        return """
                (SELECT base.department, base.task_id, base.package_id, base.plan_id, base.plan_no,
                        base.warehouse_id, base.warehouse_name, base.goods_id, base.goods_code,
                        base.goods_name, base.spec, base.color_id, base.color_name, base.unit_id, base.unit_name,
                        base.supply_route, base.required_qty, base.allocated_qty, base.fulfilled_qty,
                        base.supply_pegged_qty, base.open_qty, base.task_status, base.need_date,
                        base.expected_date, %s AS exception_code, base.updated_at,
                        base.action_doc_type, base.action_doc_id, base.action_doc_no, base.action_item_id,
                        base.action_doc_status, base.goods_count, base.open_line_count, base.action_item_ids,
                        %s AS issued_at,
                        (%s AND base.task_status='WAITING_ORDER' AND base.action_doc_type='%s'
                            AND base.open_line_count > 0%s) AS can_create_order,
                        %s AS visible_doc_no,
                        %s AS display_stage,
                        %s AS component_available_qty
                 FROM %s base %s %s %s)
                """.formatted(exceptionExpression, subcontract ? "issue.issued_at" : "NULL::timestamptz",
                        canCreate ? "TRUE" : "FALSE", requestType,
                        // ADR-103: 路线 B 锁住的申请不能生成委外订货单 (与建单/送审/批准的服务端守卫同判据).
                        subcontract ? " AND NOT COALESCE(component.locked, FALSE)" : "",
                        visibleDoc, stageExpression,
                        subcontract ? "component.available_qty" : "NULL::numeric",
                        source, issueJoin, progressJoin, componentJoin);
    }

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
                new FulfillmentWorkbenchPage.Capabilities(false, false), Map.of(), Map.of());
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
                stringArray(row[33]), row.length > 34 ? offsetDateTime(row[34]) : null,
                row.length > 35 && Boolean.TRUE.equals(row[35]),
                row.length > 36 ? (String) row[36] : null,
                row.length > 37 && row[37] != null ? new BigDecimal(row[37].toString()) : null);
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
                restricted ? List.of() : row.actionItemIds(), row.issuedAt(),
                !restricted && row.canCreateOrder(), row.displayStage(),
                row.componentAvailableQty());
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
