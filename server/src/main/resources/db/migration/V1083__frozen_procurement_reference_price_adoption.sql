-- Reference prices are adopted once when the business input is saved. Finance
-- review verifies that saved proof; it never selects another rounding policy.
-- Existing NULL proofs keep V760's exact historical ten-place verifier.
-- Main V1062 owns the canonical policy column. Its existing NULL and plain
-- {version,choices} rows remain unchanged; genuine future intents use a tagged
-- saved-input proof in that same column. There is no second writable policy.
-- Successor identity and transaction ownership remain Main V1067's single
-- unapproval_source_item_id/document_unapprovals authority.
CREATE FUNCTION fn_procurement_tagged_reference_price_shape_valid(proof jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE fields text[];
BEGIN
    IF jsonb_typeof(proof) IS DISTINCT FROM 'object' OR proof->>'version' IS DISTINCT FROM '1' THEN RETURN false;END IF;
    fields:=CASE proof->>'kind'
        WHEN 'PROCUREMENT_REFERENCE_PRICE' THEN ARRAY['version','kind','mode','totalInput','quantity','referencePrice','unitId','unitRate','precisionPolicy','sourceActionId','actorId']
        WHEN 'PROCUREMENT_REFERENCE_PRICE_REVISION' THEN ARRAY['version','kind','totalInput','quantity','referencePrice','unitId','unitRate','basis','revisionId','revisionMode','revisionPolicy','sourceActionId','actorId'] END;
    RETURN fields IS NOT NULL AND proof ?& fields AND proof-fields='{}'::jsonb
        AND (proof->>'sourceActionId' ~ '^[0-9]+$') IS TRUE
        AND (proof->>'actorId' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') IS TRUE;
END $$;

ALTER TABLE purchase_order_items DROP CONSTRAINT purchase_order_reference_price_policy;
ALTER TABLE purchase_order_items ADD CONSTRAINT purchase_order_reference_price_policy CHECK(reference_price_precision_policy IS NULL
    OR (total_amount_input IS NOT NULL AND (fn_procurement_reference_price_policy_valid(reference_price_precision_policy)
        OR fn_procurement_tagged_reference_price_shape_valid(reference_price_precision_policy))));
ALTER TABLE subcontract_order_items DROP CONSTRAINT subcontract_order_reference_price_policy;
ALTER TABLE subcontract_order_items ADD CONSTRAINT subcontract_order_reference_price_policy CHECK(reference_price_precision_policy IS NULL
    OR (total_amount_input IS NOT NULL AND (fn_procurement_reference_price_policy_valid(reference_price_precision_policy)
        OR fn_procurement_tagged_reference_price_shape_valid(reference_price_precision_policy))));

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
DECLARE proof jsonb:=p_item->'reference_price_precision_policy';total numeric;quantity numeric;price numeric;
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
    -- A real pre-integration Main map is already a saved decision. Validate it
    -- through Main's pure policy verifier, never today's session or a fabricated
    -- actor/action envelope. Legacy NULL remains the separate V760 contract.
    IF NOT (proof ? 'kind') THEN
        IF NOT fn_procurement_reference_price_policy_valid(proof) THEN RETURN false;END IF;
        BEGIN
            RETURN price IS NOT DISTINCT FROM fn_procurement_reference_price_proof(total,quantity,proof);
        EXCEPTION WHEN invalid_parameter_value OR numeric_value_out_of_range OR check_violation THEN RETURN false;
        END;
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
CREATE FUNCTION fn_procurement_legacy_revised_total_input(total numeric,old_qty numeric,new_qty numeric)
RETURNS numeric LANGUAGE plpgsql VOLATILE STRICT AS $$
DECLARE result numeric;
BEGIN
    IF old_qty<=0 OR new_qty<=0 THEN RAISE EXCEPTION 'Invalid total-price quantity revision' USING ERRCODE='23514';END IF;
    -- V760's historical ratio contract accepted an exact finite amount, not a
    -- new choice supplied by a later reviewer. Keep that NULL-policy verifier.
    result:=fn_business_exact_divide_with_policy(total*new_qty,old_qty,'money.revised-total','历史总额改量核对',24,
        '{"version":1,"choices":{}}'::jsonb,false);
    IF NOT fn_financial_amount_is_exact(result) THEN RAISE EXCEPTION 'Revised agreed total exceeds exact amount range' USING ERRCODE='23514';END IF;
    RETURN result;
END $$;

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

-- Header-first and item-first flushes use the same revised-total calculation.
-- Main's old map remains supported; tagged revisions expose only their actual
-- revised-total policy rather than re-adopting a reference price.
CREATE OR REPLACE FUNCTION fn_procurement_revised_total_input_proof(total numeric,old_qty numeric,new_qty numeric,policy jsonb)
RETURNS numeric LANGUAGE plpgsql VOLATILE AS $$
DECLARE result numeric;actual_policy jsonb:=policy;
BEGIN
    IF total IS NULL THEN RETURN NULL;END IF;
    IF policy IS NULL OR policy='null'::jsonb THEN RETURN fn_procurement_legacy_revised_total_input(total,old_qty,new_qty);END IF;
    IF policy->>'kind'='PROCUREMENT_REFERENCE_PRICE_REVISION' THEN actual_policy:=policy->'revisionPolicy';END IF;
    IF NOT fn_procurement_reference_price_policy_valid(actual_policy) OR old_qty IS NULL OR old_qty<=0 OR new_qty IS NULL OR new_qty<=0 THEN
        RAISE EXCEPTION 'invalid frozen total-price revision proof' USING ERRCODE='23514';END IF;
    result:=fn_business_exact_divide_with_policy(total*new_qty,old_qty,'money.revised-total','本次按原总额比例改量',24,actual_policy,false);
    IF result<0 OR NOT fn_financial_amount_is_exact(result) THEN RAISE EXCEPTION 'revised total exceeds its exact native capacity' USING ERRCODE='23514';END IF;
    RETURN result;
END $$;

CREATE FUNCTION fn_procurement_reference_root_basis(p_item jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_item->'reference_price_precision_policy'->>'kind'='PROCUREMENT_REFERENCE_PRICE_REVISION'
        THEN p_item->'reference_price_precision_policy'->'basis'
        ELSE jsonb_build_object('qty',p_item->'qty','total_amount_input',p_item->'total_amount_input','price',p_item->'price',
            'unit_id',p_item->'unit_id','unit_rate',p_item->'unit_rate','reference_price_precision_policy',p_item->'reference_price_precision_policy') END
$$;

-- Main V1065's actual source-revision authority is checked before arithmetic.
-- This helper intentionally does not depend on the richer proof being built.
CREATE FUNCTION fn_procurement_reference_revision_source(p_table text,p_old jsonb,p_new jsonb)
RETURNS uuid LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN count(*)=1 THEN min(r.id::text)::uuid END
    FROM procurement_order_source_revisions r
    WHERE r.created_txid=txid_current()
        AND r.order_type=CASE p_table WHEN 'purchase_order_items' THEN 'PURCHASE' WHEN 'subcontract_order_items' THEN 'SUBCONTRACT' END
        AND r.order_id=(p_old->>'order_id')::uuid AND r.order_item_id=(p_old->>'id')::uuid
        AND r.old_qty=(p_old->>'qty')::numeric AND r.new_qty=(p_new->>'qty')::numeric
        AND r.before_item=p_old
        AND (NOT EXISTS(SELECT 1 FROM procurement_order_approval_cases pending
                WHERE pending.order_type=r.order_type AND pending.order_id=r.order_id AND pending.status='PENDING')
            OR EXISTS(SELECT 1 FROM procurement_order_approval_cases pending
                WHERE pending.id=r.pending_case_id AND r.order_type='PURCHASE'
                    AND pending.order_type='PURCHASE' AND pending.order_id=r.order_id
                    AND pending.status='PENDING' AND pending.request_type='ORDER' AND pending.version=r.pending_case_version))
$$;

CREATE FUNCTION fn_build_procurement_reference_revision_policy(p_table text,p_old jsonb,p_new jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE revision procurement_order_source_revisions%ROWTYPE;expected numeric;exact boolean:=true;
    message text;policy jsonb:='{"version":1,"choices":{}}';choice jsonb;kind text;
BEGIN
    IF p_old->>'total_amount_input' IS NULL THEN RETURN NULL;END IF;
    kind:=CASE p_table WHEN 'purchase_order_items' THEN 'PURCHASE' WHEN 'subcontract_order_items' THEN 'SUBCONTRACT' END;
    SELECT * INTO revision FROM procurement_order_source_revisions r
    WHERE r.id=fn_procurement_reference_revision_source(p_table,p_old,p_new);
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
DECLARE proof jsonb:=p_item->'reference_price_precision_policy';revision procurement_order_source_revisions%ROWTYPE;
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
        IF p_item->>'unapproval_source_item_id' IS NULL THEN RETURN false;END IF;
        prefix:=CASE revision.order_type WHEN 'PURCHASE' THEN 'purchase' ELSE 'subcontract' END;
        family:=CASE revision.order_type WHEN 'PURCHASE' THEN 'purchaseOrder' ELSE 'subcontractOrder' END;
        EXECUTE format('WITH RECURSIVE ancestors AS (
            SELECT i.id,i.order_id,i.unapproval_source_item_id,ARRAY[i.id] path FROM %I i
                JOIN document_unapprovals relation ON relation.family=$3 AND relation.original_id=i.order_id
                    AND relation.draft_id=$6 AND relation.line_id_map->>i.id::text=$7 AND relation.created_txid IS NOT NULL
                WHERE i.id=$1 AND i.reference_price_precision_policy=$2 AND NOT i.is_deleted
            UNION ALL SELECT parent.id,parent.order_id,parent.unapproval_source_item_id,child.path||parent.id
                FROM ancestors child JOIN %I parent ON parent.id=child.unapproval_source_item_id
                JOIN document_unapprovals relation ON relation.family=$3 AND relation.original_id=parent.order_id
                    AND relation.draft_id=child.order_id AND relation.line_id_map->>parent.id::text=child.id::text
                WHERE NOT parent.id=ANY(child.path) AND parent.reference_price_precision_policy=$2 AND NOT parent.is_deleted)
            SELECT EXISTS(SELECT 1 FROM ancestors WHERE id=$4 AND order_id=$5)',prefix||'_order_items',prefix||'_order_items')
            INTO inherited USING (p_item->>'unapproval_source_item_id')::uuid,proof,family,revision.order_item_id,revision.order_id,(p_item->>'order_id')::uuid,p_item->>'id';
        IF NOT inherited THEN RETURN false;END IF;
    END IF;
    basis:=fn_procurement_reference_root_basis(revision.before_item);
    IF proof->'basis' IS DISTINCT FROM basis OR basis->'reference_price_precision_policy'->>'kind'='PROCUREMENT_REFERENCE_PRICE_REVISION'
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

-- Extend the original Main frozen-fact owner to understand the same tagged
-- proof as finance review. Keep its original quantity/physical evidence path.
DO $unapproval_saved_reference_dispatch$
DECLARE definition text; anchor text;
BEGIN
 definition:=pg_get_functiondef('fn_unapproval_frozen_fields(text,jsonb)'::regprocedure);
 anchor:=$old$IF p_source->>'total_amount_input' IS NOT NULL AND (p_source->>'price')::numeric IS DISTINCT FROM
    fn_procurement_reference_price_proof((p_source->>'total_amount_input')::numeric,(p_source->>'qty')::numeric,p_source->'reference_price_precision_policy') THEN$old$;
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'Review Main frozen reference proof before tagged dispatch'; END IF;
 EXECUTE replace(definition,anchor,'IF NOT fn_procurement_reference_price_matches(p_source) THEN');
END $unapproval_saved_reference_dispatch$;

CREATE OR REPLACE FUNCTION fn_guard_procurement_reference_price_policy() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE old_item jsonb;new_item jsonb:=to_jsonb(NEW);expected jsonb;source jsonb;
    prefix text;kind text;family text;old_status smallint;new_status smallint;old_deleted boolean;new_deleted boolean;
    changed boolean;field text;proven_revision boolean:=false;
BEGIN
    -- Main's actor/same-transaction/source-map proof owns every inherited row.
    -- Validate the frozen original; no current reviewer choice is re-adopted.
    IF TG_OP='INSERT' AND NEW.unapproval_source_item_id IS NOT NULL THEN
        source:=fn_unapproval_source_item(TG_TABLE_NAME,new_item);
        IF NOT fn_procurement_reference_price_matches(source) THEN
            RAISE EXCEPTION 'reference price successor source proof is inconsistent' USING ERRCODE='23514';
        END IF;
        RETURN jsonb_populate_record(NEW,fn_unapproval_frozen_fields(TG_TABLE_NAME,source));
    END IF;
    prefix:=CASE TG_TABLE_NAME WHEN 'purchase_order_items' THEN 'purchase' WHEN 'subcontract_order_items' THEN 'subcontract' END;
    kind:=upper(prefix);family:=CASE prefix WHEN 'purchase' THEN 'purchaseOrder' ELSE 'subcontractOrder' END;
    IF TG_OP='UPDATE' THEN
        old_item:=to_jsonb(OLD);
        -- Preserve Main's importer update contract: an existing saved policy
        -- cannot be replaced by switching replication role.
        IF current_setting('session_replication_role')='replica' THEN
            IF NEW.reference_price_precision_policy IS DISTINCT FROM OLD.reference_price_precision_policy THEN
                RAISE EXCEPTION 'saved reference price proof cannot be independently replaced' USING ERRCODE='55000';END IF;
            RETURN NEW;
        END IF;
        changed:=(new_item->'qty',new_item->'total_amount_input',new_item->'price',new_item->'unit_id',new_item->'unit_rate')
            IS DISTINCT FROM (old_item->'qty',old_item->'total_amount_input',old_item->'price',old_item->'unit_id',old_item->'unit_rate');
        IF NOT changed AND NEW.reference_price_precision_policy IS NOT DISTINCT FROM OLD.reference_price_precision_policy THEN RETURN NEW;END IF;
        IF NOT changed AND fn_procurement_reference_price_matches(old_item) THEN
            RAISE EXCEPTION 'saved reference price proof cannot be independently replaced' USING ERRCODE='55000';END IF;
        proven_revision:=NEW.qty IS DISTINCT FROM OLD.qty AND fn_procurement_reference_revision_source(TG_TABLE_NAME,old_item,new_item) IS NOT NULL;
        EXECUTE format('SELECT status,is_deleted FROM %I WHERE id=$1 FOR SHARE',prefix||'_orders') INTO new_status,new_deleted USING NEW.order_id;
        IF new_status IS NULL OR new_deleted OR NOT (new_status=0 AND NOT procurement_order_commercial_locked(kind,NEW.order_id)
            OR proven_revision) THEN
            RAISE EXCEPTION 'frozen reference price operands are immutable without their actual source revision' USING ERRCODE='55000';
        END IF;
        IF proven_revision THEN
            NEW.reference_price_precision_policy:=fn_build_procurement_reference_revision_policy(TG_TABLE_NAME,old_item,new_item);
            IF NOT fn_is_proven_procurement_qty_revision(TG_TABLE_NAME,old_item,to_jsonb(NEW)) THEN
                RAISE EXCEPTION 'reference price revision must retain its complete source and commercial proof' USING ERRCODE='23514';END IF;
            RETURN NEW;
        END IF;
    ELSE
        EXECUTE format('SELECT status,is_deleted FROM %I WHERE id=$1 FOR SHARE',prefix||'_orders') INTO new_status,new_deleted USING NEW.order_id;
        IF new_status IS NULL OR new_deleted THEN RAISE EXCEPTION 'missing reference price document' USING ERRCODE='23514';END IF;
        IF EXISTS(SELECT 1 FROM procurement_order_approval_cases pending WHERE pending.order_type=kind
            AND pending.order_id=NEW.order_id AND pending.status='PENDING') THEN
            RAISE EXCEPTION 'pending finance reference price proof is immutable' USING ERRCODE='55000';END IF;
    END IF;
    -- Genuine imported historical rows keep Main's existing ten-place NULL
    -- proof. Ordinary native INSERTs cannot acquire that importer identity.
    IF TG_OP='INSERT' AND NEW.legacy_id IS NOT NULL AND NEW.reference_price_precision_policy IS NULL THEN
        IF NEW.total_amount_input IS NOT NULL AND NEW.price IS DISTINCT FROM fn_procurement_reference_price(NEW.total_amount_input,NEW.qty) THEN
            RAISE EXCEPTION 'legacy reference price differs from its historical proof' USING ERRCODE='23514';END IF;
        RETURN NEW;
    END IF;
    expected:=fn_build_procurement_reference_price_policy(new_item,fn_business_precision_snapshot());
    IF TG_OP='INSERT' AND NEW.reference_price_precision_policy IS NOT NULL AND NEW.reference_price_precision_policy IS DISTINCT FROM expected
        OR TG_OP='UPDATE' AND NEW.reference_price_precision_policy IS DISTINCT FROM OLD.reference_price_precision_policy
            AND NEW.reference_price_precision_policy IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'reference price policy must be the actual current input adoption' USING ERRCODE='23514';
    END IF;
    NEW.reference_price_precision_policy:=expected;
    RETURN NEW;
END $$;

DO $reference_price_triggers$
DECLARE target text;operands text[];old_values text;new_values text;
BEGIN
    FOREACH target IN ARRAY ARRAY['purchase_order_items','subcontract_order_items'] LOOP
        -- Replace, rather than stack beside, Main's existing policy writer.
        EXECUTE format('DROP TRIGGER %I ON %I',CASE target WHEN 'purchase_order_items' THEN 'trg_00b_purchase_reference_price_insert' ELSE 'trg_00b_subcontract_reference_price_insert' END,target);
        EXECUTE format('DROP TRIGGER %I ON %I',CASE target WHEN 'purchase_order_items' THEN 'trg_00b_purchase_reference_price_update' ELSE 'trg_00b_subcontract_reference_price_update' END,target);
        EXECUTE format('CREATE TRIGGER trg_00_reference_price_policy_insert BEFORE INSERT ON %I FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_reference_price_policy()',target);
        operands:=ARRAY['qty','total_amount_input','price','unit_id','unit_rate','amount_original','amount_local','reference_price_precision_policy'];
        IF target='purchase_order_items' THEN
            operands:=operands||ARRAY['quantity_semantics','gift_qty','charged_base_qty','gift_base_qty','quantity_adoption_version','quantity_precision_policy'];
        END IF;
        SELECT string_agg(format('OLD.%I',field),',' ORDER BY position),string_agg(format('NEW.%I',field),',' ORDER BY position)
            INTO old_values,new_values FROM unnest(operands) WITH ORDINALITY AS fields(field,position);
        EXECUTE format('CREATE TRIGGER trg_00_reference_price_policy_update BEFORE UPDATE ON %I FOR EACH ROW
            WHEN ((%s) IS DISTINCT FROM (%s)) EXECUTE FUNCTION fn_guard_procurement_reference_price_policy()',target,old_values,new_values);
        -- Main's INSERT activation/import semantics are retained; UPDATE stays ALWAYS.
        EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER trg_00_reference_price_policy_update',target);
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
        IF item->'reference_price_precision_policy' IS NOT NULL AND item->'reference_price_precision_policy'<>'null'::jsonb THEN
            IF NOT fn_procurement_reference_price_matches(item) THEN RAISE EXCEPTION 'saved reference price proof is inconsistent' USING ERRCODE='23514';END IF;
            IF item->'reference_price_precision_policy'->>'sourceActionId'=txid_current()::text
                AND item->'reference_price_precision_policy'->>'mode'='SELECTED'
                AND item->'reference_price_precision_policy'->'precisionPolicy'->'choices'->'money.reference-unit-price'
                    IS DISTINCT FROM p_used->'choices'->'money.reference-unit-price' THEN
                RAISE EXCEPTION 'reference price proof was not used by the actual saved calculation' USING ERRCODE='23514';
            END IF;
            IF item->'reference_price_precision_policy'->>'sourceActionId'=txid_current()::text
                AND item->'reference_price_precision_policy'->>'revisionMode'='SELECTED'
                AND item->'reference_price_precision_policy'->'revisionPolicy'->'choices'->'money.revised-total'
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
        EXECUTE format('UPDATE %I SET reference_price_precision_policy=$1 WHERE id=$2',prefix||'_order_items') USING proof,(item->>'id')::uuid;
        count:=count+1;
    END LOOP;
    RETURN count;
END $$;

DO $saved_reference_price_verification$
DECLARE definition text;needle text;
BEGIN
    SELECT pg_get_functiondef('fn_guard_procurement_finance_commercial_snapshot()'::regprocedure) INTO definition;
    needle:='(total_amount_input IS NOT NULL AND price<>fn_procurement_reference_price_proof(total_amount_input,qty,reference_price_precision_policy))';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>2 THEN
        RAISE EXCEPTION 'V1083 Main reference price snapshot verification anchor differs';END IF;
    definition:=replace(definition,'FROM purchase_order_items','FROM purchase_order_items reference_item');
    definition:=replace(definition,'FROM subcontract_order_items','FROM subcontract_order_items reference_item');
    EXECUTE replace(definition,needle,'(total_amount_input IS NOT NULL AND NOT fn_procurement_reference_price_matches(to_jsonb(reference_item)))');

    SELECT pg_get_functiondef('fn_is_proven_procurement_qty_revision(text,jsonb,jsonb)'::regprocedure) INTO definition;
    -- Keep Main V1047/V1062's complete source, case-version, immutable input,
    -- deterministic adoption and amount checks. Only its old tuple-price check
    -- now dispatches through the complete saved-row proof.
    needle:='ELSIF (p_new->>''price'')::numeric IS DISTINCT FROM fn_procurement_reference_price_proof(
    (p_new->>''total_amount_input'')::numeric,(p_new->>''qty'')::numeric,p_new->''reference_price_precision_policy'') THEN RETURN FALSE;';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V1083 Main quantity reference proof anchor differs';END IF;
    EXECUTE replace(definition,needle,'ELSIF NOT fn_procurement_reference_price_matches(p_new) THEN RETURN FALSE;');

    SELECT pg_get_functiondef('fn_is_pending_purchase_case_qty_revision(jsonb,jsonb)'::regprocedure) INTO definition;
    needle:='(i.total_amount_input IS NOT NULL AND i.price IS DISTINCT FROM
               fn_procurement_reference_price_proof(i.total_amount_input,i.qty,i.reference_price_precision_policy))';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V1083 Main pending-case reference proof anchor differs';END IF;
    EXECUTE replace(definition,needle,'(i.total_amount_input IS NOT NULL AND NOT fn_procurement_reference_price_matches(to_jsonb(i)))');
END $saved_reference_price_verification$;
