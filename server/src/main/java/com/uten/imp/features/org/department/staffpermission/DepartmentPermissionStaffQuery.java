package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.features.org.department.staffpermission
        .OrganizationPermissionManagementScopeService.StaffSearchAuthority;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.UUID;

/** Bounded, server-filtered employee projection for the permission workspace. */
@Repository
@RequiredArgsConstructor
public class DepartmentPermissionStaffQuery {

    private static final String CURRENT_FROM_FILTER = """
            FROM employees employee
            JOIN departments department ON department.id = employee.department_id
            LEFT JOIN positions position ON position.id = employee.position_id
            WHERE employee.is_deleted = FALSE
              AND employee.status IN ('active', 'probation', 'onLeave')
              AND department.is_deleted = FALSE
              AND department.level IN ('管理中心', '一级部门', '二级班组', '三级科室')
            """;

    private final JdbcTemplate jdbc;

    public Result query(
            StaffSearchAuthority authority,
            UUID selectedDepartmentId,
            UUID excludedEmployeeId,
            String search,
            int requestedPage,
            int requestedSize) {
        int page = Math.max(1, requestedPage);
        int size = Math.min(Math.max(1, requestedSize), 50);
        String normalized = search == null ? "" : search.trim();
        boolean hasSearch = !normalized.isEmpty();

        List<Object> parameters = new ArrayList<>();
        String cte = scopeCte(authority, selectedDepartmentId, parameters);
        StringBuilder filter = scopedFilter(authority, selectedDepartmentId);
        if (excludedEmployeeId != null) {
            filter.append(" AND employee.id <> ?\n");
            parameters.add(excludedEmployeeId);
        }
        if (hasSearch) {
            filter.append("""
                      AND (
                          lower(employee.code) LIKE ? ESCAPE '!'
                          OR lower(employee.full_name) LIKE ? ESCAPE '!'
                      )
                    """);
            String pattern = "%" + escapeLike(normalized.toLowerCase(Locale.ROOT)) + "%";
            parameters.add(pattern);
            parameters.add(pattern);
        }

        Long count = jdbc.queryForObject(
                cte + "SELECT count(*) " + filter,
                Long.class,
                parameters.toArray());
        long total = count == null ? 0L : count;

        List<Object> pageParameters = new ArrayList<>(parameters);
        pageParameters.add(size);
        pageParameters.add((long) (page - 1) * size);
        List<StaffProjection> rows = jdbc.query(
                cte
                        + """
                        SELECT employee.id,
                               employee.code,
                               employee.full_name,
                               department.id AS department_id,
                               department.name AS department_name,
                               position.name AS position_name,
                               (department.manager_id = employee.id) AS department_manager
                        """
                        + filter
                        + """
                        ORDER BY employee.full_name, employee.code, employee.id
                        LIMIT ? OFFSET ?
                        """,
                (rs, rowNum) -> new StaffProjection(
                        rs.getObject("id", UUID.class),
                        rs.getString("code"),
                        rs.getString("full_name"),
                        rs.getObject("department_id", UUID.class),
                        rs.getString("department_name"),
                        rs.getString("position_name"),
                        rs.getBoolean("department_manager")),
                pageParameters.toArray());
        int totalPages = total == 0L ? 0 : (int) Math.ceil((double) total / size);
        return new Result(List.copyOf(rows), page, size, total, totalPages);
    }

    private String scopeCte(
            StaffSearchAuthority authority,
            UUID selectedDepartmentId,
            List<Object> parameters) {
        if (authority == null) {
            throw new IllegalArgumentException("staff search authority is required");
        }
        List<String> ctes = new ArrayList<>();
        switch (authority.scope()) {
            case SUPER_ADMIN_COMPANY -> {
            }
            case EXECUTIVE_OFFICE_COMPANY -> {
                requireManagerEmployee(authority);
                ctes.add("""
                        company_authority AS (
                            SELECT office.id
                            FROM departments office
                            JOIN departments company ON company.id = office.parent_id
                            JOIN employees manager ON manager.id = ?
                            WHERE office.code = 'GM'
                              AND office.manager_id = manager.id
                              AND office.is_deleted = false
                              AND office.level IN ('管理中心', '一级部门', '二级班组', '三级科室')
                              AND manager.department_id = office.id
                              AND manager.is_deleted = false
                              AND manager.status IN ('active', 'probation', 'onLeave')
                              AND company.is_deleted = false
                              AND company.level = '公司'
                              AND company.parent_id IS NULL
                        )
                        """);
                parameters.add(authority.managerEmployeeId());
            }
            case MANAGER_SUBTREES -> {
                requireManagerEmployee(authority);
                ctes.add("""
                        authorized_departments(id) AS (
                            SELECT root.id
                            FROM departments root
                            JOIN employees manager ON manager.id = ?
                            WHERE root.manager_id = manager.id
                              AND root.is_deleted = false
                              AND root.code <> 'GM'
                              AND root.level IN ('管理中心', '一级部门', '二级班组', '三级科室')
                              AND manager.is_deleted = false
                              AND manager.status IN ('active', 'probation', 'onLeave')
                            UNION
                            SELECT child.id
                            FROM departments child
                            JOIN authorized_departments parent
                              ON child.parent_id = parent.id
                            WHERE child.is_deleted = false
                        )
                        """);
                parameters.add(authority.managerEmployeeId());
            }
        }
        if (selectedDepartmentId != null) {
            ctes.add("""
                    selected_departments(id) AS (
                        SELECT selected.id
                        FROM departments selected
                        WHERE selected.id = ?
                          AND selected.is_deleted = false
                        UNION
                        SELECT child.id
                        FROM departments child
                        JOIN selected_departments parent
                          ON child.parent_id = parent.id
                        WHERE child.is_deleted = false
                    )
                    """);
            parameters.add(selectedDepartmentId);
        }
        return ctes.isEmpty()
                ? ""
                : "WITH RECURSIVE " + String.join(",\n", ctes) + "\n";
    }

    private StringBuilder scopedFilter(
            StaffSearchAuthority authority,
            UUID selectedDepartmentId) {
        StringBuilder filter = new StringBuilder(CURRENT_FROM_FILTER);
        switch (authority.scope()) {
            case SUPER_ADMIN_COMPANY -> {
            }
            case EXECUTIVE_OFFICE_COMPANY -> filter.append(
                    " AND EXISTS (SELECT 1 FROM company_authority)\n");
            case MANAGER_SUBTREES -> filter.append(
                    " AND department.id IN (SELECT id FROM authorized_departments)\n");
        }
        if (selectedDepartmentId != null) {
            filter.append(
                    " AND department.id IN (SELECT id FROM selected_departments)\n");
        }
        return filter;
    }

    private void requireManagerEmployee(StaffSearchAuthority authority) {
        if (authority.managerEmployeeId() == null) {
            throw new IllegalArgumentException(
                    "manager employee is required for organization scope");
        }
    }

    private static String escapeLike(String value) {
        return value
                .replace("!", "!!")
                .replace("%", "!%")
                .replace("_", "!_");
    }

    public record StaffProjection(
            UUID employeeId,
            String code,
            String fullName,
            UUID departmentId,
            String departmentName,
            String positionName,
            boolean departmentManager) {
    }

    public record Result(
            List<StaffProjection> staff,
            int page,
            int size,
            long total,
            int totalPages) {
    }
}
