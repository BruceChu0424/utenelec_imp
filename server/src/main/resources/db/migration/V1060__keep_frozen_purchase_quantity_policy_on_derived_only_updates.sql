-- A purchase-order derived-base edit currently re-enters V1033's adoption
-- routine, which restores its values but replaces the old policy with today's
-- session policy. An unchanged original quantity is not a new adoption event.
-- Genuine operand edits and the purchase-return source-slice lifecycle retain
-- their existing calculation, source proof and transaction guards.
DO $quantity_policy_guard$
DECLARE definition text; anchor text; replacement text;
BEGIN
 SELECT pg_get_functiondef('fn_guard_document_quantity_adoption()'::regprocedure) INTO definition;
 anchor:='  changed:=to_jsonb(NEW)->''qty'' IS DISTINCT FROM to_jsonb(OLD)->''qty''';
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'V1060 quantity adoption operand anchor differs';
 END IF;
 replacement:='  IF TG_TABLE_NAME=''purchase_order_items''
    AND NEW.qty IS NOT DISTINCT FROM OLD.qty
    AND NEW.unit_id IS NOT DISTINCT FROM OLD.unit_id
    AND NEW.unit_rate IS NOT DISTINCT FROM OLD.unit_rate
    AND to_jsonb(NEW)->''quantity_semantics'' IS NOT DISTINCT FROM to_jsonb(OLD)->''quantity_semantics''
    AND to_jsonb(NEW)->''gift_qty'' IS NOT DISTINCT FROM to_jsonb(OLD)->''gift_qty''
    AND (to_jsonb(NEW)->''charged_base_qty'' IS DISTINCT FROM to_jsonb(OLD)->''charged_base_qty''
      OR to_jsonb(NEW)->''gift_base_qty'' IS DISTINCT FROM to_jsonb(OLD)->''gift_base_qty'') THEN
   RAISE EXCEPTION ''saved quantity adoption cannot be independently replaced'' USING ERRCODE=''55000'';
  END IF;
'||anchor;
 EXECUTE replace(definition,anchor,replacement);
END $quantity_policy_guard$;
