-- Administrative applications are distinct from expense claims and payroll.
CREATE TABLE business_applications (
 id uuid PRIMARY KEY, application_no text NOT NULL UNIQUE,
 kind text NOT NULL CHECK(kind IN ('TRAVEL','PAYMENT','PREPAYMENT','SUPPLIER_PAYMENT')),
 title text NOT NULL CHECK(char_length(title) BETWEEN 1 AND 200),
 amount numeric(18,2) NOT NULL CHECK(amount>=0), fields jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(fields)='object'),
 supplier_id uuid REFERENCES suppliers(id) ON DELETE RESTRICT,
 applicant_id uuid NOT NULL REFERENCES employees(id), applicant_name text NOT NULL,
 department_id uuid NOT NULL REFERENCES departments(id), department_name text NOT NULL,
 status text NOT NULL DEFAULT 'DRAFT' CHECK(status IN('DRAFT','SUBMITTED','REVIEWING','REJECTED','APPROVED','PAID','COMPLETED','CANCELLED')),
 approval_stage text, round integer NOT NULL DEFAULT 0, version bigint NOT NULL DEFAULT 0,
 reject_reason text, submitted_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
 finance_document_id uuid, finance_document_type text,
 CHECK((status IN('SUBMITTED','REVIEWING','APPROVED'))=(approval_stage IS NOT NULL)),
 CHECK(kind<>'TRAVEL' OR status NOT IN('APPROVED','PAID')),
 CHECK((kind IN('SUPPLIER_PAYMENT','PREPAYMENT'))=(supplier_id IS NOT NULL)),
 CHECK(kind NOT IN('SUPPLIER_PAYMENT','PREPAYMENT') OR (fields->>'supplierId') IS NOT DISTINCT FROM supplier_id::text),
 CHECK(kind NOT IN('PREPAYMENT','SUPPLIER_PAYMENT') OR finance_document_type IS NULL OR finance_document_type='PAYMENT'),
 CHECK((finance_document_id IS NULL)=(finance_document_type IS NULL)),
 CHECK(kind IN('TRAVEL','PREPAYMENT') OR status<>'PAID' OR finance_document_id IS NOT NULL),
 CHECK(status<>'PAID' OR (fields->>'paymentDate' IS NOT NULL AND COALESCE(length(btrim(fields->>'paymentReference')),0)>0)),
 UNIQUE(finance_document_type,finance_document_id)
);
CREATE INDEX business_applications_mine ON business_applications(applicant_id,status,created_at DESC);
CREATE INDEX business_applications_pending ON business_applications(approval_stage,department_id,created_at) WHERE status IN('SUBMITTED','REVIEWING','APPROVED');
CREATE INDEX business_applications_supplier ON business_applications(supplier_id) WHERE supplier_id IS NOT NULL;
CREATE INDEX business_applications_prepayment_posting ON business_applications(created_at,id) WHERE kind='PREPAYMENT' AND status='PAID' AND finance_document_id IS NULL;
CREATE INDEX application_prepayment_finance_candidates ON finance_payments(supplier_id,amount_local,bill_date,id) WHERE status=1 AND NOT is_deleted;
INSERT INTO business_identifier_namespaces(namespace_key,identifier_family,fixed_prefix,source_table,identifier_column,discriminator_value)
VALUES('BUSINESS_APPLICATION','DOCUMENT','SQ','business_applications','application_no',NULL);
CREATE TRIGGER trg_business_document_applications BEFORE INSERT OR UPDATE OF application_no ON business_applications
FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier('BUSINESS_APPLICATION','application_no','');
CREATE TABLE business_application_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), application_id uuid NOT NULL REFERENCES business_applications(id),
 action text NOT NULL, actor_id uuid NOT NULL REFERENCES employees(id), actor_name text NOT NULL,
 stage text, remark text, round integer NOT NULL, occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX business_application_events_history ON business_application_events(application_id,occurred_at,id);
