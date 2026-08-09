-- V250: extend the V162/V194 production source backstop to material-analysis
-- pre-plan documents. A preplan external link is historical provenance even
-- after its action is CANCELLED; generic CRUD must not detach the provenance
-- and then mutate/delete the purchase or subcontract source line.

CREATE INDEX idx_preplan_supply_action_external_document_history
    ON preplan_supply_actions(
        external_document_type, external_document_id, status, id)
    WHERE external_document_id IS NOT NULL;

CREATE INDEX idx_preplan_supply_allocation_external_item_history
    ON preplan_supply_action_allocations(external_item_id, action_id)
    WHERE external_item_id IS NOT NULL;

-- V234 paired type/id for active actions but deliberately left CANCELLED
-- flexible. Freeze one unambiguous route/type shape for both live and
-- historical external actions before relying on it as provenance.
ALTER TABLE preplan_supply_actions
    ADD CONSTRAINT preplan_supply_action_route_external_v250_chk CHECK (
        (external_document_type IS NULL
            AND external_document_id IS NULL
            AND external_document_no IS NULL)
        OR
        (external_document_type IS NOT NULL
            AND external_document_id IS NOT NULL
            AND (
                (route = 'BUY'
                    AND external_document_type = 'PURCHASE_REQUEST')
                OR (route = 'SUBCONTRACT'
                    AND external_document_type =
                        'SUBCONTRACT_APPLICATION')
                OR (route = 'MAKE'
                    AND external_document_type = 'PREPLAN_MAKE_TASK')
            ))
    );

-- Keep the original function signature because V194's production-plan item
-- guard also calls it. The formal production_material_supply_pegs branch is
-- unchanged; pre-plan provenance is an additional, never weaker, reason to
-- protect a source item. Direct request/application rows retain provenance for
-- every action status. Downstream order rows remain editable while both the
-- order and preplan projection are only CREATED drafts (including a finance
-- rejection); approval/reversal or an advanced/cancelled action freezes them.
CREATE OR REPLACE FUNCTION fn_has_protected_production_supply_peg(
    p_supply_type TEXT,
    p_supply_item_id UUID
) RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM production_material_supply_pegs peg
        WHERE peg.supply_type = p_supply_type
          AND peg.supply_item_id = p_supply_item_id
    ) OR (
        p_supply_type = 'PURCHASE_REQUEST_ITEM'
        AND EXISTS (
            SELECT 1
            FROM preplan_supply_action_allocations allocation
            JOIN preplan_supply_actions action
              ON action.id = allocation.action_id
             AND action.route = 'BUY'
            WHERE allocation.external_item_id = p_supply_item_id
        )
    ) OR (
        p_supply_type = 'SUBCONTRACT_APPLICATION_ITEM'
        AND EXISTS (
            SELECT 1
            FROM preplan_supply_action_allocations allocation
            JOIN preplan_supply_actions action
              ON action.id = allocation.action_id
             AND action.route = 'SUBCONTRACT'
            WHERE allocation.external_item_id = p_supply_item_id
        )
    ) OR (
        p_supply_type = 'PURCHASE_ORDER_ITEM'
        AND EXISTS (
            SELECT 1
            FROM purchase_order_items order_item
            JOIN purchase_orders order_header
              ON order_header.id = order_item.order_id
            JOIN preplan_supply_action_allocations allocation
              ON allocation.external_item_id = order_item.request_item_id
            JOIN preplan_supply_actions action
              ON action.id = allocation.action_id
             AND action.route = 'BUY'
            WHERE order_item.id = p_supply_item_id
              AND (order_header.status <> 0
                   OR action.status IN (
                       'IN_PROGRESS', 'DONE', 'CANCELLED'))
        )
    ) OR (
        p_supply_type = 'SUBCONTRACT_ORDER_ITEM'
        AND EXISTS (
            SELECT 1
            FROM subcontract_order_items order_item
            JOIN subcontract_orders order_header
              ON order_header.id = order_item.order_id
            JOIN preplan_supply_action_allocations allocation
              ON allocation.external_item_id = order_item.application_item_id
            JOIN preplan_supply_actions action
              ON action.id = allocation.action_id
             AND action.route = 'SUBCONTRACT'
            WHERE order_item.id = p_supply_item_id
              AND (order_header.status <> 0
                   OR action.status IN (
                       'IN_PROGRESS', 'DONE', 'CANCELLED'))
        )
    );
