-- The allowance is a material budget, never an assertion of actual material loss.
-- Retain every approved historical quantity, amount and immutable consumption slice.
ALTER TABLE subcontract_receipt_items ADD COLUMN material_consumption_version SMALLINT;
UPDATE subcontract_receipt_items item
SET material_consumption_version=CASE WHEN item.material_basis_qty IS NOT NULL
  OR EXISTS(SELECT 1 FROM subcontract_receipts receipt WHERE receipt.id=item.receipt_id AND receipt.status IN(1,-1))
  OR EXISTS(SELECT 1 FROM subcontract_receipt_material_consumptions source WHERE source.receipt_item_id=item.id)
  THEN 1 ELSE 2 END;
ALTER TABLE subcontract_receipt_items ALTER COLUMN material_consumption_version SET DEFAULT 2,
  ALTER COLUMN material_consumption_version SET NOT NULL,
  ADD CONSTRAINT subcontract_receipt_consumption_version_chk CHECK(material_consumption_version IN(1,2));
COMMENT ON COLUMN subcontract_receipt_items.material_consumption_version IS
  '1 preserves previously approved allowance-based estimate slices; 2 consumes frozen base BOM against explicitly recorded actual receipts. Never rewrite posted consumption.';
CREATE FUNCTION fn_guard_subcontract_receipt_consumption_version() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP='INSERT' AND NEW.material_consumption_version<>2 THEN
    RAISE EXCEPTION 'new subcontract receipts must use actual base material consumption' USING ERRCODE='23514';
  END IF;
  IF TG_OP='UPDATE' AND NEW.material_consumption_version IS DISTINCT FROM OLD.material_consumption_version THEN
    RAISE EXCEPTION 'subcontract receipt material consumption version is immutable' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_subcontract_receipt_consumption_version BEFORE INSERT OR UPDATE OF material_consumption_version
ON subcontract_receipt_items FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_receipt_consumption_version();

DO $$ DECLARE rule RECORD; BEGIN
  FOR rule IN SELECT conname FROM pg_constraint WHERE conrelid='subcontract_receipt_material_consumptions'::regclass
    AND contype='c' AND pg_get_constraintdef(oid) LIKE '%consumption_basis%'
  LOOP EXECUTE format('ALTER TABLE subcontract_receipt_material_consumptions DROP CONSTRAINT %I',rule.conname); END LOOP;
END $$;
ALTER TABLE subcontract_receipt_material_consumptions ADD CONSTRAINT subcontract_consumption_basis_version_chk
CHECK(consumption_basis IN('FROZEN_BOM_ESTIMATE','FROZEN_BASE_BOM_ACTUAL'));

