-- FIN06 is a reviewed attribution of real stock and one real GL, never another stock/amount ledger.
CREATE TABLE finance_material_contexts (
 id uuid PRIMARY KEY,auxiliary_id uuid NOT NULL REFERENCES finance_auxiliary_items(id),
 account_code text NOT NULL REFERENCES finance_chart_codes(code),accounting_currency_id uuid NOT NULL REFERENCES currencies(id),
 goods_id uuid NOT NULL REFERENCES goods(id),color_id uuid REFERENCES colors(id),
 amount_basis text NOT NULL CHECK(amount_basis IN('LOCAL','ORIGINAL')),original_currency_id uuid REFERENCES currencies(id),
 CHECK((amount_basis='LOCAL' AND original_currency_id IS NULL) OR (amount_basis='ORIGINAL' AND original_currency_id IS NOT NULL)),
 row_version bigint NOT NULL DEFAULT 0,active boolean NOT NULL DEFAULT true,created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_finance_material_active_context ON finance_material_contexts(auxiliary_id,accounting_currency_id,account_code,goods_id,color_id,amount_basis,original_currency_id) NULLS NOT DISTINCT WHERE active;
CREATE TABLE finance_material_evidence (
 id uuid PRIMARY KEY,context_id uuid NOT NULL REFERENCES finance_material_contexts(id),
 kind text NOT NULL CHECK(kind IN('CONTEXT','GOODS','NATIVE_PARTY','UNIT','OPENING','WEIGHT','SOURCE_RELATION','COVERAGE','FEE','ZERO','SIDEBAR','CLOSE')),
 input jsonb NOT NULL CHECK(jsonb_typeof(input)='object'),resource_key text,
 expected_approved_id uuid REFERENCES finance_material_evidence(id),
 status text NOT NULL DEFAULT 'DRAFT' CHECK(status IN('DRAFT','SUBMITTED','APPROVED','REJECTED','WITHDRAWN')),
 row_version bigint NOT NULL DEFAULT 0,current_approved boolean NOT NULL DEFAULT false,
 source_snapshot jsonb,source_fingerprint text,submission_reason text,submitted_by uuid REFERENCES users(id),submitted_at timestamptz,
 approved_by uuid REFERENCES users(id),approved_at timestamptz,decision_reason text,
 created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(NOT current_approved OR status='APPROVED'),CHECK(approved_by IS NULL OR approved_by<>submitted_by)
);
CREATE UNIQUE INDEX ux_finance_material_current_resource ON finance_material_evidence(kind,resource_key) WHERE current_approved;
CREATE INDEX ix_finance_material_context_evidence ON finance_material_evidence(context_id,kind,current_approved,created_at);
CREATE TABLE finance_material_operations (
 request_id uuid PRIMARY KEY,actor_id uuid NOT NULL REFERENCES users(id),fingerprint text NOT NULL,
 result jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),CHECK(fingerprint ~ '^[0-9a-f]{64}$')
);
CREATE FUNCTION fn_finance_material_history_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'material evidence history cannot be deleted' USING ERRCODE='55000'; END IF;
 IF OLD.status IN('APPROVED','REJECTED','WITHDRAWN') AND
    (to_jsonb(NEW)-'current_approved') IS DISTINCT FROM (to_jsonb(OLD)-'current_approved') THEN
   RAISE EXCEPTION 'reviewed material evidence cannot be rewritten' USING ERRCODE='55000';
 END IF;
 IF OLD.status='SUBMITTED' AND (to_jsonb(NEW)-ARRAY['status','current_approved','approved_by','approved_at','decision_reason','row_version','updated_at']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['status','current_approved','approved_by','approved_at','decision_reason','row_version','updated_at']) THEN
   RAISE EXCEPTION 'submitted material evidence source is frozen' USING ERRCODE='55000';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_finance_material_history_guard BEFORE UPDATE OR DELETE ON finance_material_evidence FOR EACH ROW EXECUTE FUNCTION fn_finance_material_history_guard();
CREATE TRIGGER trg_finance_material_operations_immutable BEFORE UPDATE OR DELETE ON finance_material_operations FOR EACH ROW EXECUTE FUNCTION fn_reject_update_or_delete();
SELECT fn_audit_track_table('finance_material_contexts','COLUMN_SCOPED','data_change',false,ARRAY['id','auxiliary_id','account_code','accounting_currency_id','goods_id','color_id','amount_basis','original_currency_id','row_version','active','created_by','created_at'],true,NULL);
SELECT fn_audit_track_table('finance_material_evidence','COLUMN_SCOPED','data_change',false,ARRAY['id','context_id','kind','resource_key','status','row_version','current_approved','source_fingerprint','submitted_by','submitted_at','approved_by','approved_at','created_by','created_at','updated_at'],true,NULL);
SELECT fn_audit_track_table('finance_material_operations','COLUMN_SCOPED','data_change',false,ARRAY['request_id','actor_id','fingerprint','created_at'],true,NULL);
