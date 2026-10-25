-- A newly captured hold is a real goods reference, even when its quantity is
-- zero or has no established unit. Keep the established lifetime recorder.
-- Existing goods/holds are not retrospectively assigned invented use events.
DO $hold_lifetime$
DECLARE existing pg_trigger%ROWTYPE;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.fn_goods_code_usage_columns()
        WHERE table_name='stock_measurement_holds' AND column_name='goods_id' AND kind='U'
    ) THEN
        RAISE EXCEPTION 'Unreviewed measurement hold goods identity; lifetime upgrade refused'
            USING ERRCODE='23514';
    END IF;
    SELECT * INTO existing FROM pg_trigger
        WHERE tgrelid='public.stock_measurement_holds'::regclass
          AND tgname='trg_track_goods_code_usage' AND NOT tgisinternal;
    IF FOUND THEN
        IF existing.tgfoid<>'public.fn_capture_goods_code_use()'::regprocedure
            OR existing.tgtype<>29 OR existing.tgenabled<>'O' OR existing.tgnargs<>1
            OR existing.tgqual IS NOT NULL OR existing.tgattr<>''::int2vector
            OR existing.tgconstraint<>0 OR existing.tgdeferrable OR existing.tginitdeferred
            OR existing.tgoldtable IS NOT NULL OR existing.tgnewtable IS NOT NULL
            OR existing.tgargs<>(convert_to('U:goods_id','UTF8')||decode('00','hex')) THEN
            RAISE EXCEPTION 'Unreviewed measurement hold lifetime trigger; upgrade refused'
                USING ERRCODE='23514';
        END IF;
    ELSE
        CREATE TRIGGER trg_track_goods_code_usage
            AFTER INSERT OR UPDATE OR DELETE ON public.stock_measurement_holds
            FOR EACH ROW EXECUTE FUNCTION public.fn_capture_goods_code_use('U:goods_id');
    END IF;
END $hold_lifetime$;
