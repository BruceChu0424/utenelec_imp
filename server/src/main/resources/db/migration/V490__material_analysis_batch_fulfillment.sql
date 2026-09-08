-- Keep batch material demand through plan issuance; finish only on actual fulfillment.
-- No historical stock, plan links, or completed analyses are rewritten by migration.
CREATE OR REPLACE FUNCTION fn_material_analysis_fulfillment_status(p_analysis_id UUID)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT CASE
      WHEN analysis.status='CANCELLED' THEN 'CANCELLED'
      WHEN NOT EXISTS (
        SELECT 1 FROM production_material_analysis_items item
        WHERE item.analysis_id=analysis.id AND item.is_deleted=FALSE
          AND item.requested_qty > item.root_fulfilled_qty + COALESCE((
            SELECT SUM(LEAST(plan_item.qty,GREATEST(COALESCE(plan_item.iqty,0),0)))
            FROM production_plans plan
            JOIN production_plan_items plan_item ON plan_item.plan_id=plan.id
              AND plan_item.is_deleted=FALSE
            WHERE plan.material_analysis_item_id=item.id
              AND plan.material_analysis_id=analysis.id
              AND plan.status=1 AND plan.is_deleted=FALSE AND plan.is_canceled=FALSE
          ),0))
        AND NOT EXISTS (
          SELECT 1 FROM preplan_supply_actions action
          WHERE action.analysis_id=analysis.id
            AND action.status IN ('OPEN','CREATED','IN_PROGRESS'))
        THEN 'COMPLETED'
      WHEN EXISTS (
        SELECT 1 FROM production_material_analysis_items item
        WHERE item.analysis_id=analysis.id AND item.is_deleted=FALSE
          AND item.submitted_qty+item.approved_qty+item.root_fulfilled_qty>0)
        THEN 'PARTIALLY_PLANNED'
      ELSE 'ACTIVE' END
    FROM production_material_analyses analysis WHERE analysis.id=p_analysis_id;
$$;

