-- New, explicitly enabled native approvals accrue pending supplier obligations.
-- Formal AP is created only by a separately authorized reconciliation confirmation.
-- Existing official sources are never reopened or rewritten by this policy.
INSERT INTO system_posting_style_roles(role_key,required_category,description) VALUES
 ('PROCUREMENT_GRNI_PENDING','LIABILITY','收货已入账、尚待对账确认的供应商暂估债务'),
 ('PROCUREMENT_RETURN_PENDING_ASSET','ACCOUNT','实物已退回、尚待确认供应商贷项的应收资产') ON CONFLICT(role_key) DO NOTHING;
CREATE TABLE finance_procurement_ap_policy (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),enabled boolean NOT NULL DEFAULT false,
 effective_from date,source_reference text,row_version bigint NOT NULL DEFAULT 0,
 updated_at timestamptz NOT NULL DEFAULT now(),updated_by uuid REFERENCES users(id),
 CHECK(NOT enabled OR(effective_from IS NOT NULL AND length(trim(source_reference))>=8))
);
INSERT INTO finance_procurement_ap_policy(singleton)VALUES(true);
CREATE TABLE finance_procurement_payable_routes (
 source_type text NOT NULL CHECK(source_type IN('PURCHASE_RECEIPT','SUBCONTRACT_RECEIPT','PURCHASE_RETURN','SUBCONTRACT_RETURN','PURCHASE_IQC_CREDIT','SUBCONTRACT_IQC_CREDIT')),
 source_id uuid NOT NULL,policy_version bigint NOT NULL,approved_on date NOT NULL,
 created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),creation_tx xid8 NOT NULL DEFAULT pg_current_xact_id(),
 PRIMARY KEY(source_type,source_id)
);
CREATE TABLE finance_procurement_payable_candidates (
 id uuid PRIMARY KEY,source_type text NOT NULL,source_id uuid NOT NULL,
 bill_no text NOT NULL,commercial_date date NOT NULL,accrual_date date NOT NULL,due_date date,
 supplier_id uuid NOT NULL REFERENCES suppliers(id),currency_id uuid NOT NULL REFERENCES currencies(id),
 exchange_rate numeric NOT NULL CHECK(exchange_rate>0 AND fn_financial_amount_is_exact(exchange_rate)),
 amount_original numeric NOT NULL CHECK(fn_financial_amount_is_exact(amount_original)),
 amount_local numeric NOT NULL CHECK(fn_financial_book_amount_is_exact(amount_local)),
 settlement_method_id uuid REFERENCES settlement_methods(id),settlement_style_legacy smallint,
 inventory_style_id uuid NOT NULL REFERENCES payment_styles(id),pending_style_id uuid NOT NULL REFERENCES payment_styles(id),
 pending_account_code text NOT NULL REFERENCES finance_chart_codes(code),pending_accounting_currency_id uuid NOT NULL REFERENCES currencies(id),
 auxiliary_id uuid NOT NULL REFERENCES finance_auxiliary_items(id),auxiliary_snapshot jsonb NOT NULL,
 source_fingerprint text NOT NULL CHECK(source_fingerprint~'^[0-9a-f]{64}$'),source_snapshot jsonb NOT NULL,
 pending_voucher_id uuid REFERENCES gl_vouchers(id),pending_reversal_voucher_id uuid REFERENCES gl_vouchers(id),
 status text NOT NULL CHECK(status IN('PENDING','CONFIRMED','ZERO_CONFIRMED','SOURCE_REVERSED')),
 ledger_id uuid UNIQUE REFERENCES ar_ap_ledger(id),recognition_id uuid,
 created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),source_reversed_at timestamptz,
 UNIQUE(source_type,source_id),FOREIGN KEY(source_type,source_id) REFERENCES finance_procurement_payable_routes(source_type,source_id),
 CHECK(amount_original<>0 OR amount_local=0),CHECK((source_type LIKE '%_RECEIPT' AND amount_original>=0) OR(source_type NOT LIKE '%_RECEIPT' AND amount_original<=0)),
 CHECK(status NOT IN('CONFIRMED','ZERO_CONFIRMED') OR recognition_id IS NOT NULL),
 CHECK((status='CONFIRMED')=(ledger_id IS NOT NULL)),CHECK((status='SOURCE_REVERSED')=(source_reversed_at IS NOT NULL))
);
CREATE INDEX idx_finance_procurement_candidate_scope ON finance_procurement_payable_candidates(supplier_id,currency_id,status,commercial_date,id);
CREATE TABLE finance_procurement_ap_recognitions (
 id uuid PRIMARY KEY,request_id uuid NOT NULL UNIQUE,payload_hash text NOT NULL,
 supplier_id uuid NOT NULL REFERENCES suppliers(id),currency_id uuid NOT NULL REFERENCES currencies(id),effective_date date NOT NULL,
 source_reference text NOT NULL,counterpart_confirmed_by text NOT NULL,counterpart_confirmed_date date NOT NULL,
 file_provider text NOT NULL,file_key text NOT NULL,file_version text,file_size bigint NOT NULL CHECK(file_size>0),
 file_sha256 text NOT NULL CHECK(file_sha256~'^[0-9a-f]{64}$'),file_name text NOT NULL,file_content_type text,
 submitted_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),
 status text NOT NULL CHECK(status IN('DRAFT','POSTED','REVERSED')),approved_by uuid REFERENCES users(id),approved_at timestamptz,
 reversed_by uuid REFERENCES users(id),reversed_at timestamptz,reverse_reason text,
 CHECK(approved_by IS NULL OR approved_by<>submitted_by),CHECK(status='DRAFT' OR approved_by IS NOT NULL),
 CHECK((status='REVERSED')=(reversed_by IS NOT NULL AND reversed_at IS NOT NULL))
);
ALTER TABLE finance_procurement_payable_candidates ADD CONSTRAINT finance_procurement_candidate_recognition_fk
 FOREIGN KEY(recognition_id)REFERENCES finance_procurement_ap_recognitions(id) DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE finance_procurement_ap_recognition_lines (
 recognition_id uuid NOT NULL REFERENCES finance_procurement_ap_recognitions(id),candidate_id uuid NOT NULL REFERENCES finance_procurement_payable_candidates(id),
 ledger_id uuid REFERENCES ar_ap_ledger(id),voucher_id uuid REFERENCES gl_vouchers(id),reversal_voucher_id uuid REFERENCES gl_vouchers(id),
 confirmed_original numeric NOT NULL CHECK(fn_financial_amount_is_exact(confirmed_original)),
 confirmed_local numeric NOT NULL CHECK(fn_financial_book_amount_is_exact(confirmed_local)),source_fingerprint text NOT NULL,
 PRIMARY KEY(recognition_id,candidate_id)
);
CREATE FUNCTION fn_finance_procurement_uses_legacy_ap(p_type text,p_source uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$SELECT NOT EXISTS(SELECT 1 FROM finance_procurement_payable_routes WHERE source_type=p_type AND source_id=p_source)$$;

-- Receipt consideration validates the true nominal receipt/candidate fact. A
-- candidate has no invented AP id; the terminal assertion below separately owns
-- the unique real formal AP and its later financial recognition date.
CREATE VIEW v_finance_procurement_receipt_payable_basis AS
 SELECT ledger.source_doc_type,ledger.source_doc_id,ledger.direction,ledger.status,ledger.is_deleted,
   ledger.supplier_id,ledger.currency_id,ledger.exchange_rate,ledger.settlement_type_id,
   ledger.amount_original,ledger.amount_original_local
 FROM ar_ap_ledger ledger WHERE fn_finance_procurement_uses_legacy_ap(ledger.source_doc_type,ledger.source_doc_id)
 UNION ALL SELECT candidate.source_type,candidate.source_id,'AP',1::smallint,false,
   candidate.supplier_id,candidate.currency_id,candidate.exchange_rate,candidate.settlement_method_id,
   candidate.amount_original,candidate.amount_local
 FROM finance_procurement_payable_candidates candidate
 WHERE candidate.status<>'SOURCE_REVERSED'
   AND(candidate.amount_original<>0 OR candidate.amount_local<>0);
DO $$ DECLARE definition text;needle text;BEGIN
 SELECT pg_get_functiondef('fn_assert_procurement_consideration_receipt(text,uuid)'::regprocedure)INTO definition;
 needle:='INTO v_ap FROM ar_ap_ledger WHERE source_doc_type=p_type||''_RECEIPT'' AND source_doc_id=p_receipt';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review exact receipt consideration AP aggregate before enabling deferred AP';END IF;
 EXECUTE replace(definition,needle,'INTO v_ap FROM v_finance_procurement_receipt_payable_basis WHERE source_doc_type=p_type||''_RECEIPT'' AND source_doc_id=p_receipt');
END $$;

-- Typed IQC source contract. The existing insert/terminal validators remain in
-- force until the complete pending-credit workflow supplies its own exact plan.
ALTER TABLE procurement_iqc_credit_documents ADD COLUMN source_candidate_id uuid REFERENCES finance_procurement_payable_candidates(id);
ALTER TABLE procurement_iqc_credit_documents ALTER COLUMN source_ap_ledger_id DROP NOT NULL;
ALTER TABLE procurement_iqc_credit_documents ADD CONSTRAINT procurement_credit_one_typed_source CHECK((source_ap_ledger_id IS NOT NULL)<>(source_candidate_id IS NOT NULL));
ALTER TABLE procurement_iqc_credit_documents ADD COLUMN allocation_version smallint NOT NULL DEFAULT 1 CHECK(allocation_version IN(1,2));
ALTER TABLE procurement_iqc_credit_documents ADD CONSTRAINT procurement_credit_v2_precision CHECK(allocation_version=1 OR COALESCE((
 jsonb_typeof(book_allocation_plan->'precisionPolicy')='object' AND(book_allocation_plan->'precisionPolicy'->>'version')='1'
 AND jsonb_typeof(book_allocation_plan->'precisionPolicy'->'choices')='object'),false));
ALTER TABLE procurement_iqc_credit_slices ADD COLUMN allocation_sequence integer;
ALTER TABLE procurement_iqc_credit_slices ADD COLUMN before_quantity numeric;
ALTER TABLE procurement_iqc_credit_slices ADD COLUMN before_original numeric;
ALTER TABLE procurement_iqc_credit_slices ADD COLUMN before_local numeric;
ALTER TABLE procurement_iqc_credit_slices ADD COLUMN after_quantity numeric;
ALTER TABLE procurement_iqc_credit_slices ADD COLUMN after_original numeric;
ALTER TABLE procurement_iqc_credit_slices ADD COLUMN after_local numeric;
ALTER TABLE procurement_iqc_credit_slices ADD CONSTRAINT procurement_credit_slice_balance_proof CHECK(
 (allocation_sequence IS NULL AND before_quantity IS NULL AND before_original IS NULL AND before_local IS NULL AND after_quantity IS NULL AND after_original IS NULL AND after_local IS NULL)
 OR(allocation_sequence IS NOT NULL AND before_quantity IS NOT NULL AND before_original IS NOT NULL AND before_local IS NOT NULL
  AND after_quantity IS NOT NULL AND after_original IS NOT NULL AND after_local IS NOT NULL
  AND allocation_sequence>0 AND before_quantity>0 AND after_quantity>=0 AND before_original>=0 AND before_local>=0 AND after_original>=0 AND after_local>=0
  AND amount_original IS NOT NULL AND amount_local IS NOT NULL AND before_quantity=after_quantity+base_qty
  AND before_original=after_original+amount_original AND before_local=after_local+amount_local
  AND fn_financial_amount_is_exact(before_original) AND fn_financial_amount_is_exact(after_original)
  AND fn_financial_book_amount_is_exact(before_local) AND fn_financial_book_amount_is_exact(after_local)));
CREATE UNIQUE INDEX procurement_credit_slice_sequence ON procurement_iqc_credit_slices(case_allocation_id,allocation_sequence)WHERE allocation_sequence IS NOT NULL;
CREATE FUNCTION fn_plan_procurement_pending_credit_book(p_candidate uuid,p_actual numeric)RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE source finance_procurement_payable_candidates%ROWTYPE;used_original numeric;used_local numeric;before_original numeric;before_local numeric;book numeric;
BEGIN
 SELECT * INTO source FROM finance_procurement_payable_candidates WHERE id=p_candidate FOR UPDATE;
 IF NOT FOUND OR source.status<>'PENDING' OR source.source_type NOT IN('PURCHASE_RECEIPT','SUBCONTRACT_RECEIPT')
   OR source.amount_original<=0 OR p_actual IS NULL OR p_actual<=0 OR NOT fn_financial_amount_is_exact(p_actual)THEN
  RAISE EXCEPTION 'pending credit requires its exact positive unrecognized receipt source' USING ERRCODE='23514';END IF;
 SELECT original,local INTO used_original,used_local FROM fn_finance_pending_credit_used(p_candidate);
 before_original:=source.amount_original-used_original;before_local:=source.amount_local-used_local;
 IF used_original IS NULL OR used_local IS NULL OR p_actual>before_original OR before_local<0 THEN RAISE EXCEPTION 'actual credits exceed the unrecognized receipt source' USING ERRCODE='23514';END IF;
 book:=fn_financial_book_part(p_actual,before_original,before_local);
 RETURN jsonb_build_object('sourceApLedgerId',NULL,'sourceCandidateId',p_candidate,'amountOriginal',p_actual,'amountLocal',book,
   'precisionPolicy',fn_business_precision_snapshot(),
   'offsetOriginal',0,'offsetLocal',0,'creditRemainingOriginal',p_actual,'creditRemainingLocal',book,
   'sourceBeforeOriginal',before_original,'sourceBeforeLocal',before_local,'sourceAfterOriginal',before_original,'sourceAfterLocal',before_local,
   'basis',jsonb_build_array(jsonb_build_object('sourceKind','PENDING_RECEIPT','sourceId',p_candidate,
      'sourceAmountOriginal',source.amount_original,'sourceAmountLocal',source.amount_local,'beforeOriginal',before_original,'beforeLocal',before_local,
      'allocatedOriginal',p_actual,'allocatedLocal',book,'afterOriginal',before_original-p_actual,'afterLocal',before_local-book)));
END $$;

CREATE FUNCTION fn_assert_finance_procurement_candidate(p_id uuid)RETURNS void LANGUAGE plpgsql AS $$
DECLARE candidate finance_procurement_payable_candidates%ROWTYPE;actual record;document_status smallint;header_table text;recognition finance_procurement_ap_recognitions%ROWTYPE;
BEGIN
 SELECT * INTO candidate FROM finance_procurement_payable_candidates WHERE id=p_id;IF NOT FOUND THEN RETURN;END IF;
 header_table:=CASE candidate.source_type WHEN 'PURCHASE_RECEIPT' THEN 'purchase_receipts' WHEN 'SUBCONTRACT_RECEIPT' THEN 'subcontract_receipts'
   WHEN 'PURCHASE_RETURN' THEN 'purchase_returns' WHEN 'SUBCONTRACT_RETURN' THEN 'subcontract_returns' END;
 IF header_table IS NOT NULL THEN
  EXECUTE format('SELECT status FROM %I WHERE id=$1 AND NOT is_deleted',header_table)INTO document_status USING candidate.source_id;
  IF document_status IS DISTINCT FROM(CASE WHEN candidate.status='SOURCE_REVERSED' THEN -1 ELSE 1 END)::smallint THEN
   RAISE EXCEPTION 'pending AP source requires its original physical terminal status' USING ERRCODE='23514';END IF;
 END IF;
 SELECT count(*) n,COALESCE(sum(amount_original),0) original,COALESCE(sum(amount_original_local),0)local,
   COALESCE(bool_and(supplier_id=candidate.supplier_id AND currency_id=candidate.currency_id),true)identity,
   min(id::text)::uuid actual_id INTO actual
 FROM ar_ap_ledger WHERE source_doc_type=candidate.source_type AND source_doc_id=candidate.source_id AND direction='AP' AND status=1 AND NOT is_deleted;
 IF (candidate.status='CONFIRMED' AND(actual.n<>1 OR actual.actual_id IS DISTINCT FROM candidate.ledger_id
     OR NOT actual.identity OR(actual.original,actual.local)IS DISTINCT FROM(candidate.amount_original,candidate.amount_local)))
   OR(candidate.status<>'CONFIRMED' AND actual.n<>0)THEN
  RAISE EXCEPTION 'reconcile-first source requires exactly one confirmed real AP, or none while pending/reversed' USING ERRCODE='23514';END IF;
 IF candidate.amount_local<>0 AND(candidate.pending_voucher_id IS NULL OR NOT EXISTS(SELECT 1 FROM gl_vouchers WHERE id=candidate.pending_voucher_id AND status IN(1,-1)AND NOT is_deleted))THEN
  RAISE EXCEPTION 'reconcile-first receipt/return requires its real pending inventory/debt journal' USING ERRCODE='23514';END IF;
 IF candidate.recognition_id IS NOT NULL THEN
  SELECT * INTO recognition FROM finance_procurement_ap_recognitions WHERE id=candidate.recognition_id;
  IF recognition.status<>'POSTED' OR(recognition.supplier_id,recognition.currency_id)IS DISTINCT FROM(candidate.supplier_id,candidate.currency_id)
    OR NOT EXISTS(SELECT 1 FROM finance_procurement_ap_recognition_lines line WHERE line.recognition_id=recognition.id AND line.candidate_id=candidate.id
       AND(line.confirmed_original,line.confirmed_local,line.source_fingerprint,line.ledger_id)IS NOT DISTINCT FROM(candidate.amount_original,candidate.amount_local,candidate.source_fingerprint,candidate.ledger_id))
    OR(candidate.ledger_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM ar_ap_ledger ledger WHERE ledger.id=candidate.ledger_id AND ledger.bill_date=recognition.effective_date))THEN
   RAISE EXCEPTION 'formal AP must retain its independently reviewed source amounts, identity, date and original file' USING ERRCODE='23514';END IF;
 END IF;
