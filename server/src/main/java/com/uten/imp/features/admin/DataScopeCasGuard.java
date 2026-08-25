package com.uten.imp.features.admin;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/** Serializes one user+scope replacement and rejects stale administrator edits. */
@Component
@RequiredArgsConstructor
public class DataScopeCasGuard {

    private final EntityManager em;

    public void lockAndVerify(
            UUID userId,
            String scope,
            List<UUID> expectedOwnerEmployeeIds) {
        if (expectedOwnerEmployeeIds == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "缺少原数据范围，请刷新后重试");
        }
        em.createNativeQuery(
                        "SELECT pg_advisory_xact_lock("
                                + "hashtextextended(CAST(:lockKey AS text), 0))")
                .setParameter("lockKey", userId + ":" + scope)
                .getSingleResult();
        Set<UUID> current = new LinkedHashSet<>(NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT data_scope.owner_employee_id
                                FROM user_data_scopes data_scope
                                WHERE data_scope.user_id=:uid AND data_scope.scope=:scope
                                  AND data_scope.owner_employment_generation=(
                                      SELECT count(*) FROM employment_history history
                                      WHERE history.employee_id=data_scope.owner_employee_id
                                        AND history.event_type='rehire')
                                ORDER BY data_scope.owner_employee_id
                                """)
                        .setParameter("uid", userId)
                        .setParameter("scope", scope),
                UUID.class));
        Set<UUID> expected = new LinkedHashSet<>(expectedOwnerEmployeeIds);
        if (!current.equals(expected)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "数据范围已被其他管理员修改，请刷新后重试");
        }
    }
}
