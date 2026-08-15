-- V283: let finance approval freeze display snapshots without weakening the
-- production/pre-plan source-item backstop installed by V162/V194/V250.
--
-- The existing source-item constraint triggers are deferred deliberately: an
-- authoritative reversal may release its provenance and update the source row
-- in one transaction.  Finance approval, however, freezes the item while the
-- order header is still DRAFT and changes the header to APPROVED before those
-- deferred events run.  An immediate trigger therefore proves the DRAFT state
-- at update time; the deferred guard only recognizes that exact, already
-- validated one-way snapshot transition.

CREATE OR REPLACE FUNCTION fn_is_production_order_snapshot_approval_lock(
    p_table_name TEXT,
    p_old JSONB,
    p_new JSONB
) RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT
        p_table_name IN ('purchase_order_items', 'subcontract_order_items')
        AND p_old ->> 'goods_snapshot_locked_at' IS NULL
        AND p_new ->> 'goods_snapshot_locked_at' IS NOT NULL
        AND CASE p_table_name
            WHEN 'purchase_order_items' THEN
                p_new ->> 'goods_snapshot_source' IN (
                    'REQUEST_ITEM_AT_APPROVAL', 'MASTER_AT_APPROVAL')
            WHEN 'subcontract_order_items' THEN
                p_new ->> 'goods_snapshot_source' IN (
                    'APPLICATION_ITEM_AT_APPROVAL', 'MASTER_AT_APPROVAL')
            ELSE FALSE
        END
        AND (
            p_old - ARRAY[
                'goods_code_snapshot',
                'goods_name_snapshot',
                'goods_snapshot_source',
                'goods_snapshot_locked_at'
            ]::TEXT[]
        ) IS NOT DISTINCT FROM (
            p_new - ARRAY[
                'goods_code_snapshot',
                'goods_name_snapshot',
                'goods_snapshot_source',
                'goods_snapshot_locked_at'
            ]::TEXT[]
        );
$$;

CREATE OR REPLACE FUNCTION fn_guard_production_order_snapshot_approval()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_supply_type TEXT;
    v_constraint TEXT;
    v_upstream_item_id UUID;
    v_protected BOOLEAN;
    v_header_is_draft BOOLEAN;
    v_is_approval_lock BOOLEAN;
    v_provenance_is_exact BOOLEAN := FALSE;
