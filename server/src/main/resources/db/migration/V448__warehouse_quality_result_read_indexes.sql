-- V448: read-path indexes for the merged warehouse quality-result center
-- (/warehouse/quality-results, replacing the IQC stock-in + IQC return lists).
--
-- The facts stay in their existing append-only ledgers; this migration only
-- adds covering / partial indexes so the per-receipt aggregation pipeline and
-- the 60-second badge poll remain fast as history grows.  Old rows are fully
-- compatible: pre-V446 PASS events keep requires_warehouse_stock_in = FALSE and
-- simply stay outside the pending-release partial index, and NULL is_deleted
-- receipts keep matching the existing COALESCE predicates (no partial index is
-- used on those columns).  No data is rewritten and no query semantics change.

-- Per-receipt verdict aggregation (list/status-counts/detail): index-only scan
-- over status + passed/failed quantities for every non-reversed inspection row.
CREATE INDEX idx_procurement_inspection_items_quality_verdict
    ON procurement_inspection_items (receipt_type, receipt_id)
    INCLUDE (status, passed_base_qty, failed_base_qty)
    WHERE status <> 'REVERSED';

-- Pending release slices (waiting-stock-in aggregation + detail slice feed):
-- partial covering index over warehouse-confirmable PASS events.
CREATE INDEX idx_procurement_inspection_events_pending_release
    ON procurement_inspection_events (inspection_item_id, id)
    INCLUDE (base_qty)
    WHERE action = 'PASS' AND requires_warehouse_stock_in;

-- event_stocked aggregation (stocked qty per PASS slice) and batch joins.
CREATE INDEX idx_procurement_iqc_stock_in_item_event_qty
    ON procurement_iqc_stock_in_batch_items (pass_event_id)
    INCLUDE (base_qty);

CREATE INDEX idx_procurement_iqc_stock_in_item_batch
    ON procurement_iqc_stock_in_batch_items (batch_id);

-- Pending physical returns (merged-page badge + return section of detail).
CREATE INDEX idx_procurement_iqc_rejection_pending_return
    ON procurement_iqc_rejection_cases (inspection_item_id, id)
    INCLUDE (return_recorded_at)
    WHERE is_deleted = FALSE AND status <> 'REVERSED';

COMMENT ON INDEX idx_procurement_inspection_items_quality_verdict IS
    'Index-only per-receipt IQC verdict aggregation for the merged warehouse quality-result center';
COMMENT ON INDEX idx_procurement_inspection_events_pending_release IS
    'Warehouse-confirmable PASS slices (remaining > stocked) feed for quality-result pending-release counts';
COMMENT ON INDEX idx_procurement_iqc_stock_in_item_event_qty IS
    'Stocked quantity per PASS slice (event_stocked aggregation) for quality-result and IQC stock-in reads';
COMMENT ON INDEX idx_procurement_iqc_stock_in_item_batch IS
    'Batch-item join for IQC stock-in history reads keyed by batch';
COMMENT ON INDEX idx_procurement_iqc_rejection_pending_return IS
    'Pending physical-return cases joined through inspection items for the merged quality-result center';
