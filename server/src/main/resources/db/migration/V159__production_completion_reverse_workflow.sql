-- V159: explicit, atomic reverse-completion workflow.
--
-- A V156 execution segment becomes COMPLETED only after exact finished-product
-- inbound and material settlement. Reversing such an inbound must first reopen
-- the segment inside the same transaction. Direct SQL remains fail-closed:
-- reopening requires a transaction-local stock-document identity plus an
-- idempotent semantic event for the exact segment/version.

ALTER TABLE production_execution_segments
    ADD COLUMN completion_reopened BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN production_execution_segments.completion_reopened IS
    'True only while a previously completed segment is open for correction; released material reservations are not restored.';

ALTER TABLE production_execution_segment_events
    DROP CONSTRAINT production_execution_segment_events_action_check;
ALTER TABLE production_execution_segment_events
    ADD CONSTRAINT production_execution_segment_events_action_check
        CHECK (action IN (
            'ASSIGNMENT', 'DISPATCH', 'START', 'CANCEL', 'REVERSE',
            'REOPEN_COMPLETION'
        ));

CREATE OR REPLACE FUNCTION fn_is_completion_reopen_authorized(
    p_segment_id UUID,
    p_expected_version BIGINT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM stock_documents document
        JOIN stock_document_items item
          ON item.doc_id = document.id
         AND item.execution_segment_id = p_segment_id
         AND item.bill_type = 'FINISHED_IN'
         AND item.is_deleted = FALSE
        JOIN production_execution_segment_events event
          ON event.execution_segment_id = p_segment_id
         AND event.action = 'REOPEN_COMPLETION'
         AND event.idempotency_key =
             'FINISHED_IN_REVERSE:' || document.id::text
         AND event.expected_version = p_expected_version
         AND event.resulting_version = p_expected_version + 1
        WHERE document.doc_type = 'FINISHED_IN'
          AND document.status = 1
          AND document.is_deleted = FALSE
          AND document.id::text =
              current_setting(
                  'app.production_completion_reopen_doc_id', TRUE)
    );
$$;

COMMENT ON FUNCTION fn_is_completion_reopen_authorized(UUID, BIGINT) IS
    'Authorizes one COMPLETED to IN_PROGRESS correction transition for the exact approved FINISHED_IN document and semantic event in the current transaction.';

/*
 * Preserve the complete V155 identity/organization validator and change only
 * its terminal-transition clauses. Using pg_get_functiondef makes this upgrade
 * additive while retaining every existing validation branch verbatim. Each
 * replacement is asserted so a future migration cannot silently weaken the
 * guard if the predecessor definition changes.
 */
DO $migration$
DECLARE
    v_definition TEXT;
    v_updated TEXT;
    v_old_terminal TEXT := $old$
        IF OLD.status IN ('COMPLETED', 'CANCELLED', 'REVERSED')
           AND NEW.status <> OLD.status THEN
            RAISE EXCEPTION 'terminal execution segment is immutable'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_execution_segment_terminal_guard';
        END IF;$old$;
    v_new_terminal TEXT := $new$
        IF OLD.status IN ('COMPLETED', 'CANCELLED', 'REVERSED')
           AND NEW.status <> OLD.status
           AND NOT (
               OLD.status = 'COMPLETED'
               AND NEW.status = 'IN_PROGRESS'
               AND NEW.completion_reopened = TRUE
               AND fn_is_completion_reopen_authorized(
                   OLD.id, OLD.lock_version)
           ) THEN
            RAISE EXCEPTION 'terminal execution segment is immutable'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_execution_segment_terminal_guard';
        END IF;
        IF OLD.completion_reopened IS DISTINCT FROM
               NEW.completion_reopened
           AND NOT (
               OLD.status = 'COMPLETED'
               AND NEW.status = 'IN_PROGRESS'
               AND OLD.completion_reopened = FALSE
               AND NEW.completion_reopened = TRUE
               AND fn_is_completion_reopen_authorized(
                   OLD.id, OLD.lock_version)
           )
           AND NOT (
               OLD.status = 'IN_PROGRESS'
               AND NEW.status = 'COMPLETED'
               AND OLD.completion_reopened = TRUE
               AND NEW.completion_reopened = FALSE
           ) THEN
            RAISE EXCEPTION
                'completion correction flag may only change in the explicit reverse-completion workflow'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_execution_segment_completion_reopen_guard';
        END IF;$new$;
    v_old_transition TEXT :=
        $old$OR (OLD.status = 'IN_PROGRESS' AND NEW.status = 'COMPLETED')$old$;
    v_new_transition TEXT :=
        $new$OR (OLD.status = 'IN_PROGRESS' AND NEW.status = 'COMPLETED')
            OR (
                OLD.status = 'COMPLETED'
                AND NEW.status = 'IN_PROGRESS'
                AND NEW.completion_reopened = TRUE
                AND fn_is_completion_reopen_authorized(
                    OLD.id, OLD.lock_version)
            )$new$;
