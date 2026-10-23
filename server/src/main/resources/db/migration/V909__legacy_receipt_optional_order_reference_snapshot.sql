-- Preserve a recorded optional upstream order identity without inventing an
-- order when the old source no longer contains it. Mandatory masters, complete
-- typed source proofs, original quantities and every operational guard remain.
ALTER TABLE public.purchase_receipt_items ADD COLUMN order_item_legacy_id integer
    CHECK(order_item_legacy_id IS NULL OR order_item_legacy_id>0);
ALTER TABLE public.subcontract_receipt_items ADD COLUMN order_item_legacy_id integer
    CHECK(order_item_legacy_id IS NULL OR order_item_legacy_id>0);
COMMENT ON COLUMN public.purchase_receipt_items.order_item_legacy_id IS
    'Immutable positive original optional P_InItem.OrderID; not a foreign key or usable capacity. A missing historical order keeps order_item_id NULL; bound by the complete original import proof.';
COMMENT ON COLUMN public.subcontract_receipt_items.order_item_legacy_id IS
    'Immutable positive original optional E_InItem.OrderID; not a foreign key or usable capacity. A missing historical order keeps order_item_id NULL; bound by the complete original import proof.';

-- Forward-only: V627 stays byte-for-byte applied. Its registrar automatically
-- includes every new projection field in target_fields and the snapshot hash.
DO $projection$
DECLARE definition text; anchor text; replacement text;
BEGIN
    definition:=replace(pg_get_functiondef('public.fn_legacy_receipt_source_projection(text,jsonb)'::regprocedure),E'\r\n',E'\n');
    anchor:=E'    IF purchase THEN\n        SELECT to_jsonb(parent) INTO parent_row FROM public.purchase_receipts parent';
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V909 original receipt item projection entry anchor differs';
    END IF;
    replacement:=E'    IF (s->>''order_item_legacy_id'')::integer<0 THEN\n'
        ||E'        RAISE EXCEPTION ''negative original optional order identity requires source review'' USING ERRCODE=''23514'';\n'
        ||E'    END IF;\n'||anchor;
    definition:=replace(definition,anchor,replacement);
    anchor:='''receipt_id'',receipt,''order_item_id'',order_item,''goods_id'',goods,''color_id'',color,''unit_id'',unit,';
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V909 original receipt item identity projection anchor differs';
    END IF;
    replacement:='''receipt_id'',receipt,''order_item_id'',order_item,'
        ||E'\n        ''order_item_legacy_id'',CASE WHEN (s->>''order_item_legacy_id'')::integer>0 THEN (s->>''order_item_legacy_id'')::integer ELSE NULL END,'
        ||E'\n        ''goods_id'',goods,''color_id'',color,''unit_id'',unit,';
    definition:=replace(definition,anchor,replacement);
    anchor:='(''unit_legacy_id'',''unit_id''),(''order_item_legacy_id'',''order_item_id'')) reference(source_key,target_key)';
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V909 original optional order reference rejection anchor differs';
    END IF;
    definition:=replace(definition,anchor,'(''unit_legacy_id'',''unit_id'')) reference(source_key,target_key)');
    EXECUTE definition;
END;
$projection$;

-- A new snapshot is not an online alias/foreign key. Its exact positive value
-- must be in this transaction's complete V627 source proof. Existing proofs
-- without the new field retain NULL; nothing is retrospectively filled.
CREATE FUNCTION public.fn_guard_legacy_receipt_order_reference() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE proof public.legacy_procurement_receipt_import_sources%ROWTYPE;
    expected_kind text; expected_file text; upstream_table text; linked_ids uuid[];
