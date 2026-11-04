-- Source facts stay in gl_entries. Auxiliary/currency allocations must reconcile to that one amount.
CREATE TABLE finance_accounting_import_batches (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), actor_id uuid NOT NULL REFERENCES users(id),
    source_name text NOT NULL, storage_provider text NOT NULL,storage_key text NOT NULL,storage_version text,
    storage_size bigint NOT NULL CHECK(storage_size>0),sha256 text NOT NULL CHECK(sha256~'^[0-9a-f]{64}$'),
    source_system text NOT NULL,preview jsonb NOT NULL, reviewed_input jsonb,
    status text NOT NULL DEFAULT 'PREVIEW' CHECK(status IN('PREVIEW','SUBMITTED','POSTED','REJECTED','CANCELLED')),
    row_version bigint NOT NULL DEFAULT 0,submitted_by uuid REFERENCES users(id),submitted_at timestamptz,
    approved_by uuid REFERENCES users(id),approved_at timestamptz,result jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(actor_id,sha256,source_system),CHECK(approved_by IS NULL OR approved_by<>submitted_by),
    CHECK((status='POSTED')=(result IS NOT NULL))
);
CREATE TABLE finance_gl_voucher_evidence (
    voucher_id uuid PRIMARY KEY REFERENCES gl_vouchers(id),
    import_batch_id uuid REFERENCES finance_accounting_import_batches(id),
    purpose text NOT NULL CHECK(purpose IN('OPERATING','OPENING','PNL_CLOSE','PNL_CLOSE_REVERSAL','PRIOR_YEAR_ADJUSTMENT','RECLASSIFICATION')),
    source_system text NOT NULL,source_ledger text NOT NULL,source_year integer NOT NULL,source_period integer NOT NULL CHECK(source_period BETWEEN 1 AND 12),
    source_voucher_type text NOT NULL,source_voucher_no text NOT NULL,source_voucher_id text,
    source_sha256 text NOT NULL CHECK(source_sha256~'^[0-9a-f]{64}$'),source_snapshot jsonb NOT NULL,
    submitted_by uuid NOT NULL REFERENCES users(id),approved_by uuid NOT NULL REFERENCES users(id),
    approved_at timestamptz NOT NULL DEFAULT now(),reversed_voucher_id uuid REFERENCES gl_vouchers(id),
    UNIQUE(source_system,source_ledger,source_year,source_period,source_voucher_type,source_voucher_no),
    CHECK(submitted_by<>approved_by)
);
CREATE TABLE finance_gl_entry_allocations (
    entry_id uuid NOT NULL REFERENCES gl_entries(id),allocation_no integer NOT NULL CHECK(allocation_no BETWEEN 1 AND 2000),
    account_code text NOT NULL REFERENCES finance_chart_codes(code),
    source_account_code text NOT NULL,source_account_name text,source_account_path_name text,
    auxiliary_id uuid, -- V994 installs the owning auxiliary FK after its directory exists.
    currency_id uuid REFERENCES currencies(id),original_currency_id uuid REFERENCES currencies(id),
    amount_local numeric NOT NULL CHECK(fn_financial_book_amount_is_exact(amount_local)),
    amount_original numeric CHECK(fn_financial_amount_is_exact(amount_original)),exchange_rate numeric CHECK(fn_financial_amount_is_exact(exchange_rate)),
    auxiliary_role text CHECK(auxiliary_role IN('CUSTOMER','SUPPLIER','EMPLOYEE','OTHER')),
    party_id_snapshot uuid,source_system text,source_code text,source_name text,
    source_entry_id text NOT NULL,source_row integer NOT NULL CHECK(source_row>0),source_snapshot jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),created_by uuid NOT NULL REFERENCES users(id),
    PRIMARY KEY(entry_id,allocation_no),
    CHECK(amount_original IS NULL OR original_currency_id IS NOT NULL),
    CHECK(exchange_rate IS NULL OR exchange_rate>0),
    CHECK(auxiliary_id IS NULL OR (auxiliary_role IS NOT NULL AND party_id_snapshot IS NOT NULL
        AND source_system IS NOT NULL AND source_code IS NOT NULL AND source_name IS NOT NULL))
);
CREATE INDEX idx_finance_gl_alloc_account ON finance_gl_entry_allocations(account_code,entry_id);
CREATE INDEX idx_finance_gl_alloc_aux_currency ON finance_gl_entry_allocations(auxiliary_id,currency_id,entry_id);
-- In the existing subledgers -1 marks the original of a real signed reversal; its entries remain facts.
CREATE OR REPLACE FUNCTION fn_finance_gl_voucher_is_booked(p_voucher_id uuid)
RETURNS boolean LANGUAGE sql STABLE STRICT AS $$
    SELECT EXISTS(SELECT 1 FROM gl_vouchers v WHERE v.id=p_voucher_id AND NOT v.is_deleted AND v.status IN(1,-1));
