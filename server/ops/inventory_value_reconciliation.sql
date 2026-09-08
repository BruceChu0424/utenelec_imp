-- Read-only evidence for an explicitly selected goods cohort, PostgreSQL 16+.
-- Example (isolated acceptance database; choose its existing connection safely):
-- psql -X "$TEST_DATABASE_URL" -v goods_ids='{UUID_A,UUID_B,UUID_E}' \
--   -v warehouse_id='' -v limit_rows=200 -f ops/inventory_value_reconciliation.sql
-- No date cutoff is applied to the movement aggregate: a current balance must
-- be compared with all retained movements for the SAME warehouse/goods/color.
-- Missing imported/opening history means UNPROVEN, not permission to fix data.
-- All money comparisons use recorded amount_local only. Commercial original
-- currencies are never summed. A recorded zero amount is NOT an error test.
-- Stock movement qty is already in the basic unit; DO NOT multiply unit_rate.
\set ON_ERROR_STOP on
\if :{?goods_ids}
\else
  \set goods_ids '{}'
\endif
\if :{?warehouse_id}
\else
  \set warehouse_id ''
\endif
\if :{?limit_rows}
\else
  \set limit_rows 200
\endif

SELECT cardinality(:'goods_ids'::uuid[]) BETWEEN 1 AND 500
       AND array_position(:'goods_ids'::uuid[], NULL::uuid) IS NULL AS valid_scope
\gset
\if :valid_scope
\else
  \echo 'ERROR: supply 1..500 explicit goods UUIDs in goods_ids; no unscoped history scan is allowed.'
  SELECT 1 / 0 AS invalid_audit_scope;
\endif

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '30s';
SET LOCAL lock_timeout = '5s';

SELECT 'READ_ONLY_SNAPSHOT' AS report_section, current_database() AS database_name,
       transaction_timestamp() AS snapshot_at,
       current_setting('transaction_read_only') AS transaction_read_only,
       cardinality(:'goods_ids'::uuid[]) AS requested_goods_count,
       NULLIF(:'warehouse_id', '')::uuid AS selected_warehouse_id,
       greatest(1, least(1000, :'limit_rows'::integer)) AS maximum_rows_per_section;

-- 1. Numeric projection differences. Summing known amounts mirrors the current
-- balance projection only; it does not turn a missing amount into a proven cost.
-- A zero difference proves neither historical completeness nor correct costing.
WITH settings AS (
    SELECT :'goods_ids'::uuid[] AS goods_ids,
           NULLIF(:'warehouse_id', '')::uuid AS warehouse_id
), movement AS (
    SELECT m.warehouse_id, m.goods_id, m.color_id,
           count(*) AS movement_count,
           sum(m.qty * m.direction) AS movement_qty,
           sum(m.amount_local * m.direction) AS recorded_movement_amount,
           count(*) FILTER (WHERE m.amount_local IS NULL) AS unknown_amount_movements,
           count(*) FILTER (WHERE m.source_doc_id IS NULL OR m.source_item_id IS NULL
                           OR nullif(btrim(m.source_doc_type), '') IS NULL) AS missing_source_uuid_movements,
           count(*) FILTER (WHERE m.qty IS NULL OR m.qty <= 0
                           OR m.direction IS NULL OR m.direction NOT IN (-1, 1)) AS malformed_movements
    FROM stock_movements m CROSS JOIN settings p
    WHERE m.goods_id = ANY(p.goods_ids)
      AND (p.warehouse_id IS NULL OR m.warehouse_id = p.warehouse_id)
    GROUP BY m.warehouse_id, m.goods_id, m.color_id
), balance AS (
    SELECT min(b.id::text)::uuid AS representative_balance_id,
           b.warehouse_id, b.goods_id, b.color_id,
           sum(b.qty) AS qty, sum(b.amount_local) AS amount_local,
           count(*) AS balance_row_count,
           count(*) FILTER (WHERE b.amount_local IS NULL) AS unknown_balance_amount_rows
    FROM stock_balances b CROSS JOIN settings p
    WHERE b.goods_id = ANY(p.goods_ids)
      AND (p.warehouse_id IS NULL OR b.warehouse_id = p.warehouse_id)
    GROUP BY b.warehouse_id, b.goods_id, b.color_id
), compared AS (
    SELECT coalesce(b.warehouse_id, m.warehouse_id) AS warehouse_id,
           coalesce(b.goods_id, m.goods_id) AS goods_id,
           coalesce(b.color_id, m.color_id) AS color_id,
           b.representative_balance_id, b.qty AS balance_qty, b.amount_local AS balance_amount_local,
           coalesce(b.balance_row_count, 0) AS balance_row_count,
           coalesce(b.unknown_balance_amount_rows, 0) AS unknown_balance_amount_rows,
           m.movement_qty, m.recorded_movement_amount,
           coalesce(b.qty, 0) - coalesce(m.movement_qty, 0) AS quantity_difference,
           coalesce(b.amount_local, 0) - coalesce(m.recorded_movement_amount, 0) AS recorded_amount_difference,
           coalesce(m.movement_count, 0) AS movement_count,
           coalesce(m.unknown_amount_movements, 0) AS unknown_amount_movements,
           coalesce(m.missing_source_uuid_movements, 0) AS missing_source_uuid_movements,
           coalesce(m.malformed_movements, 0) AS malformed_movements,
           CASE WHEN m.movement_count IS NULL THEN 'NO_RETAINED_MOVEMENTS_OPENING_HISTORY_UNPROVEN'
                WHEN m.malformed_movements > 0 THEN 'MALFORMED_HISTORY_UNPROVEN'
                WHEN m.missing_source_uuid_movements > 0 THEN 'SOURCE_UUIDS_UNPROVEN'
                WHEN m.unknown_amount_movements > 0 OR b.unknown_balance_amount_rows > 0 THEN 'VALUE_NOT_FULLY_RECORDED'
                ELSE 'RECORDED_ROWS_ONLY_NOT_PROOF_OF_COMPLETE_HISTORY_OR_COST' END AS evidence_qualification
    FROM balance b FULL JOIN movement m
      ON m.warehouse_id = b.warehouse_id AND m.goods_id = b.goods_id
     AND m.color_id IS NOT DISTINCT FROM b.color_id
), findings AS (
    SELECT issue.finding_kind, c.*
    FROM compared c CROSS JOIN LATERAL (VALUES
        ('QUANTITY_PROJECTION_MISMATCH', c.quantity_difference <> 0),
        ('RECORDED_AMOUNT_PROJECTION_MISMATCH', c.recorded_amount_difference <> 0),
        ('DUPLICATE_BALANCE_DIMENSION', c.balance_row_count > 1)
    ) issue(finding_kind, present)
    WHERE issue.present
)
SELECT f.*, count(*) OVER() AS total_findings_before_limit
FROM findings f ORDER BY goods_id, warehouse_id, color_id NULLS FIRST, finding_kind
LIMIT greatest(1, least(1000, :'limit_rows'::integer));