END $$;
CREATE FUNCTION fn_guard_finance_procurement_candidate_terminal()RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE id uuid;source_kind text;
BEGIN
 IF TG_TABLE_NAME='finance_procurement_payable_candidates'THEN id:=COALESCE(NEW.id,OLD.id);
 ELSIF TG_TABLE_NAME='ar_ap_ledger'THEN SELECT candidate.id INTO id FROM finance_procurement_payable_candidates candidate WHERE candidate.source_type=COALESCE(NEW.source_doc_type,OLD.source_doc_type)AND candidate.source_id=COALESCE(NEW.source_doc_id,OLD.source_doc_id);
 ELSE
  source_kind:=CASE TG_TABLE_NAME WHEN 'purchase_receipts'THEN 'PURCHASE_RECEIPT' WHEN 'subcontract_receipts'THEN 'SUBCONTRACT_RECEIPT' WHEN 'purchase_returns'THEN 'PURCHASE_RETURN' WHEN 'subcontract_returns'THEN 'SUBCONTRACT_RETURN' END;
  SELECT candidate.id INTO id FROM finance_procurement_payable_candidates candidate WHERE candidate.source_type=source_kind AND candidate.source_id=COALESCE(NEW.id,OLD.id);
 END IF;
 PERFORM fn_assert_finance_procurement_candidate(id);RETURN NULL;
