-- A material-loss budget never lowers the finished-product delivery target.
-- Closed historical cases keep their original threshold and authorized decision.
ALTER TABLE subcontract_short_delivery_cases
    ADD COLUMN delivery_policy_version SMALLINT NOT NULL DEFAULT 1
        CHECK(delivery_policy_version IN(1,2));
ALTER TABLE subcontract_short_delivery_cases ALTER COLUMN delivery_policy_version SET DEFAULT 2;
COMMENT ON COLUMN subcontract_short_delivery_cases.delivery_policy_version IS
    '1 keeps closed historical tolerance snapshots; 2 requires the full finished target and never automatically accepts a material-budget percentage as delivered products.';

CREATE FUNCTION fn_subcontract_finished_delivery_floor(p_ordered NUMERIC)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$ SELECT p_ordered $$;

DO $finished_target_policy$
DECLARE definition TEXT;anchor TEXT;
BEGIN
    definition:=pg_get_functiondef('fn_guard_short_delivery_exact_figures()'::regprocedure);
    anchor:='floor_changed:=ratio_changed OR NEW.allowed_loss_pct IS DISTINCT FROM OLD.allowed_loss_pct;';
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'Review changed short-delivery threshold input guard';
    END IF;
    definition:=replace(definition,anchor,
        'floor_changed:=ratio_changed OR NEW.allowed_loss_pct IS DISTINCT FROM OLD.allowed_loss_pct'
        ||' OR NEW.delivery_policy_version IS DISTINCT FROM OLD.delivery_policy_version;'
        ||E'\n  IF NEW.delivery_policy_version IS DISTINCT FROM OLD.delivery_policy_version'
        ||E'\n     AND NOT(OLD.delivery_policy_version=1 AND NEW.delivery_policy_version=2'
        ||E'\n       AND OLD.status IN(''PENDING_OWNER'',''WAITING_MORE'')) THEN'
        ||E'\n   RAISE EXCEPTION ''closed short-delivery policy snapshots are immutable'' USING ERRCODE=''55000'';END IF;');
    anchor:='IF TG_OP=''INSERT'' THEN';
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'Review changed short-delivery insertion guard';
    END IF;
    definition:=replace(definition,anchor,anchor
        ||E'\n  IF NEW.delivery_policy_version<>2 THEN RAISE EXCEPTION ''new short-delivery cases require the finished target policy'' USING ERRCODE=''23514'';END IF;');
    anchor:='NEW.floor_qty:=CASE WHEN NEW.allowed_loss_pct IS NULL THEN NULL ELSE NEW.ordered_qty*greatest(100-NEW.allowed_loss_pct,0)*0.01 END;';
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'Review changed short-delivery threshold arithmetic';
    END IF;
    definition:=replace(definition,anchor,
        'NEW.floor_qty:=CASE WHEN NEW.delivery_policy_version=1 THEN '
        ||'CASE WHEN NEW.allowed_loss_pct IS NULL THEN NULL ELSE NEW.ordered_qty*greatest(100-NEW.allowed_loss_pct,0)*0.01 END'
        ||' ELSE fn_subcontract_finished_delivery_floor(NEW.ordered_qty) END;');
    EXECUTE definition;
END $finished_target_policy$;

-- Only live decisions adopt the new policy. Do not rewrite closed cases, events,
-- accepted-loss quantities, material consumption, source money or responsibility.
UPDATE subcontract_short_delivery_cases
SET delivery_policy_version=2,
    severity=CASE WHEN GREATEST(ordered_qty-delivered_qty,0)*100>=ordered_qty*20
                  THEN 'SEVERE' ELSE 'BELOW_FLOOR' END,
    version=version+1,updated_at=now()
WHERE status IN('PENDING_OWNER','WAITING_MORE');
