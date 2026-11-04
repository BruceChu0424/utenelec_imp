-- Original six request paths. They are approval intents, never another money ledger.
CREATE TABLE finance_application_settings (
    id smallint PRIMARY KEY CHECK(id=1),enabled boolean NOT NULL DEFAULT false,
    enabled_at timestamptz,row_version bigint NOT NULL DEFAULT 0,
    source_reference text NOT NULL DEFAULT '',updated_at timestamptz NOT NULL DEFAULT now(),updated_by uuid REFERENCES users(id),
    CHECK(NOT enabled OR enabled_at IS NOT NULL)
);
INSERT INTO finance_application_settings(id) VALUES(1);
CREATE TABLE finance_application_enable_periods (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),enabled_at timestamptz NOT NULL,disabled_at timestamptz,
    actor_id uuid NOT NULL REFERENCES users(id),source_reference text NOT NULL,
    CHECK(disabled_at IS NULL OR disabled_at>=enabled_at)
);
CREATE UNIQUE INDEX finance_application_one_enable_period ON finance_application_enable_periods((true)) WHERE disabled_at IS NULL;
CREATE TABLE finance_application_role_bindings (
    id uuid PRIMARY KEY,role_key text NOT NULL CHECK(role_key IN('DEPARTMENT_REVIEW','TRAVEL_APPROVAL','FINANCE_CUSTODY','FINANCE_REVIEW_1','FINANCE_REVIEW_2','MANAGEMENT_PAYMENT')),
    department_id uuid REFERENCES departments(id),employee_id uuid NOT NULL REFERENCES employees(id),
    source_reference text NOT NULL CHECK(length(btrim(source_reference))>=4),
    row_version bigint NOT NULL DEFAULT 0,updated_at timestamptz NOT NULL DEFAULT now(),updated_by uuid NOT NULL REFERENCES users(id)
);
CREATE UNIQUE INDEX finance_application_role_person_unique ON finance_application_role_bindings(role_key,COALESCE(department_id,'00000000-0000-0000-0000-000000000000'::uuid),employee_id);
CREATE TABLE finance_applications (
    id uuid PRIMARY KEY,application_no text NOT NULL UNIQUE,
    kind text NOT NULL CHECK(kind IN('TRAVEL_APPLICATION','TRAVEL_REIMBURSEMENT','REIMBURSEMENT','PAYMENT_APPLICATION','PREPAYMENT_APPLICATION','PAYROLL_PAYMENT')),
    source_kind text NOT NULL CHECK(source_kind IN('TRAVEL_PLAN','EXPENSE_CLAIM','PAYMENT_INTENT','PAYROLL_BATCH')),
    source_id uuid,applicant_id uuid NOT NULL REFERENCES employees(id),applicant_name_snapshot text NOT NULL,
    department_id uuid REFERENCES departments(id),department_name_snapshot text NOT NULL DEFAULT '',
    title text NOT NULL CHECK(length(btrim(title)) BETWEEN 1 AND 200),remark text NOT NULL DEFAULT '',
    travel_application_id uuid REFERENCES finance_applications(id),requested_date date NOT NULL,
    requested_payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(requested_payload)='object'),
    source_snapshot jsonb,previous_source_snapshot jsonb,source_fingerprint text,
    amount_original numeric CHECK(amount_original IS NULL OR fn_financial_amount_is_exact(amount_original)),currency_id uuid REFERENCES currencies(id),
    status text NOT NULL DEFAULT 'DRAFT' CHECK(status IN('DRAFT','SUBMITTED','REVIEWING','APPROVED','ARCHIVED','REJECTED','EXECUTED','CONFIRMED','REVERSED')),
    current_step integer,submission_round integer NOT NULL DEFAULT 0,
    submitted_at timestamptz,approved_at timestamptz,approved_by uuid REFERENCES employees(id),approved_name_snapshot text,
    native_doc_type text,native_doc_id uuid,payroll_instruction jsonb,payroll_instruction_fingerprint text,
    row_version bigint NOT NULL DEFAULT 0,request_fingerprint text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid NOT NULL REFERENCES users(id),updated_by uuid NOT NULL REFERENCES users(id),
    CHECK(amount_original IS NULL OR amount_original>=0),CHECK(source_fingerprint IS NULL OR source_fingerprint ~ '^[0-9a-f]{64}$'),
    CHECK(kind<>'TRAVEL_REIMBURSEMENT' OR travel_application_id IS NOT NULL)
);
CREATE UNIQUE INDEX finance_application_expense_source_unique ON finance_applications(source_kind,source_id) WHERE source_kind='EXPENSE_CLAIM';
CREATE INDEX finance_application_owner_status ON finance_applications(applicant_id,status,created_at,id);
CREATE TABLE finance_application_nodes (
    application_id uuid NOT NULL REFERENCES finance_applications(id),submission_round integer NOT NULL,step_no integer NOT NULL,
    role_key text NOT NULL,label_snapshot text NOT NULL,action text NOT NULL CHECK(action IN('APPROVE','ARCHIVE')),
    assignees jsonb NOT NULL CHECK(jsonb_typeof(assignees)='array'),
    status text NOT NULL DEFAULT 'PENDING' CHECK(status IN('PENDING','APPROVED','ARCHIVED','REJECTED','WITHDRAWN')),
    decided_by uuid REFERENCES employees(id),decided_name_snapshot text,decided_at timestamptz,reason text NOT NULL DEFAULT '',
    PRIMARY KEY(application_id,submission_round,step_no)
);
CREATE TABLE finance_application_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),application_id uuid NOT NULL REFERENCES finance_applications(id),
    submission_round integer NOT NULL,event_type text NOT NULL,step_no integer,
    actor_id uuid NOT NULL REFERENCES users(id),actor_employee_id uuid NOT NULL REFERENCES employees(id),actor_name_snapshot text NOT NULL,
    detail jsonb NOT NULL DEFAULT '{}'::jsonb,occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX finance_application_events_source ON finance_application_events(application_id,occurred_at,id);
