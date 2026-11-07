package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.util.*;

/** Same-sales-source reservations remain private; adopting them never moves or reserves stock again. */
public final class MaterialAnalysisSalesStock {
    private MaterialAnalysisSalesStock() { }

    public static String unadoptedSourceStockSql(String itemAlias) {
        return "COALESCE((SELECT SUM(GREATEST(reservation.qty-reservation.consumed_qty-reservation.released_qty-"+
                adoptedSql("reservation")+",0)) FROM stock_reservations reservation WHERE reservation.order_item_id="+itemAlias+".id"+
                " AND reservation.owner_type='SALES_ORDER_ITEM' AND reservation.owner_id="+itemAlias+".id"+
                " AND reservation.source_doc_type IN('SALES_ORDER','SALES_ORDER_CHANGE') AND reservation.status=0 AND NOT reservation.is_deleted),0)"+
                "/COALESCE("+itemAlias+".unit_rate,1)";
    }
    private static String adoptedSql(String alias) {
        return "COALESCE((SELECT SUM(adopt.qty_base) FROM preplan_sales_stock_adoptions adopt JOIN production_material_analyses active ON active.id=adopt.analysis_id"+
                " WHERE adopt.reservation_id="+alias+".id AND NOT active.is_deleted AND active.status<>'CANCELLED'),0)";
    }
    static Map<UUID,BigDecimal> availableByRoot(EntityManager em,UUID analysisId) {
        Map<UUID,BigDecimal> result=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT item.root_material_id,SUM(GREATEST(reservation.qty-reservation.consumed_qty-reservation.released_qty-
                """+adoptedSql("reservation")+"""
                ,0)) FROM production_material_analysis_items item
                JOIN stock_reservations reservation ON reservation.order_item_id=item.sales_order_item_id
                  AND reservation.owner_type='SALES_ORDER_ITEM' AND reservation.owner_id=item.sales_order_item_id
                  AND reservation.goods_id=item.goods_id AND reservation.color_id IS NOT DISTINCT FROM item.color_id
                  AND reservation.source_doc_type IN('SALES_ORDER','SALES_ORDER_CHANGE')
                  AND reservation.status=0 AND NOT reservation.is_deleted
                WHERE item.analysis_id=:id AND NOT item.is_deleted AND item.planning_quantity_mode='COVERAGE_TOTAL' AND item.root_material_id IS NOT NULL
                GROUP BY item.root_material_id
                """).setParameter("id",analysisId)))result.put((UUID)row[0],new BigDecimal(row[1].toString()));
        return Map.copyOf(result);
    }
    static Map<UUID,BigDecimal> ownedByRoot(EntityManager em,UUID analysisId,Map<UUID,BigDecimal> adopted) {
        Map<UUID,BigDecimal> result=new HashMap<>(availableByRoot(em,analysisId));
        adopted.forEach((id,qty)->result.merge(id,qty,BigDecimal::add));
        return Map.copyOf(result);
    }
    static Map<UUID,BigDecimal> adoptedByRoot(EntityManager em,UUID analysisId) {
        Map<UUID,BigDecimal> result=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT root_material_id,fn_preplan_adopted_sales_stock_base(id) FROM production_material_analysis_items
                WHERE analysis_id=:id AND NOT is_deleted AND root_material_id IS NOT NULL
                """).setParameter("id",analysisId)))result.merge((UUID)row[0],new BigDecimal(row[1].toString()),BigDecimal::add);
        return Map.copyOf(result);
    }
    static boolean adopt(EntityManager em,UUID analysisId,UUID rootId,BigDecimal maxBase,String key,UUID actor) {
        if(maxBase.signum()<=0)return false;
        @SuppressWarnings("unchecked")
        List<Object[]> rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT reservation.id,item.id,GREATEST(reservation.qty-reservation.consumed_qty-reservation.released_qty-
                """+adoptedSql("reservation")+"""
                ,0),GREATEST(item.requested_qty-item.submitted_qty-item.approved_qty-item.root_fulfilled_qty,0)*root.per_product_qty
                FROM production_material_analysis_items item
                JOIN production_material_analysis_materials root ON root.id=item.root_material_id
                JOIN stock_reservations reservation ON reservation.order_item_id=item.sales_order_item_id
                  AND reservation.owner_type='SALES_ORDER_ITEM' AND reservation.owner_id=item.sales_order_item_id
                  AND reservation.goods_id=item.goods_id AND reservation.color_id IS NOT DISTINCT FROM item.color_id
                  AND reservation.source_doc_type IN('SALES_ORDER','SALES_ORDER_CHANGE')
                  AND reservation.status=0 AND NOT reservation.is_deleted
                WHERE item.analysis_id=:analysis AND root.id=:root AND NOT item.is_deleted AND item.planning_quantity_mode='COVERAGE_TOTAL'
                ORDER BY reservation.id FOR UPDATE OF reservation
                """).setParameter("analysis",analysisId).setParameter("root",rootId));
        BigDecimal remaining=rows.isEmpty()?BigDecimal.ZERO:maxBase.min(new BigDecimal(rows.getFirst()[3].toString()));boolean changed=false;
        for(Object[] row:rows) {
            BigDecimal take=remaining.min(new BigDecimal(row[2].toString())).min(new BigDecimal(row[3].toString()));
            if(take.signum()<=0)continue;
            int added=em.createNativeQuery("""
                    INSERT INTO preplan_sales_stock_adoptions(analysis_id,analysis_item_id,root_material_id,reservation_id,qty_base,idempotency_key,created_by)
                    VALUES(:analysis,:item,:root,:reservation,:qty,:key,:actor) ON CONFLICT(idempotency_key) DO NOTHING
                    """).setParameter("analysis",analysisId).setParameter("item",row[1]).setParameter("root",rootId)
                    .setParameter("reservation",row[0]).setParameter("qty",take).setParameter("key",key+":"+row[0]).setParameter("actor",actor).executeUpdate();
            remaining=remaining.subtract(take);changed|=added>0;if(remaining.signum()==0)break;
        }
        return changed;
    }
}
