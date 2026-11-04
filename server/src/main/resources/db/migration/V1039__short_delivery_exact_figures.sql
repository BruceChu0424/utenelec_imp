-- Physical quantities keep the native 24-place boundary. A threshold is the
-- exact finite product of its original quantity and percentage, up to 50 places.
DO $floor_reference$
DECLARE name text;definition text;
BEGIN
 IF (SELECT atttypmod FROM pg_attribute WHERE attrelid='subcontract_short_delivery_cases'::regclass AND attname='floor_qty')>=0 THEN
  PERFORM fn_migrate_financial_amount_columns('[{"table":"subcontract_short_delivery_cases","column":"floor_qty"}]'::jsonb);
 END IF;
 name:='ck_financial_exact_'||substr(md5('public.subcontract_short_delivery_cases.floor_qty'),1,24);
 SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint WHERE conrelid='subcontract_short_delivery_cases'::regclass AND conname=name;
 IF FOUND THEN
  IF position('fn_financial_amount_is_exact' IN definition)=0 THEN RAISE EXCEPTION 'Review changed short-delivery threshold bound';END IF;
  EXECUTE format('ALTER TABLE subcontract_short_delivery_cases DROP CONSTRAINT %I',name);
 END IF;
END $floor_reference$;
ALTER TABLE subcontract_short_delivery_cases ADD CONSTRAINT short_delivery_floor_reference_exact CHECK(
 floor_qty IS NULL OR (floor_qty::text NOT IN('NaN','Infinity','-Infinity') AND floor_qty>=0 AND abs(floor_qty)<1e40 AND scale(trim_scale(floor_qty))<=50));
ALTER TABLE subcontract_short_delivery_cases
 ADD COLUMN shortfall_pct_precision_version smallint NOT NULL DEFAULT 1,
 ADD COLUMN shortfall_pct_precision_policy jsonb,
 ADD COLUMN loss_pct_precision_version smallint NOT NULL DEFAULT 1,
 ADD COLUMN loss_pct_precision_policy jsonb;
ALTER TABLE subcontract_short_delivery_cases ALTER COLUMN shortfall_pct_precision_version SET DEFAULT 2,
 ALTER COLUMN loss_pct_precision_version SET DEFAULT 2,
 ALTER COLUMN shortfall_pct SET DEFAULT 0;
ALTER TABLE subcontract_short_delivery_cases ADD CONSTRAINT short_delivery_pct_precision_check CHECK(
 (shortfall_pct_precision_version=1 AND shortfall_pct_precision_policy IS NULL
  OR shortfall_pct_precision_version=2 AND shortfall_pct_precision_policy IS NOT NULL)
 AND (loss_pct_precision_version=1 AND loss_pct_precision_policy IS NULL
  OR loss_pct_precision_version=2 AND (loss_pct IS NULL AND loss_pct_precision_policy IS NULL OR loss_pct IS NOT NULL AND loss_pct_precision_policy IS NOT NULL)));

CREATE FUNCTION fn_subcontract_shortfall_percent(q numeric,d numeric,policy jsonb,record_used boolean) RETURNS numeric LANGUAGE plpgsql VOLATILE AS $$
BEGIN
 IF q IS NULL OR q<=0 THEN RETURN 0;END IF;
 RETURN fn_business_exact_divide_with_policy(greatest(q-COALESCE(d,0),0)*100,q,
  'subcontract.shortfall.percent','本次委外短交比例',24,policy,record_used);
END $$;

