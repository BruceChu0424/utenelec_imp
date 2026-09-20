package com.uten.imp.features.finance.payables;

import com.uten.imp.features.finance.LegacyOpeningBalanceSql;

/** Dated statement projection shared by the service and real PostgreSQL contract. */
final class SupplierSettlementSnapshotSql {
    private SupplierSettlementSnapshotSql() {}
    static final String LINES = """
                WITH payment_event AS (
                    SELECT line.applied_ledger_id AS ledger_id,
                           payment.bill_date AS event_date,
                           line.amount_original AS amount_original,
                           %s AS amount_local
                    FROM finance_payment_lines line
                    JOIN finance_payments payment ON payment.id=line.payment_id
                    WHERE payment.status IN(1,-1) AND payment.legacy_id IS NULL
                      AND COALESCE(payment.is_deleted,FALSE)=FALSE
                      AND COALESCE(line.is_deleted,FALSE)=FALSE
                    UNION ALL
                    SELECT line.applied_ledger_id,
                           (COALESCE(payment.reversed_at, payment.updated_at)
                               AT TIME ZONE 'Asia/Shanghai')::DATE,
                           -line.amount_original,
                           -%s
                    FROM finance_payment_lines line
                    JOIN finance_payments payment ON payment.id=line.payment_id
                    WHERE payment.status=-1 AND payment.legacy_id IS NULL
                      AND COALESCE(payment.is_deleted,FALSE)=FALSE
                      AND COALESCE(line.is_deleted,FALSE)=FALSE
                ), offset_event AS (
                    SELECT target_ledger_id AS ledger_id,effective_date AS event_date,
                           amount_original,target_amount_local AS amount_local
                    FROM supplier_open_item_offsets
                    UNION ALL
                    SELECT source_ledger_id,effective_date,-amount_original,-source_amount_local
                    FROM supplier_open_item_offsets
                    UNION ALL
                    SELECT target_ledger_id,
                           (reversed_at AT TIME ZONE 'Asia/Shanghai')::DATE,
                           -amount_original,-target_amount_local
                    FROM supplier_open_item_offsets WHERE status='REVERSED'
                    UNION ALL
                    SELECT source_ledger_id,
                           (reversed_at AT TIME ZONE 'Asia/Shanghai')::DATE,
                           amount_original,source_amount_local
                    FROM supplier_open_item_offsets WHERE status='REVERSED'
                ), payment_sum AS (
                    SELECT ledger_id,
                           COALESCE(SUM(amount_original) FILTER (WHERE event_date<:start),0) prior_original,
                           COALESCE(SUM(amount_original) FILTER (WHERE event_date BETWEEN :start AND :end),0) period_original,
                           COALESCE(SUM(amount_local) FILTER (WHERE event_date<:start),0) prior_local,
                           COALESCE(SUM(amount_local) FILTER (WHERE event_date BETWEEN :start AND :end),0) period_local
                    FROM payment_event WHERE event_date<=:end GROUP BY ledger_id
                ), offset_sum AS (
                    SELECT ledger_id,
                           COALESCE(SUM(amount_original) FILTER (WHERE event_date<:start),0) prior_original,
                           COALESCE(SUM(amount_original) FILTER (WHERE event_date BETWEEN :start AND :end),0) period_original,
                           COALESCE(SUM(amount_local) FILTER (WHERE event_date<:start),0) prior_local,
                           COALESCE(SUM(amount_local) FILTER (WHERE event_date BETWEEN :start AND :end),0) period_local
                    FROM offset_event WHERE event_date<=:end GROUP BY ledger_id
                ), source AS (
                    SELECT ledger.*,
                           %s AS posted_original,
                           %s AS posted_local,
                           CASE WHEN ledger.status=-1
                                THEN (ledger.deleted_at AT TIME ZONE 'Asia/Shanghai')::DATE END AS reversal_date
                    FROM ar_ap_ledger ledger
                    %s
                    LEFT JOIN finance_payments payment
                      ON ledger.source_doc_type='DIRECT_PAYMENT'
                     AND payment.id=ledger.source_doc_id AND payment.status IN(1,-1)
                    WHERE ledger.direction='AP'
                      AND ((ledger.status=1 AND COALESCE(ledger.is_deleted,FALSE)=FALSE)
                        OR (ledger.status=-1 AND COALESCE(ledger.is_deleted,FALSE)=TRUE
                            AND ledger.deleted_at IS NOT NULL))
                      AND ledger.supplier_id=:supplierId AND ledger.currency_id=:currencyId
                      AND ledger.bill_date<=:end
                )
                SELECT source.id,source.business_type,source.open_item_kind,
                       source.source_doc_type,source.source_doc_id,source.source_doc_no,
                       source.bill_date,source.due_date,source.exchange_rate,
                       CASE WHEN source.bill_date<:start THEN source.posted_original ELSE 0 END
                           - CASE WHEN source.reversal_date<:start THEN source.posted_original ELSE 0 END
                           - COALESCE(payment_sum.prior_original,0)-COALESCE(offset_sum.prior_original,0),
                       CASE WHEN source.bill_date BETWEEN :start AND :end THEN source.posted_original ELSE 0 END
                           - CASE WHEN source.reversal_date BETWEEN :start AND :end THEN source.posted_original ELSE 0 END,
                       COALESCE(payment_sum.period_original,0),COALESCE(offset_sum.period_original,0),
                       CASE WHEN source.bill_date<=:end THEN source.posted_original ELSE 0 END
                           - CASE WHEN source.reversal_date<=:end THEN source.posted_original ELSE 0 END
                           - COALESCE(payment_sum.prior_original,0)-COALESCE(payment_sum.period_original,0)
                           - COALESCE(offset_sum.prior_original,0)-COALESCE(offset_sum.period_original,0),
                       CASE WHEN source.bill_date<:start THEN source.posted_local ELSE 0 END
                           - CASE WHEN source.reversal_date<:start THEN source.posted_local ELSE 0 END
                           - COALESCE(payment_sum.prior_local,0)-COALESCE(offset_sum.prior_local,0),
                       CASE WHEN source.bill_date BETWEEN :start AND :end THEN source.posted_local ELSE 0 END
                           - CASE WHEN source.reversal_date BETWEEN :start AND :end THEN source.posted_local ELSE 0 END,
                       COALESCE(payment_sum.period_local,0),COALESCE(offset_sum.period_local,0),
                       CASE WHEN source.bill_date<=:end THEN source.posted_local ELSE 0 END
                           - CASE WHEN source.reversal_date<=:end THEN source.posted_local ELSE 0 END
                           - COALESCE(payment_sum.prior_local,0)-COALESCE(payment_sum.period_local,0)
                           - COALESCE(offset_sum.prior_local,0)-COALESCE(offset_sum.period_local,0),
                       source.settlement_type_id
                FROM source
                LEFT JOIN payment_sum ON payment_sum.ledger_id=source.id
                LEFT JOIN offset_sum ON offset_sum.ledger_id=source.id
                ORDER BY source.bill_date,source.source_doc_no,source.id
                """.formatted(
                    LegacyOpeningBalanceSql.paymentBookLocal("line"),LegacyOpeningBalanceSql.paymentBookLocal("line"),
                    LegacyOpeningBalanceSql.originalAmount("CASE WHEN ledger.open_item_kind='PREPAYMENT' THEN -COALESCE(payment.amount_original,0) ELSE ledger.amount_original END"),
                    LegacyOpeningBalanceSql.localAmount("CASE WHEN ledger.open_item_kind='PREPAYMENT' THEN -COALESCE(payment.amount_local,0) ELSE ledger.amount_original_local END"),
                    LegacyOpeningBalanceSql.PROOF_JOIN);

    // A snapshot records aggregate balances at a verified instant, not the
    // original dates of each historical payment. A monthly window crossing
    // that business day cannot be reconstructed from this source.
    static final String UNREPLAYABLE_OPENING = """
            SELECT count(*) FROM ar_ap_ledger ledger
            %s
            WHERE ledger.direction='AP' AND ledger.supplier_id=:supplierId
              AND ledger.currency_id=:currencyId AND ledger.bill_date<=:end
              AND ledger.status=1 AND COALESCE(ledger.is_deleted,FALSE)=FALSE
              AND %s
            """.formatted(LegacyOpeningBalanceSql.PROOF_JOIN,
                    LegacyOpeningBalanceSql.unreplayableCondition("start"));
}
