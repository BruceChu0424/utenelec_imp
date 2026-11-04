-- Explicit reviewed correspondence for native writers. This is configuration and identity,
-- never an alternative set of monetary facts and never a replay of imported accounting data.
CREATE TABLE finance_native_posting_configurations (
 id uuid PRIMARY KEY,request_id uuid NOT NULL UNIQUE,payload_hash text NOT NULL CHECK(payload_hash~'^[0-9a-f]{64}$'),
 role_key text NOT NULL REFERENCES system_posting_style_roles(role_key),original_currency_id uuid REFERENCES currencies(id),
 party_role text CHECK(party_role IN('CUSTOMER','SUPPLIER','EMPLOYEE','OTHER')),party_id uuid,
 effective_from date NOT NULL,configuration_version bigint NOT NULL CHECK(configuration_version>0),
 enabled boolean NOT NULL,style_id uuid NOT NULL REFERENCES payment_styles(id),account_code text NOT NULL REFERENCES finance_chart_codes(code),
 accounting_currency_id uuid NOT NULL REFERENCES currencies(id),auxiliary_id uuid REFERENCES finance_auxiliary_items(id),
 source_reference text NOT NULL CHECK(length(trim(source_reference)) BETWEEN 1 AND 2000),
 status text NOT NULL DEFAULT 'DRAFT' CHECK(status IN('DRAFT','APPROVED')),created_by uuid NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),approved_by uuid REFERENCES users(id),approved_at timestamptz,
 CHECK((party_role IS NULL)=(party_id IS NULL)),CHECK(auxiliary_id IS NULL OR party_id IS NOT NULL),
 CHECK((status='APPROVED')=(approved_by IS NOT NULL AND approved_at IS NOT NULL)),CHECK(approved_by IS NULL OR approved_by<>created_by),
 UNIQUE NULLS NOT DISTINCT(role_key,original_currency_id,party_role,party_id,effective_from,configuration_version)
);
CREATE INDEX idx_native_posting_effective ON finance_native_posting_configurations(role_key,effective_from,status);
CREATE OR REPLACE FUNCTION fn_guard_native_posting_configuration() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='UPDATE' AND OLD.status='DRAFT' AND NEW.status='APPROVED' AND NEW.approved_by IS NOT NULL
  AND NEW.approved_by<>OLD.created_by AND NEW.approved_at IS NOT NULL
  AND (to_jsonb(OLD)-ARRAY['status','approved_by','approved_at'])=(to_jsonb(NEW)-ARRAY['status','approved_by','approved_at']) THEN RETURN NEW;END IF;
 RAISE EXCEPTION 'Native correspondence versions are immutable; approve independently or append a new version' USING ERRCODE='55000';
END $$;
CREATE TRIGGER trg_native_posting_configuration BEFORE UPDATE OR DELETE ON finance_native_posting_configurations
 FOR EACH ROW EXECUTE FUNCTION fn_guard_native_posting_configuration();

CREATE TABLE finance_native_debt_accounts (
 ledger_id uuid PRIMARY KEY REFERENCES ar_ap_ledger(id),account_snapshot jsonb NOT NULL,
 counterpart_snapshot jsonb,source_fingerprint text NOT NULL CHECK(source_fingerprint~'^[0-9a-f]{64}$'),
 evidence_kind text NOT NULL CHECK(evidence_kind IN('NATIVE_APPROVAL','REVIEWED_EXISTING_ENTRY')),
 existing_entry_id uuid REFERENCES gl_entries(id),created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),
 CHECK((evidence_kind='REVIEWED_EXISTING_ENTRY')=(existing_entry_id IS NOT NULL))
);
CREATE OR REPLACE FUNCTION fn_guard_native_financial_snapshot() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Native accounting source snapshots are immutable; retain the original and reverse its owning business' USING ERRCODE='55000';END $$;
CREATE TRIGGER trg_native_debt_account_immutable BEFORE UPDATE OR DELETE ON finance_native_debt_accounts
 FOR EACH ROW EXECUTE FUNCTION fn_guard_native_financial_snapshot();
CREATE TABLE finance_native_debt_entry_refs (
 ledger_id uuid PRIMARY KEY REFERENCES ar_ap_ledger(id),entry_id uuid NOT NULL UNIQUE REFERENCES gl_entries(id),
 voucher_id uuid NOT NULL REFERENCES gl_vouchers(id),owner_reverses_journal boolean NOT NULL,
 created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_native_debt_entry_ref_immutable BEFORE UPDATE OR DELETE ON finance_native_debt_entry_refs
 FOR EACH ROW EXECUTE FUNCTION fn_guard_native_financial_snapshot();
CREATE TABLE finance_native_debt_correspondence_reviews (
 id uuid PRIMARY KEY,request_id uuid NOT NULL UNIQUE,payload_hash text NOT NULL,ledger_id uuid NOT NULL REFERENCES ar_ap_ledger(id),
 entry_id uuid NOT NULL REFERENCES gl_entries(id),account_snapshot jsonb NOT NULL,source_fingerprint text NOT NULL,
 source_reference text NOT NULL CHECK(length(trim(source_reference)) BETWEEN 1 AND 2000),
 status text NOT NULL DEFAULT 'DRAFT' CHECK(status IN('DRAFT','APPROVED')),created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),
 approved_by uuid REFERENCES users(id),approved_at timestamptz,CHECK((status='APPROVED')=(approved_by IS NOT NULL AND approved_at IS NOT NULL)),
 CHECK(approved_by IS NULL OR approved_by<>created_by)
);
CREATE UNIQUE INDEX idx_native_debt_correspondence_approved ON finance_native_debt_correspondence_reviews(ledger_id) WHERE status='APPROVED';
CREATE TRIGGER trg_native_debt_correspondence_review BEFORE UPDATE OR DELETE ON finance_native_debt_correspondence_reviews
 FOR EACH ROW EXECUTE FUNCTION fn_guard_native_posting_configuration();

