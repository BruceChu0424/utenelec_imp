-- New allocations use the empty-prefix six-digit sequence. UT namespace,
-- release certificates and all historical reservations remain immutable.
-- Historical renumbering is an explicit reviewed maintenance transaction, NOT
-- inferred from names or applied on application startup.
INSERT INTO master_code_sequences(prefix,last_seq)
SELECT '', GREATEST(2, COALESCE(MAX(code::integer),0))
FROM employees WHERE code ~ '^[0-9]{6}$'
ON CONFLICT(prefix) DO UPDATE
SET last_seq=GREATEST(master_code_sequences.last_seq,EXCLUDED.last_seq);

CREATE FUNCTION fn_sync_employee_numeric_sequence() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    IF NEW.code ~ '^[0-9]{6}$' THEN
        INSERT INTO public.master_code_sequences(prefix,last_seq)
        VALUES ('',GREATEST(2,NEW.code::integer))
        ON CONFLICT(prefix) DO UPDATE
        SET last_seq=GREATEST(master_code_sequences.last_seq,EXCLUDED.last_seq);
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_sync_employee_numeric_sequence AFTER INSERT OR UPDATE OF code ON employees
FOR EACH ROW EXECUTE FUNCTION fn_sync_employee_numeric_sequence();

-- One immutable receipt per business dataset. The plan contains only reviewed
-- identity/code/date snapshots, never credentials or encrypted personnel data.
CREATE TABLE employee_code_numbering_receipts (
    dataset_id uuid PRIMARY KEY,
    plan_sha256 text NOT NULL CHECK(plan_sha256 ~ '^[0-9a-f]{64}$'),
    plan jsonb NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    applied_by text NOT NULL DEFAULT session_user,
    evidence_reference text NOT NULL CHECK(length(btrim(evidence_reference)) BETWEEN 1 AND 1000)
);
CREATE TRIGGER trg_employee_code_numbering_receipt_immutable
BEFORE UPDATE OR DELETE ON employee_code_numbering_receipts
FOR EACH ROW EXECUTE FUNCTION fn_guard_business_identifier_append_only();
CREATE TRIGGER trg_employee_code_numbering_receipt_no_truncate
BEFORE TRUNCATE ON employee_code_numbering_receipts
FOR EACH STATEMENT EXECUTE FUNCTION fn_guard_business_identifier_append_only();
REVOKE ALL ON employee_code_numbering_receipts FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='uten') THEN
        REVOKE ALL ON employee_code_numbering_receipts FROM uten;
    END IF;
END $$;
SELECT fn_audit_track_table('employee_code_numbering_receipts','FULL','data_change',false);

-- Old code-only permission imports must require explicit identity mapping after
-- renumbering too. Never reinterpret old snapshots as a different person.
CREATE OR REPLACE FUNCTION fn_employee_code_requires_identity_mapping(p_code text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
    SELECT EXISTS(SELECT 1 FROM public.employee_code_reuse_releases WHERE normalized_code=upper(btrim(p_code)))
        OR EXISTS(SELECT 1 FROM public.employee_identity_merges WHERE upper(btrim(source_code))=upper(btrim(p_code)))
        OR EXISTS(SELECT 1 FROM public.employee_code_numbering_receipts receipt,
                       jsonb_array_elements(receipt.plan->'entries') entry
                  WHERE upper(btrim(entry->>'oldCode'))=upper(btrim(p_code))
                    AND entry->>'oldCode' IS DISTINCT FROM entry->>'newCode')
$$;

CREATE FUNCTION fn_guard_employee_fixed_numeric_code() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    IF EXISTS(SELECT 1 FROM public.employee_code_numbering_receipts receipt
              JOIN public.authorization_state state ON state.business_dataset_id=receipt.dataset_id
              WHERE state.singleton_id=1) THEN
        IF TG_OP='INSERT' THEN
            IF NEW.code !~ '^[0-9]{6}$' OR NEW.code<'000003' THEN
                RAISE EXCEPTION 'New employees require a six-digit number after the reserved founders' USING ERRCODE='23514';
            END IF;
        ELSIF NEW.code IS DISTINCT FROM OLD.code THEN
            RAISE EXCEPTION 'Assigned employee numbers are fixed after initial numbering' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_employee_fixed_numeric_code BEFORE INSERT OR UPDATE OF code ON employees
FOR EACH ROW EXECUTE FUNCTION fn_guard_employee_fixed_numeric_code();
ALTER TABLE employees ENABLE ALWAYS TRIGGER trg_employee_fixed_numeric_code;
