-- Physical loss allowances are independent of the processing-price currency.
-- A reviewed SKU/unit/period rule must not change between CNY and USD copies of
-- the same physical statement. Historical versions remain immutable evidence.
CREATE TABLE finance_subcontract_loss_policies (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),request_id uuid NOT NULL UNIQUE,
 supplier_id uuid NOT NULL REFERENCES suppliers(id),goods_id uuid NOT NULL REFERENCES goods(id),
 color_id uuid REFERENCES colors(id),unit_id uuid NOT NULL REFERENCES units(id),
 effective_from date NOT NULL,effective_to date,
 revision bigint NOT NULL CHECK(revision>=0),
 rate_percent_original numeric NOT NULL CHECK(rate_percent_original>=0 AND rate_percent_original<=100),
 precision_policy jsonb NOT NULL CHECK(jsonb_typeof(precision_policy)='object'),
 rate numeric NOT NULL CHECK(rate>=0 AND rate<=1 AND fn_financial_amount_is_exact(rate)),
 enabled boolean NOT NULL DEFAULT true,status text NOT NULL DEFAULT 'SUBMITTED' CHECK(status IN('SUBMITTED','APPROVED','REJECTED')),
 source_reference text NOT NULL CHECK(length(btrim(source_reference)) BETWEEN 1 AND 2000),
 fingerprint text NOT NULL CHECK(fingerprint~'^[0-9a-f]{64}$'),
 submitted_by uuid NOT NULL REFERENCES users(id),submitted_at timestamptz NOT NULL DEFAULT now(),
 reviewed_by uuid REFERENCES users(id),reviewed_at timestamptz,review_reason text,
 CHECK(effective_to IS NULL OR effective_to>=effective_from),
 CHECK((status='SUBMITTED')=(reviewed_by IS NULL AND reviewed_at IS NULL AND review_reason IS NULL)),
 CHECK(reviewed_by IS NULL OR reviewed_by<>submitted_by)
);
CREATE UNIQUE INDEX finance_subcontract_loss_policy_revision ON finance_subcontract_loss_policies
 (supplier_id,goods_id,color_id,unit_id,effective_from,revision) NULLS NOT DISTINCT;
CREATE INDEX finance_subcontract_loss_policy_scope ON finance_subcontract_loss_policies(supplier_id,goods_id,unit_id,effective_from);
CREATE VIEW v_finance_subcontract_loss_policy_current AS
 SELECT DISTINCT ON(supplier_id,goods_id,color_id,unit_id,effective_from)*
 FROM finance_subcontract_loss_policies WHERE status='APPROVED'
 ORDER BY supplier_id,goods_id,color_id,unit_id,effective_from,revision DESC;

CREATE FUNCTION fn_guard_finance_subcontract_loss_policy()RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION '原损耗率版本和来源不可删除，请提交受审停用版本' USING ERRCODE='23514';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('uten:subcontract-loss-policy:'||NEW.supplier_id::text||':'||NEW.goods_id::text||':'||NEW.unit_id::text,0));
 IF NEW.rate IS DISTINCT FROM fn_business_exact_divide_with_policy(NEW.rate_percent_original,100,
   'finance.subcontract.loss-percent','本次允许损耗百分率',24,NEW.precision_policy,false) THEN
  RAISE EXCEPTION '实际损耗比例须对应保留的原百分率及本次明确精度选择' USING ERRCODE='23514';END IF;
 IF TG_OP='INSERT' THEN
  IF NEW.status<>'SUBMITTED' OR NEW.reviewed_by IS NOT NULL OR NEW.revision<>(SELECT COALESCE(max(previous.revision),-1)+1
   FROM finance_subcontract_loss_policies previous WHERE previous.supplier_id=NEW.supplier_id AND previous.goods_id=NEW.goods_id
    AND previous.color_id IS NOT DISTINCT FROM NEW.color_id AND previous.unit_id=NEW.unit_id AND previous.effective_from=NEW.effective_from) THEN
   RAISE EXCEPTION '损耗率须从实际来源提交下一版本，再由另一人审核' USING ERRCODE='23514';END IF;
 ELSIF OLD.status<>'SUBMITTED' OR NEW.status NOT IN('APPROVED','REJECTED') OR NEW.reviewed_by IS NULL OR NEW.reviewed_at IS NULL
   OR length(btrim(COALESCE(NEW.review_reason,'')))NOT BETWEEN 1 AND 2000
   OR(to_jsonb(NEW)-ARRAY['status','reviewed_by','reviewed_at','review_reason']) IS DISTINCT FROM(to_jsonb(OLD)-ARRAY['status','reviewed_by','reviewed_at','review_reason']) THEN
  RAISE EXCEPTION '原损耗率事实不可覆盖，只可审核原版本或提交新版本' USING ERRCODE='23514';
 END IF;
 IF NEW.status='APPROVED' THEN
  IF EXISTS(SELECT 1 FROM finance_subcontract_loss_policies later WHERE later.supplier_id=NEW.supplier_id AND later.goods_id=NEW.goods_id
    AND later.color_id IS NOT DISTINCT FROM NEW.color_id AND later.unit_id=NEW.unit_id AND later.effective_from=NEW.effective_from AND later.revision>NEW.revision) THEN
   RAISE EXCEPTION '此损耗率已有后续版本，请核对最新原提交' USING ERRCODE='23514';END IF;
  IF NEW.enabled AND EXISTS(SELECT 1 FROM v_finance_subcontract_loss_policy_current other
    WHERE other.enabled AND other.supplier_id=NEW.supplier_id AND other.goods_id=NEW.goods_id AND other.unit_id=NEW.unit_id
      AND(other.color_id IS NULL OR NEW.color_id IS NULL OR other.color_id=NEW.color_id)
      AND NOT(other.color_id IS NOT DISTINCT FROM NEW.color_id AND other.effective_from=NEW.effective_from)
      AND daterange(other.effective_from,other.effective_to,'[]')&&daterange(NEW.effective_from,NEW.effective_to,'[]')) THEN
   RAISE EXCEPTION '同一供应商、商品、颜色与单位的有效损耗率区间重叠，请明确原适用期间' USING ERRCODE='23514';END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER finance_subcontract_loss_policy_guard BEFORE INSERT OR UPDATE OR DELETE ON finance_subcontract_loss_policies
 FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_subcontract_loss_policy();
SELECT fn_audit_track_table('finance_subcontract_loss_policies','COLUMN_SCOPED','data_change',false,
 ARRAY['id','request_id','supplier_id','goods_id','color_id','unit_id','effective_from','effective_to','revision','status','enabled','submitted_by','reviewed_by'],true,NULL);