END $$;

CREATE FUNCTION fn_guard_finance_procurement_source_facts()RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE mutable text[];
BEGIN
 IF TG_OP='DELETE'THEN RAISE EXCEPTION 'procurement financial source history cannot be deleted' USING ERRCODE='55000';END IF;
 mutable:=CASE TG_TABLE_NAME WHEN 'finance_procurement_payable_candidates' THEN ARRAY['status','ledger_id','recognition_id','source_reversed_at','pending_reversal_voucher_id']
   WHEN 'finance_procurement_ap_recognitions'THEN ARRAY['status','approved_by','approved_at','reversed_by','reversed_at','reverse_reason']
   ELSE ARRAY['ledger_id','voucher_id','reversal_voucher_id']END;
 IF (to_jsonb(NEW)-mutable)IS DISTINCT FROM(to_jsonb(OLD)-mutable)THEN RAISE EXCEPTION 'frozen procurement financial source facts cannot be overwritten' USING ERRCODE='55000';END IF;
 IF TG_TABLE_NAME='finance_procurement_ap_recognitions'THEN
  IF NOT((OLD.status='DRAFT' AND NEW.status='POSTED')OR(OLD.status='POSTED' AND NEW.status='REVERSED'))THEN
   RAISE EXCEPTION 'invalid procurement reconciliation lifecycle transition' USING ERRCODE='55000';END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_finance_procurement_candidate_facts BEFORE UPDATE OR DELETE ON finance_procurement_payable_candidates FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_procurement_source_facts();
