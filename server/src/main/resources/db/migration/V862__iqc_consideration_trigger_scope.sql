-- V518's inspection bridge rechecked every historical quality/stock slice for
-- every projection or notice update. V844 quality consideration reads only the
-- inspection identity/tranche and REVERSED membership; stock consideration reads
-- only REVERSED membership. Quantity/projection guards remain separate and intact.
-- Reversal facts and changes to events/financial parts retain their own ALWAYS
-- deferred guards. No validation body, money rule or source rule is removed.
DO $inspection_consideration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid='public.procurement_inspection_items'::regclass
          AND tgname='trg_procurement_inspection_items_consideration'
          AND tgfoid='public.fn_check_procurement_consideration()'::regprocedure
          AND tgdeferrable AND tginitdeferred AND tgenabled='A'
          AND (tgtype & 16)<>0 AND tgqual IS NULL
    ) THEN
        RAISE EXCEPTION 'V862 expected the original ALWAYS deferred inspection consideration bridge';
    END IF;
END;
$inspection_consideration_guard$;

DROP TRIGGER trg_procurement_inspection_items_consideration ON public.procurement_inspection_items;

CREATE CONSTRAINT TRIGGER trg_procurement_inspection_items_consideration
AFTER INSERT OR DELETE ON public.procurement_inspection_items
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
EXECUTE FUNCTION public.fn_check_procurement_consideration();

CREATE CONSTRAINT TRIGGER trg_procurement_inspection_items_consideration_upd
AFTER UPDATE ON public.procurement_inspection_items
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
WHEN (
    (OLD.id,OLD.receipt_type,OLD.receipt_id,OLD.receipt_item_id,OLD.quantity_tranche)
      IS DISTINCT FROM
    (NEW.id,NEW.receipt_type,NEW.receipt_id,NEW.receipt_item_id,NEW.quantity_tranche)
    OR (OLD.status='REVERSED') IS DISTINCT FROM (NEW.status='REVERSED')
)
EXECUTE FUNCTION public.fn_check_procurement_consideration();

ALTER TABLE public.procurement_inspection_items
    ENABLE ALWAYS TRIGGER trg_procurement_inspection_items_consideration;
ALTER TABLE public.procurement_inspection_items
    ENABLE ALWAYS TRIGGER trg_procurement_inspection_items_consideration_upd;

COMMENT ON TRIGGER trg_procurement_inspection_items_consideration_upd ON public.procurement_inspection_items IS
    'Recheck financial quality/stock history only for its inspection identity or reversal transition; projection quantities and notification metadata have independent guards.';
