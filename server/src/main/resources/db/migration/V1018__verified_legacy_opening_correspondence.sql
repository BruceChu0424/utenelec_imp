-- References only: the original R1 GL and verified bootstrap initial_state keep all money authority.
CREATE TABLE finance_native_legacy_opening_reviews (
 id uuid PRIMARY KEY,request_id uuid NOT NULL UNIQUE,payload_hash text NOT NULL CHECK(payload_hash~'^[0-9a-f]{64}$'),
 source_reference text NOT NULL CHECK(length(trim(source_reference)) BETWEEN 1 AND 2000),plan jsonb NOT NULL,
 status text NOT NULL DEFAULT 'DRAFT' CHECK(status IN('DRAFT','APPROVED','REVERSED')),
 created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),
 approved_by uuid REFERENCES users(id),approved_at timestamptz,reversed_by uuid REFERENCES users(id),reversed_at timestamptz,reverse_reason text,
 CHECK(approved_by IS NULL OR approved_by<>created_by),CHECK(status='DRAFT' OR approved_by IS NOT NULL),
 CHECK((status='REVERSED')=(reversed_by IS NOT NULL AND reversed_at IS NOT NULL AND reverse_reason IS NOT NULL))
);
CREATE TABLE finance_native_legacy_opening_targets (
 id uuid PRIMARY KEY,review_id uuid NOT NULL REFERENCES finance_native_legacy_opening_reviews(id),
 ledger_id uuid NOT NULL REFERENCES ar_ap_ledger(id),legacy_proof_id uuid NOT NULL REFERENCES legacy_finance_import_sources(id),
 legacy_fingerprint text NOT NULL,cutoff_date date NOT NULL,native_original_currency_id uuid NOT NULL REFERENCES currencies(id),
 account_snapshot jsonb NOT NULL,UNIQUE(review_id,ledger_id)
);
CREATE INDEX idx_native_legacy_target_ledger ON finance_native_legacy_opening_targets(ledger_id,review_id);
CREATE TABLE finance_native_legacy_opening_parts (
 id uuid PRIMARY KEY,review_id uuid NOT NULL REFERENCES finance_native_legacy_opening_reviews(id),
 target_id uuid NOT NULL REFERENCES finance_native_legacy_opening_targets(id),ledger_id uuid NOT NULL REFERENCES ar_ap_ledger(id),
 entry_id uuid NOT NULL,allocation_no integer NOT NULL,opening_evidence_id uuid NOT NULL REFERENCES finance_gl_auxiliary_opening_evidence(id),
 import_batch_id uuid NOT NULL REFERENCES finance_accounting_import_batches(id),balance_import_id uuid NOT NULL REFERENCES finance_accounting_import_batches(id),
 amount_local numeric NOT NULL CHECK(amount_local>=0 AND fn_financial_book_amount_is_exact(amount_local)),
 amount_original numeric CHECK(amount_original>=0 AND fn_financial_amount_is_exact(amount_original)),
 native_original numeric NOT NULL CHECK(native_original>=0 AND fn_financial_amount_is_exact(native_original)),
 native_original_currency_id uuid NOT NULL REFERENCES currencies(id),source_fingerprint text NOT NULL,source_snapshot jsonb NOT NULL,
 FOREIGN KEY(entry_id,allocation_no) REFERENCES finance_gl_entry_allocations(entry_id,allocation_no),
 UNIQUE(review_id,ledger_id,entry_id,allocation_no),CHECK(amount_local<>0 OR native_original<>0)
);
CREATE INDEX idx_native_legacy_part_source ON finance_native_legacy_opening_parts(entry_id,allocation_no);
ALTER TABLE finance_native_cash_debt_parts ADD COLUMN legacy_opening_review_id uuid REFERENCES finance_native_legacy_opening_reviews(id);
CREATE TRIGGER trg_native_legacy_target_immutable BEFORE UPDATE OR DELETE ON finance_native_legacy_opening_targets FOR EACH ROW EXECUTE FUNCTION fn_guard_native_financial_snapshot();
CREATE TRIGGER trg_native_legacy_part_immutable BEFORE UPDATE OR DELETE ON finance_native_legacy_opening_parts FOR EACH ROW EXECUTE FUNCTION fn_guard_native_financial_snapshot();
CREATE OR REPLACE FUNCTION fn_guard_native_legacy_opening_review() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='UPDATE' AND OLD.status='DRAFT' AND NEW.status='APPROVED' AND NEW.approved_by IS NOT NULL AND NEW.approved_by<>OLD.created_by
   AND (to_jsonb(NEW)-ARRAY['status','approved_by','approved_at'])=(to_jsonb(OLD)-ARRAY['status','approved_by','approved_at']) THEN RETURN NEW;END IF;
 IF TG_OP='UPDATE' AND OLD.status='APPROVED' AND NEW.status='REVERSED'
   AND (to_jsonb(NEW)-ARRAY['status','reversed_by','reversed_at','reverse_reason'])=(to_jsonb(OLD)-ARRAY['status','reversed_by','reversed_at','reverse_reason']) THEN RETURN NEW;END IF;
 RAISE EXCEPTION 'Legacy correspondence evidence is immutable; independently approve or withdraw its owning review' USING ERRCODE='55000';
