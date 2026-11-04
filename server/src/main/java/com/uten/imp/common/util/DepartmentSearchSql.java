package com.uten.imp.common.util;

/** Search-only organization paths shared by authorized employee candidate directories. */
public final class DepartmentSearchSql {
    private DepartmentSearchSql() { }

    public static String name(String departmentNameExpression) {
        return "COALESCE(employee_department_path.names," + departmentNameExpression + ")";
    }

    public static String prefix(boolean searched) {
        if (!searched) return "";
        // Build the small organization tree once per read, rather than walking ancestors per employee/word.
        return """
                WITH RECURSIVE employee_department_paths(id,names,visited) AS (
                    SELECT department.id, department.name::text, ARRAY[department.id]
                    FROM departments department
                    WHERE department.parent_id IS NULL AND NOT department.is_deleted
                    UNION ALL
                    SELECT child.id, parent.names || ' / ' || child.name, parent.visited || child.id
                    FROM departments child
                    JOIN employee_department_paths parent ON child.parent_id=parent.id
                    WHERE NOT child.is_deleted AND NOT child.id=ANY(parent.visited)
                )
                """;
    }

    /** Expressions are fixed application-owned SQL, never request values. */
    public static String joins(boolean searched, String employeeDepartmentExpression) {
        return searched ? " LEFT JOIN employee_department_paths employee_department_path ON employee_department_path.id="
                + employeeDepartmentExpression + "\n" : "";
    }
}
