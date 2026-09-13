-- Let plans using a main warehouse reallocate original stock held in its real
-- leaf warehouses. The header is a scope; each immutable event retains its
-- original physical reservation and warehouse. No history or balance rewrite.
DO $$
DECLARE
    definition TEXT;
    patched TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_validate_preplan_material_reallocation_endpoints()'::regprocedure)
      INTO definition;
    patched := replace(definition,
        'source_analysis.warehouse_id <> reallocation.warehouse_id',
        'NOT fn_warehouse_same_main(source_analysis.warehouse_id, reallocation.warehouse_id)');
    IF patched = definition THEN
        RAISE EXCEPTION 'V565 source endpoint warehouse guard anchor missing';
    END IF;
    definition := patched;
    patched := replace(definition,
        'target_analysis.warehouse_id <> reallocation.warehouse_id',
        'NOT fn_warehouse_same_main(target_analysis.warehouse_id, reallocation.warehouse_id)');
    IF patched = definition THEN
        RAISE EXCEPTION 'V565 target endpoint warehouse guard anchor missing';
    END IF;
    EXECUTE patched;

    SELECT pg_get_functiondef('fn_check_preplan_stock_entitlement_event()'::regprocedure)
      INTO definition;
    patched := replace(definition,
        'reallocation.warehouse_id <> reservation.warehouse_id',
        'NOT fn_warehouse_same_main(reallocation.warehouse_id, reservation.warehouse_id)');
    IF patched = definition THEN
        RAISE EXCEPTION 'V565 entitlement warehouse guard anchor missing';
    END IF;
    EXECUTE patched;
END;
$$;

COMMENT ON COLUMN preplan_material_reallocations.warehouse_id IS
    '让料的同主仓范围锚点；历史叶仓锚点保留，实物仓由各不可变权益事件关联的原 reservation 保留';
