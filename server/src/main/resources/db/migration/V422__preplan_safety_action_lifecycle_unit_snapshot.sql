-- V422: a public-safety action freezes its unit when it is created/externalized.
-- Later master-data unit changes must not block IN_PROGRESS/DONE/CANCELLED.

CREATE OR REPLACE FUNCTION fn_guard_preplan_supply_action_safety_split()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_item purchase_request_items%ROWTYPE;
    v_base_unit_id UUID;
    v_first_external_handshake BOOLEAN;
BEGIN
    v_first_external_handshake := TG_OP = 'UPDATE'
        AND OLD.safety_external_item_id IS NULL
        AND NEW.safety_external_item_id IS NOT NULL;

    -- Check the mutable goods master only while freezing a new action or its
    -- first public-safety purchase item. Lifecycle updates use the immutable
    -- action/request-item unit snapshots below.
    IF NEW.safety_replenishment_qty > 0
       AND (TG_OP = 'INSERT' OR v_first_external_handshake) THEN
        SELECT goods.unit_id INTO v_base_unit_id
        FROM goods WHERE goods.id = NEW.goods_id;
        IF v_base_unit_id IS NULL
           OR NEW.unit_id IS DISTINCT FROM v_base_unit_id THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'public safety replenishment must use the goods base unit',
                CONSTRAINT = 'preplan_supply_action_safety_base_unit_guard';
        END IF;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF OLD.safety_replenishment_qty
                IS DISTINCT FROM NEW.safety_replenishment_qty
           OR OLD.safety_stock_snapshot_qty
                IS DISTINCT FROM NEW.safety_stock_snapshot_qty
           OR OLD.public_available_snapshot_qty
                IS DISTINCT FROM NEW.public_available_snapshot_qty
           OR OLD.open_safety_supply_snapshot_qty
                IS DISTINCT FROM NEW.open_safety_supply_snapshot_qty THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'preplan safety replenishment quantity and basis are immutable',
                CONSTRAINT = 'preplan_supply_action_safety_identity_guard';
        END IF;
        IF OLD.safety_external_item_id IS NOT NULL
           AND NEW.safety_external_item_id
                IS DISTINCT FROM OLD.safety_external_item_id THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'preplan safety replenishment purchase item is immutable',
                CONSTRAINT = 'preplan_supply_action_safety_external_guard';
        END IF;
        IF v_first_external_handshake
           AND NOT (
               OLD.status = 'OPEN'
               AND NEW.status = 'CREATED'
               AND NEW.route = 'BUY'
               AND NEW.external_document_type = 'PURCHASE_REQUEST'
               AND NEW.external_document_id IS NOT NULL
           ) THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'safety purchase item may only be attached during BUY externalization',
                CONSTRAINT = 'preplan_supply_action_safety_external_guard';
        END IF;
    END IF;

    IF NEW.safety_external_item_id IS NOT NULL THEN
        SELECT * INTO v_item
        FROM purchase_request_items item
        WHERE item.id = NEW.safety_external_item_id;
        IF v_item.id IS NULL
           OR v_item.is_deleted
           OR v_item.request_id IS DISTINCT FROM NEW.external_document_id
           OR v_item.goods_id IS DISTINCT FROM NEW.goods_id
           OR v_item.color_id IS DISTINCT FROM NEW.color_id
           OR v_item.unit_id IS DISTINCT FROM NEW.unit_id
           OR COALESCE(v_item.unit_rate, 1) <> 1
           OR v_item.qty * COALESCE(v_item.unit_rate, 1)
                IS DISTINCT FROM NEW.safety_replenishment_qty
           OR EXISTS (
               SELECT 1
               FROM preplan_supply_action_allocations allocation
               WHERE allocation.external_item_id = NEW.safety_external_item_id
           ) THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'public safety replenishment item must be a separate matching purchase-request line',
                CONSTRAINT = 'preplan_supply_action_safety_external_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fn_guard_preplan_supply_action_safety_split() IS
    'Freezes BUY public-safety quantity, source item and unit snapshots while allowing later lifecycle transitions after goods-master unit changes';

-- The action handshake runs before the demand allocation receives its external
-- item. Reject the reverse mutation as well, otherwise a later allocation
-- handshake could point at the public-safety request item and make IQC exact-peg it.
CREATE OR REPLACE FUNCTION fn_guard_preplan_safety_item_not_demand_allocation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.external_item_id IS NOT NULL
       AND EXISTS (
           SELECT 1
           FROM preplan_supply_actions action
           WHERE action.id = NEW.action_id
             AND action.safety_external_item_id = NEW.external_item_id
       ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'public safety replenishment item cannot be used as an exact-demand allocation source',
            CONSTRAINT = 'preplan_safety_item_demand_allocation_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_preplan_safety_item_not_demand_allocation
    BEFORE INSERT OR UPDATE OF action_id, external_item_id
    ON preplan_supply_action_allocations
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_preplan_safety_item_not_demand_allocation();

COMMENT ON FUNCTION fn_guard_preplan_safety_item_not_demand_allocation() IS
    'Prevents a public-safety purchase item from ever becoming an IQC exact-demand allocation source';
