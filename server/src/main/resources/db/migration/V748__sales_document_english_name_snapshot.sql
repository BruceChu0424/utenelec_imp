-- New commercial documents retain the English label shown during authoring.
-- Do not backfill approved history from today's mutable goods master.
ALTER TABLE sales_quote_items ADD COLUMN goods_name_en_snapshot varchar(255);
ALTER TABLE sales_order_items ADD COLUMN goods_name_en_snapshot varchar(255);

CREATE FUNCTION fn_guard_sales_english_name_snapshot()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE parent_status smallint; parent_id uuid;
BEGIN
    IF NEW.goods_name_en_snapshot IS NOT DISTINCT FROM OLD.goods_name_en_snapshot THEN RETURN NEW; END IF;
    parent_id := (to_jsonb(NEW)->>TG_ARGV[1])::uuid;
    EXECUTE format('SELECT status FROM %I WHERE id=$1 FOR SHARE', TG_ARGV[0])
        INTO parent_status USING parent_id;
    IF parent_status IS NULL OR parent_status <> 0 THEN
        RAISE EXCEPTION 'Confirmed sales English-name snapshots are immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END
$function$;

CREATE TRIGGER trg_sales_quote_english_name_snapshot
BEFORE UPDATE OF goods_name_en_snapshot ON sales_quote_items FOR EACH ROW
WHEN (OLD.goods_name_en_snapshot IS DISTINCT FROM NEW.goods_name_en_snapshot)
EXECUTE FUNCTION fn_guard_sales_english_name_snapshot('sales_quotes', 'quote_id');
CREATE TRIGGER trg_sales_order_english_name_snapshot
BEFORE UPDATE OF goods_name_en_snapshot ON sales_order_items FOR EACH ROW
WHEN (OLD.goods_name_en_snapshot IS DISTINCT FROM NEW.goods_name_en_snapshot)
EXECUTE FUNCTION fn_guard_sales_english_name_snapshot('sales_orders', 'order_id');
