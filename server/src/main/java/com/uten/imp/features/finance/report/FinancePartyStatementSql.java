package com.uten.imp.features.finance.report;

import com.uten.imp.features.finance.LegacyOpeningBalanceSql;

/** One dated event stream for AR/AP flow, detail and annual statements. */
final class FinancePartyStatementSql {
    private FinancePartyStatementSql() { }

    static String events(boolean receivable, String documentScope) {
        String party=receivable ? "client_id" : "supplier_id";
        String offsets=receivable ? "customer_open_item_offsets" : "supplier_open_item_offsets";
        String reason=receivable ? "batch.reason" : "allocation.reason";
        String reverseReason=receivable ? "batch.reverse_reason" : "allocation.reverse_reason";
        String sourceExclusion=receivable ? "1=1"
                : "(ledger.source_doc_type<>'DIRECT_PAYMENT' OR ledger.legacy_import_run_id IS NOT NULL)";
        return """
                WITH @cashCte@, offset_facts AS (
                    SELECT allocation.*, @reason@ AS event_remark,@reverseReason@ AS reversal_remark
                    FROM @offsets@ allocation @batchJoin@
                    WHERE allocation.@party@=:pid
                ), party_events AS (
                    SELECT CASE WHEN ledger.legacy_import_run_id IS NOT NULL
                                THEN ((ledger.legacy_source_resolution->>'snapshotAsOfUtc')::timestamptz
                                    AT TIME ZONE 'Asia/Shanghai')::date ELSE ledger.bill_date END AS event_date,
                           ledger.bill_no AS ref_no,@openingOriginal@ AS posted_original,
                           ledger.exchange_rate AS posted_rate,@openingLocal@ AS posted_local,
                           0::numeric AS settled_original,NULL::numeric AS settled_rate,0::numeric AS settled_local,
                           CASE WHEN ledger.legacy_import_run_id IS NOT NULL THEN '历史期初' ELSE '立账' END AS event_type,
                           currency.code AS currency_code,ledger.remark,ledger.currency_id,
                           10 AS event_order,ledger.id AS event_id
                    FROM ar_ap_ledger ledger @proofJoin@
                    LEFT JOIN currencies currency ON currency.id=ledger.currency_id
                    WHERE ledger.direction='@direction@' AND ledger.@party@=:pid AND @sourceExclusion@
                      AND ((ledger.status=1 AND NOT COALESCE(ledger.is_deleted,false))
                        OR (ledger.status=-1 AND COALESCE(ledger.is_deleted,false) AND ledger.deleted_at IS NOT NULL))
                    UNION ALL
                    SELECT (ledger.deleted_at AT TIME ZONE 'Asia/Shanghai')::date,ledger.bill_no,
                           -ledger.amount_original,ledger.exchange_rate,-ledger.amount_original_local,
                           0::numeric,NULL::numeric,0::numeric,'立账红冲',currency.code,ledger.remark,ledger.currency_id,
                           20,ledger.id
                    FROM ar_ap_ledger ledger LEFT JOIN currencies currency ON currency.id=ledger.currency_id
                    WHERE ledger.direction='@direction@' AND ledger.@party@=:pid
                      AND ledger.legacy_import_run_id IS NULL AND ledger.status=-1
                      AND COALESCE(ledger.is_deleted,false) AND ledger.deleted_at IS NOT NULL
                    UNION ALL
                    SELECT cash.event_date,cash.bill_no,0::numeric,NULL::numeric,0::numeric,
                           cash.book_original,cash.book_rate,cash.book_local,cash.event_type,currency.code,
                           cash.remark,cash.currency_id,cash.event_order,cash.id
                    FROM cash_events cash LEFT JOIN currencies currency ON currency.id=cash.currency_id
                    UNION ALL
                    SELECT allocation.effective_date,allocation.offset_batch_id::text,0::numeric,NULL::numeric,0::numeric,
                           allocation.amount_original,allocation.target_rate,allocation.target_amount_local,
                           '@offsetLabel@',currency.code,allocation.event_remark,allocation.currency_id,50,allocation.id
                    FROM offset_facts allocation LEFT JOIN currencies currency ON currency.id=allocation.currency_id
                    UNION ALL
                    SELECT allocation.effective_date,allocation.offset_batch_id::text,
                           allocation.amount_original,allocation.source_rate,allocation.source_amount_local,
                           0::numeric,NULL::numeric,0::numeric,'@sourceLabel@使用',currency.code,
                           allocation.event_remark,allocation.currency_id,60,allocation.id
                    FROM offset_facts allocation LEFT JOIN currencies currency ON currency.id=allocation.currency_id
                    UNION ALL
                    SELECT (allocation.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,allocation.offset_batch_id::text,
                           0::numeric,NULL::numeric,0::numeric,-allocation.amount_original,allocation.target_rate,
                           -allocation.target_amount_local,'抵销反转',currency.code,
                           allocation.reversal_remark,allocation.currency_id,70,allocation.id
                    FROM offset_facts allocation LEFT JOIN currencies currency ON currency.id=allocation.currency_id
                    WHERE allocation.status='REVERSED' AND allocation.reversed_at IS NOT NULL
                    UNION ALL
                    SELECT (allocation.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,allocation.offset_batch_id::text,
                           -allocation.amount_original,allocation.source_rate,-allocation.source_amount_local,
                           0::numeric,NULL::numeric,0::numeric,'@sourceLabel@恢复',currency.code,
                           allocation.reversal_remark,allocation.currency_id,80,allocation.id
                    FROM offset_facts allocation LEFT JOIN currencies currency ON currency.id=allocation.currency_id
                    WHERE allocation.status='REVERSED' AND allocation.reversed_at IS NOT NULL
                )
                """.replace("@cashCte@",FinanceCashEventSql.ctes(receivable,"t."+party+"=:pid AND "+documentScope))
                .replace("@party@",party)
                .replace("@offsets@",offsets).replace("@reason@",reason).replace("@reverseReason@",reverseReason)
                .replace("@batchJoin@",receivable ? "JOIN customer_open_item_offset_batches batch ON batch.id=allocation.offset_batch_id" : "")
                .replace("@openingOriginal@",LegacyOpeningBalanceSql.originalAmount("ledger.amount_original"))
                .replace("@openingLocal@",LegacyOpeningBalanceSql.localAmount("ledger.amount_original_local"))
                .replace("@proofJoin@",LegacyOpeningBalanceSql.PROOF_JOIN).replace("@sourceExclusion@",sourceExclusion)
                .replace("@direction@",receivable ? "AR" : "AP").replace("@cashLabel@",receivable ? "冲减应收" : "付款")
                .replace("@offsetLabel@",receivable ? "预收转销" : "应付抵销").replace("@sourceLabel@",receivable ? "预收" : "贷项")
                .replace("@scope@",documentScope);
    }

