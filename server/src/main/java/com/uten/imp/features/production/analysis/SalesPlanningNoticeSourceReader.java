package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.SalesPlanningNoticeReadPort;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.UUID;

@Component
public class SalesPlanningNoticeSourceReader implements SalesPlanningNoticeReadPort {
    private final JdbcTemplate jdbc;
    public SalesPlanningNoticeSourceReader(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    private static final String INITIAL_HANDOFF = """
            AND NOT o.finance_rejected AND o.requoted_to_id IS NULL
            AND NOT EXISTS (
                SELECT 1 FROM production_material_analysis_items taken
                JOIN sales_order_items original ON original.id=taken.sales_order_item_id
                WHERE original.order_id=o.id AND taken.source_type='SALES_ORDER_ITEM')
            """;

    @Override public boolean needsInitialHandoff(UUID orderId) {
        // Creation is the persisted handoff, including a partial, later cancelled or soft-deleted analysis.
        // Reopening residual demand does not turn it into a never-handled initial order.
        return Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 "
                + MaterialAnalysisSalesSourceQuery.fromWhere("", false) + INITIAL_HANDOFF + " AND o.id=?)",
                Boolean.class, orderId));
    }

    @Override public List<UUID> initialHandoffOrdersAfter(UUID afterId, int limit) {
        return jdbc.queryForList("SELECT DISTINCT o.id " + MaterialAnalysisSalesSourceQuery.fromWhere("", false)
                        + INITIAL_HANDOFF + (afterId == null ? "" : " AND o.id > ?") + " ORDER BY o.id LIMIT ?",
                UUID.class, afterId == null ? new Object[]{Math.min(Math.max(limit, 1), 100)}
                        : new Object[]{afterId, Math.min(Math.max(limit, 1), 100)});
    }
}
