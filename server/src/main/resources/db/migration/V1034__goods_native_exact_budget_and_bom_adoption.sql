-- Extend legitimate native capacity only. No historical value or old proof is recalculated.
ALTER TABLE goods DROP CONSTRAINT goods_cost_amount_range_chk;
ALTER TABLE goods ADD CONSTRAINT goods_cost_amount_range_chk CHECK (
 (source_e IS NULL OR source_e>=0 AND fn_financial_amount_is_exact(source_e))
 AND (work_e IS NULL OR work_e>=0 AND fn_financial_amount_is_exact(work_e))
 AND (lacquer_e IS NULL OR lacquer_e>=0 AND fn_financial_amount_is_exact(lacquer_e))
 AND (incidental_e IS NULL OR incidental_e>=0 AND fn_financial_amount_is_exact(incidental_e))
 AND (plating_e IS NULL OR plating_e>=0 AND fn_financial_amount_is_exact(plating_e))
 AND (casing_e IS NULL OR casing_e>=0 AND fn_financial_amount_is_exact(casing_e))
 AND (manage_e IS NULL OR manage_e>=0 AND fn_financial_amount_is_exact(manage_e))
 AND (polish_e IS NULL OR polish_e>=0 AND fn_financial_amount_is_exact(polish_e))
 AND (electric_e IS NULL OR electric_e>=0 AND fn_financial_amount_is_exact(electric_e))
 AND (machining_e IS NULL OR machining_e>=0 AND fn_financial_amount_is_exact(machining_e))
 AND (lost_e IS NULL OR lost_e>=0 AND fn_financial_amount_is_exact(lost_e))
 AND (rent_e IS NULL OR rent_e>=0 AND fn_financial_amount_is_exact(rent_e))
 AND (make_e IS NULL OR make_e>=0 AND fn_financial_amount_is_exact(make_e))
 AND (total IS NULL OR total>=0 AND fn_financial_amount_is_exact(total))
 AND (c_total IS NULL OR c_total>=0 AND fn_financial_amount_is_exact(c_total))
 AND (g_total IS NULL OR g_total>=0 AND fn_financial_amount_is_exact(g_total))
) NOT VALID;
ALTER TABLE goods VALIDATE CONSTRAINT goods_cost_amount_range_chk;
COMMENT ON CONSTRAINT goods_cost_amount_range_chk ON goods IS
 'V1034: nonnegative finite native 40 integer / 24 effective fractional digits, without typmod rounding';