CREATE TABLE finance_application_operations (
    request_id uuid PRIMARY KEY,application_id uuid NOT NULL REFERENCES finance_applications(id),actor_id uuid NOT NULL REFERENCES users(id),
    operation text NOT NULL,payload_hash text NOT NULL CHECK(payload_hash ~ '^[0-9a-f]{64}$'),result jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE finance_application_executions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),application_id uuid NOT NULL REFERENCES finance_applications(id),submission_round integer NOT NULL,
    request_id uuid NOT NULL UNIQUE,doc_type text NOT NULL,doc_id uuid NOT NULL,
    state text NOT NULL CHECK(state IN('PREPARING','POSTED_PENDING_CONFIRMATION','CONFIRMED','REVERSED')),
    result jsonb NOT NULL DEFAULT '{}'::jsonb,paid_by uuid NOT NULL REFERENCES employees(id),paid_name_snapshot text NOT NULL,
    paid_at timestamptz NOT NULL DEFAULT now(),confirmed_by uuid REFERENCES employees(id),confirmed_name_snapshot text,confirmed_at timestamptz,
    reversed_by uuid REFERENCES employees(id),reversed_name_snapshot text,reversed_at timestamptz,
    UNIQUE(doc_type,doc_id)
);
CREATE UNIQUE INDEX finance_application_one_live_execution ON finance_application_executions(application_id) WHERE state<>'REVERSED';
CREATE TABLE finance_expense_application_links (
    claim_id uuid PRIMARY KEY REFERENCES expense_claims(id),kind text NOT NULL CHECK(kind IN('REIMBURSEMENT','TRAVEL_REIMBURSEMENT')),
    travel_application_id uuid REFERENCES finance_applications(id),application_id uuid REFERENCES finance_applications(id),
    created_at timestamptz NOT NULL DEFAULT now(),created_by uuid NOT NULL REFERENCES users(id)
);

CREATE FUNCTION fn_finance_application_events_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Application decisions and operation receipts are immutable; append a new event' USING ERRCODE='23514';END;
$$;
CREATE TRIGGER finance_application_events_immutable BEFORE UPDATE OR DELETE ON finance_application_events FOR EACH ROW EXECUTE FUNCTION fn_finance_application_events_immutable();
CREATE TRIGGER finance_application_operations_immutable BEFORE UPDATE OR DELETE ON finance_application_operations FOR EACH ROW EXECUTE FUNCTION fn_finance_application_events_immutable();
CREATE FUNCTION fn_guard_finance_application_source() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.id<>OLD.id OR NEW.application_no<>OLD.application_no OR NEW.applicant_id<>OLD.applicant_id OR NEW.source_kind<>OLD.source_kind OR NEW.kind<>OLD.kind OR NEW.created_at<>OLD.created_at THEN
        RAISE EXCEPTION '申请身份不能被替换' USING ERRCODE='23514';
    END IF;
    IF OLD.status NOT IN('DRAFT','REJECTED','REVERSED') AND
       (NEW.requested_payload IS DISTINCT FROM OLD.requested_payload OR NEW.amount_original IS DISTINCT FROM OLD.amount_original
        OR NEW.currency_id IS DISTINCT FROM OLD.currency_id OR NEW.source_id IS DISTINCT FROM OLD.source_id
        OR NEW.requested_date IS DISTINCT FROM OLD.requested_date OR NEW.remark IS DISTINCT FROM OLD.remark
        OR NEW.department_id IS DISTINCT FROM OLD.department_id OR NEW.title IS DISTINCT FROM OLD.title OR NEW.travel_application_id IS DISTINCT FROM OLD.travel_application_id) THEN
        RAISE EXCEPTION '已提交申请的原始内容已冻结，请先撤回或退回后修订' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER finance_application_source_guard BEFORE UPDATE ON finance_applications FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_application_source();