CREATE TRIGGER trg_finance_procurement_recognition_facts BEFORE UPDATE OR DELETE ON finance_procurement_ap_recognitions FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_procurement_source_facts();
CREATE TRIGGER trg_finance_procurement_recognition_line_facts BEFORE UPDATE OR DELETE ON finance_procurement_ap_recognition_lines FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_procurement_source_facts();
CREATE CONSTRAINT TRIGGER trg_finance_procurement_candidate_terminal AFTER INSERT OR UPDATE OR DELETE ON finance_procurement_payable_candidates DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_procurement_candidate_terminal();
CREATE CONSTRAINT TRIGGER trg_finance_procurement_candidate_ledger_terminal AFTER INSERT OR UPDATE OR DELETE ON ar_ap_ledger DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_procurement_candidate_terminal();
CREATE CONSTRAINT TRIGGER trg_finance_procurement_purchase_receipt_terminal AFTER UPDATE ON purchase_receipts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN(OLD.status IS DISTINCT FROM NEW.status)EXECUTE FUNCTION fn_guard_finance_procurement_candidate_terminal();
CREATE CONSTRAINT TRIGGER trg_finance_procurement_subcontract_receipt_terminal AFTER UPDATE ON subcontract_receipts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN(OLD.status IS DISTINCT FROM NEW.status)EXECUTE FUNCTION fn_guard_finance_procurement_candidate_terminal();
CREATE CONSTRAINT TRIGGER trg_finance_procurement_purchase_return_terminal AFTER UPDATE ON purchase_returns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN(OLD.status IS DISTINCT FROM NEW.status)EXECUTE FUNCTION fn_guard_finance_procurement_candidate_terminal();
CREATE CONSTRAINT TRIGGER trg_finance_procurement_subcontract_return_terminal AFTER UPDATE ON subcontract_returns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN(OLD.status IS DISTINCT FROM NEW.status)EXECUTE FUNCTION fn_guard_finance_procurement_candidate_terminal();
CREATE FUNCTION fn_guard_finance_procurement_route_immutable()RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'native payable cutover route is immutable; existing official sources are never reopened' USING ERRCODE='55000';END $$;
CREATE TRIGGER trg_finance_procurement_route_immutable BEFORE UPDATE OR DELETE ON finance_procurement_payable_routes FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_procurement_route_immutable();
CREATE TRIGGER trg_audit_finance_procurement_ap_policy AFTER INSERT OR UPDATE OR DELETE ON finance_procurement_ap_policy FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_procurement_payable_routes AFTER INSERT OR UPDATE OR DELETE ON finance_procurement_payable_routes FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_procurement_payable_candidates AFTER INSERT OR UPDATE OR DELETE ON finance_procurement_payable_candidates FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_procurement_ap_recognitions AFTER INSERT OR UPDATE OR DELETE ON finance_procurement_ap_recognitions FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_procurement_ap_recognition_lines AFTER INSERT OR UPDATE OR DELETE ON finance_procurement_ap_recognition_lines FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- A failed physical slice may be funded by a real pending receipt. It is a
-- different typed identity from an AP ledger and remains stable after AP exists.
ALTER TABLE procurement_iqc_funding_slices ADD COLUMN source_candidate_id uuid REFERENCES finance_procurement_payable_candidates(id);
ALTER TABLE procurement_iqc_funding_slices ADD CONSTRAINT procurement_iqc_funding_source_exclusive CHECK(source_ap_ledger_id IS NULL OR source_candidate_id IS NULL);
ALTER TABLE procurement_iqc_rejection_cases ADD COLUMN source_candidate_id uuid REFERENCES finance_procurement_payable_candidates(id);
DO $$ DECLARE definition text;BEGIN
 SELECT pg_get_functiondef('fn_assert_procurement_iqc_funding(uuid)'::regprocedure)INTO definition;
 IF position('ledger.id own_ap' IN definition)=0 OR position('v_source.parent_ap)' IN definition)=0 THEN RAISE EXCEPTION 'Review complete frozen IQC funding contract before adding pending receipt identity';END IF;
 definition:=replace(definition,'ledger.id own_ap','CASE WHEN candidate.id IS NULL THEN ledger.id END own_ap,candidate.id own_candidate,parent.source_candidate_id parent_candidate');
 definition:=replace(definition,'WHERE quality.id=v_fund.quality_part_id','LEFT JOIN finance_procurement_payable_candidates candidate ON candidate.source_type=part.receipt_type||''_RECEIPT'' AND candidate.source_id=part.receipt_id AND candidate.status<>''SOURCE_REVERSED'' AND part.quantity_tranche<>''GIFT'' WHERE quality.id=v_fund.quality_part_id');
 definition:=replace(definition,'v_fund.root_receipt_item_id,v_fund.source_ap_ledger_id)','v_fund.root_receipt_item_id,v_fund.source_ap_ledger_id,v_fund.source_candidate_id)');
 definition:=replace(definition,'v_source.parent_root_item,v_source.parent_ap)','v_source.parent_root_item,v_source.parent_ap,v_source.parent_candidate)');
 definition:=replace(definition,'OR v_fund.source_ap_ledger_id IS DISTINCT FROM v_source.own_ap','OR v_fund.source_ap_ledger_id IS DISTINCT FROM v_source.own_ap OR v_fund.source_candidate_id IS DISTINCT FROM v_source.own_candidate');
 definition:=replace(definition,'v_fund.source_ap_ledger_id IS NULL AND (v_fund.amount_original<>0','v_fund.source_ap_ledger_id IS NULL AND v_fund.source_candidate_id IS NULL AND (v_fund.amount_original<>0');
 EXECUTE definition;
