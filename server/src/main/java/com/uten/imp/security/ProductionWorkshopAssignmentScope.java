package com.uten.imp.security;

/** Shared task assignment predicate for workshop lists and exact material operations. */
public final class ProductionWorkshopAssignmentScope {
    private ProductionWorkshopAssignmentScope() {}

    /** Caller binds employeeId. Alias is an internal SQL identifier, never request input. */
    public static String predicate(String alias) {
        if (alias == null || !alias.matches("[a-zA-Z_][a-zA-Z0-9_]*")) {
            throw new IllegalArgumentException("Invalid internal task alias");
        }
        return """
                EXISTS (
                    WITH RECURSIVE workshop_tree(id) AS (
                        SELECT %1$s.workshop_department_id WHERE %1$s.workshop_department_id IS NOT NULL
                        UNION ALL
                        SELECT child.id FROM departments child JOIN workshop_tree parent ON child.parent_id=parent.id
                        WHERE child.is_deleted=FALSE
                    )
                    SELECT 1 FROM employees employee
                    LEFT JOIN employee_secondary_departments secondary ON secondary.employee_id=employee.id
                    WHERE employee.id=:employeeId AND employee.is_deleted=FALSE
                      AND employee.status IN ('active','probation','onLeave')
                      AND (%1$s.responsible_employee_id=employee.id
                           OR employee.department_id IN (SELECT id FROM workshop_tree)
                           OR secondary.department_id IN (SELECT id FROM workshop_tree)
                           OR EXISTS (SELECT 1 FROM departments managed WHERE managed.id IN (SELECT id FROM workshop_tree)
                                      AND managed.manager_id=employee.id AND managed.is_deleted=FALSE))
                )
                """.formatted(alias);
    }
}
