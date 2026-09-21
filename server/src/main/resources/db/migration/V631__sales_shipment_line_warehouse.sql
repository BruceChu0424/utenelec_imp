-- ============ 出货明细按行记实际发出仓 (2026-09-20 用户口径) ============
-- 用户口径: 仓库确认出库时不要再选一个「实际发货仓库」——发出仓在明细表里按行选,
-- 预填建议仓(表头仓能发则表头仓, 否则首个能发出本行的仓), 一张出货单的货可以分别从
-- 几个叶仓发出, 批量发货不再因为货分在不同仓而只能拆单。
--
-- 本迁移:
--   1. sales_shipment_items.warehouse_id: 行的实际发出仓。仓库确认出库时按行落定; 已出库
--      的历史行回填为表头仓(此前整单只能从表头仓发, 事实等价)。SHIPPED 前为空=尚未确认。
--   2. sales_shipment_warehouse_events.line_warehouses: 确认出库事件按行冻结发出仓
--      (itemId -> warehouseId), 与 line_stock_places 同一条 SHIPPED 事件。
--   3. fn_guard_sales_shipment_picking_evidence 用 pg_get_functiondef 锚点补丁(V582 定义,
--      V613 未改本函数): 非 SHIPPED 事件不得带 line_warehouses; SHIPPED 事件的每个键必须是
--      本单明细 UUID, 值必须是启用的核算叶仓。
-- 表头 sales_shipments.warehouse_id 语义收窄为「默认/主发出仓」: 推迟选仓的单据在确认出库时
-- 取第一行的发出仓落表头(V582 出库事件仍按表头仓取证), 销售指定过仓的单据表头不动。
-- 扣库存、消预留、红冲回库、退货来源都按行仓走(SalesShipmentService.approveLocked /
-- applyMovement / reverse)。

ALTER TABLE sales_shipment_items
    ADD COLUMN warehouse_id UUID REFERENCES warehouses(id);
COMMENT ON COLUMN sales_shipment_items.warehouse_id IS
    '实际发出仓(V631): 仓库确认出库时按行落定, 可与表头 warehouse_id 不同; SHIPPED 前为空=尚未确认。历史已出库行回填为表头仓';

UPDATE sales_shipment_items item
SET warehouse_id = document.warehouse_id
FROM sales_shipments document
WHERE document.id = item.shipment_id
  AND item.warehouse_id IS NULL
  AND document.status = 1
  AND document.warehouse_id IS NOT NULL;

CREATE INDEX idx_sales_shipment_items_warehouse
    ON sales_shipment_items(warehouse_id)
    WHERE warehouse_id IS NOT NULL;

ALTER TABLE sales_shipment_warehouse_events
    ADD COLUMN line_warehouses JSONB NOT NULL DEFAULT '{}'::jsonb;
COMMENT ON COLUMN sales_shipment_warehouse_events.line_warehouses IS
    '确认出库时冻结的逐行实际发出仓(shipment_item_id -> warehouse_id, V631); 只挂在 SHIPPED 事件上';

DO $migration$
DECLARE
    definition TEXT;
    updated TEXT;
BEGIN
    SELECT replace(pg_get_functiondef('fn_guard_sales_shipment_picking_evidence()'::regprocedure), E'\r\n', E'\n')
    INTO definition;

    updated := replace(definition,
        $old$        IF NEW.line_stock_places<>'{}'::jsonb THEN$old$,
        $new$        IF NEW.line_stock_places<>'{}'::jsonb OR NEW.line_warehouses<>'{}'::jsonb THEN$new$);
    IF updated = definition THEN
        RAISE EXCEPTION 'V631 missing V582 outbound evidence anchor (non-shipped branch)';
    END IF;
    definition := updated;

    updated := replace(definition,
        $old$    FOR entry IN SELECT * FROM jsonb_each(NEW.line_stock_places) LOOP$old$,
        $new$    FOR entry IN SELECT * FROM jsonb_each(NEW.line_warehouses) LOOP
        IF entry.key !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
           OR jsonb_typeof(entry.value)<>'string'
           OR (entry.value#>>'{}') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
            RAISE EXCEPTION 'Outbound line warehouses require exact shipment item and warehouse UUIDs' USING ERRCODE='23514';
        END IF;
        IF NOT EXISTS(SELECT 1 FROM sales_shipment_items item WHERE item.id=entry.key::uuid
            AND item.shipment_id=document.id AND NOT item.is_deleted) THEN
            RAISE EXCEPTION 'Outbound line warehouse does not belong to this shipment' USING ERRCODE='23514';
        END IF;
        IF NOT fn_warehouse_is_active_accounting_leaf((entry.value#>>'{}')::uuid) THEN
            RAISE EXCEPTION 'Outbound line warehouse must be an active accounting leaf warehouse' USING ERRCODE='23514';
        END IF;
    END LOOP;
    FOR entry IN SELECT * FROM jsonb_each(NEW.line_stock_places) LOOP$new$);
    IF updated = definition THEN
        RAISE EXCEPTION 'V631 missing V582 outbound evidence anchor (location loop)';
    END IF;
    EXECUTE updated;
END;
$migration$;