$$;
COMMENT ON COLUMN finance_gl_entry_allocations.currency_id IS '已明确的会计科目/辅助核算币别属性；不是amount_original的单位';
COMMENT ON COLUMN finance_gl_entry_allocations.original_currency_id IS 'amount_original的真实计量币别，来自实际交易或经复核原币资料';

CREATE OR REPLACE FUNCTION fn_finance_entry_is_pnl_closing(p_entry_id uuid)
RETURNS boolean LANGUAGE sql STABLE STRICT AS $$
    SELECT EXISTS(SELECT 1 FROM gl_entries e JOIN finance_gl_voucher_evidence proof ON proof.voucher_id=e.voucher_id
        WHERE e.id=p_entry_id AND proof.purpose IN('PNL_CLOSE','PNL_CLOSE_REVERSAL'));
$$;

CREATE OR REPLACE FUNCTION fn_finance_gl_allocations_reconcile()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE entry_uuid uuid; original_amount numeric; allocated_amount numeric; mismatched boolean;
BEGIN
    entry_uuid:=CASE WHEN TG_OP='DELETE' THEN OLD.entry_id ELSE NEW.entry_id END;
    SELECT amount INTO original_amount FROM gl_entries WHERE id=entry_uuid;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT sum(amount_local),bool_or(amount_local<>0 AND sign(amount_local)<>sign(original_amount))
        INTO allocated_amount,mismatched FROM finance_gl_entry_allocations WHERE entry_id=entry_uuid;
    IF allocated_amount IS NOT NULL AND (allocated_amount<>original_amount OR COALESCE(mismatched,false)) THEN
        RAISE EXCEPTION 'Financial allocation must preserve the complete source local amount and sign' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_finance_gl_allocations_reconcile
    AFTER INSERT OR UPDATE OR DELETE ON finance_gl_entry_allocations DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_finance_gl_allocations_reconcile();

CREATE OR REPLACE FUNCTION fn_finance_gl_evidence_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Posted financial source evidence is immutable; use an explicit reviewed reversal' USING ERRCODE='23514';
END;
$$;
CREATE TRIGGER trg_finance_gl_evidence_immutable BEFORE UPDATE OR DELETE ON finance_gl_voucher_evidence
    FOR EACH ROW EXECUTE FUNCTION fn_finance_gl_evidence_immutable();
CREATE OR REPLACE FUNCTION fn_finance_gl_allocation_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE entry_uuid uuid;
BEGIN
    entry_uuid:=CASE WHEN TG_OP='DELETE' THEN OLD.entry_id ELSE NEW.entry_id END;
    IF EXISTS(SELECT 1 FROM gl_entries e JOIN finance_gl_voucher_evidence proof ON proof.voucher_id=e.voucher_id WHERE e.id=entry_uuid)
        OR (TG_OP='UPDATE' AND EXISTS(SELECT 1 FROM gl_entries e JOIN finance_gl_voucher_evidence proof ON proof.voucher_id=e.voucher_id WHERE e.id=OLD.entry_id)) THEN
        RAISE EXCEPTION 'Posted financial auxiliary snapshots cannot be changed' USING ERRCODE='23514';
    END IF;
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END;
$$;
CREATE TRIGGER trg_finance_gl_allocation_immutable BEFORE INSERT OR UPDATE OR DELETE ON finance_gl_entry_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_finance_gl_allocation_immutable();