-- New cash approval freezes each actual source line independently. Header cash, fees and FX remain
-- their original authorities; these identities only select the already-booked debt account.
CREATE TABLE finance_native_cash_debt_parts (
 kind text NOT NULL CHECK(kind IN('PAYMENT','RECEIPT')),cash_id uuid NOT NULL,source_line_id uuid NOT NULL,
 ledger_id uuid NOT NULL REFERENCES ar_ap_ledger(id),line_no integer NOT NULL CHECK(line_no>0),
 account_snapshot jsonb NOT NULL,amount_original numeric NOT NULL CHECK(fn_financial_amount_is_exact(amount_original)),
 amount_local numeric NOT NULL CHECK(fn_financial_book_amount_is_exact(amount_local)),
 source_fingerprint text NOT NULL CHECK(source_fingerprint~'^[0-9a-f]{64}$'),created_by uuid NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(kind,cash_id,source_line_id),UNIQUE(kind,cash_id,line_no)
);
CREATE TRIGGER trg_native_cash_debt_immutable BEFORE UPDATE OR DELETE ON finance_native_cash_debt_parts
 FOR EACH ROW EXECUTE FUNCTION fn_guard_native_financial_snapshot();
CREATE TABLE finance_native_cash_debt_entry_links (
 kind text NOT NULL,cash_id uuid NOT NULL,source_line_id uuid NOT NULL,entry_id uuid NOT NULL REFERENCES gl_entries(id),
 created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(kind,cash_id,source_line_id),
 FOREIGN KEY(kind,cash_id,source_line_id) REFERENCES finance_native_cash_debt_parts(kind,cash_id,source_line_id)
);
CREATE TRIGGER trg_native_cash_debt_entry_link_immutable BEFORE UPDATE OR DELETE ON finance_native_cash_debt_entry_links
 FOR EACH ROW EXECUTE FUNCTION fn_guard_native_financial_snapshot();
CREATE TABLE finance_native_cash_accounts (
 kind text NOT NULL CHECK(kind IN('PAYMENT','RECEIPT')),cash_id uuid NOT NULL,account_snapshot jsonb NOT NULL,
 created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(kind,cash_id)
);
CREATE TRIGGER trg_native_cash_accounts_immutable BEFORE UPDATE OR DELETE ON finance_native_cash_accounts
 FOR EACH ROW EXECUTE FUNCTION fn_guard_native_financial_snapshot();
CREATE TABLE finance_native_supplier_offset_journals (
 offset_id uuid PRIMARY KEY REFERENCES supplier_open_item_offsets(id),source_account jsonb NOT NULL,target_account jsonb NOT NULL,
 voucher_id uuid REFERENCES gl_vouchers(id),reversal_voucher_id uuid REFERENCES gl_vouchers(id),reversed_at timestamptz,
 created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),
 CHECK(reversal_voucher_id IS NULL OR (voucher_id IS NOT NULL AND reversed_at IS NOT NULL)),
 CHECK(reversed_at IS NULL OR voucher_id IS NULL OR reversal_voucher_id IS NOT NULL)
);
CREATE OR REPLACE FUNCTION fn_guard_native_supplier_offset_journal() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='UPDATE' AND OLD.reversed_at IS NULL AND NEW.reversed_at IS NOT NULL
  AND (to_jsonb(NEW)-ARRAY['reversal_voucher_id','reversed_at'])=(to_jsonb(OLD)-ARRAY['reversal_voucher_id','reversed_at']) THEN RETURN NEW;END IF;
 RAISE EXCEPTION 'Supplier offset accounting lineage is immutable; reverse the owning actual offset' USING ERRCODE='55000';
END $$;
CREATE TRIGGER trg_native_supplier_offset_journal BEFORE UPDATE OR DELETE ON finance_native_supplier_offset_journals
 FOR EACH ROW EXECUTE FUNCTION fn_guard_native_supplier_offset_journal();
