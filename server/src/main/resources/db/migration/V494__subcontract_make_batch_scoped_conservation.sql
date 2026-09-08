-- Validate existing facts once; normal batch mutations must not scan every task.
SELECT fn_assert_subcontract_make_task_batches();

CREATE OR REPLACE FUNCTION fn_assert_subcontract_make_task_batches(p_task_id UUID)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_status TEXT;
    v_notified NUMERIC(18,4);
    v_batches NUMERIC(18,4);
BEGIN
    IF p_task_id IS NULL THEN
        RETURN;
    END IF;
    -- Serialize writers for this task only. The following statement gets the
    -- post-lock snapshot, including any batch committed while this lock waited.
    SELECT status, notified_qty INTO v_status, v_notified
    FROM preplan_subcontract_make_tasks
    WHERE id = p_task_id
    FOR UPDATE;
    IF v_status IS DISTINCT FROM 'ACTIVE' THEN
        RETURN;
    END IF;
    SELECT COALESCE(SUM(notify_qty), 0) INTO v_batches
    FROM preplan_subcontract_make_task_batches
    WHERE task_id = p_task_id;
    IF v_notified IS DISTINCT FROM v_batches THEN
        RAISE EXCEPTION 'subcontract make task notified qty lacks exact batch coverage'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'subcontract_make_task_batch_conservation_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_check_subcontract_make_task_batches()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_task UUID;
    v_new_task UUID;
    v_task UUID;
BEGIN
    IF TG_TABLE_NAME = 'preplan_subcontract_make_task_batches' THEN
        IF TG_OP <> 'INSERT' THEN v_old_task := OLD.task_id; END IF;
        IF TG_OP <> 'DELETE' THEN v_new_task := NEW.task_id; END IF;
    ELSE
        IF TG_OP <> 'INSERT' THEN v_old_task := OLD.id; END IF;
        IF TG_OP <> 'DELETE' THEN v_new_task := NEW.id; END IF;
    END IF;
    -- Preserve both sides of updates, in deterministic order, and the existing
    -- deferred trigger protocol. Existing history/lineage guards remain active.
    FOR v_task IN
        SELECT DISTINCT task_id
        FROM unnest(ARRAY[v_old_task, v_new_task]) AS changed(task_id)
        WHERE task_id IS NOT NULL
        ORDER BY task_id
    LOOP
        PERFORM fn_assert_subcontract_make_task_batches(v_task);
    END LOOP;
    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION fn_assert_subcontract_make_task_batches(UUID) IS
    'Validate one locked subcontract make task against its indexed batch sum; the zero-argument overload remains a full audit.';