CREATE FUNCTION fn_guard_finance_application_decided_node() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status<>'PENDING' THEN RAISE EXCEPTION '已作出的节点决定不能覆盖' USING ERRCODE='23514';END IF;
    IF NEW.application_id<>OLD.application_id OR NEW.submission_round<>OLD.submission_round OR NEW.step_no<>OLD.step_no OR NEW.role_key<>OLD.role_key OR NEW.label_snapshot<>OLD.label_snapshot OR NEW.action<>OLD.action THEN
        RAISE EXCEPTION '原审批步骤不能被替换' USING ERRCODE='23514';
    END IF;RETURN NEW;
END;
$$;
CREATE TRIGGER finance_application_decided_node_guard BEFORE UPDATE ON finance_application_nodes FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_application_decided_node();
INSERT INTO permissions(code,name,module,category,sort_order,action_type,description) VALUES
 ('finance_application:view','查看各部门申请流程','财税管理','各部门申请流程',801,'VIEW','查看本人、明确指派或已处理的申请；不因此开放全部员工薪资和公司报销'),
 ('finance_application:apply','填写付款及预付申请','财税管理','各部门申请流程',802,'CREATE','填写真实支付前申请，不会因此扣款或生成费用'),
 ('finance_application:review','办理指派的申请节点','财税管理','各部门申请流程',803,'APPROVE','只办理本单当前明确指派的部门、财务或总经办节点，不能越级或审批本人申请'),
 ('finance_application:execute','登记已批准申请的实际付款','财税管理','各部门申请流程',804,'EXECUTE','批准支付之后按真实回单登记付款，仍要求原付款/费用/工资执行资格，不能重复支付'),
 ('finance_application:confirm','财务确认申请付款分录','财税管理','各部门申请流程',805,'EXECUTE','确认既有实际付款和凭证，不会重新计薪、计费用或扣款'),
 ('finance_application:reverse','反审申请的实际付款','财税管理','各部门申请流程',806,'EXECUTE','沿原付款依赖和账期保护对称反审，保留原申请、节点和回执历史')
ON CONFLICT(code) DO NOTHING;
INSERT INTO permission_surfaces(id,surface_key,name,sort_order,enabled)
VALUES('f19a0001-0000-4000-8000-000000000001','finance.applications','各部门申请流程',80,true)
ON CONFLICT(surface_key) DO NOTHING;
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT s.id,p.id FROM permission_surfaces s CROSS JOIN permissions p
WHERE s.surface_key='finance.applications' AND (p.code LIKE 'finance_application:%' OR p.code='expense:settings') ON CONFLICT DO NOTHING;
-- New business authorities are explicitly assigned; never grant all department heads the old company-wide expense pool.
INSERT INTO business_identifier_namespaces(namespace_key,identifier_family,fixed_prefix,source_table,identifier_column,discriminator_value)
VALUES('FIN_APPLICATION','DOCUMENT','FQ','finance_applications','application_no',NULL);
CREATE TRIGGER finance_application_identifier BEFORE INSERT OR UPDATE OF application_no ON finance_applications
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('FIN_APPLICATION','application_no','');

-- Preserve ordinary expense semantics. Only an explicit manufacturing-cost purpose can
-- consume an existing ACCOUNT leaf proved by the reviewed 4101 mapping; no parallel chart.
ALTER TABLE finance_expense_items ADD COLUMN posting_purpose text NOT NULL DEFAULT 'ORDINARY_EXPENSE'
    CHECK(posting_purpose IN('ORDINARY_EXPENSE','MANUFACTURING_COST'));
ALTER TABLE expense_claims ADD COLUMN payment_posting_purpose text NOT NULL DEFAULT 'ORDINARY_EXPENSE'
    CHECK(payment_posting_purpose IN('ORDINARY_EXPENSE','MANUFACTURING_COST'));
CREATE FUNCTION fn_finance_expense_posting_style_allowed(p_id uuid,p_purpose text,p_active boolean DEFAULT true)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT fn_finance_cost_expense_style_allowed(s.id) AND (NOT p_active OR s.status='使用')
        AND ((p_purpose='ORDINARY_EXPENSE' AND s.category='EXPENSE') OR (p_purpose='MANUFACTURING_COST' AND s.category='ACCOUNT'))
        FROM payment_styles s WHERE s.id=p_id),false);
