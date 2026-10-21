package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.application.port.WarehouseTaskRowCountPort;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/** Reuses the list projections, including physical line identity and line warehouse overrides. */
@Service
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class WarehouseTaskRowCountService implements WarehouseTaskRowCountPort {
    private final NamedParameterJdbcTemplate jdbc;
    private final ProductionStockTaskAccessPolicy productionAccess;
    private final SecurityContextCurrentUser currentUser;

    @Override public Map<String, Long> inboundExpectations(WarehouseTaskScope scope) {
        var counts = new LinkedHashMap<String, Long>();
        counts.put("PURCHASE", 0L);
        counts.put("SUBCONTRACT", 0L);
        jdbc.query(WarehouseInboundTaskCenterSql.expectationBadgeSql(scope(scope)), parameters(scope),
                rs -> { counts.put(rs.getString(1), rs.getLong(2)); });
        return counts;
    }

    @Override public long finishedInbound(WarehouseTaskScope scope) {
        if (!productionAccess.canAccessWarehouseTasks()) return 0;
        return scalar(WarehouseInboundTaskCenterSql.finishedBadgeSql(scope(scope)), parameters(scope));
    }

    @Override public long productionReturn(WarehouseTaskScope scope) {
        if (!productionAccess.canAccessWarehouseTasks()) return 0;
        return scalar(WarehouseInboundTaskCenterSql.returnBadgeSql(scope(scope)), parameters(scope));
    }

    @Override public long subcontractOutbound(WarehouseTaskScope scope) {
        var plan = outbound("SUBCONTRACT", scope, false, true, false);
        return scalar(plan.cte() + " SELECT COUNT(*) FROM filtered WHERE actionable", plan.parameters());
    }

    @Override public Map<String, Long> salesOutbound(WarehouseTaskScope scope) {
        var plan = outbound("SALES", scope, true, false, false);
        var counts = new LinkedHashMap<String, Long>();
        for (String status : java.util.List.of("PENDING_PICK", "LEGACY_PENDING", "SHIPPED", "CANCELLED", "REVERSED")) counts.put(status, 0L);
        jdbc.query(plan.cte() + " SELECT status, COUNT(*) FROM filtered GROUP BY status", plan.parameters(), rs -> {
            String status = switch (rs.getString(1)) {
                case "SALES_PENDING" -> "PENDING_PICK";
                case "SALES_SHIPPED" -> "SHIPPED";
                case "SALES_CANCELLED" -> "CANCELLED";
                case "SALES_REVERSED" -> "REVERSED";
                case "SALES_LEGACY" -> "LEGACY_PENDING";
                default -> "";
            };
            if (!status.isEmpty()) counts.merge(status, rs.getLong(2), Long::sum);
        });
        return counts;
    }

    @Override public Map<String, Long> productionDraw(WarehouseTaskScope scope) {
        var counts = new LinkedHashMap<String, Long>();
        for (String status : Set.of("READY_TO_PICK", "PARTIAL", "MATERIALS_TO_DEFINE", "OPEN_ANY")) counts.put(status, 0L);
        if (!productionAccess.canAccessWarehouseTasks() || !hasAuthorities("stock_doc:view", "stock_doc:approve", "stock_doc:issue")) return counts;
        var plan = outbound("DRAW", scope, false, false, true);
        jdbc.query(plan.cte() + " SELECT status, COUNT(*) FROM filtered WHERE actionable GROUP BY status", plan.parameters(), rs -> {
            String status = switch (rs.getString(1)) {
                case "DRAW_PENDING" -> "READY_TO_PICK";
                case "DRAW_PARTIAL" -> "PARTIAL";
                case "DRAW_DISCOVERY_PENDING" -> "MATERIALS_TO_DEFINE";
                default -> "";
            };
            if (!status.isEmpty()) {
                counts.merge(status, rs.getLong(2), Long::sum);
                counts.merge("OPEN_ANY", rs.getLong(2), Long::sum);
            }
        });
        return counts;
    }

    private WarehouseOutboundTaskCenterSql.Plan outbound(String source, WarehouseTaskScope scope,
            boolean sales, boolean subcontract, boolean production) {
        var filter = new WarehouseTaskCenterContracts.Filter(source, null, "", null, null, null,
                null, 1, 1, null, null, WarehouseTaskCenterContracts.TaskView.ALL);
        var access = new WarehouseOutboundTaskCenterSql.Access(sales, subcontract, false, production,
                production, new OwnerScope(false, Set.of()));
        return WarehouseOutboundTaskCenterSql.build(filter, access, scope(scope), "");
    }

    private boolean hasAuthorities(String... required) {
        var actor = currentUser.get().orElse(null);
        if (actor == null || actor.isVisitor()) return false;
        if (actor.isSuperAdmin()) return true;
        var granted = actor.getAuthorities().stream().map(authority -> authority.getAuthority()).collect(java.util.stream.Collectors.toSet());
        return java.util.Arrays.stream(required).allMatch(granted::contains);
    }

    private long scalar(String sql, Map<String, ?> parameters) {
        Long count = jdbc.queryForObject(sql, parameters, Long.class);
        return count == null ? 0 : count;
    }
    private long scalar(String sql, MapSqlParameterSource parameters) {
        Long count = jdbc.queryForObject(sql, parameters, Long.class);
        return count == null ? 0 : count;
    }
    private static WarehouseTaskScope scope(WarehouseTaskScope scope) { return scope == null ? WarehouseTaskScope.ALL : scope; }
    private static MapSqlParameterSource parameters(WarehouseTaskScope scope) {
        return new MapSqlParameterSource("warehouseScope", scope(scope).idsCsv()).addValue("ownDraftMaker", "");
    }
}
