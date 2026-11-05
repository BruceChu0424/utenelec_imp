-- An agreed total is authoritative. Its reference unit price is a projection
-- under the operation's explicit policy, retained for later reviewers.
-- Existing NULL proofs keep V760's ten-place DOWN contract; no choices are backfilled.
CREATE FUNCTION fn_procurement_reference_price_policy_valid(policy jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE entry record;
BEGIN
 IF policy IS NULL OR jsonb_typeof(policy) IS DISTINCT FROM 'object' THEN RETURN FALSE; END IF;
 IF (SELECT count(*) FROM jsonb_object_keys(policy))<>2
   OR jsonb_typeof(policy->'version') IS DISTINCT FROM 'number' OR policy->>'version'<>'1'
   OR jsonb_typeof(policy->'choices') IS DISTINCT FROM 'object' THEN RETURN FALSE; END IF;
 IF (SELECT count(*) FROM jsonb_object_keys(policy->'choices'))>32 THEN RETURN FALSE; END IF;
 FOR entry IN SELECT key,value FROM jsonb_each(policy->'choices') LOOP
  IF length(trim(entry.key))=0 OR length(entry.key)>200 OR jsonb_typeof(entry.value) IS DISTINCT FROM 'object' THEN RETURN FALSE; END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(entry.value))<>2
    OR jsonb_typeof(entry.value->'scale') IS DISTINCT FROM 'number'
    OR (entry.value->>'scale') !~ '^[0-9]+$'
    OR (entry.value->>'scale')::numeric>30
    OR jsonb_typeof(entry.value->'rounding') IS DISTINCT FROM 'string'
    OR entry.value->>'rounding' NOT IN('HALF_UP','DOWN') THEN RETURN FALSE; END IF;
 END LOOP;
 RETURN TRUE;
END $$;

CREATE FUNCTION fn_procurement_reference_price_proof(total numeric,qty numeric,policy jsonb)
RETURNS numeric LANGUAGE plpgsql VOLATILE AS $$
DECLARE result numeric;
BEGIN
 IF policy IS NULL OR policy='null'::jsonb THEN RETURN fn_procurement_reference_price(total,qty); END IF;
 IF NOT fn_procurement_reference_price_policy_valid(policy) THEN
  RAISE EXCEPTION 'invalid frozen reference price policy' USING ERRCODE='23514'; END IF;
 IF total IS NULL OR qty IS NULL THEN RETURN NULL; END IF;
 IF total<0 OR qty<=0 OR NOT fn_financial_amount_is_exact(total) OR NOT fn_financial_amount_is_exact(qty) THEN
  RAISE EXCEPTION 'invalid total-price original operands' USING ERRCODE='23514'; END IF;
 result:=fn_business_exact_divide_with_policy(total,qty,'money.reference-unit-price','本次参考单价',24,policy,false);
 IF NOT fn_financial_amount_is_exact(result) THEN
  RAISE EXCEPTION 'reference price exceeds its exact native capacity' USING ERRCODE='23514'; END IF;
 RETURN result;
END $$;

CREATE FUNCTION fn_procurement_revised_total_input_proof(total numeric,old_qty numeric,new_qty numeric,policy jsonb)
RETURNS numeric LANGUAGE plpgsql VOLATILE AS $$
DECLARE result numeric;
BEGIN
 IF total IS NULL THEN RETURN NULL; END IF;
 IF policy IS NULL OR policy='null'::jsonb THEN RETURN fn_procurement_revised_total_input(total,old_qty,new_qty); END IF;
 IF NOT fn_procurement_reference_price_policy_valid(policy) OR old_qty IS NULL OR old_qty<=0 OR new_qty IS NULL OR new_qty<=0 THEN
  RAISE EXCEPTION 'invalid frozen total-price revision proof' USING ERRCODE='23514'; END IF;
 result:=fn_business_exact_divide_with_policy(total*new_qty,old_qty,'money.revised-total','本次按原总额比例改量',24,policy,false);
 IF result<0 OR NOT fn_financial_amount_is_exact(result) THEN
  RAISE EXCEPTION 'revised total exceeds its exact native capacity' USING ERRCODE='23514'; END IF;
 RETURN result;
END $$;

