-- A bank reference is optional input. Retain every other actual-bank and
-- double-entry constraint; never invent a bank reference for existing records.
DO $$
DECLARE v RECORD; d TEXT;
BEGIN
    FOR v IN
        SELECT conrelid::regclass relation, conname, pg_get_constraintdef(oid) definition
        FROM pg_constraint
        WHERE (conrelid='finance_receipts'::regclass AND conname='finance_receipts_v1_external_evidence_chk')
           OR (conrelid='finance_payments'::regclass AND conname='finance_payments_v2_shape_chk')
    LOOP
        d := replace(v.definition,
            '(NULLIF(btrim((bank_reference)::text), ''''::text) IS NOT NULL)',
            '(bank_reference IS NULL OR length(bank_reference)<=128)');
        IF d=v.definition THEN
            RAISE EXCEPTION 'Optional bank-reference migration: unexpected constraint definition %', v.conname;
        END IF;
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', v.relation, v.conname);
        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', v.relation, v.conname, d);
    END LOOP;
END $$;
