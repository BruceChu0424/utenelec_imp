-- V247: BOM control stage, packaging measurement, and material-analysis snapshots.
--
-- Existing BOM rows keep the historical behavior: every component is a hard
-- start gate consumed per finished unit.  The analysis snapshot columns are
-- additive and the plan-link exchange below consumes only immutable snapshots.

ALTER TABLE goods_bom_items
    ADD COLUMN control_stage TEXT NOT NULL DEFAULT 'START',
    ADD COLUMN consumption_basis TEXT NOT NULL DEFAULT 'PER_UNIT',
    ADD COLUMN basis_output_qty NUMERIC(18,6) NOT NULL DEFAULT 1,
    ADD COLUMN allow_partial_package BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN hard_gate BOOLEAN NOT NULL DEFAULT TRUE,
    ADD CONSTRAINT goods_bom_item_control_stage_chk CHECK (
        control_stage IN ('START', 'ASSEMBLY', 'FINISH', 'SHIP', 'REFERENCE')
    ),
    ADD CONSTRAINT goods_bom_item_hard_gate_stage_chk CHECK (
        NOT hard_gate OR control_stage IN ('START', 'ASSEMBLY', 'FINISH')
    ),
    ADD CONSTRAINT goods_bom_item_consumption_basis_chk CHECK (
        consumption_basis IN ('PER_UNIT', 'PER_PACKAGE', 'FIXED_BATCH')
    ),
    ADD CONSTRAINT goods_bom_item_basis_output_qty_chk CHECK (
        basis_output_qty > 0
    );

COMMENT ON COLUMN goods_bom_items.control_stage IS
    'Material stage: START, ASSEMBLY, FINISH, or warning-only SHIP/REFERENCE.';
COMMENT ON COLUMN goods_bom_items.consumption_basis IS
    'Consumption rule: PER_UNIT, PER_PACKAGE, or FIXED_BATCH.';
COMMENT ON COLUMN goods_bom_items.basis_output_qty IS
    'Output quantity represented by one BOM consumption basis.';
COMMENT ON COLUMN goods_bom_items.allow_partial_package IS
    'Whether a non-full final package is allowed for PER_PACKAGE consumption.';
COMMENT ON COLUMN goods_bom_items.hard_gate IS
    'True only for START, ASSEMBLY, or FINISH production gates. SHIP and REFERENCE are warning-only.';

ALTER TABLE production_material_analysis_materials
    ADD COLUMN control_stage TEXT NOT NULL DEFAULT 'START',
    ADD COLUMN consumption_basis TEXT NOT NULL DEFAULT 'PER_UNIT',
    ADD COLUMN basis_output_qty NUMERIC(18,6) NOT NULL DEFAULT 1,
    ADD COLUMN allow_partial_package BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN hard_gate BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN calculation_mode TEXT NOT NULL
        DEFAULT 'LEGACY_CUMULATIVE_PER_UNIT',
    ADD COLUMN bom_qty NUMERIC(18,6),
    ADD COLUMN parent_per_product_qty NUMERIC(18,6) NOT NULL DEFAULT 1,
    ADD COLUMN allocated_start_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN allocated_finish_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN allocated_ship_qty NUMERIC(18,4) NOT NULL DEFAULT 0;

-- Historical analysis rows froze only cumulative per-product usage. Never
-- infer an edge from today's mutable BOM row: an edited BOM must not rewrite
-- an already-created analysis. New/refreshed rows explicitly use EDGE_RULE.
UPDATE production_material_analysis_materials
SET bom_qty = per_product_qty,
    parent_per_product_qty = 1,
    allocated_start_qty = allocated_available_qty,
    allocated_finish_qty = allocated_available_qty,
    allocated_ship_qty = allocated_available_qty;

