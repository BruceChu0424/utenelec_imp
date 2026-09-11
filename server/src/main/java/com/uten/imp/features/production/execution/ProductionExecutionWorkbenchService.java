package com.uten.imp.features.production.execution;

import com.uten.imp.application.port.SubcontractDocumentReadAccessPort;
import com.uten.imp.application.port.ProductionMaterialUsageReadPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;

/** Query service for the planning-root and exact workshop-task projections. */
@Service
@RequiredArgsConstructor
public class ProductionExecutionWorkbenchService {

    private final EntityManager em;
    private final ProductionDocumentAccessPolicy productionAccess;
    private final PurchaseDocumentAccessPolicy purchaseAccess;
    private final SubcontractDocumentReadAccessPort subcontractAccess;
    private final SecurityContextCurrentUser currentUser;
    private final ProductionMaterialUsageReadPort materialUsage;
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.features.production.SubcontractDraftPreparationAccessPolicy draftPreparationAccess;

    private String rootVisibility(String normal){
        return draftPreparationAccess.inPlanningPool()?"("+normal+" OR (root.root_type='ANALYSIS' AND "+draftPreparationAccess.sourcePredicate("root.root_id")+"))":normal;
    }

    @Transactional(readOnly = true)
    public PageResponse<ProductionExecutionWorkbenchGroup> list(
            int requestedPage,
            int requestedSize,
            String keyword,
            UUID workshopDepartmentId,
            boolean mine,
            String sort,
            String order) {
        int size = boundedSize(requestedSize);
        int page = Math.max(requestedPage, 1);
        NativeReadScope scope = productionAccess.nativeReadScope(
                "root.owner_employee_id", "rootOwners");
        UUID employeeId = currentUser.employeeId().orElse(null);
        boolean canSearchClient =
                productionAccess.hasAuthority("sales_order:view");
        String filters = rootFilters(
                keyword, workshopDepartmentId, mine, employeeId,
                canSearchClient);
        String from = " FROM v_production_execution_workbench_roots root WHERE ("
                + rootVisibility(scope.predicate()) + ") " + filters;
        Query count = em.createNativeQuery("SELECT COUNT(*)" + from);
        scope.bind(count);
        bindRootFilters(count, keyword, workshopDepartmentId, mine, employeeId);
        long total = ((Number) count.getSingleResult()).longValue();
        int totalPages = pages(total, size);
        if (totalPages > 0 && page > totalPages) page = totalPages;

        Query data = em.createNativeQuery(rootSelect() + from
                + " ORDER BY " + rootOrderBy(sort, order) + """
                         , root.root_id ASC
                LIMIT :limit OFFSET :offset
                """);
        scope.bind(data);
        bindRootFilters(data, keyword, workshopDepartmentId, mine, employeeId);
        data.setParameter("limit", size);
        data.setParameter("offset", (long) (page - 1) * size);
        List<ProductionExecutionWorkbenchGroup> items =
                NativeQueryResults.objectArrayRows(data).stream()
                        .map(ProductionExecutionWorkbenchService::groupRow)
                        .toList();
        return new PageResponse<>(items, page, size, total, totalPages);
    }

