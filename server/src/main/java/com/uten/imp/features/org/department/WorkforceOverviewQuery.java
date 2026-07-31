package com.uten.imp.features.org.department;

import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 人员概况的单次聚合查询。历史流动按任职事件发生时的 from/to 部门归属统计；
 * 当前人数按员工当前组织归属统计。
 */
@Repository
@RequiredArgsConstructor
public class WorkforceOverviewQuery {

    private static final String SQL = """
            WITH RECURSIVE scope AS (
                SELECT id
                FROM departments
                WHERE id = ? AND is_deleted = false
                UNION ALL
                SELECT d.id
                FROM departments d
                JOIN scope s ON d.parent_id = s.id
                WHERE d.is_deleted = false
            ),
            current_counts AS (
                SELECT
                    COUNT(*) FILTER (
                        WHERE e.department_id = ?
                          AND e.status IN ('active', 'probation', 'onLeave')
                    ) AS direct_current,
                    COUNT(*) FILTER (
                        WHERE e.status IN ('active', 'probation', 'onLeave')
                    ) AS current_total,
                    COUNT(*) FILTER (WHERE e.status = 'active') AS active_total,
                    COUNT(*) FILTER (WHERE e.status = 'probation') AS probation_total,
                    COUNT(*) FILTER (WHERE e.status = 'onLeave') AS leave_total
                FROM employees e
                WHERE e.is_deleted = false
                  AND e.department_id IN (SELECT id FROM scope)
            ),
            period_events AS (
                SELECT
                    COUNT(*) FILTER (
                        WHERE h.event_type = 'onboard'
                          AND h.to_dept_id IN (SELECT id FROM scope)
                    ) AS hired_total,
                    COUNT(*) FILTER (
                        WHERE h.event_type = 'rehire'
                          AND h.to_dept_id IN (SELECT id FROM scope)
                    ) AS rehired_total,
                    COUNT(*) FILTER (
                        WHERE h.event_type = 'resign'
                          AND h.from_dept_id IN (SELECT id FROM scope)
                    ) AS departed_total,
                    COUNT(*) FILTER (
                        WHERE h.event_type = 'transfer'
                          AND h.to_dept_id IN (SELECT id FROM scope)
                          AND (
                              h.from_dept_id IS NULL
                              OR h.from_dept_id NOT IN (SELECT id FROM scope)
                          )
                    ) AS transfer_in_total,
                    COUNT(*) FILTER (
                        WHERE h.event_type = 'transfer'
                          AND h.from_dept_id IN (SELECT id FROM scope)
                          AND (
                              h.to_dept_id IS NULL
                              OR h.to_dept_id NOT IN (SELECT id FROM scope)
                          )
                    ) AS transfer_out_total
                FROM employment_history h
                WHERE h.event_date >= ?
                  AND h.event_date <= ?
            ),
            latest_contracts AS (
                SELECT DISTINCT ON (c.employee_id)
                    c.employee_id,
                    c.end_date,
                    c.probation_months
                FROM employee_contracts c
                JOIN employees e ON e.id = c.employee_id
                WHERE e.is_deleted = false
                  AND e.status IN ('active', 'probation', 'onLeave')
                  AND e.department_id IN (SELECT id FROM scope)
                ORDER BY c.employee_id, c.sign_order DESC, c.created_at DESC
            ),
            alerts AS (
                SELECT
                    COUNT(*) FILTER (
                        WHERE lc.end_date < ?
                    ) AS contract_overdue,
                    COUNT(*) FILTER (
                        WHERE lc.end_date >= ?
                          AND lc.end_date <= ?
                    ) AS contract_expiring,
                    COUNT(*) FILTER (
                        WHERE e.status = 'probation'
                          AND lc.probation_months IS NOT NULL
                          AND (
                              e.hire_date
                              + lc.probation_months * INTERVAL '1 month'
                          )::date < ?
                    ) AS probation_overdue,
                    COUNT(*) FILTER (
                        WHERE e.status = 'probation'
                          AND lc.probation_months IS NOT NULL
                          AND (
                              e.hire_date
                              + lc.probation_months * INTERVAL '1 month'
                          )::date >= ?
                          AND (
                              e.hire_date
                              + lc.probation_months * INTERVAL '1 month'
                          )::date <= ?
                    ) AS probation_ending
                FROM latest_contracts lc
                JOIN employees e ON e.id = lc.employee_id
            ),
            quality AS (
                SELECT
                    COUNT(*) FILTER (
                        WHERE e.is_deleted = false
                          AND e.status = 'resigned'
                          AND NOT EXISTS (
                              SELECT 1
                              FROM employment_history h
                              WHERE h.employee_id = e.id
                                AND h.event_type = 'resign'
                          )
                    )
                    +
                    COUNT(*) FILTER (
                        WHERE e.is_deleted = false
                          AND e.status IN ('active', 'probation', 'onLeave')
                          AND e.hire_date >= ?
                          AND e.hire_date <= ?
                          AND NOT EXISTS (
                              SELECT 1
                              FROM employment_history h
                              WHERE h.employee_id = e.id
                                AND h.event_type IN ('onboard', 'rehire')
                                AND h.event_date >= ?
                                AND h.event_date <= ?
                          )
                    ) AS missing_history
                FROM employees e
                WHERE e.department_id IN (SELECT id FROM scope)
            )
            SELECT
                cc.direct_current,
                cc.current_total,
                cc.active_total,
                cc.probation_total,
                cc.leave_total,
                pe.hired_total,
                pe.rehired_total,
                pe.departed_total,
                pe.transfer_in_total,
                pe.transfer_out_total,
                a.contract_overdue,
                a.contract_expiring,
                a.probation_overdue,
                a.probation_ending,
                q.missing_history,
                GREATEST((SELECT COUNT(*) FROM scope) - 1, 0) AS descendant_departments
            FROM current_counts cc
            CROSS JOIN period_events pe
            CROSS JOIN alerts a
            CROSS JOIN quality q
            """;

    private final JdbcTemplate jdbc;

    public Snapshot load(UUID organizationId, LocalDate periodStart, LocalDate asOf) {
        LocalDate alertEnd = asOf.plusDays(30);
        return jdbc.queryForObject(
                SQL,
                (rs, rowNum) -> new Snapshot(
                        rs.getLong("direct_current"),
                        rs.getLong("current_total"),
                        rs.getLong("active_total"),
                        rs.getLong("probation_total"),
                        rs.getLong("leave_total"),
                        rs.getLong("hired_total"),
                        rs.getLong("rehired_total"),
                        rs.getLong("departed_total"),
                        rs.getLong("transfer_in_total"),
                        rs.getLong("transfer_out_total"),
                        rs.getLong("contract_overdue"),
                        rs.getLong("contract_expiring"),
                        rs.getLong("probation_overdue"),
                        rs.getLong("probation_ending"),
                        rs.getLong("missing_history"),
                        rs.getLong("descendant_departments")),
                organizationId,
                organizationId,
                periodStart,
                asOf,
                asOf,
                asOf,
                alertEnd,
                asOf,
                asOf,
                alertEnd,
                periodStart,
                asOf,
                periodStart,
                asOf);
    }

    public record Snapshot(
            long directCurrent,
            long current,
            long active,
            long probation,
            long onLeave,
            long hired,
            long rehired,
            long departed,
            long transferIn,
            long transferOut,
            long contractOverdue,
            long contractExpiring,
            long probationOverdue,
            long probationEnding,
            long missingHistory,
            long descendantDepartments) {
    }
}
