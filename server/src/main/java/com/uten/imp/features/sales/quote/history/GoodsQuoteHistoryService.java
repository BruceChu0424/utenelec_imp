package com.uten.imp.features.sales.quote.history;

import com.uten.imp.common.web.PageResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.UUID;

/** Immutable submitted and finance-priced snapshots, never reconstructed from current goods prices. */
@Service
@RequiredArgsConstructor
public class GoodsQuoteHistoryService {
    private final NamedParameterJdbcTemplate jdbc;

    // A line may have been removed from today's quotation. Search the retained snapshots themselves.
    static final String FROM = """
            FROM sales_quote_revision_logs log
            JOIN sales_quotes quote ON quote.id = log.quote_id
            CROSS JOIN LATERAL jsonb_array_elements(log.snapshot->'lines') line
            LEFT JOIN LATERAL (
                SELECT so.id, so.bill_no, so.is_deleted FROM sales_orders so
                WHERE so.source_quote_id = quote.id
                  AND so.client_id::text = log.snapshot->>'clientId'
                ORDER BY so.is_deleted, so.created_at DESC, so.id LIMIT 1
            ) linked_order ON TRUE
            WHERE log.action IN ('SUBMIT', 'FINANCE_EDIT', 'CONFIRM')
              AND log.snapshot @> CAST(:goodsFilter AS jsonb)
              AND line->>'goodsId' = :goodsId
            """;

    public record Row(String id, UUID quoteId, String billNo, int revision, String action,
                      OffsetDateTime occurredAt, String clientName, String sellerName,
                      String qty, String price, String discount, String amount,
                      UUID orderId, String orderNo, boolean orderDeleted) {}

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('goods:view') and hasAuthority('sales_quote_finance:view')")
    public PageResponse<Row> list(UUID goodsId, int page, int size) {
        int limit = Math.clamp(size, 1, 100);
        var params = new MapSqlParameterSource("goodsId", goodsId.toString());
        params.addValue("goodsFilter", "{\"lines\":[{\"goodsId\":\"" + goodsId + "\"}]}");
        Long count = jdbc.queryForObject("SELECT COUNT(*) " + FROM, params, Long.class);
        long total = count == null ? 0 : count;
        int pages = (int) Math.min(Integer.MAX_VALUE, (total + limit - 1) / limit);
        int current = Math.max(1, Math.min(page, Math.max(1, pages)));
        params.addValue("limit", limit).addValue("offset", (long) (current - 1) * limit);
        var rows = jdbc.query("""
                SELECT log.id::text || ':' || COALESCE(line->>'id', line->>'lineNo', '') AS id,
                       quote.id AS quote_id, quote.bill_no, log.revision, log.action, log.created_at,
                       COALESCE(NULLIF(log.snapshot->>'clientName', ''), '历史未记录') AS client_name,
                       COALESCE(NULLIF(log.snapshot->>'sellerName', ''), '历史未记录') AS seller_name,
                       line->>'qty' AS qty, line->>'price' AS price,
                       line->>'discount' AS discount, line->>'amount' AS amount,
                       linked_order.id AS order_id, linked_order.bill_no AS order_no,
                       COALESCE(linked_order.is_deleted, false) AS order_deleted
                """ + FROM + " ORDER BY log.created_at DESC, log.id DESC, line->>'id' LIMIT :limit OFFSET :offset",
                params, (rs, index) -> new Row(rs.getString("id"), rs.getObject("quote_id", UUID.class),
                        rs.getString("bill_no"), rs.getInt("revision"), rs.getString("action"),
                        rs.getObject("created_at", OffsetDateTime.class), rs.getString("client_name"),
                        rs.getString("seller_name"), rs.getString("qty"), rs.getString("price"),
                        rs.getString("discount"), rs.getString("amount"), rs.getObject("order_id", UUID.class),
                        rs.getString("order_no"), rs.getBoolean("order_deleted")));
        return new PageResponse<>(rows, current, limit, total, pages);
    }
}