BEGIN
    IF TG_TABLE_NAME = 'purchase_order_items' THEN
        v_supply_type := 'PURCHASE_ORDER_ITEM';
        v_constraint := 'production_purchase_order_item_supply_guard';
        v_upstream_item_id := OLD.request_item_id;
        PERFORM 1
        FROM purchase_orders header
        WHERE header.id = OLD.order_id
          AND header.status = 0
          AND COALESCE(header.is_deleted, FALSE) = FALSE
        FOR SHARE;
        v_header_is_draft := FOUND;

        IF NEW.goods_snapshot_source = 'REQUEST_ITEM_AT_APPROVAL' THEN
            PERFORM 1
            FROM purchase_request_items upstream
            WHERE upstream.id = NEW.request_item_id
              AND upstream.goods_id = NEW.goods_id
              AND upstream.goods_code_snapshot
                    IS NOT DISTINCT FROM NEW.goods_code_snapshot
              AND upstream.goods_name_snapshot
                    IS NOT DISTINCT FROM NEW.goods_name_snapshot
            FOR SHARE;
            v_provenance_is_exact := FOUND;
        ELSIF NEW.goods_snapshot_source = 'MASTER_AT_APPROVAL' THEN
            PERFORM 1
            FROM goods master
            WHERE master.id = NEW.goods_id
              AND master.code IS NOT DISTINCT FROM NEW.goods_code_snapshot
              AND master.name IS NOT DISTINCT FROM NEW.goods_name_snapshot
            FOR SHARE;
            v_provenance_is_exact := FOUND;
        END IF;
    ELSIF TG_TABLE_NAME = 'subcontract_order_items' THEN
        v_supply_type := 'SUBCONTRACT_ORDER_ITEM';
        v_constraint := 'production_subcontract_order_item_supply_guard';
        v_upstream_item_id := OLD.application_item_id;
        PERFORM 1
        FROM subcontract_orders header
        WHERE header.id = OLD.order_id
          AND header.status = 0
          AND COALESCE(header.is_deleted, FALSE) = FALSE
        FOR SHARE;
        v_header_is_draft := FOUND;

        IF NEW.goods_snapshot_source = 'APPLICATION_ITEM_AT_APPROVAL' THEN
            PERFORM 1
            FROM subcontract_application_items upstream
            WHERE upstream.id = NEW.application_item_id
              AND upstream.goods_id = NEW.goods_id
              AND upstream.goods_code_snapshot
                    IS NOT DISTINCT FROM NEW.goods_code_snapshot
              AND upstream.goods_name_snapshot
                    IS NOT DISTINCT FROM NEW.goods_name_snapshot
            FOR SHARE;
            v_provenance_is_exact := FOUND;
        ELSIF NEW.goods_snapshot_source = 'MASTER_AT_APPROVAL' THEN
            PERFORM 1
            FROM goods master
            WHERE master.id = NEW.goods_id
              AND master.code IS NOT DISTINCT FROM NEW.goods_code_snapshot
              AND master.name IS NOT DISTINCT FROM NEW.goods_name_snapshot
            FOR SHARE;
            v_provenance_is_exact := FOUND;
        END IF;
    ELSE
        RAISE EXCEPTION 'unsupported production order snapshot table'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_order_snapshot_table_guard';
    END IF;

    v_is_approval_lock :=
        fn_is_production_order_snapshot_approval_lock(
            TG_TABLE_NAME, to_jsonb(OLD), to_jsonb(NEW));

    -- Every first lock is an approval operation, even if the row is linked to
    -- production later in the same transaction.  Validate it while the header
    -- still exposes the update-time DRAFT state.
    IF OLD.goods_snapshot_locked_at IS NULL
       AND NEW.goods_snapshot_locked_at IS NOT NULL THEN
        IF v_is_approval_lock
           AND v_header_is_draft
           AND v_provenance_is_exact THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION
            'order goods snapshot can only be locked once during draft approval'
            USING ERRCODE = '23514', CONSTRAINT = v_constraint;
    END IF;

    v_protected := fn_has_protected_production_supply_peg(
        v_supply_type, OLD.id);
    IF NEW.id IS DISTINCT FROM OLD.id THEN
        v_protected := v_protected
            OR fn_has_protected_production_supply_peg(
                v_supply_type, NEW.id);
    END IF;
    IF OLD.order_id IS NOT NULL AND v_upstream_item_id IS NOT NULL THEN
        v_protected := v_protected
            OR fn_has_protected_preplan_order_context(
                v_supply_type, OLD.order_id, v_upstream_item_id);
    END IF;

    IF v_protected THEN
        RAISE EXCEPTION
            'production-linked supply source item cannot be changed or deleted'
            USING ERRCODE = '23514', CONSTRAINT = v_constraint;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_production_supply_source_item()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_supply_type text;
    v_constraint text;
    v_old_order_id uuid;
    v_new_order_id uuid;
    v_old_upstream_item_id uuid;
    v_new_upstream_item_id uuid;
    v_protected boolean;
