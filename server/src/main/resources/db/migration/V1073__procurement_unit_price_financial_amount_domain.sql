-- The public financial contract validates finite unit prices below 1e40 with
-- at most 24 significant fractional decimal places. V518's older 14/10 guard
-- outlived the storage widening and rejects valid explicit reference prices.
-- Reuse the one SQL actual-amount validator; no saved price or total is changed.
DO $procurement_price_domain$
DECLARE target text; definition text; normalized text;
BEGIN
    FOREACH target IN ARRAY ARRAY['purchase_order_items','subcontract_order_items',
        'purchase_receipt_items','subcontract_receipt_items'] LOOP
        SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint
        WHERE conrelid=target::regclass AND conname=target||'_price_exact_input' AND contype='c';
        normalized:=replace(replace(regexp_replace(definition,'[[:space:]()]','','g'),'::numeric',''),'''','');
        IF normalized IS DISTINCT FROM 'CHECKabsprice<100000000000000ANDscaletrim_scaleprice<=10' THEN
            RAISE EXCEPTION 'V1073 original price domain differs for %: %',target,definition;
        END IF;
        EXECUTE format('ALTER TABLE %I DROP CONSTRAINT %I',target,target||'_price_exact_input');
        EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I CHECK(price IS NULL OR fn_financial_amount_is_exact(price))',
            target,target||'_price_exact_input');
    END LOOP;
END $procurement_price_domain$;
