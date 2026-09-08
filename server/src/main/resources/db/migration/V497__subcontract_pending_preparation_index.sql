-- Completed preparations remain ACTIVE for history. Keep the operational hot set narrow.
CREATE INDEX idx_subcontract_make_pending
    ON preplan_subcontract_make_tasks(id)
    INCLUDE (preparation_item_id)
    WHERE status = 'ACTIVE' AND notified_qty < required_qty;
