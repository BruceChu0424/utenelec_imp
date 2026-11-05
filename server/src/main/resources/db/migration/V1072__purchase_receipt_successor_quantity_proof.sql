-- A successor draft inherits its predecessor's frozen quantity adoption. It is
-- not a new conversion under today's policy. The source must be an actual
-- reversed receipt line and the immutable unapproval relation must corroborate
-- the exact original/new line pair before the transaction can commit.
ALTER TABLE purchase_receipt_items
    ADD COLUMN quantity_successor_source_id uuid REFERENCES purchase_receipt_items(id),
    ADD CONSTRAINT purchase_receipt_quantity_successor_source_unique UNIQUE(quantity_successor_source_id);
COMMENT ON COLUMN purchase_receipt_items.quantity_successor_source_id IS
    '反审继任草稿继承的原收货明细；基础量、原始输入和采用证据在组装时逐项相同，提交时必须有永久反审映射';

CREATE FUNCTION fn_assert_purchase_receipt_quantity_successor(p_new jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE source jsonb; old_status smallint; new_status smallint; old_deleted boolean; new_deleted boolean; field text;
BEGIN
    SELECT to_jsonb(i),original.status,draft.status,original.is_deleted,draft.is_deleted
        INTO source,old_status,new_status,old_deleted,new_deleted
    FROM purchase_receipt_items i
    JOIN purchase_receipts original ON original.id=i.receipt_id
    JOIN purchase_receipts draft ON draft.id=(p_new->>'receipt_id')::uuid
    WHERE i.id=(p_new->>'quantity_successor_source_id')::uuid
        AND i.id<>(p_new->>'id')::uuid AND original.id<>draft.id AND NOT i.is_deleted
    FOR SHARE OF i,original,draft;
    IF NOT FOUND OR old_status IS DISTINCT FROM -1 OR new_status IS DISTINCT FROM 0
        OR old_deleted OR new_deleted THEN
        RAISE EXCEPTION 'quantity successor requires a reversed original line and a distinct live draft' USING ERRCODE='23514';
    END IF;
    FOREACH field IN ARRAY ARRAY['goods_id','color_id','order_item_id','unit_id','unit_rate','qty',
        'quantity_semantics','gift_qty','charged_base_qty','gift_base_qty','replacement_intent','gift_replacement_intent',
        'quantity_adoption_version','quantity_precision_policy','price','amount_original','amount_local'] LOOP
        IF p_new->field IS DISTINCT FROM source->field THEN
            RAISE EXCEPTION 'quantity successor must preserve original input and adoption field %',field USING ERRCODE='23514';
        END IF;
    END LOOP;
END $$;

DO $successor_quantity_adoption$
DECLARE definition text; needle text;
BEGIN
    SELECT pg_get_functiondef('fn_guard_document_quantity_adoption()'::regprocedure) INTO definition;
    needle:='IF TG_OP=''INSERT'' THEN';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V1072 quantity adoption insert anchor differs';
    END IF;
    definition:=replace(definition,needle,
        'IF TG_OP=''INSERT'' AND TG_TABLE_NAME=''purchase_receipt_items''
            AND to_jsonb(NEW)->>''quantity_successor_source_id'' IS NOT NULL THEN
            PERFORM fn_assert_purchase_receipt_quantity_successor(to_jsonb(NEW));
            RETURN NEW;
        END IF;
        '||needle);
    EXECUTE definition;
END $successor_quantity_adoption$;

CREATE FUNCTION fn_guard_purchase_receipt_quantity_successor_source()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.quantity_successor_source_id IS DISTINCT FROM OLD.quantity_successor_source_id THEN
        RAISE EXCEPTION 'saved quantity successor source is immutable' USING ERRCODE='55000';
    END IF;
    IF OLD.quantity_successor_source_id IS NOT NULL
        AND NEW.id IS DISTINCT FROM OLD.id THEN
        RAISE EXCEPTION 'saved quantity successor line identity is immutable' USING ERRCODE='55000';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_purchase_receipt_quantity_successor_source
    BEFORE UPDATE ON purchase_receipt_items FOR EACH ROW
    EXECUTE FUNCTION fn_guard_purchase_receipt_quantity_successor_source();
ALTER TABLE purchase_receipt_items ENABLE ALWAYS TRIGGER trg_guard_purchase_receipt_quantity_successor_source;

CREATE FUNCTION fn_require_purchase_receipt_quantity_successor_lineage()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.quantity_successor_source_id IS NOT NULL AND NOT EXISTS(
        SELECT 1 FROM purchase_receipt_items successor
        JOIN document_unapprovals relation ON relation.draft_id=successor.receipt_id
        JOIN purchase_receipt_items original ON original.id=NEW.quantity_successor_source_id
        JOIN purchase_receipts original_header ON original_header.id=original.receipt_id
        JOIN purchase_receipts draft_header ON draft_header.id=successor.receipt_id
        WHERE relation.family='purchaseReceipt' AND relation.original_id=original.receipt_id
            AND successor.id=NEW.id AND successor.receipt_id=NEW.receipt_id
            AND successor.quantity_successor_source_id=NEW.quantity_successor_source_id
            AND NOT successor.is_deleted AND NOT original.is_deleted
            AND original_header.status=-1 AND NOT original_header.is_deleted
            AND draft_header.status=0 AND NOT draft_header.is_deleted
            AND relation.line_id_map->>original.id::text=NEW.id::text) THEN
        RAISE EXCEPTION 'quantity successor requires its immutable unapproval line mapping' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_require_purchase_receipt_quantity_successor_lineage
    AFTER INSERT ON purchase_receipt_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_require_purchase_receipt_quantity_successor_lineage();
ALTER TABLE purchase_receipt_items ENABLE ALWAYS TRIGGER trg_require_purchase_receipt_quantity_successor_lineage;
