-- Preserve all stored v1 facts. Only subsequent facts use exact arithmetic.
-- Shared exact division is the sole v2 arithmetic authority; ROUND4 is a
-- versioned historical proof, never a default for a newly created value.
CREATE FUNCTION fn_inventory_value_interval(p_value numeric,p_from numeric,p_to numeric,p_denominator numeric,
 p_version integer,p_policy jsonb,p_record_used boolean DEFAULT false) RETURNS numeric
LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog,public AS $$
DECLARE high numeric;low numeric;
BEGIN
 IF p_value IS NULL OR p_from IS NULL OR p_to IS NULL OR p_denominator IS NULL
 OR p_value::text IN('NaN','Infinity','-Infinity') OR p_from::text IN('NaN','Infinity','-Infinity')
 OR p_to::text IN('NaN','Infinity','-Infinity') OR p_denominator::text IN('NaN','Infinity','-Infinity')
 OR p_denominator<=0 OR p_from<0 OR p_to<p_from OR p_to>p_denominator THEN
  RAISE EXCEPTION 'Invalid frozen inventory value interval' USING ERRCODE='23514';END IF;
 IF p_version=1 AND p_policy IS NULL THEN
  RETURN (CASE WHEN p_to=p_denominator THEN p_value ELSE round(p_value*p_to/p_denominator,4) END)
       -(CASE WHEN p_from=0 THEN 0 ELSE round(p_value*p_from/p_denominator,4) END);
 END IF;
 IF p_version<>2 OR p_policy IS NULL OR p_policy->>'version'<>'1' OR jsonb_typeof(p_policy->'choices')<>'object' THEN
  RAISE EXCEPTION 'Inventory value precision proof is incomplete' USING ERRCODE='23514';END IF;
 IF p_from=p_to THEN RETURN 0;END IF;
 high:=CASE WHEN p_to=p_denominator THEN p_value ELSE fn_business_exact_divide_with_policy(
  p_value*p_to,p_denominator,'stock.value.interval','本次库存价值累计切片',30,p_policy,p_record_used) END;
 low:=CASE WHEN p_from=0 THEN 0 ELSE fn_business_exact_divide_with_policy(
  p_value*p_from,p_denominator,'stock.value.interval','本次库存价值累计切片',30,p_policy,p_record_used) END;
 IF abs(high)>abs(p_value) OR abs(low)>abs(p_value) OR abs(high-low)>abs(p_value)
  OR high-low<>0 AND sign(high-low)<>sign(p_value) THEN
  RAISE EXCEPTION 'UTEN_PRECISION_REQUIRED:%',jsonb_build_object('calculationKey','stock.value.interval','groupKey','stock.value.interval',
   'label','本次库存成本分配超过原来源预算，请重新选择','maxScale',30,'reason','PRECISION_LIMIT','selectionRejected',true,'notWritten',true)::text USING ERRCODE='22023';END IF;
 IF NOT fn_financial_book_amount_is_exact(high-low) THEN
  RAISE EXCEPTION 'Inventory value interval exceeds exact book storage' USING ERRCODE='22003';END IF;
 RETURN high-low;
END $$;

-- An already frozen choice wins. A later new allocation may supply a missing
-- purpose; it cannot reinterpret the policy of an existing allocation.
CREATE FUNCTION fn_inventory_value_extend_policy(p_frozen jsonb,p_current jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
 SELECT jsonb_build_object('version',1,'choices',coalesce(p_current->'choices','{}'::jsonb)||coalesce(p_frozen->'choices','{}'::jsonb))
$$;

DO $precision_columns$
DECLARE table_name text;
BEGIN
 FOREACH table_name IN ARRAY ARRAY['stock_value_nodes','stock_value_edges','stock_value_events','stock_value_tasks',
  'stock_value_node_revisions','stock_value_position_transfers','stock_value_production_cost_revisions','stock_value_production_cost_tasks'] LOOP
  EXECUTE format('ALTER TABLE %I ADD COLUMN value_precision_version smallint NOT NULL DEFAULT 1 CHECK(value_precision_version IN(1,2))',table_name);
  EXECUTE format('ALTER TABLE %I ALTER COLUMN value_precision_version SET DEFAULT 2',table_name);
  EXECUTE format('ALTER TABLE %I ADD COLUMN business_precision_policy jsonb',table_name);
  EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I CHECK((value_precision_version=1 AND business_precision_policy IS NULL) OR (value_precision_version=2 AND business_precision_policy IS NOT NULL AND business_precision_policy->>''version''=''1'' AND jsonb_typeof(business_precision_policy->''choices'')=''object''))',table_name,table_name||'_precision_proof');
 END LOOP;
END $precision_columns$;
ALTER TABLE stock_value_nodes ADD COLUMN precision_source_node_id uuid REFERENCES stock_value_nodes(id);

CREATE FUNCTION fn_inventory_value_node_interval(p_node uuid,p_value numeric,p_from numeric,p_to numeric,p_denominator numeric,
 p_new_allocation boolean DEFAULT false) RETURNS numeric LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog,public AS $$
DECLARE n stock_value_nodes%ROWTYPE; policy jsonb;
BEGIN
 SELECT * INTO STRICT n FROM stock_value_nodes WHERE id=p_node;
 policy:=n.business_precision_policy;
 IF n.revision>1 AND n.value_precision_version=2 THEN
  SELECT business_precision_policy INTO STRICT policy FROM stock_value_node_revisions WHERE node_id=n.id AND revision=n.revision;
 END IF;
 IF p_new_allocation AND n.value_precision_version=2 THEN policy:=fn_inventory_value_extend_policy(policy,fn_business_precision_snapshot());END IF;
 RETURN fn_inventory_value_interval(p_value,p_from,p_to,p_denominator,n.value_precision_version,policy,p_new_allocation);
END $$;

CREATE FUNCTION fn_inventory_value_edge_interval(p_edge uuid,p_value numeric,p_from numeric,p_to numeric,p_denominator numeric,
 p_event uuid DEFAULT NULL) RETURNS numeric LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog,public AS $$
DECLARE e stock_value_edges%ROWTYPE;policy jsonb;event_policy jsonb;
BEGIN
 SELECT * INTO STRICT e FROM stock_value_edges WHERE id=p_edge;policy:=e.business_precision_policy;
 IF p_event IS NOT NULL AND e.value_precision_version=2 THEN
  SELECT business_precision_policy INTO STRICT event_policy FROM stock_value_events WHERE id=p_event;
  policy:=fn_inventory_value_extend_policy(policy,event_policy);
 END IF;
 RETURN fn_inventory_value_interval(p_value,p_from,p_to,p_denominator,e.value_precision_version,policy,false);
END $$;

CREATE FUNCTION fn_guard_inventory_value_precision() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE parent_version smallint;parent_policy jsonb;policy jsonb:=fn_business_precision_snapshot();version smallint:=2;
BEGIN
 IF TG_OP<>'INSERT' THEN
  IF NEW.value_precision_version IS DISTINCT FROM OLD.value_precision_version OR NEW.business_precision_policy IS DISTINCT FROM OLD.business_precision_policy THEN
   RAISE EXCEPTION 'Frozen inventory value precision proof is immutable' USING ERRCODE='55000';END IF;
  RETURN NEW;
 END IF;
 CASE TG_TABLE_NAME
 WHEN 'stock_value_nodes' THEN
  IF NEW.root_issue_id IS NOT NULL AND NEW.root_issue_id<>NEW.id AND NEW.kind IN('ISSUE_POSITION','COST_RETURN_CURSOR','RETURN_SOURCE') THEN
   IF NEW.precision_source_node_id IS NULL THEN RAISE EXCEPTION 'Inherited inventory precision requires its original source node' USING ERRCODE='23514';END IF;
   SELECT n.value_precision_version,coalesce(r.business_precision_policy,n.business_precision_policy) INTO STRICT parent_version,parent_policy
    FROM stock_value_nodes n LEFT JOIN stock_value_node_revisions r ON r.node_id=n.id AND r.revision=n.revision
    WHERE n.id=NEW.precision_source_node_id AND coalesce(n.root_issue_id,n.id)=NEW.root_issue_id;
  END IF;
 WHEN 'stock_value_edges' THEN
  SELECT value_precision_version,business_precision_policy INTO parent_version,parent_policy FROM stock_value_nodes WHERE id=NEW.parent_node_id AND kind IN('ISSUE_POSITION','COST_RETURN_CURSOR');
 WHEN 'stock_value_position_transfers' THEN
  IF NEW.reversal_of_transfer_id IS NOT NULL THEN
   SELECT value_precision_version,business_precision_policy INTO STRICT parent_version,parent_policy FROM stock_value_position_transfers WHERE id=NEW.reversal_of_transfer_id;
  ELSE SELECT value_precision_version,business_precision_policy INTO STRICT parent_version,parent_policy FROM stock_value_nodes WHERE id=NEW.source_node_id;END IF;
 WHEN 'stock_value_tasks' THEN
  SELECT e.value_precision_version,fn_inventory_value_extend_policy(e.business_precision_policy,v.business_precision_policy)
   INTO STRICT parent_version,parent_policy FROM stock_value_edges e JOIN stock_value_events v ON v.id=NEW.event_id WHERE e.id=NEW.edge_id;
 WHEN 'stock_value_node_revisions' THEN
  SELECT value_precision_version,business_precision_policy INTO STRICT parent_version,parent_policy FROM stock_value_nodes WHERE id=NEW.node_id;
  IF NEW.task_id IS NOT NULL THEN SELECT business_precision_policy INTO policy FROM stock_value_tasks WHERE id=NEW.task_id;END IF;
 WHEN 'stock_value_production_cost_tasks' THEN
  SELECT value_precision_version,business_precision_policy INTO STRICT parent_version,parent_policy FROM stock_value_production_cost_revisions WHERE id=NEW.revision_id;
 WHEN 'stock_value_events' THEN
  IF NEW.reversal_of_event_id IS NOT NULL THEN
   SELECT value_precision_version,business_precision_policy INTO STRICT parent_version,parent_policy FROM stock_value_events WHERE id=NEW.reversal_of_event_id;
  ELSIF NEW.position_store_reversal_of IS NOT NULL THEN
   SELECT value_precision_version,business_precision_policy INTO STRICT parent_version,parent_policy FROM stock_value_events WHERE id=NEW.position_store_reversal_of;
  ELSIF NEW.operation='RETURN_ISSUE' THEN
   SELECT value_precision_version,business_precision_policy INTO STRICT parent_version,parent_policy FROM stock_value_nodes WHERE id=NEW.result_node_id;
  ELSIF NEW.operation='CONSUMPTION_RETURN' THEN
   SELECT value_precision_version,business_precision_policy INTO STRICT parent_version,parent_policy FROM stock_value_nodes WHERE id=NEW.result_head_id;
  END IF;
 ELSE NULL;
 END CASE;
 IF parent_version IS NOT NULL THEN
  version:=parent_version;
  policy:=CASE WHEN version=1 THEN NULL ELSE fn_inventory_value_extend_policy(parent_policy,policy) END;
 END IF;
 NEW.value_precision_version:=version;NEW.business_precision_policy:=policy;RETURN NEW;
END $$;
DO $precision_triggers$
DECLARE table_name text;
BEGIN
 FOREACH table_name IN ARRAY ARRAY['stock_value_nodes','stock_value_edges','stock_value_events','stock_value_tasks',
  'stock_value_node_revisions','stock_value_position_transfers','stock_value_production_cost_revisions','stock_value_production_cost_tasks'] LOOP
  EXECUTE format('CREATE TRIGGER trg_00_inventory_value_precision BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION fn_guard_inventory_value_precision()',table_name);
  EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER trg_00_inventory_value_precision',table_name);
 END LOOP;
END $precision_triggers$;

-- DROP EXPRESSION keeps the existing stored values byte-for-byte. The single
-- widening utility retains the full dependent-view graph, guards and ACLs.
ALTER TABLE stock_value_nodes ALTER COLUMN owned_value_local DROP EXPRESSION;
ALTER TABLE goods_bom_actual_usages ALTER COLUMN actual_qty DROP EXPRESSION;
ALTER TABLE subcontract_material_issue_items ALTER COLUMN supplier_ending DROP EXPRESSION;
SELECT fn_migrate_financial_amount_columns('[
 {"table":"stock_value_nodes","column":"quantity_basis","kind":"actual"},
 {"table":"stock_value_nodes","column":"range_from","kind":"actual"},
 {"table":"stock_value_nodes","column":"range_to","kind":"actual"},
 {"table":"stock_value_nodes","column":"returned_consumption_qty","kind":"actual"},
 {"table":"stock_value_nodes","column":"owned_value_local","kind":"book"},
 {"table":"goods_bom_actual_usages","column":"net_qty","kind":"actual"},
 {"table":"goods_bom_actual_usages","column":"exposure_output_qty","kind":"actual"},
 {"table":"goods_bom_actual_usages","column":"baseline_net_qty","kind":"actual"},
 {"table":"goods_bom_actual_usages","column":"baseline_exposure_output_qty","kind":"actual"},
 {"table":"goods_bom_actual_usages","column":"actual_qty","kind":"actual"},
 {"table":"subcontract_material_issue_items","column":"returned_qty","kind":"actual"},
 {"table":"subcontract_material_issue_items","column":"wasted_qty","kind":"actual"},
 {"table":"subcontract_material_issue_items","column":"at_supplier_qty","kind":"actual"},
 {"table":"subcontract_material_issue_items","column":"consumed_qty","kind":"actual"},
 {"table":"subcontract_material_issue_items","column":"compensated_qty","kind":"actual"},
 {"table":"subcontract_material_issue_items","column":"supplier_ending","kind":"actual"}
]'::jsonb);

CREATE FUNCTION fn_inventory_value_owned(p_row stock_value_nodes) RETURNS numeric LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog,public AS $$
DECLARE policy jsonb:=p_row.business_precision_policy;returned numeric:=0;
BEGIN
 IF NOT p_row.active THEN RETURN 0;END IF;
 IF p_row.kind='POOL' THEN RETURN p_row.basis_value_local;END IF;
 IF p_row.kind<>'ISSUE_POSITION' THEN RETURN 0;END IF;
 IF p_row.revision>1 AND p_row.value_precision_version=2 THEN
  SELECT business_precision_policy INTO STRICT policy FROM stock_value_node_revisions WHERE node_id=p_row.id AND revision=p_row.revision;
 END IF;
 IF p_row.returned_consumption_qty>0 THEN
  IF p_row.value_precision_version=2 AND p_row.consumption_return_head_id IS NOT NULL THEN
   SELECT business_precision_policy INTO STRICT policy FROM stock_value_nodes WHERE id=p_row.consumption_return_head_id;
  END IF;
  returned:=fn_inventory_value_interval(p_row.basis_value_local,0,p_row.returned_consumption_qty,p_row.quantity_basis,p_row.value_precision_version,policy,false);
 END IF;
 RETURN fn_inventory_value_interval(p_row.basis_value_local,p_row.range_from,p_row.range_to,p_row.quantity_basis,p_row.value_precision_version,policy,false)
  -p_row.distributed_value_local-returned;
END $$;
CREATE FUNCTION fn_guard_inventory_value_owned() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE source_changed boolean:=true;
BEGIN
 IF TG_OP='UPDATE' THEN
  source_changed:=(to_jsonb(NEW)-ARRAY['owned_value_local','updated_at']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['owned_value_local','updated_at']);
  IF NOT source_changed THEN
   IF NEW.owned_value_local IS DISTINCT FROM OLD.owned_value_local THEN RAISE EXCEPTION 'Inventory owned value requires its original sources' USING ERRCODE='55000';END IF;
   RETURN NEW;
  END IF;
 END IF;
 NEW.owned_value_local:=fn_inventory_value_owned(NEW);RETURN NEW;
END $$;
CREATE TRIGGER trg_zz_inventory_value_owned BEFORE INSERT OR UPDATE ON stock_value_nodes FOR EACH ROW EXECUTE FUNCTION fn_guard_inventory_value_owned();
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_zz_inventory_value_owned;

DO $source_versions$
DECLARE table_name text;
BEGIN
 FOREACH table_name IN ARRAY ARRAY['goods_bom_actual_usages','subcontract_material_issue_items'] LOOP
  EXECUTE format('ALTER TABLE %I ADD COLUMN numeric_derivation_version smallint NOT NULL DEFAULT 1 CHECK(numeric_derivation_version IN(1,2))',table_name);
  EXECUTE format('ALTER TABLE %I ALTER COLUMN numeric_derivation_version SET DEFAULT 2',table_name);
  EXECUTE format('ALTER TABLE %I ADD COLUMN numeric_derivation_policy jsonb',table_name);
 END LOOP;
END $source_versions$;
CREATE FUNCTION fn_inventory_source_derived_numeric(p_table text,p_row jsonb,p_policy jsonb) RETURNS numeric
LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog,public AS $$
DECLARE v numeric;n numeric;d numeric;
BEGIN
 IF p_table='goods_bom_actual_usages' THEN
  n:=(p_row->>'net_qty')::numeric-(p_row->>'baseline_net_qty')::numeric;
  d:=(p_row->>'exposure_output_qty')::numeric-(p_row->>'baseline_exposure_output_qty')::numeric;
  IF n<=0 OR d<=0 THEN RETURN NULL;END IF;
  v:=fn_business_exact_divide_with_policy(n,d,'goods.bom.actual-usage','本次BOM实际单耗',24,p_policy,true);
 ELSIF p_table='subcontract_material_issue_items' THEN
  v:=(p_row->>'at_supplier_qty')::numeric+(p_row->>'compensated_qty')::numeric-(p_row->>'consumed_qty')::numeric
   -coalesce((p_row->>'returned_qty')::numeric,0)-coalesce((p_row->>'wasted_qty')::numeric,0);
 ELSE RAISE EXCEPTION 'Unknown inventory numeric source family' USING ERRCODE='22023';END IF;
 IF v IS NOT NULL AND NOT fn_financial_amount_is_exact(v) THEN RAISE EXCEPTION 'Inventory derived quantity exceeds exact storage' USING ERRCODE='22003';END IF;
 RETURN v;
END $$;
CREATE FUNCTION fn_guard_inventory_source_derived_numeric() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE keys text[];field text;old_source jsonb;new_source jsonb;policy jsonb:=fn_business_precision_snapshot();value numeric;
BEGIN
 IF TG_TABLE_NAME='goods_bom_actual_usages' THEN keys:=ARRAY['net_qty','exposure_output_qty','baseline_net_qty','baseline_exposure_output_qty'];field:='actual_qty';
 ELSE keys:=ARRAY['at_supplier_qty','compensated_qty','consumed_qty','returned_qty','wasted_qty'];field:='supplier_ending';END IF;
 SELECT jsonb_object_agg(key,to_jsonb(NEW)->key) INTO new_source FROM unnest(keys) key;
 IF TG_OP='UPDATE' THEN
  SELECT jsonb_object_agg(key,to_jsonb(OLD)->key) INTO old_source FROM unnest(keys) key;
  IF new_source IS NOT DISTINCT FROM old_source THEN
   IF (to_jsonb(NEW)->field) IS DISTINCT FROM (to_jsonb(OLD)->field)
    OR NEW.numeric_derivation_version IS DISTINCT FROM OLD.numeric_derivation_version OR NEW.numeric_derivation_policy IS DISTINCT FROM OLD.numeric_derivation_policy THEN
    RAISE EXCEPTION 'Derived inventory numeric facts require an actual source change' USING ERRCODE='55000';END IF;
   RETURN NEW;
  END IF;
 END IF;
 IF EXISTS(SELECT 1 FROM jsonb_each_text(new_source) item WHERE item.value IS NOT NULL AND NOT fn_financial_amount_is_exact(item.value::numeric)) THEN
  RAISE EXCEPTION 'Inventory source quantity must be finite and exactly supported' USING ERRCODE='22003';END IF;
 value:=fn_inventory_source_derived_numeric(TG_TABLE_NAME,to_jsonb(NEW),policy);
 NEW:=jsonb_populate_record(NEW,jsonb_build_object(field,value,'numeric_derivation_version',2,'numeric_derivation_policy',policy));RETURN NEW;
END $$;
DO $source_derivation_triggers$
DECLARE table_name text;
BEGIN
 FOREACH table_name IN ARRAY ARRAY['goods_bom_actual_usages','subcontract_material_issue_items'] LOOP
  EXECUTE format('CREATE TRIGGER trg_zz_inventory_source_derived_numeric BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION fn_guard_inventory_source_derived_numeric()',table_name);
  EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER trg_zz_inventory_source_derived_numeric',table_name);
 END LOOP;
END $source_derivation_triggers$;

CREATE FUNCTION fn_inventory_value_revision_interval(p_node uuid,p_revision bigint,p_value numeric,p_from numeric,p_to numeric,p_denominator numeric)
RETURNS numeric LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog,public AS $$
DECLARE version integer;policy jsonb;
BEGIN
 IF p_revision=1 THEN SELECT value_precision_version,business_precision_policy INTO STRICT version,policy FROM stock_value_nodes WHERE id=p_node;
 ELSE SELECT value_precision_version,business_precision_policy INTO STRICT version,policy FROM stock_value_node_revisions WHERE node_id=p_node AND revision=p_revision;END IF;
 RETURN fn_inventory_value_interval(p_value,p_from,p_to,p_denominator,version,policy,false);
END $$;

-- Replace only the four expressions observed in the installed current catalog.
-- The encompassing source/owner/quantity/receipt/version assertions remain intact.
DO $inventory_value_current_proofs$
DECLARE definition text;needle text;replacement text;item record;
BEGIN
 FOR item IN SELECT * FROM (VALUES
  ('fn_is_workshop_material_value_store',
   'movement.qty=round(item.qty*COALESCE(item.unit_rate,1),4)',
   'movement.qty=CASE WHEN event.value_precision_version=1 THEN round(item.qty*COALESCE(item.unit_rate,1),4) ELSE fn_business_exact_divide_with_policy(item.qty*COALESCE(item.unit_rate,1),1,''quantity.to-base'',''本次数量换算基本量'',24,event.business_precision_policy,false) END AND movement.qty=(SELECT sum(actual.qty_base) FROM stock_value_position_transfers actual WHERE actual.event_id=event.id)'),
  ('fn_check_stock_value_position_transfer',
   'round(original_value*NEW.range_to/NEW.quantity_basis,4)-round(original_value*NEW.range_from/NEW.quantity_basis,4)',
   'fn_inventory_value_interval(original_value,NEW.range_from,NEW.range_to,NEW.quantity_basis,NEW.value_precision_version,NEW.business_precision_policy,false)'),
  ('fn_check_stock_value_reverse_transfer',
   'round(source_value*NEW.range_to/NEW.quantity_basis,4)-round(source_value*NEW.range_from/NEW.quantity_basis,4)',
   'fn_inventory_value_interval(source_value,NEW.range_from,NEW.range_to,NEW.quantity_basis,original.value_precision_version,original.business_precision_policy,false)'),
  ('fn_assert_consumption_return',
   E'round(source.basis_value_local*(e.qty_before+e.qty_base)/source.quantity_basis,4)\n        -round(source.basis_value_local*e.qty_before/source.quantity_basis,4)',
   'fn_inventory_value_interval(source.basis_value_local,e.qty_before,e.qty_before+e.qty_base,source.quantity_basis,cursor.value_precision_version,cursor.business_precision_policy,false)'),
  ('fn_check_stock_value_cost_task_plan',
   'round(NEW.input_value_local*(NEW.input_quantity_basis-NEW.input_returned_qty)*NEW.output_to/(NEW.denominator*NEW.input_quantity_basis),4)-round(NEW.input_value_local*(NEW.input_quantity_basis-NEW.input_returned_qty)*NEW.output_from/(NEW.denominator*NEW.input_quantity_basis),4)',
   'fn_inventory_value_interval(NEW.input_value_local,NEW.output_from*(NEW.input_quantity_basis-NEW.input_returned_qty),NEW.output_to*(NEW.input_quantity_basis-NEW.input_returned_qty),NEW.denominator*NEW.input_quantity_basis,NEW.value_precision_version,NEW.business_precision_policy,false)')
 ) patch(name,needle,replacement) LOOP
  SELECT replace(pg_get_functiondef(proc.oid),E'\r','') INTO STRICT definition FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
   WHERE namespace.nspname='public' AND proc.proname=item.name;
  IF position(item.needle IN definition)=0 THEN RAISE EXCEPTION 'Review current inventory precision proof % before migration',item.name;END IF;
  EXECUTE replace(definition,item.needle,item.replacement);
 END LOOP;
END $inventory_value_current_proofs$;

CREATE FUNCTION fn_guard_inventory_value_edge_amount() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE value numeric;version integer:=NEW.value_precision_version;policy jsonb:=NEW.business_precision_policy;expected numeric;task stock_value_tasks%ROWTYPE;
BEGIN
 IF TG_OP='UPDATE' THEN
  IF NEW.last_parent_revision=OLD.last_parent_revision AND NEW.allocated_amount_local=OLD.allocated_amount_local THEN RETURN NEW;END IF;
  SELECT * INTO STRICT task FROM stock_value_tasks WHERE edge_id=NEW.id AND parent_revision=NEW.last_parent_revision;
  version:=task.value_precision_version;policy:=task.business_precision_policy;
 END IF;
 IF NEW.last_parent_revision=1 THEN SELECT initial_known_value INTO STRICT value FROM stock_value_nodes WHERE id=NEW.parent_node_id;
 ELSE SELECT after_value INTO STRICT value FROM stock_value_node_revisions WHERE node_id=NEW.parent_node_id AND revision=NEW.last_parent_revision;END IF;
 expected:=fn_inventory_value_interval(value,NEW.interval_from,NEW.interval_to,NEW.denominator,version,policy,false);
 IF NEW.allocated_amount_local IS DISTINCT FROM expected OR (TG_OP='INSERT' AND NEW.initial_allocated_amount IS DISTINCT FROM expected) THEN
  RAISE EXCEPTION 'Inventory value edge must retain its exact frozen cumulative allocation' USING ERRCODE='23514';END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_01_inventory_value_edge_amount BEFORE INSERT OR UPDATE ON stock_value_edges FOR EACH ROW EXECUTE FUNCTION fn_guard_inventory_value_edge_amount();
ALTER TABLE stock_value_edges ENABLE ALWAYS TRIGGER trg_01_inventory_value_edge_amount;

CREATE FUNCTION fn_check_inventory_value_precision_source() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
 IF NEW.precision_source_node_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM stock_value_edges edge
  WHERE edge.child_node_id=NEW.id AND edge.parent_node_id=NEW.precision_source_node_id AND edge.creation_event_id=NEW.creation_event_id) THEN
  RAISE EXCEPTION 'Inherited inventory precision must retain its same-operation original edge' USING ERRCODE='23514';END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_inventory_value_precision_source AFTER INSERT ON stock_value_nodes
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_inventory_value_precision_source();
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_inventory_value_precision_source;

