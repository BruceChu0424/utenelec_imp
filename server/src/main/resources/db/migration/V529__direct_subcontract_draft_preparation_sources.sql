-- Direct draft preparation is an additional commercial demand, distinct from
-- legacy SC-PREP tasks and their original-analysis entitlement handoff.
ALTER TABLE production_material_analysis_items
    ADD COLUMN subcontract_order_item_id UUID REFERENCES subcontract_order_items(id) DEFERRABLE INITIALLY DEFERRED,
    ADD COLUMN subcontract_order_qty_base NUMERIC(18,4);
ALTER TABLE production_material_analysis_items ADD CONSTRAINT direct_subcontract_preparation_identity CHECK(
    (subcontract_order_item_id IS NULL AND subcontract_order_qty_base IS NULL)
    OR (source_type='SUBCONTRACT_PREPARATION' AND source_ref='SC-ORDER:'||subcontract_order_item_id::text
        AND subcontract_order_qty_base>0 AND requested_qty>0 AND requested_qty<=subcontract_order_qty_base));
-- Direct drafts may replace cancelled, unplanned analyses without deleting their
-- history. Their live uniqueness is serialized by the original order row lock
-- and checked below; all older manual-source uniqueness remains unchanged.
DROP INDEX uq_production_material_analysis_manual_source_ref;
CREATE UNIQUE INDEX uq_production_material_analysis_manual_source_ref
    ON production_material_analysis_items(source_type,lower(btrim(source_ref)))
    WHERE is_deleted=FALSE AND source_type<>'SALES_ORDER_ITEM'
      AND NOT(source_type='SUBCONTRACT_PREPARATION' AND source_ref LIKE 'SC-ORDER:%');

CREATE FUNCTION fn_bind_direct_subcontract_preparation() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE original subcontract_order_items%ROWTYPE; header subcontract_orders%ROWTYPE; base_unit UUID;
BEGIN
    IF TG_OP='DELETE' THEN
        IF OLD.subcontract_order_item_id IS NOT NULL THEN
            RAISE EXCEPTION 'direct subcontract preparation history must be cancelled, not deleted' USING ERRCODE='23514';
        END IF;
        RETURN OLD;
    END IF;
    IF TG_OP='UPDATE' AND OLD.subcontract_order_item_id IS NOT NULL THEN
        IF NEW.subcontract_order_item_id IS DISTINCT FROM OLD.subcontract_order_item_id
            OR NEW.subcontract_order_qty_base IS DISTINCT FROM OLD.subcontract_order_qty_base
            OR NEW.source_ref IS DISTINCT FROM OLD.source_ref OR NEW.requested_qty IS DISTINCT FROM OLD.requested_qty THEN
            RAISE EXCEPTION 'direct subcontract preparation must retain its original order line and quantity snapshot' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.source_type<>'SUBCONTRACT_PREPARATION' OR NEW.source_ref NOT LIKE 'SC-ORDER:%' THEN RETURN NEW; END IF;
    IF TG_OP<>'INSERT' OR NEW.source_ref !~ '^SC-ORDER:[0-9a-fA-F-]{36}$' THEN
        RAISE EXCEPTION 'direct subcontract preparation needs a new explicit draft source' USING ERRCODE='23514';
    END IF;
    SELECT * INTO original FROM subcontract_order_items WHERE id=substring(NEW.source_ref FROM 10)::uuid;
    SELECT * INTO header FROM subcontract_orders WHERE id=original.order_id FOR UPDATE;
    SELECT unit_id INTO base_unit FROM goods WHERE id=original.goods_id;
    IF original.id IS NULL OR original.is_deleted OR original.application_item_id IS NOT NULL
        OR header.id IS NULL OR header.is_deleted OR header.status<>0
        OR EXISTS(SELECT 1 FROM subcontract_order_item_sources WHERE order_item_id=original.id)
        OR NEW.goods_id<>original.goods_id OR NEW.color_id IS DISTINCT FROM original.color_id OR NEW.unit_id IS DISTINCT FROM base_unit
        OR NEW.requested_qty<=0 OR NEW.requested_qty>round(original.qty*COALESCE(original.unit_rate,1),4) THEN
        RAISE EXCEPTION 'direct subcontract preparation must use the actual draft item in base units without inherited application supply' USING ERRCODE='23514';
    END IF;
    NEW.subcontract_order_item_id:=original.id;
    NEW.subcontract_order_qty_base:=round(original.qty*COALESCE(original.unit_rate,1),4);
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_bind_direct_subcontract_preparation BEFORE INSERT OR UPDATE OR DELETE ON production_material_analysis_items
    FOR EACH ROW EXECUTE FUNCTION fn_bind_direct_subcontract_preparation();