-- The allocation cannot remain valid if its authoritative entry or voucher is edited afterwards.
CREATE OR REPLACE FUNCTION fn_finance_proven_entry_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (TG_OP<>'INSERT' AND EXISTS(SELECT 1 FROM finance_gl_voucher_evidence WHERE voucher_id=OLD.voucher_id))
       OR (TG_OP<>'DELETE' AND EXISTS(SELECT 1 FROM finance_gl_voucher_evidence WHERE voucher_id=NEW.voucher_id)) THEN
        RAISE EXCEPTION 'A reviewed source voucher must be reversed explicitly; its GL entries are immutable' USING ERRCODE='23514';
    END IF;
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END;
$$;
CREATE TRIGGER trg_finance_proven_entry_immutable BEFORE INSERT OR UPDATE OR DELETE ON gl_entries
    FOR EACH ROW EXECUTE FUNCTION fn_finance_proven_entry_immutable();
CREATE OR REPLACE FUNCTION fn_finance_proven_voucher_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS(SELECT 1 FROM finance_gl_voucher_evidence WHERE voucher_id=OLD.id) THEN
        IF TG_OP='DELETE' OR (to_jsonb(NEW)-'updated_at'-'updated_by'-'reversed_by_voucher_id')
            IS DISTINCT FROM (to_jsonb(OLD)-'updated_at'-'updated_by'-'reversed_by_voucher_id') THEN
            RAISE EXCEPTION 'A reviewed source voucher is immutable' USING ERRCODE='23514';
        END IF;
        IF OLD.reversed_by_voucher_id IS NOT NULL AND NEW.reversed_by_voucher_id IS DISTINCT FROM OLD.reversed_by_voucher_id THEN
            RAISE EXCEPTION 'A reviewed reversal link is immutable' USING ERRCODE='23514';
        END IF;
        IF NEW.reversed_by_voucher_id IS DISTINCT FROM OLD.reversed_by_voucher_id AND NOT EXISTS(
            SELECT 1 FROM gl_vouchers reversal JOIN finance_gl_voucher_evidence proof ON proof.voucher_id=reversal.id
            WHERE reversal.id=NEW.reversed_by_voucher_id AND reversal.reversal_of_voucher_id=OLD.id
              AND reversal.status=1 AND NOT reversal.is_deleted AND proof.reversed_voucher_id=OLD.id) THEN
            RAISE EXCEPTION 'The reversal must have reviewed evidence and link to this original' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END;
$$;
CREATE TRIGGER trg_finance_proven_voucher_immutable BEFORE UPDATE OR DELETE ON gl_vouchers
    FOR EACH ROW EXECUTE FUNCTION fn_finance_proven_voucher_immutable();

CREATE TRIGGER trg_audit_finance_gl_voucher_evidence AFTER INSERT ON finance_gl_voucher_evidence
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_gl_entry_allocations AFTER INSERT OR UPDATE OR DELETE ON finance_gl_entry_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE finance_gl_voucher_evidence ENABLE ALWAYS TRIGGER trg_audit_finance_gl_voucher_evidence;
ALTER TABLE finance_gl_entry_allocations ENABLE ALWAYS TRIGGER trg_audit_finance_gl_entry_allocations;

