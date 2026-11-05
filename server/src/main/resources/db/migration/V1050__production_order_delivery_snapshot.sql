-- Delivery decisions are versioned order facts, separate from production consumption quantities.
ALTER TABLE production_material_analysis_items
    ADD COLUMN delivery_plan_snapshot jsonb,
    ADD COLUMN delivery_plan_fingerprint text;

ALTER TABLE production_material_analysis_materials
    ADD COLUMN delivery_context boolean NOT NULL DEFAULT false,
    ADD COLUMN delivery_frontier boolean NOT NULL DEFAULT false,
    ADD COLUMN delivery_operations text NOT NULL DEFAULT '[]';

ALTER TABLE production_material_analysis_materials
    ADD CONSTRAINT ck_analysis_delivery_operations_array CHECK (jsonb_typeof(delivery_operations::jsonb)='array'),
    ADD CONSTRAINT ck_analysis_delivery_context_not_frontier CHECK (NOT(delivery_context AND delivery_frontier));

COMMENT ON COLUMN production_material_analysis_materials.delivery_context IS
    'Order-specific skipped assembly context; never allocates stock or creates a supply task';
