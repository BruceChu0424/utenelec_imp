-- Old saved quantities remain old facts. Only a new detail or a genuine edit
-- of its quantity operands freezes a new adoption and that operation's policy.
ALTER TABLE purchase_receipt_items ADD COLUMN quantity_adoption_version smallint NOT NULL DEFAULT 1,
 ADD COLUMN quantity_precision_policy jsonb;
ALTER TABLE purchase_return_items ADD COLUMN quantity_adoption_version smallint NOT NULL DEFAULT 1,
 ADD COLUMN quantity_precision_policy jsonb,ADD COLUMN quantity_source_proof jsonb;
ALTER TABLE subcontract_material_return_items ADD COLUMN quantity_adoption_version smallint NOT NULL DEFAULT 1,
 ADD COLUMN quantity_precision_policy jsonb,ADD COLUMN adopted_base_qty numeric;
ALTER TABLE subcontract_receipt_items ADD COLUMN quantity_adoption_version smallint NOT NULL DEFAULT 1,
 ADD COLUMN quantity_precision_policy jsonb,ADD COLUMN adopted_base_qty numeric;
ALTER TABLE purchase_order_items ADD COLUMN quantity_adoption_version smallint NOT NULL DEFAULT 1,
 ADD COLUMN quantity_precision_policy jsonb,ADD COLUMN charged_base_qty numeric,ADD COLUMN gift_base_qty numeric;
ALTER TABLE purchase_receipt_items ALTER COLUMN quantity_adoption_version SET DEFAULT 2;
ALTER TABLE purchase_return_items ALTER COLUMN quantity_adoption_version SET DEFAULT 2;
ALTER TABLE subcontract_material_return_items ALTER COLUMN quantity_adoption_version SET DEFAULT 2;
ALTER TABLE subcontract_receipt_items ALTER COLUMN quantity_adoption_version SET DEFAULT 2;
ALTER TABLE purchase_order_items ALTER COLUMN quantity_adoption_version SET DEFAULT 2;

-- Shared with later document owners. The caller retains its lifecycle, unit
-- identity, source capacity and frozen-row guards; this function only adopts
-- the original multiplication under the explicit operation policy.
CREATE FUNCTION fn_document_quantity_to_base(qty numeric,rate numeric,policy jsonb,record_used boolean DEFAULT false)
RETURNS numeric LANGUAGE plpgsql VOLATILE AS $$
DECLARE result numeric;details jsonb;
BEGIN
 IF qty IS NULL OR rate IS NULL OR rate<=0 OR NOT fn_financial_amount_is_exact(qty) OR NOT fn_financial_amount_is_exact(rate) THEN
  RAISE EXCEPTION 'original quantity or unit rate is missing or outside its native exact capacity' USING ERRCODE='23514';END IF;
 result:=fn_business_exact_divide_with_policy(qty*rate,1,'quantity.to-base','本次基本单位数量换算',24,policy,record_used);
 IF NOT fn_financial_amount_is_exact(result) THEN RAISE EXCEPTION 'adopted basic quantity exceeds its native capacity' USING ERRCODE='23514';END IF;
 IF qty<>0 AND result=0 THEN
  details:=jsonb_build_object('calculationKey','quantity.to-base','label','本次基本单位数量换算：所选精度会丢失非零实物，请明确重新选择',
    'maxScale',24,'reason','PRECISION_LIMIT','notWritten',true,'selectionRejected',true);
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='UTEN_PRECISION_REQUIRED:'||details::text;
 END IF;
 RETURN result;
END $$;

CREATE FUNCTION fn_document_return_quantity_slice(q numeric,whole numeric,total numeric,prior_qty numeric,prior_base numeric,policy jsonb)
RETURNS numeric LANGUAGE plpgsql VOLATILE AS $$
DECLARE result numeric;
BEGIN
 IF q=0 THEN RETURN 0;END IF;
 IF q IS NULL OR q<0 OR whole IS NULL OR whole<=0 OR total IS NULL OR total<=0
  OR prior_qty IS NULL OR prior_qty<0 OR prior_base IS NULL OR prior_base<0 OR q>whole-prior_qty THEN
  RAISE EXCEPTION 'return quantity lacks its actual source tranche capacity' USING ERRCODE='23514';END IF;
 result:=CASE WHEN q=whole-prior_qty THEN total-prior_base ELSE
  fn_business_exact_divide_with_policy(total*q,whole,'procurement.return.base-quantity','采购退货基本量换算',24,policy,true) END;
 IF result<=0 OR result>total-prior_base OR NOT fn_financial_amount_is_exact(result) THEN
  RAISE EXCEPTION 'return quantity exceeds its actual source tranche capacity' USING ERRCODE='23514';END IF;
 RETURN result;