-- Frozen source inputs accompany an actual source_e write, never a GET or migration.
CREATE TABLE goods_bom_material_cost_adoptions (
 id uuid PRIMARY KEY,goods_id uuid NOT NULL REFERENCES goods(id),goods_version bigint NOT NULL,
 source_action_id text NOT NULL,actor_id uuid NOT NULL REFERENCES users(id),request_id uuid,
 original_decimal text NOT NULL,recorded_decimal text NOT NULL,
 original_sources jsonb NOT NULL CHECK(jsonb_typeof(original_sources)='object'),
 precision_policy jsonb NOT NULL CHECK(jsonb_typeof(precision_policy)='object'),
 numeric_evidence_id uuid NOT NULL REFERENCES business_numeric_input_evidence(id),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX goods_bom_cost_adoption_owner_idx ON goods_bom_material_cost_adoptions(goods_id,created_at,id);
CREATE TRIGGER goods_bom_cost_adoption_immutable BEFORE UPDATE OR DELETE ON goods_bom_material_cost_adoptions
 FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
CREATE TRIGGER goods_bom_cost_adoption_no_truncate BEFORE TRUNCATE ON goods_bom_material_cost_adoptions
 FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
ALTER TABLE goods_bom_material_cost_adoptions ENABLE ALWAYS TRIGGER goods_bom_cost_adoption_immutable;
ALTER TABLE goods_bom_material_cost_adoptions ENABLE ALWAYS TRIGGER goods_bom_cost_adoption_no_truncate;

-- The existing selection/formula remains single-source. Numeric inputs in the
-- frozen source packet are decimal text; currency/unit identities are not inferred.
CREATE FUNCTION fn_goods_bom_material_cost_basis(p_goods uuid) RETURNS jsonb LANGUAGE sql STABLE AS $$
 WITH sources AS (
  SELECT edge.id edge_id,edge.updated_at edge_revision,edge.qty,
   component.id component_id,component.version component_version,component.currency_id,component.unit_id,
   CASE WHEN component.source_type='自制' OR EXISTS(
    SELECT 1 FROM goods_bom_items child JOIN goods grandchild ON grandchild.id=child.component_goods_id
    WHERE child.goods_id=component.id AND NOT child.is_deleted AND NOT grandchild.auto_created)
    THEN CASE WHEN component.c_total IS NULL THEN 'price' ELSE 'c_total' END ELSE 'price' END source_key,
   CASE WHEN component.source_type='自制' OR EXISTS(
    SELECT 1 FROM goods_bom_items child JOIN goods grandchild ON grandchild.id=child.component_goods_id
    WHERE child.goods_id=component.id AND NOT child.is_deleted AND NOT grandchild.auto_created)
    THEN COALESCE(component.c_total,component.price) ELSE component.price END value
  FROM goods_bom_items edge JOIN goods parent ON parent.id=edge.goods_id
  JOIN goods component ON component.id=edge.component_goods_id
  WHERE edge.goods_id=p_goods AND NOT edge.is_deleted AND NOT parent.auto_created AND NOT component.auto_created
 )
 SELECT jsonb_build_object('version',1,'formula','SUM_DESIGN_QTY_TIMES_COMPONENT_COST_OR_PRICE',
  'parentId',p_goods,'parentCurrencyId',(SELECT currency_id FROM goods WHERE id=p_goods),
  'parentUnitId',(SELECT unit_id FROM goods WHERE id=p_goods),
  'exactTotal',COALESCE(sum(qty*value),0)::text,
  'sources',COALESCE(jsonb_agg(jsonb_build_object('edgeId',edge_id,'edgeRevision',edge_revision,
   'designQty',qty::text,'componentId',component_id,'componentVersion',component_version,
   'currencyId',currency_id,'unitId',unit_id,'sourceKey',source_key,'sourceValue',value::text)
   ORDER BY edge_id),'[]'::jsonb)) FROM sources
$$;

CREATE OR REPLACE FUNCTION fn_goods_bom_material_cost(p_goods uuid) RETURNS numeric LANGUAGE plpgsql VOLATILE AS $$
DECLARE basis jsonb;raw numeric;adopted numeric;policy jsonb:=fn_business_precision_snapshot();
 used jsonb;pending jsonb;purpose text:='goods.bom.material-cost';
BEGIN
 basis:=fn_goods_bom_material_cost_basis(p_goods);raw:=(basis->>'exactTotal')::numeric;
 -- An integer overflow cannot be disguised as a choice of decimal places.
 IF raw<0 OR raw>=1e40::numeric OR raw::text IN('NaN','Infinity','-Infinity') THEN
  RAISE EXCEPTION 'BOM材料合计超出非负原数范围，本次未保存' USING ERRCODE='22003';END IF;
 adopted:=fn_business_exact_divide_with_policy(raw,1,purpose,'本次BOM材料合计',24,policy,true);
 IF NOT fn_financial_amount_is_exact(adopted) THEN
  RAISE EXCEPTION 'BOM材料合计超出可无损保存范围，本次未保存' USING ERRCODE='22003';END IF;
 used:=CASE WHEN raw IS DISTINCT FROM adopted THEN jsonb_build_object(purpose,policy->'choices'->purpose) ELSE '{}'::jsonb END;
 pending:=COALESCE(NULLIF(current_setting('app.goods_bom_cost_pending',true),''),'{}')::jsonb;
 PERFORM set_config('app.goods_bom_cost_pending',(pending||jsonb_build_object(p_goods::text,
  jsonb_build_object('basis',basis,'adopted',adopted::text,'policy',jsonb_build_object('version',1,'choices',used),
   'action',pg_current_xact_id()::text)))::text,true);
 RETURN adopted;
END $$;

CREATE FUNCTION fn_capture_goods_bom_material_cost_adoption() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE pending jsonb;proof jsonb;basis jsonb;raw text;adopted text;policy jsonb;unit jsonb;
 actor uuid:=NULLIF(current_setting('app.actor_id',true),'')::uuid;
 request uuid:=NULLIF(current_setting('app.audit_request_id',true),'')::uuid;
 adoption uuid:=gen_random_uuid();evidence uuid:=gen_random_uuid();fingerprint text;
BEGIN
 pending:=COALESCE(NULLIF(current_setting('app.goods_bom_cost_pending',true),''),'{}')::jsonb;
 proof:=pending->NEW.id::text;
 IF proof IS NULL OR (proof->>'action') IS DISTINCT FROM pg_current_xact_id()::text
  OR NEW.source_e IS DISTINCT FROM (proof->>'adopted')::numeric THEN RETURN NEW;END IF;
 PERFORM set_config('app.goods_bom_cost_pending',(pending-NEW.id::text)::text,true);
 IF actor IS NULL THEN RAISE EXCEPTION 'Actual BOM cost adoption requires the current transaction actor' USING ERRCODE='23514';END IF;
 basis:=proof->'basis';raw:=basis->>'exactTotal';adopted:=proof->>'adopted';policy:=proof->'policy';
 unit:=jsonb_strip_nulls(jsonb_build_object('kind','UNIT_COST','referenceId',basis->'parentCurrencyId'));
 fingerprint:=encode(sha256(convert_to(jsonb_build_array('GOODS_BOM_MATERIAL_COST',NEW.id,NEW.version,
  basis,raw,adopted,policy,actor,request,pg_current_xact_id()::text)::text,'UTF8')),'hex');
 INSERT INTO business_numeric_input_evidence(id,owner_kind,owner_id,source_row_id,field_key,owner_version,
  source_action_id,original_decimal,original_unit,recorded_decimal,recorded_unit,precision_policy,actor_id,request_id,fingerprint)
 VALUES(evidence,'GOODS_BOM_MATERIAL_COST',NEW.id,adoption,'sourceE',NEW.version::text,
  pg_current_xact_id()::text,raw,unit,adopted,unit,policy,actor,request,fingerprint);
 INSERT INTO goods_bom_material_cost_adoptions(id,goods_id,goods_version,source_action_id,actor_id,request_id,
  original_decimal,recorded_decimal,original_sources,precision_policy,numeric_evidence_id)
 VALUES(adoption,NEW.id,NEW.version,pg_current_xact_id()::text,actor,request,raw,adopted,basis,policy,evidence);
 RETURN NEW;
END $$;
CREATE TRIGGER goods_bom_material_cost_adoption AFTER INSERT OR UPDATE ON goods
 FOR EACH ROW EXECUTE FUNCTION fn_capture_goods_bom_material_cost_adoption();
ALTER TABLE goods ENABLE ALWAYS TRIGGER goods_bom_material_cost_adoption;

-- Periodic conversion adopts one exact per-piece quantity, retaining its original
-- numerator/basis before the existing shape normalization changes basis to 1.
CREATE TABLE goods_bom_periodic_quantity_adoptions (
 id uuid PRIMARY KEY,bom_item_id uuid NOT NULL REFERENCES goods_bom_items(id),goods_id uuid NOT NULL REFERENCES goods(id),
 component_goods_id uuid NOT NULL REFERENCES goods(id),source_action_id text NOT NULL,
 actor_id uuid NOT NULL REFERENCES users(id),request_id uuid,original_sources jsonb NOT NULL,
 recorded_quantity numeric NOT NULL CHECK(recorded_quantity>0 AND fn_financial_amount_is_exact(recorded_quantity)),
 precision_policy jsonb NOT NULL,numeric_evidence_id uuid NOT NULL REFERENCES business_numeric_input_evidence(id),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX goods_bom_periodic_adoption_owner_idx ON goods_bom_periodic_quantity_adoptions(goods_id,bom_item_id,created_at);
CREATE TRIGGER goods_bom_periodic_adoption_immutable BEFORE UPDATE OR DELETE ON goods_bom_periodic_quantity_adoptions
 FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
CREATE TRIGGER goods_bom_periodic_adoption_no_truncate BEFORE TRUNCATE ON goods_bom_periodic_quantity_adoptions
 FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
ALTER TABLE goods_bom_periodic_quantity_adoptions ENABLE ALWAYS TRIGGER goods_bom_periodic_adoption_immutable;
ALTER TABLE goods_bom_periodic_quantity_adoptions ENABLE ALWAYS TRIGGER goods_bom_periodic_adoption_no_truncate;
CREATE FUNCTION fn_goods_bom_periodic_quantity(p_row uuid,p_goods uuid,p_component uuid,p_quantity numeric,p_basis numeric,p_kind text)
 RETURNS numeric LANGUAGE plpgsql VOLATILE AS $$
DECLARE adopted numeric;policy jsonb:=fn_business_precision_snapshot();used jsonb;pending jsonb;basis jsonb;
 purpose text:='goods.bom.periodic-per-piece';
BEGIN
 IF p_row IS NULL OR p_goods IS NULL OR p_component IS NULL OR p_kind IS NULL OR p_kind NOT IN('GRAMS','BASIS_OUTPUT')
  OR p_quantity IS NULL OR p_basis IS NULL OR p_quantity<=0 OR p_basis<=0
  OR NOT fn_financial_amount_is_exact(p_quantity) OR NOT fn_financial_amount_is_exact(p_basis) THEN
  RAISE EXCEPTION 'Periodic BOM requires exact positive original quantity, basis and actual source identities' USING ERRCODE='22023';END IF;
 IF p_quantity>=1e40::numeric*p_basis THEN RAISE EXCEPTION 'Periodic BOM per-piece quantity exceeds native capacity; nothing saved' USING ERRCODE='22003';END IF;
 adopted:=fn_business_exact_divide_with_policy(p_quantity,p_basis,purpose,'本次BOM单个用量',24,policy,true);
 IF adopted<=0 OR NOT fn_financial_amount_is_exact(adopted) THEN
  RAISE EXCEPTION '本次BOM单个用量须为可保存的正原数，请重新核对采用选择；本次未保存' USING ERRCODE='22003';END IF;
 used:=CASE WHEN adopted*p_basis IS DISTINCT FROM p_quantity THEN policy->'choices'->purpose ELSE NULL END;
 basis:=jsonb_build_object('version',1,'bomItemId',p_row,'parentId',p_goods,'componentId',p_component,
  'inputKind',p_kind,'originalQuantity',p_quantity::text,'originalBasis',p_basis::text,
  'componentUnitId',(SELECT unit_id FROM goods WHERE id=p_component),'parentUnitId',(SELECT unit_id FROM goods WHERE id=p_goods));
 pending:=COALESCE(NULLIF(current_setting('app.goods_bom_periodic_pending',true),''),'{}')::jsonb;
 PERFORM set_config('app.goods_bom_periodic_pending',(pending||jsonb_build_object(p_row::text,
  jsonb_build_object('basis',basis,'adopted',adopted::text,'policy',jsonb_build_object('version',1,'choices',
   CASE WHEN used IS NULL THEN '{}'::jsonb ELSE jsonb_build_object(purpose,used) END),'action',pg_current_xact_id()::text)))::text,true);
 RETURN adopted;
END $$;
CREATE FUNCTION fn_capture_goods_bom_periodic_quantity_adoption() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE pending jsonb;proof jsonb;basis jsonb;policy jsonb;unit jsonb;raw_unit jsonb;
 actor uuid:=NULLIF(current_setting('app.actor_id',true),'')::uuid;
 request uuid:=NULLIF(current_setting('app.audit_request_id',true),'')::uuid;
 adoption uuid:=gen_random_uuid();evidence uuid:=gen_random_uuid();fingerprint text;
BEGIN
 pending:=COALESCE(NULLIF(current_setting('app.goods_bom_periodic_pending',true),''),'{}')::jsonb;proof:=pending->NEW.id::text;
 IF proof IS NULL OR (proof->>'action') IS DISTINCT FROM pg_current_xact_id()::text
  OR NEW.qty IS DISTINCT FROM (proof->>'adopted')::numeric THEN RETURN NEW;END IF;
 basis:=proof->'basis';policy:=proof->'policy';
 IF actor IS NULL OR NEW.goods_id IS DISTINCT FROM (basis->>'parentId')::uuid
  OR NEW.component_goods_id IS DISTINCT FROM (basis->>'componentId')::uuid OR NEW.basis_output_qty<>1 THEN
  RAISE EXCEPTION 'Actual periodic BOM adoption requires its same source row, normalized basis and transaction actor' USING ERRCODE='23514';END IF;
 PERFORM set_config('app.goods_bom_periodic_pending',(pending-NEW.id::text)::text,true);
 unit:=jsonb_build_object('kind','GOODS_BASE','referenceId',NEW.component_goods_id);
 raw_unit:=CASE WHEN basis->>'inputKind'='GRAMS' THEN jsonb_build_object('kind','MASS','code','g')
  ELSE jsonb_build_object('kind','BOM_BASIS_QUANTITY','referenceId',NEW.component_goods_id) END;
 fingerprint:=encode(sha256(convert_to(jsonb_build_array('GOODS_BOM_PERIODIC',NEW.id,basis,NEW.qty::text,policy,
  actor,request,pg_current_xact_id()::text)::text,'UTF8')),'hex');
 INSERT INTO business_numeric_input_evidence(id,owner_kind,owner_id,source_row_id,field_key,owner_version,
  source_action_id,original_decimal,original_unit,recorded_decimal,recorded_unit,precision_policy,actor_id,request_id,fingerprint)
 VALUES(evidence,'GOODS_BOM_PERIODIC',NEW.goods_id,adoption,'perPieceQty','1',pg_current_xact_id()::text,
  basis->>'originalQuantity',raw_unit,NEW.qty::text,unit,policy,actor,request,fingerprint);
 INSERT INTO goods_bom_periodic_quantity_adoptions(id,bom_item_id,goods_id,component_goods_id,source_action_id,
  actor_id,request_id,original_sources,recorded_quantity,precision_policy,numeric_evidence_id)
 VALUES(adoption,NEW.id,NEW.goods_id,NEW.component_goods_id,pg_current_xact_id()::text,actor,request,basis,NEW.qty,policy,evidence);
 RETURN NEW;
END $$;
CREATE TRIGGER goods_bom_periodic_quantity_adoption AFTER INSERT OR UPDATE ON goods_bom_items
 FOR EACH ROW EXECUTE FUNCTION fn_capture_goods_bom_periodic_quantity_adoption();
ALTER TABLE goods_bom_items ENABLE ALWAYS TRIGGER goods_bom_periodic_quantity_adoption;

-- Only metadata is projected into the central audit; source values stay private.
DO $goods_bom_cost_audit_scope$
DECLARE definition text;signature text;old_names text:=$names$'business_numeric_input_evidence'$names$;
BEGIN
 FOREACH signature IN ARRAY ARRAY['fn_refresh_finance_audit_metadata_projection()','fn_audit_track_table(text,text,text,boolean,text[],boolean,text)'] LOOP
  SELECT pg_get_functiondef(signature::regprocedure) INTO definition;
  IF position('goods_bom_material_cost_adoptions' IN definition)=0 THEN
   IF position(old_names IN definition)=0 THEN RAISE EXCEPTION 'Review goods BOM cost audit metadata scope: %',signature;END IF;
   EXECUTE replace(definition,old_names,old_names||$extra$,'goods_bom_material_cost_adoptions','goods_bom_periodic_quantity_adoptions'$extra$);
  END IF;
 END LOOP;
END $goods_bom_cost_audit_scope$;
SELECT fn_audit_track_table('goods_bom_material_cost_adoptions','COLUMN_SCOPED','data_change',false,
 ARRAY['id','goods_id','goods_version','source_action_id','actor_id','request_id','numeric_evidence_id','created_at'],true,NULL);
SELECT fn_refresh_finance_audit_metadata_projection();
SELECT fn_audit_track_table('goods_bom_periodic_quantity_adoptions','COLUMN_SCOPED','data_change',false,
 ARRAY['id','goods_id','bom_item_id','component_goods_id','source_action_id','actor_id','request_id','numeric_evidence_id','created_at'],true,NULL);
SELECT fn_refresh_finance_audit_metadata_projection();
