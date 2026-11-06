-- Template annotations classify already-settled source quantities. Match the
-- existing 40/24 HTTP/native fact contract without rounding those original facts.
-- V1011 already removed both classification typmods and installed their shared
-- exact checks. Verify and retain them; only the older KG constraint needs a
-- forward replacement. Existing facts, receipts and audit history stay intact.
DO $plastic_source_domain$
DECLARE target text; definition text; normalized text;actual_type text;guard_name text;
BEGIN
    IF to_regprocedure('fn_financial_amount_is_exact(numeric)') IS NULL THEN
        RAISE EXCEPTION 'The shared exact financial input authority is required';
    END IF;
    FOREACH target IN ARRAY ARRAY['reject_return_qty','reject_issue_qty'] LOOP
        SELECT format_type(atttypid,atttypmod) INTO actual_type FROM pg_attribute
        WHERE attrelid='finance_plastic_template_inputs'::regclass AND attname=target AND NOT attisdropped AND attnotnull;
        IF actual_type IS DISTINCT FROM 'numeric' THEN
            RAISE EXCEPTION 'Review the V1011 plastic source classification storage for %: %',target,actual_type;
        END IF;
        guard_name:='ck_financial_exact_'||substr(md5('public.finance_plastic_template_inputs.'||target),1,24);
        SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint
        WHERE conrelid='finance_plastic_template_inputs'::regclass AND conname=guard_name AND contype='c';
        normalized:=replace(replace(regexp_replace(definition,'[[:space:]()]','','g'),'public.',''),'::numeric','');
        IF normalized IS DISTINCT FROM 'CHECKfn_financial_amount_is_exact'||target THEN
            RAISE EXCEPTION 'Review the retained shared plastic classification guard for %: %',target,definition;
        END IF;
    END LOOP;
    SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint
    WHERE conrelid='finance_plastic_template_inputs'::regclass
      AND conname='finance_plastic_template_inputs_weight_kg_per_unit_check' AND contype='c';
    normalized:=replace(replace(regexp_replace(definition,'[[:space:]()]','','g'),'::numeric',''),'''','');
    IF normalized IS DISTINCT FROM 'CHECKweight_kg_per_unit>0ANDweight_kg_per_unit=truncweight_kg_per_unit,10ANDweight_kg_per_unit<100000000000000' THEN
        RAISE EXCEPTION 'Review the original plastic KG annotation constraint: %',definition;
    END IF;
    ALTER TABLE finance_plastic_template_inputs
        DROP CONSTRAINT finance_plastic_template_inputs_weight_kg_per_unit_check,
        ADD CONSTRAINT finance_plastic_template_inputs_weight_kg_per_unit_check
            CHECK(weight_kg_per_unit IS NULL OR (weight_kg_per_unit>0 AND fn_financial_amount_is_exact(weight_kg_per_unit)));
END $plastic_source_domain$;
