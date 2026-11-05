package com.uten.imp.features.stock;

import com.uten.imp.application.port.SalesDeliveryInventoryPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.*;

@Service
@RequiredArgsConstructor
public class SalesDeliveryInventoryService implements SalesDeliveryInventoryPort {
    private final EntityManager em;
    private final StockService stock;
    private final org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.SalesDeliveryOrderClaimPort> orderClaims;

    @Override @Transactional(readOnly=true)
    public Map<UUID,BigDecimal> ownedQuantities(Collection<UUID> componentIds){
        if(componentIds.isEmpty())return Map.of();
        Map<UUID,BigDecimal> result=new HashMap<>(orderClaims.getObject().heldQuantities(componentIds));
        for(var row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
            SELECT owner_id,sum(qty-consumed_qty-released_qty) FROM stock_reservations
            WHERE owner_type IN('SALES_DELIVERY_PROCESSING','SALES_DELIVERY_COMPONENT_SHIPMENT')
              AND owner_id IN(:ids) AND status=0 AND NOT is_deleted GROUP BY owner_id
            """).setParameter("ids",componentIds)))result.merge((UUID)row[0],(BigDecimal)row[1],BigDecimal::add);
        return Map.copyOf(result);
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void requireProcessingReservation(UUID componentId,UUID warehouseId,UUID goodsId,UUID colorId,BigDecimal quantity){
        requireStockQuantity(quantity);
        stock.lockInventory(List.of(new InventoryKey(goodsId,colorId)));
        var rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
            SELECT warehouse_id,goods_id,color_id,qty-consumed_qty-released_qty FROM stock_reservations
            WHERE owner_type IN('SALES_DELIVERY_PROCESSING','SALES_DELIVERY_COMPONENT_SHIPMENT')
              AND owner_id=:id AND status=0 AND NOT is_deleted FOR UPDATE
            """).setParameter("id",componentId));
        BigDecimal held=orderClaims.getObject().heldQuantities(List.of(componentId)).getOrDefault(componentId,BigDecimal.ZERO);
        for(var r:rows){if(!Objects.equals(r[0],warehouseId)||!Objects.equals(r[1],goodsId)||!Objects.equals(r[2],colorId))
            throw conflict("加工实物占用的货品或来源仓不一致");held=held.add((BigDecimal)r[3]);}
        if(held.compareTo(quantity)!=0)throw conflict("请先由仓库完整发至加工，车间不能直接占用未交接的库存");
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void reserveForProcessing(UUID componentId, UUID warehouseId, UUID goodsId, UUID colorId,
            UUID unitId, BigDecimal quantity, UUID requestId) {
        requireStockQuantity(quantity);
        stock.lockInventory(List.of(new InventoryKey(goodsId,colorId)));
        orderClaims.getObject().prepare(componentId,warehouseId,quantity,requestId);
        var held=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
            SELECT goods_id,color_id,warehouse_id,qty-consumed_qty-released_qty,owner_type FROM stock_reservations
            WHERE owner_type IN('SALES_DELIVERY_PROCESSING','SALES_DELIVERY_COMPONENT_SHIPMENT')
              AND owner_id=:id AND status=0 AND NOT is_deleted FOR UPDATE
            """).setParameter("id",componentId));
        BigDecimal heldQty=orderClaims.getObject().heldQuantities(List.of(componentId)).getOrDefault(componentId,BigDecimal.ZERO);boolean publicHeld=false;
        for(var row:held){if(!Objects.equals(row[0],goodsId)||!Objects.equals(row[1],colorId)||!Objects.equals(row[2],warehouseId))
            throw conflict("加工已占用的实物与本次请求不一致");heldQty=heldQty.add((BigDecimal)row[3]);publicHeld|="SALES_DELIVERY_PROCESSING".equals(row[4]);}
        if(heldQty.compareTo(quantity)>0)throw conflict("该散件已占实物超过需求，请核对来源");
        if(heldQty.compareTo(quantity)==0)return;
        if(publicHeld)throw conflict("加工已有公共实物占用但总量不足，请核对原来源");
        BigDecimal publicNeed=quantity.subtract(heldQty);
        BigDecimal available=choices(goodsId,colorId).stream().filter(c->c.warehouseId().equals(warehouseId))
                .map(Choice::availableQty).findFirst().orElse(BigDecimal.ZERO);
        BigDecimal global=(BigDecimal)em.createNativeQuery("SELECT fn_stock_global_usable(:goods,CAST(:color AS uuid))")
                .setParameter("goods",goodsId).setParameter("color",colorId).getSingleResult();
        available=available.min(global);
        if(available.compareTo(publicNeed)<0)throw conflict("加工来源仓可用实物不足，不能使用其他订单的占用");
        em.createNativeQuery("UPDATE sales_shipment_delivery_components SET warehouse_id=:warehouse WHERE id=:id AND movement_id IS NULL")
                .setParameter("warehouse",warehouseId).setParameter("id",componentId).executeUpdate();
        int count=em.createNativeQuery("""
            INSERT INTO stock_reservations(id,owner_type,owner_id,purpose,goods_id,color_id,warehouse_id,
              qty,consumed_qty,released_qty,status,source,source_doc_type,source_doc_id,supply_type,supply_id,idempotency_key)
            SELECT gen_random_uuid(),'SALES_DELIVERY_PROCESSING',component.id,'SALES_DELIVERY_PROCESSING',
              component.goods_id,component.color_id,:warehouse,:publicNeed,0,0,0,0,
              'SALES_SHIPMENT',component.shipment_id,'STOCK_BALANCE',balance.id,CAST(:request AS text)||':'||component.id::text
            FROM sales_shipment_delivery_components component JOIN v_stock_operable_balances balance
             ON balance.warehouse_id=:warehouse AND balance.goods_id=component.goods_id
             AND balance.color_id IS NOT DISTINCT FROM component.color_id
            WHERE component.id=:id AND component.goods_id=:goods AND component.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
             AND component.unit_id=:unit AND component.required_qty=:quantity AND component.movement_id IS NULL
            """).setParameter("warehouse",warehouseId).setParameter("request",requestId).setParameter("id",componentId)
                .setParameter("goods",goodsId).setParameter("color",colorId).setParameter("unit",unitId)
                .setParameter("quantity",quantity).setParameter("publicNeed",publicNeed).executeUpdate();
        if(count!=1)throw conflict("加工实物来源已变化，请重新核对");
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void releaseProcessing(UUID componentId) {
        var source=NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT goods_id,color_id,processing_completed_qty,movement_id FROM sales_shipment_delivery_components WHERE id=:id FOR UPDATE")
                .setParameter("id",componentId));
        if(source.size()!=1)throw conflict("加工来源不存在");
        if(((BigDecimal)source.getFirst()[2]).signum()>0||source.getFirst()[3]!=null)throw conflict("加工已报工或出库，不能释放实物占用");
        stock.lockInventory(List.of(new InventoryKey((UUID)source.getFirst()[0],(UUID)source.getFirst()[1])));
        em.createNativeQuery("UPDATE stock_reservations SET released_qty=qty,status=1,release_reason='DELIVERY_PROCESSING_CANCELLED',updated_at=now() WHERE owner_type='SALES_DELIVERY_PROCESSING' AND owner_id=:id AND status=0 AND consumed_qty=0 AND NOT is_deleted")
                .setParameter("id",componentId).executeUpdate();
        orderClaims.getObject().cancel(componentId);
    }

    @Override @Transactional(readOnly=true)
    public List<Choice> choices(UUID goodsId, UUID colorId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
            SELECT warehouse.id,warehouse.name,
              GREATEST(balance.qty-GREATEST(COALESCE(CAST(goods.min_qty AS numeric),0),0)
               -COALESCE((SELECT sum(r.qty-r.consumed_qty-r.released_qty) FROM stock_reservations r
                  WHERE r.warehouse_id=warehouse.id AND r.goods_id=:goods
                    AND r.color_id IS NOT DISTINCT FROM CAST(:color AS uuid) AND r.status=0 AND NOT r.is_deleted),0),0)
            FROM v_stock_operable_balances balance JOIN warehouses warehouse ON warehouse.id=balance.warehouse_id
            JOIN goods ON goods.id=balance.goods_id WHERE balance.goods_id=:goods
              AND balance.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
            ORDER BY warehouse.name,warehouse.id
            """).setParameter("goods",goodsId).setParameter("color",colorId)).stream()
                .map(row->new Choice((UUID)row[0],(String)row[1],(BigDecimal)row[2])).toList();
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void post(UUID shipmentId, List<Component> components, OffsetDateTime at) {
        if(components.isEmpty())return;
        stock.lockInventory(components.stream().map(c->new InventoryKey(c.goodsId(),c.colorId())).toList());
        for(var c:components)orderClaims.getObject().prepare(c.id(),c.warehouseId(),c.quantity(),c.id());
        Map<String,BigDecimal> totals=new LinkedHashMap<>();
        Map<String,Component> dimensions=new LinkedHashMap<>();
        Map<UUID,List<Object[]>> processingReservations=new HashMap<>();
        Map<UUID,BigDecimal> heldQuantities=new HashMap<>();
        Map<UUID,BigDecimal> orderQuantities=orderClaims.getObject().heldQuantities(components.stream().map(Component::id).toList());
        for(var c:components){
            requireStockQuantity(c.quantity());
            if(c.warehouseId()==null||c.quantity()==null||c.quantity().signum()<=0)
                throw conflict("散件出货缺少实际发出仓或有效数量");
            String key=c.warehouseId()+"|"+c.goodsId()+"|"+c.colorId();
            totals.merge(key,c.quantity(),BigDecimal::add);dimensions.putIfAbsent(key,c);
            var holds=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id,warehouse_id,goods_id,color_id,qty-consumed_qty-released_qty FROM stock_reservations
                WHERE owner_type IN('SALES_DELIVERY_PROCESSING','SALES_DELIVERY_COMPONENT_SHIPMENT')
                  AND owner_id=:id AND status=0 AND NOT is_deleted FOR UPDATE
                """).setParameter("id",c.id()));
            if(!holds.isEmpty()||orderQuantities.containsKey(c.id())){
                BigDecimal sum=orderQuantities.getOrDefault(c.id(),BigDecimal.ZERO);
                for(var held:holds){
                    if(!Objects.equals(held[1],c.warehouseId())||!Objects.equals(held[2],c.goodsId())||!Objects.equals(held[3],c.colorId()))
                        throw conflict("散件发出仓与原实物权益或加工占用不同");
                    sum=sum.add((BigDecimal)held[4]);
                }
                if(sum.signum()<0||sum.compareTo(c.quantity())>0)throw conflict("交付实物权益数量与本行需求不一致");
                processingReservations.put(c.id(),holds);heldQuantities.put(c.id(),sum);
            }
        }
        for(var entry:totals.entrySet()){
            var c=dimensions.get(entry.getKey());
            BigDecimal available=choices(c.goodsId(),c.colorId()).stream()
                    .filter(choice->choice.warehouseId().equals(c.warehouseId()))
                    .map(Choice::availableQty).findFirst().orElse(BigDecimal.ZERO);
            for(var candidate:components)if(processingReservations.containsKey(candidate.id())
                    &&Objects.equals(candidate.warehouseId(),c.warehouseId())&&Objects.equals(candidate.goodsId(),c.goodsId())
                    &&Objects.equals(candidate.colorId(),c.colorId()))available=available.add(heldQuantities.get(candidate.id()));
            if(available.compareTo(entry.getValue())<0)throw conflict("散件可用库存不足，不能占用其他订单、生产或委外预留");
        }
        Map<InventoryKey,BigDecimal> globalTotals=new TreeMap<>();
        for(var c:components)globalTotals.merge(new InventoryKey(c.goodsId(),c.colorId()),c.quantity(),BigDecimal::add);
        for(var entry:globalTotals.entrySet()){
            var key=entry.getKey();
            BigDecimal available=(BigDecimal)em.createNativeQuery("SELECT fn_stock_global_usable(:goods,CAST(:color AS uuid))")
                    .setParameter("goods",key.goodsId()).setParameter("color",key.colorId()).getSingleResult();
            for(var c:components)if(processingReservations.containsKey(c.id())&&Objects.equals(c.goodsId(),key.goodsId())
                    &&Objects.equals(c.colorId(),key.colorId()))available=available.add(heldQuantities.get(c.id()));
            if(available.compareTo(entry.getValue())<0)throw conflict("散件全局可用量不足，不能占用未分仓的其它订单承诺");
        }
        for(var c:components){
            orderClaims.getObject().consume(c.id());
            for(var held:processingReservations.getOrDefault(c.id(),List.of())){
                int consumed=em.createNativeQuery("UPDATE stock_reservations SET consumed_qty=qty-released_qty,status=1,updated_at=now() WHERE id=:id AND status=0 AND qty-consumed_qty-released_qty=:qty")
                        .setParameter("id",held[0]).setParameter("qty",held[4]).executeUpdate();
                if(consumed!=1)throw conflict("加工实物占用已变化，本次未出库");
            }
            var posted=stock.recordMovement(new StockService.MovementRequest(at,StockService.TYPE_SALES_OUT,
                    StockService.SRC_SALES_SHIPMENT,shipmentId,c.id(),c.goodsId(),c.colorId(),c.warehouseId(),
                    StockService.DIR_OUT,c.quantity(),c.unitId(),BigDecimal.ONE,null,"按订单BOM交付",null));
            int updated=em.createNativeQuery("""
                UPDATE sales_shipment_delivery_components SET movement_id=:movement,updated_at=now(),revision=revision+1
                WHERE id=:id AND shipment_id=:shipment AND movement_id IS NULL
                """).setParameter("movement",posted.movementId()).setParameter("id",c.id())
                    .setParameter("shipment",shipmentId).executeUpdate();
            if(updated!=1)throw conflict("散件出货结果已变化，请核对原任务");
        }
    }
    private static ApiException conflict(String text){return new ApiException(ErrorCode.CONFLICT,text);}
    private static void requireStockQuantity(BigDecimal quantity){
        if(quantity==null||quantity.signum()<=0||quantity.stripTrailingZeros().scale()>4
                ||quantity.compareTo(new BigDecimal("100000000000000"))>=0)
            throw conflict("实物数量超出库存账无损保存范围，请先明确采用精度，不能让数据库自动舍入");
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void reverse(UUID shipmentId,OffsetDateTime at){
        var rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
            SELECT id,goods_id,color_id,unit_id,required_qty,warehouse_id,movement_id,reversal_movement_id
            FROM sales_shipment_delivery_components WHERE shipment_id=:id ORDER BY id FOR UPDATE
            """).setParameter("id",shipmentId));
        stock.lockInventory(rows.stream().map(r->new InventoryKey((UUID)r[1],(UUID)r[2])).toList());
        for(var row:rows){
            if(row[6]==null||row[7]!=null)throw conflict("散件出货缺少原库存流水或已红冲，请核对原请求");
            var posted=stock.recordMovement(new StockService.MovementRequest(at,StockService.TYPE_SALES_OUT,
                StockService.SRC_SALES_SHIPMENT,shipmentId,(UUID)row[0],(UUID)row[1],(UUID)row[2],(UUID)row[5],
                StockService.DIR_IN,(BigDecimal)row[4],(UUID)row[3],BigDecimal.ONE,null,"散件出货红冲",null,
                new com.uten.imp.application.port.InventoryMovementCostReference.OriginalIssueMovement((UUID)row[6])));
            em.createNativeQuery("UPDATE sales_shipment_delivery_components SET reversal_movement_id=:movement,updated_at=now() WHERE id=:id AND reversal_movement_id IS NULL")
                .setParameter("movement",posted.movementId()).setParameter("id",row[0]).executeUpdate();
        }
        orderClaims.getObject().reverse(shipmentId);
    }
}
