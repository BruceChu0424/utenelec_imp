-- The existing analysis command ledger also owns pre-approval allowance edits.
-- Execution allowances continue to use the immutable V698 request/decision ledger.
DO $rate_command$
DECLARE definition TEXT; anchor TEXT := '''GENERATE_PLAN''::text';
BEGIN
    SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint
    WHERE conrelid='production_material_analysis_commands'::regclass
      AND conname='production_material_analysis_command_operation_chk';
    IF definition IS NULL OR (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V863 cannot safely extend the analysis command operation contract';
    END IF;
    ALTER TABLE production_material_analysis_commands DROP CONSTRAINT production_material_analysis_command_operation_chk;
    EXECUTE 'ALTER TABLE production_material_analysis_commands ADD CONSTRAINT production_material_analysis_command_operation_chk '
        ||replace(definition,anchor,anchor||',''OVERPRODUCTION_RATE''::text');
END;
$rate_command$;