BEGIN
    IF TG_TABLE_NAME = 'purchase_request_items' THEN
        v_supply_type := 'PURCHASE_REQUEST_ITEM';
        v_constraint :=
            'production_purchase_request_item_supply_guard';
    ELSIF TG_TABLE_NAME = 'subcontract_application_items' THEN
        v_supply_type := 'SUBCONTRACT_APPLICATION_ITEM';
        v_constraint :=
            'production_subcontract_application_item_supply_guard';
    ELSIF TG_TABLE_NAME = 'purchase_order_items' THEN
        v_supply_type := 'PURCHASE_ORDER_ITEM';
        v_constraint :=
            'production_purchase_order_item_supply_guard';
        v_old_order_id := OLD.order_id;
        v_old_upstream_item_id := OLD.request_item_id;
        IF TG_OP = 'UPDATE' THEN
            v_new_order_id := NEW.order_id;
            v_new_upstream_item_id := NEW.request_item_id;
        END IF;
    ELSIF TG_TABLE_NAME = 'subcontract_order_items' THEN
        v_supply_type := 'SUBCONTRACT_ORDER_ITEM';
        v_constraint :=
            'production_subcontract_order_item_supply_guard';
        v_old_order_id := OLD.order_id;
        v_old_upstream_item_id := OLD.application_item_id;
        IF TG_OP = 'UPDATE' THEN
            v_new_order_id := NEW.order_id;
            v_new_upstream_item_id := NEW.application_item_id;
        END IF;
    ELSIF TG_TABLE_NAME = 'production_plan_items' THEN
        v_supply_type := 'PRODUCTION_PLAN_ITEM';
        v_constraint := 'production_plan_item_supply_guard';
    ELSE
        RAISE EXCEPTION 'unsupported production supply source table'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'production_supply_source_table_guard';
    END IF;

    v_protected := fn_has_protected_production_supply_peg(
        v_supply_type, OLD.id);
    IF TG_OP = 'UPDATE' THEN
        v_protected := v_protected
            OR fn_has_protected_production_supply_peg(
                v_supply_type, NEW.id);
    END IF;
    IF v_old_order_id IS NOT NULL
       AND v_old_upstream_item_id IS NOT NULL THEN
        v_protected := v_protected
            OR fn_has_protected_preplan_order_context(
                v_supply_type, v_old_order_id,
                v_old_upstream_item_id);
    END IF;
    IF TG_OP = 'UPDATE'
       AND v_new_order_id IS NOT NULL
       AND v_new_upstream_item_id IS NOT NULL THEN
        v_protected := v_protected
            OR fn_has_protected_preplan_order_context(
                v_supply_type, v_new_order_id,
                v_new_upstream_item_id);
    END IF;

    IF v_protected THEN
        IF TG_OP = 'UPDATE'
           AND fn_is_production_order_snapshot_approval_lock(
               TG_TABLE_NAME, to_jsonb(OLD), to_jsonb(NEW)) THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION
            'production-linked supply source item cannot be changed or deleted'
            USING ERRCODE = '23514',
                  CONSTRAINT = v_constraint;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER trg_guard_production_purchase_order_item_update
    ON purchase_order_items;
CREATE CONSTRAINT TRIGGER
    trg_guard_production_purchase_order_item_update
    AFTER UPDATE OF
        id, order_id, request_item_id, goods_id, color_id,
        unit_id, unit_rate, qty, is_deleted,
        goods_code_snapshot, goods_name_snapshot,
        goods_snapshot_source, goods_snapshot_locked_at
    ON purchase_order_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_supply_source_item();

DROP TRIGGER trg_guard_production_subcontract_order_item_update
    ON subcontract_order_items;
CREATE CONSTRAINT TRIGGER
    trg_guard_production_subcontract_order_item_update
    AFTER UPDATE OF
        id, order_id, application_item_id, goods_id, color_id,
        unit_id, unit_rate, qty, is_deleted,
        goods_code_snapshot, goods_name_snapshot,
        goods_snapshot_source, goods_snapshot_locked_at
    ON subcontract_order_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_supply_source_item();

CREATE TRIGGER trg_guard_production_purchase_order_snapshot_approval
    BEFORE UPDATE OF
        goods_code_snapshot, goods_name_snapshot,
        goods_snapshot_source, goods_snapshot_locked_at
    ON purchase_order_items
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_order_snapshot_approval();

CREATE TRIGGER trg_guard_production_subcontract_order_snapshot_approval
    BEFORE UPDATE OF
        goods_code_snapshot, goods_name_snapshot,
        goods_snapshot_source, goods_snapshot_locked_at
    ON subcontract_order_items
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_production_order_snapshot_approval();
