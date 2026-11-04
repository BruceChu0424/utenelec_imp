package com.uten.imp.features.finance.report;

import com.uten.imp.features.finance.LegacyOpeningBalanceSql;

/** Dated native cash and reversal facts shared by summaries and party statements. */
final class FinanceCashEventSql {
    private FinanceCashEventSql() { }

    static String ctes(boolean receivable,String predicate) {
        String party=receivable?"client_id":"supplier_id";
        String header=receivable?"finance_receipts":"finance_payments";
        String lines=receivable?"finance_receipt_lines":"finance_payment_lines";
        String parent=receivable?"receipt_id":"payment_id";
        String original=receivable?"line.amount_original+line.write_off_amount":"line.amount_original";
        String book=receivable?"line.applied_amount_local":LegacyOpeningBalanceSql.paymentBookLocal("line");
        return """
                cash_facts AS (
                    SELECT t.id,t.@party@ AS party_id,t.currency_id,t.bill_no,t.bill_date,
                           (COALESCE(t.reversed_at,t.updated_at) AT TIME ZONE 'Asia/Shanghai')::date AS reverse_date,
                           t.exchange_rate,t.status,t.remark,
                           CASE WHEN COALESCE(lines.line_count,0)>0 THEN lines.applied_original ELSE t.amount_original END AS book_original,
                           CASE WHEN COALESCE(lines.line_count,0)>0 THEN lines.applied_local ELSE t.amount_local END AS book_local,
                           CASE WHEN COALESCE(lines.line_count,0)>0 THEN fn_business_exact_divide(lines.applied_local,lines.applied_original,'finance.cash.book-rate','本次收付款账面汇率',30)
                                ELSE t.exchange_rate END AS book_rate,
                           CASE WHEN COALESCE(lines.line_count,0)>0 THEN lines.cash_local ELSE t.amount_local END AS cash_local,
                           CASE WHEN COALESCE(lines.line_count,0)>0 THEN lines.write_off_local ELSE 0 END AS write_off_local,
                           CASE WHEN COALESCE(lines.line_count,0)>0 THEN lines.exchange_diff ELSE 0 END AS exchange_diff
                    FROM @header@ t LEFT JOIN LATERAL (
                        SELECT COUNT(*) AS line_count,
                               CASE WHEN COUNT(*)=COUNT(@original@) THEN SUM(@original@) END AS applied_original,
                               CASE WHEN COUNT(*)=COUNT(@book@) THEN SUM(@book@) END AS applied_local,
                               CASE WHEN COUNT(*)=COUNT(line.amount_local) THEN SUM(line.amount_local) END AS cash_local,
                               CASE WHEN COUNT(*)=COUNT(@writeOff@) THEN SUM(@writeOff@) END AS write_off_local,
                               CASE WHEN COUNT(*)=COUNT(line.exchange_diff) THEN SUM(line.exchange_diff) END AS exchange_diff
                        FROM @lines@ line WHERE line.@parent@=t.id AND NOT COALESCE(line.is_deleted,false)
                    ) lines ON TRUE
                    WHERE t.status IN(1,-1) AND NOT COALESCE(t.is_deleted,false)
                      AND t.legacy_id IS NULL AND t.legacy_import_run_id IS NULL AND @predicate@
                ), cash_events AS (
                    SELECT id,party_id,currency_id,bill_no,bill_date AS event_date,remark,book_original,book_local,
                           book_rate,cash_local,write_off_local,exchange_diff,30 AS event_order,'@label@'::text AS event_type
                    FROM cash_facts
                    UNION ALL
                    SELECT id,party_id,currency_id,bill_no,reverse_date,remark,-book_original,-book_local,
                           book_rate,-cash_local,-write_off_local,-exchange_diff,40,'@label@反审'
                    FROM cash_facts WHERE status=-1 AND reverse_date IS NOT NULL
                )
                """.replace("@party@",party).replace("@header@",header).replace("@lines@",lines)
                .replace("@parent@",parent).replace("@original@",original).replace("@book@",book)
                .replace("@writeOff@",receivable?"line.write_off_local":"0::numeric")
                .replace("@predicate@",predicate).replace("@label@",receivable?"冲减应收":"付款");
    }
}
