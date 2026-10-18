package com.uten.imp.features.notice;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.application.port.TaskAudiencePort;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.Set;
import java.util.List;
import java.util.UUID;
import java.util.LinkedHashSet;
import java.util.stream.Collectors;

/** Current action authority governs reminders; physical responsibility scopes remain bounded. */
@Component
@RequiredArgsConstructor
public class ReviewNoticeAudience {
    private final JdbcTemplate jdbc;
    private final OwnerVisibility ownerVisibility;
    private final com.uten.imp.features.auth.PermissionResolver permissionResolver;
    @org.springframework.beans.factory.annotation.Autowired
    private TaskAudiencePort taskAudience;

    static final String WORKSHOP_EVENT = "PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED";
    static final String OVER_LIMIT_EVENT = "PRODUCTION_OVER_LIMIT_PENDING";
    private static final Set<String> WAREHOUSE_EVENTS = Set.of("SALES_SHIPMENT_PENDING_PICK",
            "PROCUREMENT_IQC_STOCK_IN_PENDING", "PRODUCTION_DRAW_PENDING", "PRODUCTION_MATERIAL_DISCOVERY_PENDING",
            "PROCUREMENT_FINANCE_APPROVED", "SUBCONTRACT_OUTBOUND_READY", "STOCK_COUNT_PENDING_WAREHOUSE_REVIEW",
            "WORKSHOP_MATERIAL_REQUISITION_PENDING", "WORKSHOP_MATERIAL_RETURN_PENDING",
            "WORKSHOP_MATERIAL_CLOSE_BLOCKED_STOCK", "PRODUCTION_FINISHED_INBOUND_PENDING",
            "PRODUCTION_FINISHED_ARRIVAL_PENDING", "SUBCONTRACT_OUTBOUND_COMPLETED", "PROCUREMENT_ARRIVAL_EXCEPTION_DECIDED");
    private static final UUID NO_EMPLOYEE = new UUID(0, 0);

    /** Bounded organization scope, never a list of all execution segments. */
    public record WorkshopScope(boolean allowed, UUID employeeId, Set<UUID> departmentIds) {
        static final WorkshopScope NONE = new WorkshopScope(false, NO_EMPLOYEE, Set.of(NO_EMPLOYEE));
        public WorkshopScope {
            departmentIds = departmentIds.isEmpty() ? Set.of(NO_EMPLOYEE) : Set.copyOf(departmentIds);
        }
    }

    /** Bounded department/owner scopes; never materialize all visible notice or disposition IDs. */
    public record ReadScope(WorkshopScope workshop, boolean overLimitAllowed,
                            boolean overLimitSeeAll, String overLimitOwners,
                            String permissions, String actionEvents, String ownerScopes, String warehousePools) {
        public ReadScope(WorkshopScope workshop, boolean overLimitAllowed,
                         boolean overLimitSeeAll, String overLimitOwners) {
            this(workshop, overLimitAllowed, overLimitSeeAll, overLimitOwners, "", "", "{}", "{}");
        }
        public String registeredEvents() { return java.util.stream.Stream.concat(ReviewNoticeCatalog.events().stream(),
                BusinessNoticeActionCatalog.events().stream()).collect(Collectors.joining(",")); }
        static final ReadScope NONE = new ReadScope(WorkshopScope.NONE, false, false, "");
    }

    public ReadScope readScope(AuthUser user) {
        return taskAudience == null ? taskReadScope(user) : taskAudience.read(() -> taskReadScope(user));
    }