$$;

COMMENT ON FUNCTION fn_has_protected_production_supply_peg(TEXT, UUID)
    IS 'True for any formal production peg, direct preplan source history, or a preplan order item after approval/reversal/action advancement; CREATED draft orders remain editable.';

-- Deferred order-item triggers must evaluate OLD as well as NEW provenance.
-- The current row may already point at a different request/application item,
-- or may have been deleted. Missing order headers fail closed: generic hard
-- deletion cannot erase the status fact before the deferred guard runs.
CREATE OR REPLACE FUNCTION fn_has_protected_preplan_order_context(
    p_supply_type text,
    p_order_id uuid,
    p_upstream_item_id uuid
) RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
        WHEN p_supply_type = 'PURCHASE_ORDER_ITEM' THEN EXISTS (
            SELECT 1
            FROM preplan_supply_action_allocations allocation
            JOIN preplan_supply_actions action
              ON action.id = allocation.action_id
             AND action.route = 'BUY'
            WHERE allocation.external_item_id = p_upstream_item_id
              AND (
                  action.status IN ('IN_PROGRESS', 'DONE', 'CANCELLED')
                  OR NOT EXISTS (
                      SELECT 1 FROM purchase_orders order_header
                      WHERE order_header.id = p_order_id
                  )
                  OR EXISTS (
                      SELECT 1 FROM purchase_orders order_header
                      WHERE order_header.id = p_order_id
                        AND order_header.status <> 0
                  )
              )
        )
        WHEN p_supply_type = 'SUBCONTRACT_ORDER_ITEM' THEN EXISTS (
            SELECT 1
            FROM preplan_supply_action_allocations allocation
            JOIN preplan_supply_actions action
              ON action.id = allocation.action_id
             AND action.route = 'SUBCONTRACT'
            WHERE allocation.external_item_id = p_upstream_item_id
              AND (
                  action.status IN ('IN_PROGRESS', 'DONE', 'CANCELLED')
                  OR NOT EXISTS (
                      SELECT 1 FROM subcontract_orders order_header
                      WHERE order_header.id = p_order_id
                  )
                  OR EXISTS (
                      SELECT 1 FROM subcontract_orders order_header
                      WHERE order_header.id = p_order_id
                        AND order_header.status <> 0
                  )
              )
        )
        ELSE FALSE
    END;
$$;