CREATE TABLE business_application_submissions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 application_id uuid NOT NULL REFERENCES business_applications(id),round integer NOT NULL,
 snapshot jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(application_id,round)
);
CREATE TRIGGER trg_audit_business_applications AFTER INSERT OR UPDATE OR DELETE ON business_applications FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_business_application_events AFTER INSERT OR UPDATE OR DELETE ON business_application_events FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_business_application_submissions AFTER INSERT OR UPDATE OR DELETE ON business_application_submissions FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE business_applications ENABLE ALWAYS TRIGGER trg_audit_business_applications;
ALTER TABLE business_application_events ENABLE ALWAYS TRIGGER trg_audit_business_application_events;
ALTER TABLE business_application_submissions ENABLE ALWAYS TRIGGER trg_audit_business_application_submissions;
INSERT INTO permissions(code,name,module,category,sort_order,action_type,description,grant_policy,high_risk,baseline) VALUES
 ('application:apply','填写行政财务申请','常用功能','我的申请',401,'CREATE','填写出差、付款、预付及供应商付款申请；不含工资申请',ARRAY['INDIVIDUAL_ONLY']::text[],false,false),
 ('application:apply:travel','填写出差申请','常用功能','我的申请',401,'CREATE','填写本人出差申请；须部门审核和总经办批准',ARRAY['INDIVIDUAL_ONLY']::text[],false,false),
 ('application:apply:payment','填写付款申请','常用功能','我的申请',401,'CREATE','填写普通付款申请',ARRAY['INDIVIDUAL_ONLY']::text[],false,false),
 ('application:apply:prepayment','填写预付申请','常用功能','我的申请',401,'CREATE','填写预付申请；保留预付目的和后续结算要求',ARRAY['INDIVIDUAL_ONLY']::text[],false,false),
 ('application:apply:supplier_payment','填写供应商付款申请','采购管理','我的申请',401,'CREATE','填写供应生产材料供应商付款申请；不替代普通付款或预付流程',ARRAY['INDIVIDUAL_ONLY']::text[],false,false),
 ('application:view','查看申请记录','常用功能','我的申请',402,'VIEW','查看本人申请及本人已处理的申请；不能扩大部门审核范围',ARRAY['INDIVIDUAL_ONLY']::text[],false,false),
 ('application:approve:department','审核本部门申请','部门审批','申请审批',403,'APPROVE','仅本部门范围负责人审核；不可自审或同轮兼任下一节点',ARRAY['INDIVIDUAL_ONLY']::text[],true,false),
 ('application:approve:procurement','采购部审核供应商付款申请','采购管理','申请审批',404,'APPROVE','供应商付款申请的采购意见节点',ARRAY['INDIVIDUAL_ONLY']::text[],true,false),
 ('application:approve:finance_initial','财务初核申请','财税管理','申请审批',405,'APPROVE','付款和预付申请的财务初核',ARRAY['INDIVIDUAL_ONLY']::text[],true,false),
 ('application:approve:finance_review','财务复核申请','财税管理','申请审批',406,'APPROVE','付款、预付、供应商付款申请的财务复核',ARRAY['INDIVIDUAL_ONLY']::text[],true,false),
 ('application:approve:vice_executive','副总审批供应商付款申请','总经办','申请审批',407,'APPROVE','供应商付款申请的副总审批',ARRAY['INDIVIDUAL_ONLY']::text[],true,false),
 ('application:approve:executive','总经办批准申请','总经办','申请审批',408,'APPROVE','出差、付款、预付和供应商付款的总经办批准',ARRAY['INDIVIDUAL_ONLY']::text[],true,false),
 ('application:receive','接收出差申请归档','财税管理','申请审批',409,'APPROVE','批准出差申请后由财务接收保管；不产生付款或财务过账',ARRAY['INDIVIDUAL_ONLY']::text[],false,false),
 ('application:pay','登记申请付款','财税管理','申请审批',410,'APPROVE','审批完成后登记真实付款和凭据；供应商预付的实际付款与财务入账分别记录，不重复过账',ARRAY['INDIVIDUAL_ONLY']::text[],true,false),
 ('application:prepayment:link_finance','关联供应商预付财务入账','财税管理','申请审批',411,'APPROVE','仅关联同供应商、金额、付款日的合法已审核预付款记录，不新建费用、不扣账户、不绕过原财务预付禁令',ARRAY['INDIVIDUAL_ONLY']::text[],true,false)