    private ReadScope taskReadScope(AuthUser user) {
        Set<String> permissions = taskPermissions(user);
        Set<String> events = new java.util.HashSet<>(eligibleEvents(permissions));
        BusinessNoticeActionCatalog.events().stream().filter(event -> BusinessNoticeActionCatalog.eligible(event, permissions)).forEach(events::add);
        WorkshopScope workshop = workshopScope(user);
        boolean overLimitAllowed = events.contains(OVER_LIMIT_EVENT);
        // TaskAudiencePort removes only implicit super-admin authority for this read.
        // Canonical owner resolution still supplies handovers and separate read/write scopes.
        boolean planScopeNeeded = overLimitAllowed || events.contains("PRODUCTION_PLANNING_URGED")
                || events.contains("WORKSHOP_MATERIAL_CLOSE_BLOCKED_REPORT");
        var owners = planScopeNeeded ? ownerVisibility.evaluate("production_plan", "production_plan:view:all")
                : new OwnerVisibility.OwnerScope(false, Set.of());
        String scopes = "{" + scopeJson("production_plan", owners)
                + (events.stream().anyMatch(event -> event.startsWith("SUBCONTRACT_") || event.equals("PROCUREMENT_FINANCE_REJECTED"))
                    ? "," + scopeJson("subcontract", ownerVisibility.evaluate("subcontract", "subcontract:view:all")) : "")
                + (events.contains("PROCUREMENT_FINANCE_REJECTED")
                    ? "," + scopeJson("purchase", ownerVisibility.evaluate("purchase", "purchase:view:all")) : "")
                + (events.stream().anyMatch(event -> event.startsWith("SALES_") || event.equals("DIRECT_CUSTOMER_SHIPMENT_FINANCE_REJECTED"))
                    ? "," + scopeJson("sales", ownerVisibility.evaluate("sales", "sales:view:all")) : "") + "}";
        return new ReadScope(workshop, overLimitAllowed, owners.seeAll(), owners.visibleOwners().stream()
                .map(UUID::toString).sorted().collect(Collectors.joining(",")),
                String.join(",", permissions), String.join(",", events), scopes, warehousePools(permissions, events));
    }

    /** One live batch for every relevant warehouse pool; SQL then uses the canonical routing function per object. */
    private String warehousePools(Set<String> permissions, Set<String> events) {
        Set<String> warehouseEvents = new java.util.HashSet<>(events);
        warehouseEvents.retainAll(WAREHOUSE_EVENTS);
        if (warehouseEvents.isEmpty()) return "{}";
        List<UUID> candidates = jdbc.queryForList("""
                SELECT account.id FROM users account JOIN employees employee ON employee.id=account.employee_id
                WHERE NOT account.is_deleted AND account.status='active' AND NOT employee.is_deleted
                  AND employee.status IN ('active','probation','onLeave') ORDER BY account.id
                """, UUID.class);
        var grants = permissionResolver.grantedPermissionsFor(candidates, permissions);
        return warehouseEvents.stream().sorted().map(event -> "\"" + event + "\":["
                + uuidJson(grants.entrySet().stream()
                        .filter(entry -> actionEligible(event, entry.getValue()))
                        .map(java.util.Map.Entry::getKey).collect(Collectors.toSet())) + "]")
                .collect(Collectors.joining(",", "{", "}"));
    }

    private static String scopeJson(String name, OwnerVisibility.OwnerScope owners) {
        return "\"" + name + "\":{\"all\":" + owners.seeAll() + ",\"read\":["
                + uuidJson(owners.visibleOwners()) + "],\"write\":[" + uuidJson(owners.writableOwners()) + "]}";
    }

    private static String uuidJson(Set<UUID> owners) {
        return owners.stream().sorted().map(id -> "\"" + id + "\"").collect(Collectors.joining(","));
    }

    private Set<String> taskPermissions(AuthUser user) {
        if (user == null || user.isVisitor() || user.getEmployeeId() == null) return Set.of();
        return user.isSuperAdmin() ? permissionResolver.grantedPermsOf(user.getId()) : user.getPermissions();
    }

    static boolean canHandleWorkshop(Set<String> permissions) {
        return permissions != null && permissions.containsAll(Set.of("notice:read", "production_execution:view"))
                && (permissions.contains("production_execution:start")
                    || permissions.containsAll(Set.of("production_daily_report:view", "production_daily_report:create")));
    }

