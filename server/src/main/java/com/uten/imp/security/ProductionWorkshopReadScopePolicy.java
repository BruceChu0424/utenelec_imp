package com.uten.imp.security;

import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Authorization dimensions for the exact shared assignment predicate, never business task filters. */
@Component
public final class ProductionWorkshopReadScopePolicy {
    private final NamedParameterJdbcTemplate jdbc;
    public ProductionWorkshopReadScopePolicy(NamedParameterJdbcTemplate jdbc) { this.jdbc=jdbc; }
    public record Snapshot(boolean all,UUID responsibleEmployee,List<UUID> workshops) {
        public Snapshot { workshops=List.copyOf(workshops); }
    }
    public Snapshot snapshot(AuthUser actor) {
        if(actor.isSuperAdmin())return new Snapshot(true,null,List.of());
        UUID employee=actor.getEmployeeId();
        if(employee==null)return new Snapshot(false,null,List.of());
        Map<String,Object> parameters=Map.of("employeeId",employee);
        String predicate=ProductionWorkshopAssignmentScope.predicate("read_task");
        Boolean eligible=jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM (SELECT NULL::uuid AS workshop_department_id,CAST(:employeeId AS uuid) AS responsible_employee_id) read_task WHERE "+predicate+")",parameters,Boolean.class);
        if(!Boolean.TRUE.equals(eligible))return new Snapshot(false,null,List.of());
        // Department dimensions remain bounded by organization size. Reuse the
        // original predicate against virtual workshop roots; don't enumerate
        // every historical execution segment or maintain another tree algorithm.
        List<UUID> workshops=jdbc.queryForList("SELECT department.id FROM departments department CROSS JOIN LATERAL (SELECT department.id AS workshop_department_id,NULL::uuid AS responsible_employee_id) read_task WHERE "+predicate+" ORDER BY department.id",parameters,UUID.class);
        return new Snapshot(false,employee,workshops);
    }
}