-- The order's approved allowance, not the goods master's mutable remembered default.
CREATE FUNCTION fn_subcontract_normal_receipt_limit(p_order_item UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT TRUNC(item.qty*(1+COALESCE(item.allowed_loss_pct,0)/100),4)
  FROM subcontract_order_items item WHERE item.id=p_order_item AND NOT item.is_deleted
$$;
COMMENT ON FUNCTION fn_subcontract_normal_receipt_limit(UUID) IS
  'Normal cumulative finished receipts: original finished target plus its approved maximum material allowance. The physical base-BOM capacity remains an independent bound.';

-- Keep old and new cumulative rounding in separate cohorts; old excess consumption
-- cannot stand in for material consumed by a new receipt or be silently refunded.
CREATE FUNCTION fn_subcontract_material_consumption_cohort_target(p_plan_item UUID,p_version INTEGER,p_current_receipt UUID DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT fn_subcontract_draw_f(COALESCE(SUM(item.material_basis_qty),0),
       CASE WHEN p_version=1 THEN plan.bom_unit_qty ELSE plan.base_bom_unit_qty END)
  FROM subcontract_material_plan_items plan
  LEFT JOIN (subcontract_receipt_items item JOIN subcontract_receipts receipt ON receipt.id=item.receipt_id
    AND NOT receipt.is_deleted AND (receipt.status=1 OR receipt.id=p_current_receipt))
    ON item.order_item_id=plan.order_item_id AND NOT item.is_deleted AND item.material_basis_qty IS NOT NULL
      AND item.material_consumption_version=p_version
  WHERE plan.id=p_plan_item AND NOT plan.is_deleted AND p_version IN(1,2)
  GROUP BY plan.id,plan.bom_unit_qty,plan.base_bom_unit_qty
$$;
CREATE FUNCTION fn_subcontract_material_consumption_target(p_plan_item UUID,p_current_receipt UUID DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT fn_subcontract_material_consumption_cohort_target(p_plan_item,1,p_current_receipt)
       + fn_subcontract_material_consumption_cohort_target(p_plan_item,2,p_current_receipt)
$$;

CREATE FUNCTION fn_subcontract_physical_receipt_capacity(p_order_item UUID,p_excluded_issue UUID DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  WITH basis AS (
    SELECT COALESCE(SUM(item.material_basis_qty),0) received
    FROM subcontract_receipt_items item JOIN subcontract_receipts receipt ON receipt.id=item.receipt_id
    WHERE item.order_item_id=p_order_item AND NOT item.is_deleted AND receipt.status=1 AND NOT receipt.is_deleted
  ), materials AS (
    SELECT plan.id,plan.base_bom_unit_qty,
      COALESCE(SUM(issue_item.at_supplier_qty+issue_item.compensated_qty-COALESCE(issue_item.returned_qty,0)
        -COALESCE(issue_item.wasted_qty,0)) FILTER(WHERE p_excluded_issue IS NULL OR issue.id<>p_excluded_issue),0) usable,
      COALESCE(SUM(issue_item.consumed_qty),0) consumed
    FROM subcontract_material_plan_items plan
    LEFT JOIN (subcontract_material_issue_items issue_item JOIN subcontract_material_issues issue ON issue.id=issue_item.issue_id
      AND issue.status=1 AND NOT issue.is_deleted) ON issue_item.plan_item_id=plan.id AND NOT issue_item.is_deleted
    WHERE plan.order_item_id=p_order_item AND NOT plan.is_deleted
    GROUP BY plan.id,plan.base_bom_unit_qty
  )
  SELECT CASE WHEN COUNT(materials.id)=0 OR BOOL_OR(materials.usable<materials.consumed) THEN 0
    ELSE MAX(basis.received)+MIN(fn_subcontract_draw_sets(materials.usable-materials.consumed,materials.base_bom_unit_qty)) END
  FROM basis LEFT JOIN materials ON TRUE
$$;
CREATE FUNCTION fn_subcontract_returnable_qty_excluding_issue(p_order_item UUID,p_excluded_issue UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT LEAST(fn_subcontract_normal_receipt_limit(p_order_item)
    + COALESCE((SELECT returned_qty FROM subcontract_order_items WHERE id=p_order_item),0),
    fn_subcontract_physical_receipt_capacity(p_order_item,p_excluded_issue))
$$;
CREATE OR REPLACE FUNCTION fn_subcontract_returnable_qty(p_order_item UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT fn_subcontract_returnable_qty_excluding_issue(p_order_item,NULL)
$$;
COMMENT ON FUNCTION fn_subcontract_returnable_qty(UUID) IS
  'Actual own-material finished capacity: already recorded material-basis receipts plus remaining usable material/base BOM, each material independently; historical estimate consumption stays consumed. Capped by approved normal finished allowance.';

CREATE OR REPLACE FUNCTION fn_subcontract_receipt_material_complete(p_receipt_item UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    WITH receipt_line AS (
        SELECT item.id, item.order_item_id, item.material_basis_qty, item.material_consumption_version
        FROM subcontract_receipt_items item
        WHERE item.id = p_receipt_item AND NOT item.is_deleted
    ), live AS (
        SELECT consumption.issue_item_id, consumption.consumption_basis, receipt_line.material_consumption_version
        FROM subcontract_receipt_material_consumptions consumption
        JOIN receipt_line ON receipt_line.id = consumption.receipt_item_id
        WHERE consumption.reversal_of IS NULL
          AND NOT EXISTS (SELECT 1 FROM subcontract_receipt_material_consumptions reversed
                          WHERE reversed.reversal_of = consumption.id)
    ), lines AS (
        SELECT plan_item.id, plan_item.bom_unit_qty
        FROM subcontract_material_plan_items plan_item
        JOIN receipt_line ON receipt_line.order_item_id = plan_item.order_item_id
        WHERE NOT plan_item.is_deleted
    ), basis AS (
        SELECT receipt_basis.basis_qty, receipt_basis.reversed_line_count
        FROM receipt_line CROSS JOIN LATERAL fn_subcontract_receipt_basis(receipt_line.order_item_id) receipt_basis
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM receipt_line) THEN FALSE
        WHEN NOT EXISTS (SELECT 1 FROM lines) THEN FALSE
        ELSE (SELECT material_basis_qty FROM receipt_line) IS NOT NULL
             AND NOT EXISTS (
                 SELECT 1 FROM live
                 JOIN subcontract_material_issue_items issue_item ON issue_item.id = live.issue_item_id
                 LEFT JOIN lines ON lines.id = issue_item.plan_item_id
                 WHERE lines.id IS NULL OR live.consumption_basis <> CASE WHEN live.material_consumption_version=1 THEN 'FROZEN_BOM_ESTIMATE' ELSE 'FROZEN_BASE_BOM_ACTUAL' END)
             AND NOT EXISTS (
                 SELECT 1
                 FROM lines CROSS JOIN basis
                 WHERE abs(COALESCE((SELECT SUM(issue_item.consumed_qty)
                                     FROM subcontract_material_issue_items issue_item
                                     JOIN subcontract_material_issues issue ON issue.id = issue_item.issue_id
                                      AND issue.status = 1 AND NOT issue.is_deleted
                                     WHERE issue_item.plan_item_id = lines.id AND NOT issue_item.is_deleted), 0)
                           - fn_subcontract_material_consumption_target(lines.id))
                       > basis.reversed_line_count * 0.0001)
        END
$$;

CREATE OR REPLACE FUNCTION fn_assert_subcontract_target_outbound_receipt(p_order_item_id UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_rate NUMERIC;
    v_basis NUMERIC;
    v_reversed_lines INTEGER;
    v_missing_basis INTEGER;
    v_netted NUMERIC;
    v_netted_lines INTEGER;
    v_replacement NUMERIC;
    v_supplier_own NUMERIC;
    v_target NUMERIC;
    line RECORD;
BEGIN
    IF p_order_item_id IS NULL THEN
        RETURN;
    END IF;

    SELECT COALESCE(unit_rate, 1) INTO v_rate
    FROM subcontract_order_items WHERE id = p_order_item_id FOR NO KEY UPDATE;

    SELECT COUNT(*) FILTER (WHERE item.material_basis_qty IS NULL
                              AND item.legacy_id IS NULL AND item.legacy_import_run_id IS NULL
                              AND receipt.legacy_id IS NULL AND receipt.legacy_import_run_id IS NULL),
           COALESCE(SUM(item.qty - item.material_basis_qty) FILTER (WHERE item.material_basis_qty < item.qty), 0),
           COUNT(*) FILTER (WHERE item.material_basis_qty < item.qty)
      INTO v_missing_basis, v_netted, v_netted_lines
    FROM subcontract_receipt_items item
    JOIN subcontract_receipts receipt ON receipt.id = item.receipt_id
     AND receipt.status = 1 AND NOT receipt.is_deleted
    WHERE item.order_item_id = p_order_item_id AND NOT item.is_deleted;
    IF v_missing_basis > 0 THEN
        RAISE EXCEPTION 'approved subcontract receipt line lacks its frozen material basis'
            USING ERRCODE = '23514', CONSTRAINT = 'subcontract_receipt_material_basis_guard';
    END IF;

    SELECT COALESCE(SUM(allocation.allocated_base_qty), 0) INTO v_replacement
    FROM procurement_iqc_replacement_allocations allocation
    JOIN procurement_iqc_rejection_cases rejection ON rejection.id = allocation.case_id
     AND rejection.receipt_type = 'SUBCONTRACT' AND rejection.order_item_id = p_order_item_id
     AND rejection.is_deleted = FALSE AND rejection.status <> 'REVERSED'
     AND rejection.return_recorded_at IS NOT NULL
    JOIN subcontract_receipt_items original_item ON original_item.id = rejection.receipt_item_id
     AND original_item.receipt_id = rejection.receipt_id AND original_item.order_item_id = p_order_item_id
     AND original_item.is_deleted = FALSE
    JOIN subcontract_receipts original_receipt ON original_receipt.id = original_item.receipt_id
     AND original_receipt.status = 1 AND original_receipt.is_deleted = FALSE
    JOIN subcontract_receipt_items replacement_item ON replacement_item.id = allocation.replacement_receipt_item_id
     AND replacement_item.order_item_id = p_order_item_id AND replacement_item.is_deleted = FALSE
     AND replacement_item.goods_id = rejection.goods_id
     AND replacement_item.color_id IS NOT DISTINCT FROM rejection.color_id
    JOIN subcontract_receipts replacement_receipt ON replacement_receipt.id = replacement_item.receipt_id
     AND replacement_receipt.status = 1 AND replacement_receipt.is_deleted = FALSE
     AND replacement_receipt.supplier_id = rejection.supplier_id
    WHERE allocation.replacement_receipt_type = 'SUBCONTRACT' AND allocation.status = 'ACTIVE';

    v_supplier_own := fn_subcontract_supplier_own_qty(p_order_item_id);

    IF v_netted > v_replacement / NULLIF(v_rate, 0) + v_supplier_own + v_netted_lines * 0.0001 THEN
        RAISE EXCEPTION 'subcontract receipt material basis nets more than IQC replacements and finance-approved supplier material'
            USING ERRCODE = '23514', CONSTRAINT = 'subcontract_target_outbound_first_guard';
    END IF;

    SELECT receipt_basis.basis_qty, receipt_basis.reversed_line_count
      INTO v_basis, v_reversed_lines
    FROM fn_subcontract_receipt_basis(p_order_item_id) receipt_basis;

    IF v_basis > 0 AND NOT EXISTS (
        SELECT 1 FROM subcontract_material_plan_items plan_item
        WHERE plan_item.order_item_id = p_order_item_id AND NOT plan_item.is_deleted
    ) THEN
        RAISE EXCEPTION 'subcontract receipt has no frozen draw plan lines, so its returnable quantity is 0'
            USING ERRCODE = '23514', CONSTRAINT = 'subcontract_target_outbound_first_guard';
    END IF;

    FOR line IN
        SELECT plan_item.id, plan_item.bom_unit_qty,
               COALESCE(SUM(issue_item.consumed_qty), 0) AS consumed_qty,
               COALESCE(SUM(issue_item.at_supplier_qty + issue_item.compensated_qty
                            - COALESCE(issue_item.returned_qty, 0) - COALESCE(issue_item.wasted_qty, 0)), 0) AS usable_qty
        FROM subcontract_material_plan_items plan_item
        LEFT JOIN (subcontract_material_issue_items issue_item
                   JOIN subcontract_material_issues issue ON issue.id = issue_item.issue_id
                    AND issue.status = 1 AND NOT issue.is_deleted)
          ON issue_item.plan_item_id = plan_item.id AND NOT issue_item.is_deleted
        WHERE plan_item.order_item_id = p_order_item_id AND NOT plan_item.is_deleted
        GROUP BY plan_item.id, plan_item.bom_unit_qty
    LOOP
        IF line.consumed_qty > line.usable_qty THEN
            RAISE EXCEPTION 'subcontract receipt consumes more of a material than the supplier holds'
                USING ERRCODE = '23514', CONSTRAINT = 'subcontract_target_outbound_first_guard';
        END IF;
        v_target := fn_subcontract_material_consumption_target(line.id);
        IF abs(line.consumed_qty - v_target) > v_reversed_lines * 0.0001 THEN
            RAISE EXCEPTION 'subcontract receipt material consumption % differs from target % beyond the reversal tolerance',
                line.consumed_qty, v_target
                USING ERRCODE = '23514', CONSTRAINT = 'subcontract_target_outbound_consumption_guard';
        END IF;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_subcontract_receipt_material_consumption()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    receipt subcontract_receipt_items%ROWTYPE;
    issue subcontract_material_issue_items%ROWTYPE;
    original subcontract_receipt_material_consumptions%ROWTYPE;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'subcontract material consumption sources are immutable' USING ERRCODE = '55000';
    END IF;
    SELECT * INTO receipt FROM subcontract_receipt_items WHERE id = NEW.receipt_item_id;
    SELECT * INTO issue FROM subcontract_material_issue_items WHERE id = NEW.issue_item_id FOR UPDATE;
    IF receipt.id IS NULL OR issue.id IS NULL OR receipt.order_item_id IS DISTINCT FROM issue.order_item_id
       OR NEW.qty_base <> NEW.qty_doc * COALESCE(issue.unit_rate, 1) THEN
        RAISE EXCEPTION 'subcontract consumption must use the exact order and issued material base quantity'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.consumption_basis <> (CASE WHEN receipt.material_consumption_version=1 THEN 'FROZEN_BOM_ESTIMATE' ELSE 'FROZEN_BASE_BOM_ACTUAL' END) OR NOT EXISTS (
        SELECT 1 FROM subcontract_material_plan_items plan_item
        WHERE plan_item.id = issue.plan_item_id AND plan_item.order_item_id = receipt.order_item_id
    ) THEN
        RAISE EXCEPTION 'subcontract consumption must slice a frozen draw-plan material of the same order item'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.reversal_of IS NOT NULL THEN
        SELECT * INTO original FROM subcontract_receipt_material_consumptions WHERE id = NEW.reversal_of;
        IF original.id IS NULL OR original.reversal_of IS NOT NULL
           OR original.receipt_item_id <> NEW.receipt_item_id
           OR original.issue_item_id <> NEW.issue_item_id OR original.qty_doc <> NEW.qty_doc
           OR original.qty_base <> NEW.qty_base OR original.consumption_basis <> NEW.consumption_basis THEN
            RAISE EXCEPTION 'subcontract receipt reversal must restore the same complete original consumption slice'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

-- Add only the subcontract normal allowance to existing, history-aware received and
-- return guards; keep purchase tolerance, IQC replacement and finance decisions intact.
DO $$ DECLARE source TEXT; anchor TEXT; BEGIN
  source:=pg_get_functiondef('fn_guard_procurement_received_with_arrival_allowance()'::regprocedure);
  anchor:='+ v_iqc_replacement;';
  IF (length(source)-length(replace(source,anchor,'')))/length(anchor)<>1 THEN
    RAISE EXCEPTION 'V1096 received capacity anchor differs';
  END IF;
  source:=replace(source,anchor,anchor||E'\n  IF TG_ARGV[0]=''SUBCONTRACT'' THEN\n'
    ||E'    v_capacity:=v_capacity+GREATEST(TRUNC(COALESCE(NEW.qty,0)*(1+COALESCE((to_jsonb(NEW)->>''allowed_loss_pct'')::numeric,0)/100),4)-COALESCE(NEW.qty,0),0);\n'
    ||E'  END IF;');
  EXECUTE source;
  source:=pg_get_functiondef('fn_guard_return_allowance()'::regprocedure);
  anchor:='v_rate := COALESCE((v_new_row->>''unit_rate'')::numeric,1);';
  IF (length(source)-length(replace(source,anchor,'')))/length(anchor)<>1 THEN
    RAISE EXCEPTION 'V1096 return allowance capacity anchor differs';
  END IF;
  EXECUTE replace(source,anchor,anchor||E'\n'
    ||E'            IF TG_TABLE_NAME=''subcontract_order_items'' THEN\n'
    ||E'                v_tolerance_base:=GREATEST(TRUNC(v_base*(1+COALESCE((v_new_row->>''allowed_loss_pct'')::numeric,0)/100),4)-v_base,0)*v_rate;\n'
    ||E'            END IF;');
END $$;
