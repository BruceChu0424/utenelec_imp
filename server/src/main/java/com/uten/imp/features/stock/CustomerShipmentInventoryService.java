package com.uten.imp.features.stock;

import com.uten.imp.application.port.CustomerShipmentInventoryPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.Collection;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/** Warehouse-local entitlements for explicit, orderless customer dispatches. */
@Service
@RequiredArgsConstructor
@Transactional(propagation=Propagation.MANDATORY)
public class CustomerShipmentInventoryService implements CustomerShipmentInventoryPort {
    public static final String OWNER="CUSTOMER_SHIPMENT_ITEM";
    private final EntityManager em;
    private final InventoryMutationLock inventory;
    private final SecurityContextCurrentUser currentUser;

    @Override public void reservePicking(UUID shipmentId,UUID warehouseId,long revision,Collection<Line> requested) {
        List<Line> lines=validated(shipmentId,warehouseId,requested);
        requireNoUnreleased(shipmentId);
        Map<InventoryKey,BigDecimal> needed=new java.util.TreeMap<>();
        lines.forEach(line->needed.merge(new InventoryKey(line.goodsId(),line.colorId()),base(line.baseQty()),BigDecimal::add));
        for(var demand:needed.entrySet()) {
            Object[] capacity=(Object[])em.createNativeQuery("""
                    SELECT
                      GREATEST(COALESCE((SELECT SUM(GREATEST(balance.qty-GREATEST(COALESCE(CAST(goods.min_qty AS NUMERIC),0),0),0))
                          FROM stock_balances balance JOIN goods ON goods.id=balance.goods_id
                          WHERE balance.goods_id=:goods AND balance.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)),0)
                        -COALESCE((SELECT SUM(qty-consumed_qty-released_qty) FROM stock_reservations
                          WHERE goods_id=:goods AND color_id IS NOT DISTINCT FROM CAST(:color AS uuid) AND status=0 AND NOT is_deleted),0)
                        -COALESCE((SELECT SUM(item.qty*COALESCE(NULLIF(item.unit_rate,0),1)) FROM sales_shipment_items item
                          JOIN sales_shipments document ON document.id=item.shipment_id
                          WHERE document.shipment_kind<>'DIRECT_CUSTOMER' AND item.order_item_id IS NULL
                            AND document.status=0 AND NOT document.is_deleted AND NOT document.rejected AND NOT item.is_deleted
                            AND document.warehouse_work_status IN ('PICKING','PICKED','EXCEPTION')
                            AND item.goods_id=:goods AND item.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)),0),0),
                      GREATEST(COALESCE((SELECT balance.qty-GREATEST(COALESCE(CAST(goods.min_qty AS NUMERIC),0),0)
                          FROM stock_balances balance JOIN goods ON goods.id=balance.goods_id
                          WHERE balance.warehouse_id=:warehouse AND balance.goods_id=:goods
                            AND balance.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)),0)
                        -COALESCE((SELECT SUM(qty-consumed_qty-released_qty) FROM stock_reservations
                          WHERE warehouse_id=:warehouse AND goods_id=:goods AND color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                            AND status=0 AND NOT is_deleted),0)
                        -COALESCE((SELECT SUM(item.qty*COALESCE(NULLIF(item.unit_rate,0),1)) FROM sales_shipment_items item
                          JOIN sales_shipments document ON document.id=item.shipment_id
                          WHERE document.shipment_kind<>'DIRECT_CUSTOMER' AND item.order_item_id IS NULL
                            AND document.warehouse_id=:warehouse AND document.status=0 AND NOT document.is_deleted
                            AND NOT document.rejected AND NOT item.is_deleted AND document.warehouse_work_status IN ('PICKING','PICKED','EXCEPTION')
                            AND item.goods_id=:goods AND item.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)),0),0)
                    """).setParameter("goods",demand.getKey().goodsId()).setParameter("color",demand.getKey().colorId())
                    .setParameter("warehouse",warehouseId).getSingleResult();
            if(demand.getValue().compareTo(decimal(capacity[0]).min(decimal(capacity[1])))>0)
                throw conflict("可用库存不足，不能占用其他订单、生产或委外已预留的货品");
        }
        String attempt="CUSTOMER-SHIP-PICK:"+shipmentId+":"+revision+":"+UUID.randomUUID();
        int inserted=em.createNativeQuery("""
                INSERT INTO stock_reservations(id,owner_type,owner_id,purpose,goods_id,color_id,warehouse_id,
                    qty,consumed_qty,released_qty,status,source,source_doc_type,source_doc_id,supply_type,supply_id,
                    idempotency_key,created_by,updated_by)
                SELECT gen_random_uuid(),'CUSTOMER_SHIPMENT_ITEM',item.id,'CUSTOMER_SHIPMENT_ITEM',item.goods_id,item.color_id,
                    :warehouse,ROUND(item.qty*COALESCE(NULLIF(item.unit_rate,0),1),4),0,0,0,0,'SALES_SHIPMENT',:shipment,
                    'STOCK_BALANCE',balance.id,:attempt||':'||item.id::text,:actor,:actor
                FROM sales_shipment_items item JOIN stock_balances balance
                  ON balance.warehouse_id=:warehouse AND balance.goods_id=item.goods_id AND balance.color_id IS NOT DISTINCT FROM item.color_id
                WHERE item.shipment_id=:shipment AND NOT item.is_deleted ORDER BY item.id
                """).setParameter("shipment",shipmentId).setParameter("warehouse",warehouseId)
                .setParameter("attempt",attempt).setParameter("actor",currentUser.requireId()).executeUpdate();
        if(inserted!=lines.size())throw conflict("发货明细与库存来源已变化，请刷新后重试");
    }