END $$;

CREATE FUNCTION fn_guard_document_quantity_adoption() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE changed boolean;policy jsonb;charged numeric;physical numeric;free numeric;adopted numeric;
 source purchase_receipt_items%ROWTYPE;prior record;source_slice boolean:=false;
BEGIN
 IF TG_OP='INSERT' THEN
  IF NEW.quantity_adoption_version<>2 OR NEW.quantity_precision_policy IS NOT NULL THEN
   RAISE EXCEPTION 'new quantity adoption requires the current exact operation proof' USING ERRCODE='23514';END IF;
  changed:=true;
 ELSE
  IF NEW.quantity_adoption_version IS DISTINCT FROM OLD.quantity_adoption_version
    OR NEW.quantity_precision_policy IS DISTINCT FROM OLD.quantity_precision_policy
    OR to_jsonb(NEW)->'quantity_source_proof' IS DISTINCT FROM to_jsonb(OLD)->'quantity_source_proof' THEN
   RAISE EXCEPTION 'saved quantity adoption evidence cannot be independently replaced' USING ERRCODE='55000';END IF;
  IF TG_TABLE_NAME IN('subcontract_material_return_items','subcontract_receipt_items')
    AND to_jsonb(NEW)->'adopted_base_qty' IS DISTINCT FROM to_jsonb(OLD)->'adopted_base_qty'
    AND NEW.qty IS NOT DISTINCT FROM OLD.qty AND NEW.unit_id IS NOT DISTINCT FROM OLD.unit_id AND NEW.unit_rate IS NOT DISTINCT FROM OLD.unit_rate THEN
   RAISE EXCEPTION 'saved quantity adoption cannot be independently replaced' USING ERRCODE='55000';END IF;
  changed:=to_jsonb(NEW)->'qty' IS DISTINCT FROM to_jsonb(OLD)->'qty'
    OR to_jsonb(NEW)->'unit_id' IS DISTINCT FROM to_jsonb(OLD)->'unit_id'
    OR to_jsonb(NEW)->'unit_rate' IS DISTINCT FROM to_jsonb(OLD)->'unit_rate'
    OR to_jsonb(NEW)->'quantity_semantics' IS DISTINCT FROM to_jsonb(OLD)->'quantity_semantics'
    OR to_jsonb(NEW)->'gift_qty' IS DISTINCT FROM to_jsonb(OLD)->'gift_qty'
    OR to_jsonb(NEW)->'charged_base_qty' IS DISTINCT FROM to_jsonb(OLD)->'charged_base_qty'
    OR to_jsonb(NEW)->'gift_base_qty' IS DISTINCT FROM to_jsonb(OLD)->'gift_base_qty'
    OR to_jsonb(NEW)->'adopted_base_qty' IS DISTINCT FROM to_jsonb(OLD)->'adopted_base_qty';
 END IF;
 IF NOT changed THEN RETURN NEW;END IF;
 IF NEW.unit_id IS NULL OR NEW.unit_rate IS NULL OR NEW.unit_rate<=0 OR NEW.qty IS NULL OR NEW.qty<0 THEN
  RAISE EXCEPTION 'quantity adoption requires its actual positive unit rate and original unit' USING ERRCODE='23514';END IF;
 policy:=fn_business_precision_snapshot();
 IF TG_TABLE_NAME IN('subcontract_material_return_items','subcontract_receipt_items') THEN
  IF NEW.qty<=0 THEN RAISE EXCEPTION 'material return requires a positive original quantity' USING ERRCODE='23514';END IF;
  adopted:=fn_document_quantity_to_base(NEW.qty,NEW.unit_rate,policy,true);
  IF adopted<=0 OR NOT fn_financial_amount_is_exact(adopted) THEN
   RAISE EXCEPTION 'quantity adoption loses its positive source quantity' USING ERRCODE='23514';END IF;
  IF TG_OP='INSERT' AND NEW.adopted_base_qty IS NOT NULL AND NEW.adopted_base_qty IS DISTINCT FROM adopted THEN
   RAISE EXCEPTION 'supplied quantity adoption differs from original operands and actual policy' USING ERRCODE='23514';END IF;
  NEW.adopted_base_qty:=adopted;
 ELSE
  free:=CASE WHEN NEW.quantity_semantics='CHARGED_PLUS_GIFT_V1' THEN NEW.gift_qty ELSE 0 END;
  IF free IS NULL OR free<0 OR NEW.qty+free<=0 THEN RAISE EXCEPTION 'invalid charged and gift source quantities' USING ERRCODE='23514';END IF;
  -- Approval may adopt a remaining slice of an already frozen source. This
  -- retains its final residual and is distinct from multiplying by today's rate.
  IF TG_TABLE_NAME='purchase_return_items' AND TG_OP='UPDATE' AND NEW.quantity_semantics='CHARGED_PLUS_GIFT_V1'
    AND NEW.qty IS NOT DISTINCT FROM OLD.qty AND NEW.gift_qty IS NOT DISTINCT FROM OLD.gift_qty
    AND NEW.unit_id IS NOT DISTINCT FROM OLD.unit_id AND NEW.unit_rate IS NOT DISTINCT FROM OLD.unit_rate THEN
   SELECT * INTO source FROM purchase_receipt_items WHERE id=NEW.receipt_item_id AND quantity_semantics='CHARGED_PLUS_GIFT_V1';
   IF FOUND THEN
    SELECT COALESCE(sum(i.qty),0) qty,COALESCE(sum(i.charged_base_qty),0) charged,
      COALESCE(sum(i.gift_qty),0) gift_qty,COALESCE(sum(i.gift_base_qty),0) gift_base INTO prior
     FROM purchase_return_items i JOIN purchase_returns d ON d.id=i.return_id
     WHERE i.receipt_item_id=NEW.receipt_item_id AND i.return_id<>NEW.return_id
       AND d.status=1 AND NOT i.is_deleted AND NOT d.is_deleted;
    charged:=fn_document_return_quantity_slice(NEW.qty,source.qty,source.charged_base_qty,prior.qty,prior.charged,policy);
    physical:=charged+fn_document_return_quantity_slice(free,source.gift_qty,source.gift_base_qty,prior.gift_qty,prior.gift_base,policy);
    NEW.quantity_source_proof:=jsonb_build_object('kind','SOURCE_RECEIPT','sourceId',source.id,'sourceQty',source.qty,'sourceChargedBase',source.charged_base_qty,
      'sourceGiftQty',source.gift_qty,'sourceGiftBase',source.gift_base_qty,'priorQty',prior.qty,'priorChargedBase',prior.charged,'priorGiftQty',prior.gift_qty,'priorGiftBase',prior.gift_base);
    source_slice:=true;
   END IF;
  END IF;
  IF NOT source_slice THEN
   charged:=fn_document_quantity_to_base(NEW.qty,NEW.unit_rate,policy,true);
   physical:=fn_document_quantity_to_base(NEW.qty+free,NEW.unit_rate,policy,true);
   IF TG_TABLE_NAME='purchase_return_items' THEN NEW.quantity_source_proof:=NULL;END IF;
  END IF;
  IF TG_TABLE_NAME='purchase_order_items' THEN NEW.charged_base_qty:=charged;NEW.gift_base_qty:=physical-charged;END IF;
  IF NEW.charged_base_qty IS DISTINCT FROM charged OR NEW.gift_base_qty IS DISTINCT FROM physical-charged
    OR charged<0 OR physical<=0 OR charged>physical OR NEW.qty>0 AND charged=0 OR free>0 AND physical=charged
    OR NOT fn_financial_amount_is_exact(physical) THEN
   RAISE EXCEPTION 'saved charged and gift quantities do not match the actual quantity adoption' USING ERRCODE='23514';END IF;
 END IF;
 NEW.quantity_adoption_version:=2;NEW.quantity_precision_policy:=policy;
 RETURN NEW;