END $$;

CREATE FUNCTION fn_finance_iqc_funding_ap(p_funding uuid)RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT COALESCE(funding.source_ap_ledger_id,candidate.ledger_id) FROM procurement_iqc_funding_slices funding
 LEFT JOIN finance_procurement_payable_candidates candidate ON candidate.id=funding.source_candidate_id AND candidate.status='CONFIRMED'
 WHERE funding.id=p_funding
$$;
DO $$ DECLARE definition text;signature text;BEGIN
 FOREACH signature IN ARRAY ARRAY['fn_procurement_iqc_ap_hold_reason(uuid,uuid)','fn_procurement_iqc_slice_offset_authorized(uuid,uuid,uuid)','fn_assert_procurement_credit_consideration(uuid)']LOOP
  SELECT pg_get_functiondef(signature::regprocedure)INTO definition;
  definition:=replace(definition,'funding.source_ap_ledger_id','fn_finance_iqc_funding_ap(funding.id)');
  -- A record projection must retain its original field name after resolving the typed reference.
  definition:=replace(definition,'funding.case_id funding_case,fn_finance_iqc_funding_ap(funding.id)','funding.case_id funding_case,fn_finance_iqc_funding_ap(funding.id) source_ap_ledger_id');
  EXECUTE definition;
 END LOOP;
END $$;

CREATE VIEW v_finance_procurement_credit_sources AS
 SELECT 'AP'::text source_kind,id,direction,status,is_deleted,supplier_id,currency_id,exchange_rate,amount_original,amount_original_local FROM ar_ap_ledger
 UNION ALL SELECT 'PENDING_RECEIPT',id,'AP',1::smallint,false,supplier_id,currency_id,exchange_rate,amount_original,amount_local
 FROM finance_procurement_payable_candidates WHERE source_type IN('PURCHASE_RECEIPT','SUBCONTRACT_RECEIPT')AND status<>'SOURCE_REVERSED';