CREATE FUNCTION fn_guard_inventory_value_cost_snapshot() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE item jsonb;n stock_value_nodes%ROWTYPE;actual numeric;
BEGIN
 FOR item IN SELECT value FROM jsonb_array_elements(NEW.input_snapshot) LOOP
  SELECT * INTO STRICT n FROM stock_value_nodes WHERE id=(item->>'node')::uuid;
  actual:=fn_inventory_value_owned(n)+n.distributed_value_local;
  IF (item->>'revision')::bigint IS DISTINCT FROM n.revision OR (item->>'valuePrecisionVersion')::integer IS DISTINCT FROM (fn_inventory_value_current_projection(n)->>'version')::integer
    OR (item->>'bookedNetValue')::numeric IS DISTINCT FROM actual THEN
   RAISE EXCEPTION 'New production cost snapshot must retain the actual original booked net value' USING ERRCODE='23514';END IF;
 END LOOP;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_01_inventory_value_cost_snapshot BEFORE INSERT ON stock_value_production_cost_revisions FOR EACH ROW EXECUTE FUNCTION fn_guard_inventory_value_cost_snapshot();
ALTER TABLE stock_value_production_cost_revisions ENABLE ALWAYS TRIGGER trg_01_inventory_value_cost_snapshot;

-- Whole-target revaluation proof and bounded existing-work coordination.
-- Extend the existing durable work protocol. These fields contain coordination
-- keys only; nodes/events/revisions remain the sole quantity/value authority.
ALTER TABLE stock_value_jobs ADD COLUMN precision_closure_keys text[];
ALTER TABLE stock_value_jobs ADD COLUMN precision_closure_complete boolean NOT NULL DEFAULT true;
ALTER TABLE stock_value_jobs ALTER COLUMN precision_closure_complete SET DEFAULT false;
ALTER TABLE stock_value_jobs ADD COLUMN precision_origin_id uuid;
ALTER TABLE stock_value_jobs ADD COLUMN precision_created_txid bigint;
ALTER TABLE stock_value_jobs ALTER COLUMN precision_created_txid SET DEFAULT txid_current();
ALTER TABLE stock_value_production_cost_revisions ADD COLUMN precision_closure_keys text[];
ALTER TABLE stock_value_production_cost_revisions ADD COLUMN precision_closure_nodes uuid[];
ALTER TABLE stock_value_production_cost_revisions ADD COLUMN request_precision_policy jsonb;
ALTER TABLE stock_value_production_cost_revisions ADD COLUMN precision_origin_id uuid;
ALTER TABLE stock_value_production_cost_revisions ADD COLUMN precision_created_txid bigint;
ALTER TABLE stock_value_production_cost_revisions ALTER COLUMN precision_created_txid SET DEFAULT txid_current();
ALTER TABLE stock_value_production_cost_objects ADD COLUMN precision_closure_keys text[];
ALTER TABLE stock_value_production_cost_objects ADD COLUMN precision_closure_pending boolean NOT NULL DEFAULT false;
ALTER TABLE stock_value_production_cost_objects ADD COLUMN precision_closure_complete boolean NOT NULL DEFAULT true;
ALTER TABLE stock_value_production_cost_objects ADD COLUMN precision_origin_id uuid;
ALTER TABLE stock_value_production_cost_objects ADD COLUMN precision_work_txid bigint;
ALTER TABLE stock_value_production_cost_objects ADD COLUMN business_refresh_precision_version smallint NOT NULL DEFAULT 1;
ALTER TABLE stock_value_production_cost_objects ALTER COLUMN business_refresh_precision_version SET DEFAULT 2;
ALTER TABLE stock_value_production_cost_objects ADD COLUMN business_refresh_precision_policy jsonb;
ALTER TABLE stock_value_production_cost_objects ADD COLUMN business_refresh_precision_root_id uuid;
ALTER TABLE stock_value_production_cost_objects ADD COLUMN precision_forecast_hash text;
ALTER TABLE stock_value_production_cost_objects ADD COLUMN precision_input_ancestor_nodes uuid[];
ALTER TABLE stock_value_jobs ADD COLUMN precision_protocol_version smallint;
ALTER TABLE stock_value_jobs ADD COLUMN precision_forecast_hash text;
CREATE INDEX idx_stock_value_precision_job_keys ON stock_value_jobs USING gin(precision_closure_keys) WHERE NOT precision_closure_complete;
CREATE INDEX idx_stock_value_precision_object_keys ON stock_value_production_cost_objects USING gin(precision_closure_keys) WHERE precision_closure_pending;


-- The null color is a real inventory dimension.
CREATE FUNCTION fn_inventory_value_precision_key(p_goods uuid,p_color uuid) RETURNS text LANGUAGE sql IMMUTABLE AS $$
 SELECT p_goods::text||':'||coalesce(p_color::text,'-')
$$;
CREATE FUNCTION fn_inventory_value_try_precision_claim(p_key text) RETURNS void LANGUAGE plpgsql VOLATILE AS $$
BEGIN
 IF p_key IS NULL OR length(p_key)>80 OR NOT pg_try_advisory_xact_lock(hashtextextended(p_key,4702466952845812001)) THEN
  RAISE EXCEPTION '库存成本来源正在核对，请保留原单稍后重试；本次未确认'
   USING ERRCODE='40001',CONSTRAINT='stock_value_precision_scope_busy';END IF;
END $$;

CREATE FUNCTION fn_inventory_value_precision_successors(p_node uuid) RETURNS TABLE(node_id uuid) LANGUAGE sql STABLE AS $$
 SELECT child_node_id FROM stock_value_edges WHERE parent_node_id=p_node
 UNION SELECT output.source_node_id FROM stock_value_production_cost_inputs input
 JOIN stock_value_production_cost_outputs output USING(execution_segment_id) WHERE input.input_node_id=p_node
 UNION SELECT output.source_node_id FROM v_production_cost_input_candidates candidate
 JOIN stock_value_production_cost_objects object ON object.execution_segment_id=fn_production_execution_cost_scope(candidate.member_segment_id)
 JOIN stock_value_production_cost_outputs output USING(execution_segment_id)
 WHERE candidate.result_node_id=p_node AND candidate.node_active AND object.business_refresh_pending
  AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_inputs registered WHERE registered.approved_posting_id=candidate.approved_posting_id)
$$;
CREATE FUNCTION fn_inventory_value_precision_predecessors(p_node uuid) RETURNS TABLE(node_id uuid) LANGUAGE sql STABLE AS $$
 SELECT parent_node_id FROM stock_value_edges WHERE child_node_id=p_node
 UNION SELECT input.input_node_id FROM stock_value_production_cost_outputs output
 JOIN stock_value_production_cost_inputs input USING(execution_segment_id) WHERE output.source_node_id=p_node
 UNION SELECT candidate.result_node_id FROM stock_value_production_cost_outputs output
 JOIN stock_value_production_cost_objects object USING(execution_segment_id)
 JOIN v_production_cost_input_candidates candidate ON object.execution_segment_id=fn_production_execution_cost_scope(candidate.member_segment_id)
 WHERE output.source_node_id=p_node AND candidate.node_active AND object.business_refresh_pending
  AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_inputs registered WHERE registered.approved_posting_id=candidate.approved_posting_id)
$$;
CREATE FUNCTION fn_inventory_value_precision_scope(p_seeds uuid[]) RETURNS uuid[] LANGUAGE plpgsql STABLE AS $$
DECLARE nodes uuid[];
BEGIN
 WITH RECURSIVE descendants(id) AS (
  SELECT unnest(p_seeds) UNION SELECT next.node_id FROM descendants parent
   CROSS JOIN LATERAL fn_inventory_value_precision_successors(parent.id) next
 ),ancestors(id) AS (
  SELECT id FROM descendants UNION SELECT prior.node_id FROM ancestors child
   CROSS JOIN LATERAL fn_inventory_value_precision_predecessors(child.id) prior
 ) SELECT array_agg(id ORDER BY id) INTO nodes FROM (SELECT id FROM ancestors LIMIT 50001) bounded;
 IF nodes IS NULL OR cardinality(nodes)>50000 THEN
  RAISE EXCEPTION '来源成本后继超过本次可核对范围，请保留原单核对；本次未确认'
   USING ERRCODE='40001',CONSTRAINT='stock_value_precision_scope_limit';END IF;
 RETURN nodes;
END $$;

CREATE FUNCTION fn_inventory_value_root_incomplete(p_root uuid) RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE v_complete boolean;v_owner uuid;v_current uuid;
BEGIN
 SELECT precision_closure_complete INTO v_complete FROM stock_value_jobs WHERE event_id=p_root;
 IF FOUND THEN RETURN NOT v_complete;END IF;
 SELECT execution_segment_id INTO v_owner FROM stock_value_production_cost_revisions WHERE id=p_root;
 IF NOT FOUND THEN RETURN false;END IF;
 SELECT precision_closure_complete,precision_origin_id INTO v_complete,v_current FROM stock_value_production_cost_objects WHERE execution_segment_id=v_owner;
 RETURN v_current=p_root AND NOT v_complete;
END $$;
CREATE FUNCTION fn_inventory_value_precision_marked(p_keys text[],p_origin uuid DEFAULT NULL) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM stock_value_jobs job WHERE NOT job.precision_closure_complete
   AND job.precision_closure_keys&&p_keys AND job.precision_created_txid IS DISTINCT FROM txid_current()
   AND (p_origin IS NULL OR job.precision_origin_id IS DISTINCT FROM p_origin))
 OR EXISTS(SELECT 1 FROM stock_value_production_cost_objects object WHERE object.precision_closure_pending
   AND object.precision_closure_keys&&p_keys AND object.precision_work_txid IS DISTINCT FROM txid_current()
   AND (p_origin IS NULL OR object.precision_origin_id IS DISTINCT FROM p_origin) AND fn_inventory_value_root_incomplete(object.precision_origin_id))
$$;

-- Applied monetary points are separate from the original immutable quantities.
-- Keep the actual old point; do not calculate it again using a new choice.
ALTER TABLE stock_value_nodes ADD COLUMN range_from_value_local numeric;
ALTER TABLE stock_value_nodes ADD COLUMN range_to_value_local numeric;
ALTER TABLE stock_value_nodes ADD COLUMN returned_value_local numeric;
ALTER TABLE stock_value_node_revisions ADD COLUMN before_projection jsonb;
ALTER TABLE stock_value_node_revisions ADD COLUMN after_projection jsonb;
ALTER TABLE stock_value_tasks ADD COLUMN before_allocated_amount_local numeric;
ALTER TABLE stock_value_tasks ADD COLUMN before_pending_contribution boolean;
ALTER TABLE stock_value_tasks ADD COLUMN parent_before_value numeric;
ALTER TABLE stock_value_tasks ADD COLUMN parent_after_value numeric;
ALTER TABLE stock_value_tasks ADD COLUMN before_precision_version smallint;
ALTER TABLE stock_value_tasks ADD COLUMN before_precision_policy jsonb;
ALTER TABLE stock_value_tasks ADD COLUMN restores_task_id uuid REFERENCES stock_value_tasks(id);
ALTER TABLE stock_value_edges ADD COLUMN applied_precision_version smallint;
ALTER TABLE stock_value_edges ADD COLUMN applied_precision_policy jsonb;
ALTER TABLE stock_value_edges ADD COLUMN restores_transfer_id uuid REFERENCES stock_value_position_transfers(id);
ALTER TABLE stock_value_position_transfers ADD COLUMN source_projection jsonb;
ALTER TABLE stock_value_position_transfers ADD COLUMN from_value_local numeric;
ALTER TABLE stock_value_position_transfers ADD COLUMN to_value_local numeric;
ALTER TABLE stock_value_events ADD COLUMN projection_restore_of_event_id uuid REFERENCES stock_value_events(id);
ALTER TABLE stock_value_events ADD COLUMN valuation_root_id uuid;
ALTER TABLE stock_value_events ADD COLUMN valuation_root_kind text;
ALTER TABLE stock_value_production_cost_revisions ADD COLUMN restores_revision_id uuid REFERENCES stock_value_production_cost_revisions(id);
ALTER TABLE stock_value_production_cost_tasks ADD COLUMN restores_task_id uuid REFERENCES stock_value_production_cost_tasks(id);
ALTER TABLE stock_value_production_cost_tasks ADD COLUMN target_proof jsonb;
ALTER TABLE stock_value_production_cost_tasks ADD COLUMN before_precision_version smallint;
ALTER TABLE stock_value_production_cost_tasks ADD COLUMN before_precision_policy jsonb;
ALTER TABLE stock_value_jobs ADD COLUMN precision_closure_nodes uuid[];
ALTER TABLE stock_value_production_cost_objects ADD COLUMN precision_closure_nodes uuid[];
CREATE INDEX idx_stock_value_precision_job_nodes ON stock_value_jobs USING gin(precision_closure_nodes) WHERE NOT precision_closure_complete;
CREATE INDEX idx_stock_value_precision_object_nodes ON stock_value_production_cost_objects USING gin(precision_closure_nodes) WHERE precision_closure_pending;

CREATE FUNCTION fn_inventory_value_projection_inputs(p_node stock_value_nodes) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
 SELECT jsonb_build_object('kind',p_node.kind,'quantity',p_node.quantity_basis,'from',p_node.range_from,'to',p_node.range_to,
  'active',p_node.active,'distributed',p_node.distributed_value_local,'returnedQuantity',p_node.returned_consumption_qty)
$$;
CREATE FUNCTION fn_inventory_value_current_projection(p_node stock_value_nodes) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE low numeric:=p_node.range_from_value_local;high numeric:=p_node.range_to_value_local;returned numeric:=p_node.returned_value_local;
 version integer:=p_node.value_precision_version;policy jsonb:=p_node.business_precision_policy;
BEGIN
 IF p_node.revision>1 THEN SELECT value_precision_version,business_precision_policy INTO STRICT version,policy
  FROM stock_value_node_revisions WHERE node_id=p_node.id AND revision=p_node.revision;END IF;
 IF returned IS NULL THEN
  IF p_node.returned_consumption_qty=0 THEN returned:=0;
  ELSE SELECT coalesce(sum(target.basis_value_local),0) INTO returned FROM stock_value_events event
   JOIN stock_value_nodes target ON target.id=event.result_node_id WHERE event.operation='CONSUMPTION_RETURN' AND event.source_node_id=p_node.id;END IF;
 END IF;
 IF low IS NULL OR high IS NULL THEN
  IF p_node.kind='POOL' THEN low:=0;high:=p_node.basis_value_local;
  ELSIF p_node.kind IN('ISSUE_POSITION','COST_RETURN_CURSOR') THEN
   high:=CASE WHEN p_node.range_to=p_node.quantity_basis THEN p_node.basis_value_local
       ELSE fn_inventory_value_interval(p_node.basis_value_local,0,p_node.range_to,p_node.quantity_basis,version,policy,false) END;
   IF p_node.range_from=0 THEN low:=0;
   ELSIF p_node.active AND p_node.kind='ISSUE_POSITION' THEN
    low:=high-p_node.owned_value_local-p_node.distributed_value_local-returned;
   ELSE low:=fn_inventory_value_interval(p_node.basis_value_local,0,p_node.range_from,p_node.quantity_basis,version,policy,false);END IF;
  ELSE low:=0;high:=0;END IF;
 END IF;
 RETURN jsonb_build_object('basis',p_node.basis_value_local,'inputs',fn_inventory_value_projection_inputs(p_node),
  'fromValue',low,'toValue',high,'returnedValue',returned,'ownedValue',p_node.owned_value_local,
  'version',version,'policy',policy);
END $$;

CREATE FUNCTION fn_inventory_value_after_projection(p_node stock_value_nodes,p_value numeric,p_version integer,p_policy jsonb) RETURNS jsonb
LANGUAGE plpgsql VOLATILE AS $$
DECLARE low numeric:=0;high numeric:=0;returned numeric:=0;owned numeric:=0;
BEGIN
 IF p_node.kind='POOL' THEN high:=p_value;IF p_node.active THEN owned:=p_value;END IF;
 ELSIF p_node.kind IN('ISSUE_POSITION','COST_RETURN_CURSOR') THEN
  high:=CASE WHEN p_node.range_to=p_node.quantity_basis THEN p_value ELSE fn_inventory_value_interval(p_value,0,p_node.range_to,p_node.quantity_basis,p_version,p_policy,true) END;
  low:=CASE WHEN p_node.range_from=0 THEN 0 ELSE fn_inventory_value_interval(p_value,0,p_node.range_from,p_node.quantity_basis,p_version,p_policy,true) END;
  IF p_node.returned_consumption_qty>0 THEN returned:=fn_inventory_value_interval(p_value,0,p_node.returned_consumption_qty,p_node.quantity_basis,p_version,p_policy,true);END IF;
  IF p_node.active AND p_node.kind='ISSUE_POSITION' THEN owned:=high-low-p_node.distributed_value_local-returned;END IF;
 END IF;
 IF NOT fn_financial_book_amount_is_exact(owned) THEN RAISE EXCEPTION 'Inventory owned target exceeds exact book storage' USING ERRCODE='22003';END IF;
 RETURN jsonb_build_object('basis',p_value,'inputs',fn_inventory_value_projection_inputs(p_node),'fromValue',low,'toValue',high,
  'returnedValue',returned,'ownedValue',owned,'version',p_version,'policy',p_policy);
END $$;

CREATE FUNCTION fn_inventory_value_restores_event(p_event uuid) RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT coalesce(projection_restore_of_event_id,reversal_of_event_id) FROM stock_value_events WHERE id=p_event
$$;
CREATE FUNCTION fn_inventory_value_parent_revision_value(p_node uuid,p_revision bigint,p_before boolean DEFAULT false) RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE value numeric;
BEGIN
 IF p_revision=1 THEN SELECT initial_known_value INTO STRICT value FROM stock_value_nodes WHERE id=p_node;
 ELSE SELECT CASE WHEN p_before THEN before_value ELSE after_value END INTO STRICT value FROM stock_value_node_revisions WHERE node_id=p_node AND revision=p_revision;END IF;
 RETURN value;