END $$;
DO $quantity_adoption$
DECLARE target text;
BEGIN
 FOREACH target IN ARRAY ARRAY['purchase_receipt_items','purchase_return_items','subcontract_material_return_items','subcontract_receipt_items','purchase_order_items'] LOOP
  EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I CHECK(quantity_adoption_version IN(1,2) AND (quantity_adoption_version=1 AND quantity_precision_policy IS NULL OR quantity_adoption_version=2 AND quantity_precision_policy IS NOT NULL))',target,target||'_quantity_adoption_chk');
  EXECUTE format('CREATE TRIGGER trg_00_document_quantity_adoption BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION fn_guard_document_quantity_adoption()',target);
  EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER trg_00_document_quantity_adoption',target);
 END LOOP;
END $quantity_adoption$;

CREATE FUNCTION fn_document_material_return_base(item subcontract_material_return_items) RETURNS numeric LANGUAGE plpgsql VOLATILE AS $$
DECLARE expected numeric;
BEGIN
 IF item.unit_id IS NULL OR item.unit_rate IS NULL OR item.unit_rate<=0 THEN
  RAISE EXCEPTION 'material return source unit basis is unknown' USING ERRCODE='23514';END IF;
 IF item.quantity_adoption_version=1 AND item.quantity_precision_policy IS NULL THEN
  expected:=item.qty*item.unit_rate;
 ELSE
  expected:=fn_document_quantity_to_base(item.qty,item.unit_rate,item.quantity_precision_policy,false);
  IF expected IS DISTINCT FROM item.adopted_base_qty THEN
   RAISE EXCEPTION 'material return frozen quantity policy does not prove its adoption' USING ERRCODE='23514';END IF;
 END IF;
 IF expected IS NULL OR expected<=0 OR NOT fn_financial_amount_is_exact(expected) THEN
  RAISE EXCEPTION 'material return source lacks a native exact adoption' USING ERRCODE='23514';END IF;
 RETURN expected;
