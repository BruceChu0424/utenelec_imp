-- Reference prices are adopted once when the business input is saved. Finance
-- review verifies that saved proof; it never selects another rounding policy.
-- Existing NULL proofs keep V760's exact historical ten-place verifier.
ALTER TABLE purchase_order_items ADD COLUMN reference_price_policy jsonb,
    ADD COLUMN reference_price_successor_source_id uuid REFERENCES purchase_order_items(id),
    ADD CONSTRAINT purchase_order_reference_price_source_unique UNIQUE(reference_price_successor_source_id);
ALTER TABLE subcontract_order_items ADD COLUMN reference_price_policy jsonb,
    ADD COLUMN reference_price_successor_source_id uuid REFERENCES subcontract_order_items(id),
    ADD CONSTRAINT subcontract_order_reference_price_source_unique UNIQUE(reference_price_successor_source_id);

CREATE FUNCTION fn_build_procurement_reference_price_policy(p_item jsonb,p_used jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE total numeric;quantity numeric;price numeric;expected numeric;exact boolean:=true;
    message text;choice jsonb;policy jsonb:='{"version":1,"choices":{}}';actor uuid;
BEGIN
    IF p_item->>'total_amount_input' IS NULL THEN RETURN NULL;END IF;
    total:=(p_item->>'total_amount_input')::numeric;quantity:=(p_item->>'qty')::numeric;price:=(p_item->>'price')::numeric;
    IF total<0 OR quantity<=0 OR price<0 OR NOT fn_financial_amount_is_exact(total)
        OR NOT fn_financial_amount_is_exact(quantity) OR NOT fn_financial_amount_is_exact(price)
        OR p_item->>'unit_id' IS NULL OR p_item->>'unit_rate' IS NULL
        OR (p_item->>'unit_rate')::numeric<=0 OR NOT fn_financial_amount_is_exact((p_item->>'unit_rate')::numeric) THEN
        RAISE EXCEPTION 'reference price adoption lacks its actual finite total, quantity, price or unit' USING ERRCODE='23514';
    END IF;
    BEGIN
        expected:=fn_business_exact_divide_with_policy(total,quantity,'money.reference-unit-price','本次参考单价',24,policy,false);
    EXCEPTION WHEN invalid_parameter_value THEN
        GET STACKED DIAGNOSTICS message=MESSAGE_TEXT;
        IF message NOT LIKE 'UTEN_PRECISION_REQUIRED:%' THEN RAISE;END IF;
        exact:=false;
    END;
    IF NOT exact THEN
        choice:=p_used->'choices'->'money.reference-unit-price';
        IF choice IS NULL OR choice IS DISTINCT FROM fn_business_precision_snapshot()->'choices'->'money.reference-unit-price' THEN
            RAISE EXCEPTION 'reference price adoption requires the actual current explicit choice' USING ERRCODE='23514';
        END IF;
        policy:=jsonb_build_object('version',1,'choices',jsonb_build_object('money.reference-unit-price',choice));
        expected:=fn_business_exact_divide_with_policy(total,quantity,'money.reference-unit-price','本次参考单价',24,policy,false);
    END IF;
    IF expected IS DISTINCT FROM price THEN
        RAISE EXCEPTION 'reference price differs from its actual saved total and adopted policy' USING ERRCODE='23514';
    END IF;
    actor:=NULLIF(current_setting('app.actor_id',true),'')::uuid;
    IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM users WHERE id=actor) THEN
        RAISE EXCEPTION 'reference price adoption requires its actual transaction actor' USING ERRCODE='23514';END IF;
    RETURN jsonb_build_object('version',1,'kind','PROCUREMENT_REFERENCE_PRICE','mode',CASE WHEN exact THEN 'EXACT' ELSE 'SELECTED' END,
        'totalInput',trim_scale(total)::text,'quantity',trim_scale(quantity)::text,'referencePrice',trim_scale(price)::text,
        'unitId',p_item->>'unit_id','unitRate',trim_scale((p_item->>'unit_rate')::numeric)::text,
        'precisionPolicy',policy,'sourceActionId',txid_current()::text,'actorId',actor);