CREATE FUNCTION fn_procurement_revised_original_proof(old_item jsonb,new_qty numeric,policy jsonb)
RETURNS numeric LANGUAGE plpgsql VOLATILE AS $$
BEGIN
 RETURN fn_business_columns_amount(
  CASE WHEN old_item->>'total_amount_input' IS NULL THEN new_qty*(old_item->>'price')::numeric
  ELSE fn_procurement_revised_total_input_proof((old_item->>'total_amount_input')::numeric,
    (old_item->>'qty')::numeric,new_qty,policy) END,old_item->'extra_columns');
END $$;

ALTER TABLE purchase_order_items ADD COLUMN reference_price_precision_policy jsonb,
 ADD CONSTRAINT purchase_order_reference_price_policy CHECK(reference_price_precision_policy IS NULL
  OR (total_amount_input IS NOT NULL AND fn_procurement_reference_price_policy_valid(reference_price_precision_policy)));
ALTER TABLE subcontract_order_items ADD COLUMN reference_price_precision_policy jsonb,
 ADD CONSTRAINT subcontract_order_reference_price_policy CHECK(reference_price_precision_policy IS NULL
  OR (total_amount_input IS NOT NULL AND fn_procurement_reference_price_policy_valid(reference_price_precision_policy)));

CREATE FUNCTION fn_guard_procurement_reference_price_policy()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE original_changed boolean; policy_changed boolean; policy jsonb; expected numeric; parent_status smallint; parent_table text; order_kind text;
BEGIN
 IF TG_TABLE_NAME NOT IN('purchase_order_items','subcontract_order_items') THEN
  RAISE EXCEPTION 'unsupported procurement reference price owner' USING ERRCODE='23514'; END IF;
 IF TG_OP='UPDATE' THEN
  original_changed:=NEW.qty IS DISTINCT FROM OLD.qty OR NEW.total_amount_input IS DISTINCT FROM OLD.total_amount_input;
  policy_changed:=NEW.reference_price_precision_policy IS DISTINCT FROM OLD.reference_price_precision_policy;
  IF current_setting('session_replication_role')='replica' THEN
   IF NEW.reference_price_precision_policy IS DISTINCT FROM OLD.reference_price_precision_policy THEN
    RAISE EXCEPTION 'saved reference price proof cannot be independently replaced' USING ERRCODE='55000'; END IF;
   RETURN NEW;
  END IF;
  IF NOT original_changed AND NEW.price IS NOT DISTINCT FROM OLD.price
    AND NEW.reference_price_precision_policy IS NOT DISTINCT FROM OLD.reference_price_precision_policy THEN RETURN NEW; END IF;
 ELSE
  original_changed:=TRUE;
  policy_changed:=TRUE;
 END IF;
 parent_table:=CASE TG_TABLE_NAME WHEN 'purchase_order_items' THEN 'purchase_orders' ELSE 'subcontract_orders' END;
 order_kind:=CASE TG_TABLE_NAME WHEN 'purchase_order_items' THEN 'PURCHASE' ELSE 'SUBCONTRACT' END;
 EXECUTE format('SELECT status FROM %I WHERE id=$1 FOR SHARE',parent_table) INTO parent_status USING NEW.order_id;
 IF parent_status IS NULL THEN RAISE EXCEPTION 'missing reference price document' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM procurement_order_approval_cases c WHERE c.order_type=order_kind
   AND c.order_id=NEW.order_id AND c.status='PENDING') THEN
  IF TG_OP='INSERT' THEN
   RAISE EXCEPTION 'pending finance reference price proof is immutable' USING ERRCODE='55000'; END IF;
  IF NOT EXISTS(SELECT 1 FROM procurement_order_source_revisions r
    JOIN procurement_order_approval_cases c ON c.id=r.pending_case_id
    WHERE r.created_txid=txid_current() AND r.order_type='PURCHASE' AND order_kind='PURCHASE'
      AND r.order_id=NEW.order_id AND r.order_item_id=NEW.id
      AND r.old_qty=OLD.qty AND r.new_qty=NEW.qty AND r.before_item=to_jsonb(OLD)
      AND c.order_type='PURCHASE' AND c.order_id=NEW.order_id AND c.status='PENDING'
      AND c.request_type='ORDER' AND c.version=r.pending_case_version) THEN
   RAISE EXCEPTION 'pending finance reference price proof is immutable' USING ERRCODE='55000'; END IF;
 END IF;
 IF TG_OP='UPDATE' AND parent_status<>0 AND NOT original_changed THEN
  RAISE EXCEPTION 'saved reference price proof cannot be independently replaced' USING ERRCODE='55000'; END IF;
 IF NEW.total_amount_input IS NULL THEN
  IF NEW.reference_price_precision_policy IS NOT NULL THEN
   RAISE EXCEPTION 'unit-price rows cannot carry a total-price reference proof' USING ERRCODE='23514'; END IF;
  RETURN NEW;
 END IF;
 -- The offline-import identity denotes an actual historical source, not a new UI choice.
 IF TG_OP='INSERT' AND NEW.legacy_id IS NOT NULL AND NEW.reference_price_precision_policy IS NULL THEN
  expected:=fn_procurement_reference_price_proof(NEW.total_amount_input,NEW.qty,NULL);
 ELSE
  policy:=fn_business_precision_snapshot();
  IF NOT fn_procurement_reference_price_policy_valid(policy) THEN
   RAISE EXCEPTION 'current reference price operation policy is invalid' USING ERRCODE='23514'; END IF;
  IF NEW.reference_price_precision_policy IS NOT NULL AND policy_changed
    AND NEW.reference_price_precision_policy IS DISTINCT FROM policy THEN
   RAISE EXCEPTION 'reference price proof differs from its actual operation' USING ERRCODE='23514'; END IF;
  expected:=fn_procurement_reference_price_proof(NEW.total_amount_input,NEW.qty,policy);
  NEW.reference_price_precision_policy:=policy;
 END IF;
 IF NEW.price IS DISTINCT FROM expected THEN
  RAISE EXCEPTION 'reference price differs from its frozen total and quantity proof' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;