END $$;
DO $material_return_value_source$
DECLARE definition text;needle text;replacement text;count integer:=0;
BEGIN
 SELECT pg_get_functiondef('fn_is_workshop_material_value_store(uuid)'::regprocedure) INTO definition;
 replacement:='movement.qty=CASE WHEN item.quantity_adoption_version=1 AND event.value_precision_version=1 THEN round(item.qty*COALESCE(item.unit_rate,1),4) ELSE fn_document_material_return_base(item) END';
 FOREACH needle IN ARRAY ARRAY[
  'movement.qty=CASE WHEN event.value_precision_version=1 THEN round(item.qty*COALESCE(item.unit_rate,1),4) ELSE item.qty*COALESCE(item.unit_rate,1) END',
  'movement.qty=CASE WHEN event.value_precision_version=1 THEN round(item.qty*COALESCE(item.unit_rate,1),4) ELSE fn_business_exact_divide_with_policy(item.qty*COALESCE(item.unit_rate,1),1,''quantity.to-base'',''本次数量换算基本量'',24,event.business_precision_policy,false) END'
 ] LOOP
  IF position(needle IN definition)>0 THEN definition:=replace(definition,needle,replacement);count:=count+1;END IF;
 END LOOP;
 IF count<>1 THEN RAISE EXCEPTION 'Review changed material return actual quantity proof';END IF;
 EXECUTE definition;
END $material_return_value_source$;

-- The material-return ledger must prove its relationship to original document
-- operands, as well as the already guarded movement/event/transfer identity.
CREATE FUNCTION fn_validate_material_return_quantity_adoption() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE item subcontract_material_return_items%ROWTYPE;raw_q business_numeric_input_evidence%ROWTYPE;
 raw_rate business_numeric_input_evidence%ROWTYPE;basis business_numeric_input_evidence%ROWTYPE;original stock_movements%ROWTYPE;
 expected numeric;matches integer;