END $$;

-- A literal inverse can reuse the original ACTUAL applied target when its
-- operands return to that original point. New points use the new explicit rule.
CREATE FUNCTION fn_inventory_value_revaluation_target(p_edge uuid,p_before numeric,p_after numeric,p_event uuid,p_previous numeric DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE edge stock_value_edges%ROWTYPE;event stock_value_events%ROWTYPE;original stock_value_tasks%ROWTYPE;restores uuid;
 value numeric;version integer;policy jsonb;
BEGIN
 SELECT * INTO STRICT edge FROM stock_value_edges WHERE id=p_edge;SELECT * INTO STRICT event FROM stock_value_events WHERE id=p_event;
 version:=event.value_precision_version;policy:=event.business_precision_policy;restores:=fn_inventory_value_restores_event(event.id);
 IF restores IS NOT NULL THEN
  SELECT * INTO original FROM stock_value_tasks WHERE edge_id=edge.id AND event_id=restores AND status='APPLIED' ORDER BY parent_revision DESC LIMIT 1;
  IF original.id IS NOT NULL AND p_after=fn_inventory_value_parent_revision_value(edge.parent_node_id,original.parent_revision,true) THEN
   value:=coalesce(original.before_allocated_amount_local,original.target_amount_local-original.applied_delta_local);
   version:=coalesce(original.before_precision_version,edge.value_precision_version);
   policy:=CASE WHEN version=1 THEN NULL ELSE coalesce(original.before_precision_policy,edge.business_precision_policy) END;
   RETURN jsonb_build_object('amount',value,'version',version,'policy',policy,'restoresTaskId',original.id);
  END IF;
 END IF;
 IF p_before=p_after THEN
  value:=coalesce(p_previous,edge.allocated_amount_local);version:=coalesce(edge.applied_precision_version,edge.value_precision_version);
  policy:=CASE WHEN version=1 THEN NULL ELSE coalesce(edge.applied_precision_policy,edge.business_precision_policy) END;
 ELSE value:=fn_inventory_value_interval(p_after,edge.interval_from,edge.interval_to,edge.denominator,version,policy,true);END IF;
 RETURN jsonb_build_object('amount',value,'version',version,'policy',policy);
END $$;


CREATE FUNCTION fn_inventory_value_revaluation_request_policy(p_event uuid) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE event stock_value_events%ROWTYPE;plan stock_value_production_cost_revisions%ROWTYPE;
BEGIN
 SELECT * INTO event FROM stock_value_events WHERE id=p_event;
 IF event.id IS NOT NULL THEN
  IF event.valuation_root_id IS NOT NULL AND event.valuation_root_id<>event.id THEN
   IF event.valuation_root_kind='PLAN' THEN SELECT * INTO STRICT plan FROM stock_value_production_cost_revisions WHERE id=event.valuation_root_id;
    RETURN coalesce(plan.request_precision_policy,plan.business_precision_policy,'{"version":1,"choices":{}}'::jsonb);
   END IF;
   RETURN fn_inventory_value_revaluation_request_policy(event.valuation_root_id);
  END IF;
  RETURN coalesce(event.business_precision_policy,'{"version":1,"choices":{}}'::jsonb);
 END IF;
 SELECT * INTO plan FROM stock_value_production_cost_revisions WHERE id=p_event;
 IF plan.id IS NOT NULL THEN RETURN coalesce(plan.request_precision_policy,plan.business_precision_policy,'{"version":1,"choices":{}}'::jsonb);END IF;
 RAISE EXCEPTION 'Cost revaluation is missing its original request policy' USING ERRCODE='23514';
END $$;

-- Distributed ownership is an actual current contribution, not an operand of
-- the saved physical prefix. Restore that prefix at its proven original point,
-- then subtract the current stored distribution until its own inverse runs.
CREATE FUNCTION fn_inventory_value_restore_projection(p_node stock_value_nodes,p_after numeric,p_restores uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_original jsonb;v_owned numeric:=0;
BEGIN
 IF p_restores IS NULL THEN RETURN NULL;END IF;
 SELECT revision.before_projection INTO v_original FROM stock_value_node_revisions revision
  WHERE revision.node_id=p_node.id AND revision.event_id=p_restores AND revision.before_value=p_after
   AND ((revision.before_projection->'inputs')-'active'-'distributed')=(fn_inventory_value_projection_inputs(p_node)-'active'-'distributed')
  ORDER BY revision.revision DESC LIMIT 1;
 IF v_original IS NULL THEN RETURN NULL;END IF;
 IF p_node.active AND p_node.kind='POOL' THEN v_owned:=p_after;
 ELSIF p_node.active AND p_node.kind='ISSUE_POSITION' THEN
  v_owned:=(v_original->>'toValue')::numeric-(v_original->>'fromValue')::numeric-p_node.distributed_value_local-(v_original->>'returnedValue')::numeric;
 END IF;
 RETURN v_original||jsonb_build_object('inputs',fn_inventory_value_projection_inputs(p_node),'ownedValue',v_owned);
END $$;

CREATE FUNCTION fn_inventory_value_capture_revision_projection() RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$
DECLARE node stock_value_nodes%ROWTYPE;before jsonb;after jsonb;restores uuid;original record;version integer;policy jsonb;
BEGIN
 SELECT * INTO STRICT node FROM stock_value_nodes WHERE id=NEW.node_id;
 before:=fn_inventory_value_current_projection(node);NEW.before_projection:=before;
 version:=NEW.value_precision_version;policy:=NEW.business_precision_policy;
 IF NEW.after_value=NEW.before_value THEN after:=before;
 ELSE
  restores:=fn_inventory_value_restores_event(NEW.event_id);
  after:=fn_inventory_value_restore_projection(node,NEW.after_value,restores);
  IF after IS NULL THEN after:=fn_inventory_value_after_projection(node,NEW.after_value,version,policy);END IF;
 END IF;
 NEW.after_projection:=after;
 NEW.value_precision_version:=(after->>'version')::smallint;
 NEW.business_precision_policy:=nullif(after->'policy','null'::jsonb);
 RETURN NEW;
END $$;
CREATE TRIGGER trg_01_inventory_value_revision_projection BEFORE INSERT ON stock_value_node_revisions
 FOR EACH ROW EXECUTE FUNCTION fn_inventory_value_capture_revision_projection();
ALTER TABLE stock_value_node_revisions ENABLE ALWAYS TRIGGER trg_01_inventory_value_revision_projection;

-- A read of an already applied point is not another valuation calculation.
CREATE OR REPLACE FUNCTION fn_inventory_value_owned(p_row stock_value_nodes) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
 SELECT p_row.owned_value_local
$$;

CREATE FUNCTION fn_inventory_value_new_interval(p_node uuid,p_from numeric,p_to numeric,p_denominator numeric,p_policy jsonb) RETURNS numeric
LANGUAGE plpgsql VOLATILE AS $$
DECLARE node stock_value_nodes%ROWTYPE;projection jsonb;high numeric;low numeric;
BEGIN
 SELECT * INTO STRICT node FROM stock_value_nodes WHERE id=p_node;
 IF p_from=0 AND p_to=p_denominator THEN RETURN node.basis_value_local;END IF;
 IF p_from=p_to THEN RETURN 0;END IF;
 IF node.kind NOT IN('ISSUE_POSITION','COST_RETURN_CURSOR') THEN
  RETURN fn_inventory_value_interval(node.basis_value_local,p_from,p_to,p_denominator,2,p_policy,true);
 END IF;
 IF p_denominator<>node.quantity_basis OR p_from<>node.range_from OR p_to>node.range_to THEN
  RAISE EXCEPTION 'New inventory interval must continue the actual recorded range' USING ERRCODE='23514';END IF;
 projection:=fn_inventory_value_current_projection(node);low:=(projection->>'fromValue')::numeric;
 high:=CASE WHEN p_to=node.range_to THEN (projection->>'toValue')::numeric ELSE
  fn_inventory_value_interval(node.basis_value_local,0,p_to,p_denominator,2,p_policy,true) END;
 IF high<low OR high>(projection->>'toValue')::numeric THEN
  RAISE EXCEPTION 'UTEN_PRECISION_REQUIRED:%',jsonb_build_object('calculationKey','stock.value.interval','groupKey','stock.value.interval',
   'label','本次库存成本分配超过原实际范围，请重新选择','maxScale',30,'reason','PRECISION_LIMIT','selectionRejected',true,'notWritten',true)::text USING ERRCODE='22023';END IF;
 RETURN high-low;
END $$;

CREATE FUNCTION fn_inventory_value_schedule_revaluation_task(p_edge uuid,p_parent_revision bigint,p_event uuid) RETURNS integer LANGUAGE plpgsql VOLATILE AS $$
DECLARE edge stock_value_edges%ROWTYPE;node stock_value_nodes%ROWTYPE;before numeric;after numeric;previous record;target jsonb;count integer;
BEGIN
 SELECT * INTO STRICT edge FROM stock_value_edges WHERE id=p_edge;SELECT * INTO STRICT node FROM stock_value_nodes WHERE id=edge.parent_node_id;
 before:=fn_inventory_value_parent_revision_value(node.id,p_parent_revision,true);after:=fn_inventory_value_parent_revision_value(node.id,p_parent_revision,false);
 SELECT target_amount_local,value_precision_version,business_precision_policy INTO previous FROM stock_value_tasks
  WHERE edge_id=edge.id AND parent_revision=p_parent_revision-1;
 target:=fn_inventory_value_revaluation_target(edge.id,before,after,p_event,CASE WHEN FOUND THEN previous.target_amount_local ELSE edge.allocated_amount_local END);
 IF before=after AND previous.target_amount_local IS NOT NULL AND (target->>'restoresTaskId') IS NULL THEN
  target:=target||jsonb_build_object('version',previous.value_precision_version,'policy',previous.business_precision_policy);
 END IF;
 INSERT INTO stock_value_tasks(id,event_id,edge_id,parent_revision,target_amount_local,target_pending,parent_before_value,parent_after_value,
  value_precision_version,business_precision_policy,restores_task_id)
 VALUES(gen_random_uuid(),p_event,edge.id,p_parent_revision,(target->>'amount')::numeric,node.pending_parents>0 AND edge.interval_to>edge.interval_from,
  before,after,(target->>'version')::smallint,nullif(target->'policy','null'::jsonb),(target->>'restoresTaskId')::uuid)
 ON CONFLICT(edge_id,parent_revision) DO NOTHING;
 GET DIAGNOSTICS count=ROW_COUNT;RETURN count;
END $$;

CREATE OR REPLACE FUNCTION fn_guard_inventory_value_owned() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE before jsonb;projection jsonb;source stock_value_nodes%ROWTYPE;cursor stock_value_nodes%ROWTYPE;
 low numeric:=0;high numeric:=0;returned numeric:=0;owned numeric:=0;part numeric;rows integer;changed boolean;
BEGIN
 IF TG_OP='INSERT' THEN
  IF NEW.kind='POOL' THEN high:=NEW.basis_value_local;
  ELSIF NEW.kind IN('ISSUE_POSITION','COST_RETURN_CURSOR') THEN
   IF NEW.precision_source_node_id IS NOT NULL AND NEW.root_issue_id IS DISTINCT FROM NEW.id THEN
    SELECT * INTO STRICT source FROM stock_value_nodes WHERE id=NEW.precision_source_node_id;before:=fn_inventory_value_current_projection(source);
    high:=(before->>'toValue')::numeric;
    IF NEW.range_from=source.range_from THEN low:=(before->>'fromValue')::numeric;
    ELSE
     SELECT count(*),sum(initial_allocated_amount) INTO rows,part FROM stock_value_edges
      WHERE parent_node_id=source.id AND creation_event_id=NEW.creation_event_id AND interval_from=source.range_from
        AND interval_to=NEW.range_from AND denominator=source.quantity_basis;
     IF rows<>1 THEN RAISE EXCEPTION 'New remaining range must retain its actual same-operation monetary prefix' USING ERRCODE='23514';END IF;
     low:=(before->>'fromValue')::numeric+part;
    END IF;
   ELSE high:=NEW.basis_value_local;END IF;
  END IF;
 ELSE
  before:=fn_inventory_value_current_projection(OLD);low:=(before->>'fromValue')::numeric;high:=(before->>'toValue')::numeric;
  returned:=(before->>'returnedValue')::numeric;
  changed:=NEW.basis_value_local IS DISTINCT FROM OLD.basis_value_local OR NEW.revision IS DISTINCT FROM OLD.revision
   OR NEW.active IS DISTINCT FROM OLD.active OR NEW.distributed_value_local IS DISTINCT FROM OLD.distributed_value_local
   OR NEW.returned_consumption_qty IS DISTINCT FROM OLD.returned_consumption_qty;
  IF NEW.basis_value_local IS DISTINCT FROM OLD.basis_value_local OR NEW.revision IS DISTINCT FROM OLD.revision THEN
   SELECT after_projection INTO STRICT projection FROM stock_value_node_revisions WHERE node_id=NEW.id AND revision=NEW.revision;
   IF projection IS NULL OR (projection->>'basis')::numeric IS DISTINCT FROM NEW.basis_value_local
     OR projection->'inputs' IS DISTINCT FROM fn_inventory_value_projection_inputs(NEW) THEN
    RAISE EXCEPTION 'Revalued monetary projection requires the same exact before/after revision fact' USING ERRCODE='23514';END IF;
   low:=(projection->>'fromValue')::numeric;high:=(projection->>'toValue')::numeric;returned:=(projection->>'returnedValue')::numeric;
  ELSIF NEW.returned_consumption_qty IS DISTINCT FROM OLD.returned_consumption_qty THEN
   SELECT * INTO STRICT cursor FROM stock_value_nodes WHERE id=NEW.consumption_return_head_id;
   IF cursor.root_issue_id<>NEW.id OR cursor.range_from<>NEW.returned_consumption_qty OR cursor.range_from_value_local IS NULL THEN
    RAISE EXCEPTION 'Consumption return requires its actual saved cumulative monetary prefix' USING ERRCODE='23514';END IF;
   returned:=cursor.range_from_value_local;
  END IF;
  IF NOT changed AND NEW.owned_value_local IS DISTINCT FROM OLD.owned_value_local THEN
   RAISE EXCEPTION 'Inventory owned value requires an actual source operation' USING ERRCODE='55000';END IF;
  IF NOT changed AND ((NEW.range_from_value_local IS NOT NULL AND NEW.range_from_value_local IS DISTINCT FROM low)
   OR (NEW.range_to_value_local IS NOT NULL AND NEW.range_to_value_local IS DISTINCT FROM high)
   OR (NEW.returned_value_local IS NOT NULL AND NEW.returned_value_local IS DISTINCT FROM returned)) THEN
   RAISE EXCEPTION 'Applied inventory monetary prefixes cannot be replaced directly' USING ERRCODE='55000';END IF;
 END IF;
 IF NEW.active AND NEW.kind='POOL' THEN owned:=NEW.basis_value_local;
 ELSIF NEW.active AND NEW.kind='ISSUE_POSITION' THEN owned:=high-low-NEW.distributed_value_local-returned;END IF;
 IF NOT fn_financial_book_amount_is_exact(low) OR NOT fn_financial_book_amount_is_exact(high)
  OR NOT fn_financial_book_amount_is_exact(returned) OR NOT fn_financial_book_amount_is_exact(owned) THEN
  RAISE EXCEPTION 'Applied inventory monetary point exceeds exact storage' USING ERRCODE='22003';END IF;
 NEW.range_from_value_local:=low;NEW.range_to_value_local:=high;NEW.returned_value_local:=returned;NEW.owned_value_local:=owned;
 RETURN NEW;
END $$;

-- Keep the original identity, owner, revision, fan-out and lifecycle guards.
DO $whole_revaluation_projection_columns$
DECLARE definition text;needle text;
BEGIN
 SELECT pg_get_functiondef('fn_guard_stock_value_projection_identity()'::regprocedure) INTO definition;
 needle:='''consumption_return_head_id''';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review current inventory projection identity';END IF;
 definition:=replace(definition,needle,needle||',''range_from_value_local'',''range_to_value_local'',''returned_value_local''');
 needle:='''bound_parent_revision''';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review current edge projection identity';END IF;
 definition:=replace(definition,needle,needle||',''applied_precision_version'',''applied_precision_policy''');
 needle:='''applied_child_revision''';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review current task projection identity';END IF;
 definition:=replace(definition,needle,needle||',''before_allocated_amount_local'',''before_pending_contribution'',''before_precision_version'',''before_precision_policy''');
 EXECUTE definition;
END $whole_revaluation_projection_columns$;

CREATE OR REPLACE FUNCTION fn_guard_inventory_value_precision() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE v_version smallint:=2;v_policy jsonb:=fn_business_precision_snapshot();parent record;
BEGIN
 IF TG_OP<>'INSERT' THEN
  IF NEW.value_precision_version IS DISTINCT FROM OLD.value_precision_version OR NEW.business_precision_policy IS DISTINCT FROM OLD.business_precision_policy THEN
   RAISE EXCEPTION 'Original inventory precision identity is immutable' USING ERRCODE='55000';END IF;
  RETURN NEW;
 END IF;
 CASE TG_TABLE_NAME
 WHEN 'stock_value_nodes' THEN NULL;
 WHEN 'stock_value_edges' THEN
  IF NEW.restores_transfer_id IS NOT NULL THEN
   SELECT coalesce(edge.applied_precision_version,edge.value_precision_version) v_version,
    CASE WHEN coalesce(edge.applied_precision_version,edge.value_precision_version)=1 THEN NULL
     ELSE coalesce(edge.applied_precision_policy,edge.business_precision_policy) END v_policy INTO STRICT parent
   FROM stock_value_position_transfers transfer JOIN stock_value_edges edge ON edge.creation_event_id=transfer.event_id
    AND edge.parent_node_id=transfer.source_node_id AND edge.child_node_id=transfer.target_node_id WHERE transfer.id=NEW.restores_transfer_id;
   v_version:=parent.v_version;v_policy:=parent.v_policy;
  END IF;
 WHEN 'stock_value_tasks' THEN
  -- The sole planner has frozen the actual whole-target result/restoration.
  v_version:=NEW.value_precision_version;v_policy:=NEW.business_precision_policy;
 WHEN 'stock_value_node_revisions' THEN
  SELECT value_precision_version,business_precision_policy INTO parent FROM stock_value_events WHERE id=NEW.event_id;
  IF FOUND THEN v_version:=parent.value_precision_version;v_policy:=parent.business_precision_policy;END IF;
 WHEN 'stock_value_position_transfers' THEN
  IF NEW.reversal_of_transfer_id IS NOT NULL THEN
   SELECT value_precision_version,business_precision_policy INTO STRICT parent FROM stock_value_position_transfers WHERE id=NEW.reversal_of_transfer_id;
   v_version:=parent.value_precision_version;v_policy:=parent.business_precision_policy;
  END IF;
 WHEN 'stock_value_production_cost_revisions' THEN
  NEW.precision_origin_id:=NEW.id;
  IF NEW.source_doc_type='PRODUCTION_SOURCE_RECALCULATE' THEN
   SELECT value_precision_version,business_precision_policy,coalesce(valuation_root_id,id) root_id INTO parent FROM stock_value_events WHERE id=NEW.source_event_id;
   IF FOUND THEN
    v_version:=parent.value_precision_version;v_policy:=fn_inventory_value_revaluation_request_policy(NEW.source_event_id);
    NEW.precision_origin_id:=parent.root_id;
    SELECT precision_closure_keys INTO NEW.precision_closure_keys FROM stock_value_jobs WHERE event_id=parent.root_id;
   END IF;
  END IF;
  IF NEW.source_doc_type<>'PRODUCTION_SOURCE_RECALCULATE' THEN
   IF current_setting('app.inventory_value_legacy_refresh',true)='1' AND EXISTS(
     SELECT 1 FROM stock_value_production_cost_objects o WHERE o.execution_segment_id=NEW.execution_segment_id
      AND o.business_refresh_pending AND o.business_refresh_precision_version=1 AND o.business_refresh_precision_policy IS NULL) THEN
    v_version:=1;v_policy:=NULL;
   END IF;
   SELECT coalesce(r.precision_origin_id,r.id) AS root_id INTO parent FROM stock_value_production_cost_revisions r
    WHERE r.precision_created_txid=txid_current() AND r.source_doc_type<>'PRODUCTION_SOURCE_RECALCULATE'
     AND r.actor_user_id=NEW.actor_user_id AND r.value_precision_version=v_version
     AND r.request_precision_policy=coalesce(v_policy,'{"version":1,"choices":{}}'::jsonb) LIMIT 1;
   IF FOUND THEN NEW.precision_origin_id:=parent.root_id;END IF;
   SELECT o.business_refresh_precision_root_id AS root_id INTO parent FROM stock_value_production_cost_objects o
    WHERE o.execution_segment_id=NEW.execution_segment_id AND o.business_refresh_pending;
   IF parent.root_id IS NOT NULL THEN NEW.precision_origin_id:=parent.root_id;
   ELSE UPDATE stock_value_production_cost_objects SET business_refresh_precision_root_id=NEW.precision_origin_id
     WHERE execution_segment_id=NEW.execution_segment_id AND business_refresh_pending;
   END IF;
  END IF;
  NEW.request_precision_policy:=coalesce(v_policy,'{"version":1,"choices":{}}'::jsonb);
  SELECT array_agg(DISTINCT id ORDER BY id) INTO NEW.precision_closure_nodes FROM (
   SELECT (i->>'node')::uuid id FROM jsonb_array_elements(NEW.input_snapshot) i
   UNION SELECT (o->>'source')::uuid FROM jsonb_array_elements(NEW.output_snapshot) o
  ) scope_seeds;
  -- All seeds share one closure walk. Unioning one full walk per input was
  -- equivalent but multiplied the 100-input registration cost by its size.
  IF NEW.precision_closure_nodes IS NOT NULL THEN
   NEW.precision_closure_nodes:=fn_inventory_value_precision_scope(NEW.precision_closure_nodes);
  END IF;
  IF NEW.precision_closure_keys IS NULL THEN
   SELECT array_agg(DISTINCT fn_inventory_value_precision_key(pool.goods_id,pool.color_id) ORDER BY fn_inventory_value_precision_key(pool.goods_id,pool.color_id))
   INTO NEW.precision_closure_keys FROM stock_value_nodes n JOIN stock_value_pools pool ON pool.id=n.pool_id WHERE n.id=ANY(NEW.precision_closure_nodes);
  END IF;
 WHEN 'stock_value_production_cost_tasks' THEN
  IF NEW.target_proof IS NOT NULL THEN v_version:=(NEW.target_proof->>'version')::smallint;v_policy:=nullif(NEW.target_proof->'policy','null'::jsonb);
  ELSE SELECT value_precision_version,business_precision_policy INTO STRICT parent FROM stock_value_production_cost_revisions WHERE id=NEW.revision_id;
   v_version:=parent.value_precision_version;v_policy:=parent.business_precision_policy;END IF;
 WHEN 'stock_value_events' THEN
  IF NEW.operation='COST_ALLOCATE' THEN
   SELECT value_precision_version,business_precision_policy,restores_task_id INTO STRICT parent FROM stock_value_production_cost_tasks WHERE id=NEW.id;
   IF parent.value_precision_version=1 AND parent.restores_task_id IS NULL THEN v_version:=1;v_policy:=NULL;END IF;
   IF parent.restores_task_id IS NOT NULL THEN SELECT coalesce(value_event_id,id) INTO NEW.projection_restore_of_event_id FROM stock_value_production_cost_tasks WHERE id=parent.restores_task_id;END IF;
  END IF;
 ELSE NULL;
 END CASE;
 NEW.value_precision_version:=v_version;NEW.business_precision_policy:=CASE WHEN v_version=1 THEN NULL ELSE v_policy END;
 RETURN NEW;
END $$;

CREATE FUNCTION fn_inventory_value_production_task_target(p_task stock_value_production_cost_tasks) RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE revision stock_value_production_cost_revisions%ROWTYPE;input jsonb;output jsonb;
BEGIN
 SELECT * INTO STRICT revision FROM stock_value_production_cost_revisions WHERE id=p_task.revision_id;
 SELECT i INTO STRICT input FROM jsonb_array_elements(revision.input_snapshot) i WHERE (i->>'node')::uuid=p_task.input_node_id;
 SELECT o INTO STRICT output FROM jsonb_array_elements(revision.output_snapshot) o WHERE (o->>'source')::uuid=p_task.output_source_node_id;
 RETURN fn_inventory_value_production_target_after(to_jsonb(revision),input,output,'{}',revision.request_precision_policy,
  revision.value_precision_version,fn_inventory_value_restores_event(revision.source_event_id));
END $$;

CREATE FUNCTION fn_inventory_value_validate_production_target() RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$
DECLARE expected jsonb;
BEGIN
 expected:=fn_inventory_value_production_task_target(NEW);
 IF NEW.target_proof IS DISTINCT FROM expected OR NEW.desired_value_local IS DISTINCT FROM (expected->>'amount')::numeric
  OR NEW.value_precision_version IS DISTINCT FROM (expected->>'version')::smallint
  OR NEW.business_precision_policy IS DISTINCT FROM nullif(expected->'policy','null'::jsonb)
  OR NEW.restores_task_id IS DISTINCT FROM (expected->>'restoresTaskId')::uuid THEN
  RAISE EXCEPTION 'Production task requires its actual cumulative target proof' USING ERRCODE='23514';END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_01_inventory_value_production_target BEFORE INSERT ON stock_value_production_cost_tasks
 FOR EACH ROW EXECUTE FUNCTION fn_inventory_value_validate_production_target();

DO $production_actual_target_guard$
DECLARE definition text;needle text:='fn_inventory_value_interval(NEW.input_value_local,NEW.output_from*(NEW.input_quantity_basis-NEW.input_returned_qty),NEW.output_to*(NEW.input_quantity_basis-NEW.input_returned_qty),NEW.denominator*NEW.input_quantity_basis,NEW.value_precision_version,NEW.business_precision_policy,false)';
BEGIN
 SELECT pg_get_functiondef('fn_check_stock_value_cost_task_plan()'::regprocedure) INTO definition;
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review production complete target proof';END IF;
 -- The target was computed and protected at task INSERT. Completion reads that
 -- immutable fact; changing shares later cannot change its prior calculation.
 EXECUTE replace(definition,needle,'CASE WHEN NEW.target_proof IS NULL THEN '||needle||' ELSE (NEW.target_proof->>''amount'')::numeric END');
END $production_actual_target_guard$;

CREATE FUNCTION fn_inventory_value_validate_task_target() RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$
DECLARE edge stock_value_edges%ROWTYPE;expected jsonb;before numeric;after numeric;previous stock_value_tasks%ROWTYPE;
BEGIN
 SELECT * INTO STRICT edge FROM stock_value_edges WHERE id=NEW.edge_id;
 before:=fn_inventory_value_parent_revision_value(edge.parent_node_id,NEW.parent_revision,true);
 after:=fn_inventory_value_parent_revision_value(edge.parent_node_id,NEW.parent_revision,false);
 SELECT * INTO previous FROM stock_value_tasks WHERE edge_id=edge.id AND parent_revision=NEW.parent_revision-1;
 expected:=fn_inventory_value_revaluation_target(edge.id,before,after,NEW.event_id,coalesce(previous.target_amount_local,edge.allocated_amount_local));
 IF before=after AND previous.id IS NOT NULL AND (expected->>'restoresTaskId') IS NULL THEN
  expected:=expected||jsonb_build_object('version',previous.value_precision_version,'policy',previous.business_precision_policy);
 END IF;
 IF NEW.parent_before_value IS DISTINCT FROM before OR NEW.parent_after_value IS DISTINCT FROM after
  OR NEW.target_amount_local IS DISTINCT FROM (expected->>'amount')::numeric
  OR NEW.value_precision_version IS DISTINCT FROM (expected->>'version')::smallint
  OR NEW.business_precision_policy IS DISTINCT FROM nullif(expected->'policy','null'::jsonb)
  OR NEW.restores_task_id IS DISTINCT FROM (expected->>'restoresTaskId')::uuid THEN
  RAISE EXCEPTION 'Revaluation task must freeze its actual whole target and original proof' USING ERRCODE='23514';END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_01_inventory_value_task_target BEFORE INSERT ON stock_value_tasks FOR EACH ROW EXECUTE FUNCTION fn_inventory_value_validate_task_target();
ALTER TABLE stock_value_tasks ENABLE ALWAYS TRIGGER trg_01_inventory_value_task_target;

CREATE OR REPLACE FUNCTION fn_guard_inventory_value_edge_amount() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE parent stock_value_nodes%ROWTYPE;expected numeric;task stock_value_tasks%ROWTYPE;
BEGIN
 IF TG_OP='UPDATE' THEN
  IF NEW.last_parent_revision=OLD.last_parent_revision AND NEW.allocated_amount_local=OLD.allocated_amount_local THEN RETURN NEW;END IF;
  SELECT * INTO STRICT task FROM stock_value_tasks WHERE edge_id=NEW.id AND parent_revision=NEW.last_parent_revision;
  IF NEW.allocated_amount_local IS DISTINCT FROM task.target_amount_local THEN
   RAISE EXCEPTION 'Applied edge amount must equal its frozen actual task target' USING ERRCODE='23514';END IF;
  NEW.applied_precision_version:=task.value_precision_version;NEW.applied_precision_policy:=task.business_precision_policy;
  RETURN NEW;
 END IF;
 SELECT * INTO STRICT parent FROM stock_value_nodes WHERE id=NEW.parent_node_id;
 IF NEW.restores_transfer_id IS NOT NULL THEN
  SELECT original.allocated_amount_local INTO STRICT expected FROM stock_value_position_transfers transfer
   JOIN stock_value_edges original ON original.creation_event_id=transfer.event_id AND original.parent_node_id=transfer.source_node_id
    AND original.child_node_id=transfer.target_node_id WHERE transfer.id=NEW.restores_transfer_id;
 ELSIF parent.kind IN('ISSUE_POSITION','COST_RETURN_CURSOR') THEN
  expected:=fn_inventory_value_new_interval(parent.id,NEW.interval_from,NEW.interval_to,NEW.denominator,NEW.business_precision_policy);
 ELSE expected:=fn_inventory_value_interval(parent.basis_value_local,NEW.interval_from,NEW.interval_to,NEW.denominator,NEW.value_precision_version,NEW.business_precision_policy,false);END IF;
 IF NEW.allocated_amount_local IS DISTINCT FROM expected OR NEW.initial_allocated_amount IS DISTINCT FROM expected THEN
  RAISE EXCEPTION 'New inventory edge must retain its actual monetary interval' USING ERRCODE='23514';END IF;
 NEW.applied_precision_version:=NEW.value_precision_version;NEW.applied_precision_policy:=NEW.business_precision_policy;
 RETURN NEW;
END $$;

CREATE FUNCTION fn_inventory_value_capture_transfer_projection() RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$
DECLARE node stock_value_nodes%ROWTYPE;projection jsonb;value numeric;edge stock_value_edges%ROWTYPE;
BEGIN
 SELECT * INTO STRICT node FROM stock_value_nodes WHERE id=NEW.source_node_id;
 IF node.revision<>NEW.source_revision THEN RAISE EXCEPTION 'Transfer must retain its actual source revision' USING ERRCODE='23514';END IF;
 projection:=fn_inventory_value_current_projection(node);NEW.source_projection:=projection;
 IF NEW.reversal_of_transfer_id IS NOT NULL THEN
  SELECT original.* INTO STRICT edge FROM stock_value_position_transfers transfer
   JOIN stock_value_edges original ON original.creation_event_id=transfer.event_id AND original.parent_node_id=transfer.source_node_id
    AND original.child_node_id=transfer.target_node_id WHERE transfer.id=NEW.reversal_of_transfer_id;
  IF NEW.initial_value_local<>edge.allocated_amount_local THEN RAISE EXCEPTION 'Transfer inverse must mirror the actual saved original amount' USING ERRCODE='23514';END IF;
  NEW.from_value_local:=0;NEW.to_value_local:=edge.allocated_amount_local;
 ELSE
  IF NEW.range_from<>node.range_from THEN RAISE EXCEPTION 'Transfer must continue its actual recorded quantity prefix' USING ERRCODE='23514';END IF;
  NEW.from_value_local:=(projection->>'fromValue')::numeric;
  NEW.to_value_local:=NEW.from_value_local+NEW.initial_value_local;
  value:=CASE WHEN NEW.range_to=node.range_to THEN (projection->>'toValue')::numeric
    ELSE fn_inventory_value_interval(node.basis_value_local,0,NEW.range_to,NEW.quantity_basis,2,NEW.business_precision_policy,true) END;
  IF NEW.to_value_local<>value THEN RAISE EXCEPTION 'Transfer after target must match its explicit cumulative computation' USING ERRCODE='23514';END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_01_inventory_value_transfer_projection BEFORE INSERT ON stock_value_position_transfers
 FOR EACH ROW EXECUTE FUNCTION fn_inventory_value_capture_transfer_projection();
ALTER TABLE stock_value_position_transfers ENABLE ALWAYS TRIGGER trg_01_inventory_value_transfer_projection;

DO $whole_target_original_transfer_proof$
DECLARE definition text;needle text;
BEGIN
 SELECT pg_get_functiondef('fn_check_stock_value_position_transfer()'::regprocedure) INTO definition;
 needle:='fn_inventory_value_interval(original_value,NEW.range_from,NEW.range_to,NEW.quantity_basis,NEW.value_precision_version,NEW.business_precision_policy,false)';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review transfer whole target proof';END IF;
 definition:=replace(definition,needle,'(NEW.to_value_local-NEW.from_value_local)');
 definition:=replace(definition,'OR original_value IS NULL','OR original_value IS NULL OR (NEW.source_projection->>''basis'')::numeric IS DISTINCT FROM original_value');
 EXECUTE definition;
 SELECT pg_get_functiondef('fn_check_stock_value_reverse_transfer()'::regprocedure) INTO definition;
 needle:='fn_inventory_value_interval(source_value,NEW.range_from,NEW.range_to,NEW.quantity_basis,original.value_precision_version,original.business_precision_policy,false)';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review exact inverse original transfer proof';END IF;
 EXECUTE replace(definition,needle,'(NEW.to_value_local-NEW.from_value_local)');
 SELECT pg_get_functiondef('fn_assert_consumption_return(uuid)'::regprocedure) INTO definition;
 needle:='fn_inventory_value_interval(source.basis_value_local,e.qty_before,e.qty_before+e.qty_base,source.quantity_basis,cursor.value_precision_version,cursor.business_precision_policy,false)';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review actual consumption return prefix proof';END IF;
 EXECUTE replace(definition,needle,'cursor.range_from_value_local-source.range_from_value_local');
END $whole_target_original_transfer_proof$;

CREATE FUNCTION fn_inventory_value_capture_applied_task_before() RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_revision stock_value_node_revisions%ROWTYPE;edge stock_value_edges%ROWTYPE;prior stock_value_tasks%ROWTYPE;pending integer;
BEGIN
 IF OLD.status<>'PENDING' OR NEW.status<>'APPLIED' THEN RETURN NEW;END IF;
 SELECT actual.* INTO STRICT v_revision FROM stock_value_node_revisions actual WHERE actual.task_id=NEW.id AND actual.revision=NEW.applied_child_revision;
 SELECT * INTO STRICT edge FROM stock_value_edges WHERE id=NEW.edge_id;
 NEW.before_allocated_amount_local:=NEW.target_amount_local-NEW.applied_delta_local;
 pending:=(CASE WHEN NEW.target_pending THEN 1 ELSE 0 END)-(v_revision.after_pending-v_revision.before_pending);
 IF pending NOT IN(0,1) THEN RAISE EXCEPTION 'Applied task pending contribution lacks an exact before fact' USING ERRCODE='23514';END IF;
 NEW.before_pending_contribution:=pending=1;
 SELECT * INTO prior FROM stock_value_tasks WHERE edge_id=NEW.edge_id AND parent_revision=NEW.parent_revision-1 AND status='APPLIED';
 NEW.before_precision_version:=CASE WHEN FOUND THEN prior.value_precision_version ELSE edge.value_precision_version END;
 NEW.before_precision_policy:=CASE WHEN NEW.before_precision_version=1 THEN NULL
  WHEN prior.id IS NOT NULL THEN prior.business_precision_policy ELSE edge.business_precision_policy END;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_00b_inventory_value_applied_task_before BEFORE UPDATE ON stock_value_tasks
 FOR EACH ROW EXECUTE FUNCTION fn_inventory_value_capture_applied_task_before();
ALTER TABLE stock_value_tasks ENABLE ALWAYS TRIGGER trg_00b_inventory_value_applied_task_before;

CREATE FUNCTION fn_inventory_value_target_after_with_policy(p_edge uuid,p_after numeric,p_version integer,p_policy jsonb,p_restores uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE edge stock_value_edges%ROWTYPE;original stock_value_tasks%ROWTYPE;version integer:=p_version;policy jsonb:=p_policy;amount numeric;
BEGIN
 SELECT * INTO STRICT edge FROM stock_value_edges WHERE id=p_edge;
 IF p_restores IS NOT NULL THEN
  SELECT * INTO original FROM stock_value_tasks WHERE edge_id=edge.id AND event_id=p_restores AND status='APPLIED' ORDER BY parent_revision DESC LIMIT 1;
  IF original.id IS NOT NULL AND p_after=fn_inventory_value_parent_revision_value(edge.parent_node_id,original.parent_revision,true) THEN
   amount:=coalesce(original.before_allocated_amount_local,original.target_amount_local-original.applied_delta_local);
   version:=coalesce(original.before_precision_version,edge.value_precision_version);
   policy:=CASE WHEN version=1 THEN NULL ELSE coalesce(original.before_precision_policy,edge.business_precision_policy) END;
   RETURN jsonb_build_object('amount',amount,'version',version,'policy',policy,'restoresTaskId',original.id);
  END IF;
 END IF;
 amount:=fn_inventory_value_interval(p_after,edge.interval_from,edge.interval_to,edge.denominator,version,policy,true);
 RETURN jsonb_build_object('amount',amount,'version',version,'policy',policy);
END $$;

-- Bounded stock DAG rehearsal. Every before operand is a stored actual point;
-- only successors of the changed source get a new whole cumulative target.
CREATE FUNCTION fn_inventory_value_preview_stock_after(p_source uuid,p_after numeric,p_policy jsonb,p_version integer,p_restores uuid DEFAULT NULL,p_force boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog,public AS $$
DECLARE v_nodes uuid[];v_item record;v_edge record;v_node stock_value_nodes%ROWTYPE;v_values jsonb:='{}';v_owned jsonb:='{}';v_projection jsonb;
 v_value numeric;v_target jsonb;v_parent_value numeric;v_original record;
BEGIN
 WITH RECURSIVE descendants(id) AS (SELECT p_source UNION SELECT dependency.child_node_id FROM descendants parent JOIN stock_value_edges dependency ON dependency.parent_node_id=parent.id)
 SELECT array_agg(id) INTO v_nodes FROM (SELECT id FROM descendants LIMIT 50001) bounded;
 IF cardinality(v_nodes)>50000 THEN RAISE EXCEPTION '库存累计成本后继超过本次核对范围；本次未确认' USING ERRCODE='40001',CONSTRAINT='stock_value_precision_scope_limit';END IF;
 FOR v_item IN SELECT id FROM stock_value_nodes WHERE id=ANY(v_nodes) ORDER BY node_sequence LOOP
  SELECT * INTO STRICT v_node FROM stock_value_nodes WHERE id=v_item.id;
  v_value:=CASE WHEN v_node.id=p_source THEN p_after ELSE v_node.basis_value_local END;
  IF v_node.id<>p_source THEN
   FOR v_edge IN SELECT * FROM stock_value_edges WHERE child_node_id=v_node.id AND parent_node_id=ANY(v_nodes) ORDER BY id LOOP
    v_parent_value:=(v_values->>v_edge.parent_node_id::text)::numeric;
    IF v_parent_value IS NULL THEN RAISE EXCEPTION 'Inventory revaluation stock graph is not topological' USING ERRCODE='40001',CONSTRAINT='stock_value_precision_scope_cycle';END IF;
    IF NOT p_force AND v_parent_value=fn_inventory_value_parent_revision_value(v_edge.parent_node_id,v_edge.last_parent_revision,false) THEN
     v_target:=jsonb_build_object('amount',v_edge.allocated_amount_local);
    ELSE v_target:=fn_inventory_value_target_after_with_policy(v_edge.id,v_parent_value,p_version,p_policy,p_restores);END IF;
    v_value:=v_value+(v_target->>'amount')::numeric-v_edge.allocated_amount_local;
   END LOOP;
  END IF;
  IF NOT fn_financial_book_amount_is_exact(v_value) OR v_value<0 OR v_node.kind='POOL' AND v_node.quantity_basis=0 AND v_value<>0 THEN
   RAISE EXCEPTION '累计成本新目标超过该原来源或存储范围；本次未确认' USING ERRCODE='22003';END IF;
  v_projection:=NULL;
  v_projection:=fn_inventory_value_restore_projection(v_node,v_value,p_restores);
  IF v_projection IS NULL THEN
   IF NOT p_force AND v_value=v_node.basis_value_local THEN v_projection:=fn_inventory_value_current_projection(v_node);
   ELSE v_projection:=fn_inventory_value_after_projection(v_node,v_value,p_version,p_policy);END IF;
  END IF;
  v_values:=v_values||jsonb_build_object(v_node.id::text,v_value);v_owned:=v_owned||jsonb_build_object(v_node.id::text,v_projection);
 END LOOP;
 RETURN jsonb_build_object('values',v_values,'projections',v_owned,'nodes',to_jsonb(v_nodes));
END $$;

-- This predicate describes actual durable work, independently of whether the
-- cost is known. An unknown source is never converted to a known zero here.
CREATE FUNCTION fn_inventory_value_revaluation_nodes_complete(p_nodes uuid[]) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT p_nodes IS NOT NULL AND NOT EXISTS(SELECT 1 FROM stock_value_tasks task JOIN stock_value_edges edge ON edge.id=task.edge_id
   WHERE task.status='PENDING' AND (edge.parent_node_id=ANY(p_nodes) OR edge.child_node_id=ANY(p_nodes)))
 AND NOT EXISTS(SELECT 1 FROM stock_value_jobs WHERE status<>'APPLIED' AND source_node_id=ANY(p_nodes))
 AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_tasks WHERE status='PENDING'
   AND (input_node_id=ANY(p_nodes) OR output_source_node_id=ANY(p_nodes)))
 AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_dirty dirty JOIN stock_value_production_cost_objects object USING(execution_segment_id)
   WHERE object.current_revision_id IS NOT NULL AND dirty.observed_revision>dirty.cleared_revision AND dirty.input_node_id=ANY(p_nodes))
 AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_objects object WHERE object.business_refresh_pending
   AND (EXISTS(SELECT 1 FROM stock_value_production_cost_inputs input WHERE input.execution_segment_id=object.execution_segment_id AND input.input_node_id=ANY(p_nodes))
     OR EXISTS(SELECT 1 FROM stock_value_production_cost_outputs output WHERE output.execution_segment_id=object.execution_segment_id AND output.source_node_id=ANY(p_nodes))))
$$;
CREATE FUNCTION fn_inventory_value_revaluation_work_complete(p_event uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT coalesce((SELECT CASE WHEN event.valuation_root_kind='PLAN' THEN fn_inventory_value_revaluation_nodes_complete(revision.precision_closure_nodes)
    ELSE fn_inventory_value_revaluation_nodes_complete(job.precision_closure_nodes) END
  FROM stock_value_events event LEFT JOIN stock_value_jobs job ON job.event_id=coalesce(event.valuation_root_id,event.id)
  LEFT JOIN stock_value_production_cost_revisions revision ON revision.id=event.valuation_root_id
  WHERE event.id=p_event AND (job.precision_closure_nodes IS NOT NULL OR revision.precision_closure_nodes IS NOT NULL)),false)
$$;

CREATE FUNCTION fn_inventory_value_release_completed_precision(p_keys text[]) RETURNS void LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_root uuid;
BEGIN
 FOR v_root IN SELECT DISTINCT precision_origin_id FROM stock_value_jobs WHERE NOT precision_closure_complete AND precision_closure_keys&&p_keys AND precision_origin_id IS NOT NULL
  UNION SELECT DISTINCT precision_origin_id FROM stock_value_production_cost_objects WHERE precision_closure_pending AND precision_closure_keys&&p_keys AND precision_origin_id IS NOT NULL LOOP
  PERFORM fn_inventory_value_finish_root(v_root);
 END LOOP;
END $$;

-- Ordinary physical edge creation remains a bounded key claim and indexed
-- pending lookup. The exceptional source revaluation performs the DAG walk.
CREATE FUNCTION fn_inventory_value_check_new_dependency() RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$
DECLARE ids uuid[];keys text[];key text;v_owned_root uuid;
BEGIN
 IF TG_TABLE_NAME='stock_value_edges' THEN ids:=ARRAY[NEW.parent_node_id,NEW.child_node_id];
 ELSIF TG_TABLE_NAME='stock_value_production_cost_inputs' THEN ids:=ARRAY[NEW.input_node_id];
 ELSE ids:=ARRAY[NEW.source_node_id];END IF;
 IF TG_TABLE_NAME<>'stock_value_edges' THEN
  IF current_setting('app.inventory_value_legacy_refresh',true)='1' AND EXISTS(
    SELECT 1 FROM stock_value_production_cost_objects object WHERE object.execution_segment_id=NEW.execution_segment_id
     AND object.business_refresh_pending AND object.business_refresh_precision_version=1) THEN RETURN NEW;END IF;
 END IF;
 IF TG_TABLE_NAME='stock_value_production_cost_inputs' THEN
  SELECT object.business_refresh_precision_root_id INTO v_owned_root FROM stock_value_production_cost_objects object
   WHERE object.execution_segment_id=NEW.execution_segment_id AND object.business_refresh_pending
    AND object.business_refresh_precision_version=2 AND object.business_refresh_precision_root_id IS NOT NULL
    AND current_setting('app.inventory_value_business_refresh_root',true)=object.business_refresh_precision_root_id::text
    AND current_setting('app.inventory_value_legacy_refresh',true)='2'
    AND object.business_refresh_precision_policy=fn_business_precision_snapshot()
    AND object.precision_forecast_hash IS NOT NULL AND object.precision_closure_nodes @> ids;
 END IF;
 IF EXISTS(SELECT 1 FROM stock_value_jobs WHERE status<>'APPLIED' AND precision_closure_nodes IS NULL)
  OR EXISTS(SELECT 1 FROM stock_value_production_cost_tasks WHERE status='PENDING' AND target_proof IS NULL) THEN
  RAISE EXCEPTION '原已提交成本任务仍在恢复，请保留原单稍后重试；本次未确认' USING ERRCODE='40001',CONSTRAINT='stock_value_precision_scope_busy';END IF;
 SELECT array_agg(DISTINCT fn_inventory_value_precision_key(pool.goods_id,pool.color_id) ORDER BY fn_inventory_value_precision_key(pool.goods_id,pool.color_id))
 INTO keys FROM stock_value_nodes n JOIN stock_value_pools pool ON pool.id=n.pool_id WHERE n.id=ANY(ids);
 FOREACH key IN ARRAY keys LOOP PERFORM fn_inventory_value_try_precision_claim(key);END LOOP;
 IF fn_inventory_value_precision_marked(keys,v_owned_root) THEN
  RAISE EXCEPTION '该库存成本后继正在核对，请保留原单稍后重试；本次未确认' USING ERRCODE='40001',CONSTRAINT='stock_value_precision_scope_busy';END IF;
 RETURN NEW;
END $$;
CREATE FUNCTION fn_inventory_value_release_job_scope() RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$
BEGIN
 IF NEW.status='APPLIED' AND OLD.status IS DISTINCT FROM 'APPLIED' AND NEW.precision_closure_keys IS NOT NULL THEN
  PERFORM fn_inventory_value_release_completed_precision(NEW.precision_closure_keys);
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER trg_zz_inventory_value_job_scope AFTER UPDATE ON stock_value_jobs FOR EACH ROW EXECUTE FUNCTION fn_inventory_value_release_job_scope();
CREATE TRIGGER trg_00a_inventory_value_dependency BEFORE INSERT ON stock_value_edges FOR EACH ROW EXECUTE FUNCTION fn_inventory_value_check_new_dependency();
CREATE TRIGGER trg_00a_inventory_value_dependency BEFORE INSERT ON stock_value_production_cost_inputs FOR EACH ROW EXECUTE FUNCTION fn_inventory_value_check_new_dependency();
CREATE TRIGGER trg_00a_inventory_value_dependency BEFORE INSERT ON stock_value_production_cost_outputs FOR EACH ROW EXECUTE FUNCTION fn_inventory_value_check_new_dependency();

DO $precision_object_projection_fields$
DECLARE definition text;needle text:='''current_revision_id''';
BEGIN
 SELECT pg_get_functiondef('fn_guard_stock_value_cost_projection()'::regprocedure) INTO definition;
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review production cost coordination projection identity';END IF;
 EXECUTE replace(definition,needle,needle||',''precision_input_ancestor_nodes'',''precision_closure_keys'',''precision_closure_nodes'',''precision_closure_pending'',''precision_closure_complete'',''precision_origin_id'',''precision_work_txid'',''precision_forecast_hash'',''business_refresh_precision_version'',''business_refresh_precision_policy'',''business_refresh_precision_root_id''');
END $precision_object_projection_fields$;

CREATE FUNCTION fn_inventory_value_production_input_ancestors(p_scope uuid) RETURNS uuid[] LANGUAGE sql STABLE AS $$
 WITH RECURSIVE ancestors(id) AS (
  SELECT input_node_id FROM stock_value_production_cost_inputs WHERE execution_segment_id=p_scope
  UNION SELECT candidate.result_node_id FROM v_production_cost_input_candidates candidate JOIN stock_value_production_cost_objects object ON object.execution_segment_id=p_scope
   WHERE object.business_refresh_pending AND candidate.node_active AND fn_production_execution_cost_scope(candidate.member_segment_id)=p_scope
  UNION SELECT previous.node_id FROM ancestors child CROSS JOIN LATERAL fn_inventory_value_precision_predecessors(child.id) previous
 ) SELECT coalesce(array_agg(id ORDER BY id),'{}'::uuid[]) FROM ancestors
$$;
CREATE FUNCTION fn_inventory_value_production_inputs_ready(p_scope uuid) RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE v_nodes uuid[];
BEGIN
 SELECT precision_input_ancestor_nodes INTO v_nodes FROM stock_value_production_cost_objects
  WHERE execution_segment_id=p_scope AND precision_closure_pending AND NOT precision_closure_complete
   AND precision_input_ancestor_nodes IS NOT NULL AND fn_inventory_value_root_incomplete(precision_origin_id);
 IF v_nodes IS NULL THEN v_nodes:=fn_inventory_value_production_input_ancestors(p_scope);END IF;
 RETURN NOT EXISTS(SELECT 1 FROM stock_value_tasks task JOIN stock_value_edges edge ON edge.id=task.edge_id WHERE edge.child_node_id=ANY(v_nodes) AND task.status='PENDING')
 AND NOT EXISTS(SELECT 1 FROM stock_value_jobs job WHERE job.source_node_id=ANY(v_nodes) AND job.status<>'APPLIED')
 AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_tasks task WHERE task.output_source_node_id=ANY(v_nodes) AND task.status='PENDING')
 AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_dirty dirty JOIN stock_value_production_cost_outputs output USING(execution_segment_id)
   WHERE output.source_node_id=ANY(v_nodes) AND dirty.execution_segment_id<>p_scope AND dirty.observed_revision>dirty.cleared_revision);
