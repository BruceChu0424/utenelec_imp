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
    private final com.uten.imp.features.production.ProductionWorkshopMembership workshopMembership;
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.features.production.SubcontractDraftPreparationAccessPolicy draftPreparationAccess;
    /** 详情里「仓库已到多少」与齐套提升同口径(ADR-095)；只读端口，单任务粒度调用。 */
    @org.springframework.beans.factory.annotation.Autowired(required = false)
    private com.uten.imp.application.port.WorkshopMaterialAvailabilityReadPort materialAvailability;

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

    /**
     * 「进行中」批次数(ADR-100 黄色进行中徽章)：与 {@link #list} 同一视图、同一可见范围、
     * 同一 WHERE——列表默认不带任何筛选，所以这个数就等于列表行数，卡面与页内对得上。
     * 此前客户端取 {@code ?size=1} 的分页 total 凑数，准则 §四之七 已禁这种取数法：
     * 那条请求要付一遍 ORDER BY 与整行投影的钱，只为读一个 total。
     */
    @Transactional(readOnly = true)
    public long inProgressRootCount() {
        NativeReadScope scope = productionAccess.nativeReadScope(
                "root.owner_employee_id", "rootOwners");
        Query count = em.createNativeQuery(
                "SELECT COUNT(*) FROM v_production_execution_workbench_roots root"
                        + " WHERE (" + rootVisibility(scope.predicate()) + ")");
        scope.bind(count);
        return ((Number) count.getSingleResult()).longValue();
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
        return workshopTasks(requestedPage, requestedSize, keyword, rawStatus,
                workshopDepartmentId, dateFrom, dateTo, null);
    }

    @Transactional(readOnly = true)
    public PageResponse<ProductionExecutionWorkbenchSegment> workshopTasks(
            int requestedPage, int requestedSize, String keyword, String rawStatus,
            UUID workshopDepartmentId, LocalDate dateFrom, LocalDate dateTo, String preparationFilter) {
        return workshopTasks(requestedPage, requestedSize, keyword, rawStatus,
                workshopDepartmentId, dateFrom, dateTo, preparationFilter, null);
    }

    /**
     * @param routeFilter 「下一步」表头筛选(ADR-095)：UNCONFIRMED(待选路线) / FULL_KIT /
     *                    CONTINUOUS / BATCH；空=不筛。与其它筛选一样在分页前于服务端生效。
     */
    @Transactional(readOnly = true)
    public PageResponse<ProductionExecutionWorkbenchSegment> workshopTasks(
            int requestedPage, int requestedSize, String keyword, String rawStatus,
            UUID workshopDepartmentId, LocalDate dateFrom, LocalDate dateTo, String preparationFilter,
            String routeFilter) {
        UUID employeeId = currentUser.employeeId().orElse(null);
        // 超管可查看并代办全部车间任务；普通员工仍按有效车间归属收敛。
        // 车间筛选只进一步缩小范围，不扩大普通员工的可见性。
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
                    + " AND (" + effectiveIssuedPredicate() + " OR task.zero_material)";
                case "IN_PROGRESS" -> " AND task.segment_status = 'IN_PROGRESS'";
                default -> "";
            };
        }
        predicate += preparationPredicate(preparationFilter);
        String normalizedRoute = normalizeRouteFilter(routeFilter);
        if (normalizedRoute != null) {
            predicate += "UNCONFIRMED".equals(normalizedRoute)
                    ? " AND EXISTS (SELECT 1 FROM production_execution_segments route_filter"
                        + " WHERE route_filter.id = task.segment_id AND route_filter.start_route IS NULL)"
                    : " AND EXISTS (SELECT 1 FROM production_execution_segments route_filter"
                        + " WHERE route_filter.id = task.segment_id AND route_filter.start_route = :routeFilter)";
        }
        String finalPredicate = predicate;
        UUID scopedEmployeeId = seeAll ? null : employeeId;
        // 我的车间任务「等待物料」（2026-09-15 用户口径）：可开工的排最前，
        // 进度越接近可开工越靠前——档位与状态筛选四桶一一对应。
        String orderBy = "PREPARING".equals(status)
                ? SEGMENT_ORDER_READINESS
                : SEGMENT_ORDER_DEFAULT;
        // 路线记忆的操作者档(ADR-096)：本产品没有历史时预填「你上次选的」；每页只查一次。
        String operatorRouteMemory = history ? null : operatorRouteMemory();
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
                    if (normalizedRoute != null && !"UNCONFIRMED".equals(normalizedRoute)) {
                        query.setParameter("routeFilter", normalizedRoute);
                    }
                },
                requestedPage,
                requestedSize,
                orderBy,
                operatorRouteMemory);
    }

    /**
     * 当前操作者最近一次确认的路线(ADR-096「记住上次的选择」)：取其最近一条 ROUTE_CONFIRMED
     * 事件所在工单的当前路线；没有登录身份或从未确认过时为 null。V629 部分索引点查。
     */
    private String operatorRouteMemory() {
        UUID userId = currentUser.get().map(AuthUser::getId).orElse(null);
        if (userId == null) return null;
        // Single-column native query: Hibernate hands back the scalar itself, not Object[].
        List<String> rows = NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT segment.start_route
                FROM production_execution_segment_events event
                JOIN production_execution_segments segment ON segment.id = event.execution_segment_id
                WHERE event.action = 'ROUTE_CONFIRMED' AND event.created_by = :userId
                  AND segment.start_route IS NOT NULL
                ORDER BY event.created_at DESC
                LIMIT 1
                """).setParameter("userId", userId), String.class);
        return rows.isEmpty() ? null : rows.getFirst();
    }

    /**
     * 车间任务的逐种物料事实(ADR-095)：需求量 / 已预留 / 已申请待仓库发 / 可申请 / 线边仓待
     * 自动投入 / 已实领 / 缺口 / 同车间直送已交接与待分配，以及与汇总同口径的状态桶。
     * 可见范围与任务列表同源(本人车间归属或超管)，不授予任何写能力。
     */
    @Transactional(readOnly = true)
    public List<ProductionWorkshopTaskMaterial> workshopTaskMaterials(UUID segmentId) {
        UUID employeeId = currentUser.employeeId().orElse(null);
        boolean seeAll = currentUser.get().map(AuthUser::isSuperAdmin).orElse(false);
        if (segmentId == null || (employeeId == null && !seeAll)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "车间任务不存在");
        }
        Query visible = em.createNativeQuery("SELECT COUNT(*) FROM v_production_execution_workbench_segments task"
                + " WHERE task.segment_id = :segmentId AND (" + (seeAll ? "TRUE" : assignmentPredicate("task")) + ")");
        visible.setParameter("segmentId", segmentId);
        if (!seeAll) visible.setParameter("employeeId", employeeId);
        if (((Number) visible.getSingleResult()).longValue() == 0) {
            throw new ApiException(ErrorCode.NOT_FOUND, "车间任务不存在");
        }
        Query query = em.createNativeQuery("""
                SELECT facts.demand_id, goods.code, goods.name, color.name, unit.name,
                       facts.supply_route, facts.direct_supply, facts.required_qty, facts.reserved_qty,
                       facts.requested_unissued_qty, facts.requestable_qty, facts.line_side_pending_qty,
                       facts.issued_qty, facts.shortage_qty, facts.direct_received_qty,
                       facts.direct_available_qty, facts.state,
                       CASE WHEN facts.supply_route = 'MAKE' THEN (
                           SELECT string_agg(producing.segment_code || '|' || producing.status, '、'
                                             ORDER BY producing.segment_code)
                           FROM production_execution_segments producing
                           JOIN production_execution_segments receiving ON receiving.id = :segmentId
                           WHERE producing.product_goods_id = facts.goods_id
                             AND producing.product_color_id IS NOT DISTINCT FROM facts.color_id
                             AND producing.workshop_department_id = receiving.workshop_department_id
                             AND producing.id <> receiving.id AND NOT producing.is_deleted
                             AND producing.status IN ('WAITING','READY','DISPATCHED','IN_PROGRESS','COMPLETED')
                             AND fn_workshop_direct_responsibility_allows(producing.id, facts.demand_id))
                       END AS producing_segments
                FROM fn_execution_segment_material_facts(:segmentId) facts
                JOIN goods ON goods.id = facts.goods_id
                LEFT JOIN colors color ON color.id = facts.color_id
                LEFT JOIN units unit ON unit.id = facts.unit_id
                ORDER BY CASE facts.state WHEN 'SHORT_MAKE' THEN 0 WHEN 'SHORT' THEN 1 WHEN 'DRAWABLE' THEN 2
                              WHEN 'AWAITING_WAREHOUSE' THEN 3 WHEN 'LINE_SIDE_PENDING' THEN 4
                              WHEN 'PREPARING' THEN 5 ELSE 6 END,
                         goods.name, goods.code, facts.demand_id
                """);
        query.setParameter("segmentId", segmentId);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(query);
        java.util.Map<UUID, BigDecimal> warehouseAvailable = warehouseAvailableByDemand(segmentId,
                rows.stream().map(row -> uuid(row[0])).toList());
        return rows.stream()
                .map(row -> new ProductionWorkshopTaskMaterial(
                        uuid(row[0]), text(row[1]), text(row[2]), text(row[3]), text(row[4]),
                        text(row[5]), bool(row[6]), decimal(row[7]), decimal(row[8]), decimal(row[9]),
                        decimal(row[10]), decimal(row[11]), decimal(row[12]), decimal(row[13]),
                        decimal(row[14]), decimal(row[15]),
                        warehouseAvailable.getOrDefault(uuid(row[0]), BigDecimal.ZERO),
                        text(row[16]), text(row[17])))
                .toList();
    }

    /**
     * 「仓库已到多少」= 本任务专属来源权益 + 允许动用的公共库存(同主仓、扣安全库存)，与齐套
     * 提升的 {@code batchAvailability} 同一口径；公共份额在同货品颜色的多条需求间不重复计入。
     * 无可用端口(单元测试桩)或任务缺少确认计划包时返回空表，不猜数。
     */
    private java.util.Map<UUID, BigDecimal> warehouseAvailableByDemand(UUID segmentId, List<UUID> demandIds) {
        if (materialAvailability == null || demandIds.isEmpty()) return java.util.Map.of();
        List<Object[]> context = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT package.warehouse_id, plan.material_analysis_id, plan.material_analysis_item_id
                FROM production_execution_segments segment
                JOIN production_planning_packages package ON package.id = segment.package_id
                  AND package.status = 'CONFIRMED' AND NOT package.is_deleted
                JOIN production_plans plan ON plan.id = segment.plan_id
                WHERE segment.id = :segmentId AND NOT segment.is_deleted
                """).setParameter("segmentId", segmentId));
        if (context.isEmpty() || context.getFirst()[0] == null) return java.util.Map.of();
        Object[] first = context.getFirst();
        var availability = materialAvailability.batchAvailability(uuid(first[0]), demandIds, uuid(first[1]), uuid(first[2]));
        java.util.Map<UUID, BigDecimal> qualified = new java.util.HashMap<>();
        java.util.Map<UUID, BigDecimal> publicQty = new java.util.HashMap<>();
        java.util.Map<UUID, BigDecimal> safety = new java.util.HashMap<>();
        for (var row : availability) {
            qualified.merge(row.demandId(), row.qualifiedQty().max(BigDecimal.ZERO), BigDecimal::add);
            publicQty.merge(row.demandId(), row.publicQty().max(BigDecimal.ZERO), BigDecimal::add);
            safety.merge(row.demandId(), row.safetyQty(), BigDecimal::max);
        }
        java.util.Map<UUID, BigDecimal> result = new java.util.HashMap<>();
        for (UUID demandId : demandIds) {
            BigDecimal budget = com.uten.imp.common.inventory.MainWarehouseStockBudget.publicBudget(
                    publicQty.getOrDefault(demandId, BigDecimal.ZERO), safety.getOrDefault(demandId, BigDecimal.ZERO));
            result.put(demandId, qualified.getOrDefault(demandId, BigDecimal.ZERO).add(budget.max(BigDecimal.ZERO)));
        }
        return result;
    }

    private static String normalizeRouteFilter(String value) {
        if (value == null || value.isBlank()) return null;
        String normalized = value.strip().toUpperCase(Locale.ROOT);
        if (!Set.of("UNCONFIRMED", "FULL_KIT", "CONTINUOUS", "BATCH").contains(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "生产路线筛选无效");
        }
        return normalized;
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

    /** 段列表默认排序：计划完工日期 → 计划号 → 段序 → UUID 稳定收尾。 */
    private static final String SEGMENT_ORDER_DEFAULT = """
            ORDER BY task.plan_end_date ASC NULLS LAST,
                     task.plan_no ASC,
                     task.segment_no ASC,
                     task.segment_id ASC
            """;

    /**
     * 我的车间任务「等待物料」排序（2026-09-15 用户口径：可开工的放最前，越接近
     * 可开工越靠前）。档位与状态筛选四桶一一对应（preparationPredicate 同款谓词）：
     * 0 = 可开工（零料/已发料且 READY/DISPATCHED）；1 = 已提交领料·待仓库发料；
     * 2 = 物料齐套·去领料；3 = 等料（WAITING）。同档位内再按既有键稳定排序。
     * CASE 短路保证领料谓词里的 EXISTS 只对 READY/DISPATCHED 行求值。
     */
    private static final String SEGMENT_ORDER_READINESS = """
            ORDER BY CASE
                         WHEN task.segment_status IN ('READY','DISPATCHED')
                              AND (task.zero_material OR task.issued
                                   OR fn_split_batch_empty_issued(task.segment_id)
                                   OR fn_actual_supplement_material_ready(task.segment_id)) THEN 0
                         WHEN task.segment_status IN ('READY','DISPATCHED')
                              AND NOT task.zero_material AND NOT task.issued
                              AND (%s) THEN 1
                         WHEN task.segment_status IN ('READY','DISPATCHED') THEN 2
                         ELSE 3
                     END ASC,
                     task.plan_end_date ASC NULLS LAST,
                     task.plan_no ASC,
                     task.segment_no ASC,
                     task.segment_id ASC
            """.formatted(drawRequestedPredicate());

    private PageResponse<ProductionExecutionWorkbenchSegment> segmentPage(
            String predicate,
            java.util.function.Consumer<Query> binder,
            int requestedPage,
            int requestedSize) {
        return segmentPage(predicate, binder, requestedPage, requestedSize, SEGMENT_ORDER_DEFAULT);
    }

    private PageResponse<ProductionExecutionWorkbenchSegment> segmentPage(
            String predicate,
            java.util.function.Consumer<Query> binder,
            int requestedPage,
            int requestedSize,
            String orderBy) {
        return segmentPage(predicate, binder, requestedPage, requestedSize, orderBy, null);
    }

    private PageResponse<ProductionExecutionWorkbenchSegment> segmentPage(
            String predicate,
            java.util.function.Consumer<Query> binder,
            int requestedPage,
            int requestedSize,
            String orderBy,
            String operatorRouteMemory) {
        int size = boundedSize(requestedSize);
        int page = Math.max(requestedPage, 1);
        String from = " FROM v_production_execution_workbench_segments task WHERE "
                + predicate;
        Query count = em.createNativeQuery("SELECT COUNT(*)" + from);
        binder.accept(count);
        long total = ((Number) count.getSingleResult()).longValue();
        int totalPages = pages(total, size);
        if (totalPages > 0 && page > totalPages) page = totalPages;
        // 逐种物料事实(ADR-095)只在取页数据时按行 LATERAL 计算一次；计数查询不付这笔代价。
        String dataFrom = " FROM v_production_execution_workbench_segments task"
                + " LEFT JOIN LATERAL fn_execution_segment_material_summary(task.segment_id) material ON TRUE"
                + " JOIN production_execution_segments rate_segment ON rate_segment.id=task.segment_id"
                + " LEFT JOIN production_overproduction_rate_requests rate_request ON rate_request.execution_segment_id=task.segment_id AND rate_request.status='PENDING'"
                + " LEFT JOIN LATERAL (SELECT (fn_execution_overproduction_policy_applies(task.segment_id)"
                + " OR EXISTS(SELECT 1 FROM v_production_fqc_recovery_balance recovery"
                + " JOIN production_fqc_recovery_authorizations recovery_authority ON recovery_authority.id=recovery.authorization_id"
                + " WHERE recovery.execution_segment_id=task.segment_id AND NOT recovery.cancelled AND recovery.available_qty>0"
                + " AND (recovery_authority.disposition_code='REWORK' OR fn_fqc_replenishment_material_ready(recovery_authority.id)))) AS allowed) report_origin ON TRUE"
                + " WHERE " + predicate;
        Query data = em.createNativeQuery(segmentSelect() + dataFrom + "\n" + orderBy
                + "\n LIMIT :limit OFFSET :offset");
        binder.accept(data);
        boolean activeOperator = workshopMembership.isActiveOperator();
        boolean allowReport = activeOperator && reportAllowed(
                productionAccess.hasAuthority("production_daily_report:view"),
                productionAccess.hasAuthority("production_daily_report:create"),
                productionAccess.hasAuthority("production_execution:view"));
        data.setParameter("allowReport", allowReport);
        data.setParameter("allowRequestDraw", activeOperator && productionAccess.hasAuthority("production_execution:start")
                && productionAccess.hasAuthority("production_execution:view"));
        data.setParameter("limit", size);
        data.setParameter("offset", (long) (page - 1) * size);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(data);
        var usage = materialUsage.forVisibleSegments(rows.stream().map(row -> uuid(row[0])).toList());
        List<ProductionExecutionWorkbenchSegment> items = rows.stream()
                        .map(row -> segmentRow(row, usage.getOrDefault(uuid(row[0]), ProductionMaterialUsageReadPort.UsageFlags.NONE),
                                operatorRouteMemory))
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
                       task.segment_status,
                       CASE WHEN fn_split_batch_empty_issued(task.segment_id) OR fn_actual_supplement_material_ready(task.segment_id) THEN 'KIT_READY' ELSE task.material_status END,
                       CASE WHEN fn_split_batch_empty_issued(task.segment_id) OR fn_actual_supplement_material_ready(task.segment_id) THEN 'PREPARED' ELSE task.preparation_status END,
                       (task.material_status = 'KIT_READY' OR fn_split_batch_empty_issued(task.segment_id) OR fn_actual_supplement_material_ready(task.segment_id)) AS material_ready,
                       task.warehouse_ready, %s,
                       FALSE,
                       (:allowRequestDraw AND task.segment_status IN ('READY','DISPATCHED')
                         AND EXISTS (SELECT 1 FROM production_execution_segments start_segment
                           JOIN production_plans start_plan ON start_plan.id=start_segment.plan_id
                           WHERE start_segment.id=task.segment_id
                             AND start_segment.start_route IN ('FULL_KIT','CONTINUOUS')
                             AND start_segment.workshop_department_id IS NOT NULL
                             AND start_segment.responsible_employee_id IS NOT NULL
                             AND start_plan.status=1 AND NOT start_plan.is_closed
                             AND NOT start_plan.is_canceled AND NOT start_plan.is_stopped
                             AND fn_execution_start_material_ready(task.segment_id))),
                       (:allowReport AND task.reportable AND report_origin.allowed AND task.segment_status = 'IN_PROGRESS'),
                       (:allowReport AND task.reportable AND report_origin.allowed AND fn_execution_overproduction_policy_applies(task.segment_id) AND task.segment_status = 'IN_PROGRESS'
                        AND task.report_source_count = 1 AND task.remaining_qty > 0),
                       CASE
                           WHEN NOT report_origin.allowed THEN '固定追加工单请从追加计划回原批次续报'
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
                       (:allowRequestDraw AND EXISTS (SELECT 1 FROM production_execution_segments current_segment
                           WHERE current_segment.id = task.segment_id
                             AND current_segment.status IN ('WAITING','READY','DISPATCHED','IN_PROGRESS')
                             AND current_segment.start_route IN ('FULL_KIT','CONTINUOUS')
                             AND current_segment.auto_promote_when_ready = TRUE
                             AND current_segment.is_deleted = FALSE)),
                       %s,
                       (:allowRequestDraw AND task.segment_status IN ('READY','DISPATCHED','IN_PROGRESS')
                         AND NOT task.zero_material AND NOT (%s)
                         AND EXISTS(SELECT 1 FROM production_execution_segments route_segment
                           WHERE route_segment.id=task.segment_id AND route_segment.start_route IN ('FULL_KIT','CONTINUOUS'))
                         AND EXISTS (%s AND NOT pending_warehouse.is_line_side
                           AND fn_production_draw_item_requested_qty(pending_item.id)<fn_production_draw_item_effective_qty(pending_item.id))),
                       (:allowRequestDraw AND fn_can_split_execution_batch(task.segment_id)),
                       (SELECT source_segment_id FROM production_execution_segments WHERE id=task.segment_id),
                       EXISTS(SELECT 1 FROM production_execution_segment_splits WHERE source_segment_id=task.segment_id),
                       EXISTS(SELECT 1 FROM fn_production_material_usage_source_segments(task.segment_id) source
                              WHERE source.segment_id<>task.segment_id),
                       COALESCE((SELECT continuous_supply FROM production_execution_segments WHERE id=task.segment_id), FALSE),
                       (SELECT route_segment.start_route FROM production_execution_segments route_segment
                           WHERE route_segment.id = task.segment_id),
                       (:allowRequestDraw AND task.segment_status IN ('WAITING','READY','DISPATCHED')
                         AND NOT EXISTS (SELECT 1 FROM production_execution_segments route_segment
                              WHERE route_segment.id = task.segment_id
                                AND route_segment.start_route IS NOT NULL)),
                       (:allowRequestDraw AND task.segment_status IN ('WAITING','READY','DISPATCHED')
                         AND fn_can_change_execution_route(task.segment_id)),
                       EXISTS(SELECT 1 FROM production_execution_segments command_segment
                         JOIN production_plans command_plan ON command_plan.id=command_segment.plan_id
                         JOIN production_planning_packages command_package ON command_package.id=command_segment.package_id
                         WHERE command_segment.id=task.segment_id AND NOT command_segment.is_deleted
                           AND command_plan.status=1 AND NOT command_plan.is_deleted
                           AND NOT command_plan.is_closed AND NOT command_plan.is_canceled AND NOT command_plan.is_stopped
                           AND command_package.status='CONFIRMED' AND NOT command_package.is_deleted),
                       fn_execution_material_custody_valid(task.segment_id),
                       (SELECT memory.start_route
                          FROM production_execution_segments memory
                         WHERE memory.product_goods_id = task.product_goods_id
                           AND memory.id <> task.segment_id
                           AND memory.is_deleted = FALSE
                           AND memory.start_route IS NOT NULL
                           AND memory.route_confirmed_at IS NOT NULL
                           AND memory.status NOT IN ('CANCELLED', 'REVERSED')
                         ORDER BY memory.route_confirmed_at DESC
                         LIMIT 1),
                       COALESCE(material.kind_count, 0), COALESCE(material.issued_count, 0),
                       COALESCE(material.partial_issued_count, 0),
                       COALESCE(material.awaiting_warehouse_count, 0), COALESCE(material.drawable_count, 0),
                       COALESCE(material.line_side_pending_count, 0), COALESCE(material.preparing_count, 0),
                       COALESCE(material.short_count, 0), COALESCE(material.short_make_count, 0),
                       COALESCE(material.supported_output_qty, 0), COALESCE(material.prepared_output_qty, 0),
                       task.actual_surplus_reported_qty, task.actual_surplus_inbound_qty,
                       task.planned_inbound_qty,rate_segment.allowed_overproduction_rate,
                       rate_segment.overproduction_rate_version,rate_request.id,rate_request.requested_rate,
                       fn_execution_overproduction_policy_applies(rate_segment.id),
                       (SELECT actual_output_supplement_request_id FROM production_plans WHERE id=task.plan_id)
                """.formatted(effectiveIssuedPredicate(), drawRequestedPredicate(), drawRequestedPredicate(), pendingDrawItemSql());
    }

    /**
     * 本段尚未发完的领料行(V595)：与 `pending_warehouse.is_line_side` 组合判定「只剩线边仓直送料
     * 没出库」——这种段不用去领料，开工时就地自动出库，车间任务页按「可开工」呈现。
     */
    private static String pendingDrawItemSql() {
        return """
                SELECT 1 FROM production_planning_package_documents pending_mapping
                    JOIN stock_documents pending_document ON pending_document.id=pending_mapping.document_id
                    JOIN stock_document_items pending_item ON pending_item.doc_id=pending_document.id
                      AND NOT pending_item.is_deleted
                    JOIN warehouses pending_warehouse ON pending_warehouse.id=pending_document.warehouse_id
                    WHERE pending_mapping.execution_segment_id=task.segment_id
                      AND pending_mapping.document_type='DRAW'
                      AND NOT pending_document.is_deleted AND pending_document.status IN (0,1)
                      AND COALESCE(pending_item.issued_qty,0) < fn_production_draw_item_effective_qty(pending_item.id)""";
    }

    static String drawRequestedPredicate() {
        return """
                EXISTS (SELECT 1 FROM production_planning_package_documents draw_mapping
                    JOIN stock_documents draw_document ON draw_document.id=draw_mapping.document_id
                    WHERE draw_mapping.execution_segment_id=task.segment_id
                      AND draw_mapping.document_type='DRAW' AND NOT draw_document.is_deleted
                      AND draw_document.status IN (0,1)
                ) AND NOT EXISTS (
                    SELECT 1 FROM production_planning_package_documents draw_mapping
                    JOIN stock_documents draw_document ON draw_document.id=draw_mapping.document_id
                    WHERE draw_mapping.execution_segment_id=task.segment_id
                      AND draw_mapping.document_type='DRAW' AND NOT draw_document.is_deleted
                      AND draw_document.status IN (0,1)
                      AND NOT fn_production_draw_fully_requested(draw_document.id))
                """;
    }

    static String preparationPredicate(String rawFilter) {
        if (rawFilter == null || rawFilter.isBlank()) return "";
        return switch (rawFilter.strip().toUpperCase(Locale.ROOT)) {
            case "WAITING_MATERIAL" -> " AND task.segment_status='WAITING'";
            case "DRAW_NOT_REQUESTED" -> " AND task.segment_status IN ('READY','DISPATCHED')"
                    + " AND NOT task.zero_material AND NOT (" + effectiveIssuedPredicate() + ") AND NOT (" + drawRequestedPredicate() + ")";
            case "DRAW_REQUESTED" -> " AND task.segment_status IN ('READY','DISPATCHED')"
                    + " AND NOT task.zero_material AND NOT (" + effectiveIssuedPredicate() + ") AND (" + drawRequestedPredicate() + ")";
            case "READY_TO_START" -> " AND task.segment_status IN ('READY','DISPATCHED')"
                    + " AND (task.zero_material OR " + effectiveIssuedPredicate() + ")";
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "等待物料状态筛选无效");
        };
    }

    static String effectiveIssuedPredicate() {
        return "(task.issued OR fn_split_batch_empty_issued(task.segment_id) OR fn_actual_supplement_material_ready(task.segment_id))";
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

    private static ProductionExecutionWorkbenchSegment segmentRow(Object[] row, ProductionMaterialUsageReadPort.UsageFlags usage,
                                                                  String operatorRouteMemory) {
        // The same current plan/package facts gate every command capability. Compute once
        // per projected task, so historical or paused rows do not advertise rejected actions.
        boolean executable = bool(row[46]);
        boolean custodyValid = bool(row[47]);
        // 路线记忆(ADR-096)：本产品的历史优先；没有才退回操作者上次的选择。只作预填展示。
        String productMemory = text(row[48]);
        String suggestedRoute = productMemory != null ? productMemory : operatorRouteMemory;
        String suggestedSource = productMemory != null ? "PRODUCT" : operatorRouteMemory != null ? "OPERATOR" : null;
        return new ProductionExecutionWorkbenchSegment(
                uuid(row[0]), uuid(row[1]), text(row[2]), text(row[3]),
                text(row[4]), uuid(row[5]), text(row[6]), text(row[7]),
                text(row[8]), text(row[9]), text(row[10]), text(row[11]),
                decimal(row[12]), decimal(row[13]), decimal(row[14]),
                decimal(row[15]), decimal(row[16]), decimal(row[17]),
                decimal(row[18]), decimal(row[19]), text(row[20]),
                text(row[21]), text(row[22]), bool(row[23]), bool(row[24]),
                bool(row[25]), executable && bool(row[26]), executable && custodyValid && bool(row[27]), executable && custodyValid && bool(row[28]),
                executable && custodyValid && bool(row[29]), custodyValid ? text(row[30]) : "实领或直送物料与当前车间不一致，请先核对原领料并按来源退回或反向处理", date(row[31]), date(row[32]),
                ((Number) row[33]).longValue(), bool(row[34]), executable && bool(row[35]),
                usage.hasMaterialActivity(), usage.hasUnregisteredMaterial(), bool(row[36]), executable && bool(row[37]),
                executable && bool(row[38]), uuid(row[39]), bool(row[40]), bool(row[41]),
                usage.hasPendingReturn(), usage.hasAvailableMaterial(),
                bool(row[42]),
                text(row[43]), executable && bool(row[44]), executable && bool(row[45]),
                suggestedRoute, suggestedSource,
                integer(row[49]), integer(row[50]), integer(row[51]), integer(row[52]), integer(row[53]),
                integer(row[54]), integer(row[55]), integer(row[56]), integer(row[57]),
                decimal(row[58]), decimal(row[59]),
                decimal(row[60]), decimal(row[61]), decimal(row[62]),decimal(row[63]),
                ((Number)row[64]).longValue(),uuid(row[65]),row[66]==null?null:decimal(row[66]),bool(row[67]),uuid(row[68]));
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