CREATE FUNCTION fn_guard_short_delivery_exact_figures() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE ratio_changed boolean;floor_changed boolean;accepting boolean;policy jsonb;
BEGIN
 IF TG_OP='INSERT' THEN
  IF NEW.shortfall_pct_precision_version<>2 OR NEW.shortfall_pct_precision_policy IS NOT NULL
   OR NEW.loss_pct_precision_version<>2 OR NEW.loss_pct_precision_policy IS NOT NULL THEN
   RAISE EXCEPTION 'new short-delivery figures require the actual current operation' USING ERRCODE='23514';END IF;
  ratio_changed:=true;floor_changed:=true;accepting:=NEW.status='ACCEPTED_LOSS';
 ELSE
  IF NEW.shortfall_pct_precision_version IS DISTINCT FROM OLD.shortfall_pct_precision_version
   OR NEW.shortfall_pct_precision_policy IS DISTINCT FROM OLD.shortfall_pct_precision_policy
   OR NEW.loss_pct_precision_version IS DISTINCT FROM OLD.loss_pct_precision_version
   OR NEW.loss_pct_precision_policy IS DISTINCT FROM OLD.loss_pct_precision_policy THEN
   RAISE EXCEPTION 'short-delivery adopted precision cannot be independently replaced' USING ERRCODE='55000';END IF;
  ratio_changed:=NEW.ordered_qty IS DISTINCT FROM OLD.ordered_qty OR NEW.delivered_qty IS DISTINCT FROM OLD.delivered_qty;
  floor_changed:=ratio_changed OR NEW.allowed_loss_pct IS DISTINCT FROM OLD.allowed_loss_pct;
  accepting:=NEW.status='ACCEPTED_LOSS' AND OLD.status<>'ACCEPTED_LOSS';
  IF NOT ratio_changed AND NEW.shortfall_pct IS DISTINCT FROM OLD.shortfall_pct
   OR NOT floor_changed AND NEW.floor_qty IS DISTINCT FROM OLD.floor_qty THEN
   RAISE EXCEPTION 'short-delivery derived values cannot be independently edited' USING ERRCODE='55000';END IF;
  IF OLD.status='ACCEPTED_LOSS' AND (NEW.loss_qty IS DISTINCT FROM OLD.loss_qty OR NEW.loss_pct IS DISTINCT FROM OLD.loss_pct) THEN
   RAISE EXCEPTION 'accepted loss figures are frozen; use the original reversal path' USING ERRCODE='55000';END IF;
 END IF;
 IF floor_changed THEN
  NEW.floor_qty:=CASE WHEN NEW.allowed_loss_pct IS NULL THEN NULL ELSE NEW.ordered_qty*greatest(100-NEW.allowed_loss_pct,0)*0.01 END;
 END IF;
 IF ratio_changed THEN
  policy:=fn_business_precision_snapshot();
  NEW.shortfall_pct:=fn_subcontract_shortfall_percent(NEW.ordered_qty,NEW.delivered_qty,policy,true);
  NEW.shortfall_pct_precision_version:=2;NEW.shortfall_pct_precision_policy:=policy;
 END IF;
 IF accepting THEN
  policy:=fn_business_precision_snapshot();
  NEW.loss_pct:=fn_subcontract_shortfall_percent(NEW.ordered_qty,NEW.delivered_qty,policy,true);
  NEW.loss_pct_precision_version:=2;NEW.loss_pct_precision_policy:=policy;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_00_short_delivery_exact_figures BEFORE INSERT OR UPDATE ON subcontract_short_delivery_cases
 FOR EACH ROW EXECUTE FUNCTION fn_guard_short_delivery_exact_figures();
ALTER TABLE subcontract_short_delivery_cases ENABLE ALWAYS TRIGGER trg_00_short_delivery_exact_figures;

-- Patch the current installed definitions so later business sources, ACLs,
-- ownership and column contracts are retained. Never restore the old V636 view.
DO $loss_summary_precision$
DECLARE target text;definition text;needle text;replacement text;matches integer;
BEGIN
 FOREACH target IN ARRAY ARRAY['v_subcontract_supplier_goods_loss_summary','v_subcontract_supplier_loss_summary'] LOOP
  SELECT pg_get_viewdef(target::regclass,true) INTO definition;
  needle:='round(sum(loss_qty) * 100::numeric / sum(ordered_qty), 2)';
  matches:=(length(definition)-length(replace(definition,needle,'')))/length(needle);
  IF matches<>1 THEN RAISE EXCEPTION 'Review changed supplier loss aggregation %',target;END IF;
  replacement:='fn_business_exact_divide(sum(loss_qty)*100,sum(ordered_qty),''subcontract.loss-summary.percent'',''本次供应商损耗比例'',24)';
  definition:=replace(definition,needle,replacement);
  IF target='v_subcontract_supplier_goods_loss_summary' THEN
   needle:='round(loss_qty * 100::numeric / ordered_qty, 2)';
   matches:=(length(definition)-length(replace(definition,needle,'')))/length(needle);
   IF matches<>1 THEN RAISE EXCEPTION 'Review changed supplier maximum loss calculation';END IF;
   definition:=replace(definition,needle,'fn_business_exact_divide(loss_qty*100,ordered_qty,''subcontract.loss-summary.percent'',''本次供应商损耗比例'',24)');
  END IF;
  EXECUTE format('CREATE OR REPLACE VIEW %I AS %s',target,definition);
 END LOOP;
END $loss_summary_precision$;
