package com.uten.imp.features.admin.serveroperations;

import java.util.List;
import java.util.UUID;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/** Fresh DB authority for unattended execution; never a JWT, department grant or cached resolver. */
@Component
@RequiredArgsConstructor
public class ServerOperationsActorAuthority {
    private final JdbcTemplate jdbc;
    private static final String ELIGIBLE = """
            FROM users actor
            WHERE NOT actor.is_deleted AND actor.status='active'
              AND NOT actor.must_change_password
              AND (actor.is_super_admin OR (EXISTS (
                SELECT 1 FROM employees employee WHERE employee.id=actor.employee_id
                  AND NOT employee.is_deleted AND employee.status IN ('active','probation','onLeave'))
                AND EXISTS (
                SELECT 1 FROM user_permission_overrides allocation
                JOIN permissions permission ON permission.id=allocation.permission_id
                WHERE allocation.user_id=actor.id AND allocation.active
                  AND allocation.effect='grant' AND allocation.authority_source='SUPER_ADMIN_CONFIRMED'
                  AND permission.code='server:update')))
            """;

    @Transactional(readOnly = true)
    public boolean mayUpdate(UUID actorId) {
        return Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS (SELECT 1 " + ELIGIBLE + " AND actor.id=?)",
                Boolean.class, actorId));
    }

    @Transactional(readOnly = true)
    public List<UUID> currentUpdaters() {
        return jdbc.query("SELECT actor.id " + ELIGIBLE + " ORDER BY actor.id",
                (row, index) -> row.getObject(1, UUID.class));
    }
}