CREATE TRIGGER trg_00b_purchase_reference_price_insert BEFORE INSERT ON purchase_order_items
 FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_reference_price_policy();
CREATE TRIGGER trg_00b_purchase_reference_price_update BEFORE UPDATE ON purchase_order_items
 FOR EACH ROW WHEN(OLD.qty IS DISTINCT FROM NEW.qty OR OLD.total_amount_input IS DISTINCT FROM NEW.total_amount_input
  OR OLD.price IS DISTINCT FROM NEW.price OR OLD.reference_price_precision_policy IS DISTINCT FROM NEW.reference_price_precision_policy)
 EXECUTE FUNCTION fn_guard_procurement_reference_price_policy();
CREATE TRIGGER trg_00b_subcontract_reference_price_insert BEFORE INSERT ON subcontract_order_items
 FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_reference_price_policy();
CREATE TRIGGER trg_00b_subcontract_reference_price_update BEFORE UPDATE ON subcontract_order_items
 FOR EACH ROW WHEN(OLD.qty IS DISTINCT FROM NEW.qty OR OLD.total_amount_input IS DISTINCT FROM NEW.total_amount_input
  OR OLD.price IS DISTINCT FROM NEW.price OR OLD.reference_price_precision_policy IS DISTINCT FROM NEW.reference_price_precision_policy)
 EXECUTE FUNCTION fn_guard_procurement_reference_price_policy();
ALTER TABLE purchase_order_items ENABLE ALWAYS TRIGGER trg_00b_purchase_reference_price_update;
ALTER TABLE subcontract_order_items ENABLE ALWAYS TRIGGER trg_00b_subcontract_reference_price_update;