-- Once an action has an external document (or any allocation already has an
-- external item), its business identity and document provenance are frozen.
-- Lifecycle-only transitions remain legal so refresh can move
-- CREATED/IN_PROGRESS/DONE and the dedicated cancellation flow can atomically
-- move the action to CANCELLED.
CREATE OR REPLACE FUNCTION fn_guard_preplan_supply_action_history()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_externalized boolean;
BEGIN
    v_externalized := OLD.external_document_type IS NOT NULL
        OR OLD.external_document_id IS NOT NULL
        OR OLD.external_document_no IS NOT NULL
        OR EXISTS (
            SELECT 1
            FROM preplan_supply_action_allocations allocation
            WHERE allocation.action_id = OLD.id
              AND allocation.external_item_id IS NOT NULL
        );

    IF NOT v_externalized THEN
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;
        IF (NEW.external_document_type IS NOT NULL
            OR NEW.external_document_id IS NOT NULL
            OR NEW.external_document_no IS NOT NULL) THEN
            IF OLD.status <> 'OPEN'
               OR NEW.status <> 'CREATED'
               OR NEW.external_document_type IS NULL
               OR NEW.external_document_id IS NULL
               OR NOT (
                   (NEW.route = 'BUY'
                    AND NEW.external_document_type = 'PURCHASE_REQUEST')
                   OR (NEW.route = 'SUBCONTRACT'
                       AND NEW.external_document_type =
                           'SUBCONTRACT_APPLICATION')
                   OR (NEW.route = 'MAKE'
                       AND NEW.external_document_type =
                           'PREPLAN_MAKE_TASK')
               ) THEN
                RAISE EXCEPTION
                    'preplan action externalization handshake is invalid'
                    USING ERRCODE = '23514',
                          CONSTRAINT =
                            'preplan_external_supply_action_handshake_guard';
            END IF;
            IF OLD.id IS DISTINCT FROM NEW.id
                OR OLD.analysis_id IS DISTINCT FROM NEW.analysis_id
                OR OLD.warehouse_id IS DISTINCT FROM NEW.warehouse_id
                OR OLD.goods_id IS DISTINCT FROM NEW.goods_id
                OR OLD.color_id IS DISTINCT FROM NEW.color_id
                OR OLD.unit_id IS DISTINCT FROM NEW.unit_id
                OR OLD.need_date IS DISTINCT FROM NEW.need_date
                OR OLD.route IS DISTINCT FROM NEW.route
                OR OLD.requested_qty IS DISTINCT FROM NEW.requested_qty
                OR OLD.idempotency_key IS DISTINCT FROM NEW.idempotency_key
                OR OLD.action_group_key
                    IS DISTINCT FROM NEW.action_group_key
                OR OLD.request_business_key
                    IS DISTINCT FROM NEW.request_business_key
                OR OLD.generation IS DISTINCT FROM NEW.generation
                OR OLD.predecessor_action_id
                    IS DISTINCT FROM NEW.predecessor_action_id
                OR OLD.request_hash IS DISTINCT FROM NEW.request_hash
                OR OLD.created_by IS DISTINCT FROM NEW.created_by
                OR OLD.created_at IS DISTINCT FROM NEW.created_at THEN
                RAISE EXCEPTION
                    'preplan action identity cannot change while externalizing'
                    USING ERRCODE = '23514',
                          CONSTRAINT =
                            'preplan_external_supply_action_identity_guard';
            END IF;
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'preplan external supply action history is append-only'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'preplan_external_supply_action_append_only_guard';
    END IF;

    IF OLD.id IS DISTINCT FROM NEW.id
       OR OLD.analysis_id IS DISTINCT FROM NEW.analysis_id
       OR OLD.warehouse_id IS DISTINCT FROM NEW.warehouse_id
       OR OLD.goods_id IS DISTINCT FROM NEW.goods_id
       OR OLD.color_id IS DISTINCT FROM NEW.color_id
       OR OLD.unit_id IS DISTINCT FROM NEW.unit_id
       OR OLD.need_date IS DISTINCT FROM NEW.need_date
       OR OLD.route IS DISTINCT FROM NEW.route
       OR OLD.requested_qty IS DISTINCT FROM NEW.requested_qty
       OR OLD.external_document_type
            IS DISTINCT FROM NEW.external_document_type
       OR OLD.external_document_id
            IS DISTINCT FROM NEW.external_document_id
       OR OLD.external_document_no
            IS DISTINCT FROM NEW.external_document_no
       OR OLD.idempotency_key IS DISTINCT FROM NEW.idempotency_key
       OR OLD.action_group_key IS DISTINCT FROM NEW.action_group_key
       OR OLD.request_business_key
            IS DISTINCT FROM NEW.request_business_key
       OR OLD.generation IS DISTINCT FROM NEW.generation
       OR OLD.predecessor_action_id
            IS DISTINCT FROM NEW.predecessor_action_id
       OR OLD.request_hash IS DISTINCT FROM NEW.request_hash
       OR OLD.created_by IS DISTINCT FROM NEW.created_by
       OR OLD.created_at IS DISTINCT FROM NEW.created_at THEN
        RAISE EXCEPTION
            'preplan external supply action identity is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'preplan_external_supply_action_identity_guard';
    END IF;

    IF OLD.status = 'CANCELLED'
       AND (NEW.status IS DISTINCT FROM 'CANCELLED'
            OR OLD.cancelled_by IS DISTINCT FROM NEW.cancelled_by
            OR OLD.cancelled_at IS DISTINCT FROM NEW.cancelled_at
            OR OLD.cancellation_reason
                IS DISTINCT FROM NEW.cancellation_reason) THEN
        RAISE EXCEPTION
            'cancelled preplan external supply action cannot be reactivated or rewritten'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'preplan_external_supply_action_cancelled_guard';
    END IF;
    IF OLD.status IN ('IN_PROGRESS', 'DONE')
       AND NEW.status = 'CREATED' THEN
        RAISE EXCEPTION
            'advanced preplan external supply action cannot return to draft'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'preplan_external_supply_action_status_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_preplan_supply_action_history
    BEFORE UPDATE OR DELETE ON preplan_supply_actions
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_preplan_supply_action_history();

