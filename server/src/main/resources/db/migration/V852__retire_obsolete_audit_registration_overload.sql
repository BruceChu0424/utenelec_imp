-- Older installations can retain V670's defaulted six-argument function beside
-- V830's canonical seven-argument entry. Four-argument registration then raises
-- 42725. V846/V851 compatibility is handled transactionally before those immutable
-- migrations; this forward migration also retires the overload on already-upgraded
-- databases. Existing audit triggers, scoped columns and historical rows are unchanged.
DO $retire_obsolete_audit_overload$
BEGIN
    IF to_regprocedure('public.fn_audit_track_table(text,text,text,boolean,text[],boolean,text)') IS NULL THEN
        RAISE EXCEPTION 'Canonical seven-argument audit registration function is missing'
            USING ERRCODE='42883';
    END IF;
    DROP FUNCTION IF EXISTS public.fn_audit_track_table(text,text,text,boolean,text[],boolean);
END $retire_obsolete_audit_overload$;
