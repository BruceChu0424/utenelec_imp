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
                : "NOT "+com.uten.imp.features.finance.SupplierAdvanceReplaySql.cashRepresentedLedger("ledger");
        return """
                WITH @cashCte@, offset_facts AS NOT MATERIALIZED (
                    SELECT allocation.*, @reason@ AS event_remark,@reverseReason@ AS reversal_remark
                    FROM @offsets@ allocation @batchJoin@
                    WHERE allocation.@party@=:pid
                ), party_events AS NOT MATERIALIZED (
                    @postingEvents@
                    UNION ALL
                    SELECT (ledger.deleted_at AT TIME ZONE 'Asia/Shanghai')::date,ledger.bill_no,
                           -ledger.amount_original,ledger.exchange_rate,-ledger.amount_original_local,
                           0::numeric,NULL::numeric,0::numeric,'立账红冲',currency.code,ledger.remark,ledger.currency_id,
                           20,ledger.id
                    FROM ar_ap_ledger ledger LEFT JOIN currencies currency ON currency.id=ledger.currency_id
                    WHERE ledger.direction='@direction@' AND ledger.@party@=:pid
                      AND ledger.legacy_import_run_id IS NULL AND ledger.status=-1
                      AND COALESCE(ledger.is_deleted,false) AND ledger.deleted_at IS NOT NULL
                      AND @sourceExclusion@
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
                    @nativeAdvanceEvents@
                )
                """.replace("@cashCte@",FinanceCashEventSql.ctes(receivable,"t."+party+"=:pid AND "+documentScope)
                        .replace("cash_facts AS (","cash_facts AS NOT MATERIALIZED ("))
                .replace("@nativeAdvanceEvents@",receivable?"":nativeAdvanceEvents(documentScope))
                .replace("@postingEvents@",postingEvents(false)+" UNION ALL "+postingEvents(true))
                .replace("@party@",party)
                .replace("@offsets@",offsets).replace("@reason@",reason).replace("@reverseReason@",reverseReason)
                .replace("@batchJoin@",receivable ? "JOIN customer_open_item_offset_batches batch ON batch.id=allocation.offset_batch_id" : "")
                .replace("@openingOriginal@",LegacyOpeningBalanceSql.originalAmount("ledger.amount_original"))
                .replace("@openingLocal@",LegacyOpeningBalanceSql.localAmount("ledger.amount_original_local"))
                .replace("@proofJoin@",LegacyOpeningBalanceSql.PROOF_JOIN).replace("@sourceExclusion@",sourceExclusion)
                .replace("@direction@",receivable ? "AR" : "AP").replace("@cashLabel@",receivable ? "冲减应收" : "付款")
                .replace("@offsetLabel@",receivable ? "预收转销" : "应付抵销").replace("@sourceLabel@",receivable ? "预收" : "贷项")
                .replace("@scope@",documentScope)
                .replace("currency.code", com.uten.imp.common.finance.CurrencyDisplayLabel.sql("currency"));
    }

    private static String nativeAdvanceEvents(String documentScope) {
        return """
                UNION ALL
                SELECT event.event_date,payment.bill_no,0::numeric,NULL::numeric,0::numeric,
                       event.amount_original,target.exchange_rate,
                       event.amount_local,event.event_type,currency.code,event.remark,event.currency_id,event.event_order,event.id
                FROM v_finance_supplier_advance_ap_events event JOIN finance_payments payment ON payment.id=event.payment_id
                JOIN ar_ap_ledger target ON target.id=event.ledger_id
                LEFT JOIN currencies currency ON currency.id=event.currency_id
                WHERE event.supplier_id=:pid AND @scope@
                UNION ALL
                SELECT event.event_date,event.bill_no,0::numeric,NULL::numeric,0::numeric,
                       event.amount_original,payment.exchange_rate,
                       event.amount_local,event.event_type,currency.code,event.remark,event.currency_id,event.event_order,event.id
                FROM v_finance_supplier_advance_asset_events event JOIN finance_payments payment ON payment.id=event.payment_id
                LEFT JOIN currencies currency ON currency.id=event.currency_id
                WHERE event.supplier_id=:pid AND @scope@
                """.replace("@scope@",documentScope);
    }

    /** Separate native dates from imported snapshot dates so range predicates remain indexable. */
    private static String postingEvents(boolean imported) {
        return """
                SELECT %s AS event_date,ledger.bill_no AS ref_no,%s AS posted_original,
                       ledger.exchange_rate AS posted_rate,%s AS posted_local,
                       0::numeric AS settled_original,NULL::numeric AS settled_rate,0::numeric AS settled_local,
                       '%s'::text AS event_type,currency.code AS currency_code,ledger.remark,ledger.currency_id,
                       10 AS event_order,ledger.id AS event_id
                FROM ar_ap_ledger ledger %s
                LEFT JOIN currencies currency ON currency.id=ledger.currency_id
                WHERE ledger.direction='@direction@' AND ledger.@party@=:pid AND @sourceExclusion@
                  AND ledger.legacy_import_run_id IS %sNULL
                  AND ((ledger.status=1 AND NOT COALESCE(ledger.is_deleted,false))
                    OR (ledger.status=-1 AND COALESCE(ledger.is_deleted,false) AND ledger.deleted_at IS NOT NULL))
                """.formatted(imported?"((ledger.legacy_source_resolution->>'snapshotAsOfUtc')::timestamptz AT TIME ZONE 'Asia/Shanghai')::date":"ledger.bill_date",
                        imported?"@openingOriginal@":"ledger.amount_original",
                        imported?"@openingLocal@":"ledger.amount_original_local",
                        imported?"历史期初":"立账",imported?"@proofJoin@":"",imported?"NOT ":"");
    }

    /** One monthly fact contract for persisted rebuilding and same-snapshot fallback. Inputs are application-owned SQL. */
    static String monthlyAggregation(String monthExpression,String sourceClause) {
        return """
                SELECT event.currency_id,%s AS month_start,
                       SUM(event.posted_original-event.settled_original) AS net_original,
                       SUM(event.posted_local) AS posted_local_sum,SUM(event.settled_local) AS settled_local_sum,
                       SUM(event.posted_local-event.settled_local) AS net_local,COUNT(*) AS event_count,
                       COUNT(*) FILTER(WHERE event.posted_original IS NULL OR event.settled_original IS NULL
                                           OR event.currency_id IS NULL) AS null_original_count
                FROM %s GROUP BY event.currency_id,%s
                """.formatted(monthExpression,sourceClause,monthExpression);
    }

    /**
     * Read a monthly projection in the caller's snapshot. A REQUIRES_NEW healer
     * cannot replace versions already visible to an outer repeatable-read export.
     * Dirty months therefore come from that same snapshot's authoritative events;
     * clean months stay on the bounded projection. Missing whole projections and
     * explicit full-rebuild sentinels use an exclusive whole-party replay branch.
     */
    private static String snapshotMonthly(String events,String side) {
        return events+"""
                , party_projection_state AS MATERIALIZED (
                    SELECT EXISTS(SELECT 1 FROM party_monthly_summaries s
                                  WHERE s.side='@side@' AND s.party_id=:pid) AS has_summaries,
                           EXISTS(SELECT 1 FROM party_month_dirty d
                                  WHERE d.side='@side@' AND d.party_id=:pid
                                    AND d.month_start=DATE '1900-01-01') AS full_replay
                ), party_replay_months AS MATERIALIZED (
                    SELECT d.month_start FROM party_month_dirty d CROSS JOIN party_projection_state state
                    WHERE d.side='@side@' AND d.party_id=:pid AND state.has_summaries AND NOT state.full_replay
                      AND d.month_start<>DATE '1900-01-01'
                ), snapshot_monthly AS (
                    SELECT s.currency_id,s.month_start,s.net_original,s.posted_local_sum,s.settled_local_sum,
                           s.net_local,s.event_count,s.null_original_count
                    FROM party_monthly_summaries s CROSS JOIN party_projection_state state
                    WHERE s.side='@side@' AND s.party_id=:pid AND state.has_summaries AND NOT state.full_replay
                      AND NOT EXISTS(SELECT 1 FROM party_replay_months d WHERE d.month_start=s.month_start)
                    UNION ALL
                    SELECT replay.currency_id,d.month_start,replay.net_original,replay.posted_local_sum,
                           replay.settled_local_sum,replay.net_local,replay.event_count,replay.null_original_count
                    FROM party_replay_months d CROSS JOIN LATERAL (
                        @dirtyAggregate@
                    ) replay
                    UNION ALL
                    @fullAggregate@
                )
                """.replace("@side@",side)
                .replace("@dirtyAggregate@",monthlyAggregation("d.month_start","party_events event "
                        +"WHERE event.event_date>=d.month_start AND event.event_date<d.month_start+INTERVAL '1 month'"))
                .replace("@fullAggregate@",monthlyAggregation("date_trunc('month',event.event_date)::date",
                        "party_projection_state state CROSS JOIN party_events event WHERE state.full_replay OR NOT state.has_summaries"));
    }

    /**
     * 滚动余额对账单（B2 三段式期初）：旧实现把全部历史事件装进
     * UNBOUNDED PRECEDING 窗口现场重放；现改为
     * 「已关月汇总（party_monthly_summaries）+ 当月尾段事件 + 展示窗前缀」，
     * 与 V408 账户流水三段式同构。语义逐点保持：
     * <ul>
     *   <li>排序键仍是 (event_date,event_order,ref_no,event_id)，日期先于一切，
     *       因此 {event_date &lt; :from} 恰为展示行前缀之外的全部前史；</li>
     *   <li>net_* 逐行 (posted-settled) 求和、NULL 行整行跳过，与原窗口 SUM 一致；</li>
     *   <li>原币「待核验」= 前史或前缀中存在 posted/settled/currency 为 NULL 的事件，
     *       由 base_nulls（汇总列 null_original_count）+ 前缀 FILTER 计数共同判定；</li>
     *   <li>:from 为空（全历史展开）时基数为 0，与旧行为等价。</li>
     * </ul>
     * 读前自愈用于预热；同快照脏月回放独立保证正确性，不依赖另一个事务的新投影可见。
     */
    static String running(String events, String side) {
        return snapshotMonthly(events,side) + """
                , summary_opening AS (
                    SELECT summary.currency_id,
                           SUM(summary.net_original) AS base_original,
                           SUM(summary.null_original_count) AS base_nulls,
                           SUM(summary.net_local) AS base_local
                    FROM snapshot_monthly summary
                    WHERE CAST(:fromMonth AS date) IS NOT NULL
                      AND summary.month_start<:fromMonth
                    GROUP BY summary.currency_id
                ), month_tail AS (
                    SELECT event.currency_id,
                           SUM(event.posted_original-event.settled_original) AS tail_original,
                           COUNT(*) FILTER(WHERE event.posted_original IS NULL
                               OR event.settled_original IS NULL OR event.currency_id IS NULL) AS tail_nulls,
                           SUM(event.posted_local-event.settled_local) AS tail_local
                    FROM party_events event
                    WHERE CAST(:fromMonth AS date) IS NOT NULL
                      AND event.event_date>=:fromMonth
                      AND event.event_date<:from
                    GROUP BY event.currency_id
                ), opening AS (
                    -- PostgreSQL 的 FULL JOIN 只支持可哈希/可归并的等值条件，
                    -- 不能用 IS NOT DISTINCT FROM；改用并集聚合，语义逐点等价
                    --（NULL 币种在 GROUP BY 下归为一组，与 NOT DISTINCT 相同）。
                    SELECT bases.currency_id,
                           SUM(bases.base_original) AS base_original,
                           SUM(bases.base_nulls) AS base_nulls,
                           SUM(bases.base_local) AS base_local
                    FROM (
                        SELECT currency_id,base_original,base_nulls,base_local FROM summary_opening
                        UNION ALL
                        SELECT currency_id,tail_original AS base_original,
                               tail_nulls AS base_nulls,tail_local AS base_local FROM month_tail
                    ) bases
                    GROUP BY bases.currency_id
                ), global_opening AS (
                    -- running_local 是跨币种滚动余额：本币基数取全局合计而非按币基数。
                    SELECT SUM(bases.base_local) AS global_base_local
                    FROM (
                        SELECT base_local FROM summary_opening
                        UNION ALL
                        SELECT tail_local AS base_local FROM month_tail
                    ) bases
                ), windowed AS (
                    SELECT event.*,
                           CASE WHEN COALESCE(opening.base_nulls,0)
                                     +COUNT(*) FILTER(WHERE event.posted_original IS NULL
                                          OR event.settled_original IS NULL
                                          OR event.currency_id IS NULL) OVER currency_history>0
                                THEN NULL
                                ELSE COALESCE(opening.base_original,0)
                                     +SUM(event.posted_original-event.settled_original)
                                      OVER currency_history END AS running_original,
                           COALESCE(global_opening.global_base_local,0)
                                +SUM(event.posted_local-event.settled_local)
                                 OVER all_history AS running_local
                    FROM party_events event
                    LEFT JOIN opening
                      ON opening.currency_id IS NOT DISTINCT FROM event.currency_id
                    CROSS JOIN global_opening
                    WHERE (CAST(:from AS date) IS NULL OR event.event_date>=:from)
                      AND (CAST(:to AS date) IS NULL OR event.event_date<=:to)
                    WINDOW currency_history AS (PARTITION BY event.currency_id
                            ORDER BY event.event_date,event.event_order,event.ref_no,event.event_id
                            ROWS UNBOUNDED PRECEDING),
                           all_history AS (ORDER BY event.event_date,event.event_order,
                            event.ref_no,event.event_id ROWS UNBOUNDED PRECEDING)
                )
                SELECT event.event_date AS "billDate",event.ref_no AS "refNo",event.currency_code AS "currencyCode",
                       posted_original AS "salesOriginal",posted_rate AS "salesRate",posted_local AS "salesLocal",
                       settled_original AS "receiptOriginal",settled_rate AS "receiptRate",settled_local AS "receiptLocal",
                       running_original AS "balanceOriginal",posted_rate AS "balanceRate",running_local AS "balanceLocal",
                       event.event_type AS "type",event.remark AS "remark",event.event_order AS "eventOrder",event.event_id AS "eventId",
                       CASE WHEN running_original IS NULL THEN '待核验' ELSE '已核验' END AS "originalStatus",
                       event.currency_id AS "__currencyId" @nativeMetadata@
                FROM windowed event @nativeCashJoin@
                WHERE CAST(:from AS date) IS NULL OR event.event_date>=:from
                """.replace("@side@", side)
                .replace("@nativeMetadata@","AP".equals(side)?"""
                        ,event.event_type AS "__eventType",
                        CASE WHEN actual_cash.id IS NULL THEN 0::numeric ELSE actual_cash.actual_bank_cash_local END AS "actualCashLocal",
                        CASE WHEN actual_cash.id IS NULL THEN 0::numeric ELSE actual_cash.actual_bank_cash_local END AS "__actualCashLocal",
                        CASE WHEN event.event_type LIKE '预付资产%' THEN event.settled_local ELSE 0 END AS "__advanceAssetDeltaLocal",
                        CASE WHEN event.event_type LIKE '预付资产%' THEN 0 ELSE event.posted_local-event.settled_local END AS "__formalApDeltaLocal",
                        event.posted_local-event.settled_local AS "__netDeltaLocal",'BOOK_NET_MOVEMENT'::text AS "__settledMeaning"
                        """:"")
                .replace("@nativeCashJoin@","AP".equals(side)?"LEFT JOIN cash_events actual_cash ON actual_cash.id=event.event_id "
                        +"AND actual_cash.event_order=event.event_order AND actual_cash.event_date=event.event_date":"");
    }

    /**
     * 年度对账单（B2 汇总化）：期初/期末与月发生额全部来自
     * party_monthly_summaries（读前自愈保证新鲜），不再对 party_events 做
     * 逐月相关子查询全量重扫。:ys/:ye 恒为整年（1/1～12/31，均为月界），
     * 「有已知事件才出行」的门槛因此可按汇总月精确表达。
     */
    static String annual(String side) {
        return snapshotMonthly(events("AR".equals(side),"1=1"),side)+"""
                @nativeMonthlyMetadata@
                , summary_cells AS (
                    SELECT month_start,SUM(posted_local_sum) AS posted_local_sum,
                           SUM(settled_local_sum) AS settled_local_sum,SUM(net_local) AS net_local
                    FROM snapshot_monthly
                    GROUP BY month_start
                ), monthly AS (
                    SELECT month.ms,to_char(month.ms,'YYYY-MM') AS ym,
                           COALESCE(cell.posted_local_sum,0) AS posted,
                           COALESCE(cell.settled_local_sum,0) AS settled
                    FROM generate_series(CAST(:ys AS date),CAST(:ye AS date),INTERVAL '1 month') AS month(ms)
                    LEFT JOIN summary_cells cell ON cell.month_start=month.ms::date
                    WHERE EXISTS(SELECT 1 FROM summary_cells known
                                 WHERE known.month_start<=date_trunc('month',CAST(:ye AS date)))
                )
                SELECT month.ym AS "ym",
                       COALESCE((SELECT SUM(prior.net_local)
                           FROM summary_cells prior WHERE prior.month_start<month.ms),0) AS "prevBalance",
                       month.posted AS "posted",month.settled AS "settled" @nativeCashColumn@,NULL::numeric AS "returned",
                       COALESCE((SELECT SUM(closing.net_local)
                           FROM summary_cells closing
                           WHERE closing.month_start<month.ms+INTERVAL '1 month'),0) AS "balance" @nativeMetadata@
                FROM monthly month ORDER BY month.ym
                """.replace("@side@", side)
                .replace("@nativeCashColumn@","AP".equals(side)?",CASE WHEN EXISTS(SELECT 1 FROM actual_cash_months WHERE month_start=month.ms) THEN (SELECT amount_local FROM actual_cash_months WHERE month_start=month.ms) ELSE 0::numeric END AS \"actualCashLocal\"":"")
                .replace("@nativeMonthlyMetadata@","AP".equals(side)?"""
                        , advance_asset_months AS (
                            SELECT date_trunc('month',event_date)::date AS month_start,SUM(amount_local) AS amount_local
                            FROM v_finance_supplier_advance_asset_events WHERE supplier_id=:pid AND event_date<=:ye
                            GROUP BY date_trunc('month',event_date)::date
                        ), actual_cash_months AS (
                            SELECT date_trunc('month',event_date)::date AS month_start,
                                   CASE WHEN COUNT(*)=COUNT(actual_bank_cash_local) THEN SUM(actual_bank_cash_local) END AS amount_local
                            FROM cash_events WHERE event_date BETWEEN :ys AND :ye GROUP BY date_trunc('month',event_date)::date
                        )
                        """:"")
                .replace("@nativeMetadata@","AP".equals(side)?"""
                        ,CASE WHEN EXISTS(SELECT 1 FROM actual_cash_months WHERE month_start=month.ms) THEN (SELECT amount_local FROM actual_cash_months WHERE month_start=month.ms) ELSE 0::numeric END AS "__actualCashLocal",
                        COALESCE((SELECT amount_local FROM advance_asset_months WHERE month_start=month.ms),0) AS "__advanceAssetDeltaLocal",
                        month.posted-month.settled+COALESCE((SELECT amount_local FROM advance_asset_months WHERE month_start=month.ms),0) AS "__formalApDeltaLocal",
                        month.posted-month.settled AS "__netDeltaLocal",'BOOK_NET_MOVEMENT'::text AS "__settledMeaning",
                        COALESCE((SELECT SUM(prior.net_local) FROM summary_cells prior WHERE prior.month_start<month.ms),0)
                            +COALESCE((SELECT SUM(amount_local) FROM advance_asset_months WHERE month_start<month.ms),0) AS "__formalApOpeningLocal",
                        COALESCE((SELECT SUM(closing.net_local) FROM summary_cells closing WHERE closing.month_start<month.ms+INTERVAL '1 month'),0)
                            +COALESCE((SELECT SUM(amount_local) FROM advance_asset_months WHERE month_start<month.ms+INTERVAL '1 month'),0) AS "__formalApClosingLocal",
                        COALESCE((SELECT SUM(amount_local) FROM advance_asset_months WHERE month_start<month.ms),0) AS "__advanceAssetOpeningLocal",
                        COALESCE((SELECT SUM(amount_local) FROM advance_asset_months WHERE month_start<month.ms+INTERVAL '1 month'),0) AS "__advanceAssetClosingLocal"
                        """:"");
    }
}
