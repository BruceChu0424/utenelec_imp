-- Preserve the already-applied V937 bytes and move the account-lock optimization forward.
-- CREATE OR REPLACE retains the function identity, trigger bindings, owner and ACL.
CREATE OR REPLACE FUNCTION fn_guard_employee_identity_alias_account() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    IF TG_OP='UPDATE' AND NEW.employee_id IS NOT DISTINCT FROM OLD.employee_id
       AND NEW.is_deleted IS NOT DISTINCT FROM OLD.is_deleted THEN
        RETURN NEW;
    END IF;
    IF NEW.employee_id IS NOT NULL AND NOT NEW.is_deleted THEN
        -- Alias verification locks this same employee; unrelated accounts need no shared lock.
        PERFORM id FROM public.employees WHERE id=NEW.employee_id FOR UPDATE;
        IF EXISTS(SELECT 1 FROM employee_identity_aliases WHERE alias_employee_id=NEW.employee_id) THEN
            RAISE EXCEPTION 'A login account must bind to the canonical employee identity'
                USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END $$;