ALTER TABLE production_material_analysis_materials
    ALTER COLUMN bom_qty SET DEFAULT 1,
    ALTER COLUMN bom_qty SET NOT NULL,
    ADD CONSTRAINT production_material_analysis_material_control_stage_chk CHECK (
        control_stage IN ('START', 'ASSEMBLY', 'FINISH', 'SHIP', 'REFERENCE')
    ),
    ADD CONSTRAINT pma_material_hard_gate_stage_chk CHECK (
        NOT hard_gate OR control_stage IN ('START', 'ASSEMBLY', 'FINISH')
    ),
    ADD CONSTRAINT production_material_analysis_material_consumption_basis_chk CHECK (
        consumption_basis IN ('PER_UNIT', 'PER_PACKAGE', 'FIXED_BATCH')
    ),
    ADD CONSTRAINT production_material_analysis_material_calculation_mode_chk CHECK (
        calculation_mode IN ('LEGACY_CUMULATIVE_PER_UNIT', 'EDGE_RULE')
    ),
    ADD CONSTRAINT production_material_analysis_material_basis_output_qty_chk CHECK (
        basis_output_qty > 0
    ),
    ADD CONSTRAINT production_material_analysis_material_bom_qty_chk CHECK (
        bom_qty > 0
    ),
    ADD CONSTRAINT pma_material_parent_per_product_qty_chk CHECK (
        parent_per_product_qty > 0
    ),
    ADD CONSTRAINT pma_material_tree_shape_chk CHECK (
        (depth = 1 AND parent_node_key IS NULL)
        OR (depth > 1 AND parent_node_key IS NOT NULL)
    );

CREATE INDEX idx_pma_material_active_tree
    ON production_material_analysis_materials(
        analysis_item_id, parent_node_key, depth
    )
    WHERE active = TRUE;

-- One immutable edge calculator is shared by the plan-link trigger and the
-- service's submitted-draft commitment projection. It deliberately mirrors
-- MaterialConsumptionMath and rounds every edge upward to four decimals.
CREATE OR REPLACE FUNCTION fn_material_analysis_edge_required(
    p_parent_output_qty NUMERIC,
    p_bom_qty NUMERIC,
    p_consumption_basis TEXT,
    p_basis_output_qty NUMERIC,
    p_allow_partial_package BOOLEAN
)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
    SELECT CASE
        WHEN p_parent_output_qty <= 0 THEN 0::NUMERIC
        ELSE CEIL((CASE
            WHEN p_consumption_basis = 'PER_UNIT'
                THEN p_parent_output_qty * p_bom_qty
            WHEN p_consumption_basis = 'PER_PACKAGE'
                 AND p_allow_partial_package
                THEN p_parent_output_qty * p_bom_qty / p_basis_output_qty
            WHEN p_consumption_basis IN ('PER_PACKAGE', 'FIXED_BATCH')
                THEN CEIL(p_parent_output_qty / p_basis_output_qty) * p_bom_qty
            ELSE NULL
        END) * 10000) / 10000
    END
$$;

-- Repair any stale V234 release/reversal snapshot using only the immutable
-- historical cumulative quantity. This is deliberately independent of the
-- current goods_bom_items row.
WITH legacy_requirements AS (
    SELECT material.id,
           fn_material_analysis_edge_required(
               GREATEST(
                   source.requested_qty
                       - source.submitted_qty - source.approved_qty,
                   0),
               material.per_product_qty,
               'PER_UNIT', 1, TRUE) AS required_qty
    FROM production_material_analysis_materials material
    JOIN production_material_analysis_items source
      ON source.id = material.analysis_item_id
     AND source.analysis_id = material.analysis_id
    WHERE material.active = TRUE
      AND material.calculation_mode = 'LEGACY_CUMULATIVE_PER_UNIT'
)
UPDATE production_material_analysis_materials material
SET required_qty = legacy.required_qty,
    allocated_available_qty = LEAST(
        material.allocated_available_qty, legacy.required_qty),
    allocated_start_qty = LEAST(
        material.allocated_start_qty, legacy.required_qty),
    allocated_finish_qty = LEAST(
        material.allocated_finish_qty, legacy.required_qty),
    allocated_ship_qty = LEAST(
        material.allocated_ship_qty, legacy.required_qty),
    shortage_qty = GREATEST(
        legacy.required_qty
            - LEAST(material.allocated_available_qty, legacy.required_qty),
        0),
    updated_at = now()
FROM legacy_requirements legacy
WHERE material.id = legacy.id;

ALTER TABLE production_material_analysis_materials
    ADD CONSTRAINT pma_material_stage_allocation_qty_chk CHECK (
        allocated_start_qty >= 0
        AND allocated_start_qty <= required_qty
        AND allocated_finish_qty >= 0
        AND allocated_finish_qty <= required_qty
        AND allocated_ship_qty >= 0
        AND allocated_ship_qty <= required_qty
    ),
    ALTER COLUMN calculation_mode SET DEFAULT 'EDGE_RULE';

-- Rebased snapshots invalidate every previously issued combined preview.
UPDATE production_material_analyses analysis
SET version = version + 1,
    fingerprint = encode(digest(
        fingerprint || '|V247-LEGACY-REBASE|' || version::text,
        'sha256'), 'hex'),
    preview_fingerprint = NULL,
    updated_at = now()
