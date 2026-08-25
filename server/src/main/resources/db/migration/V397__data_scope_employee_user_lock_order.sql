-- V397: make the data-scope recipient guard follow the platform lock order
-- employee -> user. A single joined FOR SHARE lets the planner choose row-lock
-- order and can deadlock with offboarding, which already locks employee first.

CREATE OR REPLACE FUNCTION fn_require_current_data_scope_user()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_employee_id UUID;
    v_account_employee_id UUID;
    v_account_status TEXT;
    v_employee_status TEXT;
BEGIN
    SELECT employee.id, employee.status
    INTO v_employee_id, v_employee_status
    FROM users account
    JOIN employees employee ON employee.id = account.employee_id
    WHERE account.id = NEW.user_id
      AND account.is_deleted = FALSE
      AND employee.is_deleted = FALSE
    FOR SHARE OF employee;

    SELECT account.employee_id, account.status
    INTO v_account_employee_id, v_account_status
    FROM users account
    WHERE account.id = NEW.user_id
      AND account.is_deleted = FALSE
    FOR SHARE OF account;

    IF v_employee_id IS NULL
       OR v_account_employee_id IS DISTINCT FROM v_employee_id
       OR v_account_status IS DISTINCT FROM 'active'
       OR v_employee_status NOT IN ('active', 'probation', 'onLeave') THEN
        RAISE EXCEPTION 'data-scope recipient must be a current employee with an active account'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'user_data_scopes_current_recipient';
    END IF;
    RETURN NEW;
END;
$$;
