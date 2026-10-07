package com.uten.imp.features.notice;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.Set;
import java.util.UUID;
import java.util.LinkedHashSet;
import java.util.stream.Collectors;

/** Current department membership and action authority govern actionable reminders. */
@Component
@RequiredArgsConstructor
public class ReviewNoticeAudience {
    private final JdbcTemplate jdbc;
    private final OwnerVisibility ownerVisibility;

    static final String WORKSHOP_EVENT = "PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED";
    static final String OVER_LIMIT_EVENT = "PRODUCTION_OVER_LIMIT_PENDING";
    /** 仓库类待办(销售待拣货、IQC 待入库、生产待领料/领料发现、采购财务通过)的动手权限。 */
    private static final String[] WAREHOUSE_ACTION_PERMISSIONS = {
            "warehouse_sales_outbound:execute", "warehouse_iqc_stock_in:confirm", "stock_doc:issue",
            "warehouse_inbound:stock_in", "subcontract_outbound:execute"};
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
                            boolean overLimitSeeAll, String overLimitOwners) {
        static final ReadScope NONE = new ReadScope(WorkshopScope.NONE, false, false, "");
    }

    public ReadScope readScope(AuthUser user) {
        WorkshopScope workshop = workshopScope(user);
        if (user == null || user.isVisitor() || user.getEmployeeId() == null
                || !user.getPermissions().contains("notice:read")
                || !(user.isSuperAdmin() || user.getPermissions().contains("production_plan:approve"))) {
            return new ReadScope(workshop, false, false, "");
        }
        // Same canonical owner scope as ProductionDocumentAccessPolicy, including handover and employment generations.
        var owners = ownerVisibility.evaluate("production_plan", "production_plan:view:all");
        return new ReadScope(workshop, true, owners.seeAll(), owners.visibleOwners().stream()
                .map(UUID::toString).sorted().collect(Collectors.joining(",")));
    }

    static boolean canHandleWorkshop(Set<String> permissions) {
        return permissions != null && permissions.containsAll(Set.of("notice:read", "production_execution:view"))
                && (permissions.contains("production_execution:start")
                    || permissions.containsAll(Set.of("production_daily_report:view", "production_daily_report:create")));
    }

    /** Reverse of the sender's current leadership scope; old member cards lose visibility too. */
    public WorkshopScope workshopScope(AuthUser user) {
        if (user == null || user.isVisitor() || user.getEmployeeId() == null
                || !canHandleWorkshop(user.getPermissions())) return WorkshopScope.NONE;
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

    /** One membership query per feed/status request, never one query per notice. */
    public Set<String> eligibleEvents(AuthUser user) {
        if (user == null || user.isVisitor() || user.getEmployeeId() == null
                || !user.getPermissions().contains("notice:read")) return Set.of();
        Set<String> departments = Set.copyOf(jdbc.queryForList("""
                WITH RECURSIVE memberships(id) AS (
                    SELECT employee.department_id FROM employees employee
                    WHERE employee.id = ? AND employee.is_deleted = FALSE
                      AND employee.status IN ('active','probation','onLeave')
                    UNION
                    SELECT secondary.department_id
                    FROM employee_secondary_departments secondary
                    JOIN employees employee ON employee.id = secondary.employee_id
                    WHERE employee.id = ? AND employee.is_deleted = FALSE
                      AND employee.status IN ('active','probation','onLeave')
                ), ancestry(id, parent_id, code) AS (
                    SELECT d.id, d.parent_id, d.code FROM departments d
                    JOIN memberships m ON m.id = d.id WHERE d.is_deleted = FALSE
                    UNION
                    SELECT d.id, d.parent_id, d.code FROM departments d
                    JOIN ancestry a ON a.parent_id = d.id WHERE d.is_deleted = FALSE
                ) SELECT DISTINCT code FROM ancestry
                """, String.class, user.getEmployeeId(), user.getEmployeeId()));
        // ADR-149: 部门外登记的仓库负责人与仓储部门负责人是仓库任务的参与者, 仓库类通知池按仓纳入了他们,
        // 弹卡资格同口径(否则发给部门外负责人的待办只在通知列表里, 不弹卡)。只有部门外、又持有仓库待办动手权限的人
        // 才需要多问这一次。
        boolean warehouseParticipant = !departments.contains("SUB_WH")
                && any(user.getPermissions(), WAREHOUSE_ACTION_PERMISSIONS)
                && Boolean.TRUE.equals(jdbc.queryForObject(
                        "SELECT CAST(? AS uuid) = ANY(fn_warehouse_responsible_user_ids())", Boolean.class, user.getId()));
        return ReviewNoticeCatalog.events().stream()
                .filter(event -> eligible(event, user.getPermissions(), departments, warehouseParticipant))
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
        boolean warehouseSide = departments.contains("SUB_WH") || warehouseParticipant;
        return switch (event) {
            case "SALES_SHIPMENT_PENDING_FINANCE_AUDIT" -> departments.contains("DEPT_FIN") && permissions.contains("sales_shipment_finance:approve");
            case "SALES_SHIPMENT_PENDING_PICK" -> warehouseSide && permissions.contains("warehouse_sales_outbound:execute");
            case "SALES_SHIPMENT_FINANCE_REJECTED" -> any(departments,"DEPT_SALES","DEPT_RAIL") && permissions.containsAll(Set.of("sales_shipment:view","sales_shipment:edit"));
            case "DIRECT_CUSTOMER_SHIPMENT_FINANCE_REJECTED" -> any(departments,"DEPT_SALES","DEPT_RAIL") && permissions.containsAll(Set.of("sales_other_shipment:view","sales_other_shipment:edit"));
            case "SALES_ORDER_PENDING_FINANCE_CONFIRM" -> departments.contains("DEPT_FIN")
                    && permissions.containsAll(Set.of("sales_order_finance:view", "sales_order_finance:confirm"));
            // ADR-134 报价核价: 与核价人资格同口径(财务部门子树 + 查看 + 确认)。
            case "SALES_QUOTE_PENDING_FINANCE_REVIEW" -> departments.contains("DEPT_FIN")
                    && permissions.containsAll(Set.of("sales_quote_finance:view", "sales_quote_finance:confirm"));
            case "PROCUREMENT_FINANCE_SUBMITTED", "PROCUREMENT_FINANCE_CHANGE_SUBMITTED" ->
                    departments.contains("DEPT_FIN") && permissions.contains("finance_order_approval:view")
                    && any(permissions, "finance_order_approval:approve", "finance_order_approval:reject");
            case "PROCUREMENT_IQC_PENDING" -> departments.contains("DEPT_QA")
                    && permissions.containsAll(Set.of("procurement_inspection:view", "procurement_inspection:handle"));
            case "SALES_ORDER_APPROVED" -> departments.contains("SUB_PLAN")
                    && permissions.containsAll(Set.of("production_material_analysis:view", "production_material_analysis:create"));
            case "PRODUCTION_OVER_LIMIT_PENDING", "PRODUCTION_OVERPRODUCTION_RATE_SUBMITTED", "PRODUCTION_MATERIAL_INCREMENT_SUBMITTED" ->
                    departments.contains("SUB_PLAN") && permissions.contains("production_plan:approve");
            // ADR-143 委外可领料：收件人在发卡时已按订货单归属可见范围精确算好(不限部门)，这里复核
            // 「现在还能不能领料」。
            case "SUBCONTRACT_DRAW_AVAILABLE" ->
                    permissions.containsAll(Set.of("subcontract_order:view", "subcontract_order:draw"));
            // ADR-156 委外申请可下单：收件人在发卡时已按采购委外部门算好，这里复核「现在还能不能生成委外订货单」。
            case "SUBCONTRACT_ORDER_KIT_READY" ->
                    permissions.containsAll(Set.of("subcontract_application:view", "subcontract_order:decompose"));
            // 委外领料草稿待发料：草稿所在仓库的仓管(发卡时已按仓分发; ADR-149 部门外登记的负责人同等弹卡)。
            case "SUBCONTRACT_OUTBOUND_READY" -> warehouseSide
                    && permissions.containsAll(Set.of("subcontract_outbound:view", "subcontract_outbound:execute"));
            case WORKSHOP_EVENT -> canHandleWorkshop(permissions);
            // ADR-117 车间催计划：能在物料分析页下单的人(下达采购委外或下达车间)。收件人在发卡时已按
            // 计划 / 生产部门池 + 制单计划员 + 分析可见范围精确算好，这里不再卡部门(制单人不在池里也要弹)。
            case "PRODUCTION_PLANNING_URGED" -> permissions.contains("production_material_analysis:view")
                    && any(permissions, "production_material_analysis:notify", "production_material_analysis:generate");
            case "PROCUREMENT_IQC_STOCK_IN_PENDING" -> warehouseSide
                    && permissions.containsAll(Set.of("warehouse_iqc_stock_in:view", "warehouse_iqc_stock_in:confirm"));
            case "PRODUCTION_DRAW_PENDING", "PRODUCTION_MATERIAL_DISCOVERY_PENDING" -> warehouseSide
                    && permissions.containsAll(Set.of("stock_doc:view", "stock_doc:approve", "stock_doc:issue"));
            case "PROCUREMENT_FINANCE_APPROVED" -> warehouseSide
                    && permissions.containsAll(Set.of("warehouse_inbound:view", "warehouse_inbound:stock_in"));
            case "SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP" -> any(departments, "DEPT_SALES", "DEPT_RAIL")
                    && permissions.containsAll(Set.of("sales_order:view", "sales_shipment:create"));
            case "PROCUREMENT_IQC_REJECTION_OPENED" -> any(departments, "SUB_WH", "SUB_PURCHASE", "DEPT_SALES")
                    && permissions.containsAll(Set.of("procurement_iqc_rejection:view", "procurement_iqc_rejection:record_return"));
            case "PROCUREMENT_IQC_REJECTION_RETURNED" -> departments.contains("DEPT_FIN")
                    && permissions.contains("procurement_iqc_rejection:view")
                    && any(permissions, "procurement_iqc_rejection:confirm_credit", "procurement_iqc_rejection:close_no_credit");
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
            case "SUGGESTION_SUBMITTED" -> permissions.contains("suggestion:reply");
            case "STOCK_COUNT_PENDING_FINANCE_REVIEW" -> permissions.contains("stock:count:finance_review");
            case "STOCK_COUNT_PENDING_WAREHOUSE_REVIEW" -> permissions.contains("stock:count:warehouse_review");
            // ===== ADR-131 车间内料仓 (WorkshopMaterialNoticeService): 收件人在发卡时已按对象范围精确算好
            // (领料单预填叶仓的仓管 / 该车间的报工审核人与这些草稿的制单人 / BOM 维护人 / 内料仓所在主仓的仓管
            // 与本车间的认料人 / 设置负责人), 这里在弹卡时复核「现在还能不能动手」: 发卡时凭的那件事的动手权限
            // 要还在 (与发卡同一口径, 只看动手权限); 车间认料人另要求仍在生产部子树 (调离生产部的人不再弹车间的活)。=====
            case "WORKSHOP_MATERIAL_REQUISITION_PENDING", "WORKSHOP_MATERIAL_RETURN_PENDING" ->
                    permissions.contains("workshop_material:issue");
            // 审核人审; 制单人删掉或改好自己的草稿 (审核人删不了别人的草稿)。
            case "WORKSHOP_MATERIAL_CLOSE_BLOCKED_REPORT" -> any(permissions, "production_daily_report:approve",
                    "production_daily_report:create", "production_daily_report:edit", "production_daily_report:delete");
            case "WORKSHOP_MATERIAL_CLOSE_BLOCKED_WEIGHT" -> permissions.contains("goods:bom:edit");
            case "WORKSHOP_MATERIAL_CLOSE_BLOCKED_STOCK" -> permissions.contains("workshop_material:issue")
                    || (permissions.contains("workshop_material:choose") && departments.contains("DEPT_PROD"));
            case "WORKSHOP_MATERIAL_CLOSE_FAILING" -> permissions.contains("workshop_material:setup");
            default -> false;
        };
    }

    private static boolean any(Set<String> values, String... candidates) {
        return java.util.Arrays.stream(candidates).anyMatch(values::contains);
    }
}
