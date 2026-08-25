-- V395: close the race between offboarding and new responsibility/visibility
-- assignments. Offboarding marks the employee resigned inside its transaction;
-- concurrent assignments must wait for that row and then fail closed.

CREATE OR REPLACE FUNCTION fn_require_current_employee_reference()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_column TEXT := TG_ARGV[0];
    v_new_id UUID := NULLIF(to_jsonb(NEW) ->> v_column, '')::UUID;
    v_old_id UUID;
    v_status TEXT;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        v_old_id := NULLIF(to_jsonb(OLD) ->> v_column, '')::UUID;
        IF v_new_id IS NOT DISTINCT FROM v_old_id THEN
            RETURN NEW;
        END IF;
    END IF;
    IF v_new_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT employee.status
    INTO v_status
    FROM employees employee
    WHERE employee.id = v_new_id
      AND employee.is_deleted = FALSE
    FOR SHARE;
    IF v_status IS NULL OR v_status NOT IN ('active', 'probation', 'onLeave') THEN
        RAISE EXCEPTION 'responsibility target must be a current employee'
            USING ERRCODE = '23514',
                  CONSTRAINT = TG_TABLE_NAME || '_' || v_column || '_current_employee';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_require_current_data_scope_user()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_account_status TEXT;
    v_employee_status TEXT;
BEGIN
    SELECT account.status, employee.status
    INTO v_account_status, v_employee_status
    FROM users account
    JOIN employees employee ON employee.id = account.employee_id
    WHERE account.id = NEW.user_id
      AND account.is_deleted = FALSE
      AND employee.is_deleted = FALSE
    FOR SHARE OF account, employee;

    IF v_account_status IS DISTINCT FROM 'active'
       OR v_employee_status IS NULL
       OR v_employee_status NOT IN ('active', 'probation', 'onLeave') THEN
        RAISE EXCEPTION 'data-scope recipient must be a current employee with an active account'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'user_data_scopes_current_recipient';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_user_data_scopes_current_recipient
BEFORE INSERT OR UPDATE OF user_id ON user_data_scopes
FOR EACH ROW EXECUTE FUNCTION fn_require_current_data_scope_user();