ON CONFLICT(code) DO NOTHING;
INSERT INTO permission_surfaces(id,surface_key,name,sort_order,enabled) VALUES
 ('10010000-0000-4000-8000-000000000001','common.applications','我的申请',401,true),
 ('10010000-0000-4000-8000-000000000002','applications.approval','申请审批',402,true)
ON CONFLICT(surface_key) DO NOTHING;
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT s.id,p.id FROM permission_surfaces s JOIN permissions p ON
 (s.surface_key='common.applications' AND p.code IN('application:apply','application:apply:travel','application:apply:payment','application:apply:prepayment','application:apply:supplier_payment','application:view')) OR
 (s.surface_key='applications.approval' AND p.code IN('application:view','application:approve:department','application:approve:procurement',
 'application:approve:finance_initial','application:approve:finance_review','application:approve:vice_executive','application:approve:executive','application:receive','application:pay','application:prepayment:link_finance'))
ON CONFLICT DO NOTHING;

WITH mapping(surface_key,permission_code) AS(VALUES
 ('department.approvals','application:approve:department'),
 ('approvals.center','application:approve:department'),
 ('approvals.center','application:approve:procurement'),
 ('approvals.center','application:approve:vice_executive'),
 ('approvals.center','application:approve:executive'),
 ('executive.tasks','application:approve:vice_executive'),
 ('executive.tasks','application:approve:executive'),
 ('finance.hub','application:approve:finance_initial'),
 ('finance.hub','application:approve:finance_review'),
 ('finance.hub','application:receive'),
 ('finance.hub','application:pay'))
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT s.id,p.id FROM mapping m JOIN permission_surfaces s ON s.surface_key=m.surface_key
JOIN permissions p ON p.code=m.permission_code ON CONFLICT DO NOTHING;
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT s.id,p.id FROM permission_surfaces s CROSS JOIN permissions p
WHERE s.surface_key='finance.hub' AND p.code='application:prepayment:link_finance' ON CONFLICT DO NOTHING;

-- A linked payment remains an accounting fact until its registration is
-- explicitly cancelled with a retained audit event. Never leave a PAID
-- application pointing at a reversed, deleted or materially changed posting.
CREATE FUNCTION fn_application_linked_finance_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE document_kind text;
BEGIN
 document_kind:=CASE TG_TABLE_NAME WHEN 'finance_payments' THEN 'PAYMENT' ELSE 'EXPENSE' END;
 IF EXISTS(SELECT 1 FROM business_applications WHERE status='PAID'
   AND finance_document_type=document_kind AND finance_document_id=OLD.id) THEN
  IF TG_OP='DELETE' THEN
   RAISE EXCEPTION '已关联申请付款登记，请先由原登记人撤销登记并保留原因' USING ERRCODE='23514';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted
    OR NEW.amount_local IS DISTINCT FROM OLD.amount_local OR NEW.bill_date IS DISTINCT FROM OLD.bill_date
    OR NEW.account_id IS DISTINCT FROM OLD.account_id
    OR (document_kind='PAYMENT' AND to_jsonb(NEW)->'supplier_id' IS DISTINCT FROM to_jsonb(OLD)->'supplier_id') THEN
   RAISE EXCEPTION '已关联申请付款登记，请先由原登记人撤销登记并保留原因' USING ERRCODE='23514';
  END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;
DO $$
DECLARE target text;
BEGIN
 FOREACH target IN ARRAY ARRAY['finance_payments','finance_expenses'] LOOP
  IF to_regclass(target) IS NOT NULL THEN
   EXECUTE format('CREATE TRIGGER application_linked_finance_guard BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_application_linked_finance_guard()',target);
  END IF;
 END LOOP;
END;
$$;

