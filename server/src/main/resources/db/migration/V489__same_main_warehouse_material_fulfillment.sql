-- Logical fulfillment may span sibling warehouses. Physical inventory,
-- inspection, stock movement and reservation identities remain leaf-specific.
CREATE OR REPLACE FUNCTION fn_warehouse_main_id(p_warehouse_id UUID)
RETURNS UUID LANGUAGE sql STABLE AS $$
    WITH RECURSIVE ancestry AS (
        SELECT id,parent_id,ARRAY[id] AS path
        FROM warehouses WHERE id=p_warehouse_id AND is_deleted=FALSE
        UNION ALL
        SELECT parent.id,parent.parent_id,ancestry.path || parent.id
        FROM ancestry JOIN warehouses parent ON parent.id=ancestry.parent_id
        WHERE parent.is_deleted=FALSE AND NOT parent.id=ANY(ancestry.path)
    )
    SELECT id FROM ancestry WHERE parent_id IS NULL LIMIT 1
$$;

CREATE OR REPLACE FUNCTION fn_warehouse_same_main(p_left UUID,p_right UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT COALESCE(p_left=p_right OR
        fn_warehouse_main_id(p_left)=fn_warehouse_main_id(p_right),FALSE)
$$;

CREATE OR REPLACE VIEW v_preplan_exact_peg_warehouse_mismatches AS
SELECT exact.id AS exact_peg_id,exact.stock_reservation_id,
       exact.origin_analysis_id,exact.beneficiary_analysis_id,
       action.id AS source_action_id,
       reservation.warehouse_id AS reservation_warehouse_id,
       action.warehouse_id AS action_warehouse_id,
       origin_analysis.warehouse_id AS origin_analysis_warehouse_id,
       beneficiary_analysis.warehouse_id AS beneficiary_analysis_warehouse_id
FROM preplan_analysis_stock_exact_pegs exact
JOIN stock_reservations reservation ON reservation.id=exact.stock_reservation_id
JOIN preplan_supply_action_allocations allocation
  ON allocation.id=exact.supply_action_allocation_id
JOIN preplan_supply_actions action ON action.id=allocation.action_id
JOIN production_material_analyses origin_analysis
  ON origin_analysis.id=exact.origin_analysis_id
JOIN production_material_analyses beneficiary_analysis
  ON beneficiary_analysis.id=exact.beneficiary_analysis_id
WHERE NOT fn_warehouse_same_main(reservation.warehouse_id,action.warehouse_id)
   OR NOT fn_warehouse_same_main(reservation.warehouse_id,origin_analysis.warehouse_id)
   OR NOT fn_warehouse_same_main(reservation.warehouse_id,beneficiary_analysis.warehouse_id);

COMMENT ON VIEW v_preplan_exact_peg_warehouse_mismatches IS
    'Exact material entitlement may use sibling leaf warehouses under the same main warehouse; physical lot identities are unchanged';

CREATE OR REPLACE FUNCTION fn_analysis_plan_material_matches(
    p_item_id UUID,p_material_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(
        SELECT 1 FROM production_material_analysis_items item
        JOIN production_material_analysis_materials material
          ON material.id=p_material_id AND material.analysis_id=item.analysis_id
         AND material.active=TRUE
        LEFT JOIN production_material_analysis_materials parent
          ON parent.id=item.parent_analysis_material_id
         AND parent.analysis_id=item.analysis_id
        WHERE item.id=p_item_id AND item.is_deleted=FALSE
          AND ((item.parent_analysis_material_id IS NULL
                AND material.analysis_item_id=item.id AND material.depth=1)
            OR (item.source_type IN('MAKE_COMPONENT','SUBCONTRACT_MAKE')
                AND parent.active=TRUE
                AND material.analysis_item_id=parent.analysis_item_id
                AND material.parent_node_key=parent.node_key)))
$$;

-- Preserve all installed conservation/provenance checks, replacing only the
-- logical warehouse and anchor ownership comparisons. Unknown source fails.
DO $patch$
DECLARE definition TEXT; patched TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_guard_production_stock_allocation()'::regprocedure)
      INTO definition;
    patched := replace(definition,
        'v_demand.warehouse_id <> NEW.warehouse_id',
        'NOT fn_warehouse_same_main(v_demand.warehouse_id,NEW.warehouse_id)');
    IF patched=definition THEN
        RAISE EXCEPTION 'V489 production stock allocation guard source mismatch';
    END IF;
    EXECUTE patched;

    SELECT pg_get_functiondef('fn_check_preplan_stock_entitlement_event()'::regprocedure)
      INTO definition;
    patched := replace(definition,
        'demand.warehouse_id <> reservation.warehouse_id',
        'NOT fn_warehouse_same_main(demand.warehouse_id,reservation.warehouse_id)');
    IF patched=definition THEN
        RAISE EXCEPTION 'V489 entitlement warehouse guard source mismatch';
    END IF;
    definition := patched;
    patched := regexp_replace(definition,
        'production_plan.material_analysis_item_id\s+IS DISTINCT FROM material.analysis_item_id',
        'NOT fn_analysis_plan_material_matches(production_plan.material_analysis_item_id,material.id)');
    IF patched=definition THEN
        RAISE EXCEPTION 'V489 entitlement anchor guard source mismatch';
    END IF;
    EXECUTE patched;
END;
$patch$;

ALTER TABLE production_execution_segment_events
    DROP CONSTRAINT production_execution_segment_events_action_check,
    ADD CONSTRAINT production_execution_segment_events_action_check
    CHECK (action IN (
        'ASSIGNMENT','DISPATCH','START','CANCEL','REVERSE',
        'REOPEN_COMPLETION','RELEASE_DEFER','AUTO_START_ON_REPORT',
        'RECHECK_MATERIAL'
    ));

CREATE OR REPLACE FUNCTION fn_guard_material_stock_posting_physical_warehouse_v489()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM stock_document_items item
        JOIN stock_documents document ON document.id=item.doc_id
        JOIN stock_reservations reservation ON reservation.id=NEW.reservation_id
        WHERE item.id=NEW.stock_document_item_id
          AND document.warehouse_id=reservation.warehouse_id
    ) THEN
        RAISE EXCEPTION 'material posting must consume or restore the actual document warehouse'
            USING ERRCODE='23514',
                  CONSTRAINT='material_stock_posting_physical_warehouse_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_material_stock_posting_physical_warehouse_v489
    BEFORE INSERT ON production_material_stock_postings
    FOR EACH ROW EXECUTE FUNCTION fn_guard_material_stock_posting_physical_warehouse_v489();
