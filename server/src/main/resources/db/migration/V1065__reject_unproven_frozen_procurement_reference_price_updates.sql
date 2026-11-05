-- Frozen original operands require their real source-revision authority before
-- reference-price arithmetic can request another precision choice.
DO $frozen_reference_authority$
DECLARE definition text; anchor text; replacement text;
BEGIN
 definition:=pg_get_functiondef('fn_guard_procurement_reference_price_policy()'::regprocedure);
 anchor:='IF TG_OP=''UPDATE'' AND parent_status<>0 AND NOT original_changed THEN
  RAISE EXCEPTION ''saved reference price proof cannot be independently replaced'' USING ERRCODE=''55000''; END IF;';
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'V1065 frozen reference-price authority anchor differs'; END IF;
 replacement:='IF TG_OP=''UPDATE'' AND parent_status<>0 THEN
  IF NOT original_changed OR NOT EXISTS(SELECT 1 FROM procurement_order_source_revisions r
    WHERE r.created_txid=txid_current() AND r.order_type=order_kind
      AND r.order_id=NEW.order_id AND r.order_item_id=NEW.id
      AND r.old_qty=OLD.qty AND r.new_qty=NEW.qty AND r.before_item=to_jsonb(OLD)) THEN
   RAISE EXCEPTION ''frozen reference price operands are immutable without their actual source revision'' USING ERRCODE=''55000'';
  END IF;
 END IF;';
 EXECUTE replace(definition,anchor,replacement);
END $frozen_reference_authority$;
