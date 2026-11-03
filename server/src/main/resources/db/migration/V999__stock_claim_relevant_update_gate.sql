-- Keep V993's previously committed source bytes intact. This guard validates location
-- quantities and provenance; unrelated metadata updates must not enqueue its
-- deferred whole-reservation scan. Preserve the installed trigger mode.
DO $migration$
DECLARE previous_mode "char";
BEGIN
    SELECT tgenabled INTO previous_mode
    FROM pg_trigger
    WHERE tgrelid = 'public.stock_reservations'::regclass
      AND tgname = 'trg_check_stock_claim_storage_reservation'
      AND NOT tgisinternal;
    IF previous_mode IS NULL THEN
        RAISE EXCEPTION 'Stock claim storage reservation guard is missing';
    END IF;

    DROP TRIGGER trg_check_stock_claim_storage_reservation ON public.stock_reservations;
    EXECUTE $trigger$
        CREATE CONSTRAINT TRIGGER trg_check_stock_claim_storage_reservation
        AFTER UPDATE ON public.stock_reservations
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
        WHEN (
            OLD.id IS DISTINCT FROM NEW.id
            OR OLD.warehouse_id IS DISTINCT FROM NEW.warehouse_id
            OR OLD.goods_id IS DISTINCT FROM NEW.goods_id
            OR OLD.color_id IS DISTINCT FROM NEW.color_id
            OR OLD.qty IS DISTINCT FROM NEW.qty
            OR OLD.consumed_qty IS DISTINCT FROM NEW.consumed_qty
            OR OLD.released_qty IS DISTINCT FROM NEW.released_qty
            OR OLD.status IS DISTINCT FROM NEW.status
            OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted
        )
        EXECUTE FUNCTION public.fn_check_stock_claim_storage_total()
    $trigger$;

    CASE previous_mode
        WHEN 'A' THEN
            ALTER TABLE public.stock_reservations ENABLE ALWAYS TRIGGER trg_check_stock_claim_storage_reservation;
        WHEN 'R' THEN
            ALTER TABLE public.stock_reservations ENABLE REPLICA TRIGGER trg_check_stock_claim_storage_reservation;
        WHEN 'D' THEN
            ALTER TABLE public.stock_reservations DISABLE TRIGGER trg_check_stock_claim_storage_reservation;
        ELSE
            ALTER TABLE public.stock_reservations ENABLE TRIGGER trg_check_stock_claim_storage_reservation;
    END CASE;
END
$migration$;