    @Override public void consumeShipment(UUID shipmentId,UUID warehouseId,Collection<Line> requested) {
        List<Line> lines=validated(shipmentId,warehouseId,requested);
        Map<UUID,Object[]> reservations=new HashMap<>();
        for(var row:lockedReservations(shipmentId)) {
            if(reservations.put((UUID)row[1],row)!=null)throw conflict("发货存在重复库存占用，请先核对");
        }
        if(reservations.size()!=lines.size())throw conflict("发货库存占用缺失，请重新核对拣货任务");
        for(Line line:lines) {
            Object[] row=reservations.get(line.itemId());
            if(row==null||!Objects.equals(row[4],warehouseId)||decimal(row[5]).subtract(decimal(row[6])).subtract(decimal(row[7])).compareTo(base(line.baseQty()))!=0)
                throw conflict("发货数量与实际拣货占用不一致");
            int updated=em.createNativeQuery("""
                    UPDATE stock_reservations SET consumed_qty=qty-released_qty,status=1,updated_at=now(),updated_by=:actor
                    WHERE id=:id AND status=0 AND NOT is_deleted AND qty-consumed_qty-released_qty=:qty
                    """).setParameter("id",row[0]).setParameter("qty",base(line.baseQty())).setParameter("actor",currentUser.requireId()).executeUpdate();
            if(updated!=1)throw conflict("拣货占用已变化，本次发运未生效");
        }
    }

    @Override public void releaseUnpicked(UUID shipmentId) {
        for(var row:lockedReservations(shipmentId)) {
            if(decimal(row[6]).signum()!=0)throw conflict("已有实际发运，不能当作退拣释放库存");
            em.createNativeQuery("""
                    UPDATE stock_reservations SET released_qty=qty,status=1,release_reason='CUSTOMER_SHIPMENT_UNPICKED',
                        updated_at=now(),updated_by=:actor WHERE id=:id AND status=0 AND consumed_qty=0
                    """).setParameter("id",row[0]).setParameter("actor",currentUser.requireId()).executeUpdate();
        }
    }
    @Override public void requireNoUnreleased(UUID shipmentId) {
        Number count=(Number)em.createNativeQuery("""
                SELECT COUNT(*) FROM stock_reservations WHERE owner_type='CUSTOMER_SHIPMENT_ITEM' AND source_doc_id=:id
                  AND status=0 AND NOT is_deleted AND qty-consumed_qty-released_qty>0
                """).setParameter("id",shipmentId).getSingleResult();
        if(count.longValue()!=0)throw conflict("仓库仍有拣货占用，请先完成退拣再修改或取消");
    }

    private List<Line> validated(UUID shipmentId,UUID warehouseId,Collection<Line> requested) {
        List<Line> lines=requested==null?List.of():List.copyOf(requested);
        if(lines.isEmpty()||lines.stream().map(Line::itemId).distinct().count()!=lines.size())throw conflict("发货明细为空或重复");
        lines.forEach(line->inventory.requireHeld(new InventoryKey(line.goodsId(),line.colorId())));
        List<Object[]> rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT item.id,item.goods_id,item.color_id,ROUND(item.qty*COALESCE(NULLIF(item.unit_rate,0),1),4)
                FROM sales_shipments document JOIN sales_shipment_items item ON item.shipment_id=document.id AND NOT item.is_deleted
                WHERE document.id=:id AND document.shipment_kind='DIRECT_CUSTOMER' AND document.warehouse_id=:warehouse
                  AND document.status=0 AND NOT document.is_deleted AND NOT document.rejected AND document.finance_audit=1
                  AND document.sales_confirmed_revision=document.review_revision AND document.sales_confirmed_at IS NOT NULL
                ORDER BY item.id FOR UPDATE OF document,item
                """).setParameter("id",shipmentId).setParameter("warehouse",warehouseId));
        if(rows.size()!=lines.size())throw conflict("客户发货状态或明细已变化");
        Map<UUID,Line> expected=new HashMap<>();lines.forEach(line->expected.put(line.itemId(),line));
        for(var row:rows) {
            Line line=expected.get(row[0]);
            if(line==null||!Objects.equals(line.goodsId(),row[1])||!Objects.equals(line.colorId(),row[2])||base(line.baseQty()).compareTo(decimal(row[3]))!=0)
                throw conflict("客户发货库存身份或单位换算不一致");
        }
        return lines;
    }
    private List<Object[]> lockedReservations(UUID shipmentId) {
        List<Object[]> dimensions=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT goods_id,color_id FROM stock_reservations WHERE owner_type='CUSTOMER_SHIPMENT_ITEM'
                  AND source_doc_id=:id AND status=0 AND NOT is_deleted ORDER BY goods_id,color_id
                """).setParameter("id",shipmentId));
        dimensions.forEach(row->inventory.requireHeld(new InventoryKey((UUID)row[0],(UUID)row[1])));
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id,owner_id,goods_id,color_id,warehouse_id,qty,consumed_qty,released_qty FROM stock_reservations
                WHERE owner_type='CUSTOMER_SHIPMENT_ITEM' AND source_doc_id=:id AND status=0 AND NOT is_deleted ORDER BY id FOR UPDATE
                """).setParameter("id",shipmentId));
    }
    private static BigDecimal base(BigDecimal value) {
        if(value==null||value.setScale(4,RoundingMode.HALF_UP).signum()<=0)throw conflict("发货基本单位数量过小或无效");
        return value.setScale(4,RoundingMode.HALF_UP);
    }
    private static BigDecimal decimal(Object value){return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