-- Native return consideration already reserves the same invoice entitlement
-- while its real AP is awaiting reconciliation. Never fabricate a ledger UUID.
CREATE FUNCTION fn_finance_unrecognized_return_parts(p_type text,p_receipt uuid)
RETURNS TABLE(credit_ledger_id uuid,amount_original numeric,amount_local numeric,reserved_original numeric,reserved_local numeric)
LANGUAGE sql STABLE AS $$
 SELECT NULL::uuid,sum(item.amount_original),sum(item.amount_local),sum(item.amount_original),sum(item.amount_local)
 FROM purchase_return_items item JOIN purchase_receipt_items source ON source.id=item.receipt_item_id
 JOIN purchase_returns document ON document.id=item.return_id AND document.status=1 AND NOT document.is_deleted
 JOIN finance_procurement_payable_candidates candidate ON candidate.source_type='PURCHASE_RETURN' AND candidate.source_id=document.id AND candidate.status='PENDING'
 WHERE p_type='PURCHASE' AND source.receipt_id=p_receipt AND NOT item.is_deleted GROUP BY candidate.id
 UNION ALL SELECT NULL::uuid,sum(item.amount_original),sum(item.amount_local),sum(item.amount_original),sum(item.amount_local)
 FROM subcontract_return_items item JOIN subcontract_receipt_items source ON source.id=item.receipt_item_id
 JOIN subcontract_returns document ON document.id=item.return_id AND document.status=1 AND NOT document.is_deleted
 JOIN finance_procurement_payable_candidates candidate ON candidate.source_type='SUBCONTRACT_RETURN' AND candidate.source_id=document.id AND candidate.status='PENDING'
 WHERE p_type='SUBCONTRACT' AND source.receipt_id=p_receipt AND NOT item.is_deleted GROUP BY candidate.id
$$;

DO $$ DECLARE definition text;needle text:='WHERE document.source_ap_ledger_id=p_source';BEGIN
 SELECT pg_get_functiondef('fn_procurement_source_credit_parts(uuid)'::regprocedure)INTO definition;
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review original credit attribution before adding typed pending source';END IF;
 definition:=replace(definition,needle,needle||' OR EXISTS(SELECT 1 FROM finance_procurement_payable_candidates candidate WHERE candidate.id=document.source_candidate_id AND candidate.source_type=v_source.source_doc_type AND candidate.source_id=v_source.source_doc_id)');
 EXECUTE definition;
END $$;
ALTER FUNCTION fn_procurement_source_credit_parts(uuid)RENAME TO fn_procurement_source_credit_parts_before_v1000;
CREATE FUNCTION fn_procurement_source_credit_parts(p_source uuid)
RETURNS TABLE(credit_ledger_id uuid,amount_original numeric,amount_local numeric,reserved_original numeric,reserved_local numeric)
LANGUAGE plpgsql AS $$ DECLARE source ar_ap_ledger%ROWTYPE;BEGIN
 RETURN QUERY SELECT * FROM fn_procurement_source_credit_parts_before_v1000(p_source);
 SELECT * INTO source FROM ar_ap_ledger WHERE id=p_source;
 IF source.source_doc_type IN('PURCHASE_RECEIPT','SUBCONTRACT_RECEIPT')THEN
  RETURN QUERY SELECT * FROM fn_finance_unrecognized_return_parts(replace(source.source_doc_type,'_RECEIPT',''),source.source_doc_id);
 END IF;
END $$;

CREATE FUNCTION fn_finance_pending_credit_used(p_candidate uuid)RETURNS TABLE(original numeric,local numeric)
LANGUAGE sql STABLE AS $$
 WITH source AS(SELECT * FROM finance_procurement_payable_candidates WHERE id=p_candidate),parts AS(
  SELECT document.amount_original original,document.amount_local local FROM procurement_iqc_credit_documents document CROSS JOIN source
  WHERE(document.source_candidate_id=source.id OR document.source_ap_ledger_id IN(SELECT ledger_id FROM finance_procurement_ap_recognition_lines WHERE candidate_id=source.id))
    AND EXISTS(SELECT 1 FROM procurement_iqc_credit_slices slice WHERE slice.credit_document_id=document.id AND fn_procurement_consideration_active('CREDIT',slice.id))
  UNION ALL SELECT item.amount_original,item.amount_local FROM source
   JOIN purchase_receipt_items received ON source.source_type='PURCHASE_RECEIPT' AND received.receipt_id=source.source_id
   JOIN purchase_return_items item ON item.receipt_item_id=received.id AND NOT item.is_deleted
   JOIN purchase_returns document ON document.id=item.return_id AND document.status=1 AND NOT document.is_deleted
   JOIN v_finance_procurement_receipt_payable_basis basis ON basis.source_doc_type='PURCHASE_RETURN' AND basis.source_doc_id=document.id AND basis.status=1 AND NOT basis.is_deleted
  UNION ALL SELECT item.amount_original,item.amount_local FROM source
   JOIN subcontract_receipt_items received ON source.source_type='SUBCONTRACT_RECEIPT' AND received.receipt_id=source.source_id
   JOIN subcontract_return_items item ON item.receipt_item_id=received.id AND NOT item.is_deleted
   JOIN subcontract_returns document ON document.id=item.return_id AND document.status=1 AND NOT document.is_deleted
   JOIN v_finance_procurement_receipt_payable_basis basis ON basis.source_doc_type='SUBCONTRACT_RETURN' AND basis.source_doc_id=document.id AND basis.status=1 AND NOT basis.is_deleted
 )SELECT CASE WHEN count(*)=0 THEN 0 WHEN bool_and(original IS NOT NULL)THEN sum(original)END,
          CASE WHEN count(*)=0 THEN 0 WHEN bool_and(local IS NOT NULL)THEN sum(local)END FROM parts
$$;
CREATE FUNCTION fn_assert_finance_credit_case_slices(p_case_allocation uuid)RETURNS void LANGUAGE plpgsql AS $$
DECLARE allocation procurement_iqc_credit_case_allocations%ROWTYPE;document procurement_iqc_credit_documents%ROWTYPE;
 slice procurement_iqc_credit_slices%ROWTYPE;quantity_left numeric;original_left numeric;local_left numeric;seq integer:=0;expected numeric;
