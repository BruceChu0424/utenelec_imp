-- Initial successor assembly inherits saved facts, not a new conversion. Its
-- live row must still equal that original when the copy transaction commits.
-- Later normal draft editing/replacement uses the existing adoption paths.
CREATE FUNCTION fn_document_successor_scope(p_table text)
RETURNS TABLE(header_table text,parent_column text,source_column text,family text,quantity_adoption boolean)
LANGUAGE sql IMMUTABLE AS $$
    SELECT s.header_table,s.parent_column,s.source_column,s.family,s.quantity_adoption FROM (VALUES
        ('purchase_order_items','purchase_orders','order_id','reference_price_successor_source_id','purchaseOrder',true),
        ('subcontract_order_items','subcontract_orders','order_id','reference_price_successor_source_id','subcontractOrder',false),
        ('purchase_receipt_items','purchase_receipts','receipt_id','quantity_successor_source_id','purchaseReceipt',true),
        ('purchase_return_items','purchase_returns','return_id','quantity_successor_source_id','purchaseReturn',true),
        ('subcontract_receipt_items','subcontract_receipts','receipt_id','quantity_successor_source_id','subcontractReceipt',true),
        ('subcontract_material_return_items','subcontract_material_returns','material_return_id','quantity_successor_source_id','subcontractMaterialReturn',true),
        ('sales_return_items','sales_returns','return_id','quantity_successor_source_id','salesReturn',true)
    ) s(line_table,header_table,parent_column,source_column,family,quantity_adoption) WHERE s.line_table=p_table
$$;

CREATE FUNCTION fn_document_successor_source_id(p_table text,p_row jsonb) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
    SELECT (p_row->>scope.source_column)::uuid FROM fn_document_successor_scope(p_table) scope
$$;

CREATE FUNCTION fn_document_successor_preserved_fields(p_table text) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
    SELECT ARRAY['bill_date','goods_id','color_id','unit_id','unit_rate','qty','quantity_semantics','gift_qty',
        'charged_base_qty','gift_base_qty','adopted_base_qty','quantity_adoption_version','quantity_precision_policy','quantity_source_proof',
        'receipt_quantity_version','receipt_base_qty','receipt_quantity_proof','order_item_id','receipt_item_id','out_item_id',
        'material_issue_item_id','request_item_id','replacement_intent','gift_replacement_intent','price','amount_original','amount_local',
        'parent_goods_id','parent_color_id','cost_amount']::text[]
        || CASE WHEN p_table IN('purchase_order_items','subcontract_order_items')
            THEN ARRAY['total_amount_input','reference_price_precision_policy','extra_columns']::text[] ELSE ARRAY[]::text[] END
$$;

DO $successor_columns$
DECLARE target text;
BEGIN
    FOREACH target IN ARRAY ARRAY['purchase_return_items','subcontract_receipt_items','subcontract_material_return_items','sales_return_items'] LOOP
        EXECUTE format('ALTER TABLE %I ADD COLUMN quantity_successor_source_id uuid REFERENCES %I(id)',target,target);
        EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I UNIQUE(quantity_successor_source_id)',target,target||'_quantity_successor_unique');
    END LOOP;
    FOR target IN SELECT scope_table FROM unnest(ARRAY['purchase_order_items','subcontract_order_items','purchase_receipt_items',
        'purchase_return_items','subcontract_receipt_items','subcontract_material_return_items','sales_return_items']) scope_table LOOP
        EXECUTE format('ALTER TABLE %I ADD COLUMN successor_copy_txid bigint',target);
    END LOOP;
END $successor_columns$;

