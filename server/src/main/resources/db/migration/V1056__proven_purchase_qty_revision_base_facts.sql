-- V1033 derives charged/gift base quantities before V844's immutable-input
-- trigger runs. A sanctioned quantity revision already carries V1047's strict
-- current-transaction source-revision proof; allow only its derived base change.
-- Gift operands, semantics, units, received/returned quantities and all other
-- frozen commercial facts remain subject to the existing proof and guards.
DO $proven_purchase_base_facts$
DECLARE definition text; needle text;
BEGIN
    SELECT pg_get_functiondef('fn_guard_purchase_gift_input_facts()'::regprocedure)
        INTO definition;
    needle:='RAISE EXCEPTION ''posted charged/free input and base facts are immutable'' USING ERRCODE=''23514'';';
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V1056 purchase gift input guard anchor differs';
    END IF;
    definition:=replace(definition,needle,
        'IF TG_TABLE_NAME=''purchase_order_items''
            AND v_new->''qty'' IS DISTINCT FROM v_old->''qty''
            AND (v_new->''quantity_semantics'',v_new->''gift_qty'',v_new->''gift_replacement_intent'',v_new->''unit_id'',v_new->''unit_rate'')
                IS NOT DISTINCT FROM
                (v_old->''quantity_semantics'',v_old->''gift_qty'',v_old->''gift_replacement_intent'',v_old->''unit_id'',v_old->''unit_rate'')
            AND v_new->>''quantity_adoption_version''=''2''
            AND jsonb_typeof(v_new->''quantity_precision_policy'')=''object''
            AND fn_is_proven_procurement_qty_revision(TG_TABLE_NAME,v_old,v_new)
        THEN
            RETURN NEW;
        END IF;
        '||needle);
    EXECUTE definition;
END $proven_purchase_base_facts$;
