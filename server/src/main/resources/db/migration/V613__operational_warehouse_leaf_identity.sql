-- V613：技术线边子位不改变正常仓库的实际收发身份；不搬库存、不创建虚构普通仓。
CREATE OR REPLACE FUNCTION fn_warehouse_is_operational_leaf(p_warehouse UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM warehouses warehouse
        WHERE warehouse.id = p_warehouse AND NOT warehouse.is_deleted
          AND NOT EXISTS (
              SELECT 1 FROM warehouses child
              WHERE child.parent_id = warehouse.id AND NOT child.is_deleted
                AND (warehouse.is_line_side OR NOT child.is_line_side)));
$$;

-- 普通单据选仓：启用、记账、运营叶仓、完整启用祖先链，并明确排除技术流转位置。
CREATE OR REPLACE FUNCTION fn_warehouse_is_active_accounting_leaf(p_warehouse UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    WITH RECURSIVE ancestry AS (
        SELECT id, parent_id, status, is_deleted, ARRAY[id] AS path
        FROM warehouses WHERE id = p_warehouse
        UNION ALL
        SELECT parent.id, parent.parent_id, parent.status, parent.is_deleted, child.path || parent.id
        FROM ancestry child JOIN warehouses parent ON parent.id = child.parent_id
        WHERE NOT parent.id = ANY(child.path)
    )
    SELECT EXISTS (
        SELECT 1 FROM warehouses leaf
        WHERE leaf.id = p_warehouse AND leaf.is_accountable AND NOT leaf.is_deleted
          AND NOT leaf.is_line_side AND leaf.status = '使用'
          AND fn_warehouse_is_operational_leaf(leaf.id)
          AND EXISTS (SELECT 1 FROM ancestry WHERE parent_id IS NULL)
          AND NOT EXISTS (SELECT 1 FROM ancestry WHERE is_deleted OR status IS DISTINCT FROM '使用'));
$$;

DO $migration$
DECLARE
    definition TEXT;
    needle TEXT;
    replacement TEXT;
BEGIN
    SELECT replace(pg_get_functiondef('fn_check_main_warehouse_public_stock_budget()'::regprocedure),
                   E'\r\n', E'\n') INTO definition;
    needle := 'NOT EXISTS(SELECT 1 FROM warehouses child WHERE child.parent_id=warehouse.id AND NOT child.is_deleted)';
    IF (length(definition) - length(replace(definition, needle, ''))) / length(needle) <> 2 THEN
        RAISE EXCEPTION 'V613 public stock budget no longer matches the two V540 leaf anchors';
    END IF;
    definition := replace(definition, needle,
        '(NOT warehouse.is_line_side AND fn_warehouse_is_operational_leaf(warehouse.id))');
    needle := '    qualified:=fn_production_qualified_formal_qty(target.id);';
    replacement := $branch$
    IF EXISTS (SELECT 1 FROM warehouses WHERE id=target.warehouse_id AND is_line_side) THEN
        IF NOT fn_line_side_stock_targets_demand(target.warehouse_id,target.demand_id) THEN
            RAISE EXCEPTION 'workshop transfer stock is dedicated to its receiving demand'
                USING ERRCODE='23514',CONSTRAINT='production_line_side_demand_scope_guard';
        END IF;
        RETURN NULL;
    END IF;
    qualified:=fn_production_qualified_formal_qty(target.id);$branch$;
    IF position(needle IN definition) = 0 THEN
        RAISE EXCEPTION 'V613 public stock budget qualified-supply anchor missing';
    END IF;
    EXECUTE replace(definition, needle, replacement);

    SELECT replace(pg_get_functiondef('fn_guard_sales_shipment_picking_warehouse()'::regprocedure),
                   E'\r\n', E'\n') INTO definition;
    needle := $old$AND warehouse.status='使用' AND NOT EXISTS(SELECT 1 FROM warehouses child
                WHERE child.parent_id=warehouse.id AND NOT child.is_deleted)$old$;
    IF position(needle IN definition) = 0 THEN
        RAISE EXCEPTION 'V613 sales outbound no longer matches the V582 physical warehouse anchor';
    END IF;
    EXECUTE replace(definition, needle, 'AND fn_warehouse_is_active_accounting_leaf(warehouse.id)');

    SELECT pg_get_functiondef('fn_guard_iqc_actual_warehouse_selection()'::regprocedure) INTO definition;
    IF position('iqc_stock_in_actual_warehouse_selection_guard' IN definition) = 0
       OR position('WITH RECURSIVE ancestry' IN definition) = 0 THEN
        RAISE EXCEPTION 'V613 IQC actual warehouse guard no longer matches the V563 shape';
    END IF;
END;
$migration$;

CREATE OR REPLACE FUNCTION fn_guard_iqc_actual_warehouse_selection()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NOT fn_warehouse_is_active_accounting_leaf(NEW.warehouse_id) THEN
        RAISE EXCEPTION 'IQC stock-in requires an explicitly selected active accounting leaf warehouse'
            USING ERRCODE='23514',CONSTRAINT='iqc_stock_in_actual_warehouse_selection_guard';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fn_warehouse_is_operational_leaf(UUID) IS
    'V613 运营叶仓：普通仓不因技术线边子位失去原收发身份；线边位置本身仍不得有任何有效子节点';
COMMENT ON FUNCTION fn_warehouse_is_active_accounting_leaf(UUID) IS
    'V613 普通选仓：启用记账运营叶仓、完整启用祖先链、非线边位置；库存身份和历史流水不改变';
