-- Saving a valid order also remembers its price through the established master
-- defaults writer. Keep that same price losslessly in the shared financial
-- domain; supplier/color/unit/currency/tax provenance and quantity rules stay.
DO $learned_procurement_price_domain$
DECLARE column_name text; constraint_name text; definition text; normalized text; expected text;
BEGIN
    FOREACH column_name IN ARRAY ARRAY['default_purchase_price','default_subcontract_price'] LOOP
        constraint_name:='ck_goods_'||column_name||'_precision';
        SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint
        WHERE conrelid='goods'::regclass AND conname=constraint_name AND contype='c';
        normalized:=replace(replace(replace(regexp_replace(definition,'[[:space:]()]','','g'),'::numeric',''),'::bigint',''),'''','');
        expected:='CHECK'||column_name||'ISNULLORabs'||column_name||'<100000000000000ANDscaletrim_scale'||column_name||'<=10';
        IF normalized IS DISTINCT FROM expected THEN
            RAISE EXCEPTION 'V1074 original learned price domain differs for %: %',column_name,definition;
        END IF;
        EXECUTE format('ALTER TABLE goods DROP CONSTRAINT %I',constraint_name);
        EXECUTE format('ALTER TABLE goods ADD CONSTRAINT %I CHECK(%I IS NULL OR fn_financial_amount_is_exact(%I))',
            constraint_name,column_name,column_name);
    END LOOP;
END $learned_procurement_price_domain$;
