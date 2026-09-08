-- V498: a goods basic quantity unit is immutable after its first quantity use.
-- No quantities/rates/source UUIDs are rewritten. The lock is sticky even after
-- cancellation, soft deletion or business-data reset. Missing historical units
-- require an evidence-backed controlled repair; there is no application bypass.
ALTER TABLE goods ADD COLUMN quantity_unit_locked BOOLEAN NOT NULL DEFAULT FALSE;
COMMENT ON COLUMN goods.quantity_unit_locked IS
    'DB-owned sticky flag: quantity history/BOM fixes the basic unit; ordinary edits cannot unlock it';

-- Explicit quantity sources, not arbitrary references: images, remarks, location
-- and workshop preferences, and measurement preference decisions are excluded.
CREATE FUNCTION fn_goods_quantity_reference_sources()
RETURNS TABLE(relation_name TEXT, goods_columns TEXT[], row_predicate TEXT)
LANGUAGE sql IMMUTABLE AS $catalog$
VALUES
    ('goods_bom_items', ARRAY['component_goods_id','goods_id'], 'true'),
    ('inbound_expectation_items', ARRAY['goods_id'], 'true'),
    ('legacy_measurement_profile_snapshots', ARRAY['goods_id'], 'n.distinct_document_count > 0'),
    ('measurement_capture_evidence', ARRAY['goods_id'], 'true'),
    ('measurement_capture_line_snapshots', ARRAY['goods_id'], 'true'),
    ('preplan_material_reallocations', ARRAY['goods_id'], 'true'),
    ('preplan_public_supply_events', ARRAY['goods_id'], 'true'),
    ('preplan_root_output_events', ARRAY['goods_id'], 'true'),
    ('preplan_subcontract_make_tasks', ARRAY['goods_id'], 'true'),
    ('preplan_subcontract_requirement_handoff_items', ARRAY['goods_id'], 'true'),
    ('preplan_subcontract_requirement_handoffs', ARRAY['target_goods_id'], 'true'),
    ('preplan_supply_actions', ARRAY['goods_id'], 'true'),
    ('procurement_arrival_exceptions', ARRAY['goods_id'], 'true'),
    ('procurement_inspection_items', ARRAY['goods_id'], 'true'),
    ('procurement_iqc_rejection_cases', ARRAY['goods_id'], 'true'),
    ('procurement_iqc_stock_in_batch_items', ARRAY['goods_id'], 'true'),
    ('production_daily_report_items', ARRAY['goods_id'], 'true'),
    ('production_execution_segments', ARRAY['product_goods_id'], 'true'),
    ('production_fqc_inspections', ARRAY['goods_id'], 'true'),
    ('production_fqc_recovery_authorizations', ARRAY['goods_id'], 'true'),
    ('production_material_analysis_borrows', ARRAY['goods_id'], 'true'),
    ('production_material_analysis_items', ARRAY['goods_id'], 'true'),
    ('production_material_analysis_materials', ARRAY['goods_id'], 'true'),
    ('production_material_demands', ARRAY['goods_id'], 'true'),
    ('production_plan_costs', ARRAY['goods_id','master_goods_id'], 'true'),
    ('production_plan_items', ARRAY['goods_id','mgoods_id'], 'true'),
    ('purchase_order_items', ARRAY['goods_id'], 'true'),
    ('purchase_receipt_items', ARRAY['goods_id'], 'true'),
    ('purchase_request_items', ARRAY['goods_id'], 'true'),
    ('purchase_return_items', ARRAY['goods_id'], 'true'),
    ('sales_order_cost_items', ARRAY['alt_goods_id','goods_id'], 'true'),
    ('sales_order_items', ARRAY['goods_id'], 'true'),
    ('sales_other_shipment_items', ARRAY['goods_id'], 'true'),
    ('sales_quote_items', ARRAY['goods_id'], 'true'),
    ('sales_return_items', ARRAY['goods_id'], 'true'),
    ('sales_return_quality_items', ARRAY['goods_id'], 'true'),
    ('sales_shipment_items', ARRAY['goods_id'], 'true'),
    ('stock_balances', ARRAY['goods_id'], 'true'),
    ('stock_document_items', ARRAY['goods_id'], 'true'),
    ('stock_movements', ARRAY['goods_id'], 'true'),
    ('stock_reservations', ARRAY['goods_id'], 'true'),
    ('subcontract_application_items', ARRAY['goods_id'], 'true'),
    ('subcontract_inquiry_items', ARRAY['goods_id'], 'true'),
    ('subcontract_loss_case_lines', ARRAY['goods_id'], 'true'),
    ('subcontract_material_issue_items', ARRAY['goods_id','parent_goods_id'], 'true'),
    ('subcontract_material_plan_items', ARRAY['goods_id','parent_goods_id'], 'true'),
    ('subcontract_material_return_items', ARRAY['goods_id','parent_goods_id'], 'true'),
    ('subcontract_order_cost_items', ARRAY['goods_id','parent_goods_id'], 'true'),
    ('subcontract_order_items', ARRAY['goods_id'], 'true'),
    ('subcontract_receipt_items', ARRAY['goods_id'], 'true'),
    ('subcontract_return_items', ARRAY['goods_id'], 'true'),
    ('subcontract_waste_items', ARRAY['goods_id'], 'true');