-- Whole-month completeness is explicit and invalidated by later source changes, never inferred from no rows.
CREATE TABLE finance_gl_period_versions (
    period char(7) PRIMARY KEY CHECK(period~'^[0-9]{4}-(0[1-9]|1[0-2])$'),revision bigint NOT NULL DEFAULT 0
);
CREATE TABLE finance_accounting_period_coverage (
    period char(7) PRIMARY KEY REFERENCES finance_gl_period_versions(period),
    entries_revision bigint NOT NULL,source_kind text NOT NULL,
    import_batch_id uuid REFERENCES finance_accounting_import_batches(id),
    source_sha256 text NOT NULL CHECK(source_sha256~'^[0-9a-f]{64}$'),
    verified_by uuid NOT NULL REFERENCES users(id),verified_at timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION fn_finance_gl_period_changed()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='INSERT' THEN
        UPDATE finance_gl_period_versions SET revision=revision+1 WHERE period=NEW.period;
    ELSIF TG_OP='DELETE' THEN
        UPDATE finance_gl_period_versions SET revision=revision+1 WHERE period=OLD.period;
    ELSE
        UPDATE finance_gl_period_versions SET revision=revision+1 WHERE period=OLD.period OR period=NEW.period;
    END IF;
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END;
$$;
CREATE TRIGGER trg_finance_gl_period_changed AFTER INSERT OR UPDATE OR DELETE ON gl_entries
    FOR EACH ROW EXECUTE FUNCTION fn_finance_gl_period_changed();
CREATE OR REPLACE FUNCTION fn_finance_gl_purpose_changed()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE finance_gl_period_versions SET revision=revision+1
        WHERE period IN(SELECT period FROM gl_vouchers WHERE id=NEW.voucher_id);
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_finance_gl_purpose_changed AFTER INSERT ON finance_gl_voucher_evidence
    FOR EACH ROW EXECUTE FUNCTION fn_finance_gl_purpose_changed();

-- A verified zero auxiliary balance is evidence, not a fabricated zero-value GL transaction.
CREATE TABLE finance_gl_auxiliary_opening_evidence (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    import_batch_id uuid NOT NULL REFERENCES finance_accounting_import_batches(id),
    account_code text NOT NULL REFERENCES finance_chart_codes(code),auxiliary_id uuid NOT NULL,
    currency_id uuid NOT NULL REFERENCES currencies(id),original_currency_id uuid REFERENCES currencies(id),effective_from date NOT NULL,
    opening_debit numeric NOT NULL CHECK(opening_debit>=0 AND fn_financial_book_amount_is_exact(opening_debit)),
    opening_credit numeric NOT NULL CHECK(opening_credit>=0 AND fn_financial_book_amount_is_exact(opening_credit)),
    entry_id uuid REFERENCES gl_entries(id),
    auxiliary_role text NOT NULL CHECK(auxiliary_role IN('CUSTOMER','SUPPLIER','EMPLOYEE','OTHER')),
    party_id_snapshot uuid NOT NULL,source_system text NOT NULL,source_code text NOT NULL,source_name text NOT NULL,
    source_account_code text NOT NULL,source_account_name text,source_account_path_name text,
    source_sha256 text NOT NULL CHECK(source_sha256~'^[0-9a-f]{64}$'),source_row integer NOT NULL CHECK(source_row>0),
    submitted_by uuid NOT NULL REFERENCES users(id),approved_by uuid NOT NULL REFERENCES users(id),
    approved_at timestamptz NOT NULL DEFAULT now(),CHECK(submitted_by<>approved_by),
    CHECK(entry_id IS NOT NULL OR (opening_debit=0 AND opening_credit=0)),
    UNIQUE(import_batch_id,account_code,auxiliary_id,currency_id)
);
CREATE INDEX idx_finance_gl_aux_opening_scope ON finance_gl_auxiliary_opening_evidence(account_code,auxiliary_id,currency_id,effective_from);
CREATE TRIGGER trg_finance_gl_aux_opening_immutable BEFORE UPDATE OR DELETE ON finance_gl_auxiliary_opening_evidence
    FOR EACH ROW EXECUTE FUNCTION fn_finance_gl_evidence_immutable();
CREATE TRIGGER trg_audit_finance_gl_aux_opening AFTER INSERT ON finance_gl_auxiliary_opening_evidence
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE finance_gl_auxiliary_opening_evidence ENABLE ALWAYS TRIGGER trg_audit_finance_gl_aux_opening;
