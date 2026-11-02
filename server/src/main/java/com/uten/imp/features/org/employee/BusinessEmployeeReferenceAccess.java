package com.uten.imp.features.org.employee;

import com.uten.imp.common.identity.CurrentEmployeeStatusPolicy;
import com.uten.imp.application.port.CurrentStaffAuthorityPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;
import java.util.List;
import java.util.Set;

/** The operator must have the actual owning command authority; a read grant is insufficient. */
@Component
@RequiredArgsConstructor
public class BusinessEmployeeReferenceAccess implements CurrentStaffAuthorityPort {
    private final SecurityContextCurrentUser currentUser;
    private final JdbcTemplate jdbc;
    private final PermissionResolver permissions;

    public void require(String rawPurpose) {
        var purpose=BusinessEmployeeReferencePurpose.parse(rawPurpose);
        if(!purpose.mayListCandidates(currentStaffPermissions())) throw denied();
    }

    /** Labels in an already authorized read view do not enable the candidate picker or a write. */
    public void requireEcho(String rawPurpose) {
        var purpose=BusinessEmployeeReferencePurpose.parse(rawPurpose);
        if(!purpose.mayEcho(currentStaffPermissions())) throw denied();
    }

    /** Shared minimal-reference caller validation; does not grant a business or HR capability. */
    @Override
    @Transactional(readOnly=true)
    public Set<String> currentStaffPermissions() {
        var actor=currentUser.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED));
        if(actor.isVisitor() || actor.getEmployeeId()==null || !actor.isAccountNonLocked()
                || actor.isMustChangePassword()) throw denied();
        // This is the caller's login eligibility, not the referenced employee's.
        // A recipient may legitimately have no login or a disabled account.
        List<Boolean> states=jdbc.queryForList("""
                SELECT u.is_super_admin FROM users u JOIN employees e ON e.id=u.employee_id
                WHERE u.id=? AND e.id=? AND u.status='active' AND NOT u.is_deleted
                  AND NOT u.must_change_password AND (u.locked_until IS NULL OR u.locked_until<=CURRENT_TIMESTAMP)
                  AND NOT e.is_deleted AND e.status IN (?,?,?)
                """,Boolean.class,actor.getId(),actor.getEmployeeId(),
                CurrentEmployeeStatusPolicy.CURRENT_EMPLOYEE_STATUSES.get(0),
                CurrentEmployeeStatusPolicy.CURRENT_EMPLOYEE_STATUSES.get(1),
                CurrentEmployeeStatusPolicy.CURRENT_EMPLOYEE_STATUSES.get(2));
        if(states.size()!=1 || states.getFirst()!=actor.isSuperAdmin()) throw denied();
        Set<String> fresh=permissions.authorizationSnapshot(actor.getId(),actor.getEmployeeId(),states.getFirst()).permissions();
        if(!fresh.containsAll(actor.getPermissions())) throw denied();
        return Set.copyOf(fresh);
    }
    private static ApiException denied() {return new ApiException(ErrorCode.FORBIDDEN,"没有此业务操作的人员引用权限");}
}