CREATE OR REPLACE FUNCTION fn_sync_material_analysis_plan_link_qty()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_submitted NUMERIC(18,4) := 0;
    v_old_approved  NUMERIC(18,4) := 0;
    v_new_submitted NUMERIC(18,4) := 0;
    v_new_approved  NUMERIC(18,4) := 0;
    v_item production_material_analysis_items%ROWTYPE;
    v_next_submitted NUMERIC(18,4);
    v_next_approved NUMERIC(18,4);
    v_old_remaining NUMERIC(18,4);
    v_item_remaining NUMERIC(18,4);
    v_remaining NUMERIC(18,4);
    v_used NUMERIC(18,4);
    v_old_claim NUMERIC(18,4);
    v_new_claim NUMERIC(18,4);
    v_updated_nodes INTEGER;
    v_active_nodes INTEGER;
    v_has_nonlinear_claim BOOLEAN := FALSE;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'material analysis plan links are append-only'
            USING ERRCODE = '55000';
    END IF;

    PERFORM 1
    FROM production_material_analyses
    WHERE id = NEW.analysis_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'material analysis not found'
            USING ERRCODE = '23503';
    END IF;

    IF TG_OP = 'UPDATE' AND (
        OLD.analysis_id IS DISTINCT FROM NEW.analysis_id
        OR OLD.analysis_item_id IS DISTINCT FROM NEW.analysis_item_id
        OR OLD.plan_id IS DISTINCT FROM NEW.plan_id
        OR OLD.submitted_qty IS DISTINCT FROM NEW.submitted_qty
        OR OLD.created_by IS DISTINCT FROM NEW.created_by
        OR OLD.created_at IS DISTINCT FROM NEW.created_at
    ) THEN
        RAISE EXCEPTION 'material analysis plan-link identity is immutable'
            USING ERRCODE = '55000';
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NOT EXISTS (
            SELECT 1 FROM production_material_analysis_items i
            WHERE i.id = NEW.analysis_item_id
              AND i.analysis_id = NEW.analysis_id
              AND i.is_deleted = FALSE
        ) THEN
            RAISE EXCEPTION 'material analysis item does not belong to analysis'
                USING ERRCODE = '23514';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM production_plans p
            WHERE p.id = NEW.plan_id
              AND p.material_analysis_id = NEW.analysis_id
              AND p.material_analysis_item_id = NEW.analysis_item_id
              AND p.status = 0
              AND p.is_deleted = FALSE
              AND p.is_canceled = FALSE
        ) THEN
            RAISE EXCEPTION 'linked production plan is not the same active analysis draft'
                USING ERRCODE = '23514';
        END IF;
        IF (SELECT COUNT(*) FROM production_plan_items pi
            WHERE pi.plan_id = NEW.plan_id AND pi.is_deleted = FALSE) <> 1
           OR NOT EXISTS (
               SELECT 1
               FROM production_plan_items pi
               JOIN production_material_analysis_items ai
                 ON ai.id = NEW.analysis_item_id
                AND ai.analysis_id = NEW.analysis_id
                AND ai.is_deleted = FALSE
               LEFT JOIN sales_order_items soi
                 ON soi.id = ai.sales_order_item_id AND soi.is_deleted = FALSE
               WHERE pi.plan_id = NEW.plan_id
                 AND pi.is_deleted = FALSE
                 AND pi.goods_id = ai.goods_id
                 AND pi.color_id IS NOT DISTINCT FROM ai.color_id
                 AND pi.unit_id = ai.unit_id
                 AND COALESCE(pi.unit_rate,1) = COALESCE(soi.unit_rate,1)
                 AND pi.sales_order_item_id IS NOT DISTINCT FROM ai.sales_order_item_id
                 AND pi.qty = NEW.submitted_qty
           ) THEN
            RAISE EXCEPTION 'analysis demand, plan item and submitted quantity differ'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        v_old_submitted := CASE WHEN OLD.allocation_status = 'SUBMITTED'
            THEN OLD.submitted_qty ELSE 0 END;
        v_old_approved := CASE WHEN OLD.allocation_status = 'APPROVED'
            THEN OLD.submitted_qty ELSE 0 END;
    END IF;
    v_new_submitted := CASE WHEN NEW.allocation_status = 'SUBMITTED'
        THEN NEW.submitted_qty ELSE 0 END;
    v_new_approved := CASE WHEN NEW.allocation_status = 'APPROVED'
        THEN NEW.submitted_qty ELSE 0 END;
    v_old_claim := v_old_submitted + v_old_approved;
    v_new_claim := v_new_submitted + v_new_approved;

    SELECT * INTO v_item
    FROM production_material_analysis_items
    WHERE id = NEW.analysis_item_id
    FOR UPDATE;

    IF v_item.id IS NULL THEN
        RAISE EXCEPTION 'material analysis item not found'
            USING ERRCODE = '23503';
    END IF;

    IF v_new_claim > v_old_claim THEN
        SELECT EXISTS (
            SELECT 1
            FROM production_material_analysis_materials material
            WHERE material.analysis_id = NEW.analysis_id
              AND material.analysis_item_id = NEW.analysis_item_id
              AND material.active = TRUE
              AND material.depth = 1
              AND material.consumption_basis <> 'PER_UNIT'
        ) INTO v_has_nonlinear_claim;
    END IF;

    v_old_remaining := v_item.requested_qty
        - v_item.submitted_qty - v_item.approved_qty - v_item.root_fulfilled_qty;
    v_next_submitted := v_item.submitted_qty
        - v_old_submitted + v_new_submitted;
    v_next_approved := v_item.approved_qty
        - v_old_approved + v_new_approved;
    v_item_remaining := v_item.requested_qty
        - v_next_submitted - v_next_approved - v_item.root_fulfilled_qty;

    UPDATE production_material_analysis_items
    SET submitted_qty = v_next_submitted,
        approved_qty = v_next_approved,
        ready_now_qty = CASE
            WHEN v_old_claim > v_new_claim OR v_has_nonlinear_claim THEN 0
            WHEN v_new_claim > v_old_claim THEN LEAST(
                GREATEST(ready_now_qty - (v_new_claim - v_old_claim), 0),
                v_item_remaining)
            ELSE LEAST(ready_now_qty, v_item_remaining)
        END,
        ready_by_date_qty = CASE
            WHEN v_old_claim > v_new_claim OR v_has_nonlinear_claim THEN 0
            WHEN v_new_claim > v_old_claim THEN LEAST(
                GREATEST(ready_by_date_qty - (v_new_claim - v_old_claim), 0),
                v_item_remaining)
            ELSE LEAST(ready_by_date_qty, v_item_remaining)
        END,
        ready_start_qty = CASE
            WHEN v_old_claim > v_new_claim OR v_has_nonlinear_claim THEN 0
            WHEN v_new_claim > v_old_claim THEN LEAST(
                GREATEST(ready_start_qty - (v_new_claim - v_old_claim), 0),
                v_item_remaining)
            ELSE LEAST(ready_start_qty, v_item_remaining)
        END,
        ready_finish_qty = CASE
            WHEN v_old_claim > v_new_claim OR v_has_nonlinear_claim THEN 0
            WHEN v_new_claim > v_old_claim THEN LEAST(
                GREATEST(ready_finish_qty - (v_new_claim - v_old_claim), 0),
                v_item_remaining)
            ELSE LEAST(ready_finish_qty, v_item_remaining)
        END,
        ready_ship_qty = CASE
            WHEN v_old_claim > v_new_claim OR v_has_nonlinear_claim THEN 0
            WHEN v_new_claim > v_old_claim THEN LEAST(
                GREATEST(ready_ship_qty - (v_new_claim - v_old_claim), 0),
                v_item_remaining)
            ELSE LEAST(ready_ship_qty, v_item_remaining)
        END,
        updated_at = now()
    WHERE id = NEW.analysis_item_id;

    -- Issuance updates plan claims only. Physical demand and coverage are
    -- refreshed from qualified stock and formal reservations by the application.
    UPDATE production_material_analyses
    SET status = fn_material_analysis_fulfillment_status(NEW.analysis_id),
        version = version + 1,
        fingerprint = encode(digest(
            fingerprint || '|PLAN-LINK|' || NEW.id::text || '|'
                || NEW.allocation_status || '|' || version::text,
            'sha256'), 'hex'),
        preview_fingerprint = NULL,
        updated_at = now()
    WHERE id = NEW.analysis_id AND status <> 'CANCELLED';
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;