END $$;

CREATE FUNCTION fn_procurement_reference_price_matches(p_item jsonb)
RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE proof jsonb:=p_item->'reference_price_policy';total numeric;quantity numeric;price numeric;
    expected numeric;exact boolean:=true;message text;policy jsonb:='{"version":1,"choices":{}}';
BEGIN
    IF p_item->>'total_amount_input' IS NULL THEN RETURN proof IS NULL OR proof='null'::jsonb;END IF;
    IF proof->>'kind'='PROCUREMENT_REFERENCE_PRICE_REVISION' THEN
        RETURN fn_procurement_reference_revision_matches(p_item);
    END IF;
    total:=(p_item->>'total_amount_input')::numeric;quantity:=(p_item->>'qty')::numeric;price:=(p_item->>'price')::numeric;
    IF total IS NULL OR quantity IS NULL OR price IS NULL OR total<0 OR quantity<=0 OR price<0
        OR NOT fn_financial_amount_is_exact(total) OR NOT fn_financial_amount_is_exact(quantity)
        OR NOT fn_financial_amount_is_exact(price) THEN RETURN false;END IF;
    IF proof IS NULL OR proof='null'::jsonb THEN
        RETURN price=fn_procurement_reference_price(total,quantity);
    END IF;
    IF jsonb_typeof(proof) IS DISTINCT FROM 'object' OR proof->>'version' IS DISTINCT FROM '1'
        OR proof->>'kind' IS DISTINCT FROM 'PROCUREMENT_REFERENCE_PRICE'
        OR proof-ARRAY['version','kind','mode','totalInput','quantity','referencePrice','unitId','unitRate','precisionPolicy','sourceActionId','actorId']<>'{}'::jsonb
        OR proof->>'totalInput' IS DISTINCT FROM trim_scale(total)::text
        OR proof->>'quantity' IS DISTINCT FROM trim_scale(quantity)::text
        OR proof->>'referencePrice' IS DISTINCT FROM trim_scale(price)::text
        OR proof->>'unitId' IS DISTINCT FROM p_item->>'unit_id'
        OR proof->>'unitRate' IS DISTINCT FROM trim_scale((p_item->>'unit_rate')::numeric)::text
        OR (proof->>'sourceActionId' ~ '^[0-9]+$') IS NOT TRUE
        OR (proof->>'actorId' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') IS NOT TRUE THEN RETURN false;END IF;
    BEGIN
        expected:=fn_business_exact_divide_with_policy(total,quantity,'money.reference-unit-price','原参考单价核对',24,policy,false);
    EXCEPTION WHEN invalid_parameter_value THEN
        GET STACKED DIAGNOSTICS message=MESSAGE_TEXT;
        IF message NOT LIKE 'UTEN_PRECISION_REQUIRED:%' THEN RAISE;END IF;
        exact:=false;
    END;
    IF exact THEN
        IF proof->>'mode' IS DISTINCT FROM 'EXACT' OR proof->'precisionPolicy' IS DISTINCT FROM policy THEN RETURN false;END IF;
    ELSE
        policy:=proof->'precisionPolicy';
        IF proof->>'mode' IS DISTINCT FROM 'SELECTED' OR jsonb_typeof(policy) IS DISTINCT FROM 'object'
            OR policy->>'version' IS DISTINCT FROM '1' OR policy-ARRAY['version','choices']<>'{}'::jsonb
            OR jsonb_typeof(policy->'choices') IS DISTINCT FROM 'object'
            OR (policy->'choices')-'money.reference-unit-price'<>'{}'::jsonb
            OR jsonb_typeof(policy->'choices'->'money.reference-unit-price') IS DISTINCT FROM 'object' THEN RETURN false;END IF;
        BEGIN
            expected:=fn_business_exact_divide_with_policy(total,quantity,'money.reference-unit-price','原参考单价核对',24,policy,false);
        EXCEPTION WHEN invalid_parameter_value OR numeric_value_out_of_range THEN RETURN false;
        END;
    END IF;
    RETURN expected IS NOT DISTINCT FROM price;
END $$;

-- Quantity revisions preserve the original reference-price adoption. The new
-- agreed total has its own actual ratio policy and immutable source revision;
-- it is never turned back into a different reference price.
CREATE OR REPLACE FUNCTION fn_procurement_revised_total_input(total numeric,old_qty numeric,new_qty numeric)
RETURNS numeric LANGUAGE plpgsql VOLATILE AS $$
DECLARE result numeric;
BEGIN
    IF old_qty<=0 OR new_qty<=0 THEN RAISE EXCEPTION 'Invalid total-price quantity revision' USING ERRCODE='23514';END IF;
    result:=fn_business_exact_divide(total*new_qty,old_qty,'money.revised-total','本次按原总额比例改量',24);
    IF NOT fn_financial_amount_is_exact(result) THEN RAISE EXCEPTION 'Revised agreed total exceeds exact amount range' USING ERRCODE='23514';END IF;
    RETURN result;
END $$;
ALTER FUNCTION fn_procurement_revised_original(jsonb,numeric) VOLATILE;

CREATE FUNCTION fn_procurement_reference_root_basis(p_item jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_item->'reference_price_policy'->>'kind'='PROCUREMENT_REFERENCE_PRICE_REVISION'
        THEN p_item->'reference_price_policy'->'basis'
        ELSE jsonb_build_object('qty',p_item->'qty','total_amount_input',p_item->'total_amount_input','price',p_item->'price',
            'unit_id',p_item->'unit_id','unit_rate',p_item->'unit_rate','reference_price_policy',p_item->'reference_price_policy') END
$$;

CREATE FUNCTION fn_build_procurement_reference_revision_policy(p_table text,p_old jsonb,p_new jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE revision procurement_order_source_revisions%ROWTYPE;expected numeric;exact boolean:=true;
    message text;policy jsonb:='{"version":1,"choices":{}}';choice jsonb;kind text;
BEGIN
    IF p_old->>'total_amount_input' IS NULL THEN RETURN NULL;END IF;
    kind:=CASE p_table WHEN 'purchase_order_items' THEN 'PURCHASE' WHEN 'subcontract_order_items' THEN 'SUBCONTRACT' END;
    SELECT * INTO revision FROM procurement_order_source_revisions r
    WHERE r.created_txid=txid_current() AND r.order_type=kind AND r.order_id=(p_old->>'order_id')::uuid
        AND r.order_item_id=(p_old->>'id')::uuid AND r.old_qty=(p_old->>'qty')::numeric AND r.new_qty=(p_new->>'qty')::numeric
        AND (r.before_item-ARRAY['updated_at','updated_by'])=(p_old-ARRAY['updated_at','updated_by']);
    IF NOT FOUND OR NOT fn_procurement_reference_price_matches(p_old)
        OR (p_new->'price',p_new->'unit_id',p_new->'unit_rate') IS DISTINCT FROM (p_old->'price',p_old->'unit_id',p_old->'unit_rate') THEN
        RAISE EXCEPTION 'reference price revision requires its immutable original adoption and actual source revision' USING ERRCODE='23514';END IF;
    BEGIN
        expected:=fn_business_exact_divide_with_policy((p_old->>'total_amount_input')::numeric*revision.new_qty,revision.old_qty,
            'money.revised-total','本次按原总额比例改量',24,policy,false);
    EXCEPTION WHEN invalid_parameter_value THEN
        GET STACKED DIAGNOSTICS message=MESSAGE_TEXT;
        IF message NOT LIKE 'UTEN_PRECISION_REQUIRED:%' THEN RAISE;END IF;
        exact:=false;
    END;
    IF NOT exact THEN
        choice:=fn_business_precision_snapshot()->'choices'->'money.revised-total';
        policy:=jsonb_build_object('version',1,'choices',jsonb_build_object('money.revised-total',choice));
        expected:=fn_business_exact_divide_with_policy((p_old->>'total_amount_input')::numeric*revision.new_qty,revision.old_qty,
            'money.revised-total','本次按原总额比例改量',24,policy,false);
    END IF;
    IF expected IS DISTINCT FROM (p_new->>'total_amount_input')::numeric THEN
        RAISE EXCEPTION 'revised agreed total differs from its actual original ratio and saved choice' USING ERRCODE='23514';END IF;
    RETURN jsonb_build_object('version',1,'kind','PROCUREMENT_REFERENCE_PRICE_REVISION',
        'totalInput',trim_scale(expected)::text,'quantity',trim_scale(revision.new_qty)::text,
        'referencePrice',trim_scale((p_old->>'price')::numeric)::text,'unitId',p_old->>'unit_id',
        'unitRate',trim_scale((p_old->>'unit_rate')::numeric)::text,'basis',fn_procurement_reference_root_basis(p_old),
        'revisionId',revision.id,'revisionMode',CASE WHEN exact THEN 'EXACT' ELSE 'SELECTED' END,'revisionPolicy',policy,
        'sourceActionId',revision.created_txid::text,'actorId',revision.actor_user_id);
END $$;

CREATE FUNCTION fn_procurement_reference_revision_matches(p_item jsonb) RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE proof jsonb:=p_item->'reference_price_policy';revision procurement_order_source_revisions%ROWTYPE;
    basis jsonb;expected numeric;exact boolean:=true;message text;policy jsonb:='{"version":1,"choices":{}}';
    inherited boolean:=false;prefix text;family text;
BEGIN
    IF jsonb_typeof(proof) IS DISTINCT FROM 'object' OR proof->>'version' IS DISTINCT FROM '1'
        OR proof->>'kind' IS DISTINCT FROM 'PROCUREMENT_REFERENCE_PRICE_REVISION'
        OR proof-ARRAY['version','kind','totalInput','quantity','referencePrice','unitId','unitRate','basis','revisionId','revisionMode','revisionPolicy','sourceActionId','actorId']<>'{}'::jsonb
        OR (proof->>'revisionId' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') IS NOT TRUE THEN RETURN false;END IF;
    SELECT * INTO revision FROM procurement_order_source_revisions WHERE id=(proof->>'revisionId')::uuid;
    IF NOT FOUND OR revision.new_qty IS DISTINCT FROM (p_item->>'qty')::numeric
        OR proof->>'sourceActionId' IS DISTINCT FROM revision.created_txid::text
        OR proof->>'actorId' IS DISTINCT FROM revision.actor_user_id::text THEN RETURN false;END IF;
    IF revision.order_id IS DISTINCT FROM (p_item->>'order_id')::uuid OR revision.order_item_id IS DISTINCT FROM (p_item->>'id')::uuid THEN
        IF p_item->>'reference_price_successor_source_id' IS NULL THEN RETURN false;END IF;
        prefix:=CASE revision.order_type WHEN 'PURCHASE' THEN 'purchase' ELSE 'subcontract' END;
        family:=CASE revision.order_type WHEN 'PURCHASE' THEN 'purchaseOrder' ELSE 'subcontractOrder' END;
        EXECUTE format('WITH RECURSIVE ancestors AS (
            SELECT i.id,i.order_id,i.reference_price_successor_source_id,ARRAY[i.id] path FROM %I i
                WHERE i.id=$1 AND i.reference_price_policy=$2 AND NOT i.is_deleted
            UNION ALL SELECT parent.id,parent.order_id,parent.reference_price_successor_source_id,child.path||parent.id
                FROM ancestors child JOIN %I parent ON parent.id=child.reference_price_successor_source_id
                JOIN document_unapprovals relation ON relation.family=$3 AND relation.original_id=parent.order_id
                    AND relation.draft_id=child.order_id AND relation.line_id_map->>parent.id::text=child.id::text
                WHERE NOT parent.id=ANY(child.path) AND parent.reference_price_policy=$2 AND NOT parent.is_deleted)
            SELECT EXISTS(SELECT 1 FROM ancestors WHERE id=$4 AND order_id=$5)',prefix||'_order_items',prefix||'_order_items')
            INTO inherited USING (p_item->>'reference_price_successor_source_id')::uuid,proof,family,revision.order_item_id,revision.order_id;
        IF NOT inherited THEN RETURN false;END IF;
    END IF;
    basis:=fn_procurement_reference_root_basis(revision.before_item);
    IF proof->'basis' IS DISTINCT FROM basis OR basis->'reference_price_policy'->>'kind'='PROCUREMENT_REFERENCE_PRICE_REVISION'
        OR NOT fn_procurement_reference_price_matches(basis)
        OR (p_item->'price',p_item->'unit_id',p_item->'unit_rate') IS DISTINCT FROM
            (revision.before_item->'price',revision.before_item->'unit_id',revision.before_item->'unit_rate')
        OR proof->>'referencePrice' IS DISTINCT FROM trim_scale((p_item->>'price')::numeric)::text
        OR proof->>'unitId' IS DISTINCT FROM p_item->>'unit_id'
        OR proof->>'unitRate' IS DISTINCT FROM trim_scale((p_item->>'unit_rate')::numeric)::text
        OR proof->>'quantity' IS DISTINCT FROM trim_scale(revision.new_qty)::text
        OR proof->>'totalInput' IS DISTINCT FROM trim_scale((p_item->>'total_amount_input')::numeric)::text THEN RETURN false;END IF;
    BEGIN
        expected:=fn_business_exact_divide_with_policy((revision.before_item->>'total_amount_input')::numeric*revision.new_qty,revision.old_qty,
            'money.revised-total','原改量金额核对',24,policy,false);
    EXCEPTION WHEN invalid_parameter_value THEN
        GET STACKED DIAGNOSTICS message=MESSAGE_TEXT;
        IF message NOT LIKE 'UTEN_PRECISION_REQUIRED:%' THEN RAISE;END IF;
        exact:=false;
    END;
    IF exact THEN
        IF proof->>'revisionMode' IS DISTINCT FROM 'EXACT' OR proof->'revisionPolicy' IS DISTINCT FROM policy THEN RETURN false;END IF;
    ELSE
        policy:=proof->'revisionPolicy';
        IF proof->>'revisionMode' IS DISTINCT FROM 'SELECTED' OR jsonb_typeof(policy) IS DISTINCT FROM 'object'
            OR policy->>'version' IS DISTINCT FROM '1' OR policy-ARRAY['version','choices']<>'{}'::jsonb
            OR jsonb_typeof(policy->'choices') IS DISTINCT FROM 'object' OR (policy->'choices')-'money.revised-total'<>'{}'::jsonb THEN RETURN false;END IF;
        BEGIN
            expected:=fn_business_exact_divide_with_policy((revision.before_item->>'total_amount_input')::numeric*revision.new_qty,revision.old_qty,
                'money.revised-total','原改量金额核对',24,policy,false);
        EXCEPTION WHEN invalid_parameter_value OR numeric_value_out_of_range THEN RETURN false;END;
    END IF;
    RETURN expected IS NOT DISTINCT FROM (p_item->>'total_amount_input')::numeric;
END $$;

CREATE FUNCTION fn_guard_procurement_reference_price_policy() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE old_item jsonb;new_item jsonb:=to_jsonb(NEW);expected jsonb;source jsonb;
    prefix text;kind text;family text;old_status smallint;new_status smallint;old_deleted boolean;new_deleted boolean;
    changed boolean;field text;proven_revision boolean:=false;
BEGIN
    prefix:=CASE TG_TABLE_NAME WHEN 'purchase_order_items' THEN 'purchase' WHEN 'subcontract_order_items' THEN 'subcontract' END;
    kind:=upper(prefix);family:=CASE prefix WHEN 'purchase' THEN 'purchaseOrder' ELSE 'subcontractOrder' END;
    IF TG_OP='UPDATE' THEN
        old_item:=to_jsonb(OLD);
        IF NEW.reference_price_successor_source_id IS DISTINCT FROM OLD.reference_price_successor_source_id
            OR OLD.reference_price_successor_source_id IS NOT NULL AND NEW.id IS DISTINCT FROM OLD.id THEN
            RAISE EXCEPTION 'saved reference price successor identity is immutable' USING ERRCODE='55000';
        END IF;
        changed:=(new_item->'qty',new_item->'total_amount_input',new_item->'price',new_item->'unit_id',new_item->'unit_rate')
            IS DISTINCT FROM (old_item->'qty',old_item->'total_amount_input',old_item->'price',old_item->'unit_id',old_item->'unit_rate');
        IF NOT changed AND NEW.reference_price_policy IS NOT DISTINCT FROM OLD.reference_price_policy THEN RETURN NEW;END IF;
        proven_revision:=NEW.qty IS DISTINCT FROM OLD.qty AND fn_is_proven_procurement_qty_revision(TG_TABLE_NAME,old_item,new_item);
        EXECUTE format('SELECT status,is_deleted FROM %I WHERE id=$1',prefix||'_orders') INTO new_status,new_deleted USING NEW.order_id;
        IF new_status IS NULL OR new_deleted OR NOT (new_status=0 AND NOT procurement_order_commercial_locked(kind,NEW.order_id)
            OR proven_revision) THEN
            RAISE EXCEPTION 'saved reference price policy is frozen outside a genuine editable intent or proven quantity revision' USING ERRCODE='23514';
        END IF;
        IF proven_revision THEN
            NEW.reference_price_policy:=fn_build_procurement_reference_revision_policy(TG_TABLE_NAME,old_item,new_item);
            RETURN NEW;
        END IF;
    ELSIF NEW.reference_price_successor_source_id IS NOT NULL THEN
        EXECUTE format('SELECT to_jsonb(i),original.status,draft.status,original.is_deleted,draft.is_deleted
            FROM %I i JOIN %I original ON original.id=i.order_id JOIN %I draft ON draft.id=$1
            WHERE i.id=$2 AND i.id<>$3 AND original.id<>draft.id AND NOT i.is_deleted FOR SHARE OF i,original,draft',
            TG_TABLE_NAME,prefix||'_orders',prefix||'_orders')
            INTO source,old_status,new_status,old_deleted,new_deleted
            USING NEW.order_id,NEW.reference_price_successor_source_id,NEW.id;
        IF source IS NULL OR old_status IS DISTINCT FROM -1 OR new_status IS DISTINCT FROM 0 OR old_deleted OR new_deleted THEN
            RAISE EXCEPTION 'reference price successor requires a reversed original and distinct live draft' USING ERRCODE='23514';
        END IF;
        FOREACH field IN ARRAY ARRAY['goods_id','color_id','unit_id','unit_rate','qty','price','total_amount_input',
            'amount_original','amount_local','extra_columns','quantity_semantics','gift_qty','reference_price_policy'] LOOP
            IF new_item->field IS DISTINCT FROM source->field THEN
                RAISE EXCEPTION 'reference price successor must preserve original field %',field USING ERRCODE='23514';
            END IF;
        END LOOP;
        IF NOT fn_procurement_reference_price_matches(new_item) THEN
            RAISE EXCEPTION 'reference price successor source proof is inconsistent' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    expected:=fn_build_procurement_reference_price_policy(new_item,fn_business_precision_snapshot());
    IF TG_OP='INSERT' AND NEW.reference_price_policy IS NOT NULL AND NEW.reference_price_policy IS DISTINCT FROM expected
        OR TG_OP='UPDATE' AND NEW.reference_price_policy IS DISTINCT FROM OLD.reference_price_policy
            AND NEW.reference_price_policy IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'reference price policy must be the actual current input adoption' USING ERRCODE='23514';
    END IF;
    NEW.reference_price_policy:=expected;
    RETURN NEW;
END $$;

CREATE FUNCTION fn_require_procurement_reference_price_successor_lineage() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE prefix text;family text;valid boolean;
BEGIN
    IF NEW.reference_price_successor_source_id IS NULL THEN RETURN NULL;END IF;
    prefix:=CASE TG_TABLE_NAME WHEN 'purchase_order_items' THEN 'purchase' ELSE 'subcontract' END;
    family:=CASE prefix WHEN 'purchase' THEN 'purchaseOrder' ELSE 'subcontractOrder' END;
    EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I successor JOIN %I original ON original.id=$1
        JOIN %I old_header ON old_header.id=original.order_id JOIN %I draft_header ON draft_header.id=successor.order_id
        JOIN document_unapprovals relation ON relation.original_id=original.order_id AND relation.draft_id=successor.order_id
        WHERE successor.id=$2 AND successor.order_id=$3 AND successor.reference_price_successor_source_id=$1
            AND NOT successor.is_deleted AND NOT original.is_deleted AND old_header.status=-1 AND NOT old_header.is_deleted
            AND draft_header.status=0 AND NOT draft_header.is_deleted AND relation.family=$4
            AND relation.line_id_map->>original.id::text=successor.id::text)',TG_TABLE_NAME,TG_TABLE_NAME,prefix||'_orders',prefix||'_orders')
        INTO valid USING NEW.reference_price_successor_source_id,NEW.id,NEW.order_id,family;
    IF NOT valid THEN RAISE EXCEPTION 'reference price successor requires its immutable unapproval line mapping' USING ERRCODE='23514';END IF;
    RETURN NULL;
END $$;

DO $reference_price_triggers$
DECLARE target text;
BEGIN
    FOREACH target IN ARRAY ARRAY['purchase_order_items','subcontract_order_items'] LOOP
        EXECUTE format('CREATE TRIGGER trg_00_reference_price_policy BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_reference_price_policy()',target);
        EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER trg_00_reference_price_policy',target);
        EXECUTE format('CREATE CONSTRAINT TRIGGER trg_require_reference_price_successor_lineage AFTER INSERT ON %I DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_require_procurement_reference_price_successor_lineage()',target);
        EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER trg_require_reference_price_successor_lineage',target);
    END LOOP;
END $reference_price_triggers$;

CREATE FUNCTION fn_adopt_procurement_reference_price_policy(p_kind text,p_order uuid,p_used jsonb)
RETURNS integer LANGUAGE plpgsql VOLATILE AS $$
DECLARE prefix text;item jsonb;proof jsonb;count integer:=0;status smallint;deleted boolean;
BEGIN
    prefix:=CASE p_kind WHEN 'PURCHASE' THEN 'purchase' WHEN 'SUBCONTRACT' THEN 'subcontract' END;
    IF prefix IS NULL OR p_used->>'version' IS DISTINCT FROM '1' OR jsonb_typeof(p_used->'choices') IS DISTINCT FROM 'object'
        OR EXISTS(SELECT 1 FROM jsonb_each(p_used->'choices') choice WHERE choice.value IS DISTINCT FROM fn_business_precision_snapshot()->'choices'->choice.key) THEN
        RAISE EXCEPTION 'saved reference price adoption must use the actual business calculation choices' USING ERRCODE='23514';
    END IF;
    EXECUTE format('SELECT status,is_deleted FROM %I WHERE id=$1 FOR UPDATE',prefix||'_orders') INTO status,deleted USING p_order;
    IF status IS NULL OR deleted THEN RAISE EXCEPTION 'reference price owner is missing' USING ERRCODE='23514';END IF;
    FOR item IN EXECUTE format('SELECT to_jsonb(i) FROM %I i WHERE order_id=$1 AND NOT is_deleted ORDER BY id FOR UPDATE',prefix||'_order_items') USING p_order LOOP
        IF item->>'total_amount_input' IS NULL THEN CONTINUE;END IF;
        IF item->'reference_price_policy' IS NOT NULL AND item->'reference_price_policy'<>'null'::jsonb THEN
            IF NOT fn_procurement_reference_price_matches(item) THEN RAISE EXCEPTION 'saved reference price proof is inconsistent' USING ERRCODE='23514';END IF;
            IF item->'reference_price_policy'->>'sourceActionId'=txid_current()::text
                AND item->'reference_price_policy'->>'mode'='SELECTED'
                AND item->'reference_price_policy'->'precisionPolicy'->'choices'->'money.reference-unit-price'
                    IS DISTINCT FROM p_used->'choices'->'money.reference-unit-price' THEN
                RAISE EXCEPTION 'reference price proof was not used by the actual saved calculation' USING ERRCODE='23514';
            END IF;
            IF item->'reference_price_policy'->>'sourceActionId'=txid_current()::text
                AND item->'reference_price_policy'->>'revisionMode'='SELECTED'
                AND item->'reference_price_policy'->'revisionPolicy'->'choices'->'money.revised-total'
                    IS DISTINCT FROM p_used->'choices'->'money.revised-total' THEN
                RAISE EXCEPTION 'revised total proof was not used by the actual saved calculation' USING ERRCODE='23514';
            END IF;
            CONTINUE;
        END IF;
        -- Do not retag an unchanged, verifiable historical ten-place fact. An
        -- unproved modern draft may adopt only during an actual current save.
        IF fn_procurement_reference_price_matches(item) THEN CONTINUE;END IF;
        IF status<>0 OR procurement_order_commercial_locked(p_kind,p_order) THEN
            RAISE EXCEPTION 'unproved saved reference price requires its original editable save' USING ERRCODE='23514';
        END IF;
        proof:=fn_build_procurement_reference_price_policy(item,p_used);
        EXECUTE format('UPDATE %I SET reference_price_policy=$1 WHERE id=$2',prefix||'_order_items') USING proof,(item->>'id')::uuid;
        count:=count+1;
    END LOOP;
    RETURN count;
END $$;

DO $saved_reference_price_verification$
DECLARE definition text;needle text;
BEGIN
    SELECT pg_get_functiondef('fn_guard_procurement_finance_commercial_snapshot()'::regprocedure) INTO definition;
    needle:='(total_amount_input IS NOT NULL AND price<>fn_procurement_reference_price(total_amount_input,qty))';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>2 THEN
        RAISE EXCEPTION 'V1060 reference price snapshot verification anchor differs';END IF;
    definition:=replace(definition,'FROM purchase_order_items','FROM purchase_order_items reference_item');
    definition:=replace(definition,'FROM subcontract_order_items','FROM subcontract_order_items reference_item');
    EXECUTE replace(definition,needle,'(total_amount_input IS NOT NULL AND NOT fn_procurement_reference_price_matches(to_jsonb(reference_item)))');

    SELECT pg_get_functiondef('fn_is_proven_procurement_qty_revision(text,jsonb,jsonb)'::regprocedure) INTO definition;
    needle:='''quantity_precision_policy'',''quantity_adoption_version'',''updated_at'',''updated_by''';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>2 THEN
        RAISE EXCEPTION 'V1060 proven quantity revision adoption whitelist anchor differs';END IF;
    EXECUTE replace(definition,needle,'''quantity_precision_policy'',''quantity_adoption_version'',''reference_price_policy'',''updated_at'',''updated_by''');
END $saved_reference_price_verification$;