BEGIN
 IF NEW.source_doc_type<>'SUBCONTRACT_MATERIAL_RETURN' OR NEW.movement_type<>16 THEN RETURN NULL;END IF;
 SELECT * INTO STRICT item FROM subcontract_material_return_items WHERE id=NEW.source_item_id
   AND material_return_id=NEW.source_doc_id AND goods_id=NEW.goods_id AND color_id IS NOT DISTINCT FROM NEW.color_id;
 IF NEW.unit_id IS DISTINCT FROM item.unit_id OR NEW.unit_rate IS DISTINCT FROM item.unit_rate THEN
  RAISE EXCEPTION 'material-return movement lost its original unit basis' USING ERRCODE='23514';END IF;
 IF NEW.direction=1 THEN
  SELECT * INTO STRICT raw_q FROM business_numeric_input_evidence WHERE owner_kind='STOCK_MOVEMENT' AND owner_id=NEW.id AND source_row_id=item.id
    AND field_key='rawQuantity' AND source_action_id=pg_current_xact_id()::text;
  SELECT * INTO STRICT raw_rate FROM business_numeric_input_evidence WHERE owner_kind='STOCK_MOVEMENT' AND owner_id=NEW.id AND source_row_id=item.id
    AND field_key='rawUnitRate' AND source_action_id=pg_current_xact_id()::text;
  SELECT * INTO STRICT basis FROM business_numeric_input_evidence WHERE owner_kind='STOCK_MOVEMENT' AND owner_id=NEW.id AND source_row_id=item.id
    AND field_key='frozenBasicQuantity' AND source_action_id=pg_current_xact_id()::text;
  expected:=fn_document_material_return_base(item);
  IF raw_q.original_decimal::numeric IS DISTINCT FROM item.qty OR raw_q.recorded_decimal::numeric IS DISTINCT FROM item.qty
    OR raw_rate.original_decimal::numeric IS DISTINCT FROM item.unit_rate OR raw_rate.recorded_decimal::numeric IS DISTINCT FROM item.unit_rate
    OR raw_q.original_unit->>'kind' IS DISTINCT FROM 'LINE_QUANTITY' OR raw_q.original_unit->>'referenceId' IS DISTINCT FROM item.unit_id::text
    OR raw_rate.original_unit->>'kind' IS DISTINCT FROM 'RATIO' OR raw_rate.original_unit->>'code' IS DISTINCT FROM 'BASE_PER_LINE'
    OR raw_rate.original_unit->>'referenceId' IS DISTINCT FROM item.unit_id::text
    OR basis.original_unit->>'kind' IS DISTINCT FROM 'DOCUMENT_ADOPTED_QTY' OR basis.original_unit->>'referenceId' IS DISTINCT FROM item.id::text
    OR basis.recorded_unit->>'kind' IS DISTINCT FROM 'GOODS_BASE' OR basis.recorded_unit->>'referenceId' IS DISTINCT FROM item.goods_id::text
    OR basis.original_decimal::numeric IS DISTINCT FROM expected OR basis.recorded_decimal::numeric IS DISTINCT FROM expected OR NEW.qty IS DISTINCT FROM expected
    OR NOT fn_financial_amount_is_exact(expected) THEN
   RAISE EXCEPTION 'material-return movement lacks its saved original quantity adoption' USING ERRCODE='23514';END IF;
 ELSE
  SELECT * INTO STRICT basis FROM business_numeric_input_evidence WHERE owner_kind='STOCK_MOVEMENT' AND owner_id=NEW.id AND source_row_id=item.id
    AND field_key='restoredBasicQuantity' AND source_action_id=pg_current_xact_id()::text;
  SELECT count(*) INTO matches FROM stock_movements m WHERE m.source_doc_type=NEW.source_doc_type AND m.source_doc_id=NEW.source_doc_id
    AND m.source_item_id=NEW.source_item_id AND m.goods_id=NEW.goods_id AND m.color_id IS NOT DISTINCT FROM NEW.color_id
    AND m.warehouse_id=NEW.warehouse_id AND m.movement_type=NEW.movement_type AND m.direction=1;
  SELECT * INTO STRICT original FROM stock_movements WHERE id=(basis.original_unit->>'referenceId')::uuid;
  IF matches<>1 OR original.source_doc_type IS DISTINCT FROM NEW.source_doc_type OR original.source_doc_id IS DISTINCT FROM NEW.source_doc_id
    OR original.source_item_id IS DISTINCT FROM NEW.source_item_id OR original.goods_id IS DISTINCT FROM NEW.goods_id
    OR original.color_id IS DISTINCT FROM NEW.color_id OR original.warehouse_id IS DISTINCT FROM NEW.warehouse_id
    OR original.movement_type IS DISTINCT FROM NEW.movement_type OR original.direction<>1
    OR basis.original_unit->>'kind' IS DISTINCT FROM 'STOCK_MOVEMENT_QTY'
    OR basis.recorded_unit->>'kind' IS DISTINCT FROM 'GOODS_BASE' OR basis.recorded_unit->>'referenceId' IS DISTINCT FROM NEW.goods_id::text
    OR basis.original_decimal::numeric IS DISTINCT FROM original.qty OR basis.recorded_decimal::numeric IS DISTINCT FROM original.qty
    OR NEW.qty IS DISTINCT FROM original.qty THEN
   RAISE EXCEPTION 'material-return inverse lacks its unique actual original quantity' USING ERRCODE='23514';END IF;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER material_return_quantity_adoption AFTER INSERT ON stock_movements DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW EXECUTE FUNCTION fn_validate_material_return_quantity_adoption();