    /** Reverse of the sender's current leadership scope; old member cards lose visibility too. */
    public WorkshopScope workshopScope(AuthUser user) {
        if (user == null || user.isVisitor() || user.getEmployeeId() == null
                || !canHandleWorkshop(taskPermissions(user))) return WorkshopScope.NONE;
        var rows = jdbc.queryForList("""
                WITH RECURSIVE active_employee AS (
                    SELECT employee.id, employee.department_id FROM employees employee
                    JOIN users account ON account.employee_id=employee.id
                    WHERE account.id=? AND employee.id=?
                      AND account.is_deleted=FALSE AND account.status='active'
                      AND employee.is_deleted=FALSE
                      AND employee.status IN ('active','probation','onLeave')
                ), leaderships(id) AS (
                    SELECT department.id FROM departments department
                        JOIN active_employee employee ON employee.id=department.manager_id
                        WHERE department.is_deleted=FALSE
                ), ancestry(id,parent_id) AS (
                    SELECT department.id,department.parent_id FROM departments department
                    JOIN leaderships leader ON leader.id=department.id WHERE department.is_deleted=FALSE
                    UNION SELECT department.id,department.parent_id FROM departments department
                    JOIN ancestry child ON child.parent_id=department.id WHERE department.is_deleted=FALSE
                )
                SELECT employee.id AS employee_id, ancestry.id AS department_id
                FROM active_employee employee LEFT JOIN ancestry ON TRUE
                """, user.getId(), user.getEmployeeId());
        if (rows.isEmpty()) return WorkshopScope.NONE;
        Set<UUID> departments = new LinkedHashSet<>();
        rows.forEach(row -> { if (row.get("department_id") instanceof UUID id) departments.add(id); });
        return new WorkshopScope(true, user.getEmployeeId(), departments);
    }

    /** Current actual grants determine event eligibility; object responsibility is checked separately. */
    public Set<String> eligibleEvents(AuthUser user) {
        return eligibleEvents(taskPermissions(user));
    }

    /** Final delivery guard for direct/owner recipients as well as preselected pools. */
    public boolean eligibleEventFor(UUID userId, String event) {
        return userId != null && actionEligible(event, permissionResolver.grantedPermsOf(userId));
    }

    private static boolean actionEligible(String event,Set<String> permissions) {
        return BusinessNoticeActionCatalog.contains(event) ? BusinessNoticeActionCatalog.eligible(event,permissions)
                : eligible(event, permissions, Set.of());
    }

    private static Set<String> eligibleEvents(Set<String> permissions) {
        return ReviewNoticeCatalog.events().stream()
                .filter(event -> eligible(event, permissions, Set.of(), false))
                .collect(Collectors.toUnmodifiableSet());
    }

    static boolean eligible(String event, Set<String> permissions, Set<String> departments) {
        return eligible(event, permissions, departments, false);
    }