END $$;
CREATE TRIGGER trg_native_legacy_review BEFORE UPDATE OR DELETE ON finance_native_legacy_opening_reviews FOR EACH ROW EXECUTE FUNCTION fn_guard_native_legacy_opening_review();

CREATE OR REPLACE VIEW v_finance_native_partial_gl_allocations AS
 SELECT p.entry_id,p.allocation_no,sum(p.amount_local) amount_local,
   CASE WHEN bool_or(p.amount_original IS NULL) THEN NULL::numeric ELSE sum(p.amount_original) END amount_original
 FROM finance_native_legacy_opening_parts p JOIN finance_native_legacy_opening_reviews r ON r.id=p.review_id AND r.status='APPROVED'
 GROUP BY p.entry_id,p.allocation_no;

CREATE OR REPLACE FUNCTION fn_assert_native_legacy_opening_part() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source_local numeric;source_original numeric;source_currency uuid;used_local numeric;used_original numeric;target record;n bigint;
BEGIN
 SELECT amount_local,amount_original,original_currency_id INTO source_local,source_original,source_currency FROM finance_gl_entry_allocations WHERE entry_id=NEW.entry_id AND allocation_no=NEW.allocation_no;
 IF(source_original IS NULL AND NEW.amount_original IS NOT NULL)
  OR(source_original IS NOT NULL AND(NEW.amount_original IS DISTINCT FROM NEW.native_original OR source_currency IS DISTINCT FROM NEW.native_original_currency_id))
  OR NOT EXISTS(SELECT 1 FROM finance_native_legacy_opening_targets t WHERE t.id=NEW.target_id AND t.review_id=NEW.review_id AND t.ledger_id=NEW.ledger_id AND t.native_original_currency_id=NEW.native_original_currency_id)
 THEN RAISE EXCEPTION 'Financial original amount stays unknown without its own source; target and native original evidence must remain exact' USING ERRCODE='23514';END IF;
 SELECT amount_local,amount_original INTO used_local,used_original FROM v_finance_native_partial_gl_allocations WHERE entry_id=NEW.entry_id AND allocation_no=NEW.allocation_no;
 IF used_local>source_local OR(source_original IS NOT NULL AND used_original>source_original) THEN RAISE EXCEPTION 'Native opening shares exceed the existing R1 allocation; original money is unchanged' USING ERRCODE='23514';END IF;
 FOR target IN SELECT t.*,s.initial_state FROM finance_native_legacy_opening_targets t JOIN finance_native_legacy_opening_reviews r ON r.id=t.review_id AND r.status='APPROVED'
  JOIN legacy_finance_import_sources s ON s.id=t.legacy_proof_id WHERE t.review_id=NEW.review_id LOOP
  SELECT count(*) INTO n FROM finance_native_legacy_opening_targets other JOIN finance_native_legacy_opening_reviews r ON r.id=other.review_id AND r.status='APPROVED' WHERE other.ledger_id=target.ledger_id;
  IF n<>1 OR NOT EXISTS(SELECT 1 FROM finance_native_legacy_opening_parts p WHERE p.target_id=target.id
    HAVING sum(p.amount_local)=(target.initial_state->>'amount_balance')::numeric AND sum(p.native_original)=(target.initial_state->>'amount_balance_original')::numeric)
  THEN RAISE EXCEPTION 'Each approved legacy target must preserve its one verified initial unpaid amount and actual original unit' USING ERRCODE='23514';END IF;
 END LOOP;RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_native_legacy_parts_conserve AFTER INSERT ON finance_native_legacy_opening_parts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_native_legacy_opening_part();
CREATE CONSTRAINT TRIGGER trg_native_legacy_parts_public_floor AFTER INSERT ON finance_native_legacy_opening_parts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_finance_gl_settlement_floor();

CREATE OR REPLACE FUNCTION fn_guard_accounting_source_native_legacy_link() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF OLD.reversed_at IS NULL AND NEW.reversed_at IS NOT NULL AND EXISTS(
  SELECT 1 FROM finance_native_legacy_opening_parts p JOIN finance_native_legacy_opening_reviews r ON r.id=p.review_id AND r.status='APPROVED'
  WHERE p.import_batch_id=OLD.id OR p.balance_import_id=OLD.id)
 THEN RAISE EXCEPTION 'The R1 opening has approved native legacy references; withdraw their real downstream settlements and correspondence first' USING ERRCODE='55000';END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_accounting_source_native_legacy_link BEFORE UPDATE ON finance_accounting_import_batches FOR EACH ROW EXECUTE FUNCTION fn_guard_accounting_source_native_legacy_link();
SELECT fn_audit_track_table('finance_native_legacy_opening_reviews','COLUMN_SCOPED','data_change',false,ARRAY['id','request_id','status','created_by','approved_by','reversed_by'],true,NULL);
SELECT fn_audit_track_table('finance_native_legacy_opening_targets','COLUMN_SCOPED','data_change',false,ARRAY['id','review_id','ledger_id','legacy_proof_id','legacy_fingerprint'],true,NULL);
SELECT fn_audit_track_table('finance_native_legacy_opening_parts','COLUMN_SCOPED','data_change',false,ARRAY['id','review_id','ledger_id','entry_id','allocation_no','source_fingerprint'],true,NULL);