BEGIN
    SELECT pg_get_functiondef(
        'fn_validate_production_execution_segment()'::regprocedure)
    INTO v_definition;

    v_updated := replace(v_definition, v_old_terminal, v_new_terminal);
    IF v_updated = v_definition THEN
        RAISE EXCEPTION
            'V159 could not extend execution segment terminal guard';
    END IF;
    v_definition := v_updated;

    v_updated := replace(
        v_definition, v_old_transition, v_new_transition);
    IF v_updated = v_definition THEN
        RAISE EXCEPTION
            'V159 could not extend execution segment transition guard';
    END IF;
    EXECUTE v_updated;
END;
$migration$;

/*
 * A completed segment may have released material that was never issued.
 * Reopening is a correction lane, not a new material allocation: do not
 * recreate those reservations. The ordinary READY/DISPATCHED/IN_PROGRESS
 * complete-kit invariant stays unchanged for every segment that has not gone
 * through the explicit completion-reopen event.
 */
DO $migration$
DECLARE
    v_definition TEXT;
    v_updated TEXT;
    v_overdraw_pattern TEXT :=
        $pattern$v_segment\.status <> 'COMPLETED'[[:space:]]+AND draw_backed > stock_backed$pattern$;
    v_new_overdraw TEXT := $new$v_segment.status <> 'COMPLETED'
                      AND NOT (
                          v_segment.status = 'IN_PROGRESS'
                          AND v_segment.completion_reopened
                      )
                      AND draw_backed > stock_backed$new$;
    v_readiness_pattern TEXT :=
        $pattern$IF v_segment\.status IN \('READY', 'DISPATCHED', 'IN_PROGRESS'\)[[:space:]]+AND v_ready_count <> v_demand_count THEN$pattern$;
    v_new_readiness TEXT := $new$IF v_segment.status IN ('READY', 'DISPATCHED', 'IN_PROGRESS')
       AND NOT (
           v_segment.status = 'IN_PROGRESS'
           AND v_segment.completion_reopened
       )
       AND v_ready_count <> v_demand_count THEN$new$;
BEGIN
    SELECT pg_get_functiondef(
        'fn_assert_execution_segment_integrity(uuid)'::regprocedure)
    INTO v_definition;

    v_updated := regexp_replace(
        v_definition, v_overdraw_pattern, v_new_overdraw);
    IF v_updated = v_definition THEN
        RAISE EXCEPTION
            'V159 could not preserve completion correction material history';
    END IF;
    v_definition := v_updated;

    v_updated := regexp_replace(
        v_definition, v_readiness_pattern, v_new_readiness);
    IF v_updated = v_definition THEN
        RAISE EXCEPTION
            'V159 could not extend execution segment readiness guard';
    END IF;
    EXECUTE v_updated;
END;
$migration$;

/*
 * Re-completion is still derived from approved inbound and material clearance.
 * Clear the correction marker only when that authoritative predicate is true.
 */
DO $migration$
DECLARE
    v_definition TEXT;
    v_updated TEXT;
    v_old_update TEXT :=
        $old$SET status = 'COMPLETED', updated_at = now()$old$;
    v_new_update TEXT :=
        $new$SET status = 'COMPLETED',
            completion_reopened = FALSE,
            updated_at = now()$new$;
BEGIN
    SELECT pg_get_functiondef(
        'fn_reconcile_execution_segment_completion(uuid)'::regprocedure)
    INTO v_definition;
    v_updated := replace(v_definition, v_old_update, v_new_update);
    IF v_updated = v_definition THEN
        RAISE EXCEPTION
            'V159 could not extend execution segment reconciliation';
    END IF;
    EXECUTE v_updated;
END;
$migration$;
