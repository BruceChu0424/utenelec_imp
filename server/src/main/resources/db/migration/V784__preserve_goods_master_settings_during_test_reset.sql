-- Explicit test reset clears stock openings, never editable goods master settings.
-- NULL, zero and nonzero safety-stock/cost values keep their exact meanings.
-- Repair only the installed function; applied migrations and existing data are unchanged.
DO $preserve_goods_master_settings$
DECLARE
    definition text;
    old_update constant text := $old_update$    UPDATE goods
    SET init_stock = 0,
        init_count = 0,
        init_weight = 0,
        min_qty = 0,
        source_e = 0,
        work_e = 0,
        lacquer_e = 0,
        incidental_e = 0,
        plating_e = 0,
        casing_e = 0,
        manage_e = 0,
        polish_e = 0,
        electric_e = 0,
        machining_e = 0,
        lost_e = 0,
        rent_e = 0,
        make_e = 0,
        work_rate = 0,
        lost_rate = 0,
        make_rate = 0,
        rent_rate = 0,
        total = 0,
        c_total = 0,
        g_total = 0,
        version = version + 1,
        updated_at = CURRENT_TIMESTAMP
    WHERE COALESCE(init_stock, 0) <> 0
       OR COALESCE(init_count, 0) <> 0
       OR COALESCE(init_weight, 0) <> 0
       OR min_qty IS DISTINCT FROM 0
       OR source_e IS DISTINCT FROM 0
       OR work_e IS DISTINCT FROM 0
       OR lacquer_e IS DISTINCT FROM 0
       OR incidental_e IS DISTINCT FROM 0
       OR plating_e IS DISTINCT FROM 0
       OR casing_e IS DISTINCT FROM 0
       OR manage_e IS DISTINCT FROM 0
       OR polish_e IS DISTINCT FROM 0
       OR electric_e IS DISTINCT FROM 0
       OR machining_e IS DISTINCT FROM 0
       OR lost_e IS DISTINCT FROM 0
       OR rent_e IS DISTINCT FROM 0
       OR make_e IS DISTINCT FROM 0
       OR work_rate IS DISTINCT FROM 0
       OR lost_rate IS DISTINCT FROM 0
       OR make_rate IS DISTINCT FROM 0
       OR rent_rate IS DISTINCT FROM 0
       OR total IS DISTINCT FROM 0
       OR c_total IS DISTINCT FROM 0
       OR g_total IS DISTINCT FROM 0;

$old_update$;
    old_cost_check constant text := $old_cost_check$    SELECT count(*)
    INTO n
    FROM goods
    WHERE min_qty IS DISTINCT FROM 0
       OR source_e IS DISTINCT FROM 0
       OR work_e IS DISTINCT FROM 0
       OR lacquer_e IS DISTINCT FROM 0
       OR incidental_e IS DISTINCT FROM 0
       OR plating_e IS DISTINCT FROM 0
       OR casing_e IS DISTINCT FROM 0
       OR manage_e IS DISTINCT FROM 0
       OR polish_e IS DISTINCT FROM 0
       OR electric_e IS DISTINCT FROM 0
       OR machining_e IS DISTINCT FROM 0
       OR lost_e IS DISTINCT FROM 0
       OR rent_e IS DISTINCT FROM 0
       OR make_e IS DISTINCT FROM 0
       OR work_rate IS DISTINCT FROM 0
       OR lost_rate IS DISTINCT FROM 0
       OR make_rate IS DISTINCT FROM 0
       OR rent_rate IS DISTINCT FROM 0
       OR total IS DISTINCT FROM 0
       OR c_total IS DISTINCT FROM 0
       OR g_total IS DISTINCT FROM 0;
    IF n <> 0 THEN
        RAISE EXCEPTION
            '货品安全库存/成本预算归零校验失败：仍有 % 个货品存在非零安全库存或成本金额/费率，整体回滚',
            n;
    END IF;

$old_cost_check$;
    opening_update constant text := $opening_update$    UPDATE goods
    SET init_stock = 0,
        init_count = 0,
        init_weight = 0,
        version = version + 1,
        updated_at = CURRENT_TIMESTAMP
    WHERE COALESCE(init_stock, 0) <> 0
       OR COALESCE(init_count, 0) <> 0
       OR COALESCE(init_weight, 0) <> 0;

$opening_update$;
BEGIN
    SELECT replace(pg_get_functiondef('public.business_data_reset()'::regprocedure), E'\r\n', E'\n')
      INTO definition;
    IF (length(definition)-length(replace(definition,old_update,'')))/length(old_update)<>1
       OR (length(definition)-length(replace(definition,old_cost_check,'')))/length(old_cost_check)<>1
       OR strpos(definition,'PERFORM public.fn_require_runtime_maintenance(true);')=0
       OR strpos(definition,'PERFORM public.fn_clear_business_test_object_metadata();')=0 THEN
        RAISE EXCEPTION 'V784 cannot preserve the authenticated, physically verified test-reset implementation';
    END IF;
    -- CREATE OR REPLACE preserves the installed function owner and execute ACL.
    -- Every policy, account/party opening reset, control receipt and generation check stays intact.
    definition:=replace(definition,old_update,opening_update);
    definition:=replace(definition,old_cost_check,E'    -- Goods safety stock and cost settings remain master configuration.\n\n');
    EXECUTE definition;
END $preserve_goods_master_settings$;
