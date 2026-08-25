package com.uten.imp.responsibility;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.department.staffpermission.OrganizationPermissionManagementScopeService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.UUID;

/** Object-level boundary for HR handovers: central HR, super-admin, or a manager's own subtree. */
@Component
@RequiredArgsConstructor
public class EmployeeHandoverAuthorization {

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final OrganizationPermissionManagementScopeService managementScope;

    public void requireAuthorized(UUID sourceEmployeeId, UUID targetEmployeeId) {
        if (isSuperAdministrator(sourceEmployeeId)
                || isSuperAdministrator(targetEmployeeId)) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN, "超级管理员数据不可通过人员交接入口转移");
        }
        AuthUser actor = currentUser.get().orElseThrow(() ->
                new ApiException(ErrorCode.UNAUTHORIZED, "未登录"));
        if (actor.isSuperAdmin() || isCentralHr(actor.getEmployeeId())) return;

        UUID sourceDepartmentId = departmentOf(sourceEmployeeId);
        if (sourceDepartmentId == null
                || managementScope.resolveAuthority(actor, sourceDepartmentId).isEmpty()) {
            throw hidden();
        }
        if (targetEmployeeId != null) {
            UUID targetDepartmentId = departmentOf(targetEmployeeId);
            if (targetDepartmentId == null
                    || managementScope.resolveAuthority(actor, targetDepartmentId).isEmpty()) {
                throw hidden();
            }
        }
    }

    public CandidateScope candidateScope() {
        AuthUser actor = currentUser.get().orElseThrow(() ->
                new ApiException(ErrorCode.UNAUTHORIZED, "未登录"));
        if (actor.isSuperAdmin() || isCentralHr(actor.getEmployeeId())) {
            return new CandidateScope(true, actor.getEmployeeId());
        }
        var staffScope = managementScope.staffSearchAuthority(actor)
                .orElseThrow(EmployeeHandoverAuthorization::hidden);
        boolean companyWide = staffScope.scope()
                != OrganizationPermissionManagementScopeService.StaffSearchScope.MANAGER_SUBTREES;
        return new CandidateScope(companyWide, actor.getEmployeeId());
    }

    public record CandidateScope(boolean companyWide, UUID managerEmployeeId) {
    }

    private boolean isSuperAdministrator(UUID employeeId) {
        if (employeeId == null) return false;
        Number count = (Number) em.createNativeQuery("""
                        SELECT count(*) FROM users account
                        WHERE account.employee_id=:employeeId
                          AND account.is_super_admin=true
                          AND account.is_deleted=false
                        """)
                .setParameter("employeeId", employeeId)
                .getSingleResult();
        return count.longValue() > 0;
    }

    private boolean isCentralHr(UUID employeeId) {
        if (employeeId == null) return false;
        Number count = (Number) em.createNativeQuery("""
                        WITH RECURSIVE ancestors(id, parent_id, code) AS (
                            SELECT department.id, department.parent_id, department.code
                            FROM employees employee
                            JOIN departments department ON department.id=employee.department_id
                            WHERE employee.id=:employeeId AND employee.is_deleted=false
                              AND department.is_deleted=false
                            UNION ALL
                            SELECT parent.id, parent.parent_id, parent.code
                            FROM departments parent
                            JOIN ancestors child ON child.parent_id=parent.id
                            WHERE parent.is_deleted=false
                        )
                        SELECT count(*) FROM ancestors WHERE code='DEPT_HR'
                        """)
                .setParameter("employeeId", employeeId)
                .getSingleResult();
        return count.longValue() > 0;
    }

    private UUID departmentOf(UUID employeeId) {
        if (employeeId == null) return null;
        @SuppressWarnings("unchecked")
        var rows = em.createNativeQuery("""
                        SELECT department_id FROM employees
                        WHERE id=:employeeId AND is_deleted=false
                        """)
                .setParameter("employeeId", employeeId)
                .getResultList();
        if (rows.isEmpty() || rows.getFirst() == null) return null;
        Object value = rows.getFirst();
        return value instanceof UUID id ? id : UUID.fromString(value.toString());
    }

    private static ApiException hidden() {
        return new ApiException(ErrorCode.NOT_FOUND, "交接员工不存在或不在可管理组织范围内");
    }
}