CREATE TABLE finance_native_customer_offset_accounts (
 offset_id uuid PRIMARY KEY REFERENCES customer_open_item_offsets(id),source_account jsonb NOT NULL,target_account jsonb NOT NULL,
 created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_native_customer_offset_immutable BEFORE UPDATE OR DELETE ON finance_native_customer_offset_accounts
 FOR EACH ROW EXECUTE FUNCTION fn_guard_native_financial_snapshot();
CREATE INDEX idx_native_debt_account_aux ON finance_native_debt_accounts((account_snapshot#>>'{auxiliary,auxiliaryId}'));
CREATE INDEX idx_native_debt_counterpart_aux ON finance_native_debt_accounts((counterpart_snapshot#>>'{auxiliary,auxiliaryId}'));
CREATE INDEX idx_native_cash_debt_aux ON finance_native_cash_debt_parts((account_snapshot#>>'{auxiliary,auxiliaryId}'));
CREATE OR REPLACE FUNCTION fn_guard_native_auxiliary_party_identity() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.party_id IS DISTINCT FROM OLD.party_id AND (
  EXISTS(SELECT 1 FROM finance_native_debt_accounts WHERE account_snapshot#>>'{auxiliary,auxiliaryId}'=OLD.id::text OR counterpart_snapshot#>>'{auxiliary,auxiliaryId}'=OLD.id::text)
  OR EXISTS(SELECT 1 FROM finance_native_cash_debt_parts WHERE account_snapshot#>>'{auxiliary,auxiliaryId}'=OLD.id::text)
  OR EXISTS(SELECT 1 FROM finance_native_cash_accounts WHERE account_snapshot#>>'{auxiliary,auxiliaryId}'=OLD.id::text)
  OR EXISTS(SELECT 1 FROM finance_native_posting_configurations WHERE status='APPROVED' AND auxiliary_id=OLD.id)
 ) THEN RAISE EXCEPTION 'An approved native source already froze this auxiliary party identity; append an explicit new auxiliary instead' USING ERRCODE='55000';END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_native_auxiliary_party_identity BEFORE UPDATE ON finance_auxiliary_items
 FOR EACH ROW EXECUTE FUNCTION fn_guard_native_auxiliary_party_identity();

CREATE OR REPLACE FUNCTION fn_finance_native_configured_style(p_role text,p_original_currency uuid,p_party_role text,p_party uuid,p_date date)
RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT COALESCE((SELECT CASE WHEN c.enabled THEN c.style_id ELSE system_posting_style_id(p_role) END
  FROM finance_native_posting_configurations c WHERE c.role_key=p_role AND c.status='APPROVED' AND c.effective_from<=p_date
   AND (c.original_currency_id IS NULL OR c.original_currency_id=p_original_currency)
   AND (c.party_id IS NULL OR (c.party_role=p_party_role AND c.party_id=p_party))
  ORDER BY (c.party_id IS NOT NULL) DESC,(c.original_currency_id IS NOT NULL) DESC,c.effective_from DESC,c.configuration_version DESC,c.id LIMIT 1),system_posting_style_id(p_role));
$$;
CREATE OR REPLACE FUNCTION fn_finance_native_cash_counter_style(p_kind text,p_cash uuid,p_role text,p_currency uuid,p_party_role text,p_party uuid,p_date date)
RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT COALESCE(
  (SELECT (account_snapshot->>'styleId')::uuid FROM finance_native_cash_debt_parts WHERE kind=p_kind AND cash_id=p_cash ORDER BY line_no LIMIT 1),
  (SELECT (account_snapshot->>'styleId')::uuid FROM finance_native_cash_accounts WHERE kind=p_kind AND cash_id=p_cash),
  (SELECT (n.account_snapshot->>'styleId')::uuid FROM finance_native_debt_accounts n JOIN (
    SELECT applied_ledger_id ledger_id,line_no FROM finance_payment_lines WHERE p_kind='PAYMENT' AND payment_id=p_cash AND NOT is_deleted
    UNION ALL SELECT applied_ledger_id,line_no FROM finance_receipt_lines WHERE p_kind='RECEIPT' AND receipt_id=p_cash AND NOT is_deleted
   ) l ON l.ledger_id=n.ledger_id ORDER BY l.line_no LIMIT 1),
  CASE WHEN p_role IN('AR_CONTROL','AP_CONTROL') THEN system_posting_style_id(p_role)
    ELSE fn_finance_native_configured_style(p_role,p_currency,p_party_role,p_party,p_date) END);
$$;

-- Retain every original bank/fee/FX and legacy cash shape. Only the trade-debt counter entry
-- is replaced by its exact source lines, so several original debt accounts can be cleared once.
DO $$ DECLARE definition text;BEGIN
 SELECT pg_get_viewdef('v_payment_v2_expected_gl_entries'::regclass,true) INTO definition;
 EXECUTE 'CREATE VIEW v_payment_v2_expected_gl_entries_before_v1009 AS '||definition;
 SELECT pg_get_viewdef('v_receipt_expected_gl_entries'::regclass,true) INTO definition;
 EXECUTE 'CREATE VIEW v_receipt_expected_gl_entries_before_v1009 AS '||definition;
END $$;
CREATE OR REPLACE VIEW v_payment_v2_expected_gl_entries AS
 SELECT old.* FROM v_payment_v2_expected_gl_entries_before_v1009 old
 WHERE old.line_no<>1 OR NOT EXISTS(SELECT 1 FROM finance_native_cash_debt_parts p WHERE p.kind='PAYMENT' AND p.cash_id=old.payment_id)
 UNION ALL SELECT p.cash_id,1000+p.line_no,(p.account_snapshot->>'styleId')::uuid,1::smallint,p.amount_local
 FROM finance_native_cash_debt_parts p JOIN finance_payments cash ON cash.id=p.cash_id
 WHERE p.kind='PAYMENT' AND p.amount_local<>0 AND cash.amount_authority_version=2 AND cash.status IN(1,-1) AND NOT cash.is_deleted;
CREATE OR REPLACE VIEW v_receipt_expected_gl_entries AS
 SELECT old.* FROM v_receipt_expected_gl_entries_before_v1009 old
 WHERE old.line_no<>2 OR NOT EXISTS(SELECT 1 FROM finance_native_cash_debt_parts p WHERE p.kind='RECEIPT' AND p.cash_id=old.receipt_id)
 UNION ALL SELECT p.cash_id,1000+p.line_no,(p.account_snapshot->>'styleId')::uuid,-1::smallint,p.amount_local
 FROM finance_native_cash_debt_parts p JOIN finance_receipts cash ON cash.id=p.cash_id
 WHERE p.kind='RECEIPT' AND p.amount_local<>0 AND cash.settlement_authority_version IN(1,2) AND cash.status IN(1,-1) AND NOT cash.is_deleted;

DO $$ DECLARE definition text;needle text;BEGIN
 SELECT pg_get_functiondef('fn_guard_payment_v2_actual_bank()'::regprocedure) INTO definition;
 needle:='system_posting_style_id(CASE WHEN EXISTS(SELECT 1 FROM finance_payment_lines WHERE payment_id=NEW.id AND NOT is_deleted) THEN ''AP_CONTROL'' ELSE ''SUPPLIER_PREPAYMENT_ASSET'' END)';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review actual payment account identity before frozen debt integration';END IF;
 EXECUTE replace(definition,needle,'fn_finance_native_cash_counter_style(''PAYMENT'',NEW.id,CASE WHEN EXISTS(SELECT 1 FROM finance_payment_lines WHERE payment_id=NEW.id AND NOT is_deleted) THEN ''AP_CONTROL'' ELSE ''SUPPLIER_PREPAYMENT_ASSET'' END,NEW.currency_id,''SUPPLIER'',NEW.supplier_id,NEW.bill_date)');
 SELECT pg_get_functiondef('fn_guard_finance_receipt_v1_account_identity()'::regprocedure) INTO definition;
 needle:='system_posting_style_id(
           CASE WHEN NEW.receipt_kind=''CUSTOMER_PREPAYMENT''
                THEN ''CUSTOMER_ADVANCE'' ELSE ''AR_CONTROL'' END)';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review actual receipt account identity before frozen debt integration';END IF;
 EXECUTE replace(definition,needle,'fn_finance_native_cash_counter_style(''RECEIPT'',NEW.id,CASE WHEN NEW.receipt_kind=''CUSTOMER_PREPAYMENT'' THEN ''CUSTOMER_ADVANCE'' ELSE ''AR_CONTROL'' END,NEW.currency_id,''CUSTOMER'',NEW.client_id,NEW.bill_date)');
END $$;

CREATE OR REPLACE FUNCTION fn_finance_native_debt_style(p_ledger uuid,p_role text)
RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT CASE WHEN n.ledger_id IS NULL THEN system_posting_style_id(p_role)
  WHEN p_role IN('AR_CONTROL','AP_CONTROL') THEN (n.account_snapshot->>'styleId')::uuid
  ELSE COALESCE((n.counterpart_snapshot->>'styleId')::uuid,system_posting_style_id(p_role)) END
 FROM (SELECT p_ledger id) request LEFT JOIN finance_native_debt_accounts n ON n.ledger_id=request.id;
$$;
CREATE OR REPLACE FUNCTION fn_finance_attach_native_debt_allocations(p_period text)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE inserted integer;
BEGIN
 INSERT INTO finance_gl_entry_allocations(entry_id,allocation_no,account_code,source_account_code,auxiliary_id,currency_id,
  original_currency_id,amount_local,amount_original,exchange_rate,auxiliary_role,party_id_snapshot,source_system,source_code,
  source_name,source_entry_id,source_row,source_snapshot,created_by)
 SELECT e.id,1,s.snapshot->>'accountCode',s.snapshot->>'accountCode',(s.snapshot->'auxiliary'->>'auxiliaryId')::uuid,
  (s.snapshot->>'accountingCurrencyId')::uuid,(s.snapshot->>'originalCurrencyId')::uuid,e.amount,l.amount_original,l.exchange_rate,
  s.snapshot->'auxiliary'->>'role',(s.snapshot->'auxiliary'->>'partyId')::uuid,s.snapshot->'auxiliary'->>'sourceSystem',
  s.snapshot->'auxiliary'->>'sourceCode',s.snapshot->'auxiliary'->>'sourceName',l.id::text,1,
  jsonb_build_object('version',1,'evidence','NATIVE_APPROVAL','ledgerId',l.id,'sourceFingerprint',n.source_fingerprint,'account',s.snapshot),n.created_by
 FROM finance_native_debt_accounts n JOIN ar_ap_ledger l ON l.id=n.ledger_id
 JOIN gl_vouchers v ON v.source_type=CASE l.direction WHEN 'AR' THEN 'AR_POST' ELSE 'AP_POST' END
  AND v.source_doc_id=l.source_doc_id AND v.period=p_period AND v.source='AUTO' AND v.status=1 AND NOT v.is_deleted
 JOIN gl_entries e ON e.voucher_id=v.id AND NOT e.is_deleted
 CROSS JOIN LATERAL(SELECT CASE WHEN (l.direction='AR' AND e.line_no=1) OR (l.direction='AP' AND e.line_no=2)
    THEN n.account_snapshot ELSE n.counterpart_snapshot END snapshot) s
 WHERE e.line_no IN(1,2) AND (s.snapshot->>'complete')::boolean AND e.style_id=(s.snapshot->>'styleId')::uuid
  AND NOT EXISTS(SELECT 1 FROM finance_gl_entry_allocations old WHERE old.entry_id=e.id);
 GET DIAGNOSTICS inserted=ROW_COUNT;
 INSERT INTO finance_native_debt_entry_refs(ledger_id,entry_id,voucher_id,owner_reverses_journal,created_by)
 SELECT l.id,e.id,v.id,false,n.created_by FROM finance_native_debt_accounts n JOIN ar_ap_ledger l ON l.id=n.ledger_id
 JOIN gl_vouchers v ON v.source_type=CASE l.direction WHEN 'AR' THEN 'AR_POST' ELSE 'AP_POST' END
  AND v.source_doc_id=l.source_doc_id AND v.period=p_period AND v.source='AUTO' AND v.status=1 AND NOT v.is_deleted
 JOIN gl_entries e ON e.voucher_id=v.id AND e.line_no=CASE l.direction WHEN 'AR' THEN 1 ELSE 2 END AND NOT e.is_deleted
 WHERE NOT EXISTS(SELECT 1 FROM finance_native_debt_entry_refs old WHERE old.ledger_id=l.id);
 INSERT INTO finance_native_cash_debt_entry_links(kind,cash_id,source_line_id,entry_id)
 SELECT p.kind,p.cash_id,p.source_line_id,r.entry_id FROM finance_native_cash_debt_parts p JOIN finance_native_debt_entry_refs r ON r.ledger_id=p.ledger_id
 WHERE NOT EXISTS(SELECT 1 FROM finance_native_cash_debt_entry_links old WHERE old.kind=p.kind AND old.cash_id=p.cash_id AND old.source_line_id=p.source_line_id);
 RETURN inserted;
END $$;

CREATE OR REPLACE FUNCTION fn_finance_attach_native_cash_allocations(p_kind text,p_cash uuid)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE inserted integer;copied integer;
BEGIN
 IF p_kind NOT IN('PAYMENT','RECEIPT') THEN RAISE EXCEPTION 'Unknown native cash kind' USING ERRCODE='23514';END IF;
 INSERT INTO finance_gl_entry_allocations(entry_id,allocation_no,account_code,source_account_code,auxiliary_id,currency_id,
  original_currency_id,amount_local,amount_original,auxiliary_role,party_id_snapshot,source_system,source_code,source_name,
  source_entry_id,source_row,source_snapshot,created_by)
 SELECT e.id,1,s.snapshot->>'accountCode',s.snapshot->>'accountCode',(s.snapshot->'auxiliary'->>'auxiliaryId')::uuid,
  (s.snapshot->>'accountingCurrencyId')::uuid,(s.snapshot->>'originalCurrencyId')::uuid,e.amount,s.amount_original,
  s.snapshot->'auxiliary'->>'role',(s.snapshot->'auxiliary'->>'partyId')::uuid,s.snapshot->'auxiliary'->>'sourceSystem',
  s.snapshot->'auxiliary'->>'sourceCode',s.snapshot->'auxiliary'->>'sourceName',s.source_id,1,
  jsonb_build_object('version',1,'cashKind',p_kind,'cashId',p_cash,'originalDebt',s.ledger_id,'account',s.snapshot),s.actor
 FROM (
   SELECT account_snapshot snapshot,1000+line_no line_no,amount_original,source_line_id::text source_id,ledger_id,created_by actor
    FROM finance_native_cash_debt_parts WHERE kind=p_kind AND cash_id=p_cash
   UNION ALL SELECT a.account_snapshot,CASE p_kind WHEN 'PAYMENT' THEN 1 ELSE 2 END,
     CASE p_kind WHEN 'PAYMENT' THEN p.amount_original ELSE r.amount_original END,p_cash::text,NULL::uuid,a.created_by
    FROM finance_native_cash_accounts a LEFT JOIN finance_payments p ON p.id=a.cash_id AND a.kind='PAYMENT'
    LEFT JOIN finance_receipts r ON r.id=a.cash_id AND a.kind='RECEIPT' WHERE a.kind=p_kind AND a.cash_id=p_cash
 ) s JOIN gl_vouchers v ON v.source='AUTO' AND v.source_type=p_kind AND v.source_doc_id=p_cash AND NOT v.is_deleted
 JOIN gl_entries e ON e.voucher_id=v.id AND e.line_no=s.line_no AND NOT e.is_deleted
 WHERE (s.snapshot->>'complete')::boolean AND e.style_id=(s.snapshot->>'styleId')::uuid
  AND NOT EXISTS(SELECT 1 FROM finance_gl_entry_allocations old WHERE old.entry_id=e.id);
 GET DIAGNOSTICS inserted=ROW_COUNT;
 INSERT INTO finance_gl_entry_allocations(entry_id,allocation_no,account_code,source_account_code,source_account_name,
  source_account_path_name,auxiliary_id,currency_id,original_currency_id,amount_local,amount_original,exchange_rate,
  auxiliary_role,party_id_snapshot,source_system,source_code,source_name,source_entry_id,source_row,source_snapshot,created_by)
 SELECT back.id,a.allocation_no,a.account_code,a.source_account_code,a.source_account_name,a.source_account_path_name,a.auxiliary_id,
  a.currency_id,a.original_currency_id,a.amount_local,a.amount_original,a.exchange_rate,a.auxiliary_role,a.party_id_snapshot,
  a.source_system,a.source_code,a.source_name,a.source_entry_id,a.source_row,a.source_snapshot,a.created_by
 FROM gl_vouchers reverse JOIN gl_vouchers original ON original.id=reverse.reversal_of_voucher_id
 JOIN gl_entries e ON e.voucher_id=original.id AND NOT e.is_deleted
 JOIN gl_entries back ON back.voucher_id=reverse.id AND back.line_no=e.line_no AND NOT back.is_deleted
 JOIN finance_gl_entry_allocations a ON a.entry_id=e.id
 WHERE reverse.source='AUTO' AND reverse.source_type=p_kind||'_REV' AND reverse.source_doc_id=p_cash AND NOT reverse.is_deleted
  AND NOT EXISTS(SELECT 1 FROM finance_gl_entry_allocations old WHERE old.entry_id=back.id);
 GET DIAGNOSTICS copied=ROW_COUNT;RETURN inserted+copied;
END $$;

-- Existing unconfirmed trade projections are disposable by their original owner. Their
-- allocation metadata must follow that exact deletion, while imported/controlled facts stay protected.
CREATE OR REPLACE FUNCTION fn_cleanup_native_trade_projection_allocations() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF OLD.source='AUTO' AND OLD.source_type IN('AR_POST','AP_POST','CUSTOMER_PREPAYMENT_OFFSET')
  AND NOT EXISTS(SELECT 1 FROM finance_gl_voucher_evidence proof WHERE proof.voucher_id=OLD.id) THEN
  IF EXISTS(SELECT 1 FROM finance_native_debt_entry_refs reference WHERE reference.voucher_id=OLD.id)
   OR EXISTS(SELECT 1 FROM finance_gl_settlement_source_parts reservation JOIN gl_entries e ON e.id=reservation.entry_id WHERE e.voucher_id=OLD.id)
   OR EXISTS(SELECT 1 FROM finance_gl_settlement_clearings clearing JOIN gl_entries e ON e.id=clearing.entry_id OR e.id=clearing.source_entry_id WHERE e.voucher_id=OLD.id)
  THEN RAISE EXCEPTION 'Frozen debt or settlement source is not a disposable AUTO projection; reverse its real owning journal' USING ERRCODE='55000';END IF;
  DELETE FROM finance_gl_entry_allocations a USING gl_entries e WHERE a.entry_id=e.id AND e.voucher_id=OLD.id;
 END IF;RETURN OLD;
END $$;
CREATE TRIGGER trg_cleanup_native_trade_projection_allocations BEFORE DELETE ON gl_vouchers
 FOR EACH ROW EXECUTE FUNCTION fn_cleanup_native_trade_projection_allocations();
CREATE OR REPLACE FUNCTION fn_finance_native_projection_is_frozen(p_voucher uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM finance_native_debt_entry_refs WHERE voucher_id=p_voucher)
  OR EXISTS(SELECT 1 FROM finance_gl_settlement_source_parts part JOIN gl_entries e ON e.id=part.entry_id WHERE e.voucher_id=p_voucher)
  OR EXISTS(SELECT 1 FROM finance_gl_settlement_clearings clearing JOIN gl_entries e ON e.id=clearing.entry_id OR e.id=clearing.source_entry_id WHERE e.voucher_id=p_voucher);
$$;

CREATE OR REPLACE FUNCTION fn_finance_attach_native_customer_offset_allocations(p_period text)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE inserted integer;
BEGIN
 INSERT INTO finance_gl_entry_allocations(entry_id,allocation_no,account_code,source_account_code,auxiliary_id,currency_id,
  original_currency_id,amount_local,amount_original,auxiliary_role,party_id_snapshot,source_system,source_code,source_name,
  source_entry_id,source_row,source_snapshot,created_by)
 SELECT e.id,1,s.snapshot->>'accountCode',s.snapshot->>'accountCode',(s.snapshot->'auxiliary'->>'auxiliaryId')::uuid,
  (s.snapshot->>'accountingCurrencyId')::uuid,(s.snapshot->>'originalCurrencyId')::uuid,e.amount,o.amount_original,
  s.snapshot->'auxiliary'->>'role',(s.snapshot->'auxiliary'->>'partyId')::uuid,s.snapshot->'auxiliary'->>'sourceSystem',
  s.snapshot->'auxiliary'->>'sourceCode',s.snapshot->'auxiliary'->>'sourceName',o.id::text,o.line_sequence,
  jsonb_build_object('version',1,'customerOffsetId',o.id,'account',s.snapshot),n.created_by
 FROM finance_native_customer_offset_accounts n JOIN customer_open_item_offsets o ON o.id=n.offset_id
 JOIN gl_vouchers v ON v.source='AUTO' AND v.source_type='CUSTOMER_PREPAYMENT_OFFSET' AND v.source_doc_id=o.offset_batch_id
  AND v.period=p_period AND v.status=1 AND NOT v.is_deleted
 CROSS JOIN LATERAL(VALUES(n.source_account,1000+o.line_sequence*2),(n.target_account,1001+o.line_sequence*2))s(snapshot,line_no)
 JOIN gl_entries e ON e.voucher_id=v.id AND e.line_no=s.line_no AND NOT e.is_deleted
 WHERE (s.snapshot->>'complete')::boolean AND e.style_id=(s.snapshot->>'styleId')::uuid
  AND NOT EXISTS(SELECT 1 FROM finance_gl_entry_allocations old WHERE old.entry_id=e.id);
 GET DIAGNOSTICS inserted=ROW_COUNT;RETURN inserted;
END $$;

SELECT fn_audit_track_table('finance_native_posting_configurations','COLUMN_SCOPED','data_change',false,ARRAY['id','request_id','role_key','configuration_version','status','created_by','approved_by'],true,NULL);
SELECT fn_audit_track_table('finance_native_debt_accounts','COLUMN_SCOPED','data_change',false,ARRAY['ledger_id','source_fingerprint','evidence_kind','created_by'],true,NULL);
SELECT fn_audit_track_table('finance_native_cash_debt_parts','COLUMN_SCOPED','data_change',false,ARRAY['kind','cash_id','source_line_id','ledger_id','source_fingerprint','created_by'],true,NULL);
SELECT fn_audit_track_table('finance_native_cash_accounts','COLUMN_SCOPED','data_change',false,ARRAY['kind','cash_id','created_by'],true,NULL);
SELECT fn_audit_track_table('finance_native_supplier_offset_journals','COLUMN_SCOPED','data_change',false,ARRAY['offset_id','voucher_id','reversal_voucher_id','created_by'],true,NULL);
SELECT fn_audit_track_table('finance_native_customer_offset_accounts','COLUMN_SCOPED','data_change',false,ARRAY['offset_id','created_by'],true,NULL);
SELECT fn_audit_track_table('finance_native_debt_entry_refs','COLUMN_SCOPED','data_change',false,ARRAY['ledger_id','entry_id','voucher_id','created_by'],true,NULL);
SELECT fn_audit_track_table('finance_native_debt_correspondence_reviews','COLUMN_SCOPED','data_change',false,ARRAY['id','request_id','ledger_id','entry_id','source_fingerprint','status','created_by','approved_by'],true,NULL);

-- Capacity-source partition only. GL reports and bank facts continue to read the complete ledger.
-- Fixed source_type values below are the owning writers' protocols, not account names or code prefixes.
-- Their identities are visible during the same atomic posting before final reference rows are inserted.
CREATE VIEW v_finance_native_prepayment_gl_allocations AS
 WITH originals AS NOT MATERIALIZED (
  SELECT a.entry_id,a.allocation_no,e.voucher_id,e.line_no
  FROM finance_supplier_advances advance JOIN gl_vouchers v ON v.source='AUTO' AND v.source_type='PAYMENT' AND v.source_doc_id=advance.payment_id
  JOIN gl_entries e ON e.voucher_id=v.id AND e.line_no=1 AND e.style_id=advance.style_id
  JOIN finance_gl_entry_allocations a ON a.entry_id=e.id AND a.account_code=advance.account_code
    AND a.auxiliary_id=advance.auxiliary_id AND a.original_currency_id=advance.currency_id
 ), clearings AS NOT MATERIALIZED (
  SELECT clearing.entry_id,clearing.allocation_no FROM finance_gl_settlement_clearings clearing
  JOIN finance_gl_settlement_reservations reservation ON reservation.id=clearing.reservation_id
  JOIN originals source ON source.entry_id=clearing.source_entry_id AND source.allocation_no=clearing.source_allocation_no
  WHERE reservation.owner_kind IN('SUPPLIER_ADVANCE_APPLICATION','SUPPLIER_ADVANCE_REFUND') AND reservation.mode='EXPLICIT_GL_SOURCE'
 )
 SELECT entry_id,allocation_no FROM originals
 UNION SELECT a.entry_id,a.allocation_no FROM originals original
  JOIN gl_vouchers reverse ON reverse.reversal_of_voucher_id=original.voucher_id AND reverse.source='AUTO' AND reverse.source_type='PAYMENT_REV'
  JOIN gl_entries e ON e.voucher_id=reverse.id AND e.line_no=original.line_no
  JOIN finance_gl_entry_allocations a ON a.entry_id=e.id
 UNION SELECT entry_id,allocation_no FROM clearings
 UNION SELECT reverse.entry_id,reverse.allocation_no FROM finance_gl_settlement_reversals reverse
  JOIN clearings original ON original.entry_id=reverse.original_entry_id AND original.allocation_no=reverse.original_allocation_no;

CREATE VIEW v_finance_native_managed_gl_allocations AS
 SELECT a.entry_id,a.allocation_no FROM finance_gl_entry_allocations a JOIN gl_entries e ON e.id=a.entry_id JOIN gl_vouchers v ON v.id=e.voucher_id
 WHERE v.source='AUTO' AND (
   v.source_type IN('PROCUREMENT_PENDING','PROCUREMENT_PENDING_REV','PROCUREMENT_AP_RECOGNITION','PROCUREMENT_AP_RECOGNITION_REV',
     'NATIVE_ARAP_REV','NATIVE_SUPPLIER_OFFSET','NATIVE_SUPPLIER_OFFSET_REV',
     'SUPPLIER_ADVANCE_APPLICATION','SUPPLIER_ADVANCE_APPLICATION_REV','SUPPLIER_ADVANCE_REFUND','SUPPLIER_ADVANCE_REFUND_REV')
   OR EXISTS(SELECT 1 FROM finance_native_debt_entry_refs frozen WHERE frozen.entry_id=e.id)
   OR(v.source_type IN('AR_POST','AP_POST') AND EXISTS(SELECT 1 FROM ar_ap_ledger ledger
       WHERE ledger.source_doc_id=v.source_doc_id AND ledger.source_doc_id=e.source_doc_id AND ledger.source_doc_type=e.source_doc_type
         AND ledger.direction=CASE v.source_type WHEN 'AR_POST' THEN 'AR' ELSE 'AP' END))
   OR(v.source_type='CUSTOMER_PREPAYMENT_OFFSET' AND EXISTS(SELECT 1 FROM customer_open_item_offset_batches batch WHERE batch.id=v.source_doc_id))
   OR(v.source_type='PAYMENT' AND EXISTS(SELECT 1 FROM finance_payments cash WHERE cash.id=v.source_doc_id)
       AND(e.line_no=1 OR EXISTS(SELECT 1 FROM finance_native_cash_debt_parts part WHERE part.kind='PAYMENT' AND part.cash_id=v.source_doc_id AND e.line_no=1000+part.line_no)))
   OR(v.source_type='RECEIPT' AND EXISTS(SELECT 1 FROM finance_receipts cash WHERE cash.id=v.source_doc_id)
       AND(e.line_no=2 OR EXISTS(SELECT 1 FROM finance_native_cash_debt_parts part WHERE part.kind='RECEIPT' AND part.cash_id=v.source_doc_id AND e.line_no=1000+part.line_no)))
   OR(v.source_type IN('PAYMENT_REV','RECEIPT_REV') AND EXISTS(SELECT 1 FROM gl_vouchers original
       JOIN gl_entries origin ON origin.voucher_id=original.id AND origin.line_no=e.line_no
       WHERE original.id=v.reversal_of_voucher_id AND original.source='AUTO' AND original.source_doc_id=v.source_doc_id
         AND((original.source_type='PAYMENT' AND v.source_type='PAYMENT_REV' AND EXISTS(SELECT 1 FROM finance_payments cash WHERE cash.id=original.source_doc_id)
           AND(origin.line_no=1 OR EXISTS(SELECT 1 FROM finance_native_cash_debt_parts part WHERE part.kind='PAYMENT' AND part.cash_id=original.source_doc_id AND origin.line_no=1000+part.line_no)))
          OR(original.source_type='RECEIPT' AND v.source_type='RECEIPT_REV' AND EXISTS(SELECT 1 FROM finance_receipts cash WHERE cash.id=original.source_doc_id)
           AND(origin.line_no=2 OR EXISTS(SELECT 1 FROM finance_native_cash_debt_parts part WHERE part.kind='RECEIPT' AND part.cash_id=original.source_doc_id AND origin.line_no=1000+part.line_no))))))
 )
 UNION SELECT entry_id,allocation_no FROM v_finance_native_prepayment_gl_allocations;
COMMENT ON VIEW v_finance_native_managed_gl_allocations IS '已由原生往来/现金/抵销管理的精确GL allocation身份；仅用于清偿预算分区，不过滤GL全账或财务报表';
COMMENT ON VIEW v_finance_native_prepayment_gl_allocations IS '真实供应商预付资产原额、原生应用/退款清偿及镜像反向；仅可信本域EXPLICIT原源可用，通用owner不得认领';
