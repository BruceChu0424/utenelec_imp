-- Versioned intent is independent of quantities/prices and defaults old orders to assembled.
ALTER TABLE sales_order_items ADD COLUMN delivery_plan jsonb NOT NULL DEFAULT
    '{"version":1,"mode":"ASSEMBLED","packaging":"ORIGINAL","nodeModes":[],"processes":[]}'::jsonb;
ALTER TABLE sales_order_items ADD COLUMN delivery_bom_snapshot jsonb;
ALTER TABLE sales_order_items ADD CONSTRAINT sales_order_delivery_plan_shape CHECK (
    jsonb_typeof(delivery_plan)='object' AND delivery_plan->>'version'='1'
    AND delivery_plan->>'mode' IN ('ASSEMBLED','BOM')
    AND delivery_plan->>'packaging' IN ('ORIGINAL','BULK','PENDING')
    AND jsonb_typeof(delivery_plan->'nodeModes')='array'
    AND jsonb_typeof(delivery_plan->'processes')='array');

-- The former hard_gate expresses production readiness, never mandatory assembly.
CREATE TABLE goods_bom_delivery_rules (
    bom_edge_id uuid PRIMARY KEY REFERENCES goods_bom_items(id),
    mandatory_assembly boolean NOT NULL DEFAULT false,
    material_role text NOT NULL DEFAULT 'UNCLASSIFIED'
        CHECK (material_role IN ('PART','ACCESSORY','PRODUCT_PACKAGING','UNCLASSIFIED')),
    required_operations jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(required_operations)='array'),
    updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON COLUMN sales_order_items.delivery_bom_snapshot IS 'Server-owned BOM snapshot: UUID edge paths, design quantities, units, constraints; no prices or inventory';
COMMENT ON COLUMN goods_bom_delivery_rules.material_role IS 'Explicit classification only; no name-based inference. Accessories never removed by bulk packaging';
SELECT fn_audit_track_table('goods_bom_delivery_rules','FULL','data_change',false,NULL,true,NULL);

-- A direct SQL update must not evade the same reviewed-line lifecycle as the sales service.
CREATE FUNCTION fn_guard_sales_delivery_plan_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.delivery_plan IS DISTINCT FROM OLD.delivery_plan OR NEW.delivery_bom_snapshot IS DISTINCT FROM OLD.delivery_bom_snapshot
  OR ((OLD.delivery_plan->>'mode'='BOM' OR NEW.delivery_plan->>'mode'='BOM'
      OR jsonb_array_length(COALESCE(OLD.delivery_plan->'processes','[]'::jsonb))>0
      OR jsonb_array_length(COALESCE(NEW.delivery_plan->'processes','[]'::jsonb))>0)
    AND (NEW.goods_id,NEW.color_id,NEW.unit_id,NEW.unit_rate) IS DISTINCT FROM (OLD.goods_id,OLD.color_id,OLD.unit_id,OLD.unit_rate)) THEN
  IF COALESCE(OLD.shipped_qty,0)<>0 OR COALESCE(OLD.returned_qty,0)<>0
     OR COALESCE(OLD.planned_qty,0)<>0 OR COALESCE(OLD.produced_qty,0)<>0
     OR EXISTS(SELECT 1 FROM production_material_analysis_items ai JOIN production_material_analyses a ON a.id=ai.analysis_id
         WHERE ai.sales_order_item_id=OLD.id AND NOT ai.is_deleted AND NOT a.is_deleted AND a.status<>'CANCELLED')
     OR EXISTS(SELECT 1 FROM plan_order_item_links l WHERE l.order_item_id=OLD.id AND NOT l.is_deleted)
     OR EXISTS(SELECT 1 FROM sales_shipment_items si JOIN sales_shipments s ON s.id=si.shipment_id
         WHERE si.order_item_id=OLD.id AND NOT si.is_deleted AND NOT s.is_deleted AND s.status<>-1) THEN
   RAISE EXCEPTION '订单行已有下游事实，不能直接更换交付方案' USING ERRCODE='23514';
  END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sales_delivery_plan_change_guard BEFORE UPDATE OF delivery_plan,delivery_bom_snapshot,goods_id,color_id,unit_id,unit_rate ON sales_order_items
 FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_delivery_plan_change();