-- The allocation is editable while it is a pre-plan-only draft. The first
-- NULL -> external_item_id transition is the dedicated document-creation
-- handshake. Thereafter the exact row is append-only; an idempotent no-op
-- update remains harmless and legal.
CREATE OR REPLACE FUNCTION fn_guard_preplan_supply_allocation_history()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_action preplan_supply_actions%ROWTYPE;
    v_external_item_valid boolean;
BEGIN
    IF OLD.external_item_id IS NULL THEN
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;
        IF NEW.external_item_id IS NOT NULL
           AND (OLD.id IS DISTINCT FROM NEW.id
                OR OLD.analysis_id IS DISTINCT FROM NEW.analysis_id
                OR OLD.action_id IS DISTINCT FROM NEW.action_id
                OR OLD.analysis_material_id
                    IS DISTINCT FROM NEW.analysis_material_id
                OR OLD.allocated_qty IS DISTINCT FROM NEW.allocated_qty
                OR OLD.created_at IS DISTINCT FROM NEW.created_at
                OR OLD.created_by IS DISTINCT FROM NEW.created_by) THEN
            RAISE EXCEPTION
                'preplan allocation identity cannot change while externalizing'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                        'preplan_external_supply_allocation_identity_guard';
        END IF;
        IF NEW.external_item_id IS NOT NULL THEN
            SELECT * INTO v_action
            FROM preplan_supply_actions action
            WHERE action.id = NEW.action_id
            FOR KEY SHARE;
            v_external_item_valid := CASE v_action.route
                WHEN 'BUY' THEN
                    v_action.status = 'CREATED'
                    AND v_action.external_document_type = 'PURCHASE_REQUEST'
                    AND EXISTS (
                        SELECT 1
                        FROM purchase_request_items item
                        WHERE item.id = NEW.external_item_id
                          AND item.request_id =
                              v_action.external_document_id
                          AND item.is_deleted = FALSE
                    )
                WHEN 'SUBCONTRACT' THEN
                    v_action.status = 'CREATED'
                    AND v_action.external_document_type =
                        'SUBCONTRACT_APPLICATION'
                    AND EXISTS (
                        SELECT 1
                        FROM subcontract_application_items item
                        WHERE item.id = NEW.external_item_id
                          AND item.application_id =
                              v_action.external_document_id
                          AND item.is_deleted = FALSE
                    )
                WHEN 'MAKE' THEN
                    v_action.status = 'CREATED'
                    AND v_action.external_document_type =
                        'PREPLAN_MAKE_TASK'
                    AND v_action.external_document_id =
                        NEW.external_item_id
                    AND EXISTS (
                        SELECT 1
                        FROM production_material_analysis_items item
                        WHERE item.id = NEW.external_item_id
                          AND item.analysis_id = NEW.analysis_id
                          AND item.source_type = 'MAKE_COMPONENT'
                          AND item.is_deleted = FALSE
                    )
                ELSE FALSE
            END;
            IF v_action.id IS NULL
               OR NOT COALESCE(v_external_item_valid, FALSE) THEN
                RAISE EXCEPTION
                    'preplan allocation externalization handshake is invalid'
                    USING ERRCODE = '23514',
                          CONSTRAINT =
                            'preplan_external_supply_allocation_handshake_guard';
            END IF;
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'preplan external supply allocation history is append-only'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'preplan_external_supply_allocation_append_only_guard';
    END IF;

    IF OLD.id IS DISTINCT FROM NEW.id
       OR OLD.analysis_id IS DISTINCT FROM NEW.analysis_id
       OR OLD.action_id IS DISTINCT FROM NEW.action_id
       OR OLD.analysis_material_id
            IS DISTINCT FROM NEW.analysis_material_id
       OR OLD.allocated_qty IS DISTINCT FROM NEW.allocated_qty
       OR OLD.external_item_id IS DISTINCT FROM NEW.external_item_id
       OR OLD.created_at IS DISTINCT FROM NEW.created_at
       OR OLD.created_by IS DISTINCT FROM NEW.created_by THEN
        RAISE EXCEPTION
            'preplan external supply allocation history is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'preplan_external_supply_allocation_identity_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_preplan_supply_allocation_history
    BEFORE UPDATE OR DELETE ON preplan_supply_action_allocations
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_preplan_supply_allocation_history();

