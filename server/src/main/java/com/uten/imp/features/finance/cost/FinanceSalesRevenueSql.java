package com.uten.imp.features.finance.cost;

/** Frozen sales AR amounts and their actual dated reversals, shared by the report and its rate validation. */
final class FinanceSalesRevenueSql {
    private FinanceSalesRevenueSql() { }

    /** The caller binds :from and :to once. No current balance, updated_at or current price substitutes for an event. */
    static String ctes() {
        return """
                sales_revenue_bounds AS (
                    SELECT CAST(:from AS date) AS date_from,CAST(:to AS date) AS date_to
                ), sales_revenue_sources AS NOT MATERIALIZED (
                    SELECT ledger.*,
                           (ledger.status=-1 AND (NOT ledger.is_deleted OR ledger.deleted_at IS NULL
                               OR ledger.legacy_import_run_id IS NOT NULL OR ledger.legacy_id IS NOT NULL
                               OR NULLIF(btrim(ledger.legacy_source),'') IS NOT NULL)) AS unknown_reversal
                    FROM ar_ap_ledger ledger
                    WHERE ledger.direction='AR' AND ledger.source_doc_type IN('SALES_SHIPMENT','SALES_RETURN')
                      AND ((ledger.status=1 AND NOT ledger.is_deleted) OR ledger.status=-1)
                ), sales_revenue_events AS (
                    SELECT source.client_id,source.bill_date AS business_date,
                           source.amount_original_local AS amount_local,source.currency_id,source.exchange_rate,
                           source.amount_original_local IS NULL AS pending
                    FROM sales_revenue_sources source CROSS JOIN sales_revenue_bounds bounds
                    WHERE NOT source.unknown_reversal AND source.bill_date BETWEEN bounds.date_from AND bounds.date_to
                    UNION ALL
                    SELECT source.client_id,(source.deleted_at AT TIME ZONE 'Asia/Shanghai')::date,
                           -source.amount_original_local,source.currency_id,source.exchange_rate,
                           source.amount_original_local IS NULL
                    FROM sales_revenue_sources source CROSS JOIN sales_revenue_bounds bounds
                    WHERE source.status=-1 AND NOT source.unknown_reversal
                      AND (source.deleted_at AT TIME ZONE 'Asia/Shanghai')::date BETWEEN bounds.date_from AND bounds.date_to
                    UNION ALL
                    SELECT source.client_id,bounds.date_from,NULL::numeric,source.currency_id,source.exchange_rate,true
                    FROM sales_revenue_sources source CROSS JOIN sales_revenue_bounds bounds
                    WHERE source.unknown_reversal OR source.bill_date IS NULL
                )
                """;
    }
}