END $$;

-- Preview the original whole-target graph. This is a rehearsal of the very
-- same edge/production target functions, never another balance authority.
CREATE FUNCTION fn_inventory_value_preflight_revaluation(p_source uuid,p_after numeric,p_policy jsonb,p_version integer,p_restores uuid,p_event uuid)
RETURNS boolean LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog,public AS $$
<<preview>>
DECLARE v_nodes uuid[];v_verified uuid[];v_keys text[];v_key text;v_node stock_value_nodes%ROWTYPE;v_item record;v_link record;
 v_values jsonb:='{}';v_changed uuid[]:='{}';v_value numeric;v_amount numeric;v_desired jsonb;v_plan jsonb;v_input jsonb;v_output jsonb;
 v_original_input jsonb;v_allocated numeric;v_prefix numeric;v_projection jsonb;v_processed integer:=0;v_original record;
 v_restore_refs jsonb:='{}';v_node_restore uuid;v_parent_restore uuid;v_forecast jsonb;
BEGIN
 v_nodes:=fn_inventory_value_precision_scope(ARRAY[p_source]);
 SELECT array_agg(DISTINCT fn_inventory_value_precision_key(pool.goods_id,pool.color_id) ORDER BY fn_inventory_value_precision_key(pool.goods_id,pool.color_id))
 INTO v_keys FROM stock_value_nodes n JOIN stock_value_pools pool ON pool.id=n.pool_id WHERE n.id=ANY(v_nodes);
 IF v_keys IS NULL THEN RAISE EXCEPTION 'Revaluation requires its real source' USING ERRCODE='23514';END IF;
 FOREACH v_key IN ARRAY v_keys LOOP PERFORM fn_inventory_value_try_precision_claim(v_key);END LOOP;
 PERFORM fn_inventory_value_release_completed_precision(v_keys);
 v_verified:=fn_inventory_value_precision_scope(ARRAY[p_source]);
 IF v_verified IS DISTINCT FROM v_nodes OR fn_inventory_value_precision_marked(v_keys) OR NOT fn_inventory_value_revaluation_nodes_complete(v_nodes) THEN
  RAISE EXCEPTION '库存成本来源或后继仍在处理，请保留原单重试；本次未确认' USING ERRCODE='40001',CONSTRAINT='stock_value_precision_scope_busy';END IF;
 CREATE TEMP TABLE IF NOT EXISTS uten_value_revaluation_nodes(node_id uuid PRIMARY KEY,remaining integer NOT NULL,done boolean NOT NULL DEFAULT false) ON COMMIT DROP;
 CREATE TEMP TABLE IF NOT EXISTS uten_value_revaluation_links(parent_id uuid NOT NULL,child_id uuid NOT NULL,kind text NOT NULL,edge_id uuid,scope_id uuid,PRIMARY KEY(parent_id,child_id,kind)) ON COMMIT DROP;
 CREATE INDEX IF NOT EXISTS uten_value_revaluation_links_child ON uten_value_revaluation_links(child_id);
 CREATE INDEX IF NOT EXISTS uten_value_revaluation_ready ON uten_value_revaluation_nodes(node_id) WHERE NOT done AND remaining=0;
 TRUNCATE pg_temp.uten_value_revaluation_links,pg_temp.uten_value_revaluation_nodes;
 INSERT INTO pg_temp.uten_value_revaluation_links
 SELECT edge.parent_node_id,edge.child_node_id,'EDGE',edge.id,NULL FROM stock_value_edges edge WHERE edge.parent_node_id=ANY(v_nodes) AND edge.child_node_id=ANY(v_nodes)
 UNION ALL SELECT cost_input.input_node_id,cost_output.source_node_id,'PRODUCTION',NULL,cost_input.execution_segment_id
 FROM stock_value_production_cost_inputs cost_input JOIN stock_value_production_cost_outputs cost_output USING(execution_segment_id)
 WHERE cost_input.input_node_id=ANY(v_nodes) AND cost_output.source_node_id=ANY(v_nodes);
 INSERT INTO pg_temp.uten_value_revaluation_links
 SELECT candidate.result_node_id,output.source_node_id,'PRODUCTION',NULL,object.execution_segment_id
 FROM v_production_cost_input_candidates candidate JOIN stock_value_production_cost_objects object
  ON object.execution_segment_id=fn_production_execution_cost_scope(candidate.member_segment_id)
 JOIN stock_value_production_cost_outputs output USING(execution_segment_id)
 WHERE candidate.node_active AND object.business_refresh_pending AND candidate.result_node_id=ANY(v_nodes) AND output.source_node_id=ANY(v_nodes)
  AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_inputs registered WHERE registered.approved_posting_id=candidate.approved_posting_id)
 ON CONFLICT DO NOTHING;
 INSERT INTO pg_temp.uten_value_revaluation_nodes(node_id,remaining)
 SELECT id,coalesce((SELECT count(*) FROM pg_temp.uten_value_revaluation_links dependency WHERE dependency.child_id=id),0) FROM unnest(v_nodes) id;
 LOOP
  SELECT node_id INTO v_key FROM pg_temp.uten_value_revaluation_nodes WHERE NOT done AND remaining=0 ORDER BY node_id LIMIT 1;
  IF NOT FOUND THEN EXIT;END IF;
  UPDATE pg_temp.uten_value_revaluation_nodes SET done=true WHERE node_id=v_key::uuid;
  UPDATE pg_temp.uten_value_revaluation_nodes child SET remaining=child.remaining-counts.count FROM
   (SELECT child_id,count(*)::integer count FROM pg_temp.uten_value_revaluation_links WHERE parent_id=v_key::uuid GROUP BY child_id) counts WHERE child.node_id=counts.child_id;
  v_processed:=v_processed+1;
 END LOOP;
 IF v_processed<>cardinality(v_nodes) THEN RAISE EXCEPTION '成本来源存在循环；本次未确认' USING ERRCODE='40001',CONSTRAINT='stock_value_precision_scope_cycle';END IF;
 v_forecast:=fn_inventory_value_rehearse_root_waves(p_source,p_after,p_policy,p_version,p_restores,v_nodes);
 PERFORM set_config('app.inventory_revaluation_preflight',jsonb_build_object('source',p_source,'event',p_event,'nodes',v_nodes,'keys',v_keys,'after',p_after,'forecastHash',v_forecast->>'hash')::text,true);
 RETURN true;
