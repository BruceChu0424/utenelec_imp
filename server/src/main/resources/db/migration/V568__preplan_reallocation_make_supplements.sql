-- Preserve the parent BOM and completed plans. Additional make responsibility
-- is explicitly attributed to an outgoing, still-unfulfilled stock reallocation.
CREATE TABLE preplan_reallocation_make_supplements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    reallocation_id UUID NOT NULL REFERENCES preplan_material_reallocations(id),
    source_analysis_material_id UUID NOT NULL REFERENCES production_material_analysis_materials(id),
    child_analysis_item_id UUID NOT NULL REFERENCES production_material_analysis_items(id),
    qty NUMERIC(18,4) NOT NULL CHECK(qty>0),
    before_requested_qty NUMERIC(18,4) NOT NULL CHECK(before_requested_qty>=0),
    after_requested_qty NUMERIC(18,4) NOT NULL,
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK(after_requested_qty>=before_requested_qty+qty),
    UNIQUE(child_analysis_item_id,before_requested_qty)
);
CREATE INDEX idx_preplan_make_supplement_reallocation ON preplan_reallocation_make_supplements(reallocation_id);
CREATE TRIGGER trg_audit_preplan_reallocation_make_supplements AFTER INSERT OR UPDATE OR DELETE
    ON preplan_reallocation_make_supplements FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE FUNCTION fn_guard_preplan_reallocation_make_supplement() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE relation preplan_material_reallocations%ROWTYPE;
    child production_material_analysis_items%ROWTYPE;
    material production_material_analysis_materials%ROWTYPE;
    committed NUMERIC;
BEGIN
    IF TG_OP<>'INSERT' THEN
        RAISE EXCEPTION 'Reallocation make supplement proof is append-only' USING ERRCODE='23514';
    END IF;
    SELECT * INTO relation FROM preplan_material_reallocations WHERE id=NEW.reallocation_id FOR UPDATE;
    SELECT * INTO child FROM production_material_analysis_items WHERE id=NEW.child_analysis_item_id;
    SELECT * INTO material FROM production_material_analysis_materials WHERE id=NEW.source_analysis_material_id;
    SELECT COALESCE(SUM(qty),0) INTO committed FROM preplan_reallocation_make_supplements WHERE reallocation_id=NEW.reallocation_id;
    IF relation.id IS NULL OR relation.status NOT IN ('OPEN','PARTIAL')
       OR relation.from_analysis_material_id<>NEW.source_analysis_material_id
       OR material.analysis_id<>relation.from_analysis_id OR NOT material.active
       OR child.id IS NULL OR child.is_deleted OR child.analysis_id<>relation.from_analysis_id
       OR child.parent_analysis_material_id<>material.id
       OR child.source_type NOT IN ('MAKE_COMPONENT','SUBCONTRACT_MAKE')
       OR child.goods_id<>material.goods_id OR child.color_id IS DISTINCT FROM material.color_id
       OR child.unit_id<>material.unit_id OR child.requested_qty<>NEW.after_requested_qty
       OR NEW.qty>relation.qty-relation.priority_fulfilled_qty OR committed+NEW.qty>relation.qty THEN
        RAISE EXCEPTION 'Make supplement must match the exact outstanding reallocation and child demand increase' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_preplan_reallocation_make_supplement BEFORE INSERT OR UPDATE OR DELETE
    ON preplan_reallocation_make_supplements FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_reallocation_make_supplement();
ALTER TABLE preplan_reallocation_make_supplements ENABLE ALWAYS TRIGGER trg_guard_preplan_reallocation_make_supplement;
ALTER TABLE preplan_reallocation_make_supplements ENABLE ALWAYS TRIGGER trg_audit_preplan_reallocation_make_supplements;
DO $reset_policy$
DECLARE definition TEXT;needle TEXT:='(''preplan_material_reallocations'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V568 business reset contract changed';
    END IF;
    EXECUTE replace(definition,needle,needle||E',\n    (''preplan_reallocation_make_supplements'', ''CLEAR'')');
END;
$reset_policy$;
COMMENT ON TABLE preplan_reallocation_make_supplements IS
    'Explicit additional existing-child make responsibility for stock yielded to another plan; parent BOM and completed history unchanged';

-- One admitted-output budget serves both the command and deferred exact-source
-- guard. Recorded supplements can replenish stock previously yielded to another
-- analysis; they do not change the parent BOM or waive per-receipt physical caps.
CREATE FUNCTION fn_preplan_direct_make_admitted_qty(p_child UUID,p_material UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT LEAST(child.requested_qty,material.required_qty+COALESCE((
        SELECT SUM(supplement.qty) FROM preplan_reallocation_make_supplements supplement
        WHERE supplement.child_analysis_item_id=child.id
          AND supplement.source_analysis_material_id=material.id),0))
    FROM production_material_analysis_items child
    JOIN production_material_analysis_materials material ON material.id=child.parent_analysis_material_id
      AND material.analysis_id=child.analysis_id
    WHERE child.id=p_child AND material.id=p_material AND child.source_type='MAKE_COMPONENT'
      AND NOT child.is_deleted),0)::numeric;
$$;

DO $make_source_capacity$
DECLARE definition TEXT;
    needle TEXT:='IF attributed>LEAST(child.requested_qty,material.required_qty) THEN';
BEGIN
    SELECT pg_get_functiondef('fn_assert_preplan_direct_make_exact_peg(uuid)'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V568 direct MAKE origin capacity contract changed';
    END IF;
    EXECUTE replace(definition,needle,
        'IF attributed>fn_preplan_direct_make_admitted_qty(child.id,material.id) THEN');
END;
$make_source_capacity$;
