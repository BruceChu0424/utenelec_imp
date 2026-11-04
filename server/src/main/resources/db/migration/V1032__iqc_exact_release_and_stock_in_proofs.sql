-- Existing rows keep their actual v1 proof. Every new event/batch item receives
-- an exact-version marker and the operation's immutable policy, even when all
-- divisions terminate and the choices object is empty.
ALTER TABLE procurement_inspection_events
 ADD COLUMN numeric_proof_version smallint NOT NULL DEFAULT 1,
 ADD COLUMN business_precision_policy jsonb;
ALTER TABLE procurement_iqc_stock_in_batch_items
 ADD COLUMN numeric_proof_version smallint NOT NULL DEFAULT 1,
 ADD COLUMN business_precision_policy jsonb;
ALTER TABLE procurement_inspection_events ALTER COLUMN numeric_proof_version SET DEFAULT 2;
ALTER TABLE procurement_iqc_stock_in_batch_items ALTER COLUMN numeric_proof_version SET DEFAULT 2;
ALTER TABLE procurement_inspection_events ADD CONSTRAINT inspection_numeric_proof_version_chk CHECK(numeric_proof_version IN(1,2));
ALTER TABLE procurement_iqc_stock_in_batch_items ADD CONSTRAINT iqc_stock_numeric_proof_version_chk CHECK(numeric_proof_version IN(1,2));

CREATE FUNCTION fn_guard_iqc_frozen_precision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='INSERT' THEN
  IF NEW.numeric_proof_version<>2 OR NEW.business_precision_policy IS NULL THEN
   RAISE EXCEPTION 'new IQC facts require an exact proof version and actual operation policy' USING ERRCODE='23514';
  END IF;
 ELSIF NEW.numeric_proof_version IS DISTINCT FROM OLD.numeric_proof_version
    OR NEW.business_precision_policy IS DISTINCT FROM OLD.business_precision_policy THEN
  RAISE EXCEPTION 'frozen IQC precision evidence cannot be independently replaced' USING ERRCODE='55000';
 END IF;
 RETURN NEW;
END $$;

CREATE FUNCTION fn_iqc_stock_in_frozen_share(p_total numeric,p_whole numeric,p_before numeric,p_quantity numeric,p_actual_before numeric,p_version integer,p_policy jsonb,p_key text)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE target numeric;
BEGIN
 IF p_version=1 AND p_policy IS NULL THEN
  RETURN fn_iqc_frozen_interval(p_total,p_whole,p_before,p_quantity,p_version,p_policy,p_key);
 END IF;
 IF p_actual_before IS NULL OR p_actual_before<0 OR p_actual_before>p_total THEN
  RAISE EXCEPTION 'IQC stock-in lacks complete actual previously allocated evidence' USING ERRCODE='23514';
 END IF;
 target:=fn_iqc_frozen_cumulative(p_total,p_whole,p_before+p_quantity,p_version,p_policy,p_key);
 IF target<p_actual_before OR target>p_total THEN PERFORM fn_iqc_reject_split_choice(p_key);END IF;
 RETURN target-p_actual_before;
END $$;
DO $iqc_policy$
DECLARE target text;
BEGIN
 FOREACH target IN ARRAY ARRAY['procurement_inspection_events','procurement_iqc_stock_in_batch_items'] LOOP
  EXECUTE format('CREATE TRIGGER trg_00_iqc_operation_policy BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION fn_guard_business_precision_policy()',target);
  EXECUTE format('CREATE TRIGGER trg_01_iqc_frozen_precision BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION fn_guard_iqc_frozen_precision()',target);
  EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER trg_00_iqc_operation_policy',target);
  EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER trg_01_iqc_frozen_precision',target);
 END LOOP;
END $iqc_policy$;

