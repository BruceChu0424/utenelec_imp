-- Normal material loss is an addition to the materials supplied, never a
-- reduction of the ordered finished quantity. Existing frozen plans keep their
-- exact historical basis, including partially issued/received plans.
-- Reuse the existing dependency-preserving numeric migration mechanism. Only
-- its structural work is needed here; quantity checks below replace its
-- financial validation checks. Base(6) x percent(2)/100 needs up to 10 places.
SELECT fn_migrate_financial_amount_columns('[
  {"table":"subcontract_material_plan_items","column":"bom_unit_qty"},
  {"table":"subcontract_material_issue_items","column":"frozen_unit_qty"}
]'::jsonb);
DO $$
DECLARE target RECORD;
BEGIN
    FOR target IN SELECT * FROM (VALUES
        ('subcontract_material_plan_items','bom_unit_qty'),
        ('subcontract_material_issue_items','frozen_unit_qty')) AS columns(table_name,column_name)
    LOOP
        EXECUTE format('ALTER TABLE %I DROP CONSTRAINT %I', target.table_name,
            'ck_financial_exact_' || substr(md5('public.' || target.table_name || '.' || target.column_name),1,24));
    END LOOP;
END;
$$;

ALTER TABLE subcontract_material_plan_items
    ADD COLUMN base_bom_unit_qty NUMERIC(18,6),
    ADD COLUMN material_loss_pct NUMERIC(5,2) NOT NULL DEFAULT 0;

UPDATE subcontract_material_plan_items SET base_bom_unit_qty = bom_unit_qty;
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
ALTER TABLE subcontract_material_plan_items
    ALTER COLUMN base_bom_unit_qty SET NOT NULL,
    ADD CONSTRAINT subcontract_material_plan_loss_snapshot_chk
        CHECK (base_bom_unit_qty > 0 AND material_loss_pct BETWEEN 0 AND 100
               AND bom_unit_qty = ROUND(base_bom_unit_qty * (1 + material_loss_pct / 100), 10));
ALTER TABLE subcontract_material_issue_items
    ADD CONSTRAINT subcontract_material_issue_frozen_usage_precision_chk CHECK (
        frozen_unit_qty IS NULL OR (abs(frozen_unit_qty) < 10000000000000
            AND scale(trim_scale(frozen_unit_qty)) <= 10));

CREATE FUNCTION fn_subcontract_supply_unit_qty(p_base NUMERIC, p_loss_pct NUMERIC)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
    SELECT ROUND(p_base * (1 + COALESCE(p_loss_pct, 0) / 100), 10)
$$;
COMMENT ON FUNCTION fn_subcontract_supply_unit_qty(NUMERIC, NUMERIC) IS
    'Material supply allowance: base(6 places) x (1 + loss percent(2 places) / 100), retained to 10 places without loss. Finished target remains unchanged; normal loss is included in the frozen receipt consumption estimate.';
COMMENT ON COLUMN subcontract_material_plan_items.base_bom_unit_qty IS
    'Original direct BOM quantity per order unit at approval, before normal material loss; historical plans retain their original bom_unit_qty.';
COMMENT ON COLUMN subcontract_material_plan_items.material_loss_pct IS
    'Normal supply loss percent frozen at approval. Existing plans are 0 and are never retroactively increased.';
COMMENT ON COLUMN subcontract_material_plan_items.bom_unit_qty IS
    'Frozen supply and receipt consumption estimate per finished order unit, including normal material loss. planned_qty=CEIL4(order qty x bom_unit_qty).';

-- Keep the original edge validation and bind both snapshots to the approved
-- order. The legacy insert shape (no snapshots) remains valid for zero-loss
-- callers; nonzero loss must be explicitly frozen by the command service.
CREATE OR REPLACE FUNCTION fn_guard_subcontract_target_quantity_basis_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.base_bom_unit_qty IS NULL THEN
        NEW.base_bom_unit_qty := NEW.bom_unit_qty;
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM subcontract_order_items order_item
        CROSS JOIN LATERAL fn_subcontract_draw_edges(order_item.goods_id) edge
        JOIN goods component ON component.id = edge.component_goods_id
        WHERE order_item.id = NEW.order_item_id AND NOT order_item.is_deleted
          AND NEW.parent_goods_id = order_item.goods_id
          AND NEW.parent_color_id IS NOT DISTINCT FROM order_item.color_id
          AND NEW.goods_id = edge.component_goods_id
          AND NEW.color_id IS NOT DISTINCT FROM edge.color_id
          AND NEW.unit_id IS NOT DISTINCT FROM component.unit_id
          AND NEW.unit_rate = 1
          AND NEW.base_bom_unit_qty = ROUND(COALESCE(order_item.unit_rate, 1) * edge.edge_qty, 6)
          AND NEW.material_loss_pct = COALESCE(order_item.allowed_loss_pct, 0)
          AND NEW.bom_unit_qty = fn_subcontract_supply_unit_qty(NEW.base_bom_unit_qty, NEW.material_loss_pct)
          AND NEW.planned_qty = fn_subcontract_draw_f(order_item.qty, NEW.bom_unit_qty)
          AND NEW.issued_qty = 0
          AND NEW.draw_closed_at IS NULL
    ) THEN
        RAISE EXCEPTION 'subcontract draw plan must freeze the direct BOM edge and normal material loss allowance'
            USING ERRCODE = '23514', CONSTRAINT = 'subcontract_draw_plan_basis_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION fn_guard_subcontract_material_loss_snapshot_update()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.base_bom_unit_qty IS DISTINCT FROM OLD.base_bom_unit_qty
       OR NEW.material_loss_pct IS DISTINCT FROM OLD.material_loss_pct
       OR NEW.bom_unit_qty IS DISTINCT FROM OLD.bom_unit_qty THEN
        RAISE EXCEPTION 'subcontract material usage and normal loss snapshots are immutable after approval'
            USING ERRCODE = '23514', CONSTRAINT = 'subcontract_material_loss_snapshot_immutable';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_subcontract_material_loss_snapshot_update
BEFORE UPDATE OF base_bom_unit_qty, material_loss_pct, bom_unit_qty
ON subcontract_material_plan_items FOR EACH ROW
EXECUTE FUNCTION fn_guard_subcontract_material_loss_snapshot_update();
ALTER TABLE subcontract_material_plan_items
    ENABLE ALWAYS TRIGGER trg_subcontract_material_loss_snapshot_update;
