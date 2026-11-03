-- V993 correctly excludes workshop custody from public ATP, but also used
-- that public-only view for exact physical warehouse issue/allocation checks.
-- Restore the dedicated local channel without pooling it with normal storage.
-- Demand, receipt, original reservation and physical-posting guards stay intact.
CREATE OR REPLACE FUNCTION fn_stock_storage_movable(p_warehouse UUID,p_goods UUID,p_color UUID,
 p_exclude_order_items UUID[] DEFAULT NULL,p_keep_safety BOOLEAN DEFAULT TRUE)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
 SELECT CASE WHEN EXISTS(
   SELECT 1 FROM warehouses warehouse WHERE warehouse.id=p_warehouse
     AND NOT warehouse.is_deleted AND warehouse.is_accountable
     AND warehouse.is_line_side AND NOT warehouse.is_defective)
 THEN GREATEST(
   COALESCE((SELECT balance.qty FROM stock_balances balance
     WHERE balance.warehouse_id=p_warehouse AND balance.goods_id=p_goods
       AND balance.color_id IS NOT DISTINCT FROM p_color
       AND fn_stock_measurement_usable(balance.warehouse_id,balance.goods_id,balance.color_id)),0)
   -COALESCE((SELECT SUM(location.open_qty)
     FROM v_stock_reservation_storage_locations location
     WHERE location.warehouse_id=p_warehouse AND location.goods_id=p_goods
       AND location.color_id IS NOT DISTINCT FROM p_color
       AND (p_exclude_order_items IS NULL OR location.order_item_id IS NULL
         OR location.order_item_id<>ALL(p_exclude_order_items))),0),0)
 ELSE
   -- Normal storage retains V993's exact-location/main-pool budget and one
   -- public safety buffer. Workshop balances never enter v_stock_usable.
   GREATEST(LEAST(
     COALESCE((SELECT on_hand_qty FROM v_stock_usable WHERE warehouse_id=p_warehouse
       AND goods_id=p_goods AND color_id IS NOT DISTINCT FROM p_color),0)
     -COALESCE((SELECT SUM(fn_stock_claim_open_at(id,p_warehouse)) FROM stock_reservations
       WHERE NOT is_deleted AND status=0 AND goods_id=p_goods AND color_id IS NOT DISTINCT FROM p_color
         AND warehouse_id IS NOT NULL
         AND (p_exclude_order_items IS NULL OR order_item_id IS NULL OR order_item_id<>ALL(p_exclude_order_items))),0),
     COALESCE((SELECT SUM(on_hand_qty) FROM v_stock_usable WHERE goods_id=p_goods
         AND color_id IS NOT DISTINCT FROM p_color AND fn_stock_storage_same_pool(warehouse_id,p_warehouse)),0)
       -COALESCE((SELECT SUM(qty-consumed_qty-released_qty) FROM stock_reservations
         WHERE NOT is_deleted AND status=0 AND goods_id=p_goods AND color_id IS NOT DISTINCT FROM p_color
           AND (warehouse_id IS NULL OR fn_stock_storage_same_pool(warehouse_id,p_warehouse))
           AND (p_exclude_order_items IS NULL OR order_item_id IS NULL OR order_item_id<>ALL(p_exclude_order_items))),0)
       -CASE WHEN p_keep_safety THEN COALESCE((SELECT GREATEST(min_qty,0) FROM goods WHERE id=p_goods),0) ELSE 0 END),0)
 END
$$;

COMMENT ON FUNCTION fn_stock_storage_movable(UUID,UUID,UUID,UUID[],BOOLEAN) IS
 'Normal storage uses exact-location/main-pool ATP; workshop custody uses only its own measured physical quantity minus its located hard claims, outside public safety stock.';
