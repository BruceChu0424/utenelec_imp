package com.uten.imp.security;

/** Shared task assignment predicate for workshop lists and exact material operations. */
public final class ProductionWorkshopAssignmentScope {
    private ProductionWorkshopAssignmentScope() {}

    /**
     * Caller binds employeeId. Alias is an internal SQL identifier, never request input.
     *
     * <p>A task is assigned when the active employee is its responsible person, or when one of the
     * employee's primary, secondary or managed (non-deleted) departments lies in the task workshop's
     * subtree: the workshop itself plus descendants reached through non-deleted children. The
     * workshops whose subtree holds such a department are the department itself plus the parents
     * reached upward from each non-deleted node, so that set is resolved once per statement as an
     * uncorrelated subquery instead of one recursive department walk per task row.
     */
    public static String predicate(String alias) {
        if (alias == null || !alias.matches("[a-zA-Z_][a-zA-Z0-9_]*")) {
            throw new IllegalArgumentException("Invalid internal task alias");
        }
        return """
                COALESCE((
                    (%1$s.responsible_employee_id=:employeeId AND EXISTS (
                        SELECT 1 FROM employees assignment_employee
                        WHERE assignment_employee.id=:employeeId AND assignment_employee.is_deleted=FALSE
                          AND assignment_employee.status IN ('active','probation','onLeave')))
                    OR %1$s.workshop_department_id IN (
                        WITH RECURSIVE assignment_departments(id) AS (
                            SELECT assignment_employee.department_id FROM employees assignment_employee
                            WHERE assignment_employee.id=:employeeId AND assignment_employee.is_deleted=FALSE
                              AND assignment_employee.status IN ('active','probation','onLeave')
                              AND assignment_employee.department_id IS NOT NULL
                            UNION
                            SELECT secondary.department_id FROM employee_secondary_departments secondary
                            JOIN employees assignment_employee ON assignment_employee.id=secondary.employee_id
                            WHERE assignment_employee.id=:employeeId AND assignment_employee.is_deleted=FALSE
                              AND assignment_employee.status IN ('active','probation','onLeave')
                              AND secondary.department_id IS NOT NULL
                            UNION
                            SELECT managed.id FROM departments managed
                            JOIN employees assignment_employee ON assignment_employee.id=managed.manager_id
                            WHERE assignment_employee.id=:employeeId AND assignment_employee.is_deleted=FALSE
                              AND assignment_employee.status IN ('active','probation','onLeave')
                              AND managed.is_deleted=FALSE
                        ), assignment_workshops(id) AS (
                            SELECT id FROM assignment_departments
                            UNION
                            SELECT department.parent_id FROM assignment_workshops reached
                            JOIN departments department ON department.id=reached.id
                            WHERE department.is_deleted=FALSE AND department.parent_id IS NOT NULL
                        )
                        SELECT id FROM assignment_workshops)
                ), FALSE)
                """.formatted(alias);
    }
}
