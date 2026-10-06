package com.uten.imp.features.operations.workbench;

import com.uten.imp.application.port.SubcontractTaskSource;
import com.uten.imp.common.finance.SubcontractLossSettlementSql;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
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
                               AND short_case.severity <> 'WITHIN_TOLERANCE'
                               AND short_case.expected_complete_by < CURRENT_DATE)))""";
    static final String SHORT_DELIVERY_TOLERANT_EXISTS = """
            EXISTS (SELECT 1 FROM subcontract_short_delivery_cases tolerant_case
                    WHERE tolerant_case.order_id = %s
                      AND ((tolerant_case.status = 'PENDING_OWNER'
                            AND tolerant_case.severity IN ('WITHIN_TOLERANCE', 'UNSET_TOLERANCE'))
                           OR (tolerant_case.status = 'WAITING_MORE'
                               AND tolerant_case.severity = 'WITHIN_TOLERANCE')))""";

    /**
     * 仓库待领任务按真实 DRAW 明细映射归组；同一需求跨仓的多张单均独立列出。
     * 未配置实际仓的材料申请由下面独立分支保留申请身份，不伪造库存单。
     * 列表 {@link #query}、状态卡片与 {@link #warehouseStatusBreakdown} 子分类徽章
     * 都从这同一段 SQL 取 task_status，保证三处口径永不分叉：整单状态按全部行
     *（含已出完的 DONE 行）判定——无 open 行=DONE、任一行≠READY_TO_PICK=PARTIAL、
     * 否则 READY_TO_PICK。
     */
    static final String WAREHOUSE_DOCUMENT_ROWS = """
            (SELECT v.department,
                    draw_doc.id AS task_id,
                    MIN(v.package_id::text)::uuid AS package_id,
                    MIN(v.plan_id::text)::uuid AS plan_id,
                    MAX(v.plan_no) AS plan_no,
                    draw_doc.warehouse_id AS warehouse_id,
                    MAX(actual_warehouse.name) AS warehouse_name,
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
                         THEN SUM(request.effective_qty) END AS required_qty,
                    CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                         THEN SUM(request.effective_qty) END AS allocated_qty,
                    CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                         THEN SUM(request.fulfilled_qty) END AS fulfilled_qty,
                    CASE WHEN COUNT(DISTINCT v.goods_id) = 1
                         THEN 0::numeric END AS supply_pegged_qty,
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
                    CASE WHEN COUNT(*) FILTER (WHERE request.open_qty > 0)=0
                         THEN NULL ELSE MAX(v.exception_code) END AS exception_code,
                    MAX(GREATEST(v.updated_at,draw_doc.updated_at)) AS updated_at,
                    'DRAW'::text AS action_doc_type,
                    draw_doc.id AS action_doc_id,
                    draw_doc.bill_no AS action_doc_no,
                    NULL::UUID AS action_item_id,
                    draw_doc.status::text AS action_doc_status,
                    COUNT(DISTINCT v.goods_id) AS goods_count,
                    COUNT(*) FILTER (WHERE request.open_qty > 0) AS open_line_count,
                    COALESCE(
                        ARRAY_AGG(draw_item.id::TEXT ORDER BY draw_item.id),
                        ARRAY[]::TEXT[]
                    ) AS action_item_ids,
                    -- 2026-09-27 表头统一（用户口径「领料页与批量出库一样」）：
                    -- 待领任务补领料车间/领料负责人（与批量出库明细表同源同义）。
                    MAX(draw_dept.name) AS workshop_name,
                    MAX(worker.full_name) AS worker_name,
                    -- 2026-09-27 批量领料批次号（同批多张单同值，仓库识别一批领料）。
                    MAX(draw_doc.draw_batch_no) AS draw_batch_no,
                    -- 2026-09-27 行级明细（货品×数量）：前端按「批次×货品」拆分/合并
                    -- 待领任务行用（用户口径「相同货品合并、3 种物料拆开一行一个」）。
                    -- 同货品多行由前端聚合时求和，这里保持行粒度。
                    COALESCE(jsonb_agg(jsonb_build_object(
                        'goodsCode', v.goods_code,
                        'goodsName', v.goods_name,
                        'colorName', v.color_name,
                        'unitName', v.unit_name,
                        'requiredQty', request.effective_qty,
                        'fulfilledQty', request.fulfilled_qty,
                        'openQty', request.open_qty
                    ) ORDER BY v.goods_code NULLS LAST, v.color_name NULLS LAST), '[]'::jsonb) AS lines
             FROM v_fulfillment_workbench v
             JOIN production_planning_package_document_items mapping
               ON mapping.package_id=v.package_id AND mapping.demand_id=v.task_id AND mapping.document_type='DRAW'
             JOIN stock_documents draw_doc ON draw_doc.id=mapping.document_id
               AND draw_doc.doc_type='DRAW' AND NOT draw_doc.is_deleted AND draw_doc.status IN(0,1)
             JOIN stock_document_items draw_item ON draw_item.id=mapping.document_item_id
               AND draw_item.doc_id=draw_doc.id AND NOT draw_item.is_deleted
             LEFT JOIN warehouses actual_warehouse ON actual_warehouse.id=draw_doc.warehouse_id
             LEFT JOIN departments draw_dept ON draw_dept.id=draw_doc.department_id
             LEFT JOIN employees worker ON worker.id=draw_doc.worker_id
             CROSS JOIN LATERAL (SELECT
               fn_production_draw_item_effective_qty(draw_item.id)*COALESCE(draw_item.unit_rate,1) AS effective_qty,
               COALESCE(draw_item.issued_qty,0)*COALESCE(draw_item.unit_rate,1) AS fulfilled_qty,
               GREATEST(fn_production_draw_item_requested_qty(draw_item.id)-COALESCE(draw_item.issued_qty,0),0)
                 *COALESCE(draw_item.unit_rate,1) AS open_qty) request
             WHERE v.department = 'WAREHOUSE'
               AND fn_production_draw_requested(draw_doc.id)
               AND fn_production_draw_item_requested_qty(draw_item.id)>0
             GROUP BY v.department,draw_doc.id,draw_doc.warehouse_id,draw_doc.bill_no,draw_doc.status
             UNION ALL
             SELECT 'WAREHOUSE', request.id, segment.package_id, segment.plan_id,
                    plan.bill_no, NULL::uuid, NULL::text,
                    material.goods_id, material.goods_code, material.goods_name, material.spec,
                    material.color_id, material.color_name, material.unit_id, material.unit_name,
                    'MAKE', material.qty, NULL::numeric, NULL::numeric, NULL::numeric,
                    material.qty, 'MATERIALS_TO_DEFINE', segment.plan_end_date, NULL::date,
                    NULL::text, request.created_at, 'MATERIAL_DISCOVERY', request.id,
                    request.request_no, NULL::uuid, NULL::text, material.goods_count,
                    GREATEST(material.line_count,1), ARRAY[]::text[],
                    NULL::text AS workshop_name, NULL::text AS worker_name,
                    NULL::text AS draw_batch_no,
                    '[]'::jsonb AS lines
             FROM production_material_discovery_requests request
             JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
             JOIN production_plans plan ON plan.id=segment.plan_id
             CROSS JOIN LATERAL (
                 SELECT COUNT(DISTINCT item."goodsId") AS goods_count, COUNT(*) AS line_count,
                        CASE WHEN COUNT(DISTINCT item."goodsId")=1 THEN MIN(item."goodsId"::text)::uuid END AS goods_id,
                        CASE WHEN COUNT(DISTINCT item."goodsId")=1 THEN MAX(item."goodsCode") END AS goods_code,
                        STRING_AGG(DISTINCT item."goodsName",'、' ORDER BY item."goodsName") AS goods_name,
                        CASE WHEN COUNT(DISTINCT item."goodsId")=1 THEN MAX(goods.spec) END AS spec,
                        CASE WHEN COUNT(*)=1 THEN MIN(item."colorId"::text)::uuid END AS color_id,
                        CASE WHEN COUNT(*)=1 THEN MAX(item."colorName") END AS color_name,
                        CASE WHEN COUNT(*)=1 THEN MIN(item."unitId"::text)::uuid END AS unit_id,
                        CASE WHEN COUNT(*)=1 THEN MAX(item."unitName") END AS unit_name,
                        CASE WHEN COUNT(*)=1 THEN MAX(item.qty) END AS qty
                 FROM jsonb_to_recordset(request.requested_materials) AS item(
                     "goodsId" uuid,"goodsCode" text,"goodsName" text,"colorId" uuid,"colorName" text,
                     "unitId" uuid,"unitName" text,qty numeric)
                 LEFT JOIN goods ON goods.id=item."goodsId"
             ) material
             WHERE request.status='PENDING' AND NOT segment.is_deleted
               AND segment.status IN ('WAITING','READY','DISPATCHED')
               AND plan.status=1 AND NOT plan.is_deleted AND NOT plan.is_closed
               AND NOT plan.is_canceled AND NOT plan.is_stopped)
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
        return query(department, status, keyword, exception, dateFrom, dateTo, page, size, table,
                WarehouseTaskScope.ALL);
    }

    /**
     * 同上, 仓库待领任务另按仓库数据范围过滤(ADR-149: 本人范围 / 所选仓); 采购/委外忽略范围。
     * 范围进 {@code filters}, 列表、合计、状态卡与待完成计数同口径。
     */
    @Transactional(readOnly = true)
    public FulfillmentWorkbenchPage query(
            String department, String status, String keyword, String exception,
            LocalDate dateFrom, LocalDate dateTo, int page, int size,
            FulfillmentWorkbenchTableQuery table, WarehouseTaskScope warehouseScope) {
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
                          ) AS action_item_ids,
                          NULL::text AS workshop_name, NULL::text AS worker_name,
                          NULL::text AS draw_batch_no, '[]'::jsonb AS lines
                   FROM v_procurement_decomposition_tasks v
                   GROUP BY v.department, v.action_doc_type, v.action_doc_id, v.task_status)
                  """;
        sourceView = enrichTableRows(sourceView, department);
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
                      COALESCE(goods_name,'') || ' ' ||
                      COALESCE(production_product_code,'') || ' ' ||
                      COALESCE(production_product_name,'') || ' ' ||
                      COALESCE(material_request_no,'') || ' ' ||
                      COALESCE(execution_segment_codes,'')
                  ) LIKE :keywordLike)
                  -- 历史记录时间门控：仅行/汇总查询传入日期；null = 不过滤
                  -- （状态/异常/待完成计数始终传 null，保持角标全量口径）。
                  -- updated_at 对已完成任务近似完结时间。
                  AND (CAST(:date_from AS date) IS NULL
                       OR updated_at >= CAST(:date_from AS date))
                  AND (CAST(:date_to AS date) IS NULL
                       OR updated_at < CAST(:date_to AS date) + INTERVAL '1 day')
                """.formatted(statusBranches.formatted(IN_PROGRESS_STATUS_SQL));
        boolean scoped = "WAREHOUSE".equals(department)
                && warehouseScope != null && warehouseScope.active();
        if (scoped) filters += " AND " + warehouseScope.predicate("warehouse_id", ":warehouse_scope");
        java.util.function.Consumer<Query> bindScope = query -> {
            if (scoped) query.setParameter("warehouse_scope", warehouseScope.idsCsv());
        };
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
                       display_stage,
                       materials_defined, production_product_code, production_product_name, material_request_no,
                       workshop_name, worker_name, draw_batch_no, lines,
                       rd_task_no, bom_missing_item_ids, orderable_qty
                FROM %s
                WHERE %s
                ORDER BY %s
                OFFSET :offset LIMIT :limit
                """.formatted(sourceView, filters + tableFilters, orderBy));
        bind(rowsQuery, department, normalizedStatus, normalizedKeyword,
                normalizedException, dateFrom, dateTo);
        bindScope.accept(rowsQuery);
        if (table != null) table.bind(rowsQuery);
        rowsQuery.setParameter("offset", (long) (safePage - 1) * safeSize);
        rowsQuery.setParameter("limit", safeSize);
        List<FulfillmentTaskRow> items =
                NativeQueryResults.objectArrayRows(rowsQuery).stream()
                        .map(FulfillmentWorkbenchQueryService::mapRow)
                        .map(this::applyActionAccess)
                        .toList();
        if ("SUBCONTRACT".equals(department)) items = enrichApplicationSources(items);

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
        bindScope.accept(summaryQuery);
        if (table != null) table.bind(summaryQuery);
        Object[] summary = (Object[]) summaryQuery.getSingleResult();
        long total = ((Number) summary[0]).longValue();

        // ADR-143 §二.3：缺 BOM 的委外申请行(display_stage BOM_MISSING)照样列在「待处理」段(task_status
        // 仍是 WAITING_ORDER), 但球在研发手上, 不计入该段红数; 单独以 BOM_MISSING 计数, 与 countPending 同口径。
        String statusKey = "SUBCONTRACT".equals(department)
                ? "CASE WHEN display_stage = 'BOM_MISSING' THEN 'BOM_MISSING' ELSE task_status END"
                : "task_status";
        Query statusQuery = em.createNativeQuery("""
                SELECT %s AS status_key, COUNT(*)
                FROM %s
                WHERE %s
                GROUP BY 1
                ORDER BY 1
                """.formatted(statusKey, sourceView, filters));
        // Status cards always describe the whole department/keyword result so
        // selecting one card never makes the other card counts disappear.
        bind(statusQuery, department, "", normalizedKeyword, normalizedException, null, null);
        bindScope.accept(statusQuery);
        Map<String, Long> statusCounts = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(statusQuery)) {
            statusCounts.put((String) row[0], ((Number) row[1]).longValue());
        }
        if (usesDecompositionProjection(department)) {
            // 采购与委外的任务中心都把等待财务审核 / 财务已通过 / 财务已退回合并成「进行中」
            // 一段(ADR-100 的黄色在办数); 三档各自的计数保留给可筛的状态列与异常小类行。
            // 合并只发生在分段栏这一层, 逐档明细一个都没丢。
            statusCounts.put("IN_PROGRESS", IN_PROGRESS_STATUSES.stream()
                    .mapToLong(code -> statusCounts.getOrDefault(code, 0L)).sum());
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
        bindScope.accept(exceptionQuery);
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
        bindScope.accept(pendingQuery);
        long pendingTasks = ((Number) pendingQuery.getSingleResult()).longValue();
        Map<String, List<FulfillmentWorkbenchPage.Facet>> facets = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        if (table != null && !"WAREHOUSE".equals(department)) {
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
            bindScope.accept(facetQuery);
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
        } else if ("WAREHOUSE".equals(department)) {
            // 2026-09-25 单号列统一：仓库待领任务也带回 docNo（领料单号）桶——只算这一列
            // （其余列仍不做分面），谓词与列表同一份 filters，docNo 自身的值筛选不算进桶。
            // table 可为 null（未排序、无列筛选时），此时桶只按状态/关键字/范围过滤。
            String docNoFilter = table == null ? "" : table.filterSql("docNo");
            Query docNoFacetQuery = em.createNativeQuery("""
                    SELECT visible_doc_no, COUNT(*)
                    FROM %s
                    WHERE %s
                    GROUP BY visible_doc_no
                    ORDER BY visible_doc_no NULLS LAST
                    """.formatted(sourceView, filters + docNoFilter));
            bind(docNoFacetQuery, department, normalizedStatus, normalizedKeyword, normalizedException, dateFrom, dateTo);
            bindScope.accept(docNoFacetQuery);
            if (table != null) {
                // 只绑定进得了 SQL 的参数：docNo 被排除在桶谓词外，绑了会撞
                // Hibernate「未出现的命名参数」校验。
                table.filters().forEach((key, value) -> {
                    if (!"docNo".equals(key)
                            && !FulfillmentWorkbenchTableQuery.NULL_VALUE.equals(value)) {
                        docNoFacetQuery.setParameter("f_" + key, value);
                    }
                });
            }
            for (Object[] row : NativeQueryResults.objectArrayRows(docNoFacetQuery)) {
                long count = ((Number) row[1]).longValue();
                if (row[0] == null) {
                    nullCounts.put("docNo", count);
                } else {
                    facets.computeIfAbsent("docNo", ignored -> new java.util.ArrayList<>()).add(
                            new FulfillmentWorkbenchPage.Facet(row[0].toString(), row[0].toString(), count));
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
     * <p>委外缺 BOM 的申请(ADR-143 §二.3, 列表状态 {@code BOM_MISSING}「缺 BOM·已通知研发」)
     * 照样列在「待处理」段, 但球在研发手上(研发任务中心已计红一次), 不计入红数: 与列表同一判据,
     * 按 (单据, 状态) 归组, 组内任一申请明细的货品没有可发外直属物料({@code fn_subcontract_draw_edges})
     * 即整组不计。
     *
     * <p>口径依据 docs/00-项目准则/14-徽章与计数口径.md。
     */
    @Transactional(readOnly = true)
    public long countPending(String department) {
        return countPending(department, WarehouseTaskScope.ALL);
    }

    /** 同上; 仓库待领另按仓库数据范围(ADR-149)计数, 与列表同一谓词(发料仓); 采购/委外忽略范围。 */
    @Transactional(readOnly = true)
    public long countPending(String department, WarehouseTaskScope warehouseScope) {
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
        // 委外「可领料」的订货明细不在这里数: 它们是「领料」分段的红数, 由委外领料模块的
        // subcontractDraw.drawable 计数来源单独登记(ADR-143 §4.1), 这里再数就是同一件活计两次。
        // ADR-098：委外还要数「回厂短交待判定」的订货单(财务已通过但有待判定案件), 与列表异常行同源。
        String shortDelivery = " OR (decomposition.task_status = 'FINANCE_APPROVED'"
                + " AND decomposition.action_doc_type = 'SUBCONTRACT_ORDER' AND "
                + SHORT_DELIVERY_PENDING_EXISTS.formatted("decomposition.action_doc_id") + ")";
        Query query = em.createNativeQuery("SUBCONTRACT".equals(department)
                ? """
                    SELECT COUNT(*) FROM (
                        SELECT DISTINCT counted.action_doc_id
                        FROM (
                            SELECT decomposition.action_doc_id, decomposition.open_qty,
                                   bool_or(decomposition.action_doc_type = 'SUBCONTRACT_APPLICATION'
                                           AND decomposition.task_status = 'WAITING_ORDER'
                                           AND EXISTS (
                                               SELECT 1 FROM subcontract_application_items gap_item
                                               WHERE gap_item.id = decomposition.action_item_id
                                                 AND gap_item.is_deleted = FALSE
                                                 AND NOT EXISTS (SELECT 1 FROM fn_subcontract_draw_edges(gap_item.goods_id))))
                                       OVER (PARTITION BY decomposition.action_doc_type, decomposition.action_doc_id,
                                                          decomposition.task_status) AS bom_missing
                            FROM v_procurement_decomposition_tasks decomposition
                            WHERE decomposition.department = :department
                              AND (decomposition.task_status IN ('WAITING_ORDER', 'FINANCE_REJECTED')%s)
                        ) counted
                        WHERE counted.open_qty > 0 AND NOT counted.bom_missing
                    ) documents
                    """.formatted(shortDelivery)
                : decomposition
                ? """
                    SELECT COUNT(*) FROM (
                        SELECT DISTINCT decomposition.action_doc_id
                        FROM v_procurement_decomposition_tasks decomposition
                        WHERE decomposition.department = :department AND decomposition.open_qty > 0
                          AND decomposition.task_status IN ('WAITING_ORDER', 'FINANCE_REJECTED')
                    ) documents
                    """
                : """
                    SELECT COUNT(*) FROM %s documents
                    WHERE department = :department AND open_line_count > 0%s
                    """.formatted(WAREHOUSE_DOCUMENT_ROWS, warehouseScoped(department, warehouseScope)
                        ? " AND " + warehouseScope.predicate("warehouse_id", ":warehouse_scope") : ""));
        query.setParameter("department", department);
        if (warehouseScoped(department, warehouseScope)) query.setParameter("warehouse_scope", warehouseScope.idsCsv());
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

    /** 仓库待领任务的「所在仓」= 领料单发料仓(列 warehouse_id); 只有仓库部门的任务按仓库数据范围过滤。 */
    private static boolean warehouseScoped(String department, WarehouseTaskScope warehouseScope) {
        return "WAREHOUSE".equals(department) && warehouseScope != null && warehouseScope.active();
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
        return warehouseStatusBreakdown(WarehouseTaskScope.ALL);
    }

    /** 同上, 按仓库数据范围(ADR-149)计数, 与列表同一范围。 */
    @Transactional(readOnly = true)
    public Map<String, Long> warehouseStatusBreakdown(WarehouseTaskScope warehouseScope) {
        if (!accessPolicy.canAccessWarehouseTasks()) {
            return Map.of("READY_TO_PICK", 0L, "PARTIAL", 0L, "OPEN_ANY", 0L);
        }
        boolean scoped = warehouseScope != null && warehouseScope.active();
        Query query = em.createNativeQuery("""
                SELECT task_status, COUNT(*)
                FROM %s document_rows
                WHERE task_status IN ('READY_TO_PICK', 'PARTIAL', 'MATERIALS_TO_DEFINE')%s
                GROUP BY task_status
                """.formatted(WAREHOUSE_DOCUMENT_ROWS, scoped
                        ? " AND " + warehouseScope.predicate("warehouse_id", ":warehouse_scope") : ""));
        if (scoped) query.setParameter("warehouse_scope", warehouseScope.idsCsv());
        long ready = 0;
        long partial = 0;
        long discovery = 0;
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) {
            String status = String.valueOf(row[0]);
            long count = ((Number) row[1]).longValue();
            if ("READY_TO_PICK".equals(status)) ready = count;
            else if ("PARTIAL".equals(status)) partial = count;
            else if ("MATERIALS_TO_DEFINE".equals(status)) discovery = count;
        }
        return Map.of(
                "READY_TO_PICK", ready,
                "PARTIAL", partial,
                "MATERIALS_TO_DEFINE", discovery,
                "OPEN_ANY", ready + partial + discovery);
    }

    /**
     * 列表行的服务端派生列: 委外取最早来源行动时间与执行状态列(display_stage), 采购/委外改写
     * 异常小类, 仓库取来源生产产品与领料申请号。状态列的表头筛选/排序都走 display_stage。
     */
    private String enrichTableRows(String source, String department) {
        boolean subcontract = "SUBCONTRACT".equals(department);
        boolean purchase = "PURCHASE".equals(department);
        boolean canCreate = subcontract ? accessPolicy.canCreateSubcontractOrder()
                : purchase && accessPolicy.canCreatePurchaseOrder();
        String requestType = subcontract ? "SUBCONTRACT_APPLICATION" : "PURCHASE_REQUEST";
        List<String> types = "WAREHOUSE".equals(department) ? List.of("DRAW", "MATERIAL_DISCOVERY")
                : subcontract ? List.of("SUBCONTRACT_APPLICATION", "SUBCONTRACT_ORDER")
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
                    )
                    SELECT MIN(action.created_at) AS issued_at
                    FROM source_items source
                    JOIN preplan_supply_action_allocations allocation
                      ON allocation.external_item_id=source.application_item_id
                    JOIN preplan_supply_actions action ON action.id=allocation.action_id
                      AND action.external_document_type='SUBCONTRACT_APPLICATION' AND action.route='SUBCONTRACT'
                ) issue ON TRUE
                """ : "";
        // ADR-143 §4.1「进行中」状态列: 已批准的委外订货单按各明细聚合, 取第一个命中——
        // 回厂短交待判定 > 分批等待中 > 容差内待结案 > 已回厂待入库(回厂净量已到齐, 只差质检入库)
        // > 可领料 > 已提交领料·待仓库发料 > 部分回厂 > 委外加工中(有已发料) > 等待物料。
        // 已批准的订货单一定有冻结领料计划行(缺 BOM 的委外件不能下单, ADR-143 §二.3)。
        // 可领料逐明细按 fn_subcontract_draw_summary 判(领料计划开着、明细还有开着的领料行、可领 > 0),
        // 从不把不同物料的数量相加; 只对财务已通过的订货单才去算。
        // 财务已退回与短交待判定同时写进 exception_code, 让异常小类行挂红徽章。
        String progressJoin = subcontract ? """
                LEFT JOIN LATERAL (
                    SELECT %s AS short_pending,
                           %s AS tolerant_pending,
                           EXISTS (SELECT 1 FROM subcontract_short_delivery_cases waiting_case
                                   WHERE waiting_case.order_id = base.action_doc_id
                                     AND waiting_case.status = 'WAITING_MORE'
                                     AND waiting_case.severity <> 'WITHIN_TOLERANCE'
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
                                             + %s
                                             < COALESCE(pending_item.qty, 0)) AS all_received,
                           EXISTS (SELECT 1 FROM subcontract_order_items draw_item
                                   CROSS JOIN LATERAL fn_subcontract_draw_summary(draw_item.id) draw_summary
                                   WHERE base.task_status = 'FINANCE_APPROVED'
                                     AND draw_item.order_id = base.action_doc_id
                                     AND NOT draw_item.is_deleted
                                     AND draw_summary.drawable_qty > 0
                                     AND GREATEST(COALESCE(draw_item.received_qty, 0)
                                                  - COALESCE(draw_item.returned_qty, 0), 0)
                                         + %s < draw_item.qty
                                     AND EXISTS (SELECT 1 FROM subcontract_material_plans draw_plan
                                                 JOIN subcontract_material_plan_items open_line
                                                   ON open_line.plan_id = draw_plan.id
                                                  AND open_line.order_item_id = draw_item.id
                                                  AND NOT open_line.is_deleted
                                                  AND open_line.draw_closed_at IS NULL
                                                  AND open_line.issued_qty < fn_subcontract_draw_needed_qty(
                                                      open_line.order_item_id, open_line.planned_qty,
                                                      open_line.bom_unit_qty)
                                                 WHERE draw_plan.order_id = base.action_doc_id
                                                   AND draw_plan.status = 'OPEN'
                                                   AND NOT draw_plan.is_deleted)) AS any_drawable,
                           EXISTS (SELECT 1 FROM subcontract_material_issue_items draft_item
                                   JOIN subcontract_material_issues draft_doc
                                     ON draft_doc.id = draft_item.issue_id
                                    AND draft_doc.status = 0 AND NOT draft_doc.is_deleted
                                   JOIN subcontract_order_items draft_order_item
                                     ON draft_order_item.id = draft_item.order_item_id
                                   WHERE draft_order_item.order_id = base.action_doc_id
                                     AND draft_item.plan_item_id IS NOT NULL
                                     AND NOT draft_item.is_deleted) AS any_draw_submitted,
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
                        SubcontractLossSettlementSql.acceptedLossQty("pending_item.id"),
                        SubcontractLossSettlementSql.acceptedLossQty("draw_item.id")) : "";
        // ADR-100：采购侧的执行状态就是 task_status 本身(等待财务审核 / 财务已通过 /
        // 财务已退回三档), 下面的 ELSE 分支已经把它落进 display_stage —— 采购与委外因此
        // 共用同一列做状态列、表头筛选与排序, 采购不另算一遍。
        String stageExpression = subcontract ? """
                CASE WHEN base.action_doc_type='SUBCONTRACT_ORDER' AND base.task_status='FINANCE_APPROVED' THEN
                          CASE WHEN progress.short_pending THEN 'SHORT_DELIVERY'
                               WHEN progress.waiting_more THEN 'WAITING_MORE_BATCH'
                               WHEN progress.tolerant_pending THEN 'TOLERANT_SHORT'
                               WHEN progress.any_received AND progress.all_received THEN 'RECEIVED_PENDING_STOCK'
                               WHEN progress.any_drawable THEN 'DRAWABLE'
                               WHEN progress.any_draw_submitted THEN 'DRAW_SUBMITTED'
                               WHEN progress.any_received THEN 'PARTIAL_RECEIVED'
                               WHEN progress.any_issued THEN 'AT_SUPPLIER'
                               ELSE 'WAITING_MATERIAL' END
                     WHEN base.action_doc_type='SUBCONTRACT_APPLICATION' AND bom_gap.bom_missing THEN 'BOM_MISSING'
                     WHEN kit.open_qty > 0 AND kit.orderable_lines = 0 THEN 'WAITING_KIT'
                     WHEN kit.open_qty > 0 AND kit.orderable_qty < kit.open_qty THEN 'KIT_PARTIAL'
                     ELSE base.task_status END""" : "base.task_status";
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
        String productionProductJoin = "WAREHOUSE".equals(department) ? """
                LEFT JOIN LATERAL (
                    SELECT STRING_AGG(DISTINCT goods.code,'、' ORDER BY goods.code) AS product_code,
                           STRING_AGG(DISTINCT goods.name,'、' ORDER BY goods.name) AS product_name,
                           STRING_AGG(DISTINCT source.request_no,'、' ORDER BY source.request_no) AS request_no,
                           STRING_AGG(DISTINCT segment.segment_code,'、' ORDER BY segment.segment_code) AS segment_codes
                    FROM (
                        SELECT discovery.execution_segment_id AS id,discovery.request_no
                        FROM production_material_discovery_requests discovery
                        WHERE base.action_doc_type='MATERIAL_DISCOVERY' AND discovery.id=base.action_doc_id
                        UNION
                        SELECT mapping.execution_segment_id,discovery.request_no
                        FROM production_planning_package_documents mapping
                        LEFT JOIN production_material_discovery_requests discovery
                          ON discovery.execution_segment_id=mapping.execution_segment_id AND discovery.status='CONFIGURED'
                         AND EXISTS(SELECT 1 FROM production_material_discovery_lines discovered
                           JOIN production_planning_package_document_items item_mapping ON item_mapping.demand_id=discovered.demand_id
                            AND item_mapping.document_type='DRAW' AND item_mapping.document_id=mapping.document_id
                           WHERE discovered.request_id=discovery.id)
                        WHERE base.action_doc_type='DRAW' AND mapping.document_type='DRAW'
                          AND mapping.document_id=base.action_doc_id
                    ) source
                    JOIN production_execution_segments segment ON segment.id=source.id
                    JOIN goods ON goods.id=segment.product_goods_id
                ) production_product ON TRUE
                """ : "";
        // ADR-156：待分解委外申请逐明细「这次能下单」= MIN(剩余未下单, 现有物料够做的套数)(库里唯一一处计算
        // fn_subcontract_application_kit_qty)。一条都不能下 = WAITING_KIT 锁住(照样留在「待处理」计红数, 只是
        // 不能勾选、不能生成订货单); 能下一部分 = KIT_PARTIAL。
        // ADR-143 §二.3：待分解的委外申请里缺 BOM(没有可发外直属物料)的明细。这张申请不能生成订货单,
        // 状态列显示「缺 BOM·已通知研发」并带上研发任务编号; 没有未完成研发任务时页面按 bom_missing_item_ids
        // 逐条「通知研发完善」(POST /api/subcontract/applications/items/{id}/forward-bom)。
        String bomGapJoin = subcontract ? """
                LEFT JOIN LATERAL (
                    SELECT COUNT(*) > 0 AS bom_missing,
                           STRING_AGG(DISTINCT open_task.task_no, '、' ORDER BY open_task.task_no) AS rd_task_no,
                           ARRAY_AGG(DISTINCT gap_item.id::text ORDER BY gap_item.id::text) AS item_ids
                    FROM unnest(base.action_item_ids) gap_ref(item_id)
                    JOIN subcontract_application_items gap_item
                      ON gap_item.id = gap_ref.item_id::uuid AND gap_item.is_deleted = FALSE
                    LEFT JOIN rd_tasks open_task
                      ON open_task.goods_id = gap_item.goods_id AND open_task.category = 'BOM'
                     AND open_task.status IN ('OPEN', 'IN_PROGRESS') AND open_task.is_deleted = FALSE
                    WHERE base.action_doc_type = 'SUBCONTRACT_APPLICATION'
                      AND base.task_status = 'WAITING_ORDER'
                      AND NOT EXISTS (SELECT 1 FROM fn_subcontract_draw_edges(gap_item.goods_id))
                ) bom_gap ON TRUE
                LEFT JOIN LATERAL (
                    SELECT COUNT(*) FILTER (WHERE kit_line.orderable > 0) AS orderable_lines,
                           COALESCE(SUM(kit_line.orderable), 0) AS orderable_qty,
                           COALESCE(SUM(kit_line.open_qty), 0) AS open_qty
                    FROM unnest(base.action_item_ids) kit_ref(item_id)
                    CROSS JOIN LATERAL (
                        SELECT fn_subcontract_application_open_qty(kit_ref.item_id::uuid) AS open_qty
                    ) kit_open
                    CROSS JOIN LATERAL (
                        SELECT kit_open.open_qty,
                               CASE WHEN kit_open.open_qty > 0
                                    THEN LEAST(kit_open.open_qty,
                                               fn_subcontract_application_kit_qty(kit_ref.item_id::uuid, NULL))
                                    ELSE 0 END AS orderable
                    ) kit_line
                    WHERE base.action_doc_type = 'SUBCONTRACT_APPLICATION'
                      AND base.task_status = 'WAITING_ORDER'
                      AND NOT COALESCE(bom_gap.bom_missing, FALSE)
                ) kit ON TRUE
                """ : "";
        // A grouped order can contain several real source issues. Its earliest source issue
        // remains the displayed date; later application creation never substitutes for it.
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
                        (base.action_doc_type IS DISTINCT FROM 'MATERIAL_DISCOVERY' OR base.goods_count>0) AS materials_defined,
                        %s AS production_product_code, %s AS production_product_name, %s AS material_request_no,
                        %s AS execution_segment_codes,
                        base.workshop_name, base.worker_name, base.draw_batch_no, base.lines,
                        %s AS rd_task_no, %s AS bom_missing_item_ids,
                        %s AS orderable_qty
                 FROM %s base %s %s %s %s)
                """.formatted(exceptionExpression, subcontract ? "issue.issued_at" : "NULL::timestamptz",
                        canCreate ? "TRUE" : "FALSE", requestType,
                        subcontract ? " AND NOT COALESCE(bom_gap.bom_missing, FALSE)"
                                + " AND COALESCE(kit.orderable_lines, 0) > 0" : "",
                        visibleDoc, stageExpression,
                        "WAREHOUSE".equals(department) ? "production_product.product_code" : "NULL::text",
                        "WAREHOUSE".equals(department) ? "production_product.product_name" : "NULL::text",
                        "WAREHOUSE".equals(department) ? "production_product.request_no" : "NULL::text",
                        "WAREHOUSE".equals(department) ? "production_product.segment_codes" : "NULL::text",
                        subcontract ? "bom_gap.rd_task_no" : "NULL::text",
                        subcontract ? "COALESCE(bom_gap.item_ids, ARRAY[]::text[])" : "ARRAY[]::text[]",
                        subcontract ? "kit.orderable_qty" : "NULL::numeric",
                        source, issueJoin, progressJoin, bomGapJoin, productionProductJoin);
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
                List.of(), row.length <= 37 || Boolean.TRUE.equals(row[37]),
                row.length > 38 ? (String) row[38] : null,
                row.length > 39 ? (String) row[39] : null,
                row.length > 40 ? (String) row[40] : null,
                row.length > 41 ? (String) row[41] : null,
                row.length > 42 ? (String) row[42] : null,
                row.length > 43 ? (String) row[43] : null,
                row.length > 44 ? parseLines(row[44]) : List.of(),
                row.length > 45 ? (String) row[45] : null,
                row.length > 46 ? stringArray(row[46]) : List.of(),
                row.length > 47 && row[47] != null ? decimal(row[47]) : null);
    }

    private static final com.fasterxml.jackson.databind.ObjectMapper LINES_MAPPER =
            new com.fasterxml.jackson.databind.ObjectMapper();

    /** jsonb 明细数组 → List<Map>（行级货品明细；空/异常回空表，不让显示粒度拖垮列表）。 */
    @SuppressWarnings("unchecked")
    static List<java.util.Map<String, Object>> parseLines(Object value) {
        if (value == null) return List.of();
        try {
            String json = value.toString();
            if (json.isBlank()) return List.of();
            return LINES_MAPPER.readValue(json, List.class);
        } catch (Exception ignored) {
            return List.of();
        }
    }

    /** Only the visible application IDs on this page are expanded, in one bounded query. */
    private List<FulfillmentTaskRow> enrichApplicationSources(List<FulfillmentTaskRow> items) {
        List<UUID> applicationIds = items.stream()
                .filter(row -> row.actionDocCanView() && !row.actionDocRestricted())
                .filter(row -> "SUBCONTRACT_APPLICATION".equals(row.actionDocType()))
                .map(FulfillmentTaskRow::actionDocId).filter(java.util.Objects::nonNull).distinct().toList();
        if (applicationIds.isEmpty()) return items;
        Query query = em.createNativeQuery("""
                WITH visible_items AS (
                    SELECT item.id, item.application_id
                    FROM subcontract_application_items item
                    WHERE item.application_id IN (:applicationIds) AND NOT item.is_deleted
                ), source_rows AS (
                    SELECT item.application_id, origin.id AS origin_id, origin.source_type,
                           COALESCE(sale.bill_no, origin.source_ref, '') AS source_no,
                           sale.line_no, product.code AS product_code, product.name AS product_name,
                           material_goods.code AS material_code, material_goods.name AS material_name,
                           allocation.allocated_qty AS quantity, unit.name AS unit_name
                    FROM visible_items item
                    JOIN preplan_supply_action_allocations allocation ON allocation.external_item_id = item.id
                    JOIN preplan_supply_actions action ON action.id = allocation.action_id
                     AND action.status <> 'CANCELLED' AND action.route = 'SUBCONTRACT'
                    JOIN production_material_analysis_materials material ON material.id = allocation.analysis_material_id
                     AND material.analysis_id = allocation.analysis_id
                    JOIN production_material_analysis_items origin ON origin.id = material.analysis_item_id
                     AND origin.analysis_id = material.analysis_id
                    JOIN goods product ON product.id = origin.goods_id
                    JOIN goods material_goods ON material_goods.id = action.goods_id
                    LEFT JOIN sales_order_items sale ON sale.id = origin.sales_order_item_id
                    LEFT JOIN units unit ON unit.id = action.unit_id
                    UNION ALL
                    SELECT item.application_id, NULL::uuid, 'PUBLIC_STOCK', '', NULL::integer, '', '',
                           material_goods.code, material_goods.name, action.public_surplus_qty, unit.name
                    FROM visible_items item
                    JOIN preplan_supply_actions action ON action.public_surplus_external_item_id = item.id
                     AND action.status <> 'CANCELLED' AND action.route = 'SUBCONTRACT'
                     AND action.public_surplus_qty > 0
                    JOIN goods material_goods ON material_goods.id = action.goods_id
                    LEFT JOIN units unit ON unit.id = action.unit_id
                )
                SELECT application_id, origin_id, source_type, source_no, line_no,
                       product_code, product_name, material_code, material_name, SUM(quantity), unit_name
                FROM source_rows
                GROUP BY application_id, origin_id, source_type, source_no, line_no,
                         product_code, product_name, material_code, material_name, unit_name
                ORDER BY application_id, product_code, source_no, line_no, material_code
                """);
        query.setParameter("applicationIds", applicationIds);
        Map<UUID, List<SubcontractTaskSource>> sources = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) {
            sources.computeIfAbsent((UUID) row[0], ignored -> new java.util.ArrayList<>())
                    .add(new SubcontractTaskSource((UUID) row[1], (String) row[2], (String) row[3],
                            row[4] == null ? null : ((Number) row[4]).intValue(),
                            (String) row[5], (String) row[6], (String) row[7], (String) row[8],
                            decimal(row[9]), (String) row[10]));
        }
        return items.stream().map(row -> row.withSources(
                sources.getOrDefault(row.actionDocId(), List.of()))).toList();
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
                restricted ? List.of() : row.sources(), row.materialsDefined(),
                row.productionProductCode(), row.productionProductName(), restricted ? null : row.materialRequestNo(),
                row.workshopName(), row.workerName(), row.drawBatchNo(), row.lines(),
                row.rdTaskNo(), restricted ? List.of() : row.bomMissingItemIds(),
                restricted ? null : row.orderableQty());
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
