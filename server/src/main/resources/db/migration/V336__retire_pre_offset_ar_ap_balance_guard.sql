-- V129's local balance check predates explicit non-cash supplier offsets.
-- V330 installed and validated the stronger replacement while every offset was
-- still zero; retire the old equation before the online offset workflow opens.

ALTER TABLE ar_ap_ledger
    DROP CONSTRAINT IF EXISTS ar_ap_ledger_balance_consistency_chk;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'ar_ap_ledger'::regclass
          AND conname = 'ar_ap_ledger_local_balance_chk'
          AND convalidated
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '55000',
            MESSAGE = 'validated V330 ar_ap local balance guard is required';
    END IF;
END
$$;
