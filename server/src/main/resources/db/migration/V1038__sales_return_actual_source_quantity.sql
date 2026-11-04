-- One authoritative original shipment movement; all quantity and value readers
-- can consume the same row without multiplying a current document rate again.
CREATE FUNCTION fn_sales_shipment_original_movement(item sales_shipment_items) RETURNS stock_movements LANGUAGE plpgsql STABLE AS $$
DECLARE original stock_movements%ROWTYPE;matches integer:=0;
BEGIN
 FOR original IN SELECT movement.* FROM stock_movements movement JOIN sales_shipments document ON document.id=item.shipment_id
 WHERE movement.source_doc_type='SALES_SHIPMENT' AND movement.source_doc_id=item.shipment_id
  AND movement.source_item_id=item.id AND movement.movement_type=3 AND movement.direction=-1
  AND movement.goods_id=item.goods_id AND movement.color_id IS NOT DISTINCT FROM item.color_id
  AND movement.warehouse_id=COALESCE(item.warehouse_id,document.warehouse_id) LOOP
  matches:=matches+1;
  IF matches>1 THEN RAISE EXCEPTION 'shipment requires its unique actual original physical movement' USING ERRCODE='23514';END IF;
 END LOOP;
 IF matches<>1 THEN RAISE EXCEPTION 'shipment requires its unique actual original physical movement' USING ERRCODE='23514';END IF;
 IF original.qty IS NULL OR original.qty<=0 OR NOT fn_financial_amount_is_exact(original.qty) THEN
  RAISE EXCEPTION 'shipment actual physical movement is outside native exact capacity' USING ERRCODE='23514';END IF;
 RETURN original;
END $$;
CREATE OR REPLACE FUNCTION fn_sales_shipment_original_base(item sales_shipment_items) RETURNS numeric LANGUAGE sql STABLE AS $$
 SELECT (fn_sales_shipment_original_movement(item)).qty
$$;

ALTER TABLE sales_return_items ADD COLUMN receipt_quantity_version smallint NOT NULL DEFAULT 1,
 ADD COLUMN receipt_base_qty numeric,ADD COLUMN receipt_quantity_proof jsonb;
ALTER TABLE sales_return_items ALTER COLUMN receipt_quantity_version SET DEFAULT 2;
ALTER TABLE sales_return_items ADD CONSTRAINT sales_return_received_quantity_proof_chk CHECK(
 receipt_quantity_version IN(1,2) AND ((receipt_base_qty IS NULL AND receipt_quantity_proof IS NULL)
 OR (receipt_quantity_version=2 AND receipt_base_qty>0 AND fn_financial_amount_is_exact(receipt_base_qty) AND receipt_quantity_proof IS NOT NULL)));