DO $reference_price_proofs$
DECLARE definition text; anchor text; replacement text;
BEGIN
 definition:=pg_get_functiondef('fn_guard_procurement_finance_commercial_snapshot()'::regprocedure);
 anchor:='price<>fn_procurement_reference_price(total_amount_input,qty)';
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>2 THEN
  RAISE EXCEPTION 'V1062 procurement reference-price guard anchor differs'; END IF;
 EXECUTE replace(definition,anchor,'price<>fn_procurement_reference_price_proof(total_amount_input,qty,reference_price_precision_policy)');

 definition:=pg_get_functiondef('fn_is_proven_procurement_qty_revision(text,jsonb,jsonb)'::regprocedure);
 anchor:='''qty'',''amount_original'',''amount_local'',''total_amount_input'',''charged_base_qty'',''gift_base_qty'',''quantity_precision_policy'',''quantity_adoption_version'',''updated_at'',''updated_by''';
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>2 THEN
  RAISE EXCEPTION 'V1062 quantity revision permitted-column anchor differs'; END IF;
 definition:=replace(definition,anchor,
  '''qty'',''amount_original'',''amount_local'',''total_amount_input'',''charged_base_qty'',''gift_base_qty'',''quantity_precision_policy'',''quantity_adoption_version'',''price'',''reference_price_precision_policy'',''updated_at'',''updated_by''');

 anchor:='fn_procurement_revised_total_input((p_old->>''total_amount_input'')::numeric,
                (p_old->>''qty'')::numeric,(p_new->>''qty'')::numeric)';
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'V1062 quantity revision total-input proof anchor differs'; END IF;
 definition:=replace(definition,anchor,
  'fn_procurement_revised_total_input_proof((p_old->>''total_amount_input'')::numeric,
                (p_old->>''qty'')::numeric,(p_new->>''qty'')::numeric,p_new->''reference_price_precision_policy'')');

 anchor:='expected_original:=fn_procurement_revised_original(p_old,(p_new->>''qty'')::numeric);';
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'V1062 quantity revision consideration proof anchor differs'; END IF;
 replacement:='IF p_new->>''total_amount_input'' IS NULL THEN
    IF p_new->''reference_price_precision_policy'' IS NOT NULL AND p_new->''reference_price_precision_policy''<>''null''::jsonb
      OR (p_new->>''price'')::numeric IS DISTINCT FROM (p_old->>''price'')::numeric THEN RETURN FALSE; END IF;
  ELSIF (p_new->>''price'')::numeric IS DISTINCT FROM fn_procurement_reference_price_proof(
    (p_new->>''total_amount_input'')::numeric,(p_new->>''qty'')::numeric,p_new->''reference_price_precision_policy'') THEN RETURN FALSE;
  END IF;
  expected_original:=fn_procurement_revised_original_proof(p_old,(p_new->>''qty'')::numeric,p_new->''reference_price_precision_policy'');';
 definition:=replace(definition,anchor,replacement);
 EXECUTE definition;

 -- A header may flush before its items. Prepared revisions belong to this
 -- transaction and therefore use this operation's policy, not another actor's later session.
 definition:=pg_get_functiondef('fn_is_proven_procurement_header_revision(text,jsonb,jsonb)'::regprocedure);
 anchor:='fn_procurement_revised_original(r.before_item,r.new_qty)';
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>2 THEN
  RAISE EXCEPTION 'V1062 header revision consideration proof anchor differs'; END IF;
 EXECUTE replace(definition,anchor,
  'fn_procurement_revised_original_proof(r.before_item,r.new_qty,CASE WHEN i.qty=r.new_qty
    THEN i.reference_price_precision_policy ELSE fn_business_precision_snapshot() END)');

 definition:=pg_get_functiondef('fn_is_pending_purchase_case_qty_revision(jsonb,jsonb)'::regprocedure);
 anchor:='''qty'',''amountOriginal'',''amountLocal'',''totalAmountInput''';
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>2 THEN
  RAISE EXCEPTION 'V1062 pending purchase item projection anchor differs'; END IF;
 definition:=replace(definition,anchor,'''qty'',''amountOriginal'',''amountLocal'',''totalAmountInput'',''price''');
 anchor:='OR i.total_amount_input IS DISTINCT FROM (updated->>''totalAmountInput'')::numeric';
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'V1062 pending purchase reference proof anchor differs'; END IF;
 definition:=replace(definition,anchor,anchor||'
             OR i.price IS DISTINCT FROM (updated->>''price'')::numeric
             OR (i.total_amount_input IS NOT NULL AND i.price IS DISTINCT FROM
               fn_procurement_reference_price_proof(i.total_amount_input,i.qty,i.reference_price_precision_policy))');
 EXECUTE definition;
END $reference_price_proofs$;
