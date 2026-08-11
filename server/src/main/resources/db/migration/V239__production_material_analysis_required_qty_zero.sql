-- V239: relax production_material_analysis_materials.required_qty to allow 0.
--
-- V234 (already applied to every target database) created this CHECK with
-- required_qty > 0. The plan-link conservation trigger
-- (fn_sync_material_analysis_plan_link_qty) subtracts each claimed batch from
-- required_qty; when the FULL remaining demand is planned in one batch,
-- required_qty legitimately reaches 0. The strict > 0 then rejects that
-- terminal state and crashes full-batch generate-plan.
--
-- Because V234 is already applied, the fix is additive here: drop + re-add the
-- constraint with required_qty >= 0. Every existing row satisfies >= 0 (the
-- prior > 0 was strictly tighter), so the re-add cannot fail on存量数据.

ALTER TABLE production_material_analysis_materials
    DROP CONSTRAINT IF EXISTS production_material_analysis_material_qty_chk;

ALTER TABLE production_material_analysis_materials
    ADD CONSTRAINT production_material_analysis_material_qty_chk CHECK (
        per_product_qty > 0 AND required_qty >= 0
        AND available_qty >= 0 AND reserved_qty >= 0
        AND allocated_available_qty >= 0
        AND allocated_available_qty <= required_qty
        AND safety_stock_qty >= 0 AND inbound_qty >= 0
        AND shortage_qty >= 0
    );