WHERE EXISTS (
    SELECT 1
    FROM production_material_analysis_materials material
    WHERE material.analysis_id = analysis.id
      AND material.active = TRUE
      AND material.calculation_mode = 'LEGACY_CUMULATIVE_PER_UNIT'
);

ALTER TABLE production_material_analysis_items
    ADD COLUMN ready_start_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN ready_finish_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN ready_ship_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD CONSTRAINT production_material_analysis_item_stage_ready_qty_chk CHECK (
        ready_start_qty >= 0
        AND ready_start_qty <= requested_qty - submitted_qty - approved_qty
        AND ready_finish_qty >= 0
        AND ready_finish_qty <= requested_qty - submitted_qty - approved_qty
        AND ready_ship_qty >= 0
        AND ready_ship_qty <= requested_qty - submitted_qty - approved_qty
        AND ready_ship_qty <= ready_finish_qty
        AND ready_finish_qty <= ready_start_qty
    );

-- Preserve the readiness already shown by historical analyses. The stage
-- values may diverge after the new calculation logic is adopted, but all
-- three begin from the existing conservative ready-now result.
UPDATE production_material_analysis_items
SET ready_start_qty = ready_now_qty,
    ready_finish_qty = ready_now_qty,
    ready_ship_qty = ready_now_qty;

ALTER TABLE production_material_analysis_items
    ADD CONSTRAINT pma_item_ready_now_is_finish_chk CHECK (
        ready_now_qty = ready_finish_qty
    );

COMMENT ON COLUMN production_material_analysis_items.ready_start_qty IS
    'Analytical start-capacity reference supported by hard START gates; not a formal plan limit.';
COMMENT ON COLUMN production_material_analysis_items.ready_finish_qty IS
    'Conservative complete-kit quantity used as the formal plan limit.';
COMMENT ON COLUMN production_material_analysis_items.ready_ship_qty IS
    'Reference shipment forecast bounded by ready_finish_qty; not a stock reservation or formal shipment gate.';

