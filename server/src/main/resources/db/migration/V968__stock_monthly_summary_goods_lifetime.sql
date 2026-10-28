-- V949 introduced a rebuildable stock_movements projection after V911 installed
-- lifetime triggers. Its goods identity is now discovered dynamically, so the
-- same reviewed lifetime recorder must follow future projection writes too.
-- Historical rows remain backed by the already tracked authoritative ledger;
-- this upgrade does not rewrite projection rows or invent retrospective uses.
DO $monthly_stock_lifetime$
DECLARE existing pg_trigger%ROWTYPE;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.fn_goods_code_usage_columns()
        WHERE table_name='stock_monthly_summaries' AND column_name='goods_id' AND kind='U'
    ) THEN
        RAISE EXCEPTION 'Unreviewed monthly stock goods identity; lifetime upgrade refused'
            USING ERRCODE='23514';
    END IF;
    SELECT * INTO existing FROM pg_trigger
        WHERE tgrelid='public.stock_monthly_summaries'::regclass
          AND tgname='trg_track_goods_code_usage' AND NOT tgisinternal;
    IF FOUND THEN
        IF existing.tgfoid<>'public.fn_capture_goods_code_use()'::regprocedure
            OR existing.tgtype<>29 OR existing.tgenabled<>'O' OR existing.tgnargs<>1
            OR existing.tgqual IS NOT NULL OR existing.tgattr<>''::int2vector
            OR existing.tgconstraint<>0 OR existing.tgdeferrable OR existing.tginitdeferred
            OR existing.tgoldtable IS NOT NULL OR existing.tgnewtable IS NOT NULL
            OR existing.tgargs<>(convert_to('U:goods_id','UTF8')||decode('00','hex')) THEN
            RAISE EXCEPTION 'Unreviewed monthly stock lifetime trigger; upgrade refused'
                USING ERRCODE='23514';
        END IF;
    ELSE
        CREATE TRIGGER trg_track_goods_code_usage
            AFTER INSERT OR UPDATE OR DELETE ON public.stock_monthly_summaries
            FOR EACH ROW EXECUTE FUNCTION public.fn_capture_goods_code_use('U:goods_id');
    END IF;
END $monthly_stock_lifetime$;
