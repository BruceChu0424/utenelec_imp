-- Reconcile only the mutable preparation projection. Supply actions and plan links
-- are independent source evidence and must agree before old quantities are repaired.
-- In particular, never infer a missing public action or cancel an unexplained one.
CREATE INDEX IF NOT EXISTS idx_preplan_subcontract_make_action_item
    ON preplan_supply_actions(analysis_id, external_document_id)
    WHERE external_document_type = 'SUBCONTRACT_MAKE_TASK' AND status <> 'CANCELLED';

DO $reconcile$
DECLARE
    mismatch TEXT;
BEGIN
    WITH commitments AS (
        SELECT task.id, task.required_qty, task.produced_qty, task.notified_qty,
               item.requested_qty,
               COALESCE((SELECT SUM(action.public_surplus_qty)
                         FROM preplan_supply_actions action
                         WHERE action.analysis_id = task.analysis_id
                           AND action.external_document_type = 'SUBCONTRACT_MAKE_TASK'
                           AND action.external_document_id = task.preparation_item_id
                           AND action.status <> 'CANCELLED'), 0) AS action_surplus,
               COALESCE((SELECT SUM(link.public_surplus_qty)
                         FROM production_material_analysis_plan_links link
                         WHERE link.analysis_id = task.analysis_id
                           AND link.analysis_item_id = task.preparation_item_id
                           AND link.allocation_status IN ('SUBMITTED', 'APPROVED')), 0) AS plan_surplus
        FROM preplan_subcontract_make_tasks task
        JOIN production_material_analysis_items item ON item.id = task.preparation_item_id
        WHERE task.status = 'ACTIVE'
    )
    SELECT string_agg(id::text || '[actions=' || action_surplus || ',plans=' || plan_surplus ||
                      ',required=' || required_qty || ']', '; ' ORDER BY id)
    INTO mismatch
    FROM (SELECT * FROM commitments
          WHERE action_surplus <> plan_surplus
             OR requested_qty + action_surplus < GREATEST(produced_qty, notified_qty)
          ORDER BY id LIMIT 20) invalid;

    IF mismatch IS NOT NULL THEN
        RAISE EXCEPTION 'V621 subcontract preparation source mismatch: %', mismatch
            USING ERRCODE = '23514',
                  HINT = 'Reconcile the identified actions and production plans through their audited lifecycle before retrying. Historical source facts are not changed by this migration.';
    END IF;

    WITH expected AS (
        SELECT task.id, item.requested_qty + COALESCE(SUM(action.public_surplus_qty), 0) AS qty
        FROM preplan_subcontract_make_tasks task
        JOIN production_material_analysis_items item ON item.id = task.preparation_item_id
        LEFT JOIN preplan_supply_actions action ON action.analysis_id = task.analysis_id
             AND action.external_document_type = 'SUBCONTRACT_MAKE_TASK'
             AND action.external_document_id = task.preparation_item_id
             AND action.status <> 'CANCELLED'
        WHERE task.status = 'ACTIVE'
        GROUP BY task.id, item.requested_qty
    )
    UPDATE preplan_subcontract_make_tasks task
    SET required_qty = expected.qty, version = task.version + 1, updated_at = now()
    FROM expected
    WHERE task.id = expected.id AND task.required_qty IS DISTINCT FROM expected.qty;
END;
$reconcile$;
