package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 车间内料仓的对象范围 (ADR-131 §8.2): 车间成员 (生产部子树的部门成员) 只看、只办本车间的内料仓;
 * 其他部门持码的人 (仓库、计划、财务) 看全部。直接挂在生产部 (不在任何车间) 的人按生产部管理看全部。
 */
@Component
public class WorkshopMaterialScope {

    private final NamedParameterJdbcTemplate db;
    private final SecurityContextCurrentUser currentUser;

    public WorkshopMaterialScope(NamedParameterJdbcTemplate db, SecurityContextCurrentUser currentUser) {
        this.db = db;
        this.currentUser = currentUser;
    }

    /** 受限时返回可见车间; 不受限为空。 */
    public Optional<Set<UUID>> restrictedWorkshops() {
        AuthUser user = currentUser.get().orElse(null);
        if (user == null || user.isSuperAdmin() || user.getEmployeeId() == null) return Optional.empty();
        return restrictedWorkshopsForEmployee(user.getEmployeeId());
    }

    /** 通知候选人使用相同对象范围, 不切换请求中的登录主体。权限与账号有效性由通知接收人解析器判定。 */
    public boolean canSeeForUser(UUID workshopDepartmentId, UUID userId) {
        if (workshopDepartmentId == null || userId == null) return false;
        var users=db.queryForList("SELECT employee_id,is_super_admin FROM users WHERE id=:user",Map.of("user",userId));
        if(users.size()!=1) return false;
        var user=users.getFirst();
        if(Boolean.TRUE.equals(user.get("is_super_admin")) || user.get("employee_id")==null) return true;
        return restrictedWorkshopsForEmployee((UUID)user.get("employee_id"))
                .map(workshops->workshops.contains(workshopDepartmentId)).orElse(true);
    }

    private Optional<Set<UUID>> restrictedWorkshopsForEmployee(UUID employeeId) {
        var rows = db.queryForList("""
                WITH RECURSIVE production AS (
                    SELECT department.id FROM departments department
                    WHERE department.code = 'DEPT_PROD' AND NOT department.is_deleted
                ), memberships(id) AS (
                    SELECT employee.department_id FROM employees employee
                    WHERE employee.id = :employee AND NOT employee.is_deleted
                      AND employee.status IN ('active', 'probation', 'onLeave')
                    UNION
                    SELECT secondary.department_id FROM employee_secondary_departments secondary
                    WHERE secondary.employee_id = :employee
                    UNION
                    SELECT department.id FROM departments department
                    WHERE department.manager_id = :employee AND NOT department.is_deleted
                ), ancestry(member_id, id, parent_id, depth) AS (
                    SELECT member.id, department.id, department.parent_id, 0
                    FROM memberships member JOIN departments department ON department.id = member.id
                    WHERE NOT department.is_deleted
                    UNION ALL
                    SELECT child.member_id, department.id, department.parent_id, child.depth + 1
                    FROM ancestry child JOIN departments department ON department.id = child.parent_id
                    WHERE NOT department.is_deleted AND child.depth < 32
                )
                SELECT ancestry.member_id, ancestry.id, ancestry.parent_id,
                       ancestry.id IN (SELECT id FROM production) AS is_production
                FROM ancestry
                """, Map.of("employee", employeeId));
        Set<UUID> production = rows.stream().filter(row -> Boolean.TRUE.equals(row.get("is_production")))
                .map(row -> (UUID) row.get("id")).collect(Collectors.toSet());
        if (production.isEmpty()) return Optional.empty();
        Set<UUID> workshops = new LinkedHashSet<>();
        boolean productionManagement = false;
        for (Map<String, Object> row : rows) {
            UUID id = (UUID) row.get("id");
            UUID parent = (UUID) row.get("parent_id");
            if (parent != null && production.contains(parent)) workshops.add(id);
            if (production.contains(id) && id.equals(row.get("member_id"))) productionManagement = true;
        }
        if (productionManagement || workshops.isEmpty()) return Optional.empty();
        return Optional.of(Set.copyOf(workshops));
    }

    public boolean canSee(UUID workshopDepartmentId) {
        return restrictedWorkshops().map(set -> set.contains(workshopDepartmentId)).orElse(true);
    }

    public void requireWorkshop(UUID workshopDepartmentId) {
        if (workshopDepartmentId == null || !canSee(workshopDepartmentId)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "只能查看和办理本车间的内料仓");
        }
    }

    /**
     * 车间列在范围内的 SQL 条件; column 是调用方内部的列名 (不是请求输入)。不受限时为 TRUE、不绑定参数。
     */
    public String predicate(String column, MapSqlParameterSource params) {
        if (column == null || !column.matches("[a-zA-Z_][a-zA-Z0-9_.]*")) {
            throw new IllegalArgumentException("invalid internal column");
        }
        Optional<Set<UUID>> restricted = restrictedWorkshops();
        if (restricted.isEmpty()) return "TRUE";
        params.addValue("scopeWorkshops", restricted.get().stream().map(UUID::toString)
                .collect(Collectors.joining(",")));
        return column + " = ANY(CAST(string_to_array(CAST(:scopeWorkshops AS text), ',') AS uuid[]))";
    }
}
