-- Only the request item owns this persistent CAS counter. Occupancy writers
-- retain their existing canonical source locks and do not receive new triggers.
ALTER TABLE public.purchase_request_items
    ADD COLUMN row_version BIGINT NOT NULL DEFAULT 0,
    ADD CONSTRAINT purchase_request_item_row_version_chk CHECK (row_version >= 0);

CREATE FUNCTION public.fn_purchase_request_item_row_version() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE previous_version BIGINT;
BEGIN
    IF TG_OP='INSERT' THEN
        -- BEFORE INSERT runs before the unique-index wait. Serialize with a
        -- still-visible concurrent delete/update before reading its retained
        -- epoch; RC then observes the committed before-image, while RR fails
        -- closed with 40001 if its snapshot cannot lock the changed row.
        PERFORM 1 FROM public.purchase_request_items WHERE id=NEW.id FOR UPDATE;
        -- Permanent before-images retain the old ID's epoch. A legitimate
        -- same-parent replacement or restore must never make an old token valid.
        SELECT MAX(CASE WHEN payload->>'row_version' ~ '^[0-9]+$'
                        THEN (payload->>'row_version')::bigint ELSE 0 END)
        INTO previous_version FROM public.business_record_history
        WHERE source_table='purchase_request_items' AND source_id=NEW.id::text;
        NEW.row_version:=GREATEST(COALESCE(NEW.row_version,0),COALESCE(previous_version+1,0));
    ELSE
        NEW.row_version:=OLD.row_version+1;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_purchase_request_item_row_version
    BEFORE INSERT OR UPDATE ON public.purchase_request_items
    FOR EACH ROW EXECUTE FUNCTION public.fn_purchase_request_item_row_version();
ALTER TABLE public.purchase_request_items
    ENABLE ALWAYS TRIGGER trg_purchase_request_item_row_version;

COMMENT ON COLUMN public.purchase_request_items.row_version IS
    'Database generated monotonic item version for quantity CAS; native/JPA updates and retained-ID reincarnation cannot reset it.';
