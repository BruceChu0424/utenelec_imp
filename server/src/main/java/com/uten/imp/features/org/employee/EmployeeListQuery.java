package com.uten.imp.features.org.employee;

import com.uten.imp.features.org.employee.dto.EmployeeListItem;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * 员工列表读模型。领导优先级在数据库分页前计算，保证负责人不会因分页落到普通员工之后。
 */
@Repository
@RequiredArgsConstructor
public class EmployeeListQuery {

    private static final String SELECT = """
            SELECT
                e.id,
                e.code,
                e.full_name,
                e.gender,
                d.name AS department_name,
                p.name AS position_name,
                e.status,
                e.employment_type,
                e.hire_date,
                p.level AS position_level,
                (d.manager_id = e.id) AS department_manager,
                CASE
                    WHEN d.manager_id = e.id THEN 0
                    WHEN p.level = '领导层' THEN 1
                    WHEN p.level = '班组管理' THEN 2
                    ELSE 3
                END AS leader_rank
            FROM employees e
            JOIN departments d ON d.id = e.department_id
            LEFT JOIN positions p ON p.id = e.position_id
            """;

    private static final String ORDER_BY = """
            ORDER BY
                CASE
                    WHEN d.manager_id = e.id THEN 0
                    WHEN p.level = '领导层' THEN 1
                    WHEN p.level = '班组管理' THEN 2
                    ELSE 3
                END,
                e.code
            """;

    private final JdbcTemplate jdbc;

    public Result query(
            int page,
            int requestedSize,
            String search,
            Set<String> statuses,
            Collection<UUID> departmentIds,
            boolean filterDepartments) {
        int safePage = Math.max(1, page);
        int size = Math.min(Math.max(1, requestedSize), 100);
        List<Object> parameters = new ArrayList<>();
        String where = where(search, statuses, departmentIds, filterDepartments, parameters);

        Long totalValue = jdbc.queryForObject(
                "SELECT COUNT(*) FROM employees e " + where,
                Long.class,
                parameters.toArray());
        long total = totalValue == null ? 0 : totalValue;

        List<Object> pageParameters = new ArrayList<>(parameters);
        pageParameters.add(size);
        pageParameters.add((safePage - 1) * size);
        List<EmployeeListItem> items = jdbc.query(
                SELECT + where + ORDER_BY + " LIMIT ? OFFSET ?",
                (rs, rowNum) -> new EmployeeListItem(
                        rs.getObject("id", UUID.class),
                        rs.getString("code"),
                        rs.getString("full_name"),
                        rs.getString("gender"),
                        rs.getString("department_name"),
                        rs.getString("position_name"),
                        rs.getString("status"),
                        rs.getString("employment_type"),
                        rs.getObject("hire_date", java.time.LocalDate.class),
                        rs.getString("position_level"),
                        rs.getBoolean("department_manager"),
                        rs.getInt("leader_rank")),
                pageParameters.toArray());
        int totalPages = total == 0 ? 0 : (int) Math.ceil((double) total / size);
        return new Result(items, safePage, size, total, totalPages);
    }

    private String where(
            String search,
            Set<String> statuses,
            Collection<UUID> departmentIds,
            boolean filterDepartments,
            List<Object> parameters) {
        StringBuilder sql = new StringBuilder(" WHERE e.is_deleted = false");
        if (search != null && !search.isBlank()) {
            sql.append(" AND (LOWER(e.code) LIKE ? OR LOWER(e.full_name) LIKE ?)");
            String like = "%" + search.trim().toLowerCase() + "%";
            parameters.add(like);
            parameters.add(like);
        }
        if (statuses != null && !statuses.isEmpty()) {
            sql.append(" AND e.status IN (")
                    .append(placeholders(statuses.size()))
                    .append(')');
            parameters.addAll(statuses);
        }
        if (filterDepartments) {
            if (departmentIds == null || departmentIds.isEmpty()) {
                sql.append(" AND 1 = 0");
            } else {
                sql.append(" AND e.department_id IN (")
                        .append(placeholders(departmentIds.size()))
                        .append(')');
                parameters.addAll(departmentIds);
            }
        }
        return sql.toString();
    }

    private String placeholders(int count) {
        return String.join(",", java.util.Collections.nCopies(count, "?"));
    }

    public record Result(
            List<EmployeeListItem> items,
            int page,
            int size,
            long total,
            int totalPages) {
    }
}