ALTER TABLE production_material_analysis_items ENABLE ALWAYS TRIGGER trg_bind_direct_subcontract_preparation;

CREATE FUNCTION fn_assert_direct_subcontract_preparation(p_item UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE source production_material_analysis_items%ROWTYPE; analysis production_material_analyses%ROWTYPE;
    original subcontract_order_items%ROWTYPE; header subcontract_orders%ROWTYPE;
BEGIN
    SELECT * INTO source FROM production_material_analysis_items WHERE id=p_item;
    IF source.subcontract_order_item_id IS NULL THEN RETURN; END IF;
    SELECT * INTO analysis FROM production_material_analyses WHERE id=source.analysis_id;
    SELECT * INTO original FROM subcontract_order_items WHERE id=source.subcontract_order_item_id;
    SELECT * INTO header FROM subcontract_orders WHERE id=original.order_id;
    IF original.id IS NULL OR header.id IS NULL OR source.goods_id<>original.goods_id OR source.color_id IS DISTINCT FROM original.color_id
        OR original.application_item_id IS NOT NULL OR EXISTS(SELECT 1 FROM subcontract_order_item_sources WHERE order_item_id=original.id)
        OR (analysis.status<>'CANCELLED' AND (original.is_deleted OR header.is_deleted
            OR analysis.warehouse_id IS DISTINCT FROM header.warehouse_id
            OR header.status=0 AND round(original.qty*COALESCE(original.unit_rate,1),4)<>source.subcontract_order_qty_base))
        OR (analysis.status<>'CANCELLED' AND EXISTS(SELECT 1 FROM production_material_analysis_items other
            JOIN production_material_analyses other_analysis ON other_analysis.id=other.analysis_id
            WHERE other.subcontract_order_item_id=original.id AND other.id<>source.id AND other.is_deleted=FALSE
                AND other_analysis.is_deleted=FALSE AND other_analysis.status<>'CANCELLED')) THEN
        RAISE EXCEPTION 'direct subcontract preparation source changed or is duplicated; cancel idle preparation before editing the original draft' USING ERRCODE='23514';
    END IF;
END;
$$;
ALTER FUNCTION fn_check_subcontract_preparation_analysis_source() RENAME TO fn_check_legacy_subcontract_preparation_analysis_source;
CREATE FUNCTION fn_check_subcontract_preparation_analysis_source() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE plan_item UUID;
BEGIN
    IF TG_OP<>'DELETE' AND NEW.subcontract_order_item_id IS NOT NULL THEN
        PERFORM fn_assert_direct_subcontract_preparation(NEW.id);RETURN NULL;
    END IF;
    -- Preserve the legacy task check; trigger functions cannot be called as ordinary functions.
    IF TG_OP<>'INSERT' THEN
        FOR plan_item IN SELECT id FROM subcontract_material_plan_items
            WHERE preparation_analysis_id=OLD.analysis_id AND preparation_analysis_item_id=OLD.id LOOP
            PERFORM fn_assert_subcontract_preparation_source(plan_item);
        END LOOP;
    END IF;
    IF TG_OP<>'DELETE' THEN
        FOR plan_item IN SELECT id FROM subcontract_material_plan_items
            WHERE preparation_analysis_id=NEW.analysis_id AND preparation_analysis_item_id=NEW.id LOOP
            PERFORM fn_assert_subcontract_preparation_source(plan_item);
        END LOOP;
        IF NEW.source_type='SUBCONTRACT_PREPARATION' AND NOT EXISTS(SELECT 1 FROM subcontract_material_plan_items item
            WHERE item.preparation_analysis_id=NEW.analysis_id AND item.preparation_analysis_item_id=NEW.id
                AND item.flow_mode='MAKE_THEN_OUTBOUND' AND item.is_deleted=FALSE AND NEW.source_ref='SC-PREP:'||item.order_item_id::text) THEN
            RAISE EXCEPTION 'SUBCONTRACT_PREPARATION analysis item lacks a real subcontract task' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;
DROP TRIGGER trg_subcontract_preparation_analysis_source_guard ON production_material_analysis_items;
CREATE CONSTRAINT TRIGGER trg_subcontract_preparation_analysis_source_guard AFTER INSERT OR UPDATE OR DELETE ON production_material_analysis_items
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_preparation_analysis_source();
ALTER TABLE production_material_analysis_items ENABLE ALWAYS TRIGGER trg_subcontract_preparation_analysis_source_guard;

CREATE FUNCTION fn_check_direct_subcontract_preparation_owner() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source UUID;
BEGIN
    IF TG_TABLE_NAME='subcontract_orders' THEN
        FOR source IN SELECT item.id FROM production_material_analysis_items item JOIN subcontract_order_items original ON original.id=item.subcontract_order_item_id WHERE original.order_id=NEW.id LOOP
            PERFORM fn_assert_direct_subcontract_preparation(source);
        END LOOP;
    ELSIF TG_TABLE_NAME='subcontract_order_items' THEN
        FOR source IN SELECT id FROM production_material_analysis_items WHERE subcontract_order_item_id=NEW.id LOOP
            PERFORM fn_assert_direct_subcontract_preparation(source);
        END LOOP;
    ELSE
        FOR source IN SELECT id FROM production_material_analysis_items WHERE analysis_id=NEW.id AND subcontract_order_item_id IS NOT NULL LOOP
            PERFORM fn_assert_direct_subcontract_preparation(source);
        END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_direct_subcontract_order_preparation AFTER UPDATE ON subcontract_orders DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_direct_subcontract_preparation_owner();
CREATE CONSTRAINT TRIGGER trg_direct_subcontract_item_preparation AFTER UPDATE ON subcontract_order_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_direct_subcontract_preparation_owner();
CREATE CONSTRAINT TRIGGER trg_direct_subcontract_analysis_preparation AFTER UPDATE ON production_material_analyses DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_direct_subcontract_preparation_owner();
ALTER TABLE subcontract_orders ENABLE ALWAYS TRIGGER trg_direct_subcontract_order_preparation;
ALTER TABLE subcontract_order_items ENABLE ALWAYS TRIGGER trg_direct_subcontract_item_preparation;
ALTER TABLE production_material_analyses ENABLE ALWAYS TRIGGER trg_direct_subcontract_analysis_preparation;

-- Qualified target stock can satisfy a BOM-bearing direct order. Keep its true
-- BOM snapshot; DIRECT_OUTBOUND describes the physical route, not BOM absence.
DO $stock_direct_snapshot$
DECLARE definition TEXT;
BEGIN
    SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint WHERE conrelid='subcontract_material_plan_items'::regclass
        AND conname='subcontract_material_plan_item_bom_snapshot_chk';
    IF position('bom_has_children_snapshot = false' IN definition)=0 THEN RAISE EXCEPTION 'subcontract BOM snapshot guard changed before V529'; END IF;
    ALTER TABLE subcontract_material_plan_items DROP CONSTRAINT subcontract_material_plan_item_bom_snapshot_chk;
    EXECUTE 'ALTER TABLE subcontract_material_plan_items ADD CONSTRAINT subcontract_material_plan_item_bom_snapshot_chk '
        ||replace(definition,'bom_has_children_snapshot = false','bom_has_children_snapshot IS NOT NULL');
END;
$stock_direct_snapshot$;