-- A returned portion is a cumulative target minus the actual already received
-- quantity. The final portion owns the original remainder, independent of a
-- newly supplied unrelated rounding choice.
CREATE FUNCTION fn_sales_return_quantity_plan(p_item uuid,p_policy jsonb,p_record_used boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE item sales_return_items%ROWTYPE;document sales_returns%ROWTYPE;source sales_shipment_items%ROWTYPE;
 shipment sales_shipments%ROWTYPE;original stock_movements%ROWTYPE;prior record;target numeric;adopted numeric;
BEGIN
 SELECT * INTO STRICT item FROM sales_return_items WHERE id=p_item AND NOT is_deleted;
 SELECT * INTO STRICT document FROM sales_returns WHERE id=item.return_id AND NOT is_deleted;
 SELECT * INTO STRICT source FROM sales_shipment_items WHERE id=item.out_item_id AND NOT is_deleted FOR UPDATE;
 SELECT * INTO STRICT shipment FROM sales_shipments WHERE id=source.shipment_id AND NOT is_deleted;
 IF document.status<>0 OR shipment.status<>1 OR shipment.warehouse_work_status<>'SHIPPED'
   OR shipment.shipment_kind NOT IN('ORDER','DIRECT_CUSTOMER') OR document.client_id IS DISTINCT FROM shipment.client_id
   OR item.goods_id IS DISTINCT FROM source.goods_id OR item.color_id IS DISTINCT FROM source.color_id
   OR item.unit_id IS NULL OR item.unit_id IS DISTINCT FROM source.unit_id OR item.unit_rate IS NULL OR item.unit_rate<=0
   OR item.unit_rate IS DISTINCT FROM source.unit_rate OR item.qty IS NULL OR item.qty<=0 OR source.qty IS NULL OR source.qty<=0 THEN
  RAISE EXCEPTION 'return requires a known, actually shipped source and its original customer/unit identity; legacy origin needs review' USING ERRCODE='23514';END IF;
 original:=fn_sales_shipment_original_movement(source);
 SELECT COALESCE(sum(previous.qty),0) qty,COALESCE(sum(actual.base_qty),0) base_qty,
   count(*) FILTER(WHERE actual.matches<>1 OR actual.base_qty IS NULL OR actual.base_qty<=0) missing INTO prior
 FROM sales_return_items previous JOIN sales_returns returned ON returned.id=previous.return_id
 LEFT JOIN LATERAL (
  SELECT count(*) matches,min(qty) base_qty FROM (
   SELECT quality.received_base_qty qty FROM sales_return_quality_items quality
    WHERE quality.return_item_id=previous.id AND quality.return_id=returned.id AND quality.status<>'REVERSED'
      AND quality.goods_id=previous.goods_id AND quality.color_id IS NOT DISTINCT FROM previous.color_id
      AND quality.warehouse_id=returned.warehouse_id AND quality.unit_id IS NOT DISTINCT FROM previous.unit_id
      AND quality.unit_rate IS NOT DISTINCT FROM previous.unit_rate
   UNION ALL
   SELECT movement.qty FROM stock_movements movement
    WHERE NOT EXISTS(SELECT 1 FROM sales_return_quality_items quality WHERE quality.return_item_id=previous.id)
     AND movement.source_doc_type='SALES_RETURN' AND movement.source_doc_id=returned.id AND movement.source_item_id=previous.id
     AND movement.movement_type=4 AND movement.direction=1 AND movement.goods_id=previous.goods_id
     AND movement.color_id IS NOT DISTINCT FROM previous.color_id AND movement.warehouse_id=returned.warehouse_id
  ) facts
 ) actual ON true
 WHERE previous.out_item_id=source.id AND previous.return_id<>document.id AND returned.status=1
  AND NOT previous.is_deleted AND NOT returned.is_deleted;
 IF prior.missing<>0 OR source.returned_qty IS DISTINCT FROM prior.qty OR prior.qty<0 OR prior.base_qty<0
   OR prior.qty+item.qty>source.qty OR prior.base_qty>=original.qty THEN
  RAISE EXCEPTION 'return source lacks complete actual prior quantities or remaining physical capacity' USING ERRCODE='23514';END IF;
 IF prior.qty+item.qty=source.qty THEN target:=original.qty;
 ELSE target:=fn_business_exact_divide_with_policy(original.qty*(prior.qty+item.qty),source.qty,
  'sales.return.base-quantity','本次销售退货基本数量',24,p_policy,p_record_used);END IF;
 adopted:=target-prior.base_qty;
 IF adopted<=0 OR adopted>original.qty-prior.base_qty OR NOT fn_financial_amount_is_exact(adopted) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='UTEN_PRECISION_REQUIRED:'||jsonb_build_object('calculationKey','sales.return.base-quantity',
    'label','本次销售退货基本数量：所选精度不能覆盖原实际份额，请明确重新选择','maxScale',24,'reason','PRECISION_LIMIT','selectionRejected',true,'notWritten',true)::text;
 END IF;
 RETURN jsonb_build_object('version',1,'kind','ACTUAL_SHIPMENT_RETURN','sourceItemId',source.id,'sourceMovementId',original.id,
  'sourceQuantity',source.qty,'sourceBaseQuantity',original.qty,'priorQuantity',prior.qty,'priorBaseQuantity',prior.base_qty,
  'sliceQuantity',item.qty,'receivedBaseQuantity',adopted,'precisionPolicy',p_policy);
END $$;

CREATE FUNCTION fn_guard_sales_return_quantity_adoption() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE expected jsonb;
BEGIN
 IF TG_OP='INSERT' THEN
  IF NEW.receipt_quantity_version<>2 OR NEW.receipt_quantity_proof IS NOT NULL OR NEW.receipt_base_qty IS NOT NULL THEN
   RAISE EXCEPTION 'new return detail cannot invent an old or already received physical proof' USING ERRCODE='23514';END IF;
 ELSIF OLD.receipt_quantity_proof IS NOT NULL THEN
  IF NEW.receipt_quantity_version IS DISTINCT FROM OLD.receipt_quantity_version OR NEW.receipt_quantity_proof IS DISTINCT FROM OLD.receipt_quantity_proof
    OR NEW.receipt_base_qty IS DISTINCT FROM OLD.receipt_base_qty OR NEW.qty IS DISTINCT FROM OLD.qty OR NEW.out_item_id IS DISTINCT FROM OLD.out_item_id
    OR NEW.unit_id IS DISTINCT FROM OLD.unit_id OR NEW.unit_rate IS DISTINCT FROM OLD.unit_rate
    OR NEW.goods_id IS DISTINCT FROM OLD.goods_id OR NEW.color_id IS DISTINCT FROM OLD.color_id OR NEW.return_id IS DISTINCT FROM OLD.return_id THEN
   RAISE EXCEPTION 'actual return quantity and its original source proof are immutable' USING ERRCODE='55000';END IF;
 ELSE
  IF NEW.receipt_quantity_proof IS NOT NULL OR NEW.receipt_base_qty IS NOT NULL THEN
   IF NEW.qty IS DISTINCT FROM OLD.qty OR NEW.out_item_id IS DISTINCT FROM OLD.out_item_id OR NEW.unit_id IS DISTINCT FROM OLD.unit_id
     OR NEW.unit_rate IS DISTINCT FROM OLD.unit_rate OR NEW.goods_id IS DISTINCT FROM OLD.goods_id
     OR NEW.color_id IS DISTINCT FROM OLD.color_id OR NEW.return_id IS DISTINCT FROM OLD.return_id THEN
    RAISE EXCEPTION 'return adoption must consume its already saved original operands' USING ERRCODE='23514';END IF;
   expected:=fn_sales_return_quantity_plan(NEW.id,fn_business_precision_snapshot(),false);
   IF NEW.receipt_quantity_version<>2 OR NEW.receipt_quantity_proof IS DISTINCT FROM expected
     OR NEW.receipt_base_qty IS DISTINCT FROM (expected->>'receivedBaseQuantity')::numeric THEN
    RAISE EXCEPTION 'return physical quantity does not match its actual original shipment tranche' USING ERRCODE='23514';END IF;
  ELSIF NEW.receipt_quantity_version IS DISTINCT FROM OLD.receipt_quantity_version THEN
   RAISE EXCEPTION 'return quantity version cannot be independently replaced' USING ERRCODE='55000';END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_00_sales_return_quantity_adoption BEFORE INSERT OR UPDATE ON sales_return_items
 FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_return_quantity_adoption();
ALTER TABLE sales_return_items ENABLE ALWAYS TRIGGER trg_00_sales_return_quantity_adoption;

CREATE FUNCTION fn_sales_return_adopt_base(p_item uuid) RETURNS numeric LANGUAGE plpgsql VOLATILE AS $$
DECLARE item sales_return_items%ROWTYPE;proof jsonb;adopted numeric;
BEGIN
 SELECT * INTO STRICT item FROM sales_return_items WHERE id=p_item AND NOT is_deleted FOR UPDATE;
 IF item.receipt_quantity_proof IS NOT NULL THEN RETURN item.receipt_base_qty;END IF;
 proof:=fn_sales_return_quantity_plan(p_item,fn_business_precision_snapshot(),true);
 adopted:=(proof->>'receivedBaseQuantity')::numeric;
 UPDATE sales_return_items SET receipt_base_qty=adopted,receipt_quantity_proof=proof,receipt_quantity_version=2 WHERE id=p_item;
 RETURN adopted;
END $$;

CREATE FUNCTION fn_validate_sales_return_received_quantity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE item sales_return_items%ROWTYPE;document sales_returns%ROWTYPE;
BEGIN
 SELECT * INTO STRICT item FROM sales_return_items WHERE id=NEW.return_item_id AND return_id=NEW.return_id AND NOT is_deleted;
 SELECT * INTO STRICT document FROM sales_returns WHERE id=NEW.return_id AND NOT is_deleted;
 IF document.status<>1 OR item.receipt_quantity_version<>2 OR item.receipt_quantity_proof IS NULL OR item.receipt_base_qty IS DISTINCT FROM NEW.received_base_qty
  OR item.goods_id IS DISTINCT FROM NEW.goods_id OR item.color_id IS DISTINCT FROM NEW.color_id
  OR item.unit_id IS DISTINCT FROM NEW.unit_id OR item.unit_rate IS DISTINCT FROM NEW.unit_rate
  OR document.warehouse_id IS DISTINCT FROM NEW.warehouse_id THEN
  RAISE EXCEPTION 'return quality receipt lost its actual source quantity, unit or warehouse identity' USING ERRCODE='23514';END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER sales_return_received_quantity AFTER INSERT ON sales_return_quality_items
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_validate_sales_return_received_quantity();
ALTER TABLE sales_return_quality_items ENABLE ALWAYS TRIGGER sales_return_received_quantity;
