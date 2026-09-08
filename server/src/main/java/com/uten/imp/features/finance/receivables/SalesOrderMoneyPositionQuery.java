package com.uten.imp.features.finance.receivables;

import com.uten.imp.common.util.NativeValueConverters;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.util.UUID;

/** Read-only order attribution of invoice balances, return credits and future shipment value. */
@Service
@RequiredArgsConstructor
public class SalesOrderMoneyPositionQuery {
    private final EntityManager em;

    public InvoicePosition invoices(UUID orderId) {
        Object[] row = (Object[]) em.createNativeQuery("""
                WITH missing_sources AS (
                    SELECT DISTINCT ledger.id FROM sales_order_items ordered
                    JOIN sales_shipment_items shipped ON shipped.order_item_id=ordered.id
                    JOIN ar_ap_ledger ledger ON ledger.source_doc_id=shipped.shipment_id
                    WHERE ordered.order_id=:orderId AND ledger.source_doc_type='SALES_SHIPMENT'
                      AND ledger.direction='AR' AND ledger.status=1 AND NOT ledger.is_deleted
                      AND NOT EXISTS(SELECT 1 FROM ar_ap_source_refs source WHERE source.ledger_id=ledger.id
                                     AND source.source_type='SALES_ORDER' AND source.source_id=:orderId)
                ), target_ledgers AS (
                    SELECT ledger_id FROM ar_ap_source_refs
                    WHERE source_type='SALES_ORDER' AND source_id=:orderId
                ), sources AS (
                    SELECT source.* FROM ar_ap_source_refs source
                    JOIN target_ledgers target ON target.ledger_id=source.ledger_id
                    WHERE source.source_type='SALES_ORDER'
                ), cash AS (
                    SELECT allocation.source_ref_id,
                           SUM(allocation.cash_original+allocation.write_off_original) AS original,
                           SUM(allocation.applied_book_local) AS local,
                           SUM(allocation.cash_original) AS cash_original,
                           SUM(allocation.cash_local) AS cash_local
                    FROM finance_receipt_source_allocations allocation
                    JOIN sources source ON source.id=allocation.source_ref_id
                    WHERE allocation.status='APPLIED' GROUP BY allocation.source_ref_id
                ), advances AS (
                    SELECT application.target_source_ref_id,
                           SUM(application.amount_original) AS original,
                           SUM(application.target_amount_local) AS local
                    FROM customer_open_item_offsets application
                    JOIN sources source ON source.id=application.target_source_ref_id
                    WHERE application.status='APPLIED' GROUP BY application.target_source_ref_id
                ), remaining AS (
                    SELECT source.*, COALESCE(cash.original,0)+COALESCE(advances.original,0) AS applied_original,
                           COALESCE(cash.local,0)+COALESCE(advances.local,0) AS applied_local,
                           COALESCE(cash.cash_original,0) AS cash_original, COALESCE(cash.cash_local,0) AS cash_local
                    FROM sources source LEFT JOIN cash ON cash.source_ref_id=source.id
                    LEFT JOIN advances ON advances.target_source_ref_id=source.id
                ), proof AS (
                    SELECT ledger_id, COUNT(*) AS source_count, SUM(amount_original) AS original,
                           SUM(amount_local) AS local, SUM(applied_original) AS applied_original,
                           SUM(applied_local) AS applied_local, SUM(cash_original) AS cash_original, SUM(cash_local) AS cash_local
                    FROM remaining GROUP BY ledger_id
                ), attributed AS (
                    SELECT source.amount_original, source.amount_local,
                           CASE WHEN proof.source_count=1 THEN ledger.amount_balance_original
                                ELSE source.amount_original-source.applied_original END AS remaining_original,
                           CASE WHEN proof.source_count=1 THEN ledger.amount_balance
                                ELSE source.amount_local-source.applied_local END AS remaining_local,
                           (proof.original=ledger.amount_original AND proof.local=ledger.amount_original_local
                            AND ledger.client_id=orders.client_id AND ledger.currency_id=orders.currency_id
                            AND ledger.amount_balance_original BETWEEN 0 AND ledger.amount_original
                            AND ledger.amount_balance BETWEEN 0 AND ledger.amount_original_local
                            AND (proof.source_count=1 OR
                                 (proof.applied_original=ledger.amount_original-ledger.amount_balance_original
                                  AND proof.applied_local=ledger.amount_original_local-ledger.amount_balance))) AS proven,
                           (proof.cash_original=ledger.amount_received_original
                            AND proof.cash_local=ledger.amount_received_local) AS cash_proven
                    FROM remaining source JOIN proof ON proof.ledger_id=source.ledger_id
                    JOIN ar_ap_ledger ledger ON ledger.id=source.ledger_id
                    JOIN sales_orders orders ON orders.id=source.source_id
                    WHERE source.source_id=:orderId AND ledger.source_doc_type='SALES_SHIPMENT'
                      AND ledger.direction='AR' AND ledger.open_item_kind='RECEIVABLE'
                      AND ledger.status=1 AND NOT ledger.is_deleted
                )
                SELECT COALESCE(SUM(amount_original),0), COALESCE(SUM(amount_local),0),
                       COALESCE(SUM(remaining_original),0), COALESCE(SUM(remaining_local),0),
                       COUNT(*) FILTER(WHERE proven IS NOT TRUE OR remaining_original<0 OR remaining_local<0)
                         + (SELECT COUNT(*) FROM missing_sources),
                       COUNT(*) FILTER(WHERE cash_proven IS NOT TRUE)
                FROM attributed
                """).setParameter("orderId", orderId).getSingleResult();
        return new InvoicePosition(decimal(row[0]), decimal(row[1]), decimal(row[2]), decimal(row[3]), count(row[4]), count(row[5]));
    }