    /**
     * @param warehouseParticipant 部门外登记的仓库负责人或仓储部门负责人: 仓库类待办与仓储部门成员同等对待
     */
    static boolean eligible(String event, Set<String> permissions, Set<String> departments,
                            boolean warehouseParticipant) {
        if (!permissions.contains("notice:read")) return false;
        return switch (event) {
            case "SALES_SHIPMENT_PENDING_FINANCE_AUDIT" -> permissions.contains("sales_shipment_finance:view")
                    && any(permissions, "sales_shipment_finance:approve", "sales_shipment_finance:reject");
            case "SALES_SHIPMENT_PENDING_PICK" -> permissions.containsAll(Set.of("warehouse_sales_outbound:view", "warehouse_sales_outbound:execute"));
            case "SALES_SHIPMENT_FINANCE_REJECTED" -> permissions.containsAll(Set.of("sales_shipment:view","sales_shipment:edit"));
            case "DIRECT_CUSTOMER_SHIPMENT_FINANCE_REJECTED" -> permissions.containsAll(Set.of("sales_other_shipment:view","sales_other_shipment:edit"));
            case "SALES_ORDER_PENDING_FINANCE_CONFIRM" ->
                    permissions.containsAll(Set.of("sales_order_finance:view", "sales_order_finance:confirm"));
            case "SALES_QUOTE_PENDING_FINANCE_REVIEW" ->
                    permissions.containsAll(Set.of("sales_quote_finance:view", "sales_quote_finance:confirm"));
            case "PROCUREMENT_FINANCE_SUBMITTED", "PROCUREMENT_FINANCE_CHANGE_SUBMITTED" ->
                    permissions.contains("finance_order_approval:view")
                    && any(permissions, "finance_order_approval:approve", "finance_order_approval:reject");
            case "PROCUREMENT_IQC_PENDING" ->
                    permissions.containsAll(Set.of("procurement_inspection:view", "procurement_inspection:handle"));
            case "SALES_ORDER_APPROVED" ->
                    permissions.containsAll(Set.of("production_material_analysis:view", "production_material_analysis:create"));
            case "PRODUCTION_OVER_LIMIT_PENDING", "PRODUCTION_OVERPRODUCTION_RATE_SUBMITTED", "PRODUCTION_MATERIAL_INCREMENT_SUBMITTED" ->
                    permissions.contains("production_plan:approve");
            // ADR-143 委外可领料：收件人在发卡时已按订货单归属可见范围精确算好(不限部门)，这里复核
            // 「现在还能不能领料」。
            case "SUBCONTRACT_DRAW_AVAILABLE" ->
                    permissions.containsAll(Set.of("subcontract_order:view", "subcontract_order:draw"));
            // 委外申请可下单：复核当前是否仍能查看申请并生成委外订货单。
            case "SUBCONTRACT_ORDER_KIT_READY" ->
                    permissions.containsAll(Set.of("subcontract_application:view", "subcontract_order:create", "subcontract_order:decompose"));
            case "SUBCONTRACT_SHORT_DELIVERY_DETECTED", "SUBCONTRACT_SHORT_DELIVERY_WAIT_OVERDUE" ->
                    permissions.containsAll(Set.of("subcontract_order:view", "subcontract_short_delivery:decide"));
            // 委外领料草稿待发料：草稿所在仓库的仓管(发卡时已按仓分发; ADR-149 部门外登记的负责人同等弹卡)。
            case "SUBCONTRACT_OUTBOUND_READY" -> permissions.containsAll(Set.of("subcontract_outbound:view", "subcontract_outbound:execute"));
            case WORKSHOP_EVENT -> canHandleWorkshop(permissions);
            // ADR-117 车间催计划：能在物料分析页下单的人(下达采购委外或下达车间)。收件人在发卡时已按
            // 当前动作权限 + 制单计划员 + 分析可见范围精确算好，这里只复核当前动作权限。
            case "PRODUCTION_PLANNING_URGED" -> permissions.contains("production_material_analysis:view")
                    && any(permissions, "production_material_analysis:notify", "production_material_analysis:generate");
            case "PROCUREMENT_IQC_STOCK_IN_PENDING" -> permissions.containsAll(Set.of("warehouse_iqc_stock_in:view", "warehouse_iqc_stock_in:confirm"));
            case "PRODUCTION_DRAW_PENDING", "PRODUCTION_MATERIAL_DISCOVERY_PENDING" -> permissions.containsAll(Set.of("stock_doc:view", "stock_doc:approve", "stock_doc:issue"));
            case "PROCUREMENT_FINANCE_APPROVED" -> permissions.containsAll(Set.of("warehouse_inbound:view", "warehouse_inbound:stock_in"));
            case "SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP" ->
                    permissions.containsAll(Set.of("sales_order:view", "sales_shipment:view", "sales_shipment:create"));
            case "PROCUREMENT_IQC_REJECTION_OPENED" ->
                    permissions.containsAll(Set.of("procurement_iqc_rejection:view", "procurement_iqc_rejection:record_return"));
            case "PROCUREMENT_IQC_REJECTION_RETURNED" -> permissions.contains("procurement_iqc_rejection:view")
                    && (permissions.containsAll(Set.of("procurement_iqc_rejection:confirm_credit", "procurement_iqc_rejection:amount:view"))
                        || permissions.contains("procurement_iqc_rejection:close_no_credit"));
            // ===== 2026-09-09 人事域（HrNoticeService）：职能权限判定，不限定部门子树
            // （ADR-063 2026-09-10 修订明示的例外：HR/财务/回复职能可跨部门）=====
            case "PROFILE_CHANGE_SUBMITTED" -> permissions.contains("profile:review");
            case "VISITOR_APPLY_SUBMITTED" -> permissions.contains("visitor:approve");
            case "VISITOR_HOST_CONFIRM_REQUIRED" -> permissions.contains("visitor:host_confirm");
            case "EXPENSE_CLAIM_SUBMITTED" -> permissions.contains("expense:approve");
            case "EXPENSE_CLAIM_PENDING_PAYMENT" -> permissions.contains("expense:pay");
            case "EXPENSE_CLAIM_REJECTED" -> permissions.contains("expense:apply");
            case "PAYROLL_BATCH_SUBMITTED" -> permissions.contains("payroll:review");
            case "PAYROLL_BATCH_PENDING_PUBLISH" -> permissions.contains("payroll:publish");
            case "WEBSITE_INQUIRY_NEW" -> permissions.containsAll(Set.of("webinquiry:view","webinquiry:claim"));
            case "SUGGESTION_SUBMITTED" -> permissions.containsAll(Set.of("suggestion:submit", "suggestion:reply"));
            case "STOCK_COUNT_PENDING_FINANCE_REVIEW" -> permissions.contains("stock:count:finance_review");
            case "STOCK_COUNT_PENDING_WAREHOUSE_REVIEW" -> permissions.contains("stock:count:warehouse_review");
            // ===== ADR-131 车间内料仓 (WorkshopMaterialNoticeService): 收件人在发卡时已按对象范围精确算好
            // (领料单预填叶仓的仓管 / 该车间的报工审核人与这些草稿的制单人 / BOM 维护人 / 内料仓所在主仓的仓管
            // 与本车间的认料人 / 设置负责人), 这里在弹卡时复核「现在还能不能动手」: 发卡时凭的那件事的动手权限
            // 要还在 (与发卡同一口径, 只看动手权限); 具体车间、仓库及制单人范围由发卡侧约束。=====
            case "WORKSHOP_MATERIAL_REQUISITION_PENDING", "WORKSHOP_MATERIAL_RETURN_PENDING" ->
                    permissions.containsAll(Set.of("workshop_material:view", "workshop_material:issue"));
            // 审核人审; 制单人删掉或改好自己的草稿 (审核人删不了别人的草稿)。
            case "WORKSHOP_MATERIAL_CLOSE_BLOCKED_REPORT" -> permissions.contains("production_daily_report:view")
                    && any(permissions, "production_daily_report:approve", "production_daily_report:edit", "production_daily_report:delete");
            case "WORKSHOP_MATERIAL_CLOSE_BLOCKED_WEIGHT" -> permissions.containsAll(Set.of("goods:view", "goods:bom:edit"));
            case "WORKSHOP_MATERIAL_CLOSE_BLOCKED_STOCK" -> permissions.contains("workshop_material:view")
                    && any(permissions, "workshop_material:issue", "workshop_material:choose");
            case "WORKSHOP_MATERIAL_CLOSE_FAILING" -> permissions.containsAll(Set.of("workshop_material:view", "workshop_material:setup"));
            default -> false;
        };
    }

    private static boolean any(Set<String> values, String... candidates) {
        return java.util.Arrays.stream(candidates).anyMatch(values::contains);
    }
}
