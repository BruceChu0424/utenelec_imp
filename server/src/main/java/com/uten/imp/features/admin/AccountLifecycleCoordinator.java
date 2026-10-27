package com.uten.imp.features.admin;

import com.uten.imp.common.identity.CurrentEmployeeStatusPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.Map;
import java.util.UUID;

/** Super-admin registry mutations only: registry -> employee -> user. Ordinary commands keep narrow row locks. */
@Component
@RequiredArgsConstructor
@Transactional(propagation = Propagation.MANDATORY)
public class AccountLifecycleCoordinator {
    public static final int LOCK_NAMESPACE = 1431586126;
    public static final int LOCK_KEY = 399;
    private final NamedParameterJdbcTemplate jdbc;

    public void lock() {
        jdbc.queryForObject("SELECT 1 FROM pg_advisory_xact_lock(:namespace,:key)",
                Map.of("namespace", LOCK_NAMESPACE, "key", LOCK_KEY), Integer.class);
    }

    /** A queued command cannot reuse the super-admin flag that another command just revoked. */
    public void requireCurrentAdministrator(AuthUser actor) {
        if (actor == null || actor.isVisitor() || actor.isMustChangePassword() || actor.getImpersonatedBy() != null
                || !Boolean.TRUE.equals(jdbc.queryForObject("""
                    SELECT EXISTS(SELECT 1 FROM users u JOIN employees e ON e.id=u.employee_id
                    WHERE u.id=:actor AND u.is_super_admin AND NOT u.is_deleted AND u.status='active'
                      AND NOT u.must_change_password AND NOT e.is_deleted AND e.status IN(:current))
                    """, Map.of("actor", actor.getId(), "current", CurrentEmployeeStatusPolicy.CURRENT_EMPLOYEE_STATUSES), Boolean.class))) {
            throw new ApiException(ErrorCode.FORBIDDEN, "当前管理员资格已变化，请重新登录核对权限");
        }
    }

    /** Disabled, locked, archived, departed and expired temporary-credential accounts are not a fallback. */
    public void requireAdministratorSurvives(UUID targetUserId) {
        Boolean survives = jdbc.queryForObject("""
                WITH usable AS (
                  SELECT u.id FROM users u JOIN employees e ON e.id=u.employee_id
                  WHERE u.is_super_admin AND NOT u.is_deleted AND u.status='active'
                    AND NOT e.is_deleted AND e.status IN(:current)
                    AND (NOT u.must_change_password OR u.temp_password_expires_at IS NULL
                         OR u.temp_password_expires_at>clock_timestamp())
                )
                SELECT NOT EXISTS(SELECT 1 FROM usable WHERE id=:target) OR (SELECT count(*) FROM usable)>1
                """, Map.of("target", targetUserId, "current", CurrentEmployeeStatusPolicy.CURRENT_EMPLOYEE_STATUSES), Boolean.class);
        if (!Boolean.TRUE.equals(survives)) {
            throw new ApiException(ErrorCode.CONFLICT, "至少需保留一位当前可用的超级管理员");
        }
    }
}
