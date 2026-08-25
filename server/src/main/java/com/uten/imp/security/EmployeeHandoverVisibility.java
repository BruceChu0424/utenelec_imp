package com.uten.imp.security;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * Resolves the append-only employee responsibility handover graph (V393).
 * The latest completed source+scope edge wins; older edges remain audit facts.
 */
@Component
@RequiredArgsConstructor
public class EmployeeHandoverVisibility {

    private final EntityManager em;

    /** Raw historical owner ids whose current responsibility ends at this employee. */
    public Set<UUID> inheritedOwners(UUID employeeId, String scope) {
        if (employeeId == null) return Set.of();
        List<UUID> rows = NativeQueryResults.typedRows(em.createNativeQuery("""
                WITH RECURSIVE ranked_edges AS (
                        SELECT handover.source_employee_id,
                               handover.target_employee_id,
                               handover.target_employment_generation,
                               row_number() OVER (
                                   PARTITION BY handover.source_employee_id
                                   ORDER BY handover.sequence_no DESC) AS position
                        FROM employee_data_handovers handover
                        JOIN employee_data_handover_scopes handover_scope
                          ON handover_scope.handover_id = handover.id
                        JOIN employees source_employee
                          ON source_employee.id=handover.source_employee_id
                         AND source_employee.is_deleted=false
                        WHERE handover.status = 'COMPLETED'
                          AND handover_scope.scope = :scope
                          AND handover.source_employment_generation=(
                              SELECT count(*) FROM employment_history history
                              WHERE history.employee_id=handover.source_employee_id
                                AND history.event_type='rehire')
                ), latest_edges AS (
                    SELECT ranked.source_employee_id, ranked.target_employee_id
                    FROM ranked_edges ranked
                    JOIN employees target_employee
                      ON target_employee.id=ranked.target_employee_id
                     AND target_employee.is_deleted=false
                    WHERE ranked.position=1
                      AND ranked.target_employment_generation=(
                              SELECT count(*) FROM employment_history history
                              WHERE history.employee_id=ranked.target_employee_id
                                AND history.event_type='rehire')
                ), inherited(owner_employee_id, path) AS (
                    SELECT edge.source_employee_id,
                           ARRAY[edge.target_employee_id, edge.source_employee_id]
                    FROM latest_edges edge
                    WHERE edge.target_employee_id = :employeeId
                    UNION ALL
                    SELECT edge.source_employee_id,
                           inherited.path || edge.source_employee_id
                    FROM inherited
                    JOIN latest_edges edge
                      ON edge.target_employee_id = inherited.owner_employee_id
                    WHERE NOT edge.source_employee_id = ANY(inherited.path)
                )
                SELECT DISTINCT owner_employee_id FROM inherited
                """)
                .setParameter("employeeId", employeeId)
                .setParameter("scope", scope), UUID.class);
        return Set.copyOf(new HashSet<>(rows));
    }

    /** Resolve an upstream historical owner to the latest current successor. */
    public UUID currentResponsible(String scope, UUID historicalOwnerId) {
        if (historicalOwnerId == null) return null;
        List<UUID> rows = NativeQueryResults.typedRows(em.createNativeQuery("""
                WITH RECURSIVE ranked_edges AS (
                        SELECT handover.source_employee_id,
                               handover.target_employee_id,
                               handover.target_employment_generation,
                               row_number() OVER (
                                   PARTITION BY handover.source_employee_id
                                   ORDER BY handover.sequence_no DESC) AS position
                        FROM employee_data_handovers handover
                        JOIN employee_data_handover_scopes handover_scope
                          ON handover_scope.handover_id = handover.id
                        JOIN employees source_employee
                          ON source_employee.id=handover.source_employee_id
                         AND source_employee.is_deleted=false
                        WHERE handover.status = 'COMPLETED'
                          AND handover_scope.scope = :scope
                          AND handover.source_employment_generation=(
                              SELECT count(*) FROM employment_history history
                              WHERE history.employee_id=handover.source_employee_id
                                AND history.event_type='rehire')
                ), latest_edges AS (
                    SELECT ranked.source_employee_id, ranked.target_employee_id
                    FROM ranked_edges ranked
                    JOIN employees target_employee
                      ON target_employee.id=ranked.target_employee_id
                     AND target_employee.is_deleted=false
                    WHERE ranked.position=1
                      AND ranked.target_employment_generation=(
                              SELECT count(*) FROM employment_history history
                              WHERE history.employee_id=ranked.target_employee_id
                                AND history.event_type='rehire')
                ), chain(employee_id, path, depth) AS (
                    SELECT CAST(:ownerId AS UUID), ARRAY[CAST(:ownerId AS UUID)], 0
                    UNION ALL
                    SELECT edge.target_employee_id,
                           chain.path || edge.target_employee_id,
                           chain.depth + 1
                    FROM chain
                    JOIN latest_edges edge
                      ON edge.source_employee_id = chain.employee_id
                    WHERE NOT edge.target_employee_id = ANY(chain.path)
                )
                SELECT employee_id FROM chain ORDER BY depth DESC LIMIT 1
                """)
                .setParameter("ownerId", historicalOwnerId)
                .setParameter("scope", scope), UUID.class);
        return rows.isEmpty() ? historicalOwnerId : rows.get(0);
    }
}
