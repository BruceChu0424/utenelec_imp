-- Procurement headers remain status=0 while a finance case is PENDING.
-- Freeze the full extension snapshot during that interval, including TEXT and
-- zero-value terms that do not change the existing amount-column trigger gates.
CREATE OR REPLACE FUNCTION fn_guard_business_column_snapshot()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    parent_table text;
    parent_id uuid;
    parent_status smallint;
    commercial_locked boolean := false;
BEGIN
    IF NEW.extra_columns IS NOT DISTINCT FROM OLD.extra_columns THEN RETURN NEW; END IF;
    parent_table := TG_ARGV[0];
    parent_id := (to_jsonb(NEW)->>TG_ARGV[1])::uuid;
    EXECUTE format('SELECT status FROM %I WHERE id=$1 FOR SHARE', parent_table)
        INTO parent_status USING parent_id;
    IF parent_table = 'purchase_orders' THEN
        commercial_locked := procurement_order_commercial_locked('PURCHASE', parent_id);
    ELSIF parent_table = 'subcontract_orders' THEN
        commercial_locked := procurement_order_commercial_locked('SUBCONTRACT', parent_id);
    END IF;
    IF parent_status IS NULL OR parent_status <> 0 OR commercial_locked THEN
        RAISE EXCEPTION 'Submitted or confirmed business column snapshots are immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END
$function$;