-- Plain-language help mirrors permission-help.json; this changes presentation only.
UPDATE permissions p SET name=h.name,description=h.description FROM (VALUES
 ('application:apply','填写行政财务申请','能做什么：填写出差、付款、预付及供应商付款申请；不含工资申请。

范围与限制：本人申请、负责范围和单据状态继续单独核对，填写或查看不自动获得审批、付款或他人申请数据的查看权限。

提醒和待办：仅按本人已授权且当前可办理的节点显示待办，已处理、撤回和驳回后同步数量。

例如：经办人保存本人申请草稿，补齐依据后按指定流程提交。'),
 ('application:apply:travel','填写出差申请','能做什么：填写本人出差申请；须部门审核和总经办批准。

范围与限制：本人申请、负责范围和单据状态继续单独核对，填写或查看不自动获得审批、付款或他人申请数据的查看权限。

提醒和待办：仅按本人已授权且当前可办理的节点显示待办，已处理、撤回和驳回后同步数量。

例如：经办人保存本人申请草稿，补齐依据后按指定流程提交。'),
 ('application:apply:payment','填写付款申请','能做什么：填写普通付款申请。

范围与限制：本人申请、负责范围和单据状态继续单独核对，填写或查看不自动获得审批、付款或他人申请数据的查看权限。

提醒和待办：仅按本人已授权且当前可办理的节点显示待办，已处理、撤回和驳回后同步数量。

例如：经办人保存本人申请草稿，补齐依据后按指定流程提交。'),
 ('application:apply:prepayment','填写预付申请','能做什么：填写预付申请；保留预付目的和后续结算要求。

范围与限制：本人申请、负责范围和单据状态继续单独核对，填写或查看不自动获得审批、付款或他人申请数据的查看权限。

提醒和待办：仅按本人已授权且当前可办理的节点显示待办，已处理、撤回和驳回后同步数量。

例如：经办人保存本人申请草稿，补齐依据后按指定流程提交。'),
 ('application:apply:supplier_payment','填写供应商付款申请','能做什么：填写供应生产材料供应商付款申请；不替代普通付款或预付流程。

范围与限制：本人申请、负责范围和单据状态继续单独核对，填写或查看不自动获得审批、付款或他人申请数据的查看权限。

提醒和待办：仅按本人已授权且当前可办理的节点显示待办，已处理、撤回和驳回后同步数量。

例如：经办人保存本人申请草稿，补齐依据后按指定流程提交。'),
 ('application:view','查看申请记录','能做什么：查看本人申请及本人已处理的申请；不能扩大部门审核范围。

范围与限制：本人申请、负责范围和单据状态继续单独核对，填写或查看不自动获得审批、付款或他人申请数据的查看权限。

提醒和待办：仅按本人已授权且当前可办理的节点显示待办，已处理、撤回和驳回后同步数量。

例如：经办人保存本人申请草稿，补齐依据后按指定流程提交。'),
 ('application:approve:department','审核本部门申请','能做什么：仅本部门范围负责人审核；不可自审或同轮兼任下一节点。

范围与限制：只能处理当前审批节点和负责部门范围，不可自审、越级或同轮兼任多个节点；驳回必须填写原因。

提醒和待办：仅按本人已授权且当前可办理的节点显示待办，已处理、撤回和驳回后同步数量。

例如：负责人核对申请内容与附件后通过，或填写原因退回经办人修订重提。'),
 ('application:approve:procurement','采购部审核供应商付款申请','能做什么：供应商付款申请的采购意见节点。

范围与限制：只能处理当前审批节点和负责部门范围，不可自审、越级或同轮兼任多个节点；驳回必须填写原因。

提醒和待办：仅按本人已授权且当前可办理的节点显示待办，已处理、撤回和驳回后同步数量。

例如：负责人核对申请内容与附件后通过，或填写原因退回经办人修订重提。'),
 ('application:approve:finance_initial','财务初核申请','能做什么：付款和预付申请的财务初核。

范围与限制：只能处理当前审批节点和负责部门范围，不可自审、越级或同轮兼任多个节点；驳回必须填写原因。

提醒和待办：仅按本人已授权且当前可办理的节点显示待办，已处理、撤回和驳回后同步数量。

例如：负责人核对申请内容与附件后通过，或填写原因退回经办人修订重提。'),
 ('application:approve:finance_review','财务复核申请','能做什么：付款、预付、供应商付款申请的财务复核。

范围与限制：只能处理当前审批节点和负责部门范围，不可自审、越级或同轮兼任多个节点；驳回必须填写原因。

提醒和待办：仅按本人已授权且当前可办理的节点显示待办，已处理、撤回和驳回后同步数量。

例如：负责人核对申请内容与附件后通过，或填写原因退回经办人修订重提。'),
 ('application:approve:vice_executive','副总审批供应商付款申请','能做什么：供应商付款申请的副总审批。

范围与限制：只能处理当前审批节点和负责部门范围，不可自审、越级或同轮兼任多个节点；驳回必须填写原因。

提醒和待办：仅按本人已授权且当前可办理的节点显示待办，已处理、撤回和驳回后同步数量。

例如：负责人核对申请内容与附件后通过，或填写原因退回经办人修订重提。'),
 ('application:approve:executive','总经办批准申请','能做什么：出差、付款、预付和供应商付款的总经办批准。

范围与限制：只能处理当前审批节点和负责部门范围，不可自审、越级或同轮兼任多个节点；驳回必须填写原因。

提醒和待办：仅按本人已授权且当前可办理的节点显示待办，已处理、撤回和驳回后同步数量。

例如：负责人核对申请内容与附件后通过，或填写原因退回经办人修订重提。'),
 ('application:receive','接收出差申请归档','能做什么：批准出差申请后由财务接收保管；不产生付款或财务过账。

范围与限制：只能接收总经办已经批准的出差申请并保留归档记录，不产生付款，不代替报销审核。

提醒和待办：仅按本人已授权且当前可办理的节点显示待办，已处理、撤回和驳回后同步数量。

例如：财务接收已批准的出差申请，供后续核对和装订归档。'),
 ('application:pay','登记申请付款','能做什么：审批完成后核对并关联已审核财务单和付款凭据，不重复过账。

范围与限制：仅登记实际已经支付且财务单已审核的付款凭据，关联同一申请和真实财务记录，不向银行发起支付，不重复记账。

提醒和待办：仅按本人已授权且当前可办理的节点显示待办，已处理、撤回和驳回后同步数量。

例如：财务完成银行付款后关联已审核的财务单和付款回单。')
) h(code,name,description) WHERE p.code=h.code;

-- Supplier prepayment finance-link permission help mirrors the reviewed catalog.
UPDATE permissions SET name='关联供应商预付财务入账',description=E'能做什么：在供应商预付申请完成实际付款登记后，核对并关联同一供应商、同金额、同支付日期且已审核的合法预付财务记录。\n\n范围与限制：仅登记真实关联，不新建费用，不重复扣减账户，不绕过供应商预付新入账禁令；与登记实际付款分别授权，付款证明仍须通过扫描确认。\n\n提醒和待办：只有本人能办理且存在合法可关联记录时计入待办；已经付款但尚无合法财务记录时显示待财务入账，不把付款事实当作会计已入账。\n\n例如：核对已审核的供应商预付财务记录和银行回单后，将它关联到对应预付申请。' WHERE code='application:prepayment:link_finance';

-- Supplier-only prepayment purpose, as confirmed by the requester.
UPDATE permissions SET description=E'能做什么：填写供应商预付申请，供应商必填，记录预付用途和相应依据。\n\n范围与限制：本流程仅用于供应商预付，不支持员工个人借款或预支；填写或提交不自动获得审批、登记实际付款或财务入账权限。\n\n提醒和待办：按本人申请及当前已授权的办理节点显示待办；已登记付款仍须区分待财务入账，不把付款事实登记当作会计已入账。\n\n例如：采购经办人填写某供应商的采购预付款用途，获批后由财务登记实际付款，再按独立权限关联合法财务记录。' WHERE code='application:apply:prepayment';

-- Payment fact registration and prepayment accounting linkage have separate authority.
UPDATE permissions SET description=E'能做什么：为已批准的申请登记实际付款。普通付款和供应商付款核对并关联合法已审核财务单与付款凭据；供应商预付只登记实际支付日期、银行流水号和扫描确认的付款证明。\n\n范围与限制：供应商预付付款登记不新建费用、不扣减系统账户、不代替财务入账；后续关联合法预付财务记录须另获对应权限，不绕过原财务预付新入账禁令。申请人与本轮已审核人员不能付款。\n\n提醒和待办：仅当前可由本人办理的已批准申请进入付款待办；供应商预付登记后仍明确显示已付款待财务入账，合法关联另行办结。\n\n例如：出纳按真实银行回单登记已批准的供应商预付款日期与流水，申请保留待财务入账，由另行授权的财务人员关联合法账记录。' WHERE code='application:pay';