END $$;

CREATE FUNCTION fn_inventory_value_capture_job_scope() RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$
DECLARE context jsonb;revision stock_value_production_cost_revisions%ROWTYPE;root_job stock_value_jobs%ROWTYPE;source stock_value_nodes%ROWTYPE;
BEGIN
 SELECT r.* INTO revision FROM stock_value_production_cost_tasks task
  JOIN stock_value_production_cost_revisions r ON r.id=task.revision_id WHERE task.id=NEW.event_id;
 IF revision.id IS NOT NULL THEN
  NEW.precision_origin_id:=coalesce(revision.precision_origin_id,revision.id);
  NEW.precision_closure_keys:=revision.precision_closure_keys;
  NEW.precision_closure_nodes:=revision.precision_closure_nodes;
  SELECT * INTO root_job FROM stock_value_jobs WHERE event_id=revision.precision_origin_id;
  IF root_job.event_id IS NOT NULL THEN NEW.precision_closure_nodes:=root_job.precision_closure_nodes;
  ELSIF NEW.precision_closure_nodes IS NULL THEN SELECT precision_closure_nodes,coalesce(NEW.precision_closure_keys,precision_closure_keys) INTO NEW.precision_closure_nodes,NEW.precision_closure_keys
    FROM stock_value_production_cost_objects WHERE execution_segment_id=revision.execution_segment_id;END IF;
 ELSE
  context:=nullif(current_setting('app.inventory_revaluation_preflight',true),'')::jsonb;
  IF (context->>'event')::uuid IS DISTINCT FROM NEW.event_id OR (context->>'source')::uuid IS DISTINCT FROM NEW.source_node_id THEN
   RAISE EXCEPTION 'A new source revaluation requires its complete same-transaction rehearsal' USING ERRCODE='23514';END IF;
  SELECT * INTO STRICT source FROM stock_value_nodes WHERE id=NEW.source_node_id;
  IF source.basis_value_local IS DISTINCT FROM (context->>'after')::numeric THEN RAISE EXCEPTION 'Rehearsed source amount changed before its job' USING ERRCODE='23514';END IF;
  NEW.precision_origin_id:=NEW.event_id;
  NEW.precision_protocol_version:=1;NEW.precision_forecast_hash:=context->>'forecastHash';
  SELECT array_agg(value::uuid) INTO NEW.precision_closure_nodes FROM jsonb_array_elements_text(context->'nodes') value;
  SELECT array_agg(value) INTO NEW.precision_closure_keys FROM jsonb_array_elements_text(context->'keys') value;
 END IF;
 NEW.precision_closure_complete:=NEW.precision_closure_nodes IS NULL;
 NEW.precision_created_txid:=txid_current();
 RETURN NEW;
END $$;
CREATE TRIGGER trg_00_inventory_value_job_scope BEFORE INSERT ON stock_value_jobs FOR EACH ROW EXECUTE FUNCTION fn_inventory_value_capture_job_scope();

CREATE FUNCTION fn_inventory_value_capture_event_root() RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$
DECLARE revision stock_value_production_cost_revisions%ROWTYPE;root stock_value_events%ROWTYPE;
BEGIN
 IF NEW.operation='COST_ALLOCATE' THEN
  SELECT r.* INTO STRICT revision FROM stock_value_production_cost_tasks task
   JOIN stock_value_production_cost_revisions r ON r.id=task.revision_id WHERE task.id=NEW.id;
  NEW.valuation_root_id:=coalesce(revision.precision_origin_id,revision.id);
  NEW.valuation_root_kind:=CASE WHEN EXISTS(SELECT 1 FROM stock_value_events WHERE id=NEW.valuation_root_id) THEN 'EVENT' ELSE 'PLAN' END;
 ELSIF NEW.operation IN('COST_ADJUST','COST_ADJUST_REVERSE') THEN
  NEW.valuation_root_id:=NEW.id;NEW.valuation_root_kind:='EVENT';
  IF NEW.operation='COST_ADJUST_REVERSE' THEN NEW.projection_restore_of_event_id:=NEW.reversal_of_event_id;END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_00a_inventory_value_event_root BEFORE INSERT ON stock_value_events FOR EACH ROW EXECUTE FUNCTION fn_inventory_value_capture_event_root();

CREATE FUNCTION fn_inventory_value_preflight_plan(p_revision uuid) RETURNS boolean LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_plan stock_value_production_cost_revisions%ROWTYPE;v_root uuid;v_seeds uuid[];v_nodes uuid[];v_verified uuid[];
 v_keys text[];v_key text;v_forecast jsonb;v_policy jsonb;
BEGIN
 SELECT r.* INTO STRICT v_plan FROM stock_value_production_cost_revisions r WHERE r.id=p_revision;
 v_root:=coalesce(v_plan.precision_origin_id,v_plan.id);
 SELECT array_agg(DISTINCT id ORDER BY id) INTO v_seeds FROM (
  SELECT (i->>'node')::uuid id FROM stock_value_production_cost_revisions r CROSS JOIN LATERAL jsonb_array_elements(r.input_snapshot) i WHERE r.id=v_root OR r.precision_origin_id=v_root
  UNION SELECT (o->>'source')::uuid FROM stock_value_production_cost_revisions r CROSS JOIN LATERAL jsonb_array_elements(r.output_snapshot) o WHERE r.id=v_root OR r.precision_origin_id=v_root
  UNION SELECT candidate.result_node_id FROM v_production_cost_input_candidates candidate JOIN stock_value_production_cost_objects object
   ON object.execution_segment_id=fn_production_execution_cost_scope(candidate.member_segment_id)
   WHERE candidate.node_active AND object.business_refresh_pending AND (object.precision_origin_id=v_root OR object.business_refresh_precision_root_id=v_root)
 ) roots;
 IF v_seeds IS NULL THEN RETURN true;END IF;
 v_nodes:=fn_inventory_value_precision_scope(v_seeds);
 SELECT array_agg(DISTINCT fn_inventory_value_precision_key(pool.goods_id,pool.color_id) ORDER BY fn_inventory_value_precision_key(pool.goods_id,pool.color_id))
 INTO v_keys FROM stock_value_nodes n JOIN stock_value_pools pool ON pool.id=n.pool_id WHERE n.id=ANY(v_nodes);
 FOREACH v_key IN ARRAY v_keys LOOP PERFORM fn_inventory_value_try_precision_claim(v_key);END LOOP;
 v_verified:=fn_inventory_value_precision_scope(v_seeds);
 IF v_verified IS DISTINCT FROM v_nodes OR fn_inventory_value_precision_marked(v_keys,v_root) THEN
  RAISE EXCEPTION '生产成本后继已变化，请保留原方案稍后重试；本次未确认' USING ERRCODE='40001',CONSTRAINT='stock_value_precision_scope_busy';END IF;
 v_policy:=CASE WHEN v_plan.value_precision_version=1 THEN NULL ELSE coalesce(v_plan.request_precision_policy,v_plan.business_precision_policy) END;
 v_forecast:=fn_inventory_value_rehearse_plan_root(v_root,v_nodes,v_plan.value_precision_version,v_policy);
 UPDATE stock_value_production_cost_objects object SET precision_input_ancestor_nodes=(SELECT array_agg(node_id ORDER BY node_id) FROM pg_temp.uten_iv_preview_ancestors WHERE scope_id=object.execution_segment_id),precision_closure_keys=v_keys,precision_closure_nodes=v_nodes,precision_forecast_hash=v_forecast->>'hash'
  WHERE precision_work_txid=txid_current() AND (precision_origin_id=v_root OR business_refresh_precision_root_id=v_root);
 UPDATE stock_value_jobs SET precision_closure_keys=v_keys,precision_closure_nodes=v_nodes,precision_forecast_hash=v_forecast->>'hash',precision_protocol_version=1
  WHERE precision_origin_id=v_root AND precision_created_txid=txid_current();
 PERFORM fn_inventory_value_finish_root(v_root);
 RETURN true;
END $$;