BEGIN
 SELECT * INTO allocation FROM procurement_iqc_credit_case_allocations WHERE id=p_case_allocation;
 SELECT * INTO document FROM procurement_iqc_credit_documents WHERE id=allocation.credit_document_id;
 IF document.allocation_version<>2 OR NOT EXISTS(SELECT 1 FROM procurement_iqc_credit_slices active WHERE active.case_allocation_id=allocation.id AND fn_procurement_consideration_active('CREDIT',active.id))THEN RETURN;END IF;
 quantity_left:=allocation.base_qty;original_left:=allocation.amount_original;local_left:=allocation.amount_local;
 FOR slice IN SELECT * FROM procurement_iqc_credit_slices WHERE case_allocation_id=allocation.id AND fn_procurement_consideration_active('CREDIT',id)ORDER BY allocation_sequence,id LOOP
  seq:=seq+1;
  IF slice.allocation_sequence IS DISTINCT FROM seq OR(slice.before_quantity,slice.before_original,slice.before_local)IS DISTINCT FROM(quantity_left,original_left,local_left)
    OR(slice.after_quantity,slice.after_original,slice.after_local)IS DISTINCT FROM(quantity_left-slice.base_qty,original_left-slice.amount_original,local_left-slice.amount_local)THEN
   RAISE EXCEPTION 'credit funding slice loses its actual preceding or remaining source' USING ERRCODE='23514';END IF;
  expected:=CASE WHEN slice.base_qty=quantity_left THEN original_left ELSE fn_business_exact_divide_with_policy(original_left*slice.base_qty,quantity_left,
    'procurement.credit.actual-share','已冻结实际贷项原币分摊',24,document.book_allocation_plan->'precisionPolicy',false)END;
  IF slice.amount_original IS DISTINCT FROM expected OR slice.amount_local IS DISTINCT FROM fn_financial_book_part_proof(slice.base_qty,quantity_left,local_left,document.book_allocation_plan->'precisionPolicy')THEN
   RAISE EXCEPTION 'credit funding slice differs from the reviewed explicit precision policy' USING ERRCODE='23514';END IF;
  quantity_left:=slice.after_quantity;original_left:=slice.after_original;local_left:=slice.after_local;
 END LOOP;
 IF(quantity_left,original_left,local_left)IS DISTINCT FROM(0::numeric,0::numeric,0::numeric)THEN RAISE EXCEPTION 'final credit funding slice must take the true whole remainder' USING ERRCODE='23514';END IF;
END $$;

CREATE OR REPLACE FUNCTION fn_guard_procurement_credit_book_plan_insert()RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE expected jsonb;BEGIN
 expected:=CASE WHEN NEW.source_candidate_id IS NULL THEN fn_plan_procurement_credit_book(NEW.source_ap_ledger_id,NEW.amount_original)
   ELSE fn_plan_procurement_pending_credit_book(NEW.source_candidate_id,NEW.amount_original)END;
 IF NEW.book_allocation_plan IS DISTINCT FROM expected OR NEW.amount_local IS DISTINCT FROM(expected->>'amountLocal')::numeric THEN
  RAISE EXCEPTION 'credit document book plan differs from its explicit AP or pending receipt source' USING ERRCODE='23514';END IF;
 RETURN NEW;
END $$;

DO $$ DECLARE definition text;needle text;BEGIN
 SELECT pg_get_functiondef('fn_assert_procurement_credit_consideration(uuid)'::regprocedure)INTO definition;
 needle:='SELECT * INTO v_source FROM ar_ap_ledger WHERE id=v_document.source_ap_ledger_id FOR UPDATE;';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review full physical credit source validation before typed extension';END IF;
 definition:=replace(definition,needle,'IF v_document.source_candidate_id IS NULL THEN '||needle||' ELSE SELECT * INTO v_source FROM v_finance_procurement_credit_sources WHERE source_kind=''PENDING_RECEIPT'' AND id=v_document.source_candidate_id; END IF;');
 definition:=replace(definition,'IF v_total.n>0 AND (v_source.status<>1','IF v_total.n>0 AND (v_source.id IS NULL OR v_source.status<>1');
 definition:=replace(definition,'OR (v_document.book_allocation_plan->>''amountOriginal'')::numeric',
   'OR (v_document.book_allocation_plan->>''sourceCandidateId'')::uuid IS DISTINCT FROM v_document.source_candidate_id OR (v_document.book_allocation_plan->>''amountOriginal'')::numeric');
 definition:=replace(definition,'funding.case_id funding_case,fn_finance_iqc_funding_ap(funding.id) source_ap_ledger_id',
    'funding.case_id funding_case,fn_finance_iqc_funding_ap(funding.id) source_ap_ledger_id,funding.source_candidate_id');
 definition:=replace(definition,'OR v_slice.source_ap_ledger_id<>v_document.source_ap_ledger_id',
   'OR(v_document.source_candidate_id IS NULL AND v_slice.source_ap_ledger_id IS DISTINCT FROM v_document.source_ap_ledger_id) OR(v_document.source_candidate_id IS NOT NULL AND v_slice.source_candidate_id IS DISTINCT FROM v_document.source_candidate_id)');
 needle:='OR NOT EXISTS(SELECT 1 FROM ar_ap_ledger WHERE id=v_slice.source_ap_ledger_id'||chr(10)||'                AND direction=''AP'' AND status=1 AND is_deleted=FALSE AND amount_original>0)';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review exact IQC funding source assertion';END IF;
 definition:=replace(definition,needle,'OR(v_document.source_candidate_id IS NULL AND NOT EXISTS(SELECT 1 FROM ar_ap_ledger WHERE id=v_slice.source_ap_ledger_id AND direction=''AP'' AND status=1 AND NOT is_deleted AND amount_original>0)) OR(v_document.source_candidate_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM finance_procurement_payable_candidates WHERE id=v_slice.source_candidate_id AND status<>''SOURCE_REVERSED'' AND amount_original>0))');
 definition:=replace(definition,'IF (v_allocation.amount_original=v_original_left AND v_allocation.amount_local<>v_local_left)',
   'IF (v_document.allocation_version=1 AND ((v_allocation.amount_original=v_original_left AND v_allocation.amount_local<>v_local_left)');
 definition:=replace(definition,'OR v_remainder>=v_original_left*1e-30::numeric THEN',
   'OR v_remainder>=v_original_left*1e-30::numeric)) OR(v_document.allocation_version=2 AND v_allocation.amount_local IS DISTINCT FROM fn_financial_book_part_proof(v_allocation.amount_original,v_original_left,v_local_left,v_document.book_allocation_plan->''precisionPolicy'')) THEN');
 definition:=replace(definition,'v_original_left:=v_allocation.book_after_original;v_local_left:=v_allocation.book_after_local;',
   'IF v_document.allocation_version=2 THEN PERFORM fn_assert_finance_credit_case_slices(v_allocation.id);END IF; v_original_left:=v_allocation.book_after_original;v_local_left:=v_allocation.book_after_local;');
 definition:=replace(definition,'OR (v_slice.amount_original IS NOT NULL','OR (v_document.allocation_version=1 AND v_slice.amount_original IS NOT NULL');
 definition:=replace(definition,'OR (v_slice.amount_local IS NOT NULL','OR (v_document.allocation_version=1 AND v_slice.amount_local IS NOT NULL');
 EXECUTE definition;
