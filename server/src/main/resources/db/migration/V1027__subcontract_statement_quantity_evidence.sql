-- Financial original-statement sources; never warehouse quantity, cost or ERP consumption updates.
CREATE TABLE finance_subcontract_quantity_evidence (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),request_id uuid NOT NULL UNIQUE,
 scope_key text NOT NULL CHECK(scope_key~'^[0-9a-f]{64}$'),statement_key text NOT NULL CHECK(statement_key~'^[0-9a-f]{64}$'),revision bigint NOT NULL CHECK(revision>=0),
 supplier_id uuid NOT NULL REFERENCES suppliers(id),date_from date NOT NULL,date_to date NOT NULL CHECK(date_to>=date_from),
 purpose text NOT NULL CHECK(purpose IN('ROW_CORRESPONDENCE','PERIOD_OPENING','PERIOD_ENDING')),
 evidence_type text NOT NULL CHECK(evidence_type IN('BILATERAL_SETTLEMENT_EQUIVALENCE','RECEIPT_USAGE_DOCUMENT','PHYSICAL_COUNT')),
 source_kind text CHECK(source_kind IN('MATERIAL_ISSUE','MATERIAL_RETURN','RECEIPT','PRODUCT_RETURN')),source_item_id uuid,
 material_issue_item_id uuid REFERENCES subcontract_material_issue_items(id),
 goods_id uuid NOT NULL REFERENCES goods(id),color_id uuid REFERENCES colors(id),pcs_unit_id uuid NOT NULL REFERENCES units(id),
 quantity_pcs numeric NOT NULL CHECK(quantity_pcs>=0 AND fn_financial_amount_is_exact(quantity_pcs)),
 evidence_date date NOT NULL,enabled boolean NOT NULL,apply_to_statement boolean NOT NULL,
 source_reference text NOT NULL CHECK(length(btrim(source_reference)) BETWEEN 1 AND 2000),
 input_json jsonb NOT NULL CHECK(jsonb_typeof(input_json)='object'),precision_policy jsonb NOT NULL CHECK(jsonb_typeof(precision_policy)='object'),source_json jsonb,material_source_json jsonb,
 book_estimated_pcs numeric,book_estimate_basis text NOT NULL,
 attachment_metadata jsonb,attachment_reference jsonb,
 payload_hash text NOT NULL CHECK(payload_hash~'^[0-9a-f]{64}$'),
 status text NOT NULL DEFAULT 'SUBMITTED' CHECK(status IN('SUBMITTED','APPROVED','REJECTED')),
 submitted_by uuid NOT NULL REFERENCES users(id),submitted_at timestamptz NOT NULL DEFAULT now(),
 reviewed_by uuid REFERENCES users(id),reviewed_at timestamptz,review_reason text,
 CHECK((purpose='ROW_CORRESPONDENCE' AND source_kind IS NOT NULL AND source_item_id IS NOT NULL AND source_json IS NOT NULL) OR(purpose<>'ROW_CORRESPONDENCE' AND source_kind IS NULL AND source_item_id IS NULL AND source_json IS NULL)),
 CHECK(purpose='ROW_CORRESPONDENCE' OR evidence_type='PHYSICAL_COUNT'),
 CHECK((attachment_metadata IS NULL)=(attachment_reference IS NULL)),
 CHECK((status='SUBMITTED')=(reviewed_by IS NULL AND reviewed_at IS NULL AND review_reason IS NULL)),
 CHECK(reviewed_by IS NULL OR reviewed_by<>submitted_by),UNIQUE(scope_key,revision)
);
CREATE INDEX finance_subcontract_quantity_scope ON finance_subcontract_quantity_evidence(supplier_id,date_from,date_to,purpose);
CREATE VIEW v_finance_subcontract_quantity_evidence_current AS
 SELECT DISTINCT ON(scope_key)* FROM finance_subcontract_quantity_evidence WHERE status='APPROVED' ORDER BY scope_key,revision DESC;
CREATE FUNCTION fn_guard_finance_subcontract_quantity_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION '原表数量证据不可删除，请提交新受审停用版本' USING ERRCODE='23514';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('uten:subcontract-quantity:'||NEW.statement_key,1027));
 IF NOT EXISTS(SELECT 1 FROM units WHERE id=NEW.pcs_unit_id AND upper(btrim(code))='PCS') THEN
  RAISE EXCEPTION '原表PCS须选择真实PCS单位，不能按名称或单位前缀猜配' USING ERRCODE='23514';END IF;
 IF NEW.quantity_pcs IS DISTINCT FROM fn_business_exact_divide_with_policy((NEW.input_json->>'quantityPcs')::numeric,1,
  'finance.subcontract.statement-pcs','本次原表数量证据PCS采用量',24,NEW.precision_policy,false) THEN
  RAISE EXCEPTION '采用PCS量须对应保留的原输入及本次明确精度选择' USING ERRCODE='23514';END IF;
 IF TG_OP='INSERT' THEN
  IF NEW.status<>'SUBMITTED' OR NEW.reviewed_by IS NOT NULL OR NEW.revision<>(SELECT COALESCE(max(previous.revision),-1)+1 FROM finance_subcontract_quantity_evidence previous WHERE previous.scope_key=NEW.scope_key) THEN
   RAISE EXCEPTION '须保留原数量证据并提交下一版本，再由另一人审核' USING ERRCODE='23514';END IF;
 ELSIF OLD.status<>'SUBMITTED' OR NEW.status NOT IN('APPROVED','REJECTED') OR NEW.reviewed_by IS NULL OR NEW.reviewed_at IS NULL
    OR length(btrim(COALESCE(NEW.review_reason,''))) NOT BETWEEN 1 AND 2000
    OR(to_jsonb(NEW)-ARRAY['status','reviewed_by','reviewed_at','review_reason']) IS DISTINCT FROM(to_jsonb(OLD)-ARRAY['status','reviewed_by','reviewed_at','review_reason']) THEN
  RAISE EXCEPTION '原数量、来源、附件与依据不可覆盖，只可审核原版本或提交新版本' USING ERRCODE='23514';
 END IF;
 IF NEW.status='APPROVED' AND EXISTS(SELECT 1 FROM finance_subcontract_quantity_evidence later WHERE later.scope_key=NEW.scope_key AND later.revision>NEW.revision) THEN
  RAISE EXCEPTION '原表数量证据已有后续版本，请读取最新原提交' USING ERRCODE='23514';END IF;
 IF NEW.status='APPROVED' AND NEW.enabled AND NEW.apply_to_statement AND EXISTS(
  SELECT 1 FROM v_finance_subcontract_quantity_evidence_current other WHERE other.statement_key=NEW.statement_key
    AND other.scope_key<>NEW.scope_key AND other.enabled AND other.apply_to_statement) THEN
  RAISE EXCEPTION '同一原行或实盘范围已有原表采用来源；请先受审取消原采用，不按证据类型或时间自动替换' USING ERRCODE='23514';END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER finance_subcontract_quantity_evidence_guard BEFORE INSERT OR UPDATE OR DELETE ON finance_subcontract_quantity_evidence
 FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_subcontract_quantity_evidence();
SELECT fn_audit_track_table('finance_subcontract_quantity_evidence','COLUMN_SCOPED','data_change',false,
 ARRAY['id','request_id','scope_key','statement_key','revision','supplier_id','date_from','date_to','purpose','evidence_type','source_kind','source_item_id','material_issue_item_id','goods_id','color_id','pcs_unit_id','status','enabled','apply_to_statement','submitted_by','reviewed_by'],true,NULL);