-- 2. Recorded-value symptoms. These are review evidence, not an instruction to
-- zero a balance or infer its correct value from current master costs.
WITH balance AS (
    SELECT min(b.id::text)::uuid AS representative_balance_id,
           b.warehouse_id, b.goods_id, b.color_id, sum(b.qty) AS qty,
           sum(b.amount_local) AS amount_local, count(*) AS balance_row_count
    FROM stock_balances b
    WHERE b.goods_id = ANY(:'goods_ids'::uuid[])
      AND (NULLIF(:'warehouse_id', '')::uuid IS NULL
           OR b.warehouse_id = NULLIF(:'warehouse_id', '')::uuid)
    GROUP BY b.warehouse_id, b.goods_id, b.color_id
), findings AS (
    SELECT issue.finding_kind, b.representative_balance_id, b.warehouse_id, b.goods_id,
           b.color_id, b.qty, b.amount_local, b.balance_row_count,
           'REVIEW_REQUIRED_NO_AUTOMATIC_CORRECTION'::text AS evidence_qualification
    FROM balance b CROSS JOIN LATERAL (VALUES
        ('ZERO_QUANTITY_NONZERO_VALUE', b.qty = 0 AND b.amount_local <> 0),
        ('NEGATIVE_RECORDED_INVENTORY_VALUE', b.amount_local < 0)
    ) issue(finding_kind, present)
    WHERE issue.present
)
SELECT f.*, count(*) OVER() AS total_findings_before_limit
FROM findings f ORDER BY goods_id, warehouse_id, color_id NULLS FIRST, finding_kind
LIMIT greatest(1, least(1000, :'limit_rows'::integer));