    @Transactional(readOnly = true)
    public ProductionExecutionWorkbenchGroup group(
            String rawRootType, UUID rootId) {
        String rootType = rootType(rawRootType);
        NativeReadScope scope = productionAccess.nativeReadScope(
                "root.owner_employee_id", "rootOwners");
        Query query = em.createNativeQuery(rootSelect() + """
                FROM v_production_execution_workbench_roots root
                WHERE root.root_type = :rootType
                  AND root.root_id = :rootId
                  AND (%s)
                """.formatted(rootVisibility(scope.predicate())));
        query.setParameter("rootType", rootType);
        query.setParameter("rootId", rootId);
        scope.bind(query);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(query);
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "生产任务批次不存在");
        }
        return groupRow(rows.getFirst());
    }

    @Transactional(readOnly = true)
    public PageResponse<ProductionExecutionWorkbenchSegment> workOrders(
            String rawRootType,
            UUID rootId,
            int requestedPage,
            int requestedSize) {
        String rootType = rootType(rawRootType);
        group(rootType, rootId);
        return segmentPage(
                "task.root_type = :rootType AND task.root_id = :rootId",
                query -> {
                    query.setParameter("rootType", rootType);
                    query.setParameter("rootId", rootId);
                },
                requestedPage,
                requestedSize);
    }

    @Transactional(readOnly = true)
    public PageResponse<ProductionExecutionWorkbenchSegment> workshopTasks(
            int requestedPage,
            int requestedSize,
            String keyword,
            String rawStatus,
            UUID workshopDepartmentId,
            LocalDate dateFrom,
            LocalDate dateTo) {
        UUID employeeId = currentUser.employeeId().orElse(null);
        // V477 读侧放行：超管在本页看全部车间任务（前端徽章本就放行超管，
        // 两端口径必须一致）；写侧（报工）仍要求车间归属——FullChainEndToEndTest
        // 锁定的「超管不豁免车间范围」是写侧口径，不受影响。2026-09-06 起支持
        // 按车间筛选（超管看多车间时收敛视角；普通员工仍受本人范围约束）。
        boolean seeAll = currentUser.get().map(AuthUser::isSuperAdmin).orElse(false);
        if (employeeId == null && !seeAll) {
            int size = boundedSize(requestedSize);
            return new PageResponse<>(List.of(), 1, size, 0, 0);
        }
        String status = normalizeTaskStatus(rawStatus);
        // 「历史任务」= 终态段（已完工 / 已取消 / 已红冲），ADR-066 §1.3 时间门控：
        // 只在显式筛选时返回，并按计划完工日期 dateFrom/dateTo 收窄（视图没有
        // 完工时间戳列，退回 plan_end_date；CAST 判空口径与全站一致）。默认列表
        // 与徽章仍只看四个活动状态（终态不挂徽章——与全站计数口径一致）。
        boolean history = "COMPLETED".equals(status);
        String statuses = history
                ? "('COMPLETED','CANCELLED','REVERSED')"
                : "('WAITING','READY','DISPATCHED','IN_PROGRESS')";
        String predicate = (seeAll ? "1=1" : assignmentPredicate("task"))
                + " AND task.segment_status IN " + statuses;
        if (history) {
            predicate += " AND (CAST(:dateFrom AS date) IS NULL"
                    + " OR task.plan_end_date >= CAST(:dateFrom AS date))"
                    + " AND (CAST(:dateTo AS date) IS NULL"
                    + " OR task.plan_end_date <= CAST(:dateTo AS date))";
        }
        if (workshopDepartmentId != null) {
            predicate += " AND task.workshop_department_id = :workshopId";
        }
        if (keyword != null && !keyword.isBlank()) {
            predicate += """
                    AND (
                        lower(COALESCE(task.plan_no, '')) LIKE :keyword
                        OR lower(COALESCE(task.segment_code, '')) LIKE :keyword
                        OR lower(COALESCE(task.sales_order_nos, '')) LIKE :keyword
                        OR lower(COALESCE(task.product_code, '')) LIKE :keyword
                        OR lower(COALESCE(task.product_name, '')) LIKE :keyword
                        OR lower(COALESCE(task.product_color_name, '')) LIKE :keyword
                        OR lower(COALESCE(task.workshop_name, '')) LIKE :keyword
                    )
                    """;
        }
        if (status != null) {
            predicate += switch (status) {
                // 2026-09-06 车间任务页改版：「等待物料」= 全部未开工段
                //（WAITING 等料 + READY/DISPATCHED 物料齐套·可开工）；
                //「可报工」兼容状态参数 2026-09-10 退役（无客户端调用方，且与分段计数口径矛盾）
                //（无客户端调用方；它与分段计数第三列口径本就互相矛盾）。
                case "PREPARING" ->
                    " AND task.segment_status <> 'IN_PROGRESS'";
                case "READY_TO_START" ->
                    " AND task.segment_status IN ('READY', 'DISPATCHED')"
                    + " AND (task.issued OR task.zero_material)";
                case "IN_PROGRESS" -> " AND task.segment_status = 'IN_PROGRESS'";
                default -> "";
            };
        }
        String finalPredicate = predicate;
        UUID scopedEmployeeId = seeAll ? null : employeeId;
        return segmentPage(
                finalPredicate,
                query -> {
                    if (scopedEmployeeId != null) {
                        query.setParameter("employeeId", scopedEmployeeId);
                    }
                    if (workshopDepartmentId != null) {
                        query.setParameter("workshopId", workshopDepartmentId);
                    }
                    if (keyword != null && !keyword.isBlank()) {
                        query.setParameter(
                                "keyword",
                                "%" + keyword.strip().toLowerCase(Locale.ROOT) + "%");
                    }
                    if (history) {
                        query.setParameter("dateFrom", dateFrom);
                        query.setParameter("dateTo", dateTo);
                    }
                },
                requestedPage,
                requestedSize);
    }

    @Transactional(readOnly = true)
    public long workshopTaskCount() {
        return workshopTaskCountBreakdown().total();
    }

    /** 顶部分类徽章与总数同源同范围：一次查询同时给出各状态计数。 */
    @Transactional(readOnly = true)
    public WorkshopTaskCountBreakdown workshopTaskCountBreakdown() {
        UUID employeeId = currentUser.employeeId().orElse(null);
        boolean seeAll = currentUser.get().map(AuthUser::isSuperAdmin).orElse(false);
        if (employeeId == null && !seeAll) {
            return new WorkshopTaskCountBreakdown(0, 0, 0);
        }
        String predicate = seeAll ? "TRUE" : assignmentPredicate("task");
        Query query = em.createNativeQuery("""
                        SELECT COUNT(*),
                               COUNT(*) FILTER (
                                   WHERE task.segment_status <> 'IN_PROGRESS'),
                               COUNT(*) FILTER (
                                   WHERE task.segment_status = 'IN_PROGRESS')
                        FROM v_production_execution_workbench_segments task
                        WHERE task.segment_status IN (
                            'WAITING','READY','DISPATCHED','IN_PROGRESS')
                          AND (%s)
                        """.formatted(predicate));
        if (!seeAll) {
            query.setParameter("employeeId", employeeId);
        }
        Object[] row = NativeQueryResults.objectArrayRows(query).getFirst();
        return new WorkshopTaskCountBreakdown(
                ((Number) row[0]).longValue(),
                ((Number) row[1]).longValue(),
                ((Number) row[2]).longValue());
    }

    /** 车间任务分段计数（与列表筛选口径一一对应：等待物料 + 生产中 = 总数）。 */
    public record WorkshopTaskCountBreakdown(
            long total, long preparing, long inProgress) {
    }

    private PageResponse<ProductionExecutionWorkbenchSegment> segmentPage(
            String predicate,
            java.util.function.Consumer<Query> binder,
            int requestedPage,
            int requestedSize) {
        int size = boundedSize(requestedSize);
        int page = Math.max(requestedPage, 1);
        String from = " FROM v_production_execution_workbench_segments task WHERE "
                + predicate;
        Query count = em.createNativeQuery("SELECT COUNT(*)" + from);
        binder.accept(count);
        long total = ((Number) count.getSingleResult()).longValue();
        int totalPages = pages(total, size);
        if (totalPages > 0 && page > totalPages) page = totalPages;
        Query data = em.createNativeQuery(segmentSelect() + from + "\n" + """
                ORDER BY task.plan_end_date ASC NULLS LAST,
                         task.plan_no ASC,
                         task.segment_no ASC,
                         task.segment_id ASC
                LIMIT :limit OFFSET :offset
                """);
        binder.accept(data);
        boolean allowReport = reportAllowed(
                productionAccess.hasAuthority("production_daily_report:view"),
                productionAccess.hasAuthority("production_daily_report:create"),
                productionAccess.hasAuthority("production_execution:view"));
        data.setParameter("allowReport", allowReport);
        data.setParameter("limit", size);
        data.setParameter("offset", (long) (page - 1) * size);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(data);
        var usage = materialUsage.forVisibleSegments(rows.stream().map(row -> uuid(row[0])).toList());
        List<ProductionExecutionWorkbenchSegment> items = rows.stream()
                        .map(row -> segmentRow(row, usage.getOrDefault(uuid(row[0]), ProductionMaterialUsageReadPort.UsageFlags.NONE)))
                        .toList();
        return new PageResponse<>(items, page, size, total, totalPages);
    }

    @Transactional(readOnly = true)
    public PageResponse<ProductionExecutionWorkbenchRelatedDocument> relatedDocuments(
            String rawRootType,
            UUID rootId,
            int requestedPage,
            int requestedSize) {
        String rootType = rootType(rawRootType);
        group(rootType, rootId);
        int size = boundedSize(requestedSize);
        int page = Math.max(requestedPage, 1);
        List<String> branches = new ArrayList<>();
        List<ScopeBinding> bindings = new ArrayList<>();

        if ("ANALYSIS".equals(rootType)) {
            if (purchaseAccess.hasAuthority("purchase_request:view")) {
                NativeReadScope scope = purchaseAccess.nativeReadScope(
                        "document.maker_id", "purchaseRequestOwners");
                branches.add("""
                        SELECT 'BUY' AS route, 'PURCHASE_REQUEST' AS document_type,
                               document.id AS document_id,
                               document.bill_no AS document_no,
                               document.status::text AS status
                        FROM preplan_supply_actions action
                        JOIN purchase_requests document
                          ON document.id = action.external_document_id
                         AND document.is_deleted = FALSE
                        WHERE action.analysis_id = :rootId
                          AND action.external_document_type = 'PURCHASE_REQUEST'
                          AND %s
                        """.formatted(scope.predicate()));
                bindings.add(new ScopeBinding(scope));
            }
            if (purchaseAccess.hasAuthority("purchase_order:view")) {
                NativeReadScope scope = purchaseAccess.nativeReadScope(
                        "document.maker_id", "purchaseOrderOwners");
                branches.add("""
                        SELECT 'BUY', 'PURCHASE_ORDER', document.id,
                               document.bill_no, document.status::text
                        FROM preplan_supply_actions action
                        JOIN preplan_supply_action_allocations allocation
                          ON allocation.action_id = action.id
                        JOIN purchase_order_item_sources source
                          ON source.request_item_id = allocation.external_item_id
                        JOIN purchase_order_items item
                          ON item.id = source.order_item_id
                         AND item.is_deleted = FALSE
                        JOIN purchase_orders document
                          ON document.id = item.order_id
                         AND document.is_deleted = FALSE
                        WHERE action.analysis_id = :rootId
                          AND action.route = 'BUY'
                          AND %s
                        """.formatted(scope.predicate()));
                bindings.add(new ScopeBinding(scope));
            }
            if (subcontractAccess.hasAuthority("subcontract_application:view")) {
                NativeReadScope scope = subcontractAccess.nativeReadScope(
                        "document.maker_id", "subcontractApplicationOwners");
                branches.add("""
                        SELECT 'SUBCONTRACT', 'SUBCONTRACT_APPLICATION',
                               document.id, document.bill_no, document.status::text
                        FROM preplan_supply_actions action
                        JOIN subcontract_applications document
                          ON document.id = action.external_document_id
                         AND document.is_deleted = FALSE
                        WHERE action.analysis_id = :rootId
                          AND action.external_document_type = 'SUBCONTRACT_APPLICATION'
                          AND %s
                        """.formatted(scope.predicate()));
                bindings.add(new ScopeBinding(scope));
            }
            if (subcontractAccess.hasAuthority("subcontract_order:view")) {
                NativeReadScope scope = subcontractAccess.nativeReadScope(
                        "document.maker_id", "subcontractOrderOwners");
                branches.add("""
                        SELECT 'SUBCONTRACT', 'SUBCONTRACT_ORDER', document.id,
                               document.bill_no, document.status::text
                        FROM preplan_supply_actions action
                        JOIN preplan_supply_action_allocations allocation
                          ON allocation.action_id = action.id
                        JOIN subcontract_order_item_sources source
                          ON source.application_item_id = allocation.external_item_id
                        JOIN subcontract_order_items item
                          ON item.id = source.order_item_id
                         AND item.is_deleted = FALSE
                        JOIN subcontract_orders document
                          ON document.id = item.order_id
                         AND document.is_deleted = FALSE
                        WHERE action.analysis_id = :rootId
                          AND action.route = 'SUBCONTRACT'
                          AND %s
                        """.formatted(scope.predicate()));
                bindings.add(new ScopeBinding(scope));
                branches.add("""
                        SELECT 'SUBCONTRACT', 'SUBCONTRACT_ORDER', document.id,document.bill_no,document.status::text
                        FROM production_material_analysis_items preparation
                        JOIN subcontract_order_items item ON item.id=preparation.subcontract_order_item_id AND item.is_deleted=FALSE
                        JOIN subcontract_orders document ON document.id=item.order_id AND document.is_deleted=FALSE
                        WHERE preparation.analysis_id=:rootId AND preparation.is_deleted=FALSE AND %s
                        """.formatted(scope.predicate()));
            }
        }
        if (productionAccess.hasAuthority("production_plan:view")) {
            NativeReadScope scope = productionAccess.nativeReadScope(
                    "document.maker_id", "relatedPlanOwners");
            // ANALYSIS 根：直接携带分析 id 的顶层计划之外，还要沿 subplan_links
            // 血缘下钻——EXECUTION_V1 自动生成的自制子计划不回填
            // material_analysis_id（该列语义=「直接由本分析创建」，1:1 锚点），
            // 但它们仍是本批次的子计划单，必须出现在关联单据里。
            String rootPredicate = "ANALYSIS".equals(rootType)
                    ? """
                      (document.material_analysis_id = :rootId
                       OR document.id IN (
                           WITH RECURSIVE analysis_root_plans(id) AS (
                               SELECT root.id
                               FROM production_plans root
                               WHERE root.material_analysis_id = :rootId
                                 AND root.is_deleted = FALSE
                           ), analysis_plan_tree(id) AS (
                               SELECT id FROM analysis_root_plans
                               UNION ALL
                               SELECT child.id
                               FROM analysis_plan_tree parent_plan
                               JOIN subplan_links link
                                 ON link.plan_id = parent_plan.id
                                AND link.is_deleted = FALSE
                               JOIN production_plans child
                                 ON child.id = link.subplan_id
                                AND child.is_deleted = FALSE
                           )
                           SELECT id FROM analysis_plan_tree))
                      """
                    : "task.root_type = 'PLAN' AND task.root_id = :rootId";
            branches.add("""
                    SELECT 'MAKE', 'PRODUCTION_PLAN', document.id,
                           document.bill_no, document.status::text
                    FROM production_plans document
                    %s
                    WHERE %s
                      AND document.is_deleted = FALSE
                      AND %s
                    """.formatted(
                    "ANALYSIS".equals(rootType)
                            ? ""
                            : "JOIN v_production_execution_workbench_segments task ON task.plan_id = document.id",
                    rootPredicate,
                    scope.predicate()));
            bindings.add(new ScopeBinding(scope));
        }
        if (branches.isEmpty()) {
            return new PageResponse<>(List.of(), 1, size, 0, 0);
        }
        String candidates = "SELECT DISTINCT * FROM ("
                + String.join(" UNION ALL ", branches)
                + ") candidate(route, document_type, document_id, document_no, status)";
        Query count = em.createNativeQuery("SELECT COUNT(*) FROM ("
                + candidates + ") visible_documents");
        count.setParameter("rootId", rootId);
        bindings.forEach(binding -> binding.scope().bind(count));
        long total = ((Number) count.getSingleResult()).longValue();
        int totalPages = pages(total, size);
        if (totalPages > 0 && page > totalPages) page = totalPages;
        Query data = em.createNativeQuery(candidates + "\n" + """
                ORDER BY document_type, document_no, document_id
                LIMIT :limit OFFSET :offset
                """);
        data.setParameter("rootId", rootId);
        bindings.forEach(binding -> binding.scope().bind(data));
        data.setParameter("limit", size);
        data.setParameter("offset", (long) (page - 1) * size);
        List<ProductionExecutionWorkbenchRelatedDocument> items =
                NativeQueryResults.objectArrayRows(data).stream()
                        .map(row -> new ProductionExecutionWorkbenchRelatedDocument(
                                text(row[0]), text(row[1]), uuid(row[2]),
                                text(row[3]), text(row[4]), true))
                        .toList();
        return new PageResponse<>(items, page, size, total, totalPages);
    }

    private static String rootSelect() {
        return """
                SELECT root.root_type, root.root_id, root.owner_employee_id,
                       root.root_label, root.status,
                       root.sales_order_preview, root.sales_order_count,
                       root.sales_order_has_more,
                       root.work_order_preview, root.work_order_count,
                       root.work_order_has_more,
                       root.workshop_preview, root.workshop_count,
                       root.workshop_has_more,
                       root.product_code_preview, root.product_name_preview,
                       root.product_color_preview, root.product_count,
                       root.product_has_more,
                       root.quantity_summary, root.mixed_units,
                       root.execution_unit_count, root.execution_unit_has_more,
                       root.plan_count, root.segment_count,
                       root.waiting_count, root.ready_count,
                       root.dispatched_count, root.in_progress_count,
                       root.completed_count, root.material_ready_count,
                       root.warehouse_ready_count, root.issued_count,
                       root.reportable_count, root.fqc_pending_count,
                       root.finished_inbound_pending_count,
                       root.earliest_begin_date, root.latest_end_date,
                       root.owner_employee_name,
                       to_char(root.analyzed_at, 'YYYY-MM-DD HH24:MI'),
                       root.root_planned_qty, root.root_inbound_qty,
                       root.root_progress_ratio
                """;
    }

    static String segmentSelect() {
        return """
                SELECT task.segment_id, task.plan_id, task.plan_no,
                       task.segment_code, task.sales_order_nos,
                       task.workshop_department_id, task.workshop_name,
                       task.responsible_employee_name,
                       task.product_code, task.product_name,
                       task.product_color_name, task.product_unit_name,
                       task.planned_qty, task.reported_qty, task.remaining_qty,
                       task.fqc_pending_qty, task.fqc_passed_qty,
                       task.fqc_failed_qty,
                       task.finished_inbound_pending_qty, task.inbound_qty,
                       task.segment_status, task.material_status,
                       task.preparation_status,
                       task.material_status = 'KIT_READY' AS material_ready,
                       task.warehouse_ready, task.issued,
                       FALSE,
                       FALSE,
                       (:allowReport AND task.reportable AND task.segment_status = 'IN_PROGRESS'),
                       (:allowReport AND task.reportable AND task.segment_status = 'IN_PROGRESS'
                        AND task.report_source_count = 1),
                       CASE
                           WHEN :allowReport AND task.reportable
                                AND task.segment_status = 'IN_PROGRESS' THEN NULL
                           WHEN task.reportable AND NOT :allowReport
                                AND task.segment_status = 'IN_PROGRESS'
                             THEN '缺少生产报工权限'
                           ELSE task.blocked_reason
                       END,
                       task.plan_begin_date, task.plan_end_date,
                       task.lock_version,
                       task.zero_material,
                       EXISTS (SELECT 1 FROM production_execution_segments current_segment
                           WHERE current_segment.id = task.segment_id
                             AND current_segment.status = 'WAITING'
                             AND current_segment.auto_promote_when_ready = TRUE
                             AND current_segment.is_deleted = FALSE)
                """;
    }

    private static String rootFilters(
            String keyword,
            UUID workshopDepartmentId,
            boolean mine,
            UUID employeeId,
            boolean canSearchClient) {
        String filter = "";
        if (keyword != null && !keyword.isBlank()) {
            String clientFilter = canSearchClient ? """
                        OR EXISTS (
                            SELECT 1
                            FROM v_production_execution_workbench_segments task
                            JOIN execution_segment_sales_allocations allocation
                              ON allocation.execution_segment_id=task.segment_id
                            JOIN sales_order_items sales_item
                              ON sales_item.id=allocation.sales_order_item_id
                             AND sales_item.is_deleted=FALSE
                            JOIN sales_orders sales_order
                              ON sales_order.id=sales_item.order_id
                             AND sales_order.is_deleted=FALSE
                            JOIN clients client ON client.id=sales_order.client_id
                            WHERE task.root_type=root.root_type
                              AND task.root_id=root.root_id
                              AND lower(COALESCE(client.name,'')) LIKE :keyword)
                    """ : "";
            filter += """
                    AND (
                        lower(COALESCE(root.root_label, '')) LIKE :keyword
                        OR EXISTS (
                            SELECT 1
                            FROM v_production_execution_workbench_segments task
                            WHERE task.root_type = root.root_type
                              AND task.root_id = root.root_id
                              AND (
                                  lower(COALESCE(task.plan_no, '')) LIKE :keyword
                                  OR lower(COALESCE(task.segment_code, '')) LIKE :keyword
                                  OR lower(COALESCE(task.sales_order_nos, '')) LIKE :keyword
                                  OR lower(COALESCE(task.product_code, '')) LIKE :keyword
                                  OR lower(COALESCE(task.product_name, '')) LIKE :keyword
                                  OR lower(COALESCE(task.product_color_name, '')) LIKE :keyword
                                  OR lower(COALESCE(task.workshop_name, '')) LIKE :keyword))
                    """ + clientFilter + """
                        OR (root.root_type = 'ANALYSIS' AND EXISTS (
                            SELECT 1
                            FROM production_material_analysis_items item
                            JOIN goods ON goods.id = item.goods_id
                            LEFT JOIN sales_order_items sales_item
                              ON sales_item.id = item.sales_order_item_id
                            LEFT JOIN sales_orders sales_order
                              ON sales_order.id = sales_item.order_id
                            WHERE item.analysis_id = root.root_id
                              AND item.is_deleted = FALSE
                              AND (
                                  lower(COALESCE(item.source_ref, '')) LIKE :keyword
                                  OR lower(COALESCE(goods.code, '')) LIKE :keyword
                                  OR lower(COALESCE(goods.name, '')) LIKE :keyword
                                  OR lower(COALESCE(sales_order.bill_no, '')) LIKE :keyword)))
                    )
                    """;
        }
        if (workshopDepartmentId != null) {
            filter += """
                    AND EXISTS (
                        SELECT 1
                        FROM v_production_execution_workbench_segments task
                        WHERE task.root_type = root.root_type
                          AND task.root_id = root.root_id
                          AND task.workshop_department_id = :workshopId)
                    """;
        }
        if (mine) {
            filter += employeeId == null
                    ? " AND FALSE"
                    : """
                    AND EXISTS (
                        SELECT 1
                        FROM v_production_execution_workbench_segments task
                        WHERE task.root_type = root.root_type
                          AND task.root_id = root.root_id
                          AND %s)
                    """.formatted(assignmentPredicate("task"));
        }
        return filter;
    }

    private static void bindRootFilters(
            Query query,
            String keyword,
            UUID workshopDepartmentId,
            boolean mine,
            UUID employeeId) {
        if (keyword != null && !keyword.isBlank()) {
            query.setParameter(
                    "keyword",
                    "%" + keyword.strip().toLowerCase(Locale.ROOT) + "%");
        }
        if (workshopDepartmentId != null) {
            query.setParameter("workshopId", workshopDepartmentId);
        }
        if (mine && employeeId != null) {
            query.setParameter("employeeId", employeeId);
        }
    }

    /** Exact workshop subtree, including main and secondary departments. */
    private static String assignmentPredicate(String alias) {
        return com.uten.imp.security.ProductionWorkshopAssignmentScope.predicate(alias);
    }

    private static ProductionExecutionWorkbenchGroup groupRow(Object[] row) {
        Double progressRatio = row[42] == null
                ? null : ((BigDecimal) row[42]).doubleValue();
        return new ProductionExecutionWorkbenchGroup(
                text(row[0]), uuid(row[1]), text(row[3]), text(row[4]),
                text(row[5]), integer(row[6]), bool(row[7]),
                text(row[8]), integer(row[9]), bool(row[10]),
                text(row[11]), integer(row[12]), bool(row[13]),
                text(row[14]), text(row[15]), text(row[16]),
                integer(row[17]), bool(row[18]), text(row[19]), bool(row[20]),
                integer(row[21]), bool(row[22]), integer(row[23]),
                integer(row[24]), integer(row[25]), integer(row[26]),
                integer(row[27]), integer(row[28]), integer(row[29]),
                integer(row[30]), integer(row[31]), integer(row[32]),
                integer(row[33]), integer(row[34]), integer(row[35]),
                false, date(row[36]), date(row[37]),
                text(row[38]), text(row[39]),
                decimal(row[40]), decimal(row[41]), progressRatio);
    }

    private static ProductionExecutionWorkbenchSegment segmentRow(Object[] row, ProductionMaterialUsageReadPort.UsageFlags usage) {
        return new ProductionExecutionWorkbenchSegment(
                uuid(row[0]), uuid(row[1]), text(row[2]), text(row[3]),
                text(row[4]), uuid(row[5]), text(row[6]), text(row[7]),
                text(row[8]), text(row[9]), text(row[10]), text(row[11]),
                decimal(row[12]), decimal(row[13]), decimal(row[14]),
                decimal(row[15]), decimal(row[16]), decimal(row[17]),
                decimal(row[18]), decimal(row[19]), text(row[20]),
                text(row[21]), text(row[22]), bool(row[23]), bool(row[24]),
                bool(row[25]), bool(row[26]), bool(row[27]), bool(row[28]),
                bool(row[29]), text(row[30]), date(row[31]), date(row[32]),
                ((Number) row[33]).longValue(), bool(row[34]), bool(row[35]),
                usage.hasMaterialActivity(), usage.hasUnregisteredMaterial());
    }

    private static int boundedSize(int requested) {
        return Math.min(Math.max(requested, 1), 100);
    }

    private static int pages(long total, int size) {
        return total == 0 ? 0 : (int) ((total + size - 1) / size);
    }

    static String rootOrderBy(String rawSort, String rawOrder) {
        String direction = "desc".equalsIgnoreCase(rawOrder) ? "DESC" : "ASC";
        String column = switch (rawSort == null ? "" : rawSort.strip()) {
            case "status" -> """
                    CASE root.status
                        WHEN 'PARTIALLY_SCHEDULED' THEN 0
                        WHEN 'KIT_SHORT' THEN 1
                        WHEN 'PREPARING' THEN 2
                        WHEN 'KIT_READY_PREPARING' THEN 3
                        WHEN 'PREPARED' THEN 4
                        WHEN 'IN_PROGRESS' THEN 5
                        WHEN 'PLAN_PENDING' THEN 6
                        WHEN 'ANALYZING' THEN 7
                        ELSE 99
                    END""";
            case "rootLabel" -> "root.root_label";
            case "latestEndDate", "" -> "root.latest_end_date";
            default -> "root.latest_end_date";
        };
        return column + " " + direction + " NULLS LAST";
    }

    static boolean reportAllowed(
            boolean canViewReports,
            boolean canCreateReports,
            boolean canViewWorkshopTasks) {
        return canViewReports && canCreateReports && canViewWorkshopTasks;
    }

    private static String rootType(String value) {
        String normalized = value == null ? "" : value.strip().toUpperCase(Locale.ROOT);
        if (!Set.of("ANALYSIS", "PLAN").contains(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知生产任务根类型");
        }
        return normalized;
    }

    private static String normalizeTaskStatus(String value) {
        if (value == null || value.isBlank()) return null;
        String normalized = value.strip().toUpperCase(Locale.ROOT);
        if (!Set.of(
                        "PREPARING", "READY_TO_START", "IN_PROGRESS", "COMPLETED")
                .contains(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知车间任务状态");
        }
        return normalized;
    }

    private static UUID uuid(Object value) {
        if (value == null) return null;
        return value instanceof UUID id ? id : UUID.fromString(value.toString());
    }

    private static String text(Object value) {
        return value == null ? null : value.toString();
    }

    private static boolean bool(Object value) {
        return Boolean.TRUE.equals(value);
    }

    private static int integer(Object value) {
        return value == null ? 0 : ((Number) value).intValue();
    }

    private static BigDecimal decimal(Object value) {
        if (value instanceof BigDecimal number) return number;
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private static LocalDate date(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate result) return result;
        if (value instanceof java.sql.Date result) return result.toLocalDate();
        return LocalDate.parse(value.toString());
    }

    private record ScopeBinding(NativeReadScope scope) {
    }
}