-- V194 is the latest definition of this shared trigger function. Preserve its
-- PRODUCTION_PLAN_ITEM branch and add OLD/NEW upstream checks for derived order
-- items. Checking OLD is essential for deferred UPDATE/DELETE triggers: the
-- current order row may already be gone or may already point somewhere else.
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

CREATE OR REPLACE FUNCTION fn_has_preplan_external_document_history(
    p_document_type text,
    p_document_id uuid,
    p_live_only boolean
) RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM preplan_supply_actions action
        WHERE (NOT COALESCE(p_live_only, FALSE)
               OR action.status <> 'CANCELLED')
          AND (
              (action.external_document_type = p_document_type
               AND action.external_document_id = p_document_id)
              OR (
                  p_document_type = 'PURCHASE_REQUEST'
                  AND action.route = 'BUY'
                  AND EXISTS (
                      SELECT 1
                      FROM preplan_supply_action_allocations allocation
                      JOIN purchase_request_items item
                        ON item.id = allocation.external_item_id
                      WHERE allocation.action_id = action.id
                        AND item.request_id = p_document_id
                  )
              )
              OR (
                  p_document_type = 'SUBCONTRACT_APPLICATION'
                  AND action.route = 'SUBCONTRACT'
                  AND EXISTS (
                      SELECT 1
                      FROM preplan_supply_action_allocations allocation
                      JOIN subcontract_application_items item
                        ON item.id = allocation.external_item_id
                      WHERE allocation.action_id = action.id
                        AND item.application_id = p_document_id
                  )
              )
          )
    );
$$;

-- Preserve V162 formal-peg close/release semantics. Preplan source documents
-- add two rules: an active action must be cancelled in the same transaction as
-- the dedicated downstream cancel/reverse, and any historical action (including
-- CANCELLED) permanently forbids resurrection of that source document.
CREATE OR REPLACE FUNCTION fn_guard_production_supply_source_header()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_has_live boolean;
    v_has_history boolean;
    v_constraint text;
    v_document_type text;
