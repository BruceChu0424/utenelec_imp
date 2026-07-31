package com.uten.imp.features.notice;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.dto.NoticeAudienceEmployeeDto;
import com.uten.imp.features.notice.dto.NoticeAudiencePreviewDto;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * 通知接收范围读侧与解析器。
 *
 * <p>人工发布只接收 employees.id / departments.id。服务端在发布事务内把部门子树和显式人员
 * 解析成 users.id 并去重，避免前端伪造接收人数，也避免人员调岗后历史通知的可见范围漂移。
 */
@Service
@RequiredArgsConstructor
public class NoticeAudienceService {

    private static final int MAX_SEARCH_RESULTS = 100;

    private final JdbcClient jdbc;

    /** notice:publish 专用人员目录，不要求额外 employee:view，且不暴露敏感档案字段。 */
    @Transactional(readOnly = true)
    public List<NoticeAudienceEmployeeDto> searchEmployees(String search) {
        String keyword = search == null ? "" : search.trim();
        return jdbc.sql("""
                        SELECT e.id,
                               e.full_name,
                               e.code,
                               d.name AS department_name
                        FROM employees e
                        JOIN users u ON u.employee_id = e.id
                        LEFT JOIN departments d ON d.id = e.department_id
                        WHERE e.is_deleted = false
                          AND e.status <> 'resigned'
                          AND u.is_deleted = false
                          AND u.status = 'active'
                          AND (
                            :keyword = ''
                            OR e.full_name ILIKE '%' || :keyword || '%'
                            OR e.code ILIKE '%' || :keyword || '%'
                          )
                        ORDER BY e.full_name, e.code
                        LIMIT :limit
                        """)
                .param("keyword", keyword)
                .param("limit", MAX_SEARCH_RESULTS)
                .query((rs, rowNum) -> new NoticeAudienceEmployeeDto(
                        rs.getObject("id", UUID.class).toString(),
                        rs.getString("full_name"),
                        rs.getString("code"),
                        rs.getString("department_name")))
                .list();
    }

    @Transactional(readOnly = true)
    public NoticeAudiencePreviewDto preview(List<UUID> departmentIds, List<UUID> employeeIds) {
        ResolvedAudience resolved = resolveSelected(departmentIds, employeeIds);
        return new NoticeAudiencePreviewDto(resolved.summary(), resolved.userIds().size());
    }

    @Transactional(readOnly = true)
    public ResolvedAudience resolveSelected(
            List<UUID> departmentIds,
            List<UUID> employeeIds) {
        Set<UUID> departments = normalized(departmentIds);
        Set<UUID> employees = normalized(employeeIds);
        if (departments.isEmpty() && employees.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请至少选择一个部门或人员");
        }

        List<TargetName> departmentNames = loadDepartmentNames(departments);
        if (departmentNames.size() != departments.size()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "所选部门已失效，请重新选择");
        }

        List<EmployeeTarget> employeeTargets = loadEmployeeTargets(employees);
        if (employeeTargets.size() != employees.size()) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "所选人员中存在离职、停用或未开通账号的人员，请重新选择");
        }

        Set<UUID> userIds = new LinkedHashSet<>();
        if (!departments.isEmpty()) {
            userIds.addAll(loadDepartmentUserIds(departments));
        }
        for (EmployeeTarget employee : employeeTargets) {
            userIds.add(employee.userId());
        }
        if (userIds.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "所选范围内没有可接收通知的在职账号");
        }

        return new ResolvedAudience(
                Set.copyOf(userIds),
                Set.copyOf(departments),
                Set.copyOf(employees),
                buildSummary(departmentNames, employeeTargets));
    }

    private List<TargetName> loadDepartmentNames(Set<UUID> departmentIds) {
        if (departmentIds.isEmpty()) return List.of();
        return jdbc.sql("""
                        SELECT id, name
                        FROM departments
                        WHERE id IN (:ids)
                          AND is_deleted = false
                        ORDER BY name
                        """)
                .param("ids", departmentIds)
                .query((rs, rowNum) -> new TargetName(
                        rs.getObject("id", UUID.class),
                        rs.getString("name")))
                .list();
    }

    private List<EmployeeTarget> loadEmployeeTargets(Set<UUID> employeeIds) {
        if (employeeIds.isEmpty()) return List.of();
        return jdbc.sql("""
                        SELECT e.id AS employee_id,
                               u.id AS user_id,
                               e.full_name
                        FROM employees e
                        JOIN users u ON u.employee_id = e.id
                        WHERE e.id IN (:ids)
                          AND e.is_deleted = false
                          AND e.status <> 'resigned'
                          AND u.is_deleted = false
                          AND u.status = 'active'
                        ORDER BY e.full_name
                        """)
                .param("ids", employeeIds)
                .query((rs, rowNum) -> new EmployeeTarget(
                        rs.getObject("employee_id", UUID.class),
                        rs.getObject("user_id", UUID.class),
                        rs.getString("full_name")))
                .list();
    }

    private List<UUID> loadDepartmentUserIds(Set<UUID> departmentIds) {
        return jdbc.sql("""
                        WITH RECURSIVE selected_departments(id) AS (
                            SELECT id
                            FROM departments
                            WHERE id IN (:departmentIds)
                              AND is_deleted = false
                            UNION
                            SELECT d.id
                            FROM departments d
                            JOIN selected_departments parent ON d.parent_id = parent.id
                            WHERE d.is_deleted = false
                        )
                        SELECT DISTINCT u.id
                        FROM users u
                        JOIN employees e ON e.id = u.employee_id
                        WHERE e.department_id IN (SELECT id FROM selected_departments)
                          AND e.is_deleted = false
                          AND e.status <> 'resigned'
                          AND u.is_deleted = false
                          AND u.status = 'active'
                        ORDER BY u.id
                        """)
                .param("departmentIds", departmentIds)
                .query(UUID.class)
                .list();
    }

    private Set<UUID> normalized(List<UUID> ids) {
        if (ids == null || ids.isEmpty()) return Set.of();
        Set<UUID> out = new LinkedHashSet<>();
        for (UUID id : ids) {
            if (id != null) out.add(id);
        }
        return out;
    }

    private String buildSummary(
            List<TargetName> departments,
            List<EmployeeTarget> employees) {
        List<String> parts = new ArrayList<>(2);
        if (!departments.isEmpty()) {
            parts.add(compactNames(
                    departments.stream().map(TargetName::name).toList(),
                    "个部门"));
        }
        if (!employees.isEmpty()) {
            parts.add(compactNames(
                    employees.stream().map(EmployeeTarget::name).toList(),
                    "人"));
        }
        return String.join("、", parts);
    }

    private String compactNames(List<String> names, String countSuffix) {
        if (names.size() <= 2) return String.join("、", names);
        return names.get(0) + "、" + names.get(1) + "等 " + names.size() + " " + countSuffix;
    }

    public record ResolvedAudience(
            Set<UUID> userIds,
            Set<UUID> departmentIds,
            Set<UUID> employeeIds,
            String summary) {
    }

    private record TargetName(UUID id, String name) {
    }

    private record EmployeeTarget(UUID employeeId, UUID userId, String name) {
    }
}