$$;
CREATE FUNCTION fn_guard_typed_expense_posting_style() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE style uuid; purpose text; old_style uuid; old_purpose text;
BEGIN
    IF TG_TABLE_NAME='expense_claims' THEN style:=NEW.payment_expense_style_id;purpose:=NEW.payment_posting_purpose;
        IF TG_OP='UPDATE' THEN old_style:=OLD.payment_expense_style_id;old_purpose:=OLD.payment_posting_purpose;END IF;
    ELSE style:=NEW.expense_style_id;purpose:=NEW.posting_purpose;
        IF TG_OP='UPDATE' THEN old_style:=OLD.expense_style_id;old_purpose:=OLD.posting_purpose;END IF;
    END IF;
    IF style IS NULL OR (TG_OP='UPDATE' AND style IS NOT DISTINCT FROM old_style AND purpose IS NOT DISTINCT FROM old_purpose) THEN RETURN NEW;END IF;
    PERFORM pg_advisory_xact_lock_shared(hashtextextended('PAYMENT_STYLE_HIERARCHY',0));
    IF NOT fn_finance_expense_posting_style_allowed(style,purpose,true) THEN RAISE EXCEPTION '普通费用/制造成本支出科目与明确用途不一致或科目未核验' USING ERRCODE='23514';END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER trg_psref_expense_item ON finance_expense_items;
DROP TRIGGER trg_psref_claim_payment ON expense_claims;
CREATE TRIGGER trg_psref_expense_item BEFORE INSERT OR UPDATE OF expense_style_id,posting_purpose ON finance_expense_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_typed_expense_posting_style();
CREATE TRIGGER trg_psref_claim_payment BEFORE INSERT OR UPDATE OF payment_expense_style_id,payment_posting_purpose ON expense_claims
    FOR EACH ROW EXECUTE FUNCTION fn_guard_typed_expense_posting_style();
ALTER TABLE expense_claim_events DROP CONSTRAINT expense_claim_events_type_chk;
ALTER TABLE expense_claim_events ADD CONSTRAINT expense_claim_events_type_chk CHECK(event_type IN(
    'CREATED','SUBMITTED','WITHDRAWN','EDITED','APPROVED','REJECTED','PAID','PAYMENT_REVERSED'));
CREATE FUNCTION fn_finance_expense_is_application_managed(p_id uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM finance_expense_application_links WHERE claim_id=p_id AND application_id IS NOT NULL);
$$;
-- Salary/application payloads and bank-proof names remain in purpose-authorized records.
-- General audit readers receive only immutable identities, decisions and fingerprints.
SELECT fn_audit_track_table('finance_application_settings','COLUMN_SCOPED','authorization',false,ARRAY['id','enabled','enabled_at','updated_by'],true,NULL);
SELECT fn_audit_track_table('finance_application_enable_periods','COLUMN_SCOPED','authorization',false,ARRAY['id','enabled_at','disabled_at','actor_id'],true,NULL);
SELECT fn_audit_track_table('finance_application_role_bindings','COLUMN_SCOPED','authorization',false,ARRAY['id','role_key','department_id','employee_id','updated_by'],true,NULL);
SELECT fn_audit_track_table('finance_applications','COLUMN_SCOPED','data_change',false,ARRAY['id','application_no','kind','source_kind','source_id','status','current_step','submission_round','source_fingerprint','payroll_instruction_fingerprint','submitted_at','approved_at','approved_by','created_by','updated_by'],true,NULL);
SELECT fn_audit_track_table('finance_application_nodes','COLUMN_SCOPED','data_change',false,ARRAY['application_id','submission_round','step_no','role_key','action','status','decided_by','decided_at'],true,NULL);
SELECT fn_audit_track_table('finance_application_events','COLUMN_SCOPED','data_change',false,ARRAY['id','application_id','submission_round','event_type','step_no','actor_id','actor_employee_id','occurred_at'],true,NULL);
SELECT fn_audit_track_table('finance_application_operations','COLUMN_SCOPED','data_change',false,ARRAY['request_id','application_id','actor_id','operation','payload_hash','created_at'],true,NULL);
SELECT fn_audit_track_table('finance_application_executions','COLUMN_SCOPED','data_change',false,ARRAY['id','application_id','submission_round','request_id','doc_type','doc_id','state','paid_by','paid_at','confirmed_by','confirmed_at','reversed_by','reversed_at'],true,NULL);
SELECT fn_audit_track_table('finance_expense_application_links','COLUMN_SCOPED','data_change',false,ARRAY['claim_id','kind','travel_application_id','application_id','created_by'],true,NULL);