-- Preserve the existing complete production formula. Only an exact original
-- operand point restores its actual previous share; before is never redivided.
CREATE FUNCTION fn_inventory_value_production_target_after(p_revision jsonb,p_input jsonb,p_output jsonb,p_parent_values jsonb,
 p_policy jsonb,p_version integer,p_restores_event uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE original stock_value_production_cost_tasks%ROWTYPE;previous stock_value_production_cost_tasks%ROWTYPE;
 original_plan stock_value_production_cost_revisions%ROWTYPE;prior_plan stock_value_production_cost_revisions%ROWTYPE;
 before_input jsonb;before_output jsonb;current_input jsonb;amount numeric;version integer:=p_version;policy jsonb:=p_policy;
 current_share stock_value_production_cost_shares%ROWTYPE;target numeric:=(p_revision->>'target_qty_base')::numeric;zero_history jsonb;
BEGIN
 SELECT * INTO current_share FROM stock_value_production_cost_shares WHERE input_node_id=(p_input->>'node')::uuid AND output_source_node_id=(p_output->>'source')::uuid;
 IF p_restores_event IS NOT NULL THEN
  SELECT task.* INTO original FROM stock_value_production_cost_tasks task JOIN stock_value_production_cost_revisions revision ON revision.id=task.revision_id
   LEFT JOIN stock_value_events event ON event.id=revision.source_event_id
   WHERE task.input_node_id=(p_input->>'node')::uuid AND task.output_source_node_id=(p_output->>'source')::uuid AND task.status='APPLIED'
    AND (revision.source_event_id=p_restores_event OR event.valuation_root_id=p_restores_event)
   ORDER BY task.task_sequence DESC LIMIT 1;
  IF original.id IS NOT NULL THEN
   SELECT * INTO STRICT original_plan FROM stock_value_production_cost_revisions WHERE id=original.revision_id;
   SELECT approved.* INTO prior_plan FROM stock_value_production_cost_revisions approved
    WHERE approved.execution_segment_id=original.execution_segment_id AND approved.version=original_plan.previous_version;
   SELECT i INTO before_input FROM jsonb_array_elements(prior_plan.input_snapshot) i WHERE (i->>'node')::uuid=original.input_node_id;
   SELECT o INTO before_output FROM jsonb_array_elements(prior_plan.output_snapshot) o WHERE (o->>'source')::uuid=original.output_source_node_id;
   IF before_input IS NOT NULL AND before_output IS NOT NULL AND (before_input->>'value')::numeric=(p_input->>'value')::numeric
    AND (before_input->>'quantityBasis')::numeric=(p_input->>'quantityBasis')::numeric AND (before_input->>'returnedQty')::numeric=(p_input->>'returnedQty')::numeric
    AND before_input->>'returnCursor' IS NOT DISTINCT FROM p_input->>'returnCursor'
    AND prior_plan.target_qty_base=target AND (before_output->>'from')::numeric=(p_output->>'from')::numeric AND (before_output->>'to')::numeric=(p_output->>'to')::numeric THEN
    SELECT * INTO previous FROM stock_value_production_cost_tasks WHERE id=original.previous_task_id;
    version:=coalesce(previous.value_precision_version,1);policy:=CASE WHEN version=1 THEN NULL ELSE previous.business_precision_policy END;
    RETURN jsonb_build_object('amount',original.before_share_local,'version',version,'policy',policy,'restoresTaskId',original.id,'restoresValueEventId',original.value_event_id);
   END IF;
  END IF;
 END IF;
 IF target=0 THEN amount:=0;
 ELSIF (p_revision->>'output_qty_base')::numeric>target THEN amount:=coalesce(current_share.allocated_value_local,0);
 ELSE
  SELECT * INTO previous FROM stock_value_production_cost_tasks WHERE id=current_share.last_task_id;
  IF previous.id IS NOT NULL AND previous.input_value_local=(p_input->>'value')::numeric
   AND previous.input_quantity_basis=(p_input->>'quantityBasis')::numeric AND previous.input_returned_qty=(p_input->>'returnedQty')::numeric
   AND previous.input_return_cursor_id IS NOT DISTINCT FROM (p_input->>'returnCursor')::uuid
   AND previous.denominator=target AND previous.output_from=(p_output->>'from')::numeric AND previous.output_to=(p_output->>'to')::numeric THEN
   amount:=current_share.allocated_value_local;version:=previous.value_precision_version;policy:=previous.business_precision_policy;
  ELSE amount:=fn_inventory_value_interval((p_input->>'value')::numeric,(p_output->>'from')::numeric*((p_input->>'quantityBasis')::numeric-(p_input->>'returnedQty')::numeric),
    (p_output->>'to')::numeric*((p_input->>'quantityBasis')::numeric-(p_input->>'returnedQty')::numeric),target*(p_input->>'quantityBasis')::numeric,version,policy,true);END IF;
 END IF;
 IF amount=0 AND coalesce(current_share.allocated_value_local,0)>0 THEN
  zero_history:=fn_inventory_value_share_zero_history(current_share.last_task_id);
  IF zero_history IS NOT NULL THEN
   SELECT * INTO previous FROM stock_value_production_cost_tasks WHERE id=(zero_history->>'firstProducerTaskId')::uuid;
   SELECT * INTO original FROM stock_value_production_cost_tasks WHERE id=previous.previous_task_id;
   version:=coalesce(original.value_precision_version,1);policy:=CASE WHEN version=1 THEN NULL ELSE original.business_precision_policy END;
   RETURN jsonb_build_object('amount',amount,'version',version,'policy',policy,'restoresTaskId',previous.id,'restoresValueEventId',previous.value_event_id);
  END IF;
 END IF;
 RETURN jsonb_build_object('amount',amount,'version',version,'policy',policy);
END $$;


CREATE FUNCTION fn_inventory_value_revaluation_contract_version() RETURNS integer LANGUAGE sql IMMUTABLE AS $$ SELECT 1 $$;

-- A book projection is an already recorded fact. Directed rational bounds can
-- establish coverage, but rounding a bound must never create a reported amount.
CREATE OR REPLACE FUNCTION fn_inventory_value_book_projection(p_node uuid) RETURNS numeric LANGUAGE sql STABLE AS $$
 SELECT CASE WHEN n.pending_parents=0 AND n.bound_revision=n.revision AND n.bound_lower IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM stock_value_jobs WHERE status<>'APPLIED')
   AND NOT EXISTS(SELECT 1 FROM stock_value_tasks WHERE status='PENDING')
   AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_tasks WHERE status='PENDING')
   AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_dirty dirty JOIN stock_value_production_cost_objects object USING(execution_segment_id) WHERE object.current_revision_id IS NOT NULL AND dirty.observed_revision>dirty.cleared_revision)
   AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_objects WHERE business_refresh_pending)
  THEN n.basis_value_local END FROM stock_value_nodes n WHERE n.id=p_node
$$;

ALTER TABLE stock_value_production_cost_tasks ENABLE ALWAYS TRIGGER trg_01_inventory_value_production_target;
ALTER TABLE stock_value_edges ENABLE ALWAYS TRIGGER trg_00a_inventory_value_dependency;
ALTER TABLE stock_value_production_cost_inputs ENABLE ALWAYS TRIGGER trg_00a_inventory_value_dependency;
ALTER TABLE stock_value_production_cost_outputs ENABLE ALWAYS TRIGGER trg_00a_inventory_value_dependency;
ALTER TABLE stock_value_jobs ENABLE ALWAYS TRIGGER trg_00_inventory_value_job_scope;
ALTER TABLE stock_value_jobs ENABLE ALWAYS TRIGGER trg_zz_inventory_value_job_scope;
ALTER TABLE stock_value_events ENABLE ALWAYS TRIGGER trg_00a_inventory_value_event_root;

-- Publication uses the same durable closure authority as writers. A previously
-- known shipment must remain pending while its upstream production is dirty.
CREATE FUNCTION fn_inventory_value_node_revaluation_pending(p_node uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM stock_value_jobs root WHERE NOT root.precision_closure_complete
   AND root.precision_closure_nodes @> ARRAY[p_node] AND NOT fn_inventory_value_revaluation_nodes_complete(root.precision_closure_nodes))
 OR EXISTS(SELECT 1 FROM stock_value_production_cost_objects root WHERE root.precision_closure_pending
   AND root.precision_closure_nodes @> ARRAY[p_node] AND NOT fn_inventory_value_revaluation_nodes_complete(root.precision_closure_nodes))
 -- Already committed pre-transition work has no invented/backfilled closure.
 -- Keep it conservative until its original work really drains.
 OR EXISTS(SELECT 1 FROM stock_value_jobs WHERE status<>'APPLIED' AND precision_closure_nodes IS NULL)
 OR EXISTS(SELECT 1 FROM stock_value_production_cost_tasks WHERE status='PENDING' AND target_proof IS NULL)
 OR EXISTS(SELECT 1 FROM stock_value_production_cost_dirty dirty JOIN stock_value_events event ON event.id=dirty.source_event_id JOIN stock_value_production_cost_objects object USING(execution_segment_id)
   WHERE object.current_revision_id IS NOT NULL AND dirty.observed_revision>dirty.cleared_revision AND event.valuation_root_id IS NULL)
 OR EXISTS(SELECT 1 FROM stock_value_production_cost_objects WHERE business_refresh_pending AND (precision_closure_nodes IS NULL OR business_refresh_precision_root_id IS NULL))
$$;

DO $actual_cost_publication_pending$
DECLARE name text;definition text;needle text:='node.pending_parents > 0';
BEGIN
 FOREACH name IN ARRAY ARRAY['v_stock_actual_cogs_postings','v_stock_actual_sales_cost_coverage'] LOOP
  SELECT pg_get_viewdef(to_regclass(name),true) INTO definition;
  IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review current actual cost pending view %',name;END IF;
  EXECUTE 'CREATE OR REPLACE VIEW '||quote_ident(name)||' AS '||replace(definition,needle,
    '(node.pending_parents > 0 OR fn_inventory_value_node_revaluation_pending(node.id))');
 END LOOP;
END $actual_cost_publication_pending$;

CREATE FUNCTION fn_inventory_value_event_root(p_event uuid) RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT coalesce(valuation_root_id,id) FROM stock_value_events WHERE id=p_event
$$;
CREATE FUNCTION fn_inventory_value_root_nodes(p_root uuid) RETURNS uuid[] LANGUAGE sql STABLE AS $$
 SELECT array_agg(DISTINCT member ORDER BY member) FROM (
  SELECT unnest(precision_closure_nodes) member FROM stock_value_jobs WHERE event_id=p_root
  UNION ALL SELECT unnest(precision_closure_nodes) FROM stock_value_production_cost_revisions WHERE id=p_root OR precision_origin_id=p_root
  UNION ALL SELECT unnest(precision_closure_nodes) FROM stock_value_production_cost_objects WHERE precision_origin_id=p_root OR business_refresh_precision_root_id=p_root
 ) actual_roots
