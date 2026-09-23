package com.uten.imp.features.visitor;

import com.uten.imp.common.identity.CurrentEmployeeStatusPolicy;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * 可对外接待的员工白名单(security-08 / permissions-13，ADR-109 §3.9)。
 *
 * <p>「能被外部访客搜到并选为接待人」与「能确认本人的来访」是同一件事，用同一个权限码
 * {@value #HOST_PERMISSION} 表达：V679 起它不再是全员基础包，默认只授给对外接待的部门，
 * 管理员在权限管理页按部门或逐人增减——白名单就是权限目录本身，不另设名单。
 *
 * <p>判定分两步，与审核组资格同一模式：先用一条 SQL 取「可能持有该码」的超集
 * (部门授权按部门子树向下生效、兼职部门、个人加授、负责人委派、超管；个人收回永远优先，
 * 直接排除)，再逐人交给 {@link PermissionResolver} 做最终判定(离职、委派失效等都在这里生效)。
 */
@Component
@RequiredArgsConstructor
class VisitorHostEligibility {

    /** 接待访客：可被访客搜到、选为接待人，并确认本人的来访。 */
    static final String HOST_PERMISSION = "visitor:host_confirm";

    /** 超集最多取多少人再逐人终判(按姓名前缀匹配后通常远少于此数)。 */
    static final int CANDIDATE_WINDOW = 20;

    private static final String CANDIDATES_SQL = """
            WITH RECURSIVE host_permission AS MATERIALIZED (
                SELECT id, baseline FROM permissions WHERE code = ?
            ), granted_departments(id) AS (
                SELECT allocation.department_id
                FROM department_permissions allocation
                JOIN host_permission permission ON permission.id = allocation.permission_id
                UNION
                SELECT child.id
                FROM departments child
                JOIN granted_departments parent ON child.parent_id = parent.id
            )
            SELECT account.id AS user_id, employee.id AS employee_id, employee.full_name
            FROM employees employee
            JOIN users account ON account.employee_id = employee.id
             AND account.is_deleted = FALSE AND account.status = 'active'
            WHERE employee.is_deleted = FALSE
              AND employee.status = ANY (?::text[])
              AND %s
              AND (account.is_super_admin
                   OR EXISTS (SELECT 1 FROM host_permission permission WHERE permission.baseline)
                   OR employee.department_id IN (SELECT id FROM granted_departments)
                   OR EXISTS (SELECT 1 FROM employee_secondary_departments secondary
                              WHERE secondary.employee_id = employee.id
                                AND secondary.department_id IN (SELECT id FROM granted_departments))
                   OR EXISTS (SELECT 1 FROM user_permission_overrides allocation
                              JOIN host_permission permission ON permission.id = allocation.permission_id
                              WHERE allocation.user_id = account.id
                                AND allocation.active = TRUE AND allocation.effect = 'grant')
                   OR EXISTS (SELECT 1 FROM manager_permission_delegations delegation
                              JOIN host_permission permission ON permission.id = delegation.permission_id
                              WHERE delegation.user_id = account.id AND delegation.enabled = TRUE))
              -- 个人收回永远优先(与 PermissionResolver 同口径)：被收回的人不必再逐人终判。
              AND NOT EXISTS (SELECT 1 FROM user_permission_overrides allocation
                              JOIN host_permission permission ON permission.id = allocation.permission_id
                              WHERE allocation.user_id = account.id
                                AND allocation.active = TRUE AND allocation.effect = 'revoke'
                                AND NOT account.is_super_admin)
            ORDER BY employee.full_name, employee.id
            LIMIT ?
            """;

    private final JdbcTemplate jdbc;
    private final UserAccountRepository userRepo;
    private final PermissionResolver permissionResolver;

    /** 姓名以 {@code namePrefix} 开头、且确实持有接待权限的在职员工，最多 {@code limit} 人。 */
    List<Host> searchByNamePrefix(String namePrefix, int limit) {
        List<Host> hosts = new ArrayList<>();
        for (Candidate candidate : candidates(
                "employee.full_name LIKE ? ESCAPE '\\'", escapeLike(namePrefix) + "%")) {
            if (hosts.size() >= limit) {
                break;
            }
            if (holdsHostPermission(candidate.userId())) {
                hosts.add(new Host(candidate.employeeId(), candidate.fullName()));
            }
        }
        return hosts;
    }

    /** 提交来访申请时复核：接待人必须在白名单里，不能拿猜到的员工编号绕过搜索。 */
    boolean isEligible(UUID employeeId) {
        return candidates("employee.id = ?", employeeId).stream()
                .anyMatch(candidate -> holdsHostPermission(candidate.userId()));
    }

    private List<Candidate> candidates(String predicate, Object predicateArg) {
        return jdbc.query(
                CANDIDATES_SQL.formatted(predicate),
                (rs, rowNum) -> new Candidate(
                        rs.getObject("user_id", UUID.class),
                        rs.getObject("employee_id", UUID.class),
                        rs.getString("full_name")),
                HOST_PERMISSION,
                CurrentEmployeeStatusPolicy.CURRENT_EMPLOYEE_STATUSES.toArray(String[]::new),
                predicateArg,
                CANDIDATE_WINDOW);
    }

    private boolean holdsHostPermission(UUID userId) {
        return userRepo.findById(userId)
                .map(permissionResolver::permsOf)
                .map(permissions -> permissions.contains(HOST_PERMISSION))
                .orElse(false);
    }

    private static String escapeLike(String value) {
        return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_");
    }

    record Host(UUID employeeId, String name) {
    }

    private record Candidate(UUID userId, UUID employeeId, String fullName) {
    }
}