    public ReturnPosition returns(UUID orderId) {
        Object[] row = (Object[]) em.createNativeQuery("""
                WITH related AS (
                    SELECT item.return_id FROM sales_order_items ordered
                    JOIN sales_return_items item ON item.order_item_id=ordered.id
                    WHERE ordered.order_id=:orderId
                    UNION
                    SELECT item.return_id FROM sales_order_items ordered
                    JOIN sales_shipment_items shipped ON shipped.order_item_id=ordered.id
                    JOIN sales_return_items item ON item.out_item_id=shipped.id
                    WHERE ordered.order_id=:orderId
                    UNION
                    SELECT returned.id FROM sales_order_items ordered
                    JOIN sales_shipment_items shipped ON shipped.order_item_id=ordered.id
                    JOIN sales_returns returned ON returned.source_shipment_id=shipped.shipment_id
                    WHERE ordered.order_id=:orderId
                ), documents AS (
                    SELECT returned.* FROM sales_returns returned JOIN related ON related.return_id=returned.id
                    WHERE returned.status=1 AND NOT returned.is_deleted
                ), credits AS (
                    SELECT ledger.*, COUNT(*) OVER(PARTITION BY ledger.source_doc_id) AS credit_count
                    FROM ar_ap_ledger ledger JOIN documents ON documents.id=ledger.source_doc_id
                    WHERE ledger.source_doc_type='SALES_RETURN' AND ledger.direction='AR'
                      AND ledger.status=1 AND NOT ledger.is_deleted
                ), lines AS (
                    SELECT item.return_id, COUNT(*) AS line_count, COUNT(DISTINCT orders.id) AS order_count,
                           COUNT(*) FILTER(WHERE orders.id=:orderId) AS target_count,
                           SUM(item.amount_original) AS original, SUM(item.amount_local) AS local,
                           COALESCE(SUM(item.amount_original) FILTER(WHERE orders.id=:orderId),0) AS target_original,
                           COALESCE(SUM(item.amount_local) FILTER(WHERE orders.id=:orderId),0) AS target_local,
                           BOOL_AND(item.qty>0 AND item.amount_original IS NOT NULL AND item.amount_original>=0
                             AND item.amount_local IS NOT NULL AND item.amount_local>=0 AND orders.id IS NOT NULL
                             AND orders.client_id=documents.client_id AND orders.currency_id=documents.currency_id
                             AND (item.out_item_id IS NULL OR
                                  (shipped.id IS NOT NULL AND shipped.order_item_id IS NOT NULL
                                   AND (item.order_item_id IS NULL OR item.order_item_id=shipped.order_item_id)))) AS proven
                    FROM sales_return_items item JOIN documents ON documents.id=item.return_id
                    LEFT JOIN sales_shipment_items shipped ON shipped.id=item.out_item_id
                    LEFT JOIN sales_order_items ordered ON ordered.id=CASE WHEN item.out_item_id IS NULL
                          THEN item.order_item_id ELSE shipped.order_item_id END
                    LEFT JOIN sales_orders orders ON orders.id=ordered.order_id
                    WHERE NOT item.is_deleted GROUP BY item.return_id
                ), checked AS (
                    SELECT documents.id, lines.target_original, lines.target_local, lines.target_count,
                           lines.order_count, credits.amount_balance_original, credits.amount_balance,
                           credits.amount_original, credits.amount_original_local,
                           (lines.proven IS TRUE AND lines.line_count>0 AND credits.credit_count=1
                            AND documents.ar_posted AND documents.currency_id IS NOT NULL
                            AND credits.client_id=documents.client_id AND credits.currency_id=documents.currency_id
                            AND credits.exchange_rate IS NOT DISTINCT FROM documents.exchange_rate
                            AND credits.amount_original=-documents.total_original
                            AND credits.amount_original_local=-documents.total_local
                            AND lines.original=documents.total_original AND lines.local=documents.total_local
                            AND credits.amount_balance_original BETWEEN credits.amount_original AND 0
                            AND credits.amount_balance BETWEEN credits.amount_original_local AND 0) AS proven,
                           (lines.order_count=1
                             OR (credits.amount_balance_original=credits.amount_original
                                 AND credits.amount_balance=credits.amount_original_local)
                             OR (credits.amount_balance_original=0 AND credits.amount_balance=0)) AS balance_proven
                    FROM documents LEFT JOIN lines ON lines.return_id=documents.id
                    LEFT JOIN credits ON credits.source_doc_id=documents.id
                )
                SELECT COALESCE(SUM(target_original) FILTER(WHERE proven IS TRUE),0),
                       COALESCE(SUM(target_local) FILTER(WHERE proven IS TRUE),0),
                       COALESCE(SUM(CASE WHEN target_count=0 THEN 0 WHEN order_count=1 THEN -amount_balance_original
                                        WHEN amount_balance_original=0 AND amount_balance=0 THEN 0 ELSE target_original END)
                                FILTER(WHERE proven IS TRUE AND balance_proven IS TRUE),0),
                       COALESCE(SUM(CASE WHEN target_count=0 THEN 0 WHEN order_count=1 THEN -amount_balance
                                        WHEN amount_balance_original=0 AND amount_balance=0 THEN 0 ELSE target_local END)
                                FILTER(WHERE proven IS TRUE AND balance_proven IS TRUE),0),
                       COUNT(DISTINCT id) FILTER(WHERE proven IS NOT TRUE
                                 OR (target_count>0 AND balance_proven IS NOT TRUE))
                FROM checked
                """).setParameter("orderId", orderId).getSingleResult();
        return new ReturnPosition(decimal(row[0]), decimal(row[1]), decimal(row[2]), decimal(row[3]), count(row[4]));
    }