$$;
CREATE OR REPLACE FUNCTION fn_inventory_value_revaluation_work_complete(p_event uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT coalesce((SELECT fn_inventory_value_revaluation_nodes_complete(scope.nodes)
  FROM (SELECT fn_inventory_value_root_nodes(fn_inventory_value_event_root(p_event)) nodes) scope WHERE scope.nodes IS NOT NULL),false)
$$;
CREATE FUNCTION fn_inventory_value_root_keys(p_root uuid) RETURNS text[] LANGUAGE sql STABLE AS $$
 SELECT coalesce((SELECT precision_closure_keys FROM stock_value_jobs WHERE event_id=p_root),
  (SELECT precision_closure_keys FROM stock_value_production_cost_objects WHERE (precision_origin_id=p_root OR business_refresh_precision_root_id=p_root) AND precision_closure_keys IS NOT NULL ORDER BY execution_segment_id LIMIT 1),
  (SELECT precision_closure_keys FROM stock_value_production_cost_revisions WHERE id=p_root OR precision_origin_id=p_root ORDER BY created_at,id LIMIT 1))
$$;

-- A source may need several waves: settled stock -> ready cost plans -> their
-- producers -> stock. These predicates order only one existing root's durable
-- work, never acquire another inventory lock and never classify unknown as 0.
CREATE FUNCTION fn_inventory_value_root_next_refresh(p_root uuid) RETURNS uuid LANGUAGE sql STABLE AS $$
 WITH candidates AS (
  SELECT dirty.execution_segment_id FROM stock_value_production_cost_dirty dirty
  JOIN stock_value_events event ON event.id=dirty.source_event_id JOIN stock_value_production_cost_objects object USING(execution_segment_id)
  WHERE dirty.observed_revision>dirty.cleared_revision AND object.state<>'APPLYING' AND NOT object.business_refresh_pending
   AND coalesce(event.valuation_root_id,event.id)=p_root
  UNION SELECT execution_segment_id FROM stock_value_production_cost_objects
   WHERE business_refresh_pending AND state<>'APPLYING' AND business_refresh_precision_root_id=p_root
 )
 SELECT execution_segment_id FROM candidates WHERE fn_inventory_value_production_inputs_ready(execution_segment_id)
  AND NOT EXISTS(SELECT 1 FROM stock_value_tasks stock JOIN stock_value_events source ON source.id=stock.event_id
   WHERE stock.status='PENDING' AND coalesce(source.valuation_root_id,source.id)=p_root)
 ORDER BY execution_segment_id LIMIT 1
$$;
CREATE INDEX idx_inventory_value_event_root ON stock_value_events(valuation_root_id) WHERE valuation_root_id IS NOT NULL;
CREATE INDEX idx_inventory_value_production_root ON stock_value_production_cost_revisions(precision_origin_id) WHERE precision_origin_id IS NOT NULL;
CREATE INDEX idx_inventory_value_pending_event ON stock_value_tasks(event_id,task_sequence) WHERE status='PENDING';

-- Trace actual share transitions back to its latest recorded zero point. This
-- proof does not allocate a delta or recompute any historical amount.
CREATE FUNCTION fn_inventory_value_share_zero_history(p_last uuid) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v_first stock_value_production_cost_tasks%ROWTYPE;v_task stock_value_production_cost_tasks%ROWTYPE;
 v_seen uuid[]:='{}';v_events uuid[]:='{}';v_expected numeric;v_ids uuid[];v_event_ids uuid[];v_count integer:=0;
BEGIN
 SELECT t.* INTO v_first FROM stock_value_production_cost_tasks t WHERE t.id=p_last;
 IF v_first.id IS NULL OR v_first.status<>'APPLIED' OR v_first.before_share_local IS NULL THEN RETURN NULL;END IF;
 v_task:=v_first;v_expected:=v_first.desired_value_local;
 LOOP
  IF v_task.id IS NULL OR v_task.id=ANY(v_seen) OR v_task.status<>'APPLIED' OR v_task.before_share_local IS NULL
    OR v_task.execution_segment_id<>v_first.execution_segment_id OR v_task.input_node_id<>v_first.input_node_id
    OR v_task.output_source_node_id<>v_first.output_source_node_id OR v_task.desired_value_local<>v_expected OR v_task.value_event_id IS NULL THEN RETURN NULL;END IF;
  v_seen:=array_append(v_seen,v_task.id);v_events:=array_append(v_events,v_task.value_event_id);v_count:=v_count+1;
  IF v_count>50000 THEN RETURN NULL;END IF;
  v_expected:=v_task.before_share_local;
  IF v_expected=0 THEN
   SELECT array_agg(member ORDER BY ordinal DESC) INTO v_ids FROM unnest(v_seen) WITH ORDINALITY item(member,ordinal);
   SELECT array_agg(member ORDER BY ordinal DESC) INTO v_event_ids FROM unnest(v_events) WITH ORDINALITY item(member,ordinal);
   RETURN jsonb_build_object('version',1,'scopeId',v_first.execution_segment_id,'inputNodeId',v_first.input_node_id,'outputSourceNodeId',v_first.output_source_node_id,
    'beforeShare',v_first.desired_value_local,'afterShare',0,'firstProducerTaskId',v_task.id,'lastProducerTaskId',v_first.id,
    'originalProducerTaskIds',v_ids,'originalValueEventIds',v_event_ids);
  END IF;
  SELECT t.* INTO v_task FROM stock_value_production_cost_tasks t WHERE t.id=v_task.previous_task_id;
 END LOOP;
END $$;

CREATE FUNCTION fn_inventory_value_producer_withdrawal_proof(p_task uuid) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v_inverse stock_value_production_cost_tasks%ROWTYPE;v_history jsonb;v_original_before numeric;v_original_after numeric;
 v_inverse_before numeric;v_inverse_after numeric;v_first_event uuid;v_last_event uuid;
BEGIN
 SELECT t.* INTO v_inverse FROM stock_value_production_cost_tasks t WHERE t.id=p_task;
 IF v_inverse.id IS NULL OR v_inverse.status<>'APPLIED' OR v_inverse.target_proof IS NULL OR v_inverse.desired_value_local<>0
  OR v_inverse.before_share_local IS NULL OR v_inverse.before_share_local<=0 OR v_inverse.value_event_id IS NULL THEN RETURN NULL;END IF;
 v_history:=fn_inventory_value_share_zero_history(v_inverse.previous_task_id);
 IF v_history IS NULL OR (v_history->>'beforeShare')::numeric<>v_inverse.before_share_local
  OR v_inverse.restores_task_id IS DISTINCT FROM (v_history->>'firstProducerTaskId')::uuid THEN RETURN NULL;END IF;
 v_first_event:=(v_history->'originalValueEventIds'->>0)::uuid;
 -- Unchanged-share metadata records knowledge, not another monetary span.
 -- Keep all original events in the trace, but anchor the monetary endpoint to
 -- the last actual share change rather than a later other-input source point.
 SELECT task.value_event_id INTO v_last_event
 FROM jsonb_array_elements_text(v_history->'originalProducerTaskIds') WITH ORDINALITY member(id,ordinal)
 JOIN stock_value_production_cost_tasks task ON task.id=member.id::uuid
 WHERE task.before_share_local IS DISTINCT FROM task.desired_value_local ORDER BY member.ordinal DESC LIMIT 1;
 IF v_last_event IS NULL THEN RETURN NULL;END IF;
 SELECT r.before_value INTO v_original_before FROM stock_value_node_revisions r WHERE r.node_id=v_inverse.output_source_node_id AND r.event_id=v_first_event AND r.task_id IS NULL;
 SELECT r.after_value INTO v_original_after FROM stock_value_node_revisions r WHERE r.node_id=v_inverse.output_source_node_id AND r.event_id=v_last_event AND r.task_id IS NULL;
 SELECT r.before_value,r.after_value INTO v_inverse_before,v_inverse_after FROM stock_value_node_revisions r WHERE r.node_id=v_inverse.output_source_node_id AND r.event_id=v_inverse.value_event_id AND r.task_id IS NULL;
 IF v_original_before IS NULL OR v_original_after IS NULL OR v_inverse_before IS NULL OR v_inverse_after IS NULL
  OR NOT EXISTS(SELECT 1 FROM stock_value_events e WHERE e.id=v_inverse.value_event_id AND e.operation='COST_ALLOCATE'
   AND e.projection_restore_of_event_id=v_first_event AND e.source_node_id=v_inverse.output_source_node_id) THEN RETURN NULL;END IF;
 RETURN v_history||jsonb_build_object('kind','SHARE_WITHDRAWAL','inverseProducerTaskId',v_inverse.id,'inverseValueEventId',v_inverse.value_event_id,
  'lastMonetaryValueEventId',v_last_event,'originalSourceBefore',v_original_before,'originalSourceAfter',v_original_after,'inverseSourceBefore',v_inverse_before,'inverseSourceAfter',v_inverse_after,
  'restoresOriginalPoint',v_inverse_after=v_original_before AND v_inverse_before=v_original_after);
END $$;

CREATE FUNCTION fn_inventory_value_mark_plan_scope(p_revision uuid) RETURNS boolean LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_plan stock_value_production_cost_revisions%ROWTYPE;v_key text;v_nodes uuid[];v_keys text[];
BEGIN
 SELECT r.* INTO STRICT v_plan FROM stock_value_production_cost_revisions r WHERE r.id=p_revision;
 v_nodes:=v_plan.precision_closure_nodes;v_keys:=v_plan.precision_closure_keys;
 IF v_nodes IS NULL THEN RETURN true;END IF;
 FOREACH v_key IN ARRAY v_keys LOOP PERFORM fn_inventory_value_try_precision_claim(v_key);END LOOP;
 PERFORM fn_inventory_value_release_completed_precision(v_keys);
 IF fn_inventory_value_precision_marked(v_keys,v_plan.precision_origin_id) THEN
  RAISE EXCEPTION '生产成本来源或后继正在核对，请保留原方案稍后重试；本次未确认' USING ERRCODE='40001',CONSTRAINT='stock_value_precision_scope_busy';END IF;
 UPDATE stock_value_production_cost_objects SET precision_input_ancestor_nodes=NULL,precision_closure_keys=v_keys,precision_closure_nodes=v_nodes,
  precision_closure_pending=true,precision_closure_complete=false,precision_origin_id=coalesce(v_plan.precision_origin_id,v_plan.id),precision_work_txid=txid_current()
  WHERE execution_segment_id=v_plan.execution_segment_id;
 RETURN true;
END $$;

CREATE FUNCTION fn_inventory_value_capture_business_refresh_precision() RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_resuming boolean;
BEGIN
 IF TG_OP='UPDATE' AND NEW.business_refresh_pending
  AND (NOT OLD.business_refresh_pending OR NEW.business_refresh_event_id IS DISTINCT FROM OLD.business_refresh_event_id
       OR NEW.business_refresh_actor_id IS DISTINCT FROM OLD.business_refresh_actor_id) THEN
  v_resuming:=current_setting('app.inventory_value_business_refresh_root',true)=coalesce(OLD.business_refresh_precision_root_id,OLD.execution_segment_id)::text
    AND current_setting('app.inventory_value_legacy_refresh',true)=OLD.business_refresh_precision_version::text
    AND NEW.business_refresh_event_id IS NOT DISTINCT FROM OLD.business_refresh_event_id;
  IF ((OLD.precision_closure_pending AND fn_inventory_value_root_incomplete(OLD.precision_origin_id)) OR (OLD.state='APPLYING' AND OLD.precision_origin_id IS NULL))
    AND OLD.precision_work_txid IS DISTINCT FROM txid_current() AND NOT coalesce(v_resuming,false) THEN
   RAISE EXCEPTION '原生产成本仍在处理，请保留本次原输入稍后重试；本次未确认' USING ERRCODE='40001',CONSTRAINT='stock_value_precision_scope_busy';END IF;
 END IF;
 IF NEW.business_refresh_pending AND (TG_OP='INSERT' OR NOT OLD.business_refresh_pending OR NEW.business_refresh_event_id IS DISTINCT FROM OLD.business_refresh_event_id) THEN
  NEW.business_refresh_precision_version:=2;NEW.business_refresh_precision_policy:=fn_business_precision_snapshot();NEW.business_refresh_precision_root_id:=NULL;
 ELSIF TG_OP='UPDATE' AND (NEW.business_refresh_precision_version IS DISTINCT FROM OLD.business_refresh_precision_version
   OR NEW.business_refresh_precision_policy IS DISTINCT FROM OLD.business_refresh_precision_policy) THEN
  RAISE EXCEPTION 'Original business refresh precision is immutable' USING ERRCODE='55000';
 END IF;
 IF TG_OP='UPDATE' AND NEW.business_refresh_precision_root_id IS DISTINCT FROM OLD.business_refresh_precision_root_id
   AND NOT (OLD.business_refresh_precision_root_id IS NULL AND pg_trigger_depth()>1) THEN
  IF NEW.business_refresh_pending AND (NOT OLD.business_refresh_pending OR NEW.business_refresh_event_id IS DISTINCT FROM OLD.business_refresh_event_id) THEN NULL;
  ELSE RAISE EXCEPTION 'Business refresh work root requires its actual original request' USING ERRCODE='55000';END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_00a_inventory_value_business_precision BEFORE INSERT OR UPDATE ON stock_value_production_cost_objects
 FOR EACH ROW EXECUTE FUNCTION fn_inventory_value_capture_business_refresh_precision();
ALTER TABLE stock_value_production_cost_objects ENABLE ALWAYS TRIGGER trg_00a_inventory_value_business_precision;
CREATE FUNCTION fn_inventory_value_try_refresh_root(p_scope uuid) RETURNS boolean LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_root uuid;v_keys text[];v_next uuid;v_constraint text;
BEGIN
 SELECT business_refresh_precision_root_id INTO v_root FROM stock_value_production_cost_objects WHERE execution_segment_id=p_scope AND business_refresh_pending;
 IF FOUND AND v_root IS NULL THEN RETURN true;END IF;
 IF v_root IS NULL THEN
 SELECT coalesce(event.valuation_root_id,event.id) INTO v_root FROM stock_value_production_cost_dirty dirty
 JOIN stock_value_events event ON event.id=dirty.source_event_id
 WHERE dirty.execution_segment_id=p_scope AND dirty.observed_revision>dirty.cleared_revision
 ORDER BY dirty.observed_revision DESC,dirty.input_node_id LIMIT 1;
 END IF;
 IF v_root IS NULL THEN RETURN true;END IF;
 v_keys:=fn_inventory_value_root_keys(v_root);
 IF v_keys IS NULL THEN RETURN true;END IF; -- original committed pre-transition work
 v_next:=fn_inventory_value_root_next_refresh(v_root);
 IF v_next IS DISTINCT FROM p_scope THEN RETURN false;END IF;
 BEGIN
  PERFORM fn_inventory_value_try_precision_claim(v_keys[1]);
 EXCEPTION WHEN serialization_failure THEN
  GET STACKED DIAGNOSTICS v_constraint=CONSTRAINT_NAME;
  IF v_constraint='stock_value_precision_scope_busy' THEN RETURN false;END IF;
  RAISE;
 END;
 RETURN fn_inventory_value_root_next_refresh(v_root)=p_scope;
END $$;

CREATE FUNCTION fn_inventory_value_can_apply_production(p_task uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 WITH requested AS (SELECT task.*,revision.precision_origin_id root_id FROM stock_value_production_cost_tasks task
  JOIN stock_value_production_cost_revisions revision ON revision.id=task.revision_id WHERE task.id=p_task)
 SELECT coalesce((SELECT CASE WHEN requested.target_proof IS NULL OR requested.root_id IS NULL THEN true ELSE
   fn_inventory_value_production_inputs_ready(requested.execution_segment_id)
   AND fn_inventory_value_root_next_refresh(requested.root_id) IS NULL
   AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_tasks earlier JOIN stock_value_production_cost_revisions revision ON revision.id=earlier.revision_id
    WHERE earlier.status='PENDING' AND earlier.task_sequence<requested.task_sequence AND revision.precision_origin_id=requested.root_id
      AND fn_inventory_value_production_inputs_ready(earlier.execution_segment_id))
  END FROM requested),false)
$$;
CREATE FUNCTION fn_inventory_value_can_propagate(p_task uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 WITH requested AS (SELECT task.*,fn_inventory_value_event_root(task.event_id) root_id FROM stock_value_tasks task WHERE task.id=p_task)
 SELECT coalesce((SELECT CASE WHEN requested.parent_before_value IS NULL OR requested.root_id IS NULL THEN true ELSE
  NOT EXISTS(SELECT 1 FROM stock_value_production_cost_tasks producer JOIN stock_value_production_cost_revisions revision ON revision.id=producer.revision_id
   WHERE producer.status='PENDING' AND revision.precision_origin_id=requested.root_id
     AND fn_inventory_value_production_inputs_ready(producer.execution_segment_id))
  AND NOT EXISTS(SELECT 1 FROM stock_value_tasks earlier WHERE earlier.status='PENDING' AND earlier.task_sequence<requested.task_sequence
   AND fn_inventory_value_event_root(earlier.event_id)=requested.root_id)
  END FROM requested),false)
$$;

-- Root-local rehearsal of the existing cumulative targets and worker FIFO.
-- Temporary rows are predictions, never book facts or another ledger.
CREATE FUNCTION fn_inventory_value_preview_begin(p_nodes uuid[]) RETURNS void LANGUAGE plpgsql VOLATILE AS $$
BEGIN
 CREATE TEMP TABLE IF NOT EXISTS uten_iv_preview_nodes(id uuid PRIMARY KEY,amount numeric NOT NULL,distributed numeric NOT NULL,projection jsonb NOT NULL,restores uuid) ON COMMIT DROP;
 CREATE TEMP TABLE IF NOT EXISTS uten_iv_preview_edges(id uuid PRIMARY KEY,applied numeric NOT NULL,planned jsonb NOT NULL) ON COMMIT DROP;
 CREATE TEMP TABLE IF NOT EXISTS uten_iv_preview_shares(input_id uuid,output_id uuid,amount numeric NOT NULL,PRIMARY KEY(input_id,output_id)) ON COMMIT DROP;
 CREATE TEMP TABLE IF NOT EXISTS uten_iv_preview_stock(seq bigserial PRIMARY KEY,edge_id uuid,target jsonb NOT NULL,version integer,policy jsonb,restores uuid,done boolean NOT NULL DEFAULT false) ON COMMIT DROP;
 CREATE TEMP TABLE IF NOT EXISTS uten_iv_preview_producers(seq bigserial PRIMARY KEY,scope_id uuid,input_id uuid,output_id uuid,desired jsonb NOT NULL,done boolean NOT NULL DEFAULT false) ON COMMIT DROP;
 CREATE TEMP TABLE IF NOT EXISTS uten_iv_preview_scopes(id uuid PRIMARY KEY,dirty boolean NOT NULL DEFAULT true,pending boolean NOT NULL DEFAULT false,processed boolean NOT NULL DEFAULT false,business boolean NOT NULL DEFAULT false) ON COMMIT DROP;
 CREATE TEMP TABLE IF NOT EXISTS uten_iv_preview_inputs(scope_id uuid,node_id uuid,posting_id uuid,kind text,registered boolean NOT NULL,PRIMARY KEY(scope_id,node_id)) ON COMMIT DROP;
 CREATE TEMP TABLE IF NOT EXISTS uten_iv_preview_ancestors(scope_id uuid,node_id uuid,PRIMARY KEY(scope_id,node_id)) ON COMMIT DROP;
 CREATE TEMP TABLE IF NOT EXISTS uten_iv_preview_dependencies(scope_id uuid,upstream_scope_id uuid,PRIMARY KEY(scope_id,upstream_scope_id)) ON COMMIT DROP;
 CREATE TEMP TABLE IF NOT EXISTS uten_iv_preview_meta(id integer PRIMARY KEY,operations integer NOT NULL,proof_hash text NOT NULL) ON COMMIT DROP;
 TRUNCATE pg_temp.uten_iv_preview_nodes,pg_temp.uten_iv_preview_edges,pg_temp.uten_iv_preview_shares,pg_temp.uten_iv_preview_stock,pg_temp.uten_iv_preview_producers,pg_temp.uten_iv_preview_scopes,pg_temp.uten_iv_preview_inputs,pg_temp.uten_iv_preview_ancestors,pg_temp.uten_iv_preview_dependencies,pg_temp.uten_iv_preview_meta RESTART IDENTITY;
 INSERT INTO pg_temp.uten_iv_preview_meta VALUES(1,0,repeat('0',64));
 INSERT INTO pg_temp.uten_iv_preview_nodes SELECT n.id,n.basis_value_local,n.distributed_value_local,fn_inventory_value_current_projection(n),NULL::uuid FROM stock_value_nodes n WHERE n.id=ANY(p_nodes);
 INSERT INTO pg_temp.uten_iv_preview_edges
 SELECT e.id,e.allocated_amount_local,jsonb_build_object('amount',e.allocated_amount_local,'version',coalesce(e.applied_precision_version,e.value_precision_version),
  'policy',CASE WHEN coalesce(e.applied_precision_version,e.value_precision_version)=1 THEN NULL ELSE coalesce(e.applied_precision_policy,e.business_precision_policy) END)
 FROM stock_value_edges e WHERE e.parent_node_id=ANY(p_nodes) AND e.child_node_id=ANY(p_nodes);
 INSERT INTO pg_temp.uten_iv_preview_shares SELECT input_node_id,output_source_node_id,allocated_value_local FROM stock_value_production_cost_shares WHERE input_node_id=ANY(p_nodes) OR output_source_node_id=ANY(p_nodes);
 INSERT INTO pg_temp.uten_iv_preview_inputs SELECT i.execution_segment_id,i.input_node_id,i.approved_posting_id,i.input_kind,true
 FROM stock_value_production_cost_inputs i WHERE i.input_node_id=ANY(p_nodes);
 INSERT INTO pg_temp.uten_iv_preview_inputs
 SELECT object.execution_segment_id,candidate.result_node_id,candidate.approved_posting_id,candidate.input_kind,false
 FROM v_production_cost_input_candidates candidate JOIN stock_value_production_cost_objects object
  ON object.execution_segment_id=fn_production_execution_cost_scope(candidate.member_segment_id)
 WHERE candidate.node_active AND object.business_refresh_pending AND object.current_revision_id IS NOT NULL AND candidate.result_node_id=ANY(p_nodes)
  AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_inputs registered WHERE registered.approved_posting_id=candidate.approved_posting_id)
 ON CONFLICT DO NOTHING;
 INSERT INTO pg_temp.uten_iv_preview_scopes(id,business)
 SELECT DISTINCT scope_id,true FROM pg_temp.uten_iv_preview_inputs WHERE NOT registered ON CONFLICT(id) DO UPDATE SET business=true;
 INSERT INTO pg_temp.uten_iv_preview_scopes(id)
 SELECT DISTINCT dirty.execution_segment_id FROM stock_value_production_cost_dirty dirty JOIN stock_value_production_cost_objects object USING(execution_segment_id)
 WHERE dirty.observed_revision>dirty.cleared_revision AND object.current_revision_id IS NOT NULL AND dirty.input_node_id=ANY(p_nodes)
 ON CONFLICT(id) DO UPDATE SET dirty=true;
 -- The locked physical graph and complete actual/virtual input registry are
 -- fixed for this one rehearsal. Cache only its scope dependency relation;
 -- every FIFO money/ownership prefix is still calculated and checked below.
 WITH RECURSIVE ancestors(scope_id,node_id) AS (
  SELECT scope_id,node_id FROM pg_temp.uten_iv_preview_inputs
  UNION SELECT child.scope_id,prior.node_id FROM ancestors child CROSS JOIN LATERAL fn_inventory_value_precision_predecessors(child.node_id) prior
 )
 INSERT INTO pg_temp.uten_iv_preview_ancestors SELECT scope_id,node_id FROM ancestors;
 INSERT INTO pg_temp.uten_iv_preview_dependencies
 SELECT DISTINCT required.scope_id,output.execution_segment_id FROM pg_temp.uten_iv_preview_ancestors required
 JOIN stock_value_production_cost_outputs output ON output.source_node_id=required.node_id
 WHERE required.scope_id<>output.execution_segment_id;
END $$;

CREATE FUNCTION fn_inventory_value_preview_tick(p_fact jsonb,p_count integer DEFAULT 1) RETURNS void LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_count integer;
BEGIN
 UPDATE pg_temp.uten_iv_preview_meta SET operations=operations+p_count,proof_hash=encode(digest(proof_hash||p_fact::text,'sha256'),'hex') WHERE id=1 RETURNING operations INTO v_count;
 IF v_count>50000 THEN RAISE EXCEPTION '本次累计成本的实际执行路径超过核对范围，请保留原单核对；本次未确认' USING ERRCODE='40001',CONSTRAINT='stock_value_precision_scope_limit';END IF;
END $$;

CREATE FUNCTION fn_inventory_value_preview_node(p_node uuid,p_after numeric,p_version integer,p_policy jsonb,p_restores uuid) RETURNS numeric LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_node stock_value_nodes%ROWTYPE;v_before numeric;v_projection jsonb;v_scope uuid;v_processed boolean;
BEGIN
 SELECT n.* INTO STRICT v_node FROM stock_value_nodes n WHERE n.id=p_node;
 SELECT s.amount,s.distributed,s.projection INTO STRICT v_before,v_node.distributed_value_local,v_projection FROM pg_temp.uten_iv_preview_nodes s WHERE s.id=p_node;
 IF NOT fn_financial_book_amount_is_exact(p_after) OR p_after<0 OR v_node.kind='POOL' AND v_node.quantity_basis=0 AND p_after<>0 THEN
  RAISE EXCEPTION '累计成本中间目标超出原来源或存储范围；本次未确认' USING ERRCODE='22003';END IF;
 IF p_after<>v_before THEN
  v_projection:=NULL;
  v_projection:=fn_inventory_value_restore_projection(v_node,p_after,p_restores);
  IF v_projection IS NULL THEN v_projection:=fn_inventory_value_after_projection(v_node,p_after,p_version,p_policy);END IF;
 END IF;
 UPDATE pg_temp.uten_iv_preview_nodes SET amount=p_after,projection=v_projection,restores=p_restores WHERE id=p_node;
 IF v_node.owner_kind='COST_WIP' THEN
  SELECT i.execution_segment_id INTO v_scope FROM stock_value_production_cost_inputs i JOIN stock_value_production_cost_objects o USING(execution_segment_id)
   WHERE i.input_node_id=p_node AND o.current_revision_id IS NOT NULL;
  IF v_scope IS NOT NULL THEN
   SELECT s.processed INTO v_processed FROM pg_temp.uten_iv_preview_scopes s WHERE s.id=v_scope;
   -- A frozen older plan may finish before a later upstream wave; its dirty revision remains real work.
   INSERT INTO pg_temp.uten_iv_preview_scopes(id) VALUES(v_scope) ON CONFLICT(id) DO UPDATE SET dirty=true;
  END IF;
 END IF;
 RETURN v_before;
END $$;

CREATE FUNCTION fn_inventory_value_preview_edges(p_parent uuid,p_before numeric,p_after numeric,p_version integer,p_policy jsonb,p_restores uuid) RETURNS void LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_edge stock_value_edges%ROWTYPE;v_target jsonb;
BEGIN
 FOR v_edge IN SELECT e.* FROM stock_value_edges e JOIN pg_temp.uten_iv_preview_edges predicted ON predicted.id=e.id WHERE e.parent_node_id=p_parent ORDER BY e.id LOOP
  IF p_before=p_after THEN SELECT predicted.planned INTO STRICT v_target FROM pg_temp.uten_iv_preview_edges predicted WHERE predicted.id=v_edge.id;
  ELSE v_target:=fn_inventory_value_target_after_with_policy(v_edge.id,p_after,p_version,p_policy,p_restores);END IF;
  UPDATE pg_temp.uten_iv_preview_edges SET planned=v_target WHERE id=v_edge.id;
  INSERT INTO pg_temp.uten_iv_preview_stock(edge_id,target,version,policy,restores) VALUES(v_edge.id,v_target,p_version,p_policy,p_restores);
  PERFORM fn_inventory_value_preview_tick(jsonb_build_object('edge',v_edge.id,'target',v_target,'restores',p_restores));
 END LOOP;
END $$;
CREATE FUNCTION fn_inventory_value_preview_source(p_node uuid,p_after numeric,p_version integer,p_policy jsonb,p_restores uuid) RETURNS void LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_before numeric;
BEGIN
 v_before:=fn_inventory_value_preview_node(p_node,p_after,p_version,p_policy,p_restores);
 PERFORM fn_inventory_value_preview_edges(p_node,v_before,p_after,p_version,p_policy,p_restores);
END $$;
CREATE FUNCTION fn_inventory_value_preview_stock_drain() RETURNS void LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_work record;v_edge stock_value_edges%ROWTYPE;v_before numeric;v_after numeric;v_previous numeric;
BEGIN
 LOOP
  SELECT * INTO v_work FROM pg_temp.uten_iv_preview_stock q WHERE NOT q.done ORDER BY q.seq LIMIT 1;
  IF NOT FOUND THEN
   UPDATE pg_temp.uten_iv_preview_scopes scope SET pending=false,dirty=scope.dirty OR scope.business WHERE scope.pending AND NOT EXISTS(SELECT 1 FROM pg_temp.uten_iv_preview_producers producer WHERE producer.scope_id=scope.id AND NOT producer.done);
   RETURN;END IF;
  SELECT e.* INTO STRICT v_edge FROM stock_value_edges e WHERE e.id=v_work.edge_id;
  SELECT s.amount INTO STRICT v_before FROM pg_temp.uten_iv_preview_nodes s WHERE s.id=v_edge.child_node_id;
  SELECT e.applied INTO STRICT v_previous FROM pg_temp.uten_iv_preview_edges e WHERE e.id=v_edge.id;
  v_after:=v_before+(v_work.target->>'amount')::numeric-v_previous;
  PERFORM fn_inventory_value_preview_node(v_edge.child_node_id,v_after,v_work.version,v_work.policy,v_work.restores);
  UPDATE pg_temp.uten_iv_preview_edges SET applied=(v_work.target->>'amount')::numeric WHERE id=v_edge.id;
  PERFORM fn_inventory_value_preview_edges(v_edge.child_node_id,v_before,v_after,v_work.version,v_work.policy,v_work.restores);
  UPDATE pg_temp.uten_iv_preview_stock SET done=true WHERE seq=v_work.seq;
 END LOOP;
END $$;

CREATE FUNCTION fn_inventory_value_preview_ready_scope() RETURNS uuid LANGUAGE plpgsql STABLE AS $$
BEGIN
 RETURN (SELECT candidate.id FROM pg_temp.uten_iv_preview_scopes candidate WHERE candidate.dirty AND NOT candidate.pending
 AND NOT EXISTS(SELECT 1 FROM pg_temp.uten_iv_preview_dependencies dependency
  JOIN pg_temp.uten_iv_preview_scopes upstream ON upstream.id=dependency.upstream_scope_id
  WHERE dependency.scope_id=candidate.id AND (upstream.dirty OR upstream.pending)) ORDER BY candidate.id LIMIT 1);
END $$;

CREATE FUNCTION fn_inventory_value_preview_plan(p_scope uuid,p_version integer,p_policy jsonb,p_restores uuid) RETURNS integer LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_rows integer;v_plan jsonb;v_inputs jsonb;
BEGIN
 UPDATE pg_temp.uten_iv_preview_inputs SET registered=true WHERE scope_id=p_scope AND node_id IN(
  SELECT node_id FROM pg_temp.uten_iv_preview_inputs WHERE scope_id=p_scope AND NOT registered ORDER BY posting_id LIMIT 100);
 SELECT to_jsonb(r) INTO STRICT v_plan FROM stock_value_production_cost_objects o JOIN stock_value_production_cost_revisions r ON r.id=o.current_revision_id WHERE o.execution_segment_id=p_scope;
 SELECT coalesce(jsonb_agg(jsonb_build_object('node',n.id,'revision',n.revision,'value',predicted.amount,'quantityBasis',n.quantity_basis,
  'returnedQty',n.returned_consumption_qty,'returnCursor',n.consumption_return_head_id) ORDER BY n.id),'[]'::jsonb)
 INTO v_inputs FROM pg_temp.uten_iv_preview_inputs registered JOIN stock_value_nodes n ON n.id=registered.node_id
 JOIN pg_temp.uten_iv_preview_nodes predicted ON predicted.id=n.id WHERE registered.scope_id=p_scope AND registered.registered;
 v_plan:=v_plan||jsonb_build_object('input_snapshot',v_inputs);
 INSERT INTO pg_temp.uten_iv_preview_producers(scope_id,input_id,output_id,desired)
 SELECT p_scope,(i->>'node')::uuid,(o->>'source')::uuid,allocation.proof
 FROM stock_value_production_cost_objects object
 CROSS JOIN LATERAL jsonb_array_elements(v_plan->'input_snapshot') WITH ORDINALITY inputs(i,input_order)
 CROSS JOIN LATERAL jsonb_array_elements(v_plan->'output_snapshot') WITH ORDINALITY outputs(o,output_order)
 JOIN pg_temp.uten_iv_preview_nodes predicted ON predicted.id=(i->>'node')::uuid
 LEFT JOIN pg_temp.uten_iv_preview_shares previous ON previous.input_id=(i->>'node')::uuid AND previous.output_id=(o->>'source')::uuid
 CROSS JOIN LATERAL(SELECT fn_inventory_value_production_target_after(v_plan,i||jsonb_build_object('value',predicted.amount),o,'{}',p_policy,p_version,coalesce(p_restores,predicted.restores)) proof) allocation
 LEFT JOIN stock_value_production_cost_tasks original ON original.id=(allocation.proof->>'restoresTaskId')::uuid
 WHERE object.execution_segment_id=p_scope AND ((o->>'to')::numeric>(o->>'from')::numeric OR coalesce(previous.amount,0)<>0)
 ORDER BY original.task_sequence DESC NULLS LAST,input_order,output_order;
 GET DIAGNOSTICS v_rows=ROW_COUNT;
 UPDATE pg_temp.uten_iv_preview_scopes SET business=EXISTS(SELECT 1 FROM pg_temp.uten_iv_preview_inputs WHERE scope_id=p_scope AND NOT registered),
  dirty=v_rows=0 AND EXISTS(SELECT 1 FROM pg_temp.uten_iv_preview_inputs WHERE scope_id=p_scope AND NOT registered),processed=true,pending=v_rows>0 WHERE id=p_scope;
 PERFORM fn_inventory_value_preview_tick(jsonb_build_object('scope',p_scope,'tasks',v_rows),v_rows);
 RETURN v_rows;
END $$;

CREATE FUNCTION fn_inventory_value_preview_producers_drain(p_version integer,p_policy jsonb) RETURNS integer LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_applied integer:=0;v_work record;v_previous numeric;v_delta numeric;v_distributed numeric;v_projection jsonb;v_source_after numeric;v_node stock_value_nodes%ROWTYPE;
BEGIN
 LOOP
  SELECT q.* INTO v_work FROM pg_temp.uten_iv_preview_producers q WHERE q.seq=fn_inventory_value_preview_ready_producer();
  IF NOT FOUND THEN RETURN v_applied;END IF;
  SELECT s.amount INTO v_previous FROM pg_temp.uten_iv_preview_shares s WHERE s.input_id=v_work.input_id AND s.output_id=v_work.output_id;
  v_delta:=(v_work.desired->>'amount')::numeric-coalesce(v_previous,0);
  SELECT s.distributed+v_delta,s.projection INTO STRICT v_distributed,v_projection FROM pg_temp.uten_iv_preview_nodes s WHERE s.id=v_work.input_id;
  IF v_distributed<0 OR NOT fn_financial_book_amount_is_exact(v_distributed) THEN RAISE EXCEPTION '生产实际分配中间目标超出原来源；本次未确认' USING ERRCODE='22003';END IF;
  SELECT n.* INTO STRICT v_node FROM stock_value_nodes n WHERE n.id=v_work.input_id;
  v_node.distributed_value_local:=v_distributed;
  v_projection:=v_projection||jsonb_build_object('inputs',fn_inventory_value_projection_inputs(v_node),'ownedValue',CASE WHEN v_node.active THEN
    (v_projection->>'toValue')::numeric-(v_projection->>'fromValue')::numeric-v_distributed-(v_projection->>'returnedValue')::numeric ELSE 0 END);
  UPDATE pg_temp.uten_iv_preview_nodes SET distributed=v_distributed,projection=v_projection WHERE id=v_work.input_id;
  INSERT INTO pg_temp.uten_iv_preview_shares(input_id,output_id,amount) VALUES(v_work.input_id,v_work.output_id,(v_work.desired->>'amount')::numeric)
   ON CONFLICT(input_id,output_id) DO UPDATE SET amount=excluded.amount;
  SELECT s.amount+v_delta INTO STRICT v_source_after FROM pg_temp.uten_iv_preview_nodes s WHERE s.id=v_work.output_id;
  PERFORM fn_inventory_value_preview_source(v_work.output_id,v_source_after,p_version,p_policy,coalesce(v_work.desired->>'restoresValueEventId',v_work.desired->>'restoresTaskId')::uuid);
  UPDATE pg_temp.uten_iv_preview_producers SET done=true WHERE seq=v_work.seq;v_applied:=v_applied+1;
 END LOOP;
END $$;

CREATE FUNCTION fn_inventory_value_preview_ready_producer() RETURNS bigint LANGUAGE plpgsql STABLE AS $$
BEGIN
 RETURN (SELECT queue.seq FROM pg_temp.uten_iv_preview_producers queue WHERE NOT queue.done AND NOT EXISTS(
  SELECT 1 FROM pg_temp.uten_iv_preview_dependencies dependency
  JOIN pg_temp.uten_iv_preview_scopes upstream ON upstream.id=dependency.upstream_scope_id
  WHERE dependency.scope_id=queue.scope_id AND (upstream.dirty OR upstream.pending)) ORDER BY queue.seq LIMIT 1);
END $$;

CREATE FUNCTION fn_inventory_value_preview_run(p_version integer,p_policy jsonb,p_restores uuid) RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_scope uuid;v_applied integer;v_result jsonb;
BEGIN
 LOOP
  IF NOT EXISTS(SELECT 1 FROM pg_temp.uten_iv_preview_stock WHERE NOT done) THEN
   LOOP
    v_scope:=fn_inventory_value_preview_ready_scope();EXIT WHEN v_scope IS NULL;
    PERFORM fn_inventory_value_preview_plan(v_scope,p_version,p_policy,p_restores);
   END LOOP;
  END IF;
  v_applied:=fn_inventory_value_preview_producers_drain(p_version,p_policy);
  IF EXISTS(SELECT 1 FROM pg_temp.uten_iv_preview_stock WHERE NOT done) THEN
   PERFORM fn_inventory_value_preview_stock_drain();CONTINUE;
  END IF;
  IF v_applied=0 THEN
   IF EXISTS(SELECT 1 FROM pg_temp.uten_iv_preview_scopes WHERE dirty OR pending) OR EXISTS(SELECT 1 FROM pg_temp.uten_iv_preview_producers WHERE NOT done) THEN
    RAISE EXCEPTION '生产累计成本存在未闭合回路；本次未确认' USING ERRCODE='40001',CONSTRAINT='stock_value_precision_scope_cycle';END IF;
   EXIT;
  END IF;
 END LOOP;
 SELECT jsonb_build_object('operations',operations,'hash',proof_hash) INTO STRICT v_result FROM pg_temp.uten_iv_preview_meta WHERE id=1;
 RETURN v_result;
END $$;

CREATE FUNCTION fn_inventory_value_rehearse_root_waves(p_source uuid,p_after numeric,p_policy jsonb,p_version integer,p_restores uuid,p_nodes uuid[]) RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
BEGIN
 PERFORM fn_inventory_value_preview_begin(p_nodes);
 PERFORM fn_inventory_value_preview_source(p_source,p_after,p_version,p_policy,p_restores);
 RETURN fn_inventory_value_preview_run(p_version,p_policy,p_restores);
END $$;


CREATE FUNCTION fn_inventory_value_finish_root(p_root uuid) RETURNS void LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_nodes uuid[];v_owner uuid;
BEGIN
 v_nodes:=fn_inventory_value_root_nodes(p_root);
 IF v_nodes IS NULL OR NOT fn_inventory_value_revaluation_nodes_complete(v_nodes) THEN RETURN;END IF;
 UPDATE stock_value_jobs SET precision_closure_complete=true WHERE precision_origin_id=p_root AND NOT precision_closure_complete;
 SELECT execution_segment_id INTO v_owner FROM stock_value_production_cost_revisions WHERE id=p_root;
 IF FOUND THEN UPDATE stock_value_production_cost_objects SET precision_closure_complete=true WHERE execution_segment_id=v_owner AND precision_origin_id=p_root AND NOT precision_closure_complete;END IF;
END $$;

CREATE FUNCTION fn_inventory_value_scope_precision_admitted(p_scope uuid,p_event uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT NOT object.precision_closure_pending OR object.precision_work_txid=txid_current()
  OR NOT fn_inventory_value_root_incomplete(object.precision_origin_id)
  OR fn_inventory_value_event_root(p_event)=object.precision_origin_id
  OR (object.business_refresh_pending AND current_setting('app.inventory_value_business_refresh_root',true)=coalesce(object.business_refresh_precision_root_id,object.execution_segment_id)::text
      AND current_setting('app.inventory_value_legacy_refresh',true)=object.business_refresh_precision_version::text)
 FROM stock_value_production_cost_objects object WHERE object.execution_segment_id=p_scope
$$;

-- The financial projection may follow a negative slice through later actual
-- revisions of this same withdrawal root, including zero-money knowledge work.
-- It cannot skip another root, an unproved change, or a current-head mismatch.
CREATE FUNCTION fn_inventory_value_withdrawal_node_chain_proven(p_node uuid,p_from_revision bigint,p_root uuid) RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE v_node stock_value_nodes%ROWTYPE;v_revision record;v_producer stock_value_production_cost_tasks%ROWTYPE;
 v_previous jsonb;v_value numeric;v_pending integer;v_final boolean;v_number bigint:=p_from_revision-1;v_proof jsonb;
BEGIN
 SELECT n.* INTO v_node FROM stock_value_nodes n WHERE n.id=p_node;
 IF v_node.id IS NULL OR v_node.revision<p_from_revision THEN RETURN false;END IF;
 IF NOT EXISTS(SELECT 1 FROM stock_value_production_cost_tasks t JOIN stock_value_events e ON e.id=t.value_event_id
   WHERE t.status='APPLIED' AND (e.valuation_root_id=p_root OR e.id=p_root) AND t.before_share_local>0 AND t.desired_value_local=0
    AND coalesce((fn_inventory_value_producer_withdrawal_proof(t.id)->>'restoresOriginalPoint')::boolean,false)) THEN RETURN false;END IF;
 FOR v_revision IN SELECT r.*,e.operation,coalesce(e.valuation_root_id,e.id) work_root FROM stock_value_node_revisions r
  JOIN stock_value_events e ON e.id=r.event_id WHERE r.node_id=p_node AND r.revision>=p_from_revision AND r.revision<=v_node.revision ORDER BY r.revision LOOP
  IF v_revision.revision<>v_number+1 OR v_revision.operation<>'COST_ALLOCATE' OR v_revision.work_root<>p_root
    OR v_revision.before_projection IS NULL OR v_revision.after_projection IS NULL THEN RETURN false;END IF;
  IF v_previous IS NOT NULL AND (v_revision.before_projection IS DISTINCT FROM v_previous OR v_revision.before_value IS DISTINCT FROM v_value
    OR v_revision.before_pending IS DISTINCT FROM v_pending OR v_revision.before_final IS DISTINCT FROM v_final) THEN RETURN false;END IF;
  SELECT t.* INTO v_producer FROM stock_value_production_cost_tasks t WHERE t.value_event_id=v_revision.event_id AND t.status='APPLIED';
  IF v_producer.id IS NULL THEN RETURN false;END IF;
  IF v_producer.before_share_local>0 AND v_producer.desired_value_local=0 THEN
   v_proof:=fn_inventory_value_producer_withdrawal_proof(v_producer.id);
   IF NOT coalesce((v_proof->>'restoresOriginalPoint')::boolean,false) THEN RETURN false;END IF;
  ELSIF v_producer.before_share_local=v_producer.desired_value_local THEN
   IF v_revision.before_value IS DISTINCT FROM v_revision.after_value OR v_revision.before_projection IS DISTINCT FROM v_revision.after_projection THEN RETURN false;END IF;
  ELSE RETURN false;END IF;
  v_previous:=v_revision.after_projection;v_value:=v_revision.after_value;v_pending:=v_revision.after_pending;v_final:=v_revision.after_final;v_number:=v_revision.revision;
 END LOOP;
 RETURN v_previous IS NOT NULL AND v_number=v_node.revision AND (v_previous->>'basis')::numeric=v_node.basis_value_local
  AND (v_previous->>'ownedValue')::numeric=v_node.owned_value_local AND v_previous->'inputs'=fn_inventory_value_projection_inputs(v_node)
  AND v_pending=v_node.pending_parents AND v_final=v_node.source_final;
END $$;

CREATE FUNCTION fn_inventory_value_rehearse_plan_root(p_root uuid,p_nodes uuid[],p_version integer,p_policy jsonb) RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_task record;
BEGIN
 PERFORM fn_inventory_value_preview_begin(p_nodes);
 INSERT INTO pg_temp.uten_iv_preview_scopes(id,dirty,pending,processed)
 SELECT DISTINCT t.execution_segment_id,false,true,true FROM stock_value_production_cost_tasks t JOIN stock_value_production_cost_revisions r ON r.id=t.revision_id
  WHERE t.status='PENDING' AND coalesce(r.precision_origin_id,r.id)=p_root
 ON CONFLICT(id) DO UPDATE SET pending=true;
 INSERT INTO pg_temp.uten_iv_preview_producers(scope_id,input_id,output_id,desired)
 SELECT t.execution_segment_id,t.input_node_id,t.output_source_node_id,coalesce(t.target_proof,jsonb_build_object('amount',t.desired_value_local,'version',t.value_precision_version,'policy',t.business_precision_policy))
 FROM stock_value_production_cost_tasks t JOIN stock_value_production_cost_revisions r ON r.id=t.revision_id
 WHERE t.status='PENDING' AND coalesce(r.precision_origin_id,r.id)=p_root ORDER BY t.task_sequence;
 FOR v_task IN SELECT t.*,event.value_precision_version event_version,event.business_precision_policy event_policy,fn_inventory_value_restores_event(event.id) restore_event
  FROM stock_value_tasks t JOIN stock_value_events event ON event.id=t.event_id WHERE t.status='PENDING' AND coalesce(event.valuation_root_id,event.id)=p_root ORDER BY t.task_sequence LOOP
  INSERT INTO pg_temp.uten_iv_preview_stock(edge_id,target,version,policy,restores) VALUES(v_task.edge_id,
   jsonb_build_object('amount',v_task.target_amount_local,'version',v_task.value_precision_version,'policy',v_task.business_precision_policy,'restoresTaskId',v_task.restores_task_id),
   v_task.event_version,v_task.event_policy,v_task.restore_event);
  UPDATE pg_temp.uten_iv_preview_edges SET planned=jsonb_build_object('amount',v_task.target_amount_local,'version',v_task.value_precision_version,'policy',v_task.business_precision_policy,'restoresTaskId',v_task.restores_task_id) WHERE id=v_task.edge_id;
 END LOOP;
 RETURN fn_inventory_value_preview_run(p_version,p_policy,fn_inventory_value_restores_event(p_root));
END $$;


-- A newly adopted periodic-material binding changes cost completeness even if
-- the previous direct-material plan was final. Queue the existing durable
-- business refresh with the real binding fact and the current explicit policy;
-- no historical quantity, share, amount or GL entry is repriced here.
DO $periodic_binding_refresh_source$
DECLARE definition text;needle text:='OR EXISTS(SELECT 1 FROM production_daily_reports report';
BEGIN
 SELECT pg_get_functiondef('fn_guard_cost_business_refresh_source()'::regprocedure) INTO definition;
 IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
  RAISE EXCEPTION 'Review current original cost business-refresh source authority';END IF;
 EXECUTE replace(definition,needle,
  'OR EXISTS(SELECT 1 FROM production_execution_periodic_materials binding
    WHERE binding.id=NEW.business_refresh_event_id AND binding.created_by=NEW.business_refresh_actor_id
     AND NEW.source_kind=''PRODUCTION_EXECUTION''
     AND fn_production_execution_cost_scope(binding.execution_segment_id)=NEW.execution_segment_id)
   '||needle);
END $periodic_binding_refresh_source$;

CREATE FUNCTION fn_inventory_value_periodic_bindings_changed() RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_binding record;
BEGIN
 FOR v_binding IN
  SELECT DISTINCT ON(scope.id) scope.id scope_id,binding.id event_id,binding.created_by actor_id
  FROM new_inventory_periodic_bindings binding
  CROSS JOIN LATERAL (SELECT fn_production_execution_cost_scope(binding.execution_segment_id) id) scope
  JOIN stock_value_production_cost_objects object ON object.execution_segment_id=scope.id
  WHERE object.current_revision_id IS NOT NULL AND object.source_kind='PRODUCTION_EXECUTION'
  ORDER BY scope.id,binding.id
 LOOP
  UPDATE stock_value_production_cost_objects
   SET business_refresh_event_id=v_binding.event_id,business_refresh_actor_id=v_binding.actor_id,business_refresh_pending=true
   WHERE execution_segment_id=v_binding.scope_id;
 END LOOP;
 RETURN NULL;
END $$;
CREATE TRIGGER trg_inventory_value_periodic_bindings_changed AFTER INSERT ON production_execution_periodic_materials
 REFERENCING NEW TABLE AS new_inventory_periodic_bindings FOR EACH STATEMENT EXECUTE FUNCTION fn_inventory_value_periodic_bindings_changed();
ALTER TABLE production_execution_periodic_materials ENABLE ALWAYS TRIGGER trg_inventory_value_periodic_bindings_changed;


-- Physical period close may commit a proved bounded registration continuation.
-- The remaining actual allocation is still pending cost, never a final/zero
-- input. Original pre-transition work retains the strict registered-row gate.
DO $periodic_exact_registration_continuation$
DECLARE definition text;needle text:='WHERE input.approved_posting_id = allocation.id)) THEN';
BEGIN
 SELECT pg_get_functiondef('fn_assert_wm_close()'::regprocedure) INTO definition;
 IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
  RAISE EXCEPTION 'Review current periodic allocation registration authority';END IF;
 EXECUTE replace(definition,needle,
  'WHERE input.approved_posting_id = allocation.id)
    AND NOT EXISTS (
     SELECT 1 FROM stock_value_production_cost_objects object
     JOIN stock_value_production_cost_revisions revision ON revision.id=object.current_revision_id
     JOIN workshop_material_period_closes original_close ON original_close.id=target_close
     JOIN v_production_cost_input_candidates candidate ON candidate.approved_posting_id=allocation.id
      AND candidate.result_node_id=allocation.value_node_id AND candidate.node_active
      AND fn_production_execution_cost_scope(candidate.member_segment_id)=allocation.cost_scope_segment_id
     WHERE object.execution_segment_id=allocation.cost_scope_segment_id AND object.source_kind=''PRODUCTION_EXECUTION''
      AND object.business_refresh_pending AND object.business_refresh_event_id=target_close
      AND object.business_refresh_actor_id=original_close.closed_by AND object.business_refresh_precision_version=2
      AND object.business_refresh_precision_root_id=revision.precision_origin_id
      AND object.business_refresh_precision_policy=revision.request_precision_policy
      AND revision.source_event_id=target_close AND revision.source_doc_type=''PRODUCTION_COST_BUSINESS''
      AND object.precision_closure_pending AND NOT object.precision_closure_complete
      AND object.precision_forecast_hash IS NOT NULL
      AND object.precision_closure_nodes @> ARRAY[allocation.value_node_id])) THEN');
END $periodic_exact_registration_continuation$;


-- A known monetary point may have a later zero-share metadata tail in its
-- original root. Prove that exact continuous tail, including the edge pending
-- counter, instead of inventing equality between two different known states.
CREATE FUNCTION fn_inventory_value_restore_knowledge_bridge_proven(p_original uuid,p_inverse uuid) RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE v_original stock_value_tasks%ROWTYPE;v_inverse stock_value_tasks%ROWTYPE;
 v_first stock_value_node_revisions%ROWTYPE;v_last stock_value_node_revisions%ROWTYPE;v_revision record;
 v_task stock_value_tasks%ROWTYPE;v_producer stock_value_production_cost_tasks%ROWTYPE;
 v_node uuid;v_root uuid;v_projection jsonb;v_value numeric;v_pending integer;v_final boolean;v_edge_pending boolean;v_number bigint;
BEGIN
 SELECT * INTO v_original FROM stock_value_tasks WHERE id=p_original AND status='APPLIED';
 SELECT * INTO v_inverse FROM stock_value_tasks WHERE id=p_inverse AND status='APPLIED';
 IF v_original.id IS NULL OR v_inverse.id IS NULL OR v_original.edge_id<>v_inverse.edge_id
  OR v_inverse.restores_task_id IS DISTINCT FROM v_original.id THEN RETURN false;END IF;
 SELECT child_node_id INTO STRICT v_node FROM stock_value_edges WHERE id=v_original.edge_id;
 SELECT * INTO v_first FROM stock_value_node_revisions WHERE node_id=v_node AND task_id=v_original.id AND event_id=v_original.event_id AND revision=v_original.applied_child_revision;
 SELECT * INTO v_last FROM stock_value_node_revisions WHERE node_id=v_node AND task_id=v_inverse.id AND event_id=v_inverse.event_id AND revision=v_inverse.applied_child_revision;
 IF v_first.node_id IS NULL OR v_last.node_id IS NULL OR v_first.revision>=v_last.revision
  OR v_first.after_projection IS NULL OR v_last.before_projection IS NULL THEN RETURN false;END IF;
 v_root:=fn_inventory_value_event_root(v_original.event_id);
 IF NOT EXISTS(SELECT 1 FROM stock_value_events WHERE id=v_original.event_id AND operation='COST_ALLOCATE') THEN RETURN false;END IF;
 v_projection:=v_first.after_projection;v_value:=v_first.after_value;v_pending:=v_first.after_pending;v_final:=v_first.after_final;
 v_edge_pending:=v_original.target_pending;v_number:=v_first.revision;
 FOR v_revision IN SELECT r.*,e.operation,fn_inventory_value_event_root(e.id) work_root FROM stock_value_node_revisions r JOIN stock_value_events e ON e.id=r.event_id
  WHERE r.node_id=v_node AND r.revision>v_first.revision AND r.revision<v_last.revision ORDER BY r.revision LOOP
  IF v_revision.revision<>v_number+1 OR v_revision.operation<>'COST_ALLOCATE' OR v_revision.work_root IS DISTINCT FROM v_root
   OR v_revision.before_projection IS DISTINCT FROM v_projection OR v_revision.before_value IS DISTINCT FROM v_value
   OR v_revision.before_pending IS DISTINCT FROM v_pending OR v_revision.before_final IS DISTINCT FROM v_final
   OR v_revision.after_projection IS DISTINCT FROM v_revision.before_projection OR v_revision.after_value IS DISTINCT FROM v_revision.before_value
   OR NOT fn_inventory_value_revaluation_work_complete(v_revision.event_id) THEN RETURN false;END IF;
  SELECT * INTO v_task FROM stock_value_tasks WHERE id=v_revision.task_id AND status='APPLIED' AND event_id=v_revision.event_id;
  SELECT * INTO v_producer FROM stock_value_production_cost_tasks WHERE value_event_id=v_revision.event_id AND status='APPLIED';
  IF v_task.id IS NULL OR v_producer.id IS NULL OR v_producer.before_share_local IS NULL
   OR v_producer.before_share_local IS DISTINCT FROM v_producer.desired_value_local
   OR v_task.applied_delta_local IS DISTINCT FROM 0 OR v_task.before_allocated_amount_local IS DISTINCT FROM v_task.target_amount_local THEN RETURN false;END IF;
  IF v_task.edge_id=v_original.edge_id THEN
   IF v_task.before_pending_contribution IS DISTINCT FROM v_edge_pending THEN RETURN false;END IF;
   v_edge_pending:=v_task.target_pending;
  END IF;
  v_projection:=v_revision.after_projection;v_value:=v_revision.after_value;v_pending:=v_revision.after_pending;v_final:=v_revision.after_final;v_number:=v_revision.revision;
 END LOOP;
 RETURN v_number=v_last.revision-1 AND v_projection=v_last.before_projection AND v_value=v_last.before_value
  AND v_pending=v_last.before_pending AND v_final=v_last.before_final AND v_edge_pending=v_inverse.before_pending_contribution;
END $$;
