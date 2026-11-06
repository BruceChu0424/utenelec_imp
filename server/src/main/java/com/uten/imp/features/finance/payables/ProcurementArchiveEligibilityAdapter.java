package com.uten.imp.features.finance.payables;

import com.uten.imp.application.port.ProcurementArchiveEligibilityPort;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** The finance owner exposes facts; it does not grant archive or settlement authority. */
@Component
@RequiredArgsConstructor
public class ProcurementArchiveEligibilityAdapter implements ProcurementArchiveEligibilityPort {
    private final JdbcTemplate jdbc;

    @Override
    @Transactional(readOnly = true)
    public Map<UUID, Facts> purchaseOrderFacts(Collection<UUID> orderIds) {
        List<UUID> ids = orderIds.stream().distinct().toList();
        if (ids.isEmpty()) return Map.of();
        if (ids.size() > 1_000) throw new IllegalArgumentException("Archive finance fact batch exceeds 1000 orders");
        String parameters = String.join(",", java.util.Collections.nCopies(ids.size(), "?"));
        List<Object> args = new ArrayList<>(ids);
        args.addAll(ids);
        Map<UUID, Facts> facts = new LinkedHashMap<>();
        jdbc.query("""
                WITH sources AS (
                    SELECT DISTINCT oi.order_id, 'PURCHASE_RECEIPT' AS source_type,
                           r.id AS source_id, r.status = 1 AND NOT r.is_deleted AS active
                    FROM purchase_order_items oi
                    JOIN purchase_receipt_items ri ON ri.order_item_id = oi.id
                    JOIN purchase_receipts r ON r.id = ri.receipt_id
                    WHERE oi.order_id IN (%s)
                    UNION
                    SELECT DISTINCT oi.order_id, 'PURCHASE_RETURN' AS source_type,
                           t.id AS source_id, t.status = 1 AND NOT t.is_deleted AS active
                    FROM purchase_order_items oi
                    JOIN purchase_return_items ti ON ti.order_item_id = oi.id
                    JOIN purchase_returns t ON t.id = ti.return_id
                    WHERE oi.order_id IN (%s)
                )
                SELECT source.order_id, count(*) AS reference_count,
                       count(*) FILTER (WHERE source.active AND candidate.status = 'PENDING') AS pending_count,
                       count(*) FILTER (WHERE source.active AND candidate.status = 'CONFIRMED'
                           AND (ledger.id IS NULL OR NOT ledger.is_settled)) AS unsettled_count
                FROM sources source
                JOIN finance_procurement_payable_candidates candidate
                  ON candidate.source_type = source.source_type AND candidate.source_id = source.source_id
                LEFT JOIN ar_ap_ledger ledger ON ledger.id = candidate.ledger_id
                  AND ledger.status = 1 AND NOT ledger.is_deleted
                GROUP BY source.order_id
                """.formatted(parameters, parameters), rs -> {
            facts.put(rs.getObject("order_id", UUID.class), new Facts(
                    rs.getLong("reference_count"), rs.getLong("pending_count"), rs.getLong("unsettled_count")));
        }, args.toArray());
        return Map.copyOf(facts);
    }
}