-- 3. Source evidence for production, sales and unresolved legacy movements.
-- The current schema has quantity/source UUIDs but no unified input-value ->
-- output-cost allocation fact. Therefore *_COST_BASIS_UNPROVEN means just that:
-- amount 0 is not classified as wrong; equality with a commercial amount alone
-- is NOT proof of misuse. Do not infer original COGS from a return credit.
WITH selected AS (
    SELECT m.* FROM stock_movements m
    WHERE m.goods_id = ANY(:'goods_ids'::uuid[])
      AND (NULLIF(:'warehouse_id', '')::uuid IS NULL
           OR m.warehouse_id = NULLIF(:'warehouse_id', '')::uuid)
      AND ((m.source_doc_type = 'STOCK_DOC' AND m.movement_type IN (5, 6, 13, 14))
           OR m.source_doc_type IN ('SALES_SHIPMENT', 'SALES_RETURN')
           OR m.source_doc_id IS NULL OR m.source_item_id IS NULL
           OR nullif(btrim(m.source_doc_type), '') IS NULL)
), resolved AS (
    SELECT m.id AS stock_movement_id, m.transaction_date, m.warehouse_id,
           m.goods_id, m.color_id, m.movement_type, m.direction, m.qty,
           m.amount_local AS recorded_stock_amount_local,
           m.source_doc_type, m.source_doc_id, m.source_item_id,
           coalesce(si.id, shi.id, ri.id) AS resolved_business_item_id,
           si.execution_segment_id, si.source_daily_report_item_id,
           CASE WHEN si.id IS NULL THEN false ELSE EXISTS (
               SELECT 1 FROM production_material_stock_postings posting
               WHERE posting.stock_document_item_id = si.id
           ) END AS has_material_quantity_posting,
           qe.id AS return_quality_event_id,
           ri.out_item_id AS returned_shipment_item_id,
           coalesce(sh.currency_id, ret.currency_id) AS commercial_currency_id,
           CASE WHEN m.source_doc_type = 'SALES_SHIPMENT' THEN shi.amount_local
                WHEN m.source_doc_type = 'SALES_RETURN' THEN ri.amount_local END AS commercial_line_amount_local,
           CASE WHEN m.source_doc_type = 'SALES_SHIPMENT' THEN m.amount_local = shi.amount_local
                WHEN m.source_doc_type = 'SALES_RETURN' THEN m.amount_local = ri.amount_local END AS equals_commercial_amount_only,
           CASE WHEN m.source_doc_id IS NULL OR m.source_item_id IS NULL
                     OR nullif(btrim(m.source_doc_type), '') IS NULL THEN 'LEGACY_SOURCE_UUID_UNPROVEN'
                WHEN coalesce(si.id, shi.id, ri.id) IS NULL THEN 'SOURCE_UUID_UNRESOLVED'
                WHEN m.source_doc_type = 'STOCK_DOC' AND m.amount_local IS NULL THEN 'PRODUCTION_AMOUNT_UNRECORDED'
                WHEN m.source_doc_type = 'STOCK_DOC' THEN 'PRODUCTION_COST_BASIS_UNPROVEN'
                ELSE 'SALES_COST_BASIS_UNPROVEN' END AS finding_kind
    FROM selected m
    LEFT JOIN stock_document_items si
      ON m.source_doc_type = 'STOCK_DOC' AND si.id = m.source_item_id AND si.doc_id = m.source_doc_id
     AND si.goods_id = m.goods_id AND si.color_id IS NOT DISTINCT FROM m.color_id
    LEFT JOIN sales_shipment_items shi
      ON m.source_doc_type = 'SALES_SHIPMENT' AND shi.id = m.source_item_id AND shi.shipment_id = m.source_doc_id
     AND shi.goods_id = m.goods_id AND shi.color_id IS NOT DISTINCT FROM m.color_id
    LEFT JOIN sales_shipments sh ON sh.id = shi.shipment_id
    LEFT JOIN sales_return_quality_events qe
      ON m.source_doc_type = 'SALES_RETURN' AND qe.id = m.source_item_id
    LEFT JOIN sales_return_quality_items qi ON qi.id = qe.quality_item_id AND qi.return_id = m.source_doc_id
    LEFT JOIN sales_return_items ri
      ON m.source_doc_type = 'SALES_RETURN' AND ri.id = coalesce(qi.return_item_id, m.source_item_id)
     AND ri.return_id = m.source_doc_id
     AND ri.goods_id = m.goods_id AND ri.color_id IS NOT DISTINCT FROM m.color_id
    LEFT JOIN sales_returns ret ON ret.id = ri.return_id
)
SELECT r.*, 'UNPROVEN_NOT_A_ZERO_COST_ERROR'::text AS evidence_qualification,
       count(*) OVER() AS total_findings_before_limit
FROM resolved r ORDER BY transaction_date DESC, stock_movement_id
LIMIT greatest(1, least(1000, :'limit_rows'::integer));

SELECT 'READ_ONLY_RECONCILIATION_COMPLETE' AS report_section,
       'No findings is not proof of complete history, correct valuation, or deployment acceptance.' AS interpretation;
COMMIT;