ALTER TABLE stock_movements ENABLE ALWAYS TRIGGER material_return_quantity_adoption;

-- Raw warehouse input may carry 48 places; only the chosen 24-place kilogram
-- fact reaches receipt/IQC/stock. The immutable same-action evidence retains
-- every original digit and its actual policy, without retagging old weights.
CREATE FUNCTION fn_validate_receipt_weight_adoption() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE evidence business_numeric_input_evidence%ROWTYPE;kind text;document uuid;raw numeric;expected numeric;
BEGIN
 IF NEW.weight IS NULL OR TG_OP='UPDATE' AND NEW.weight IS NOT DISTINCT FROM OLD.weight THEN RETURN NULL;END IF;
 IF TG_TABLE_NAME='purchase_receipt_items' THEN kind:='PURCHASE_RECEIPT';document:=NEW.receipt_id;
 ELSE kind:='SUBCONTRACT_RECEIPT';document:=NEW.receipt_id;END IF;
 SELECT * INTO STRICT evidence FROM business_numeric_input_evidence
  WHERE owner_kind=kind AND owner_id=document AND source_row_id=NEW.id AND field_key='actualWeightKg'
    AND source_action_id=pg_current_xact_id()::text;
 raw:=evidence.original_decimal::numeric;
 IF raw<0 OR abs(raw)>=1e40::numeric OR scale(trim_scale(raw))>48
    OR evidence.original_unit->>'kind' IS DISTINCT FROM 'WEIGHT' OR evidence.original_unit->>'code' IS DISTINCT FROM 'KG'
    OR evidence.recorded_unit IS DISTINCT FROM evidence.original_unit THEN
  RAISE EXCEPTION 'receipt weight lacks its actual original kilogram input' USING ERRCODE='23514';END IF;
 expected:=fn_business_exact_divide_with_policy(raw,1,'weight.kg-field','本次千克重量记录',24,evidence.precision_policy,false);
 IF expected IS DISTINCT FROM NEW.weight OR evidence.recorded_decimal::numeric IS DISTINCT FROM expected
    OR raw>0 AND expected=0 OR NOT fn_financial_amount_is_exact(expected) THEN
  RAISE EXCEPTION 'receipt weight does not match its original input and actual policy' USING ERRCODE='23514';END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER purchase_receipt_weight_adoption AFTER INSERT OR UPDATE ON purchase_receipt_items
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_validate_receipt_weight_adoption();
CREATE CONSTRAINT TRIGGER subcontract_receipt_weight_adoption AFTER INSERT OR UPDATE ON subcontract_receipt_items
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_validate_receipt_weight_adoption();
ALTER TABLE purchase_receipt_items ENABLE ALWAYS TRIGGER purchase_receipt_weight_adoption;
ALTER TABLE subcontract_receipt_items ENABLE ALWAYS TRIGGER subcontract_receipt_weight_adoption;
