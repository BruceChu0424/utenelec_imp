-- Distinguish a retained plan without an effective arrangement from a withdrawn plan.
-- Display reasons only: direct-transfer eligibility, quantities and ordering remain unchanged.
DO $patch$
DECLARE
    definition TEXT;
    needle TEXT;
    replacement TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_workshop_direct_reason_text(text,text,text,text,text,numeric,numeric)'::regprocedure)
      INTO definition;
    needle := 'WHEN ''PACKAGE_NOT_CONFIRMED'' THEN format(''%s的计划包已取消，不再接收直送'', receiver)';
    replacement := 'WHEN ''PACKAGE_NOT_CONFIRMED'' THEN format(''%s尚无有效执行安排，暂不能接收直送'', receiver)';
    IF (length(definition) - length(replace(definition, needle, ''))) / length(needle) <> 1 THEN
        RAISE EXCEPTION 'V856 direct-transfer package reason anchor changed' USING ERRCODE = '23514';
    END IF;
    EXECUTE replace(definition, needle, replacement);

    SELECT pg_get_functiondef('fn_workshop_direct_targets(uuid,uuid,numeric)'::regprocedure)
      INTO definition;
    needle := E'WHEN coded.is_closed THEN ''已结案''\n                       WHEN coded.is_stopped THEN ''已暂停''';
    -- Reversal preserves the original stop/close flags; its terminal status wins.
    replacement := E'WHEN coded.plan_status = -1 THEN ''已红冲''\n                       WHEN coded.is_closed THEN ''已结案''\n                       WHEN coded.is_stopped THEN ''已暂停''';
    IF (length(definition) - length(replace(definition, needle, ''))) / length(needle) <> 1 THEN
        RAISE EXCEPTION 'V856 direct-transfer plan lifecycle reason anchor changed' USING ERRCODE = '23514';
    END IF;
    EXECUTE replace(definition, needle, replacement);
END;
$patch$;