$catalog$;

CREATE FUNCTION fn_guard_goods_quantity_unit() RETURNS trigger
LANGUAGE plpgsql AS $guard$
BEGIN
    IF OLD.quantity_unit_locked AND (
        NOT NEW.quantity_unit_locked
        OR NEW.unit_id IS DISTINCT FROM OLD.unit_id
        OR (OLD.unit_id IS NULL AND NEW.unit_legacy_id IS DISTINCT FROM OLD.unit_legacy_id)
    ) THEN
        IF OLD.unit_id IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = '23514', CONSTRAINT = 'goods_quantity_unit_immutable',
                MESSAGE = '该货品已有数量记录，但历史基本单位尚未核对，不能在普通编辑中补选或改写单位。请先由管理员按原始单据受控核对。';
        END IF;
        RAISE EXCEPTION USING ERRCODE = '23514', CONSTRAINT = 'goods_quantity_unit_immutable',
            MESSAGE = '该货品已有数量记录或组装引用，基本单位不能再改。请保留原单位；不同计量规格请新建货品。';
    END IF;
    RETURN NEW;
END;
$guard$;
CREATE TRIGGER trg_goods_quantity_unit_immutable
BEFORE UPDATE ON goods FOR EACH ROW EXECUTE FUNCTION fn_guard_goods_quantity_unit();

CREATE FUNCTION fn_lock_goods_quantity_unit_from_references() RETURNS trigger
LANGUAGE plpgsql AS $lock$
DECLARE
    goods_id_to_lock UUID;
BEGIN
    -- The transition table contains only this statement's new rows. Sort all
    -- parent/child references before first-use updates to keep a consistent lock
    -- order. Once locked, the WHERE clause does no goods UPDATE or row locking.
    FOR goods_id_to_lock IN EXECUTE format(
        'SELECT DISTINCT refs.goods_id FROM new_quantity_refs n '
        'CROSS JOIN LATERAL (VALUES %s) refs(goods_id) '
        'JOIN goods g ON g.id = refs.goods_id '
        'WHERE NOT g.quantity_unit_locked AND (%s) ORDER BY refs.goods_id',
        TG_ARGV[0], TG_ARGV[1])
    LOOP
        UPDATE goods SET quantity_unit_locked = TRUE
        WHERE id = goods_id_to_lock AND NOT quantity_unit_locked;
    END LOOP;
    RETURN NULL;
END;
$lock$;

DO $install$
DECLARE
    source RECORD;
    column_name TEXT;
    value_sql TEXT;
    backfill_sql TEXT := '';
BEGIN
    FOR source IN SELECT * FROM fn_goods_quantity_reference_sources() ORDER BY relation_name LOOP
        IF to_regclass(source.relation_name) IS NULL THEN
            RAISE EXCEPTION 'Quantity-unit source table is missing: %', source.relation_name;
        END IF;
        value_sql := '';
        FOREACH column_name IN ARRAY source.goods_columns LOOP
            value_sql := value_sql || CASE WHEN value_sql = '' THEN '' ELSE ',' END
                || format('(n.%I)', column_name);
        END LOOP;
        backfill_sql := backfill_sql || CASE WHEN backfill_sql = '' THEN '' ELSE ' UNION ALL ' END
            || format('SELECT refs.goods_id FROM %I n CROSS JOIN LATERAL (VALUES %s) refs(goods_id) '
                'WHERE refs.goods_id IS NOT NULL AND (%s)', source.relation_name, value_sql, source.row_predicate);
        EXECUTE format('CREATE TRIGGER trg_lock_goods_quantity_unit_insert AFTER INSERT ON %I '
            'REFERENCING NEW TABLE AS new_quantity_refs FOR EACH STATEMENT '
            'EXECUTE FUNCTION fn_lock_goods_quantity_unit_from_references(%L, %L)',
            source.relation_name, value_sql, source.row_predicate);
        EXECUTE format('CREATE TRIGGER trg_lock_goods_quantity_unit_update AFTER UPDATE ON %I '
            'REFERENCING NEW TABLE AS new_quantity_refs FOR EACH STATEMENT '
            'EXECUTE FUNCTION fn_lock_goods_quantity_unit_from_references(%L, %L)',
            source.relation_name, value_sql, source.row_predicate);
    END LOOP;
    -- One pass over source references, deduplicated by UUID. Include cancelled,
    -- reversed, zero-balance and soft-deleted history: their quantity meaning is
    -- still fixed. Existing unused/null-unit masters remain editable.
    EXECUTE 'WITH used_goods AS MATERIALIZED (SELECT DISTINCT goods_id FROM ('
        || backfill_sql || ') all_quantity_references) '
        || 'UPDATE goods g SET quantity_unit_locked = TRUE FROM used_goods used '
        || 'WHERE used.goods_id = g.id AND NOT g.quantity_unit_locked';
END;
$install$;
