package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryPositionPort.Owner;
import java.math.BigDecimal;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

/** Current physical positions, found from the indexed owner and proved against the original root. */
final class InventoryOwnerPositions {
    private InventoryOwnerPositions() {}

    static final String REMAINING_SQL="""
            SELECT root.id,root.kind,head.owner_id,head.range_to-head.range_from qty
            FROM stock_value_nodes head JOIN stock_value_nodes root
              ON root.id=head.root_issue_id AND root.return_head_id=head.id
            WHERE head.active AND root.root_issue_id=root.id
              AND head.owner_kind=:owner AND head.owner_id IN (:ids)
              AND head.range_to>head.range_from ORDER BY root.created_at,root.id
            """;

    record Available(UUID rootId,UUID ownerId,BigDecimal quantity,String kind) {}

    static List<Available> remaining(NamedParameterJdbcTemplate db,Owner owner,Collection<UUID> ids) {
        if(ids.isEmpty())return List.of();
        return db.query(REMAINING_SQL,Map.of("owner",owner.name(),"ids",List.copyOf(ids)),
                (row,index)->new Available(row.getObject("id",UUID.class),row.getObject("owner_id",UUID.class),row.getBigDecimal("qty"),row.getString("kind")));
    }
}
