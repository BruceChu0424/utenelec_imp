-- Source-aware transition: retain every historic stored derived value. Only
-- actual source edits create v2; status changes/reopen never recalculate v1.
DO $wm_generated_catalog$
DECLARE generated text;
BEGIN
 SELECT attgenerated INTO generated FROM pg_attribute WHERE attrelid='workshop_material_count_lines'::regclass AND attname='qty_base';
 IF generated<>'s' THEN RAISE EXCEPTION 'Review WM qty_base generation before migration';END IF;
 SELECT attgenerated INTO generated FROM pg_attribute WHERE attrelid='workshop_material_count_adjustment_postings'::regclass AND attname='signed_qty';
 IF generated<>'s' THEN RAISE EXCEPTION 'Review WM signed_qty generation before migration';END IF;
 IF EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='workshop_material_period_lines'::regclass AND attname='actual_qty' AND attgenerated<>'') THEN
  RAISE EXCEPTION 'Review current WM period derivation before migration';END IF;
END; $wm_generated_catalog$;
ALTER TABLE workshop_material_count_lines ALTER COLUMN qty_base DROP EXPRESSION;
ALTER TABLE workshop_material_count_adjustment_postings ALTER COLUMN signed_qty DROP EXPRESSION;
SELECT fn_migrate_financial_amount_columns('[
 {"table":"workshop_material_count_lines","column":"bag_count","kind":"actual"},
 {"table":"workshop_material_count_lines","column":"bag_net_qty","kind":"actual"},
 {"table":"workshop_material_count_lines","column":"weighed_qty","kind":"actual"},
 {"table":"workshop_material_count_lines","column":"capacity_qty_snapshot","kind":"actual"},
 {"table":"workshop_material_count_lines","column":"qty_base","kind":"actual"},
 {"table":"workshop_material_count_adjustment_postings","column":"before_qty","kind":"actual"},
 {"table":"workshop_material_count_adjustment_postings","column":"target_qty","kind":"actual"},
 {"table":"workshop_material_count_adjustment_postings","column":"signed_qty","kind":"actual"}
]'::jsonb);

-- Keep original authorization, state and version checks; derivation moves to
-- the protected common trigger below, so direct actual_qty edits are visible.
DO $wm_period_guard$
DECLARE definition text; old_block text:=$old$    IF TG_OP <> 'DELETE' THEN
        NEW.actual_qty := NEW.opening_qty+NEW.transfer_in_qty-NEW.return_qty-NEW.other_issue_qty+NEW.adjustment_qty-NEW.closing_qty;
    END IF;$old$;
BEGIN
 SELECT replace(pg_get_functiondef('fn_guard_wm_period_line()'::regprocedure),E'\r','') INTO definition;
 old_block:=replace(old_block,E'\r','');
 IF position(old_block IN definition)=0 THEN RAISE EXCEPTION 'Review current WM period guard before changing derivation';END IF;
 EXECUTE replace(definition,old_block,'');
END; $wm_period_guard$;

CREATE FUNCTION fn_workshop_material_derived_quantity(p_table text,p_row jsonb,p_policy jsonb) RETURNS numeric
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,public AS $$
DECLARE value numeric; key text; item text; n numeric;
BEGIN
 FOREACH item IN ARRAY CASE p_table
  WHEN 'workshop_material_count_lines' THEN ARRAY['bag_count','bag_net_qty','weighed_qty','capacity_qty_snapshot']
  WHEN 'workshop_material_count_adjustment_postings' THEN ARRAY['before_qty','target_qty']
  WHEN 'workshop_material_period_lines' THEN ARRAY['opening_qty','transfer_in_qty','return_qty','other_issue_qty','adjustment_qty','closing_qty']
  ELSE NULL END LOOP
  n:=(p_row->>item)::numeric;
  IF n IS NOT NULL AND NOT fn_financial_amount_is_exact(n) THEN
   RAISE EXCEPTION 'WM source quantity exceeds exact 40 integer / 24 fraction support' USING ERRCODE='22023';END IF;
 END LOOP;
 IF p_table='workshop_material_count_lines' THEN
  key:='workshop.material.count-quantity';
  value:=CASE p_row->>'line_kind'
   WHEN 'FULL_BAGS' THEN (p_row->>'bag_count')::numeric*(p_row->>'bag_net_qty')::numeric
   WHEN 'CONTAINER' THEN CASE p_row->>'fill_level'
    WHEN 'FULL' THEN (p_row->>'capacity_qty_snapshot')::numeric
    WHEN 'HALF' THEN (p_row->>'capacity_qty_snapshot')::numeric*0.5
    WHEN 'EMPTY' THEN 0 ELSE (p_row->>'weighed_qty')::numeric END
   ELSE (p_row->>'weighed_qty')::numeric END;
 ELSIF p_table='workshop_material_count_adjustment_postings' THEN
  key:='workshop.material.count-adjustment';
  value:=(p_row->>'target_qty')::numeric-(p_row->>'before_qty')::numeric;
 ELSIF p_table='workshop_material_period_lines' THEN
  key:='workshop.material.actual-quantity';
  value:=(p_row->>'opening_qty')::numeric+(p_row->>'transfer_in_qty')::numeric
    -(p_row->>'return_qty')::numeric-(p_row->>'other_issue_qty')::numeric
    +(p_row->>'adjustment_qty')::numeric-(p_row->>'closing_qty')::numeric;
 ELSE RAISE EXCEPTION 'Unsupported WM quantity family' USING ERRCODE='22023';END IF;
 IF value IS NULL THEN RETURN NULL;END IF;
 RETURN fn_business_exact_divide_with_policy(value,1,key,'本次车间物料盘点数量',24,p_policy,false);
END $$;