-- V234's plan-link trigger updates the claimed quantities and readiness in one
-- statement. Recreate it here so every readiness projection is clamped against
-- the same precomputed post-link values; referring to columns again inside the
-- SET list would still read the old row in PostgreSQL and is easy to get wrong.
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
        - v_item.submitted_qty - v_item.approved_qty;
    v_next_submitted := v_item.submitted_qty
        - v_old_submitted + v_new_submitted;
    v_next_approved := v_item.approved_qty
        - v_old_approved + v_new_approved;
    v_item_remaining := v_item.requested_qty
        - v_next_submitted - v_next_approved;

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

    -- Recalculate direct demand from the exact remaining output. Nested diagnostic
    -- demand consumes the exact parent shortage after its retained allocation;
    -- whole packages and fixed batches are never approximated by root averages.
    IF v_old_claim IS DISTINCT FROM v_new_claim THEN
        WITH RECURSIVE exact_requirements AS (
            SELECT material.node_key,
                   material.depth,
                   COALESCE(material.confirmed_route,
                       material.source_suggestion) AS effective_route,
                   material.control_stage,
                   requirement.old_required,
                   requirement.new_required,
                   requirement.claim_required,
                   allocation.new_physical_allocated,
                   GREATEST(requirement.new_required
                       - allocation.new_physical_allocated, 0) AS new_shortage
            FROM production_material_analysis_materials material
            CROSS JOIN LATERAL (
                SELECT CASE
                           WHEN material.calculation_mode
                                = 'LEGACY_CUMULATIVE_PER_UNIT'
                               THEN fn_material_analysis_edge_required(
                                   v_old_remaining, material.per_product_qty,
                                   'PER_UNIT', 1, TRUE)
                           ELSE fn_material_analysis_edge_required(
                               v_old_remaining * material.parent_per_product_qty,
                               material.bom_qty, material.consumption_basis,
                               material.basis_output_qty,
                               material.allow_partial_package)
                       END AS old_required,
                       CASE
                           WHEN material.calculation_mode
                                = 'LEGACY_CUMULATIVE_PER_UNIT'
                               THEN fn_material_analysis_edge_required(
                                   v_item_remaining, material.per_product_qty,
                                   'PER_UNIT', 1, TRUE)
                           ELSE fn_material_analysis_edge_required(
                               v_item_remaining * material.parent_per_product_qty,
                               material.bom_qty, material.consumption_basis,
                               material.basis_output_qty,
                               material.allow_partial_package)
                       END AS new_required,
                       CASE
                           WHEN material.calculation_mode
                                = 'LEGACY_CUMULATIVE_PER_UNIT'
                               THEN fn_material_analysis_edge_required(
                                   GREATEST(v_new_claim - v_old_claim, 0),
                                   material.per_product_qty,
                                   'PER_UNIT', 1, TRUE)
                           ELSE fn_material_analysis_edge_required(
                               GREATEST(v_new_claim - v_old_claim, 0)
                                   * material.parent_per_product_qty,
                               material.bom_qty, material.consumption_basis,
                               material.basis_output_qty,
                               material.allow_partial_package)
                       END AS claim_required
            ) requirement
            CROSS JOIN LATERAL (
                SELECT CASE
                           WHEN v_new_claim < v_old_claim THEN 0::NUMERIC
                           WHEN material.depth = 1 THEN LEAST(
                               GREATEST(material.allocated_available_qty
                                   - requirement.claim_required, 0),
                               requirement.new_required)
                           ELSE LEAST(material.allocated_available_qty,
                               requirement.new_required)
                       END AS new_physical_allocated
            ) allocation
            WHERE material.analysis_id = NEW.analysis_id
              AND material.analysis_item_id = NEW.analysis_item_id
              AND material.active = TRUE
              AND (
                  material.calculation_mode = 'LEGACY_CUMULATIVE_PER_UNIT'
                  OR material.depth = 1
              )

            UNION ALL

            SELECT child.node_key,
                   child.depth,
                   COALESCE(child.confirmed_route,
                       child.source_suggestion) AS effective_route,
                   child.control_stage,
                   requirement.old_required,
                   requirement.new_required,
                   requirement.claim_required,
                   allocation.new_physical_allocated,
                   GREATEST(requirement.new_required
                       - allocation.new_physical_allocated, 0) AS new_shortage
            FROM exact_requirements parent
            JOIN production_material_analysis_materials child
              ON child.analysis_id = NEW.analysis_id
             AND child.analysis_item_id = NEW.analysis_item_id
             AND child.active = TRUE
             AND child.calculation_mode = 'EDGE_RULE'
             AND child.parent_node_key = parent.node_key
             AND child.depth = parent.depth + 1
            CROSS JOIN LATERAL (
                SELECT CASE WHEN parent.effective_route = 'MAKE'
                                  AND parent.control_stage <> 'REFERENCE'
                           THEN fn_material_analysis_edge_required(
                               parent.old_required,
                               child.bom_qty, child.consumption_basis,
                               child.basis_output_qty,
                               child.allow_partial_package)
                           ELSE 0::NUMERIC END AS old_required,
                       CASE WHEN parent.effective_route = 'MAKE'
                                  AND parent.control_stage <> 'REFERENCE'
                           THEN fn_material_analysis_edge_required(
                               parent.new_shortage,
                               child.bom_qty, child.consumption_basis,
                               child.basis_output_qty,
                               child.allow_partial_package)
                           ELSE 0::NUMERIC END AS new_required,
                       CASE WHEN parent.effective_route = 'MAKE'
                                  AND parent.control_stage <> 'REFERENCE'
                           THEN fn_material_analysis_edge_required(
                               parent.claim_required,
                               child.bom_qty, child.consumption_basis,
                               child.basis_output_qty,
                               child.allow_partial_package)
                           ELSE 0::NUMERIC END AS claim_required
            ) requirement
            CROSS JOIN LATERAL (
                SELECT CASE
                           WHEN v_new_claim < v_old_claim THEN 0::NUMERIC
                           ELSE LEAST(child.allocated_available_qty,
                               requirement.new_required)
                       END AS new_physical_allocated
            ) allocation
        ), adjusted AS (
            SELECT requirement.node_key,
                   requirement.new_required,
                   requirement.new_physical_allocated,
                   CASE
                        WHEN v_new_claim < v_old_claim THEN 0::NUMERIC
                        WHEN material.depth = 1 THEN LEAST(
                            GREATEST(material.allocated_start_qty
                                - requirement.claim_required, 0),
                            requirement.new_required)
                       ELSE LEAST(
                           material.allocated_start_qty,
                           requirement.new_required)
                   END AS new_start_allocated,
                   CASE
                        WHEN v_new_claim < v_old_claim THEN 0::NUMERIC
                        WHEN material.depth = 1 THEN LEAST(
                            GREATEST(material.allocated_finish_qty
                                - requirement.claim_required, 0),
                            requirement.new_required)
                       ELSE LEAST(
                           material.allocated_finish_qty,
                           requirement.new_required)
                   END AS new_finish_allocated,
                   CASE
                        WHEN v_new_claim < v_old_claim THEN 0::NUMERIC
                        WHEN material.depth = 1 THEN LEAST(
                            GREATEST(material.allocated_ship_qty
                                - requirement.claim_required, 0),
                            requirement.new_required)
                       ELSE LEAST(
                           material.allocated_ship_qty,
                           requirement.new_required)
                   END AS new_ship_allocated
            FROM exact_requirements requirement
            JOIN production_material_analysis_materials material
              ON material.analysis_id = NEW.analysis_id
             AND material.analysis_item_id = NEW.analysis_item_id
             AND material.node_key = requirement.node_key
             AND material.active = TRUE
        )
        UPDATE production_material_analysis_materials material
        SET required_qty = adjusted.new_required,
            allocated_available_qty = adjusted.new_physical_allocated,
            allocated_start_qty = adjusted.new_start_allocated,
            allocated_finish_qty = adjusted.new_finish_allocated,
            allocated_ship_qty = adjusted.new_ship_allocated,
            shortage_qty = GREATEST(
                adjusted.new_required - adjusted.new_physical_allocated, 0),
            updated_at = now()
        FROM adjusted
        WHERE material.analysis_id = NEW.analysis_id
          AND material.analysis_item_id = NEW.analysis_item_id
          AND material.node_key = adjusted.node_key
          AND material.active = TRUE;

        GET DIAGNOSTICS v_updated_nodes = ROW_COUNT;
        SELECT COUNT(*) INTO v_active_nodes
        FROM production_material_analysis_materials material
        WHERE material.analysis_id = NEW.analysis_id
          AND material.analysis_item_id = NEW.analysis_item_id
          AND material.active = TRUE;
        IF v_updated_nodes <> v_active_nodes THEN
            RAISE EXCEPTION 'material analysis snapshot tree is incomplete'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    SELECT COALESCE(SUM(requested_qty - submitted_qty - approved_qty),0),
           COALESCE(SUM(submitted_qty + approved_qty),0)
    INTO v_remaining, v_used
    FROM production_material_analysis_items
    WHERE analysis_id = NEW.analysis_id AND is_deleted = FALSE;

    UPDATE production_material_analyses
    SET status = CASE
            WHEN v_remaining = 0 THEN 'COMPLETED'
            WHEN v_used > 0 THEN 'PARTIALLY_PLANNED'
            ELSE 'ACTIVE'
        END,
        version = version + 1,
        fingerprint = encode(digest(
            fingerprint || '|PLAN-LINK|' || NEW.id::text || '|'
                || NEW.allocation_status || '|' || version::text,
            'sha256'), 'hex'),
        preview_fingerprint = NULL,
        updated_at = now()
    WHERE id = NEW.analysis_id
      AND status <> 'CANCELLED';

    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