CREATE FUNCTION fn_iqc_frozen_cumulative(p_total numeric,p_whole numeric,p_quantity numeric,p_version integer,p_policy jsonb,p_key text)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
BEGIN
 IF p_total IS NULL OR p_whole IS NULL OR p_whole<=0 OR p_quantity IS NULL OR p_quantity<0 OR p_quantity>p_whole
    OR p_total::text IN('NaN','Infinity','-Infinity') OR p_whole::text IN('NaN','Infinity','-Infinity') OR p_quantity::text IN('NaN','Infinity','-Infinity')
    OR p_key IS NULL OR p_key NOT IN('money.cumulative-share','quantity.slice') THEN
  RAISE EXCEPTION 'invalid frozen IQC amount or quantity interval' USING ERRCODE='23514';
 END IF;
 IF p_version=1 AND p_policy IS NULL THEN RETURN round(p_total*p_quantity/p_whole,4);END IF;
 IF p_version IS DISTINCT FROM 2 OR p_policy IS NULL OR p_policy->>'version' IS DISTINCT FROM '1' OR jsonb_typeof(p_policy->'choices') IS DISTINCT FROM 'object'
    THEN
  RAISE EXCEPTION 'IQC exact proof requires its own frozen operation policy' USING ERRCODE='23514';
 END IF;
 IF p_quantity=0 THEN RETURN 0;END IF;
 IF p_quantity=p_whole THEN RETURN p_total;END IF;
 RETURN fn_business_exact_divide_with_policy(p_total*p_quantity,p_whole,p_key,
   CASE WHEN p_key='quantity.slice' THEN '本次数量或重量切片' ELSE '本次金额分摊' END,24,p_policy,false);
END $$;
CREATE FUNCTION fn_iqc_frozen_interval(p_total numeric,p_whole numeric,p_before numeric,p_quantity numeric,p_version integer,p_policy jsonb,p_key text)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
BEGIN
 IF p_before IS NULL OR p_quantity IS NULL OR p_quantity<0 THEN RAISE EXCEPTION 'invalid frozen IQC slice' USING ERRCODE='23514';END IF;
 RETURN fn_iqc_frozen_cumulative(p_total,p_whole,p_before+p_quantity,p_version,p_policy,p_key)
       -fn_iqc_frozen_cumulative(p_total,p_whole,p_before,p_version,p_policy,p_key);
END;
$$;

