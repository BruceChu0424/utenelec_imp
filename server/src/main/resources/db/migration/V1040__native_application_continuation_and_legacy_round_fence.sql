-- V1040 candidate: current native workflow owns new work. Historical authority
-- belongs to one real frozen legacy round, never to a timestamp or a permanent flag.
CREATE TABLE finance_application_legacy_sources (
 application_id uuid PRIMARY KEY REFERENCES finance_applications(id),
 header_snapshot jsonb NOT NULL CHECK(jsonb_typeof(header_snapshot)='object'),
 nodes_snapshot jsonb NOT NULL CHECK(jsonb_typeof(nodes_snapshot)='array'),
 captured_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO finance_application_legacy_sources(application_id,header_snapshot,nodes_snapshot)
 SELECT app.id,to_jsonb(app),COALESCE((SELECT jsonb_agg(to_jsonb(node) ORDER BY submission_round,step_no)
  FROM finance_application_nodes node WHERE node.application_id=app.id),'[]'::jsonb)
 FROM finance_applications app WHERE app.kind<>'PAYROLL_PAYMENT';

CREATE TABLE finance_application_legacy_round_authorities (
 application_id uuid NOT NULL REFERENCES finance_applications(id),submission_round integer NOT NULL CHECK(submission_round>0),
 source_kind text NOT NULL,source_id uuid,source_fingerprint text NOT NULL CHECK(source_fingerprint~'^[0-9a-f]{64}$'),
 frozen_source jsonb NOT NULL,node_contract jsonb NOT NULL CHECK(jsonb_typeof(node_contract)='array'),
 captured_status text NOT NULL,captured_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(application_id,submission_round)
);
INSERT INTO finance_application_legacy_round_authorities(application_id,submission_round,source_kind,source_id,
 source_fingerprint,frozen_source,node_contract,captured_status)
 SELECT app.id,app.submission_round,app.source_kind,app.source_id,app.source_fingerprint,app.source_snapshot,
  (SELECT jsonb_agg(jsonb_build_object('step',node.step_no,'role',node.role_key,'label',node.label_snapshot,'action',node.action) ORDER BY node.step_no)
   FROM finance_application_nodes node WHERE node.application_id=app.id AND node.submission_round=app.submission_round),app.status
 FROM finance_applications app WHERE app.kind<>'PAYROLL_PAYMENT' AND app.submission_round>0
  AND app.source_fingerprint IS NOT NULL AND app.source_snapshot IS NOT NULL
  AND app.status IN('SUBMITTED','REVIEWING','APPROVED','ARCHIVED','EXECUTED','CONFIRMED','REVERSED')
  AND (SELECT string_agg(node.role_key,',' ORDER BY node.step_no) FROM finance_application_nodes node
   WHERE node.application_id=app.id AND node.submission_round=app.submission_round)=
   CASE WHEN app.kind='TRAVEL_APPLICATION' THEN 'DEPARTMENT_REVIEW,TRAVEL_APPROVAL,FINANCE_CUSTODY'
    ELSE 'DEPARTMENT_REVIEW,FINANCE_REVIEW_1,FINANCE_REVIEW_2,MANAGEMENT_PAYMENT' END
  AND (SELECT min(step_no)=1 AND max(step_no)=count(*) FROM finance_application_nodes node
   WHERE node.application_id=app.id AND node.submission_round=app.submission_round)
  AND NOT EXISTS(SELECT 1 FROM finance_application_nodes node WHERE node.application_id=app.id
   AND node.submission_round=app.submission_round AND node.action<>CASE WHEN node.role_key='FINANCE_CUSTODY' THEN 'ARCHIVE' ELSE 'APPROVE' END);

CREATE FUNCTION fn_finance_application_legacy_round_allowed(p_id uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT COALESCE((SELECT CASE WHEN app.kind='PAYROLL_PAYMENT' THEN app.source_kind='PAYROLL_BATCH' AND app.source_id IS NOT NULL
  ELSE app.status IN('SUBMITTED','REVIEWING','APPROVED','ARCHIVED','EXECUTED','CONFIRMED','REVERSED') AND EXISTS(
   SELECT 1 FROM finance_application_legacy_round_authorities authority
   WHERE authority.application_id=app.id AND authority.submission_round=app.submission_round
    AND authority.source_kind=app.source_kind AND authority.source_id IS NOT DISTINCT FROM app.source_id
    AND authority.source_fingerprint=app.source_fingerprint AND authority.frozen_source IS NOT DISTINCT FROM app.source_snapshot
    AND authority.node_contract IS NOT DISTINCT FROM (SELECT jsonb_agg(jsonb_build_object('step',node.step_no,'role',node.role_key,'label',node.label_snapshot,'action',node.action) ORDER BY node.step_no)
     FROM finance_application_nodes node WHERE node.application_id=app.id AND node.submission_round=app.submission_round)) END
  FROM finance_applications app WHERE app.id=p_id),false)
$$;

CREATE TABLE finance_application_continuation_reviews (
 id uuid PRIMARY KEY,origin_id uuid NOT NULL,original_application_id uuid REFERENCES finance_applications(id),
 actor_id uuid NOT NULL REFERENCES users(id),actor_employee_id uuid NOT NULL REFERENCES employees(id),actor_session_id uuid,
 original_request_id uuid,source_version bigint,source_fingerprint text NOT NULL CHECK(source_fingerprint~'^[0-9a-f]{64}$'),
 original_command text,original_snapshot jsonb NOT NULL CHECK(jsonb_typeof(original_snapshot)='object'),
 native_source_snapshot jsonb NOT NULL CHECK(jsonb_typeof(native_source_snapshot)='object'),
 attachment_snapshot jsonb NOT NULL CHECK(jsonb_typeof(attachment_snapshot)='array'),
 target_kind text NOT NULL CHECK(target_kind IN('EXPENSE_CLAIM','BUSINESS_APPLICATION')),
 target_business_kind text,target_id uuid NOT NULL,proposed_input jsonb NOT NULL CHECK(jsonb_typeof(proposed_input)='object'),
 expires_at timestamptz NOT NULL,created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX finance_application_continuation_review_origin ON finance_application_continuation_reviews(origin_id,actor_id,created_at);
CREATE TABLE finance_application_native_mappings (
 origin_id uuid PRIMARY KEY,review_id uuid NOT NULL UNIQUE REFERENCES finance_application_continuation_reviews(id),
 original_application_id uuid REFERENCES finance_applications(id),original_kind text NOT NULL,
 native_kind text NOT NULL CHECK(native_kind IN('EXPENSE_CLAIM','BUSINESS_APPLICATION')),native_id uuid NOT NULL,
 native_business_kind text,source_fingerprint text NOT NULL CHECK(source_fingerprint~'^[0-9a-f]{64}$'),
 original_currency_id uuid REFERENCES currencies(id),amount_basis text NOT NULL CHECK(amount_basis IN('ORIGINAL','LOCAL','NOT_APPLICABLE')),
 original_amount numeric,original_obligations jsonb NOT NULL DEFAULT '[]'::jsonb CHECK(jsonb_typeof(original_obligations)='array'),
 actor_id uuid NOT NULL REFERENCES users(id),actor_employee_id uuid NOT NULL REFERENCES employees(id),request_id uuid NOT NULL UNIQUE,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),UNIQUE(native_kind,native_id),UNIQUE(original_application_id),
 CHECK(original_application_id IS NULL OR original_application_id=origin_id),
 CHECK(original_amount IS NULL OR (original_amount>=0 AND fn_financial_amount_is_exact(original_amount))),
 CHECK((amount_basis='NOT_APPLICABLE')=(original_amount IS NULL))
);
CREATE TABLE finance_application_continued_originals (
 review_id uuid NOT NULL REFERENCES finance_application_continuation_reviews(id),attachment_id uuid NOT NULL REFERENCES attachments(id),
 owner_type text NOT NULL,owner_id uuid NOT NULL,sha256 text NOT NULL,attachment_name text NOT NULL DEFAULT '',PRIMARY KEY(review_id,attachment_id)
);

DO $immutable_continuation$
DECLARE target text;
BEGIN
 FOREACH target IN ARRAY ARRAY['finance_application_legacy_sources','finance_application_legacy_round_authorities',
  'finance_application_continuation_reviews','finance_application_native_mappings','finance_application_continued_originals'] LOOP
  EXECUTE format('CREATE TRIGGER immutable_evidence BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_evidence_immutable()',target);
  EXECUTE format('CREATE TRIGGER no_truncate_evidence BEFORE TRUNCATE ON %I FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable()',target);
  EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER immutable_evidence',target);
  EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER no_truncate_evidence',target);
 END LOOP;
END $immutable_continuation$;

CREATE FUNCTION fn_guard_finance_legacy_header_fence() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='INSERT' THEN
  IF NEW.kind<>'PAYROLL_PAYMENT' OR NEW.source_kind<>'PAYROLL_BATCH' OR NEW.source_id IS NULL THEN
   RAISE EXCEPTION '新申请请审阅后按当前申请流程继续；本次未建立旧审批单' USING ERRCODE='23514';END IF;
  RETURN NEW;
 END IF;
 IF TG_OP='DELETE' THEN RAISE EXCEPTION '原申请及其历史不得删除' USING ERRCODE='23514';END IF;
 IF NEW.kind IS DISTINCT FROM OLD.kind OR NEW.source_kind IS DISTINCT FROM OLD.source_kind OR NEW.source_id IS DISTINCT FROM OLD.source_id THEN
  RAISE EXCEPTION '原申请类别和真实来源不可替换' USING ERRCODE='23514';END IF;
 IF OLD.kind='PAYROLL_PAYMENT' THEN RETURN NEW;END IF;
 IF EXISTS(SELECT 1 FROM finance_application_native_mappings WHERE original_application_id=OLD.id) THEN
  RAISE EXCEPTION '原稿已按当前流程继续，保留原稿只读；请打开对应当前申请' USING ERRCODE='23514';END IF;
 IF NEW.submission_round IS DISTINCT FROM OLD.submission_round THEN
  RAISE EXCEPTION '原轮已结束，新一轮须审阅后按当前申请流程继续' USING ERRCODE='23514';END IF;
 IF fn_finance_application_legacy_round_allowed(OLD.id) THEN
  IF NEW.source_fingerprint IS DISTINCT FROM OLD.source_fingerprint OR NEW.source_snapshot IS DISTINCT FROM OLD.source_snapshot THEN
   RAISE EXCEPTION '原轮冻结来源和指纹不得替换' USING ERRCODE='23514';END IF;
  RETURN NEW;END IF;
 IF EXISTS(SELECT 1 FROM finance_application_legacy_sources WHERE application_id=OLD.id)
  AND OLD.status IN('DRAFT','REJECTED','REVERSED') AND NEW.status IN('DRAFT','REJECTED','REVERSED') THEN RETURN NEW;END IF;
 RAISE EXCEPTION '当前记录没有对应原轮的冻结授权，不能继续旧审批或资金动作' USING ERRCODE='23514';
END $$;
CREATE TRIGGER finance_legacy_header_fence BEFORE INSERT OR UPDATE OR DELETE ON finance_applications
 FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_legacy_header_fence();
ALTER TABLE finance_applications ENABLE ALWAYS TRIGGER finance_legacy_header_fence;

-- Optional travel estimates remain unknown when blank. Existing zero is not reinterpreted.
ALTER TABLE business_applications ALTER COLUMN amount DROP NOT NULL;
ALTER TABLE business_applications ADD CONSTRAINT business_application_amount_presence CHECK(kind='TRAVEL' OR amount IS NOT NULL);

-- No new non-payroll node tree can be inserted through SQL or a former API.
CREATE FUNCTION fn_guard_finance_legacy_node_fence() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE app finance_applications%ROWTYPE;
BEGIN
 SELECT * INTO app FROM finance_applications WHERE id=COALESCE(NEW.application_id,OLD.application_id) FOR UPDATE;
 IF app.kind='PAYROLL_PAYMENT' AND app.source_kind='PAYROLL_BATCH' AND app.source_id IS NOT NULL THEN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION '原审批步骤不可删除' USING ERRCODE='23514';END IF;
  RETURN NEW;END IF;
 IF TG_OP<>'UPDATE' OR NEW.submission_round<>app.submission_round
  OR NOT fn_finance_application_legacy_round_allowed(app.id) THEN
  RAISE EXCEPTION '只能办理已冻结原轮的原节点；新的申请须由当前流程办理' USING ERRCODE='23514';END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER finance_legacy_node_fence BEFORE INSERT OR UPDATE OR DELETE ON finance_application_nodes
 FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_legacy_node_fence();
ALTER TABLE finance_application_nodes ENABLE ALWAYS TRIGGER finance_legacy_node_fence;

-- A mapping preserves amount meaning. It does not reinterpret foreign units or
-- overwrite an existing claim with the current price/default/header.
CREATE FUNCTION fn_guard_continued_application_values() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE mapping finance_application_native_mappings%ROWTYPE; original_supplier uuid;
BEGIN
 SELECT * INTO mapping FROM finance_application_native_mappings
  WHERE native_kind=CASE WHEN TG_TABLE_NAME='business_applications' THEN 'BUSINESS_APPLICATION' ELSE 'EXPENSE_CLAIM' END AND native_id=NEW.id;
 IF NOT FOUND THEN RETURN NEW;END IF;
 IF TG_TABLE_NAME='business_applications' THEN
  IF NEW.kind IS DISTINCT FROM mapping.native_business_kind OR NEW.amount IS DISTINCT FROM mapping.original_amount THEN
   RAISE EXCEPTION '当前申请类别和金额须与已审阅原稿一致；原币、本币及未知金额不能互换' USING ERRCODE='23514';END IF;
  SELECT NULLIF(review.original_snapshot->'payload'->>'supplierId','')::uuid INTO original_supplier
   FROM finance_application_continuation_reviews review WHERE review.id=mapping.review_id;
  IF original_supplier IS NOT NULL AND NEW.supplier_id IS DISTINCT FROM original_supplier THEN
   RAISE EXCEPTION '当前供应商不能替换已审阅原义务' USING ERRCODE='23514';END IF;
 ELSIF NEW.total_amount IS DISTINCT FROM mapping.original_amount THEN
  RAISE EXCEPTION '原报销金额与已审阅原稿不一致，请保留当前输入核对原稿' USING ERRCODE='23514';END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER continued_business_values BEFORE INSERT OR UPDATE ON business_applications
 FOR EACH ROW EXECUTE FUNCTION fn_guard_continued_application_values();
CREATE TRIGGER continued_expense_values BEFORE UPDATE ON expense_claims
 FOR EACH ROW EXECUTE FUNCTION fn_guard_continued_application_values();
ALTER TABLE business_applications ENABLE ALWAYS TRIGGER continued_business_values;
ALTER TABLE expense_claims ENABLE ALWAYS TRIGGER continued_expense_values;

SELECT fn_audit_track_table('finance_application_continuation_reviews','COLUMN_SCOPED','data_change',false,
 ARRAY['id','origin_id','original_application_id','actor_id','actor_employee_id','source_version','source_fingerprint','target_kind','target_business_kind','target_id','expires_at','created_at'],true,NULL);
SELECT fn_audit_track_table('finance_application_native_mappings','COLUMN_SCOPED','data_change',false,
 ARRAY['origin_id','review_id','original_application_id','original_kind','native_kind','native_id','native_business_kind','source_fingerprint','original_currency_id','amount_basis','actor_id','actor_employee_id','request_id','created_at'],true,NULL);
SELECT fn_audit_track_table('finance_application_continued_originals','COLUMN_SCOPED','data_change',false,
 ARRAY['review_id','attachment_id','owner_type','owner_id','sha256'],true,NULL);

-- Provenance only: never another payable, prepayment asset, bank flow or GL.
CREATE TABLE finance_native_application_payment_proofs (
 application_id uuid NOT NULL REFERENCES business_applications(id),submission_round integer NOT NULL,
 payment_id uuid NOT NULL REFERENCES finance_payments(id),source_branch text NOT NULL CHECK(source_branch IN('NATIVE_ADVANCE_V2','LEGACY_PREPAYMENT_LEDGER')),
 amount_basis text NOT NULL CHECK(amount_basis IN('LOCAL','ORIGINAL')),source_fingerprint text NOT NULL CHECK(source_fingerprint~'^[0-9a-f]{64}$'),
 source_facts jsonb NOT NULL CHECK(jsonb_typeof(source_facts)='object'),actor_id uuid NOT NULL REFERENCES users(id),
 actor_employee_id uuid NOT NULL REFERENCES employees(id),created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(application_id,submission_round,payment_id)
);
CREATE TRIGGER immutable_original_payment_proof BEFORE UPDATE OR DELETE ON finance_native_application_payment_proofs
 FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
CREATE TRIGGER no_truncate_original_payment_proof BEFORE TRUNCATE ON finance_native_application_payment_proofs
 FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
ALTER TABLE finance_native_application_payment_proofs ENABLE ALWAYS TRIGGER immutable_original_payment_proof;
ALTER TABLE finance_native_application_payment_proofs ENABLE ALWAYS TRIGGER no_truncate_original_payment_proof;
SELECT fn_audit_track_table('finance_native_application_payment_proofs','COLUMN_SCOPED','data_change',false,
 ARRAY['application_id','submission_round','payment_id','source_branch','amount_basis','source_fingerprint','actor_id','actor_employee_id','created_at'],true,NULL);