CREATE FUNCTION fn_assert_document_successor_inputs(p_table text,p_new jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE scope record;source jsonb;old_status smallint;new_status smallint;old_deleted boolean;new_deleted boolean;field text;source_id uuid;
BEGIN
    SELECT * INTO scope FROM fn_document_successor_scope(p_table);
    IF NOT FOUND THEN RAISE EXCEPTION 'Unsupported saved successor source family' USING ERRCODE='23514';END IF;
    source_id:=fn_document_successor_source_id(p_table,p_new);
    IF source_id IS NULL THEN RAISE EXCEPTION 'Saved successor source is missing' USING ERRCODE='23514';END IF;
    EXECUTE format('SELECT to_jsonb(i),original.status,draft.status,original.is_deleted,draft.is_deleted
        FROM %I i JOIN %I original ON original.id=i.%I JOIN %I draft ON draft.id=$1
        WHERE i.id=$2 AND i.id<>$3 AND original.id<>draft.id AND NOT i.is_deleted FOR SHARE OF i,original,draft',
        p_table,scope.header_table,scope.parent_column,scope.header_table)
        INTO source,old_status,new_status,old_deleted,new_deleted
        USING (p_new->>scope.parent_column)::uuid,source_id,(p_new->>'id')::uuid;
    IF source IS NULL OR old_status IS DISTINCT FROM -1 OR new_status IS DISTINCT FROM 0 OR old_deleted OR new_deleted THEN
        RAISE EXCEPTION 'Saved successor requires a reversed original line and a distinct live draft' USING ERRCODE='23514';END IF;
    FOREACH field IN ARRAY fn_document_successor_preserved_fields(p_table) LOOP
        IF p_new->field IS DISTINCT FROM source->field THEN
            RAISE EXCEPTION 'quantity successor must preserve original input and adoption field %',field USING ERRCODE='23514';
        END IF;
    END LOOP;
END $$;

CREATE FUNCTION fn_prepare_document_successor_copy() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.successor_copy_txid IS NOT NULL THEN
        RAISE EXCEPTION 'Successor copy transaction must come from its actual initial assembly' USING ERRCODE='23514';END IF;
    IF fn_document_successor_source_id(TG_TABLE_NAME,to_jsonb(NEW)) IS NOT NULL THEN
        PERFORM fn_assert_document_successor_inputs(TG_TABLE_NAME,to_jsonb(NEW));
        NEW.successor_copy_txid:=txid_current();
    END IF;
    RETURN NEW;
END $$;

CREATE FUNCTION fn_guard_document_successor_source() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE old_source uuid:=fn_document_successor_source_id(TG_TABLE_NAME,to_jsonb(OLD));field text;
BEGIN
    IF fn_document_successor_source_id(TG_TABLE_NAME,to_jsonb(NEW)) IS DISTINCT FROM old_source
        OR NEW.successor_copy_txid IS DISTINCT FROM OLD.successor_copy_txid THEN
        RAISE EXCEPTION 'saved quantity successor source is immutable' USING ERRCODE='55000';END IF;
    IF old_source IS NOT NULL AND NEW.id IS DISTINCT FROM OLD.id THEN
        RAISE EXCEPTION 'saved quantity successor line identity is immutable' USING ERRCODE='55000';END IF;
    IF old_source IS NOT NULL AND OLD.successor_copy_txid=txid_current() THEN
        FOREACH field IN ARRAY fn_document_successor_preserved_fields(TG_TABLE_NAME) LOOP
            IF to_jsonb(NEW)->field IS DISTINCT FROM to_jsonb(OLD)->field THEN
                RAISE EXCEPTION 'initial successor copy inputs cannot change in its assembly transaction' USING ERRCODE='23514';
            END IF;
        END LOOP;
    END IF;
    RETURN NEW;
END $$;

CREATE FUNCTION fn_assert_document_successor_lineage(p_table text,p_inserted jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE scope record;current_row jsonb;source jsonb;source_id uuid;valid boolean;
BEGIN
    source_id:=fn_document_successor_source_id(p_table,p_inserted);
    IF source_id IS NULL THEN RETURN;END IF;
    SELECT * INTO STRICT scope FROM fn_document_successor_scope(p_table);
    EXECUTE format('SELECT to_jsonb(i) FROM %I i WHERE id=$1 AND %I=$2 AND %I=$3 AND NOT is_deleted',
        p_table,scope.parent_column,scope.source_column) INTO current_row
        USING (p_inserted->>'id')::uuid,(p_inserted->>scope.parent_column)::uuid,source_id;
    IF current_row IS NULL OR current_row->'successor_copy_txid' IS DISTINCT FROM p_inserted->'successor_copy_txid'
        OR current_row->>'successor_copy_txid' IS DISTINCT FROM txid_current()::text THEN
        RAISE EXCEPTION 'Saved successor requires its current initial copy identity' USING ERRCODE='23514';END IF;
    PERFORM fn_assert_document_successor_inputs(p_table,current_row);
    EXECUTE format('SELECT to_jsonb(i) FROM %I i WHERE id=$1',p_table) INTO source USING source_id;
    SELECT EXISTS(SELECT 1 FROM document_unapprovals relation WHERE relation.family=scope.family
        AND relation.original_id=(source->>scope.parent_column)::uuid AND relation.draft_id=(current_row->>scope.parent_column)::uuid
        AND relation.line_id_map->>source_id::text=current_row->>'id') INTO valid;
    IF NOT valid THEN RAISE EXCEPTION 'quantity successor requires its immutable unapproval line mapping' USING ERRCODE='23514';END IF;
END $$;

CREATE FUNCTION fn_require_document_successor_lineage() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM fn_assert_document_successor_lineage(TG_TABLE_NAME,to_jsonb(NEW));
    RETURN NULL;
END $$;

-- Keep existing caller signatures/constraint names while routing their checks
-- through one current-row source/lineage owner. No old migration is rewritten.
CREATE OR REPLACE FUNCTION fn_assert_purchase_receipt_quantity_successor(p_new jsonb) RETURNS void LANGUAGE plpgsql AS $$
BEGIN PERFORM fn_assert_document_successor_inputs('purchase_receipt_items',p_new);END $$;
CREATE OR REPLACE FUNCTION fn_require_purchase_receipt_quantity_successor_lineage() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN PERFORM fn_assert_document_successor_lineage(TG_TABLE_NAME,to_jsonb(NEW));RETURN NULL;END $$;
CREATE OR REPLACE FUNCTION fn_require_procurement_reference_price_successor_lineage() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN PERFORM fn_assert_document_successor_lineage(TG_TABLE_NAME,to_jsonb(NEW));RETURN NULL;END $$;

DO $initial_copy_guards$
DECLARE target text;
BEGIN
    DROP TRIGGER trg_guard_purchase_receipt_quantity_successor_source ON purchase_receipt_items;
    FOR target IN SELECT scope_table FROM unnest(ARRAY['purchase_order_items','subcontract_order_items','purchase_receipt_items',
        'purchase_return_items','subcontract_receipt_items','subcontract_material_return_items','sales_return_items']) scope_table LOOP
        -- This sorts before the existing quantity/money-adoption triggers.
        EXECUTE format('CREATE TRIGGER trg_00_00_successor_copy BEFORE INSERT ON %I FOR EACH ROW EXECUTE FUNCTION fn_prepare_document_successor_copy()',target);
        EXECUTE format('CREATE TRIGGER trg_guard_document_successor_source BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION fn_guard_document_successor_source()',target);
        EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER trg_00_00_successor_copy',target);
        EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER trg_guard_document_successor_source',target);
        IF target NOT IN('purchase_receipt_items','purchase_order_items','subcontract_order_items') THEN
            EXECUTE format('CREATE CONSTRAINT TRIGGER trg_require_document_successor_lineage AFTER INSERT ON %I DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_require_document_successor_lineage()',target);
            EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER trg_require_document_successor_lineage',target);
        END IF;
    END LOOP;
END $initial_copy_guards$;

DO $inherit_saved_quantity$
DECLARE definition text;needle text;start_at integer;end_at integer;old_block text;
BEGIN
    SELECT pg_get_functiondef('fn_guard_document_quantity_adoption()'::regprocedure) INTO definition;
    needle:='IF TG_OP=''INSERT'' AND TG_TABLE_NAME=''purchase_receipt_items''';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V1062 original receipt successor dispatch differs';END IF;
    definition:=replace(definition,needle,'IF TG_OP=''INSERT'' AND TG_TABLE_NAME IN(''purchase_order_items'',''purchase_receipt_items'',''purchase_return_items'',''subcontract_receipt_items'',''subcontract_material_return_items'')');
    definition:=replace(definition,'to_jsonb(NEW)->>''quantity_successor_source_id'' IS NOT NULL',
        'fn_document_successor_source_id(TG_TABLE_NAME,to_jsonb(NEW)) IS NOT NULL');
    needle:='PERFORM fn_assert_purchase_receipt_quantity_successor(to_jsonb(NEW));';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V1062 original receipt successor proof differs';END IF;
    EXECUTE replace(definition,needle,'IF NEW.successor_copy_txid IS DISTINCT FROM txid_current() THEN RAISE EXCEPTION ''Initial quantity successor assembly is unproved'' USING ERRCODE=''23514'';END IF;');

    SELECT pg_get_functiondef('fn_guard_sales_return_quantity_adoption()'::regprocedure) INTO definition;
    needle:='IF TG_OP=''INSERT'' THEN';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V1062 original sales return quantity adoption differs';END IF;
    EXECUTE replace(definition,needle,'IF TG_OP=''INSERT'' AND NEW.quantity_successor_source_id IS NOT NULL THEN
        IF NEW.successor_copy_txid IS DISTINCT FROM txid_current() THEN RAISE EXCEPTION ''Initial quantity successor assembly is unproved'' USING ERRCODE=''23514'';END IF;
        RETURN NEW;
    END IF;
    '||needle);

    SELECT pg_get_functiondef('fn_guard_procurement_reference_price_policy()'::regprocedure) INTO definition;
    start_at:=position('IF NEW.reference_price_successor_source_id IS DISTINCT FROM OLD.reference_price_successor_source_id' IN definition);
    end_at:=position('changed:=' IN definition);
    IF start_at=0 OR end_at<=start_at THEN RAISE EXCEPTION 'V1062 original money successor identity block differs';END IF;
    old_block:=substring(definition FROM start_at FOR end_at-start_at);definition:=replace(definition,old_block,'');
    start_at:=position('IF TG_OP=''INSERT'' AND NEW.reference_price_successor_source_id IS NOT NULL THEN' IN definition);
    end_at:=position('-- Genuine imported historical rows' IN definition);
    IF start_at=0 OR end_at<=start_at THEN RAISE EXCEPTION 'V1062 original money successor input block differs';END IF;
    old_block:=substring(definition FROM start_at FOR end_at-start_at);
    EXECUTE replace(definition,old_block,'IF TG_OP=''INSERT'' AND NEW.reference_price_successor_source_id IS NOT NULL THEN
        IF NEW.successor_copy_txid IS DISTINCT FROM txid_current() THEN RAISE EXCEPTION ''Initial reference successor assembly is unproved'' USING ERRCODE=''23514'';END IF;
        IF NOT fn_procurement_reference_price_matches(new_item) THEN RAISE EXCEPTION ''reference price successor source proof is inconsistent'' USING ERRCODE=''23514'';END IF;
        RETURN NEW;
    END IF;
    ');
END $inherit_saved_quantity$;