CREATE FUNCTION fn_iqc_reject_split_choice(p_key text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE details jsonb;
BEGIN
 details:=jsonb_build_object('calculationKey',p_key,'label',CASE WHEN p_key='quantity.slice' THEN '本次数量或重量切片：原来源余额不足，请重新选择' ELSE '本次金额分摊：原来源余额不足，请重新选择' END,
   'maxScale',24,'reason','PRECISION_LIMIT','notWritten',true,'selectionRejected',true);
 RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='UTEN_PRECISION_REQUIRED:'||details::text;
END $$;

-- Retain the complete current identity/actor/warehouse/quantity guards. Only
-- their old four-place arithmetic verification is replaced, with exact
-- cardinality checks so a changed owning function cannot silently be patched.
DO $iqc_current_proofs$
DECLARE definition text;changed text;needle text;replacement text;
BEGIN
 SELECT replace(pg_get_functiondef('fn_validate_procurement_iqc_pass_release_value()'::regprocedure),E'\r','') INTO definition;
 needle:='v_expected_amount := ROUND[(].*?;';
 replacement:='v_expected_amount := fn_iqc_frozen_interval(v_inspection.received_amount_local,v_inspection.received_base_qty,v_resolved_before,NEW.base_qty,NEW.numeric_proof_version,NEW.business_precision_policy,''money.cumulative-share'');';
 IF (SELECT count(*) FROM regexp_matches(definition,needle,'sg'))<>1 THEN RAISE EXCEPTION 'review current IQC PASS amount proof';END IF;
 changed:=regexp_replace(definition,needle,replacement,'s');
 needle:='v_expected_weight := CASE.*?END;';
 replacement:='v_expected_weight := CASE WHEN v_inspection.received_weight IS NULL THEN NULL ELSE fn_iqc_frozen_interval(v_inspection.received_weight,v_inspection.received_base_qty,v_resolved_before,NEW.base_qty,NEW.numeric_proof_version,NEW.business_precision_policy,''quantity.slice'') END;';
 IF (SELECT count(*) FROM regexp_matches(changed,needle,'sg'))<>1 THEN RAISE EXCEPTION 'review current IQC PASS weight proof';END IF;
 changed:=regexp_replace(changed,needle,replacement,'s');EXECUTE changed;

 SELECT replace(pg_get_functiondef('fn_validate_procurement_iqc_stock_in_item()'::regprocedure),E'\r','') INTO definition;
 needle:='v_event_confirmed_amount IS DISTINCT FROM ROUND[(].*?4[)]';
 replacement:='NEW.amount_local IS DISTINCT FROM fn_iqc_stock_in_frozen_share(v_event.released_amount_local,v_event.base_qty,v_event.base_qty-NEW.expected_remaining_base_qty,NEW.base_qty,(SELECT COALESCE(SUM(prior.amount_local),0) FROM procurement_iqc_stock_in_batch_items prior WHERE prior.pass_event_id=NEW.pass_event_id AND prior.stock_sequence<NEW.stock_sequence),NEW.numeric_proof_version,NEW.business_precision_policy,''money.cumulative-share'')';
 IF (SELECT count(*) FROM regexp_matches(definition,needle,'sg'))<>1 THEN RAISE EXCEPTION 'review current IQC stock-in amount proof';END IF;
 changed:=regexp_replace(definition,needle,replacement,'s');
 needle:='v_event_confirmed_weight IS DISTINCT FROM ROUND[(].*?4[)]';
 replacement:='NEW.weight IS DISTINCT FROM fn_iqc_stock_in_frozen_share(v_event.released_weight,v_event.base_qty,v_event.base_qty-NEW.expected_remaining_base_qty,NEW.base_qty,(SELECT CASE WHEN count(*)=0 THEN 0 WHEN count(prior.weight)=count(*) THEN SUM(prior.weight) END FROM procurement_iqc_stock_in_batch_items prior WHERE prior.pass_event_id=NEW.pass_event_id AND prior.stock_sequence<NEW.stock_sequence),NEW.numeric_proof_version,NEW.business_precision_policy,''quantity.slice'')';
 IF (SELECT count(*) FROM regexp_matches(changed,needle,'sg'))<>1 THEN RAISE EXCEPTION 'review current IQC stock-in weight proof';END IF;
 changed:=regexp_replace(changed,needle,replacement,'s');
 needle:='    -- V743(ADR-135):';
 replacement:=E'    IF NEW.numeric_proof_version=2 AND v_event.id IS NOT NULL AND v_event.base_qty>0 THEN\n'
  ||E'      IF v_event.released_amount_local IS NOT NULL AND (v_event_confirmed_amount>v_event.released_amount_local OR (v_event_confirmed=v_event.base_qty AND v_event_confirmed_amount IS DISTINCT FROM v_event.released_amount_local)) THEN\n'
  ||E'        PERFORM fn_iqc_reject_split_choice(''money.cumulative-share'');\n      END IF;\n'
  ||E'      IF v_event.released_weight IS NOT NULL AND (v_event_confirmed_weight>v_event.released_weight OR (v_event_confirmed=v_event.base_qty AND v_event_confirmed_weight IS DISTINCT FROM v_event.released_weight)) THEN\n'
  ||E'        PERFORM fn_iqc_reject_split_choice(''quantity.slice'');\n      END IF;\n    END IF;\n'||needle;
 IF position(needle IN changed)=0 THEN RAISE EXCEPTION 'review current IQC stock-in precision rejection position';END IF;
 changed:=replace(changed,needle,replacement);
 needle:='       OR v_event_confirmed > v_event.base_qty';
 replacement:=needle||E'\n       OR v_event_confirmed_amount > v_event.released_amount_local\n       OR (v_event_confirmed=v_event.base_qty AND v_event_confirmed_amount IS DISTINCT FROM v_event.released_amount_local)\n       OR (v_event.released_weight IS NOT NULL AND (v_event_confirmed_weight>v_event.released_weight OR (v_event_confirmed=v_event.base_qty AND v_event_confirmed_weight IS DISTINCT FROM v_event.released_weight)))';
 IF position(needle IN changed)=0 THEN RAISE EXCEPTION 'review current IQC stock-in source budget proof';END IF;
 changed:=replace(changed,needle,replacement);EXECUTE changed;
END $iqc_current_proofs$;
