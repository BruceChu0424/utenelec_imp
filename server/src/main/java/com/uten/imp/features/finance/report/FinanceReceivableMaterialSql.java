package com.uten.imp.features.finance.report;

/** The original summary's last column is the remaining book debt for MATERIAL.
 * A whole, single-category source needs no invented allocation. Mixed sources
 * need the actual receipt/offset assignment; incomplete evidence stays unknown.
 * Requires the same ledger_origin/posting_events CTEs as the full AR balance. */
final class FinanceReceivableMaterialSql {
    private FinanceReceivableMaterialSql() { }

    static final String CTES = """
        , material_source_basis AS (
          SELECT ledger.id AS ledger_id,ledger.client_id,classified.id AS classification_id,
            classified.id IS NOT NULL AND classified.direction='AR'
              AND classified.party_id=ledger.client_id AND classified.currency_id=ledger.currency_id
              AND classified.amount_local=ledger.reporting_amount_local AS known,
            parts.material_local,parts.category_count,parts.single_category
          FROM ledger_origin ledger
          LEFT JOIN v_finance_open_item_classification_current classified ON classified.ledger_id=ledger.id
          LEFT JOIN LATERAL (
            SELECT COALESCE(sum(part.amount_local) FILTER(WHERE part.category='MATERIAL'),0) AS material_local,
              count(*) AS category_count,min(part.category) AS single_category
            FROM finance_open_item_classification_parts part WHERE part.batch_id=classified.id
          ) parts ON TRUE
          WHERE ledger.direction='AR' AND ledger.client_id IS NOT NULL
            AND (ledger.open_item_kind<>'CUSTOMER_PREPAYMENT' OR ledger.legacy_import_run_id IS NOT NULL)
        ), material_receipt_facts AS (
          SELECT receipt.client_id,receipt.bill_date,
            (COALESCE(receipt.reversed_at,receipt.updated_at) AT TIME ZONE 'Asia/Shanghai')::date AS reversed_date,
            receipt.status=-1 AS reversed,
            COALESCE(source.known,false) AND line.applied_amount_local IS NOT NULL
              AND receipt.currency_id=ledger.currency_id AND receipt.client_id=ledger.client_id
              AND (classified.id IS NOT NULL OR source.category_count=1) AS known,
            CASE WHEN classified.id IS NOT NULL THEN assigned.material_local
              WHEN source.category_count=1 THEN CASE WHEN source.single_category='MATERIAL' THEN line.applied_amount_local ELSE 0 END
              END AS material_local
          FROM finance_receipts receipt
          LEFT JOIN finance_receipt_lines line ON line.receipt_id=receipt.id AND NOT line.is_deleted
          LEFT JOIN ledger_origin ledger ON ledger.id=line.applied_ledger_id
          LEFT JOIN material_source_basis source ON source.ledger_id=ledger.id
          LEFT JOIN v_finance_receipt_classification_current classified
            ON classified.receipt_line_id=line.id AND classified.source_classification_id=source.classification_id
          LEFT JOIN LATERAL (
            SELECT COALESCE(sum(part.book_local) FILTER(WHERE part.category='MATERIAL'),0) AS material_local
            FROM finance_receipt_classification_parts part WHERE part.batch_id=classified.id
          ) assigned ON TRUE
          WHERE receipt.status IN(1,-1) AND NOT receipt.is_deleted AND receipt.receipt_kind='AR_SETTLEMENT'
            AND receipt.legacy_id IS NULL AND receipt.legacy_import_run_id IS NULL AND receipt.client_id IS NOT NULL
        ), material_offset_ends AS (
          SELECT actual.id,actual.effective_date,actual.reversed_at,actual.status,batch.client_id,
            actual.target_ledger_id AS ledger_id,actual.target_amount_local AS book_local,-1 AS sign,'TARGET' AS side
          FROM customer_open_item_offsets actual JOIN customer_open_item_offset_batches batch ON batch.id=actual.offset_batch_id
          UNION ALL
          SELECT actual.id,actual.effective_date,actual.reversed_at,actual.status,batch.client_id,
            actual.source_ledger_id,actual.source_amount_local,1,'SOURCE'
          FROM customer_open_item_offsets actual JOIN customer_open_item_offset_batches batch ON batch.id=actual.offset_batch_id
          JOIN ledger_origin source ON source.id=actual.source_ledger_id
          WHERE source.open_item_kind<>'CUSTOMER_PREPAYMENT' OR source.legacy_import_run_id IS NOT NULL
        ), material_offset_facts AS (
          SELECT actual.client_id,actual.effective_date,
            (actual.reversed_at AT TIME ZONE 'Asia/Shanghai')::date AS reversed_date,actual.status='REVERSED' AS reversed,
            COALESCE(source.known,false) AND actual.book_local IS NOT NULL
              AND (classified.id IS NOT NULL OR source.category_count=1) AS known,
            actual.sign * CASE WHEN classified.id IS NOT NULL THEN assigned.material_local
              WHEN source.category_count=1 THEN CASE WHEN source.single_category='MATERIAL' THEN actual.book_local ELSE 0 END END AS material_local
          FROM material_offset_ends actual
          LEFT JOIN material_source_basis source ON source.ledger_id=actual.ledger_id AND source.client_id=actual.client_id
          LEFT JOIN v_finance_customer_offset_classification_current classified ON classified.offset_id=actual.id
            AND CASE WHEN actual.side='TARGET' THEN classified.target_classification_id ELSE classified.source_classification_id END=source.classification_id
          LEFT JOIN LATERAL (
            SELECT COALESCE(sum(CASE WHEN actual.side='TARGET' THEN part.target_local ELSE part.source_local END)
              FILTER(WHERE CASE WHEN actual.side='TARGET' THEN part.target_category ELSE part.source_category END='MATERIAL'),0) AS material_local
            FROM finance_customer_offset_classification_parts part WHERE part.batch_id=classified.id
          ) assigned ON TRUE
          WHERE actual.status IN('APPLIED','REVERSED')
        ), material_events AS (
          SELECT event.client_id,event.bill_date AS event_date,COALESCE(source.known,false) AS known,
            event.event_sign*source.material_local AS amount
          FROM posting_events event LEFT JOIN material_source_basis source ON source.ledger_id=event.ledger_id
          UNION ALL SELECT client_id,bill_date,known,-material_local FROM material_receipt_facts
          UNION ALL SELECT client_id,reversed_date,known,material_local FROM material_receipt_facts WHERE reversed AND reversed_date IS NOT NULL
          UNION ALL SELECT client_id,effective_date,known,material_local FROM material_offset_facts
          UNION ALL SELECT client_id,reversed_date,known,-material_local FROM material_offset_facts WHERE reversed AND reversed_date IS NOT NULL
        ), material_balance AS (
          SELECT client_id,CASE WHEN bool_and(known) THEN sum(amount) END AS material_local
          FROM material_events WHERE event_date<=:to GROUP BY client_id
        )
        """;
}
