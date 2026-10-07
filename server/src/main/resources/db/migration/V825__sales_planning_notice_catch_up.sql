-- An initial planning task is identified by the reviewed business revision, never by two clocks.
-- Historical notifications have no provable revision: keep them unchanged, including acknowledgements.
ALTER TABLE notices ADD COLUMN source_revision BIGINT;
ALTER TABLE notices ADD CONSTRAINT notices_source_revision_chk
    CHECK (source_revision IS NULL OR source_revision >= 0);

CREATE UNIQUE INDEX uk_notice_sales_planning_recipient_revision
    ON notices (aggregate_id, audience_user_id, source_revision)
    WHERE source_event = 'SALES_ORDER_APPROVED' AND source_revision IS NOT NULL;

-- Handoff history is authoritative even when the analysis was subsequently cancelled or soft-deleted.
CREATE INDEX idx_analysis_items_sales_handoff_history
    ON production_material_analysis_items (sales_order_item_id)
    WHERE source_type = 'SALES_ORDER_ITEM' AND sales_order_item_id IS NOT NULL;

CREATE INDEX idx_outbox_sales_planning_catch_up_pending
    ON business_outbox (aggregate_id)
    WHERE event_type = 'SALES_PLANNING_NOTICE_CATCH_UP' AND status = 0;

COMMENT ON COLUMN notices.source_revision IS
    'SALES_ORDER_APPROVED: finance_review_revision at delivery. NULL is legacy/other events; never infer old phases from timestamps.';
