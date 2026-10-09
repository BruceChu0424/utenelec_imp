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

    private static final String COLUMNS = """
            SELECT
                e.id,
                e.code,
                e.full_name,
                e.gender,
                e.department_id,
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
            """;

    private static final String FROM = """
            FROM employees e
            JOIN departments d ON d.id = e.department_id
            LEFT JOIN positions p ON p.id = e.position_id
            """;

    /** 搜索词命中车牌时带回命中车牌（「、」分隔）；未命中返回 NULL。 */
    private static final String MATCHED_PLATES =
            ", (SELECT string_agg(v.plate_no, '、') FROM employee_vehicles v"
                    + " WHERE v.employee_id = e.id AND LOWER(v.plate_norm) LIKE ?) AS matched_plates\n";

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
            boolean filterDepartments,
            String sort,
            String order) {
        int safePage = Math.max(1, page);
        int size = Math.min(Math.max(1, requestedSize), 100);
        boolean hasSearch = search != null && !search.isBlank();
        List<Object> parameters = new ArrayList<>();
        String where = where(search, statuses, departmentIds, filterDepartments, parameters);

        // count 与主查询共用同一份 FROM：搜索条件引用了 d/p 的列，count 少了 JOIN 会炸。
        Long totalValue = jdbc.queryForObject(
                "SELECT COUNT(*) " + FROM + where,
                Long.class,
                parameters.toArray());
        long total = totalValue == null ? 0 : totalValue;

        // SELECT 里的命中车牌子查询参数（仅搜索时）先于 WHERE 参数
        List<Object> pageParameters = new ArrayList<>();
        if (hasSearch) {
            pageParameters.add(plateLike(search));
        }
        pageParameters.addAll(parameters);
        pageParameters.add(size);
        pageParameters.add((safePage - 1) * size);
        String select = COLUMNS
                + (hasSearch ? MATCHED_PLATES : ", NULL AS matched_plates\n")
                + FROM;
        List<EmployeeListItem> items = jdbc.query(
                // 文本块 ORDER_BY 开头的换行会被 Java 吃掉，where 结尾是 "false"，
                // 必须在此显式补换行，否则拼成 "falseORDER BY" 触发 PG 语法错误。
                select + where + "\n" + orderBy(sort, order) + " LIMIT ? OFFSET ?",
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
                        rs.getInt("leader_rank"),
                        rs.getObject("department_id", UUID.class),
                        rs.getString("matched_plates")),
                pageParameters.toArray());
        int totalPages = total == 0 ? 0 : (int) Math.ceil((double) total / size);
        return new Result(items, safePage, size, total, totalPages);
    }

    /**
     * 排序子句：sort 白名单映射（拼 SQL，禁止透传任意输入）——
     * code=工号、hireDate=入职日期、workYears=工龄（不落库，映射到 hire_date 且方向翻转：
     * 工龄从小到大 ⇔ 入职日期从新到远）。其余值（含 null）回落默认「负责人优先 + 工号」。
     * 显式排序时不再叠加负责人优先，工号作稳定并列序；hire_date 两个方向都 NULLS LAST。
     * 包级可见：白名单契约由 EmployeeListQueryOrderByTest 直接锁定。
     */
    String orderBy(String sort, String order) {
        boolean desc = "desc".equalsIgnoreCase(order == null ? "" : order.trim());
        return switch (sort == null ? "" : sort.trim()) {
            case "code" -> "ORDER BY e.code " + (desc ? "DESC" : "ASC") + ", e.code";
            case "hireDate" -> "ORDER BY e.hire_date " + (desc ? "DESC" : "ASC")
                    + " NULLS LAST, e.code";
            case "workYears" -> "ORDER BY e.hire_date " + (desc ? "ASC" : "DESC")
                    + " NULLS LAST, e.code";
            default -> ORDER_BY;
        };
    }

    private String where(
            String search,
            Set<String> statuses,
            Collection<UUID> departmentIds,
            boolean filterDepartments,
            List<Object> parameters) {
        StringBuilder sql = new StringBuilder(" WHERE e.is_deleted = false");
        if (search != null && !search.isBlank()) {
            // 全行可搜（2026-10-09 用户口径「行里显示什么就能按什么搜」）：
            // 工号 / 姓名 / 部门 / 岗位 / 入职日期(yyyy[-MM][-dd] 文本) / 车牌
            //（ADR-021：谁的车有问题 → 按车牌秒查人）。
            sql.append(" AND (LOWER(e.code) LIKE ? OR LOWER(e.full_name) LIKE ?")
                    .append(" OR LOWER(d.name) LIKE ? OR LOWER(p.name) LIKE ?")
                    .append(" OR LOWER(CAST(e.hire_date AS TEXT)) LIKE ?")
                    .append(" OR EXISTS (SELECT 1 FROM employee_vehicles v")
                    .append(" WHERE v.employee_id = e.id AND LOWER(v.plate_norm) LIKE ?))");
            String like = "%" + search.trim().toLowerCase(java.util.Locale.ROOT) + "%";
            parameters.add(like);
            parameters.add(like);
            parameters.add(like);
            parameters.add(like);
            parameters.add(like);
            parameters.add(plateLike(search));
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

    /**
     * 精确搜索 0 命中时的「类似人员」（2026-10-09）：按搜索词的每个字符在
     * 姓名/部门/岗位/工号上的命中情况评分（姓名命中权重最高），得分大于 0 即入选，
     * 按得分降序 + 负责人优先 + 工号返回前若干条。搜索词字符去重、忽略空白，
     * 最多取 8 个字符防极端长词把 SQL 撑爆。
     */
    public List<EmployeeListItem> similar(String search, int limit) {
        if (search == null || search.isBlank()) {
            return List.of();
        }
        List<Integer> codePoints = search.codePoints()
                .filter(cp -> !Character.isWhitespace(cp))
                .distinct()
                .boxed()
                .limit(8)
                .toList();
        if (codePoints.isEmpty()) {
            return List.of();
        }
        StringBuilder score = new StringBuilder("(0");
        List<Object> scoreParams = new ArrayList<>();
        for (int cp : codePoints) {
            String like = "%"
                    + String.valueOf(Character.toChars(cp)).toLowerCase(java.util.Locale.ROOT)
                    + "%";
            score.append(" + (CASE WHEN LOWER(e.full_name) LIKE ? THEN 4 ELSE 0 END)")
                    .append(" + (CASE WHEN LOWER(d.name) LIKE ? THEN 2 ELSE 0 END)")
                    .append(" + (CASE WHEN LOWER(p.name) LIKE ? THEN 2 ELSE 0 END)")
                    .append(" + (CASE WHEN LOWER(e.code) LIKE ? THEN 1 ELSE 0 END)");
            scoreParams.add(like);
            scoreParams.add(like);
            scoreParams.add(like);
            scoreParams.add(like);
        }
        score.append(')');
        String scoreExpr = score.toString();
        List<Object> args = new ArrayList<>(scoreParams);
        args.addAll(scoreParams);
        args.add(Math.min(Math.max(1, limit), 50));
        return jdbc.query(
                COLUMNS + ", NULL AS matched_plates\n" + FROM
                        + " WHERE e.is_deleted = false AND " + scoreExpr + " > 0"
                        + " ORDER BY " + scoreExpr + " DESC, leader_rank, e.code LIMIT ?",
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
                        rs.getInt("leader_rank"),
                        rs.getObject("department_id", UUID.class),
                        rs.getString("matched_plates")),
                args.toArray());
    }

    private String placeholders(int count) {
        return String.join(",", java.util.Collections.nCopies(count, "?"));
    }

    /** 车牌搜索词：去空白后小写模糊匹配（plate_norm 已是大写去空白，LOWER 后对齐）。 */
    private static String plateLike(String search) {
        return "%" + search.replaceAll("\\s+", "").toLowerCase(java.util.Locale.ROOT) + "%";
    }

    public record Result(
            List<EmployeeListItem> items,
            int page,
            int size,
            long total,
            int totalPages) {
    }
}