ALTER TABLE workshop_material_count_lines ADD COLUMN derivation_source_line_id uuid REFERENCES workshop_material_count_lines(id);

CREATE FUNCTION fn_guard_workshop_material_derived_quantity() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE field text; source_keys text[]; original jsonb; incoming jsonb:=to_jsonb(NEW);
 policy jsonb:=fn_business_precision_snapshot(); changed boolean; derived numeric; source_line workshop_material_count_lines%ROWTYPE;
BEGIN
 IF TG_TABLE_NAME='workshop_material_count_lines' THEN
  field:='qty_base';source_keys:=ARRAY['line_kind','fill_level','bag_count','bag_net_qty','weighed_qty','capacity_qty_snapshot'];
 ELSIF TG_TABLE_NAME='workshop_material_period_lines' THEN
  field:='actual_qty';source_keys:=ARRAY['opening_qty','transfer_in_qty','return_qty','other_issue_qty','adjustment_qty','closing_qty'];
 ELSE field:='signed_qty';source_keys:=ARRAY['before_qty','target_qty'];END IF;
 IF TG_OP='UPDATE' THEN
  original:=to_jsonb(OLD);
  IF TG_TABLE_NAME='workshop_material_count_lines' AND incoming->'derivation_source_line_id' IS DISTINCT FROM original->'derivation_source_line_id' THEN
   RAISE EXCEPTION 'WM original derivation reference is immutable' USING ERRCODE='23514';END IF;
  IF incoming->field IS DISTINCT FROM original->field
    OR NEW.derivation_version<>OLD.derivation_version
    OR NEW.derivation_precision_policy IS DISTINCT FROM OLD.derivation_precision_policy THEN
   RAISE EXCEPTION 'Derived WM quantity and frozen precision cannot be edited directly' USING ERRCODE='23514';END IF;
  SELECT EXISTS(SELECT 1 FROM unnest(source_keys) item WHERE incoming->item IS DISTINCT FROM original->item) INTO changed;
  IF NOT changed THEN RETURN NEW;END IF;
 ELSE
  IF TG_TABLE_NAME='workshop_material_count_lines' AND incoming->>'derivation_source_line_id' IS NOT NULL THEN
   SELECT source.* INTO source_line FROM workshop_material_count_lines source
    JOIN workshop_material_counts previous ON previous.id=source.count_id AND previous.status='SUBMITTED'
    JOIN workshop_material_counts current ON current.id=NEW.count_id AND current.status='DRAFT'
      AND current.period_id=previous.period_id AND current.version>previous.version
    WHERE source.id=(incoming->>'derivation_source_line_id')::uuid;
   IF NOT FOUND OR (to_jsonb(source_line)-ARRAY['id','count_id','entered_by','entered_at','row_version','derivation_source_line_id','qty_base','derivation_version','derivation_precision_policy'])
      IS DISTINCT FROM (incoming-ARRAY['id','count_id','entered_by','entered_at','row_version','derivation_source_line_id','qty_base','derivation_version','derivation_precision_policy']) THEN
    RAISE EXCEPTION 'WM correction must copy a proven original count line unchanged' USING ERRCODE='23514';END IF;
   NEW:=jsonb_populate_record(NEW,jsonb_build_object('qty_base',source_line.qty_base,'derivation_version',source_line.derivation_version,'derivation_precision_policy',source_line.derivation_precision_policy));
   RETURN NEW;
  END IF;
  IF NEW.derivation_version<>2 OR NEW.derivation_precision_policy IS NOT NULL THEN
   RAISE EXCEPTION 'New WM source must use current operation provenance' USING ERRCODE='23514';END IF;
  IF incoming->>field IS NOT NULL AND (incoming->>field)::numeric<>0 THEN
   RAISE EXCEPTION 'New WM derived quantity must come from its real source' USING ERRCODE='23514';END IF;
 END IF;
 derived:=fn_workshop_material_derived_quantity(TG_TABLE_NAME,incoming,policy);
 NEW:=jsonb_populate_record(NEW,jsonb_build_object(field,derived,'derivation_version',2,'derivation_precision_policy',policy));
 RETURN NEW;
END $$;
DO $wm_quantity_families$
DECLARE table_name text; field text;
BEGIN
 FOREACH table_name IN ARRAY ARRAY['workshop_material_count_lines','workshop_material_period_lines','workshop_material_count_adjustment_postings'] LOOP
  field:=CASE table_name WHEN 'workshop_material_count_lines' THEN 'qty_base' WHEN 'workshop_material_period_lines' THEN 'actual_qty' ELSE 'signed_qty' END;
  EXECUTE format('ALTER TABLE %I ADD COLUMN derivation_version smallint NOT NULL DEFAULT 1 CHECK(derivation_version IN(1,2)), ADD COLUMN derivation_precision_policy jsonb',table_name);
  EXECUTE format('ALTER TABLE %I ALTER COLUMN derivation_version SET DEFAULT 2',table_name);
  EXECUTE format('CREATE TRIGGER trg_zz_wm_exact_derived_quantity BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_material_derived_quantity()',table_name);
  EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER trg_zz_wm_exact_derived_quantity',table_name);
  EXECUTE format('ALTER TABLE %I ADD CONSTRAINT wm_derived_quantity_precision CHECK(CASE WHEN derivation_version=1 THEN derivation_precision_policy IS NULL ELSE derivation_precision_policy IS NOT NULL AND derivation_precision_policy->>''version''=''1'' AND jsonb_typeof(derivation_precision_policy->''choices'')=''object'' AND %I IS NOT DISTINCT FROM fn_workshop_material_derived_quantity(%L,to_jsonb(%I.*),derivation_precision_policy) END)',table_name,field,table_name,table_name);
 END LOOP;
END; $wm_quantity_families$;