    public FuturePosition future(UUID orderId) {
        Object[] row = (Object[]) em.createNativeQuery("""
                SELECT COALESCE(SUM(CASE WHEN orders.is_stopped OR orders.status<>1 THEN 0
                     WHEN item.qty>0 THEN ROUND(item.amount_original
                       * GREATEST(item.qty-COALESCE(item.shipped_qty,0)+COALESCE(item.returned_qty,0)
                                  -COALESCE(item.flag_qty,0),0)/item.qty,4)
                     ELSE 0 END),0),
                       COUNT(*) FILTER(WHERE item.qty<=0 OR item.amount_original IS NULL
                         OR item.amount_original<0 OR item.shipped_qty<0 OR item.returned_qty<0
                         OR item.flag_qty<0 OR COALESCE(item.returned_qty,0)>COALESCE(item.shipped_qty,0)), COUNT(*)
                FROM sales_orders orders JOIN sales_order_items item ON item.order_id=orders.id
                WHERE orders.id=:orderId AND NOT item.is_deleted
                """).setParameter("orderId", orderId).getSingleResult();
        return new FuturePosition(decimal(row[0]), count(row[1]), count(row[2]));
    }

    private static BigDecimal decimal(Object value) { return NativeValueConverters.toBigDecimal(value); }
    private static long count(Object value) { return ((Number) value).longValue(); }
    public record InvoicePosition(BigDecimal grossOriginal, BigDecimal grossLocal, BigDecimal remainingOriginal,
                                  BigDecimal remainingLocal, long unresolvedCount, long unresolvedCashCount) {}
    public record ReturnPosition(BigDecimal totalOriginal, BigDecimal totalLocal, BigDecimal unusedOriginal,
                                 BigDecimal unusedLocal, long unresolvedCount) {}
    public record FuturePosition(BigDecimal original, long unresolvedCount, long itemCount) {}
}
