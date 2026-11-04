-- Preserve every existing kg/close fact. New calculations never silently round.
-- V1011 already removed ordinary numeric typmods; this migration updates only
-- named live weight functions and introduces explicit legacy/new close proofs.
CREATE OR REPLACE FUNCTION fn_weight_kg_map_is_valid(p_map jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE entry record;kilograms numeric;raw text;
BEGIN
 IF p_map IS NULL OR jsonb_typeof(p_map)<>'object' THEN RETURN false;END IF;
 FOR entry IN SELECT * FROM jsonb_each(p_map) LOOP
  IF entry.key !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    OR jsonb_typeof(entry.value) NOT IN ('number','string') THEN RETURN false;END IF;
  raw:=entry.value#>>'{}';
  IF raw !~ '^[+]?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$' THEN RETURN false;END IF;
  BEGIN kilograms:=raw::numeric;EXCEPTION WHEN numeric_value_out_of_range OR invalid_text_representation THEN RETURN false;END;
  IF kilograms<0 OR NOT fn_financial_amount_is_exact(kilograms) THEN RETURN false;END IF;
 END LOOP;
 RETURN true;
END $$;
COMMENT ON FUNCTION fn_weight_kg_map_is_valid(jsonb) IS 'Explicit decimal kg facts, numeric/string JSON; 40 integer/24 fraction support, no rounding';

DO $weight_linked_slice$
DECLARE definition text;old_call text:='round(OLD.weight * NEW.qty / OLD.qty, 4)';
 new_call text:='fn_business_exact_divide(OLD.weight * NEW.qty, OLD.qty, ''weight.prorate'', ''本次重量分摊'', 24)';
BEGIN
 SELECT pg_get_functiondef('fn_guard_production_linked_stock_document_item()'::regprocedure) INTO definition;
 IF position(old_call IN definition)=0 THEN
  IF position(new_call IN definition)=0 THEN RAISE EXCEPTION 'Review live linked-stock weight slice guard';END IF;
 ELSE EXECUTE replace(definition,old_call,new_call);END IF;
END $weight_linked_slice$;

-- Ledger reconciliation and physical mass conversion are distinct questions.
-- No read below writes/recalculates a historic balance or scale reading.
DO $weight_reconciliation$
DECLARE definition text;old_case text;new_case text;
BEGIN
 SELECT pg_get_viewdef('v_stock_weight_reconciliation'::regclass,true) INTO definition;
 -- Capture the same source joins/order as the installed v743 view. The shape is
 -- asserted before replacing the expected-value expression.
 IF position('exact_mass.kg_per_unit' IN definition)=0 OR position('latest.weight_after' IN definition)=0 THEN
  RAISE EXCEPTION 'Review live weight reconciliation sources';END IF;
END $weight_reconciliation$;

CREATE OR REPLACE VIEW v_stock_weight_reconciliation AS
SELECT balance.warehouse_id,
       balance.goods_id,
       balance.color_id,
       balance.qty,
       balance.weight AS balance_weight,
       balance.weight_estimated,
       exact_mass.kg_per_unit AS exact_kg_per_unit,
       latest.row_kind AS last_ledger_row_kind,
       latest.row_id AS last_ledger_row_id,
       latest.ledger_seq AS last_ledger_seq,
       latest.weight_after AS ledger_weight_after,
       expected.weight AS expected_weight,
       CASE WHEN balance.weight IS NULL OR latest.weight_after IS NULL THEN 'UNKNOWN'
            WHEN balance.weight=latest.weight_after THEN 'RECONCILED' ELSE 'DRIFT'
       END AS reconciliation_status,
       balance.weight - expected.weight AS weight_difference,
       CASE WHEN exact_mass.kg_per_unit IS NOT NULL AND balance.qty>=0 THEN balance.qty*exact_mass.kg_per_unit END AS physical_expected_weight,
       CASE WHEN exact_mass.kg_per_unit IS NULL THEN 'NOT_APPLICABLE'
            WHEN balance.qty<0 OR balance.weight IS NULL THEN 'UNKNOWN'
            WHEN balance.weight=balance.qty*exact_mass.kg_per_unit THEN 'EXACT_IDENTITY'
            ELSE 'PHYSICAL_DIFFERENCE_UNVERIFIED' END AS physical_identity_status,
       CASE WHEN exact_mass.kg_per_unit IS NOT NULL AND balance.qty>=0 THEN balance.weight-balance.qty*exact_mass.kg_per_unit END AS physical_weight_difference
FROM stock_balances balance
LEFT JOIN goods material ON material.id = balance.goods_id
LEFT JOIN LATERAL (
    SELECT fn_weight_unit_kg_factor(profile.mass_unit_code) AS kg_per_unit
    FROM unit_measurement_profiles profile
    WHERE profile.unit_id = material.unit_id
      AND profile.mass_unit_code IS NOT NULL
) exact_mass ON TRUE
LEFT JOIN LATERAL (
    SELECT candidate.row_kind, candidate.row_id, candidate.ledger_seq, candidate.weight_after
    FROM (
        (SELECT 'M'::TEXT AS row_kind, movement.id AS row_id, movement.ledger_seq,
                movement.balance_weight_after AS weight_after
         FROM stock_movements movement
         WHERE movement.goods_id = balance.goods_id
           AND movement.warehouse_id = balance.warehouse_id
           AND movement.color_id IS NOT DISTINCT FROM balance.color_id
         ORDER BY movement.ledger_seq DESC
         LIMIT 1)
        UNION ALL
        (SELECT 'W'::TEXT, adjustment.id, adjustment.ledger_seq, adjustment.weight_after
         FROM stock_weight_adjustments adjustment
         WHERE adjustment.goods_id = balance.goods_id
           AND adjustment.warehouse_id = balance.warehouse_id
           AND adjustment.color_id IS NOT DISTINCT FROM balance.color_id
         ORDER BY adjustment.ledger_seq DESC
         LIMIT 1)
    ) candidate
    ORDER BY candidate.ledger_seq DESC
    LIMIT 1
) latest ON TRUE
CROSS JOIN LATERAL (
    SELECT latest.weight_after AS weight
) expected;
COMMENT ON VIEW v_stock_weight_reconciliation IS 'Ledger comparison uses real latest kg fact; physical qty×mass factor is a separate unrounded reference. Unknown provenance remains unverified. Read-only, never repairs balances.';

-- Freeze old source algorithms under proof-only names before changing writers.
DO $weight_close_legacy$
DECLARE item record;definition text;
BEGIN
 FOR item IN SELECT * FROM (VALUES
  ('fn_workshop_material_convert_weight(numeric,uuid,uuid)','fn_workshop_material_convert_weight','fn_workshop_material_convert_weight_legacy_v1'),
  ('fn_workshop_material_unit_weight_step(uuid,integer)','fn_workshop_material_unit_weight_step','fn_workshop_material_unit_weight_step_legacy_v1'),
  ('fn_workshop_material_unit_weight(uuid)','fn_workshop_material_unit_weight','fn_workshop_material_unit_weight_legacy_v1'),
  ('fn_workshop_material_period_theory(uuid,date,date)','fn_workshop_material_period_theory','fn_workshop_material_period_theory_legacy_v1')
 ) v(signature,old_name,new_name) LOOP
  SELECT pg_get_functiondef(item.signature::regprocedure) INTO definition;
  definition:=replace(definition,item.old_name,item.new_name);
  IF item.old_name<>'fn_workshop_material_convert_weight' THEN
   definition:=replace(definition,'fn_workshop_material_convert_weight(','fn_workshop_material_convert_weight_legacy_v1(');
   definition:=replace(definition,'fn_workshop_material_unit_weight_step(','fn_workshop_material_unit_weight_step_legacy_v1(');
   definition:=replace(definition,'fn_workshop_material_unit_weight(','fn_workshop_material_unit_weight_legacy_v1(');
  END IF;
  EXECUTE definition;
 END LOOP;
END $weight_close_legacy$;

CREATE OR REPLACE FUNCTION fn_workshop_material_convert_weight(p_qty numeric,p_source_unit uuid,p_target_unit uuid)
RETURNS numeric LANGUAGE sql VOLATILE AS $$
 SELECT CASE WHEN p_qty IS NULL OR p_source_unit IS NULL OR p_target_unit IS NULL THEN NULL
 WHEN p_source_unit=p_target_unit THEN p_qty ELSE (
  SELECT fn_business_exact_divide(p_qty*fn_weight_unit_kg_factor(source.mass_unit_code),
    fn_weight_unit_kg_factor(target.mass_unit_code),'workshop.material.unit-weight','本次车间物料单重换算',24)
  FROM unit_measurement_profiles source JOIN unit_measurement_profiles target ON target.unit_id=p_target_unit
  WHERE source.unit_id=p_source_unit AND source.measurement_dimension='MASS' AND target.measurement_dimension='MASS'
    AND source.mass_unit_code IS NOT NULL AND target.mass_unit_code IS NOT NULL) END
$$;
-- Wrappers call a context-aware division, so they cannot be advertised STABLE.
ALTER FUNCTION fn_workshop_material_unit_weight_step(uuid,integer) VOLATILE;
ALTER FUNCTION fn_workshop_material_unit_weight(uuid) VOLATILE;
DO $weight_theory_writer$
DECLARE definition text;
BEGIN
 SELECT pg_get_functiondef('fn_workshop_material_period_theory(uuid,date,date)'::regprocedure) INTO definition;
 IF position('round(produced.qty * weights.weight_value, 6)' IN definition)=0 THEN RAISE EXCEPTION 'Review live material theory product';END IF;
 definition:=replace(definition,'round(produced.qty * weights.weight_value, 6)',
   'fn_business_exact_divide(produced.qty * weights.weight_value,1,''workshop.material.theory'',''本次车间物料理论用量'',24)');
 definition:=replace(definition,'STABLE','VOLATILE');
 EXECUTE definition;
END $weight_theory_writer$;

CREATE FUNCTION fn_workshop_material_precision_source_fingerprint(p_period uuid) RETURNS text LANGUAGE sql STABLE AS $$
 WITH scope AS (SELECT id,bin_warehouse_id,start_date,end_date FROM workshop_material_periods WHERE id=p_period),
 rows AS (SELECT material.* FROM production_execution_periodic_materials material,scope WHERE material.bin_warehouse_id=scope.bin_warehouse_id
   AND material.effective_from<=scope.end_date AND (material.effective_to IS NULL OR material.effective_to>=scope.start_date)),
 segments AS (SELECT segment.* FROM production_execution_segments segment WHERE segment.id IN(SELECT execution_segment_id FROM rows)),
 reports AS (SELECT DISTINCT report.* FROM production_daily_reports report JOIN production_daily_report_items item ON item.report_id=report.id
   JOIN segments ON segments.id=item.execution_segment_id JOIN scope ON report.bill_date BETWEEN scope.start_date AND scope.end_date)
 SELECT encode(digest(jsonb_build_object(
   'period',(SELECT to_jsonb(scope) FROM scope),
   'lines',(SELECT coalesce(jsonb_agg(to_jsonb(line)-ARRAY['updated_at','created_at'] ORDER BY line.id),'[]'::jsonb) FROM workshop_material_period_lines line WHERE line.period_id=p_period),
   'materials',(SELECT coalesce(jsonb_agg(to_jsonb(rows)-ARRAY['updated_at','created_at'] ORDER BY rows.id),'[]'::jsonb) FROM rows),
   'reports',(SELECT coalesce(jsonb_agg(to_jsonb(reports)-ARRAY['updated_at','created_at'] ORDER BY reports.id),'[]'::jsonb) FROM reports),
   'outputs',(SELECT coalesce(jsonb_agg(to_jsonb(item)-ARRAY['updated_at','created_at'] ORDER BY item.id),'[]'::jsonb) FROM production_daily_report_items item WHERE item.report_id IN(SELECT id FROM reports)),
   'bom',(SELECT coalesce(jsonb_agg(to_jsonb(bom)-ARRAY['updated_at','created_at'] ORDER BY bom.id),'[]'::jsonb) FROM goods_bom_items bom WHERE bom.goods_id IN(SELECT product_goods_id FROM segments)),
   'changes',(SELECT coalesce(jsonb_agg(to_jsonb(change)-ARRAY['updated_at','created_at'] ORDER BY change.id),'[]'::jsonb) FROM production_execution_material_changes change WHERE change.id IN(SELECT change_id FROM rows))
 )::text,'sha256'),'hex')
$$;

ALTER TABLE workshop_material_periods ADD COLUMN close_precision_policy jsonb;
ALTER TABLE workshop_material_periods ADD COLUMN close_precision_source_fingerprint text;
ALTER TABLE workshop_material_periods ADD COLUMN close_precision_requirement jsonb;
ALTER TABLE workshop_material_period_closes ADD COLUMN precision_version smallint NOT NULL DEFAULT 1 CHECK(precision_version IN(1,2));
ALTER TABLE workshop_material_period_closes ALTER COLUMN precision_version SET DEFAULT 2;
ALTER TABLE workshop_material_period_closes ADD COLUMN business_precision_policy jsonb;
ALTER TABLE workshop_material_period_closes ADD COLUMN precision_source_fingerprint text;
ALTER TABLE workshop_material_close_theory_lines ADD COLUMN precision_version smallint NOT NULL DEFAULT 1 CHECK(precision_version IN(1,2));
ALTER TABLE workshop_material_close_theory_lines ALTER COLUMN precision_version SET DEFAULT 2;
ALTER TABLE workshop_material_close_theory_lines ADD COLUMN business_precision_policy jsonb;
CREATE FUNCTION fn_guard_wm_close_precision() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE parent workshop_material_period_closes%ROWTYPE;policy jsonb:=fn_business_precision_snapshot();
BEGIN
 IF TG_TABLE_NAME='workshop_material_period_closes' THEN
  IF NEW.precision_version<>2 OR (NEW.business_precision_policy IS NOT NULL AND NEW.business_precision_policy<>policy) THEN
   RAISE EXCEPTION 'New material close requires current explicit precision provenance' USING ERRCODE='23514';END IF;
  NEW.business_precision_policy:=policy;
  NEW.precision_source_fingerprint:=fn_workshop_material_precision_source_fingerprint(NEW.period_id);
 ELSE
  SELECT * INTO parent FROM workshop_material_period_closes WHERE id=NEW.close_id;
  IF parent.precision_version<>2 OR parent.business_precision_policy IS NULL OR parent.business_precision_policy<>policy THEN
   RAISE EXCEPTION 'New material theory must use its same-operation frozen precision provenance' USING ERRCODE='23514';END IF;
  NEW.precision_version:=parent.precision_version;NEW.business_precision_policy:=parent.business_precision_policy;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_00_wm_close_precision BEFORE INSERT ON workshop_material_period_closes FOR EACH ROW EXECUTE FUNCTION fn_guard_wm_close_precision();
CREATE TRIGGER trg_00_wm_theory_precision BEFORE INSERT ON workshop_material_close_theory_lines FOR EACH ROW EXECUTE FUNCTION fn_guard_wm_close_precision();
ALTER TABLE workshop_material_period_closes ADD CONSTRAINT wm_close_precision_provenance CHECK(
 (precision_version=1 AND business_precision_policy IS NULL) OR (precision_version=2 AND business_precision_policy IS NOT NULL AND business_precision_policy->>'version'='1' AND jsonb_typeof(business_precision_policy->'choices')='object'));
ALTER TABLE workshop_material_close_theory_lines DROP CONSTRAINT workshop_material_theory_line_qty_chk;
ALTER TABLE workshop_material_close_theory_lines ADD CONSTRAINT workshop_material_theory_line_qty_chk CHECK(
 CASE WHEN precision_version=1 THEN business_precision_policy IS NULL AND theory_qty=round(output_qty_base*unit_weight,6)
 ELSE business_precision_policy IS NOT NULL AND fn_financial_amount_is_exact(theory_qty) AND theory_qty=fn_business_exact_divide_with_policy(output_qty_base*unit_weight,1,
  'workshop.material.theory','本次车间物料理论用量',24,business_precision_policy,false) END);

CREATE FUNCTION fn_workshop_material_period_theory_proof(p_bin uuid,p_from date,p_to date,p_version smallint,p_policy jsonb)
RETURNS TABLE(report_item_id uuid,report_id uuid,business_date date,execution_segment_id uuid,cost_scope_segment_id uuid,product_goods_id uuid,
 periodic_row_id uuid,material_goods_id uuid,material_color_id uuid,output_qty_base numeric,unit_weight numeric,weight_source text,theory_qty numeric)
LANGUAGE plpgsql VOLATILE AS $$
DECLARE previous text:=current_setting('app.business_precision_choices',true);used text:=current_setting('app.business_precision_used',true);
BEGIN
 IF p_version=1 AND p_policy IS NULL THEN RETURN QUERY SELECT * FROM fn_workshop_material_period_theory_legacy_v1(p_bin,p_from,p_to);RETURN;END IF;
 IF p_version<>2 OR p_policy IS NULL OR p_policy->>'version'<>'1' OR jsonb_typeof(p_policy->'choices')<>'object' THEN
  RAISE EXCEPTION 'Material close precision proof is incomplete' USING ERRCODE='23514';END IF;
 PERFORM set_config('app.business_precision_choices',p_policy::text,true);
 RETURN QUERY SELECT * FROM fn_workshop_material_period_theory(p_bin,p_from,p_to);
 PERFORM set_config('app.business_precision_choices',coalesce(previous,''),true);
 PERFORM set_config('app.business_precision_used',coalesce(used,''),true);
EXCEPTION WHEN OTHERS THEN
 PERFORM set_config('app.business_precision_choices',coalesce(previous,''),true);
 PERFORM set_config('app.business_precision_used',coalesce(used,''),true);RAISE;
END $$;

DO $weight_close_assertion$
DECLARE definition text;
BEGIN
 SELECT pg_get_functiondef('fn_assert_wm_close()'::regprocedure) INTO definition;
 IF position('FROM fn_workshop_material_period_theory(period.bin_warehouse_id, period.start_date, period.end_date) used' IN definition)=0 THEN
  RAISE EXCEPTION 'Review live material close assertion source';END IF;
 definition:=replace(definition,'FROM fn_workshop_material_period_theory(period.bin_warehouse_id, period.start_date, period.end_date) used',
  'FROM fn_workshop_material_period_theory_proof(period.bin_warehouse_id, period.start_date, period.end_date,close_row.precision_version,close_row.business_precision_policy) used');
 definition:=replace(definition,'COALESCE(round(used.output_qty_base, 6) = 0',
   'COALESCE(CASE WHEN close_row.precision_version=1 THEN round(used.output_qty_base, 6) = 0');
 definition:=replace(definition,'OR round(round(used.output_qty_base, 6) * round(used.unit_weight, 6), 6) = 0,',
   'OR round(round(used.output_qty_base, 6) * round(used.unit_weight, 6), 6) = 0 ELSE used.output_qty_base=0 OR used.theory_qty=0 END,');
 definition:=replace(definition,
  '    PERFORM set_config(marker, statement_timestamp()::text, true);'||E'\n    RETURN NULL;',
  $proof$    IF close_row.precision_version=2 AND close_row.precision_source_fingerprint IS DISTINCT FROM fn_workshop_material_precision_source_fingerprint(close_row.period_id) THEN
      RAISE EXCEPTION '本次车间结算来源已变化，请重新核对后办理' USING ERRCODE='23514',CONSTRAINT='workshop_material_close_precision_source';END IF;
    IF close_row.precision_version=2 AND EXISTS (
      SELECT 1 FROM workshop_material_close_allocations allocation
      JOIN workshop_material_close_materials material ON material.id=allocation.close_material_id
      JOIN LATERAL (SELECT sum(other.basis_qty) basis FROM workshop_material_close_allocations other
          WHERE other.close_material_id=material.id) total_basis ON true
      WHERE material.close_id=target_close AND NOT allocation.is_tail
        AND allocation.allocated_qty IS DISTINCT FROM fn_business_exact_divide_with_policy(
          material.consumed_qty*allocation.basis_qty,total_basis.basis,'quantity.share','本次数量分配',24,close_row.business_precision_policy,false)
  ) THEN RAISE EXCEPTION '结算分摊与原实际用量及已确认精度不一致' USING ERRCODE='23514',CONSTRAINT='workshop_material_close_precision_assert';END IF;
    PERFORM set_config(marker, statement_timestamp()::text, true);
    RETURN NULL;$proof$);
 EXECUTE definition;
END $weight_close_assertion$;

-- Count proposals freeze their maker's choice. Approval verifies/posts the same
-- fact, without asking the reviewer to recompute it under a different policy.
ALTER TABLE stock_count_requests ADD COLUMN business_precision_policy jsonb;
CREATE TRIGGER trg_00_stock_count_precision BEFORE INSERT ON stock_count_requests
 FOR EACH ROW EXECUTE FUNCTION fn_guard_business_precision_policy();
ALTER TABLE stock_count_requests ENABLE ALWAYS TRIGGER trg_00_stock_count_precision;