END $$;

CREATE OR REPLACE FUNCTION fn_assert_procurement_credit_book_plan(p_document uuid)RETURNS void LANGUAGE plpgsql AS $$
DECLARE d procurement_iqc_credit_documents%ROWTYPE;p jsonb;v record;b jsonb;
 allocated_a numeric:=0;allocated_b numeric:=0;live boolean;
BEGIN
 SELECT * INTO d FROM procurement_iqc_credit_documents WHERE id=p_document;IF NOT FOUND THEN RETURN;END IF;p:=d.book_allocation_plan;
 IF d.amount_original<>(p->>'offsetOriginal')::numeric+(p->>'creditRemainingOriginal')::numeric
   OR d.amount_local<>(p->>'offsetLocal')::numeric+(p->>'creditRemainingLocal')::numeric
   OR(p->>'sourceAfterOriginal')::numeric<>(p->>'sourceBeforeOriginal')::numeric-(p->>'offsetOriginal')::numeric
   OR(p->>'sourceAfterLocal')::numeric<>(p->>'sourceBeforeLocal')::numeric-(p->>'offsetLocal')::numeric THEN
  RAISE EXCEPTION 'source book plan does not conserve its original and local balances' USING ERRCODE='23514';END IF;
 FOR b IN SELECT value FROM jsonb_array_elements(p->'basis')LOOP
  IF(b->>'sourceId')::uuid IS DISTINCT FROM COALESCE(d.source_ap_ledger_id,d.source_candidate_id)
    OR(b->>'allocatedLocal')::numeric<>fn_financial_book_part_proof((b->>'allocatedOriginal')::numeric,(b->>'beforeOriginal')::numeric,(b->>'beforeLocal')::numeric,p->'precisionPolicy')
    OR(b->>'afterOriginal')::numeric<>(b->>'beforeOriginal')::numeric-(b->>'allocatedOriginal')::numeric
    OR(b->>'afterLocal')::numeric<>(b->>'beforeLocal')::numeric-(b->>'allocatedLocal')::numeric THEN
   RAISE EXCEPTION 'book allocation loses its exact typed source ratio or remainder' USING ERRCODE='23514';END IF;
  allocated_a:=allocated_a+(b->>'allocatedOriginal')::numeric;allocated_b:=allocated_b+(b->>'allocatedLocal')::numeric;
 END LOOP;
 IF allocated_a<>d.amount_original OR allocated_b<>d.amount_local THEN RAISE EXCEPTION 'book basis differs from confirmed credit' USING ERRCODE='23514';END IF;
 SELECT EXISTS(SELECT 1 FROM procurement_iqc_credit_slices slice WHERE slice.credit_document_id=p_document AND fn_procurement_consideration_active('CREDIT',slice.id))INTO live;
 SELECT count(*)n,COALESCE(sum(o.amount_original),0)a,COALESCE(sum(o.source_amount_local),0)sb,COALESCE(sum(o.target_amount_local),0)tb,
   COALESCE(bool_and(o.target_ledger_id=d.source_ap_ledger_id AND l.source_doc_id=p_document),true)identity_matches
 INTO v FROM supplier_open_item_offsets o JOIN ar_ap_ledger l ON l.id=o.source_ledger_id WHERE o.offset_batch_id=p_document AND o.status='APPLIED';
 IF(live AND(v.a<>(p->>'offsetOriginal')::numeric OR v.sb<>(p->>'offsetLocal')::numeric OR v.tb<>v.sb OR NOT v.identity_matches OR v.n<>CASE WHEN v.a=0 THEN 0 ELSE 1 END))OR(NOT live AND v.n<>0)THEN
  RAISE EXCEPTION 'both sides must consume the frozen book allocation' USING ERRCODE='23514';END IF;
 IF d.source_candidate_id IS NOT NULL AND live THEN
  SELECT original AS a,local AS b INTO v FROM fn_finance_pending_credit_used(d.source_candidate_id);
  IF EXISTS(SELECT 1 FROM finance_procurement_payable_candidates source WHERE source.id=d.source_candidate_id
    AND(v.a IS NULL OR v.b IS NULL OR v.a>source.amount_original OR v.b>source.amount_local OR source.status='SOURCE_REVERSED'))THEN
   RAISE EXCEPTION 'active credits exceed their real pending receipt source' USING ERRCODE='23514';END IF;
 ELSIF d.source_candidate_id IS NULL THEN
  SELECT sum(parts.amount_original)a,sum(parts.amount_local)b INTO v FROM fn_procurement_source_credit_parts(d.source_ap_ledger_id)parts;
  IF EXISTS(SELECT 1 FROM ar_ap_ledger source WHERE source.id=d.source_ap_ledger_id AND(v.a>source.amount_original OR v.b>source.amount_original_local))THEN
   RAISE EXCEPTION 'active credits exceed the original source value' USING ERRCODE='23514';END IF;
 END IF;
END $$;