BEGIN
    IF TG_TABLE_NAME = 'purchase_requests' THEN
        v_document_type := 'PURCHASE_REQUEST';
    ELSIF TG_TABLE_NAME = 'subcontract_applications' THEN
        v_document_type := 'SUBCONTRACT_APPLICATION';
    ELSE
        RAISE EXCEPTION 'unsupported production supply source header'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'production_supply_source_header_table_guard';
    END IF;

    IF TG_OP = 'UPDATE'
       AND (
           (OLD.status = -1 AND NEW.status <> -1)
           OR (
               COALESCE(OLD.is_deleted, FALSE) = TRUE
               AND COALESCE(NEW.is_deleted, FALSE) = FALSE
           )
       ) THEN
        IF TG_TABLE_NAME = 'purchase_requests' THEN
            SELECT EXISTS (
                SELECT 1
                FROM purchase_request_items item
                JOIN production_material_supply_pegs peg
                  ON peg.supply_type = 'PURCHASE_REQUEST_ITEM'
                 AND peg.supply_item_id = item.id
                WHERE item.request_id = OLD.id
            ) INTO v_has_history;
            v_constraint :=
                'production_purchase_request_lifecycle_guard';
        ELSE
            SELECT EXISTS (
                SELECT 1
                FROM subcontract_application_items item
                JOIN production_material_supply_pegs peg
                  ON peg.supply_type =
                        'SUBCONTRACT_APPLICATION_ITEM'
                 AND peg.supply_item_id = item.id
                WHERE item.application_id = OLD.id
            ) INTO v_has_history;
            v_constraint :=
                'production_subcontract_application_lifecycle_guard';
        END IF;
        v_has_history := v_has_history
            OR fn_has_preplan_external_document_history(
                v_document_type, OLD.id, FALSE);
        IF v_has_history THEN
            RAISE EXCEPTION
                'production-linked source document cannot be reactivated'
                USING ERRCODE = '23514',
                      CONSTRAINT = v_constraint;
        END IF;
    END IF;

    IF TG_OP <> 'DELETE'
       AND COALESCE(NEW.is_deleted, FALSE) = FALSE
       AND NEW.status <> -1
       AND NEW.warehouse_id IS NOT DISTINCT FROM OLD.warehouse_id
       AND NEW.need_date IS NOT DISTINCT FROM OLD.need_date
    THEN
        RETURN NEW;
    END IF;

    IF TG_TABLE_NAME = 'purchase_requests' THEN
        SELECT EXISTS (
            SELECT 1
            FROM purchase_request_items item
            JOIN production_material_supply_pegs peg
              ON peg.supply_type = 'PURCHASE_REQUEST_ITEM'
             AND peg.supply_item_id = item.id
             AND (
                 peg.status NOT IN ('RELEASED', 'REVERSED')
                 OR EXISTS (
                     SELECT 1
                     FROM production_material_peg_transfers transfer
                     WHERE transfer.from_peg_id = peg.id
                       AND transfer.status = 'EFFECTIVE'
                 )
             )
            WHERE item.request_id = OLD.id
        ) INTO v_has_live;
        v_constraint := 'production_purchase_request_supply_guard';
    ELSE
        SELECT EXISTS (
            SELECT 1
            FROM subcontract_application_items item
            JOIN production_material_supply_pegs peg
              ON peg.supply_type =
                    'SUBCONTRACT_APPLICATION_ITEM'
             AND peg.supply_item_id = item.id
             AND (
                 peg.status NOT IN ('RELEASED', 'REVERSED')
                 OR EXISTS (
                     SELECT 1
                     FROM
                       production_material_subcontract_peg_transfers transfer
                     WHERE transfer.from_peg_id = peg.id
                       AND transfer.status = 'EFFECTIVE'
                 )
             )
            WHERE item.application_id = OLD.id
        ) INTO v_has_live;
        v_constraint :=
            'production_subcontract_application_supply_guard';
    END IF;

    v_has_live := v_has_live
        OR fn_has_preplan_external_document_history(
            v_document_type, OLD.id, TRUE);
    IF v_has_live THEN
        RAISE EXCEPTION
            'production-linked supply source must be released or cancelled before close'
            USING ERRCODE = '23514',
                  CONSTRAINT = v_constraint;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;
