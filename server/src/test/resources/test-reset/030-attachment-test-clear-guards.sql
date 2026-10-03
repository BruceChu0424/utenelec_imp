-- V782 assembly fragment, after 020. Ordinary row/byte identity guards remain enabled.
DO $attachment_test_clear_guards$
DECLARE definition text; marker text:=E'\nBEGIN\n'; insertion text;
BEGIN
    SELECT replace(pg_get_functiondef('public.fn_attachment_retained_identity_guard()'::regprocedure),E'\r\n',E'\n') INTO definition;
    IF strpos(definition,marker)=0 THEN RAISE EXCEPTION 'V782 cannot locate immutable attachment entry'; END IF;
    insertion:=E'    IF TG_OP=''DELETE'' AND public.fn_business_test_reset_active() THEN\n'
      || E'        IF upper(btrim(OLD.owner_type)) IN(''GOODS'',''EMPLOYEE'',''EMPLOYEE_CONTRACT'')\n'
      || E'           OR EXISTS(SELECT 1 FROM public.fn_business_test_object_sources() s WHERE s.source_type=''ATTACHMENT'' AND s.source_id=OLD.id::text) THEN\n'
      || E'            RAISE EXCEPTION ''Protected or physically unproven attachment cannot be cleared'' USING ERRCODE=''23514'';\n'
      || E'        END IF; RETURN OLD;\n    END IF;\n';
    definition:=overlay(definition placing marker||insertion from strpos(definition,marker) for length(marker));
    EXECUTE definition;
END $attachment_test_clear_guards$;

-- Root business_data_reset() must invoke fn_clear_business_test_object_metadata()
-- BEFORE its PRESERVE counts/any CLEAR/TRUNCATE, and classify business_test_object_cleanup_intents as CLEAR.
-- This function first asserts current-generation exact physical tickets for EVERY unprotected external source.
-- The ordinary attachments-no-TRUNCATE guard remains unchanged: mixed GOODS/HR rows must never be bulk truncated.
