package com.uten.imp.features.notice;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/** Positive-source superset only; PermissionResolver remains the final authority. */
@org.springframework.stereotype.Component
final class NoticePermissionCandidateQuery {
    private static final org.slf4j.Logger LOG = org.slf4j.LoggerFactory.getLogger(NoticePermissionCandidateQuery.class);
    private final NamedParameterJdbcTemplate jdbc;

    NoticePermissionCandidateQuery(JdbcTemplate jdbc) {
        this.jdbc = new NamedParameterJdbcTemplate(jdbc);
    }

    Optional<Set<UUID>> possibleUsers(Set<String> anyPermission) {
        if (anyPermission.isEmpty()) return Optional.empty();
        // Inspect catalog rows without touching an absent source relation. Catching
        // a failed SELECT would leave the caller's PostgreSQL transaction aborted.
        // No separate connection/transaction or rollback of earlier business work.
        if (!Boolean.TRUE.equals(jdbc.getJdbcOperations().queryForObject(SHAPE_SQL, Boolean.class))) {
            LOG.warn("Notice permission candidate schema is unavailable; using complete current permission resolution");
            return Optional.empty();
        }
        // Once the exact shape is proven, all SQL/security/connection errors must
        // propagate. Concurrent DDL is a retryable transaction failure, not a reason
        // to continue querying in a broken transaction or weaken authorization.
        var ids = jdbc.queryForList(SQL, Map.of("codes", anyPermission), UUID.class);
        return Optional.of(Set.copyOf(ids));
    }

    static final String SHAPE_SQL = """
            WITH expected(relation_name,column_name,kind) AS (VALUES
                ('permissions','id','uuid'),('permissions','code','text'),('permissions','active','bool'),
                ('departments','id','uuid'),('departments','parent_id','uuid'),
                ('department_permissions','department_id','uuid'),('department_permissions','permission_id','uuid'),
                ('users','id','uuid'),('users','employee_id','uuid'),('users','is_super_admin','bool'),
                ('users','is_deleted','bool'),('users','status','text'),
                ('roles','id','uuid'),('roles','code','text'),
                ('role_permissions','role_id','uuid'),('role_permissions','permission_id','uuid'),
                ('user_roles','user_id','uuid'),('user_roles','role_id','uuid'),
                ('employees','id','uuid'),('employees','department_id','uuid'),
                ('employee_secondary_departments','employee_id','uuid'),('employee_secondary_departments','department_id','uuid'),
                ('user_permission_overrides','user_id','uuid'),('user_permission_overrides','permission_id','uuid'),
                ('user_permission_overrides','active','bool'),('user_permission_overrides','effect','text'),
                ('manager_permission_delegations','user_id','uuid'),('manager_permission_delegations','permission_id','uuid'),
                ('manager_permission_delegations','enabled','bool')
            )
            SELECT NOT EXISTS (
                SELECT 1 FROM expected source
                LEFT JOIN pg_catalog.pg_attribute attribute
                  ON attribute.attrelid=pg_catalog.to_regclass(source.relation_name)
                 AND attribute.attname=source.column_name
                 AND attribute.attnum>0 AND NOT attribute.attisdropped
                WHERE attribute.attname IS NULL OR NOT (
                    (source.kind='uuid' AND attribute.atttypid='uuid'::regtype)
                    OR (source.kind='bool' AND attribute.atttypid='bool'::regtype)
                    OR (source.kind='text' AND attribute.atttypid IN ('text'::regtype,'varchar'::regtype,'bpchar'::regtype))
                )
            )
            """;

    static final String SQL = """
            WITH RECURSIVE requested AS MATERIALIZED (
                SELECT id FROM permissions WHERE code IN (:codes) AND active=TRUE
            ), delegated_departments(id) AS (
                SELECT allocation.department_id FROM department_permissions allocation
                JOIN requested permission ON permission.id=allocation.permission_id
                UNION
                SELECT child.id FROM departments child
                JOIN delegated_departments ancestor ON child.parent_id=ancestor.id
            ), positive_users(id) AS (
                SELECT account.id FROM users account WHERE account.is_super_admin=TRUE
                UNION
                SELECT account.id FROM users account WHERE EXISTS (
                    SELECT 1 FROM roles role
                    JOIN role_permissions allocation ON allocation.role_id=role.id
                    JOIN requested permission ON permission.id=allocation.permission_id
                    WHERE role.code='employee')
                UNION
                SELECT assignment.user_id FROM user_roles assignment
                JOIN role_permissions allocation ON allocation.role_id=assignment.role_id
                JOIN requested permission ON permission.id=allocation.permission_id
                UNION
                SELECT account.id FROM users account
                JOIN employees employee ON employee.id=account.employee_id
                JOIN delegated_departments department ON department.id=employee.department_id
                UNION
                SELECT account.id FROM users account
                JOIN employee_secondary_departments secondary ON secondary.employee_id=account.employee_id
                JOIN delegated_departments department ON department.id=secondary.department_id
                UNION
                SELECT allocation.user_id FROM user_permission_overrides allocation
                JOIN requested permission ON permission.id=allocation.permission_id
                WHERE allocation.active=TRUE AND allocation.effect IS DISTINCT FROM 'revoke'
                UNION
                SELECT delegation.user_id FROM manager_permission_delegations delegation
                JOIN requested permission ON permission.id=delegation.permission_id
                WHERE delegation.enabled=TRUE
            )
            SELECT account.id FROM positive_users positive
            JOIN users account ON account.id=positive.id
            WHERE account.is_deleted=FALSE AND account.status='active'
            ORDER BY account.id
            """;
}
