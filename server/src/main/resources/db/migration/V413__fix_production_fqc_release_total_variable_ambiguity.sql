-- Forward repair for V410: PL/pgSQL variable names such as pass_qty and
-- command_id collided with identically named columns when the deferred
-- constraint trigger ran at commit. Keep V410 bytes immutable and replace only
-- the function body with explicit aliases and v_* local variables.

CREATE OR REPLACE FUNCTION fn_validate_production_fqc_release_totals()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_command_id UUID;
    v_decision_id UUID;
    v_command_qty NUMERIC(18,4);
    v_allocated_command_qty NUMERIC(18,4);
    v_decision_pass_qty NUMERIC(18,4);
    v_allocated_pass_qty NUMERIC(18,4);
    v_command_inspection UUID;
    v_decision_inspection UUID;
BEGIN
    IF TG_TABLE_NAME = 'production_fqc_release_commands' THEN
        v_command_id := NEW.id;
        v_decision_id := NULL;
    ELSE
        v_command_id := NEW.release_command_id;
        v_decision_id := NEW.decision_event_id;
    END IF;

    SELECT command.requested_qty, command.inspection_id
    INTO v_command_qty, v_command_inspection
    FROM production_fqc_release_commands command
    WHERE command.id = v_command_id;

    SELECT COALESCE(SUM(allocation.qty), 0)
    INTO v_allocated_command_qty
    FROM production_fqc_release_allocations allocation
    WHERE allocation.release_command_id = v_command_id;

    IF v_command_qty IS NOT NULL
       AND v_allocated_command_qty IS DISTINCT FROM v_command_qty THEN
        RAISE EXCEPTION
            'FQC release allocations must equal requested quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_fqc_release_command_total_guard';
    END IF;

    IF v_decision_id IS NOT NULL THEN
        SELECT decision.pass_qty, decision.inspection_id
        INTO v_decision_pass_qty, v_decision_inspection
        FROM production_fqc_decision_events decision
        WHERE decision.id = v_decision_id;

        SELECT COALESCE(SUM(allocation.qty), 0)
        INTO v_allocated_pass_qty
        FROM production_fqc_release_allocations allocation
        WHERE allocation.decision_event_id = v_decision_id;

        IF v_decision_pass_qty IS NULL
           OR v_decision_pass_qty <= 0
           OR v_decision_inspection <> v_command_inspection
           OR v_allocated_pass_qty > v_decision_pass_qty THEN
            RAISE EXCEPTION
                'FQC FINISHED_IN allocation exceeds PASS quantity'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_fqc_pass_capacity_guard';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;
