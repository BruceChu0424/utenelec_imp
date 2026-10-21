-- Clearing transaction data must not revoke existing manager delegations.
-- V322 binds those grants to authorization_state.epoch; V462/V782 advanced that
-- authorization epoch only to sign everyone out, accidentally invalidating them.
-- Keep the existing session cleanup and advance only the business dataset fence.
-- This migration changes the installed reset function, never existing data.
DO $preserve_reset_authorization$
DECLARE
    definition text;
    before_attributes record;
    after_attributes record;
    before_rows text[];
    after_rows text[];
    edits text[][];
    needle text;
    replacement text;
    occurrences integer;
    i integer;
    policy_pattern constant text := '\(''([a-z][a-z0-9_]*)''\s*,\s*''(CLEAR|PRESERVE)''\)';
BEGIN
    SELECT proowner, proacl, prosecdef, proconfig INTO before_attributes
    FROM pg_catalog.pg_proc WHERE oid = 'public.business_data_reset()'::regprocedure;
    definition := replace(pg_catalog.pg_get_functiondef('public.business_data_reset()'::regprocedure), E'\r\n', E'\n');

    -- The single intended classification change preserves the security failure
    -- counter and lockout state. Every other CLEAR/PRESERVE boundary stays exact.
    SELECT coalesce(array_agg(m[1] || ':' || CASE
               WHEN m[1] = 'auth_step_up_states' THEN 'PRESERVE' ELSE m[2] END
               ORDER BY m[1], m[2]), ARRAY[]::text[]) INTO before_rows
    FROM regexp_matches(definition, policy_pattern, 'g') AS m;

    edits := ARRAY[
        ARRAY['SET epoch = epoch + 1, business_reset_generation = business_reset_generation + 1',
              'SET business_reset_generation = business_reset_generation + 1'],
        ARRAY['(''auth_step_up_states'', ''CLEAR'')',
              '(''auth_step_up_states'', ''PRESERVE'')'],
        ARRAY['    -- epoch + 1 让所有存量 staff access token 下一请求 401；',
              '    -- auth_sessions 已在 CLEAR 清单中清空, 使旧 access token 的 sid 失效;'
              || E'\n' || '    -- 业务代次推进只隔离旧业务结果和草稿, 不改变权限纪元或负责人委派。']
    ];
    FOR i IN 1 .. array_length(edits, 1) LOOP
        needle := edits[i][1];
        replacement := edits[i][2];
        occurrences := (length(definition) - length(replace(definition, needle, ''))) / length(needle);
        IF occurrences <> 1 THEN
            RAISE EXCEPTION 'V889 reset edit % expected one occurrence of its anchor, found %', i, occurrences;
        END IF;
        definition := replace(definition, needle, replacement);
    END LOOP;

    -- Re-login is enforced by server-side sessions and refresh tokens, separately
    -- from authorization. Preserve the authenticated entry and generation guard.
    IF strpos(definition, 'PERFORM public.fn_require_runtime_maintenance(true);') = 0
       OR strpos(definition, 'PERFORM public.fn_clear_business_test_object_metadata();') = 0
       OR strpos(definition, '(''auth_sessions'', ''CLEAR'')') = 0
       OR strpos(definition, 'TRUNCATE TABLE refresh_tokens RESTART IDENTITY;') = 0
       OR strpos(definition, E'SELECT epoch\n    INTO epoch_after_value') = 0
       OR strpos(definition, 'SET epoch = epoch + 1') <> 0 THEN
        RAISE EXCEPTION 'V889 cannot preserve the authenticated reset, session cleanup and unchanged authorization epoch';
    END IF;

    -- CREATE OR REPLACE retains the installed owner and execute grants.
    EXECUTE definition;

    SELECT coalesce(array_agg(p.table_name || ':' || p.disposition ORDER BY p.table_name, p.disposition), ARRAY[]::text[])
    INTO after_rows FROM public.fn_business_reset_table_policy() p;
    IF before_rows IS DISTINCT FROM after_rows THEN
        RAISE EXCEPTION 'V889 changed reset table classifications beyond preserving auth_step_up_states';
    END IF;

    SELECT proowner, proacl, prosecdef, proconfig INTO after_attributes
    FROM pg_catalog.pg_proc WHERE oid = 'public.business_data_reset()'::regprocedure;
    IF before_attributes IS DISTINCT FROM after_attributes THEN
        RAISE EXCEPTION 'V889 changed reset execution privileges, security attributes or owner';
    END IF;
END $preserve_reset_authorization$;
