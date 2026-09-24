-- Historical auto-receipt registrations did not record an explicit count.
-- Preserve NULL; never backfill a claim that staff did not actually confirm.
ALTER TABLE production_finished_arrival_registration_items
    ADD COLUMN counted_qty NUMERIC(18,4),
    ADD CONSTRAINT finished_arrival_count_positive CHECK (counted_qty IS NULL OR counted_qty>0);
COMMENT ON COLUMN production_finished_arrival_registration_items.counted_qty IS
    'Explicit warehouse physical count before agreeing to automatic receipt after FQC. Historical NULL is unknown, never inferred from reported quantity.';

CREATE FUNCTION fn_guard_finished_arrival_explicit_count()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE automatic BOOLEAN; reported NUMERIC;
BEGIN
    SELECT registration.stock_in_before_inspection,(
        SELECT source.qty FROM production_daily_report_items source
        JOIN production_daily_reports report ON report.id=source.report_id
          AND report.status=1 AND NOT report.is_deleted
        WHERE source.id=NEW.source_report_item_id AND source.report_id=registration.source_report_id
          AND NOT source.is_deleted) INTO automatic,reported
    FROM production_finished_arrival_registrations registration
    WHERE registration.id=NEW.registration_id;
    IF automatic AND (NEW.counted_qty IS NULL OR reported IS NULL OR NEW.counted_qty<>reported) THEN
        RAISE EXCEPTION 'automatic finished receipt requires an explicit count equal to the exact report line; discrepancies require manual receipt'
            USING ERRCODE='23514', CONSTRAINT='finished_arrival_explicit_count_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_finished_arrival_explicit_count
    BEFORE INSERT ON production_finished_arrival_registration_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finished_arrival_explicit_count();

CREATE FUNCTION fn_finished_arrival_count_is_proven(p_item UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_finished_arrival_registration_items item
        JOIN production_daily_report_items source ON source.id=item.source_report_item_id
        WHERE item.id=p_item AND item.counted_qty>0 AND item.counted_qty=source.qty)
$$;

-- Unprocessed historical auto registrations have no recorded physical count:
-- FQC may still release them, but warehouse acceptance must now be manual.
DO $auto_confirmation$
DECLARE definition TEXT; needle TEXT := 'AND registration.stock_in_before_inspection';
BEGIN
    SELECT pg_get_functiondef('fn_guard_production_finished_in_pre_stocked_confirmation()'::regprocedure) INTO definition;
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'V697 automatic confirmation source anchor changed'; END IF;
    EXECUTE replace(definition,needle,needle||E'\n                AND fn_finished_arrival_count_is_proven(registration_item.id)');
END;
$auto_confirmation$;