    static String running(String events) {
        return events + """
                , windowed AS (
                    SELECT event.*,
                           CASE WHEN COUNT(*) FILTER(WHERE posted_original IS NULL OR settled_original IS NULL
                                      OR currency_id IS NULL) OVER currency_history>0 THEN NULL
                                ELSE SUM(posted_original-settled_original) OVER currency_history END AS running_original,
                           SUM(posted_local-settled_local) OVER all_history AS running_local
                    FROM party_events event
                    WHERE CAST(:to AS date) IS NULL OR event_date<=:to
                    WINDOW currency_history AS (PARTITION BY currency_id ORDER BY event_date,event_order,ref_no,event_id ROWS UNBOUNDED PRECEDING),
                           all_history AS (ORDER BY event_date,event_order,ref_no,event_id ROWS UNBOUNDED PRECEDING)
                )
                SELECT event_date AS "billDate",ref_no AS "refNo",currency_code AS "currencyCode",
                       posted_original AS "salesOriginal",posted_rate AS "salesRate",posted_local AS "salesLocal",
                       settled_original AS "receiptOriginal",settled_rate AS "receiptRate",settled_local AS "receiptLocal",
                       running_original AS "balanceOriginal",posted_rate AS "balanceRate",running_local AS "balanceLocal",
                       event_type AS "type",remark AS "remark",event_order AS "eventOrder",event_id AS "eventId",
                       CASE WHEN running_original IS NULL THEN '待核验' ELSE '已核验' END AS "originalStatus"
                FROM windowed WHERE CAST(:from AS date) IS NULL OR event_date>=:from
                """;
    }

    static String annual(String events) {
        return events + """
                , monthly AS (
                    SELECT month AS ms,to_char(month,'YYYY-MM') AS ym,
                           COALESCE(SUM(event.posted_local),0) AS posted,
                           COALESCE(SUM(event.settled_local),0) AS settled
                    FROM generate_series(CAST(:ys AS date),CAST(:ye AS date),INTERVAL '1 month') month
                    LEFT JOIN party_events event ON event.event_date>=month
                        AND event.event_date<month+INTERVAL '1 month'
                    WHERE EXISTS(SELECT 1 FROM party_events known WHERE known.event_date<=:ye)
                    GROUP BY month
                )
                SELECT month.ym,
                       COALESCE((SELECT SUM(prior.posted_local-prior.settled_local)
                           FROM party_events prior WHERE prior.event_date<month.ms),0),
                       month.posted,month.settled,0,
                       COALESCE((SELECT SUM(closing.posted_local-closing.settled_local)
                           FROM party_events closing WHERE closing.event_date<month.ms+INTERVAL '1 month'),0)
                FROM monthly month ORDER BY month.ym
                """;
    }
}