COMMENT ON COLUMN production_material_analysis_materials.control_stage IS
    'Immutable BOM control-stage snapshot used by this analysis node.';
COMMENT ON COLUMN production_material_analysis_materials.consumption_basis IS
    'Immutable BOM consumption-basis snapshot used by this analysis node.';
COMMENT ON COLUMN production_material_analysis_materials.basis_output_qty IS
    'Immutable output-basis quantity snapshot used by this analysis node.';
COMMENT ON COLUMN production_material_analysis_materials.allow_partial_package IS
    'Immutable partial-package policy snapshot used by this analysis node.';
COMMENT ON COLUMN production_material_analysis_materials.hard_gate IS
    'Immutable production hard-gate snapshot; SHIP and REFERENCE snapshots are warning-only.';
COMMENT ON COLUMN production_material_analysis_materials.calculation_mode IS
    'LEGACY_CUMULATIVE_PER_UNIT preserves old frozen cumulative usage; EDGE_RULE uses exact edge snapshots.';
COMMENT ON COLUMN production_material_analysis_materials.bom_qty IS
    'Raw quantity on this BOM edge; ignored by legacy cumulative snapshots.';
COMMENT ON COLUMN production_material_analysis_materials.parent_per_product_qty IS
    'Cumulative parent output quantity per root product for this BOM edge.';
COMMENT ON COLUMN production_material_analysis_materials.allocated_start_qty IS
    'Auditable direct-node allocation supporting ready_start_qty.';
COMMENT ON COLUMN production_material_analysis_materials.allocated_finish_qty IS
    'Auditable direct-node allocation supporting ready_finish_qty.';
COMMENT ON COLUMN production_material_analysis_materials.allocated_ship_qty IS
    'Auditable direct-node allocation supporting ready_ship_qty.';
