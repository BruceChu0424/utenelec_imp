package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.shipment.dto.BatchShipRequest;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.*;

/** Read physical sources under the caller's existing sales/inventory locks. */
final class SalesShipmentBatchAllocation {
    private final EntityManager em;
    SalesShipmentBatchAllocation(EntityManager em) { this.em=em; }

    Map<UUID,Map<UUID,BigDecimal>> allocate(BatchShipRequest request) {
        List<UUID> ids=request.getLines().stream().map(BatchShipRequest.Line::getOrderItemId).sorted().toList();
        List<Object[]> rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH RECURSIVE active_warehouses AS (
                    SELECT id FROM warehouses WHERE parent_id IS NULL AND NOT is_deleted AND status='使用'
                    UNION ALL
                    SELECT child.id FROM warehouses child JOIN active_warehouses parent ON parent.id=child.parent_id
                    WHERE NOT child.is_deleted AND child.status='使用'
                ), selected AS (
                    SELECT id,goods_id,color_id,COALESCE(NULLIF(unit_rate,0),1) rate
                    FROM sales_order_items WHERE id IN (:ids) AND NOT is_deleted
                ), reservations AS (
                    SELECT r.order_item_id,r.warehouse_id,r.goods_id,r.color_id,
                           SUM(GREATEST(r.qty-r.consumed_qty-r.released_qty,0)) qty
                    FROM stock_reservations r WHERE NOT r.is_deleted AND r.status=0
                      AND EXISTS(SELECT 1 FROM selected i WHERE i.goods_id=r.goods_id
                          AND i.color_id IS NOT DISTINCT FROM r.color_id)
                    GROUP BY r.order_item_id,r.warehouse_id,r.goods_id,r.color_id
                ), drafts AS (
                    SELECT item.order_item_id,shipment.warehouse_id,item.goods_id,item.color_id,
                           SUM(item.qty*COALESCE(NULLIF(item.unit_rate,0),1)) qty
                    FROM sales_shipment_items item JOIN sales_shipments shipment ON shipment.id=item.shipment_id
                    WHERE NOT item.is_deleted AND NOT shipment.is_deleted AND shipment.status=0
                      AND NOT COALESCE(shipment.rejected,FALSE) AND item.order_item_id IS NOT NULL
                      AND EXISTS(SELECT 1 FROM selected i WHERE i.goods_id=item.goods_id
                          AND i.color_id IS NOT DISTINCT FROM item.color_id)
                    GROUP BY item.order_item_id,shipment.warehouse_id,item.goods_id,item.color_id
                ), public_claims AS (
                    SELECT d.warehouse_id,d.goods_id,d.color_id,
                           SUM(GREATEST(d.qty-COALESCE(r.qty,0),0)) qty
                    FROM drafts d LEFT JOIN reservations r ON r.order_item_id=d.order_item_id
                        AND r.warehouse_id=d.warehouse_id AND r.goods_id=d.goods_id
                        AND r.color_id IS NOT DISTINCT FROM d.color_id
                    WHERE d.warehouse_id IS NOT NULL GROUP BY d.warehouse_id,d.goods_id,d.color_id
                )
                SELECT i.id,warehouse.id,i.goods_id,i.color_id,i.rate,
                       LEAST(GREATEST(COALESCE(own.qty,0)-COALESCE(draft.qty,0),0),
                           GREATEST(balance.qty-COALESCE((SELECT SUM(r.qty) FROM reservations r
                               WHERE r.warehouse_id=warehouse.id AND r.goods_id=i.goods_id
                                 AND r.color_id IS NOT DISTINCT FROM i.color_id),0)
                               +COALESCE(own.qty,0)-COALESCE(draft.qty,0)-COALESCE(claim.qty,0)
                               -GREATEST(COALESCE(CAST(goods.min_qty AS numeric),0),0),0)) exact_qty,
                       GREATEST(balance.qty-COALESCE((SELECT SUM(r.qty) FROM reservations r
                           WHERE r.warehouse_id=warehouse.id AND r.goods_id=i.goods_id
                             AND r.color_id IS NOT DISTINCT FROM i.color_id),0)
                           -COALESCE(claim.qty,0)-GREATEST(COALESCE(CAST(goods.min_qty AS numeric),0),0),0) public_qty,
                       GREATEST(LEAST(COALESCE(global.qty,0),
                           GREATEST(COALESCE((SELECT SUM(GREATEST(stock.qty-GREATEST(COALESCE(CAST(goods.min_qty AS numeric),0),0),0))
                               FROM stock_balances stock JOIN warehouses leaf ON leaf.id=stock.warehouse_id
                               JOIN active_warehouses valid ON valid.id=leaf.id
                               WHERE stock.goods_id=i.goods_id AND stock.color_id IS NOT DISTINCT FROM i.color_id
                                 AND leaf.is_accountable AND NOT leaf.is_defective AND NOT leaf.is_line_side
                                 AND fn_warehouse_is_operational_leaf(leaf.id)),0)
                               -COALESCE((SELECT SUM(r.qty) FROM reservations r WHERE r.goods_id=i.goods_id
                                   AND r.color_id IS NOT DISTINCT FROM i.color_id
                                   AND (r.order_item_id IS DISTINCT FROM i.id OR r.warehouse_id IS NOT NULL)),0),0))
                           -COALESCE((SELECT SUM(GREATEST(d.qty-COALESCE(r.qty,0),0))
                           FROM drafts d LEFT JOIN reservations r ON r.order_item_id=d.order_item_id
                             AND r.warehouse_id=d.warehouse_id AND r.goods_id=d.goods_id
                             AND r.color_id IS NOT DISTINCT FROM d.color_id
                           WHERE d.order_item_id=i.id),0),0) global_qty
                FROM selected i JOIN stock_balances balance ON balance.goods_id=i.goods_id
                    AND balance.color_id IS NOT DISTINCT FROM i.color_id AND balance.qty>0
                JOIN goods ON goods.id=i.goods_id
                JOIN active_warehouses active ON active.id=balance.warehouse_id
                JOIN warehouses warehouse ON warehouse.id=balance.warehouse_id
                    AND NOT warehouse.is_deleted AND warehouse.status='使用'
                    AND warehouse.is_accountable AND NOT warehouse.is_defective AND NOT warehouse.is_line_side
                    AND fn_warehouse_is_operational_leaf(warehouse.id)
                LEFT JOIN reservations own ON own.order_item_id=i.id AND own.warehouse_id=warehouse.id
                    AND own.goods_id=i.goods_id AND own.color_id IS NOT DISTINCT FROM i.color_id
                LEFT JOIN reservations global ON global.order_item_id=i.id AND global.warehouse_id IS NULL
                    AND global.goods_id=i.goods_id AND global.color_id IS NOT DISTINCT FROM i.color_id
                LEFT JOIN drafts draft ON draft.order_item_id=i.id AND draft.warehouse_id=warehouse.id
                    AND draft.goods_id=i.goods_id AND draft.color_id IS NOT DISTINCT FROM i.color_id
                LEFT JOIN public_claims claim ON claim.warehouse_id=warehouse.id AND claim.goods_id=i.goods_id
                    AND claim.color_id IS NOT DISTINCT FROM i.color_id
                ORDER BY i.id,warehouse.id
                """).setParameter("ids",ids));
        Map<UUID,List<Source>> sources=new HashMap<>();
        Map<String,BigDecimal> publicRemaining=new HashMap<>();
        for(Object[] row:rows) {
            Source source=new Source((UUID)row[1],row[2]+"|"+row[3]+"|"+row[1],bd(row[4]),bd(row[5]),bd(row[6]),bd(row[7]));
            sources.computeIfAbsent((UUID)row[0],unused->new ArrayList<>()).add(source);
            publicRemaining.putIfAbsent(source.pool(),source.publicQty());
        }
        Map<UUID,Map<UUID,BigDecimal>> result=new LinkedHashMap<>();
        for(BatchShipRequest.Line line:request.getLines().stream().sorted(Comparator.comparing(BatchShipRequest.Line::getOrderItemId)).toList()) {
            Map<UUID,BigDecimal> allocated=new LinkedHashMap<>();
            BigDecimal left=line.getQty();
            if(left==null || left.signum()<=0) throw new ApiException(ErrorCode.VALIDATION_FAILED,"本次出货数量必须大于0");
            List<Source> itemSources=sources.getOrDefault(line.getOrderItemId(),List.of()).stream()
                    .filter(source->request.getWarehouseId()==null || request.getWarehouseId().equals(source.warehouse())).toList();
            for(Source source:itemSources) {
                BigDecimal take=left.min(source.exactQty().divide(source.rate(),4,RoundingMode.DOWN));
                if(take.signum()>0) { allocated.merge(source.warehouse(),take,BigDecimal::add); left=left.subtract(take); }
            }
            BigDecimal global=itemSources.stream().map(Source::globalQty).max(BigDecimal::compareTo).orElse(BigDecimal.ZERO);
            for(Source source:itemSources) {
                BigDecimal base=left.multiply(source.rate()).min(global).min(publicRemaining.getOrDefault(source.pool(),BigDecimal.ZERO));
                BigDecimal take=base.divide(source.rate(),4,RoundingMode.DOWN);
                if(take.signum()>0) {
                    allocated.merge(source.warehouse(),take,BigDecimal::add);left=left.subtract(take);
                    BigDecimal used=take.multiply(source.rate());global=global.subtract(used);
                    publicRemaining.compute(source.pool(),(key,value)->value.subtract(used));
                }
            }
            if(left.signum()>0) throw new ApiException(ErrorCode.CONFLICT,"订单行当前实仓可发数量不足，已扣其他预留及待出货占用；请刷新本批可发量后重试");
            result.put(line.getOrderItemId(),allocated);
        }
        return result;
    }
    private static BigDecimal bd(Object value) { return value==null?BigDecimal.ZERO:(BigDecimal)value; }
    private record Source(UUID warehouse,String pool,BigDecimal rate,BigDecimal exactQty,BigDecimal publicQty,BigDecimal globalQty) {}
}
