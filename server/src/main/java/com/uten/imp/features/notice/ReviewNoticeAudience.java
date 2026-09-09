package com.uten.imp.features.notice;

import com.uten.imp.security.AuthUser;
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

    static final String WORKSHOP_EVENT = "PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED";
    private static final UUID NO_EMPLOYEE = new UUID(0, 0);

    /** Bounded organization scope, never a list of all execution segments. */
    public record WorkshopScope(boolean allowed, UUID employeeId, Set<UUID> departmentIds) {
        static final WorkshopScope NONE = new WorkshopScope(false, NO_EMPLOYEE, Set.of(NO_EMPLOYEE));
        public WorkshopScope {
            departmentIds = departmentIds.isEmpty() ? Set.of(NO_EMPLOYEE) : Set.copyOf(departmentIds);
        }
    }

    static boolean canHandleWorkshop(Set<String> permissions) {
        return permissions != null && permissions.containsAll(Set.of("notice:read", "production_execution:view"))
                && (permissions.contains("production_execution:start")
                    || permissions.containsAll(Set.of("production_daily_report:view", "production_daily_report:create")));
    }

    /** Reverse of the sender's workshop subtree membership, checked once per request. */
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
                ), memberships(id) AS (
                    SELECT department_id FROM active_employee
                    UNION SELECT secondary.department_id FROM employee_secondary_departments secondary
                        JOIN active_employee employee ON employee.id=secondary.employee_id
                    UNION SELECT department.id FROM departments department
                        JOIN active_employee employee ON employee.id=department.manager_id
                        WHERE department.is_deleted=FALSE
                ), ancestry(id,parent_id) AS (
                    SELECT department.id,department.parent_id FROM departments department
                    JOIN memberships member ON member.id=department.id WHERE department.is_deleted=FALSE
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
        return ReviewNoticeCatalog.events().stream()
                .filter(event -> eligible(event, user.getPermissions(), departments))
                .collect(Collectors.toUnmodifiableSet());
    }

    static boolean eligible(String event, Set<String> permissions, Set<String> departments) {
        if (!permissions.contains("notice:read")) return false;
        return switch (event) {
            case "SALES_SHIPMENT_PENDING_FINANCE_AUDIT" -> departments.contains("DEPT_FIN") && permissions.contains("finance_shipment_audit");
            case "SALES_SHIPMENT_PENDING_PICK" -> departments.contains("SUB_WH") && permissions.contains("sales_shipment:warehouse-work");
            case "SALES_SHIPMENT_FINANCE_REJECTED" -> any(departments,"DEPT_SALES","DEPT_RAIL") && permissions.containsAll(Set.of("sales_shipment:view","sales_shipment:edit"));
            case "DIRECT_CUSTOMER_SHIPMENT_FINANCE_REJECTED" -> any(departments,"DEPT_SALES","DEPT_RAIL") && permissions.containsAll(Set.of("sales_other_shipment:view","sales_other_shipment:edit"));
            case "SALES_ORDER_PENDING_FINANCE_CONFIRM" -> departments.contains("DEPT_FIN")
                    && permissions.containsAll(Set.of("sales_order_finance:view", "sales_order_finance:confirm"));
            case "PROCUREMENT_FINANCE_SUBMITTED", "PROCUREMENT_FINANCE_CHANGE_SUBMITTED" ->
                    departments.contains("DEPT_FIN") && permissions.contains("finance_order_approval:view")
                    && any(permissions, "finance_order_approval:approve", "finance_order_approval:reject");
            case "PROCUREMENT_IQC_PENDING" -> departments.contains("DEPT_QA")
                    && permissions.containsAll(Set.of("procurement_inspection:view", "procurement_inspection:handle"));
            case "SALES_ORDER_APPROVED" -> departments.contains("SUB_PLAN")
                    && permissions.containsAll(Set.of("production_material_analysis:view", "production_material_analysis:create"));
            case "SUBCONTRACT_PREPARATION_REQUIRED", "SUBCONTRACT_ORDER_PREPARATION_DISPATCHED" ->
                    any(departments, "SUB_PLAN", "DEPT_PROD")
                    && permissions.contains("production_material_analysis:view")
                    && any(permissions, "production_material_analysis:route", "production_material_analysis:generate");
            case WORKSHOP_EVENT -> canHandleWorkshop(permissions);
            case "PROCUREMENT_IQC_STOCK_IN_PENDING" -> departments.contains("SUB_WH")
                    && permissions.containsAll(Set.of("warehouse_iqc_stock_in:view", "warehouse_iqc_stock_in:confirm"));
            case "PRODUCTION_DRAW_PENDING" -> departments.contains("SUB_WH")
                    && permissions.containsAll(Set.of("stock_doc:view", "stock_doc:approve", "stock_doc:issue"));
            case "PROCUREMENT_FINANCE_APPROVED" -> departments.contains("SUB_WH")
                    && permissions.containsAll(Set.of("warehouse_inbound:view", "warehouse_inbound:stock_in"));
            case "SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP" -> any(departments, "DEPT_SALES", "DEPT_RAIL")
                    && permissions.containsAll(Set.of("sales_order:view", "sales_shipment:create"));
            case "PROCUREMENT_IQC_REJECTION_OPENED" -> any(departments, "SUB_WH", "SUB_PURCHASE", "DEPT_SALES")
                    && permissions.containsAll(Set.of("procurement_iqc_rejection:view", "procurement_iqc_rejection:record_return"));
            case "PROCUREMENT_IQC_REJECTION_RETURNED" -> departments.contains("DEPT_FIN")
                    && permissions.contains("procurement_iqc_rejection:view")
                    && any(permissions, "procurement_iqc_rejection:confirm_credit", "procurement_iqc_rejection:close_no_credit");
            default -> false;
        };
    }

    private static boolean any(Set<String> values, String... candidates) {
        return java.util.Arrays.stream(candidates).anyMatch(values::contains);
    }
}