BEGIN
    IF TG_OP='UPDATE' THEN
        IF NEW.order_item_legacy_id IS DISTINCT FROM OLD.order_item_legacy_id THEN
            RAISE EXCEPTION 'original optional order identity cannot be added, changed or cleared'
                USING ERRCODE='23514',CONSTRAINT=TG_NAME;
        END IF;
        -- In particular, a later legal returned_qty/gift_returned_qty mutation
        -- must not have to replay a first-insert transaction's issued_txid.
        RETURN NEW;
    END IF;
    IF NEW.order_item_legacy_id IS NULL THEN RETURN NEW; END IF;
    IF NEW.order_item_legacy_id<=0 OR NEW.legacy_import_run_id IS NULL OR NEW.legacy_id IS NULL THEN
        RAISE EXCEPTION 'original optional order identity requires complete original item source evidence'
            USING ERRCODE='23514',CONSTRAINT=TG_NAME;
    END IF;
    expected_kind:=CASE TG_TABLE_NAME WHEN 'purchase_receipt_items' THEN 'PURCHASE_ITEM' ELSE 'SUBCONTRACT_ITEM' END;
    expected_file:=CASE TG_TABLE_NAME WHEN 'purchase_receipt_items' THEN 'purchase_receipt_items.csv' ELSE 'subcontract_in_i.csv' END;
    upstream_table:=CASE TG_TABLE_NAME WHEN 'purchase_receipt_items' THEN 'purchase_order_items' ELSE 'subcontract_order_items' END;
    -- Replan exact unique identities rather than retain an empty-table plan.
    EXECUTE 'SELECT * FROM public.legacy_procurement_receipt_import_sources '
        'WHERE run_id=$1 AND target_id=$2 AND target_table=$3 AND source_legacy_id=$4'
        INTO proof USING NEW.legacy_import_run_id,NEW.id,TG_TABLE_NAME,NEW.legacy_id;
    IF proof.id IS NULL OR proof.source_kind IS DISTINCT FROM expected_kind
       OR proof.source_file IS DISTINCT FROM expected_file OR proof.issued_txid<>txid_current()
       OR NOT ('order_item_legacy_id'=ANY(proof.target_fields))
       OR proof.source_file_sha256 IS DISTINCT FROM (SELECT sha256 FROM public.legacy_migration_run_files
            WHERE run_id=proof.run_id AND file_name=proof.source_file) THEN
        RAISE EXCEPTION 'original optional order identity has no exact new-field proof for this source and transaction'
            USING ERRCODE='23514',CONSTRAINT=TG_NAME;
    END IF;
    PERFORM public.fn_assert_legacy_receipt_import_source(TG_TABLE_NAME,to_jsonb(NEW));
    EXECUTE format('SELECT array_agg(id) FROM public.%I WHERE legacy_id=$1',upstream_table)
        INTO linked_ids USING NEW.order_item_legacy_id;
    IF COALESCE(cardinality(linked_ids),0)>1 OR NEW.order_item_id IS DISTINCT FROM linked_ids[1] THEN
        RAISE EXCEPTION 'original optional order identity must resolve only to its exact real upstream row'
            USING ERRCODE='23514',CONSTRAINT=TG_NAME;
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_zy_legacy_receipt_order_reference BEFORE INSERT OR UPDATE
    ON public.purchase_receipt_items FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_receipt_order_reference();
CREATE TRIGGER trg_zy_legacy_receipt_order_reference BEFORE INSERT OR UPDATE
    ON public.subcontract_receipt_items FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_receipt_order_reference();
ALTER TABLE public.purchase_receipt_items ENABLE ALWAYS TRIGGER trg_zy_legacy_receipt_order_reference;
ALTER TABLE public.subcontract_receipt_items ENABLE ALWAYS TRIGGER trg_zy_legacy_receipt_order_reference;

-- Derived review queue only: each positive snapshot without a real FK can be
-- joined to its existing immutable V627 run/row/file SHA and target UUID.
CREATE INDEX ix_purchase_receipt_original_order_gap ON public.purchase_receipt_items(legacy_import_run_id,order_item_legacy_id)
    WHERE order_item_legacy_id IS NOT NULL AND order_item_id IS NULL;
CREATE INDEX ix_subcontract_receipt_original_order_gap ON public.subcontract_receipt_items(legacy_import_run_id,order_item_legacy_id)
    WHERE order_item_legacy_id IS NOT NULL AND order_item_id IS NULL;
