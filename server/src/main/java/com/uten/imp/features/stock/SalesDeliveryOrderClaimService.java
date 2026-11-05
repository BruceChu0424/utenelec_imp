package com.uten.imp.features.stock;

import com.uten.imp.application.port.SalesDeliveryOrderClaimPort;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.util.*;

/** A claim pins an already-private order reservation at a physical warehouse without copying/releasing it. */
@Service
@RequiredArgsConstructor
@Transactional(propagation=Propagation.MANDATORY)
public class SalesDeliveryOrderClaimService implements SalesDeliveryOrderClaimPort {
    private final EntityManager em;
    private final StockService stock;
    private final TxSessionVars tx;
    private record Source(UUID component,UUID shipment,UUID orderItem,UUID goods,UUID color,UUID unit,
            BigDecimal required,BigDecimal rate,UUID warehouse) {}

    @Override public void prepare(UUID componentId,UUID warehouseId,BigDecimal quantity,UUID requestId) {
        tx.bind(); exact(quantity);if(warehouseId==null||requestId==null)throw conflict("订单实物认领缺少实际仓或请求编号");
        Source found=source(componentId,false);if(found==null)return; // Only the whole-product frontier uses this source family.
        stock.lockInventory(List.of(new InventoryKey(found.goods(),found.color())));
        Source source=source(componentId,true);
        if(source.required().compareTo(quantity)!=0)throw conflict("订单认领数量与冻结交付件不一致");
        var prior=rows("SELECT warehouse_id,requested_qty FROM sales_delivery_order_claim_requests WHERE request_id=:request AND component_id=:id",
                Map.of("request",requestId,"id",componentId));
        if(!prior.isEmpty()){
            if(!warehouseId.equals(prior.getFirst()[0])||quantity.compareTo(decimal(prior.getFirst()[1]))!=0)
                throw conflict("同一认领请求编号已经用于不同仓或数量");
            return;
        }
        if(!Objects.equals(source.warehouse(),warehouseId)) {
            int changed=em.createNativeQuery("""
                UPDATE sales_shipment_delivery_components SET warehouse_id=:warehouse
                WHERE id=:id AND movement_id IS NULL AND processing_started_at IS NULL AND processing_issued_at IS NULL
                  AND processing_completed_qty=0
                  AND NOT EXISTS(SELECT 1 FROM v_sales_delivery_order_claim_active active WHERE active.component_id=:id)
                """).setParameter("warehouse",warehouseId).setParameter("id",componentId).executeUpdate();
            if(changed!=1)throw conflict("该整件实物已经交接或认领，不能更换来源仓");
        }
        BigDecimal held=heldQuantities(List.of(componentId)).getOrDefault(componentId,BigDecimal.ZERO);
        BigDecimal otherHeld=decimal(em.createNativeQuery("""
            SELECT COALESCE(sum(qty-consumed_qty-released_qty),0) FROM stock_reservations
            WHERE owner_type IN('SALES_DELIVERY_PROCESSING','SALES_DELIVERY_COMPONENT_SHIPMENT')
              AND owner_id=:id AND status=0 AND NOT is_deleted
            """).setParameter("id",componentId).getSingleResult());
        BigDecimal need=quantity.subtract(held).subtract(otherHeld);if(need.signum()<0)throw conflict("订单实物认领超过交付数量");
        BigDecimal ownOpen=decimal(em.createNativeQuery("""
            SELECT COALESCE(sum(GREATEST(reservation.qty-reservation.consumed_qty-reservation.released_qty-
                COALESCE((SELECT sum(active.quantity) FROM v_sales_delivery_order_claim_active active
                    WHERE active.reservation_id=reservation.id),0),0)),0)
            FROM stock_reservations reservation WHERE reservation.order_item_id=:orderItem
              AND reservation.owner_type='SALES_ORDER_ITEM' AND reservation.goods_id=:goods
              AND reservation.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
              AND NOT reservation.is_deleted AND reservation.status=0
            """).setParameter("orderItem",source.orderItem()).setParameter("goods",source.goods())
                .setParameter("color",source.color()).getSingleResult());
        // Existing private stock is the first source, across all warehouses. Public stock cannot strand its row credit.
        BigDecimal minimumOwn=quantity.subtract(held).min(ownOpen);
        if(minimumOwn.compareTo(need)>0)throw conflict("本单已有原订单私有权益，不能用公共库存替代；请先核对原仓权益或拆分备货");
        if(need.signum()==0){requestResult(requestId,componentId,warehouseId,quantity,BigDecimal.ZERO);return;}
        // The canonical physical storage gate excludes this order's original reservations, then pins its claims once.
        BigDecimal physical=decimal(em.createNativeQuery("SELECT fn_stock_storage_movable(:warehouse,:goods,CAST(:color AS uuid),ARRAY[CAST(:orderItem AS uuid)],TRUE)")
                .setParameter("warehouse",warehouseId).setParameter("goods",source.goods()).setParameter("color",source.color())
                .setParameter("orderItem",source.orderItem()).getSingleResult());
        BigDecimal pinned=decimal(em.createNativeQuery("""
            SELECT COALESCE(sum(active.quantity),0) FROM v_sales_delivery_order_claim_active active
            JOIN stock_reservations reservation ON reservation.id=active.reservation_id
            WHERE active.warehouse_id=:warehouse AND active.goods_id=:goods
              AND active.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
              AND (active.order_item_id=:orderItem OR reservation.warehouse_id IS NULL)
            """).setParameter("warehouse",warehouseId).setParameter("goods",source.goods()).setParameter("color",source.color())
                .setParameter("orderItem",source.orderItem()).getSingleResult());
        BigDecimal physicalRemaining=physical.subtract(pinned).max(BigDecimal.ZERO);
        var reservations=rows("""
            SELECT reservation.id,reservation.qty-reservation.consumed_qty-reservation.released_qty,
                fn_stock_claim_open_at(reservation.id,:warehouse),reservation.consumed_qty,
                COALESCE((SELECT sum(active.quantity) FROM v_sales_delivery_order_claim_active active
                    WHERE active.reservation_id=reservation.id),0),
                COALESCE((SELECT sum(active.quantity) FROM v_sales_delivery_order_claim_active active
                    WHERE active.reservation_id=reservation.id AND active.warehouse_id=:warehouse),0),
                CAST(fn_sales_delivery_order_claim_identity(reservation) AS text),
                COALESCE((SELECT sum(event.quantity*CASE WHEN event.event_type='CONSUME' THEN 1 ELSE -1 END)
                    FROM sales_delivery_order_claim_events event JOIN sales_delivery_order_claims claim ON claim.id=event.claim_id
                    WHERE claim.reservation_id=reservation.id AND event.event_type IN('CONSUME','REVERSE')),0),
                output.id,output.qty_base,output.qty_source,
                CASE WHEN output.id IS NULL THEN TRUE ELSE NOT EXISTS(SELECT 1 FROM preplan_root_output_events other
                    WHERE other.analysis_item_id=output.analysis_item_id AND other.id<>output.id) END,reservation.qty
            FROM stock_reservations reservation
            LEFT JOIN preplan_root_output_events output ON output.sales_reservation_id=reservation.id AND output.event_kind='FULFILL'
            WHERE reservation.order_item_id=:orderItem AND reservation.owner_type='SALES_ORDER_ITEM'
              AND reservation.goods_id=:goods AND reservation.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
              AND NOT reservation.is_deleted AND reservation.status=0
              AND reservation.qty-reservation.consumed_qty-reservation.released_qty>0
            ORDER BY reservation.created_at,reservation.id FOR UPDATE OF reservation
            """,parameters("warehouse",warehouseId,"orderItem",source.orderItem(),"goods",source.goods(),"color",source.color()));
        BigDecimal claimed=BigDecimal.ZERO;
        for(var r:reservations){
            if(need.signum()<=0||physicalRemaining.signum()<=0)break;
            BigDecimal available=availableClaim(decimal(r[1]),decimal(r[2]),decimal(r[4]),decimal(r[5]));
            BigDecimal take=need.min(available).min(physicalRemaining);if(take.signum()<=0)continue;
            exact(take);
            BigDecimal sourceCap=sourceRowCap((UUID)r[8],decimal(r[12]),r[10],source.rate());
            BigDecimal sourceBase=r[9]==null?decimal(r[12]):decimal(r[9]);
            rowCredit(take,sourceBase,sourceCap,source.rate(),decimal(r[3]),decimal(r[4]),Boolean.TRUE.equals(r[11]));
            em.createNativeQuery("""
                INSERT INTO sales_delivery_order_claims(component_id,shipment_id,order_item_id,reservation_id,warehouse_id,
                    goods_id,color_id,unit_id,quantity,unit_rate,source_identity,source_consumed_baseline,request_id,
                    source_output_event_id,source_base_qty,source_row_cap)
                VALUES(:component,:shipment,:orderItem,:reservation,:warehouse,:goods,:color,:unit,:quantity,:rate,
                    CAST(:identity AS jsonb),:baseline,:request,:output,:sourceBase,:sourceCap)
                """).setParameter("component",componentId).setParameter("shipment",source.shipment()).setParameter("orderItem",source.orderItem())
                    .setParameter("reservation",r[0]).setParameter("warehouse",warehouseId).setParameter("goods",source.goods())
                    .setParameter("color",source.color()).setParameter("unit",source.unit()).setParameter("quantity",take)
                    .setParameter("rate",source.rate()).setParameter("identity",r[6].toString())
                    .setParameter("baseline",decimal(r[3]).subtract(decimal(r[7]))).setParameter("request",requestId)
                    .setParameter("output",r[8]).setParameter("sourceBase",sourceBase).setParameter("sourceCap",sourceCap).executeUpdate();
            need=need.subtract(take);claimed=claimed.add(take);physicalRemaining=physicalRemaining.subtract(take);
        }
        if(claimed.compareTo(minimumOwn)<0)throw conflict("本单原订单权益在其它仓或已被占用；请先按真实移仓或拆分备货，不能改用公共库存替代");
        requestResult(requestId,componentId,warehouseId,quantity,claimed);
    }
    private void requestResult(UUID requestId,UUID componentId,UUID warehouseId,BigDecimal quantity,BigDecimal claimed){
        em.createNativeQuery("INSERT INTO sales_delivery_order_claim_requests(request_id,component_id,warehouse_id,requested_qty,claimed_qty) VALUES(:request,:id,:warehouse,:quantity,:claimed)")
                .setParameter("request",requestId).setParameter("id",componentId).setParameter("warehouse",warehouseId)
                .setParameter("quantity",quantity).setParameter("claimed",claimed).executeUpdate();
    }
    @Override @Transactional(readOnly=true)
    public Map<UUID,BigDecimal> heldQuantities(Collection<UUID> componentIds) {
        if(componentIds==null||componentIds.isEmpty())return Map.of();
        if(componentIds.size()>10000)throw conflict("单次认领查询超过允许的交付件数");
        Map<UUID,BigDecimal> result=new LinkedHashMap<>();
        for(var row:rows("SELECT component_id,sum(quantity) FROM v_sales_delivery_order_claim_active WHERE component_id IN(:ids) GROUP BY component_id",Map.of("ids",componentIds)))
            result.put((UUID)row[0],decimal(row[1]));
        return Map.copyOf(result);
    }
    @Override public void consume(UUID componentId) {
        tx.bind();Source source=source(componentId,false);if(source==null)return;
        stock.lockInventory(List.of(new InventoryKey(source.goods(),source.color())));source=source(componentId,true);
        var claims=rows("""
            SELECT claim.id,claim.reservation_id,claim.warehouse_id,claim.quantity,claim.source_base_qty,claim.source_row_cap,
                reservation.consumed_qty,claim.unit_rate,
                CASE WHEN claim.source_output_event_id IS NULL THEN TRUE ELSE NOT EXISTS(
                    SELECT 1 FROM preplan_root_output_events other JOIN preplan_root_output_events original
                      ON original.id=claim.source_output_event_id
                    WHERE other.analysis_item_id=original.analysis_item_id AND other.id<>original.id) END
            FROM v_sales_delivery_order_claim_active claim JOIN stock_reservations reservation ON reservation.id=claim.reservation_id
            WHERE claim.component_id=:id ORDER BY claim.reservation_id,claim.id
            """,Map.of("id",componentId));
        if(claims.isEmpty())return;
        BigDecimal total=BigDecimal.ZERO,totalRow=BigDecimal.ZERO;
        for(var claim:claims){
            BigDecimal credit=rowCredit(decimal(claim[3]),decimal(claim[4]),decimal(claim[5]),decimal(claim[7]),
                    decimal(claim[6]),BigDecimal.ZERO,Boolean.TRUE.equals(claim[8]));
            em.createNativeQuery("SELECT fn_stock_claim_consume(:reservation,:warehouse,:quantity,:shipment,:component)")
                    .setParameter("reservation",claim[1]).setParameter("warehouse",claim[2]).setParameter("quantity",claim[3])
                    .setParameter("shipment",source.shipment()).setParameter("component",componentId).getSingleResult();
            int changed=em.createNativeQuery("""
                UPDATE stock_reservations SET consumed_qty=consumed_qty+:quantity,
                    status=CASE WHEN qty-consumed_qty-released_qty=:quantity THEN 1 ELSE 0 END,updated_at=now()
                WHERE id=:id AND status=0 AND NOT is_deleted AND qty-consumed_qty-released_qty>=:quantity
                """).setParameter("id",claim[1]).setParameter("quantity",claim[3]).executeUpdate();
            if(changed!=1)throw conflict("本订单原实物预留已变化，不能消费其它订单的权益");
            event((UUID)claim[0],"CONSUME",decimal(claim[3]),credit,null);total=total.add(decimal(claim[3]));totalRow=totalRow.add(credit);
        }
        var cumulative=rows("""
            SELECT COALESCE(sum(quantity_base*CASE WHEN event_type='CONSUME' THEN 1 ELSE -1 END),0),
                COALESCE(sum(quantity_row*CASE WHEN event_type='CONSUME' THEN 1 ELSE -1 END),0)
            FROM sales_delivery_order_claim_row_events WHERE order_item_id=:id
            """,Map.of("id",source.orderItem())).getFirst();
        BigDecimal beforeBase=decimal(cumulative[0]),beforeRow=decimal(cumulative[1]);
        BigDecimal afterBase=beforeBase.add(total);
        BigDecimal delta=totalRow,afterRow=beforeRow.add(delta);
        em.createNativeQuery("""
            INSERT INTO sales_delivery_order_claim_row_events(component_id,order_item_id,event_type,quantity_base,quantity_row,
                unit_rate,before_base,before_row,after_base,after_row,precision_policy)
            VALUES(:component,:orderItem,'CONSUME',:base,:row,:rate,:beforeBase,:beforeRow,:afterBase,:afterRow,CAST(:policy AS jsonb))
            """).setParameter("component",componentId).setParameter("orderItem",source.orderItem()).setParameter("base",total)
                .setParameter("row",delta).setParameter("rate",source.rate()).setParameter("beforeBase",beforeBase)
                .setParameter("beforeRow",beforeRow).setParameter("afterBase",afterBase).setParameter("afterRow",afterRow)
                .setParameter("policy",BusinessPrecisionContext.json()).executeUpdate();
    }
    @Override public void cancel(UUID componentId) {
        tx.bind();Source source=source(componentId,false);if(source==null)return;
        stock.lockInventory(List.of(new InventoryKey(source.goods(),source.color())));source(componentId,true);
        for(var claim:rows("SELECT id,quantity FROM v_sales_delivery_order_claim_active WHERE component_id=:id ORDER BY reservation_id,id",Map.of("id",componentId)))
            event((UUID)claim[0],"CANCEL",decimal(claim[1]),BigDecimal.ZERO,null);
    }
    @Override public void reverse(UUID shipmentId) {
        tx.bind();var debits=rows("""
            SELECT debit.id,debit.component_id,debit.order_item_id,debit.quantity_base,debit.quantity_row,debit.unit_rate,debit.precision_policy::text
            FROM sales_delivery_order_claim_row_events debit
            JOIN sales_shipment_delivery_components component ON component.id=debit.component_id
            WHERE component.shipment_id=:shipment AND debit.event_type='CONSUME'
              AND NOT EXISTS(SELECT 1 FROM sales_delivery_order_claim_row_events reverse WHERE reverse.counter_event_id=debit.id)
            ORDER BY debit.order_item_id,debit.id
            """,Map.of("shipment",shipmentId));
        for(var debit:debits){
            UUID componentId=(UUID)debit[1];Source source=source(componentId,false);
            if(source==null)throw conflict("原订单整件认领来源已变化");
            stock.lockInventory(List.of(new InventoryKey(source.goods(),source.color())));source(componentId,true);
            var claims=rows("""
                SELECT claim.id,claim.reservation_id,claim.warehouse_id,claim.quantity,event.id,event.row_credit_qty
                FROM sales_delivery_order_claims claim JOIN sales_delivery_order_claim_events event ON event.claim_id=claim.id AND event.event_type='CONSUME'
                WHERE claim.component_id=:id AND NOT EXISTS(SELECT 1 FROM sales_delivery_order_claim_events reverse WHERE reverse.counter_event_id=event.id)
                ORDER BY claim.reservation_id,claim.id
                """,Map.of("id",componentId));
            for(var claim:claims){
                int changed=em.createNativeQuery("""
                    UPDATE stock_reservations SET consumed_qty=consumed_qty-:quantity,status=0,updated_at=now()
                    WHERE id=:id AND NOT is_deleted AND consumed_qty>=:quantity
                    """).setParameter("id",claim[1]).setParameter("quantity",claim[3]).executeUpdate();
                if(changed!=1)throw conflict("原订单消费记录不足，不能伪造恢复权益");
                em.createNativeQuery("SELECT fn_stock_claim_restore(:reservation,:warehouse,:quantity,:shipment,:component)")
                        .setParameter("reservation",claim[1]).setParameter("warehouse",claim[2]).setParameter("quantity",claim[3])
                        .setParameter("shipment",shipmentId).setParameter("component",componentId).getSingleResult();
                event((UUID)claim[0],"REVERSE",decimal(claim[3]),decimal(claim[5]),(UUID)claim[4]);
            }
            var cumulative=rows("SELECT COALESCE(sum(quantity_base*CASE WHEN event_type='CONSUME' THEN 1 ELSE -1 END),0),COALESCE(sum(quantity_row*CASE WHEN event_type='CONSUME' THEN 1 ELSE -1 END),0) FROM sales_delivery_order_claim_row_events WHERE order_item_id=:id",Map.of("id",debit[2])).getFirst();
            em.createNativeQuery("""
                INSERT INTO sales_delivery_order_claim_row_events(component_id,order_item_id,event_type,quantity_base,quantity_row,unit_rate,
                    before_base,before_row,after_base,after_row,precision_policy,counter_event_id)
                VALUES(:component,:orderItem,'REVERSE',:base,:row,:rate,:beforeBase,:beforeRow,:afterBase,:afterRow,CAST(:policy AS jsonb),:counter)
                """).setParameter("component",componentId).setParameter("orderItem",debit[2]).setParameter("base",debit[3])
                    .setParameter("row",debit[4]).setParameter("rate",debit[5]).setParameter("beforeBase",cumulative[0])
                    .setParameter("beforeRow",cumulative[1]).setParameter("afterBase",decimal(cumulative[0]).subtract(decimal(debit[3])))
                    .setParameter("afterRow",decimal(cumulative[1]).subtract(decimal(debit[4])))
                    .setParameter("policy",debit[6]).setParameter("counter",debit[0]).executeUpdate();
        }
    }
    private Source source(UUID id,boolean lock) {
        var found=rows("""
            SELECT component.id,component.shipment_id,component.order_item_id,component.goods_id,component.color_id,component.unit_id,
                component.required_qty,item.unit_rate,component.warehouse_id,component.bom_path::text,item.delivery_plan->>'mode',
                item.goods_id,item.color_id,goods.unit_id,document.is_deleted,shipment_item.is_deleted
            FROM sales_shipment_delivery_components component JOIN sales_shipment_items shipment_item ON shipment_item.id=component.shipment_item_id
            JOIN sales_shipments document ON document.id=component.shipment_id
            JOIN sales_order_items item ON item.id=component.order_item_id JOIN goods ON goods.id=item.goods_id
            WHERE component.id=:id
            """+(lock?" FOR UPDATE OF component,item":""),Map.of("id",id));
        if(found.size()!=1)throw conflict("交付件不存在");var r=found.getFirst();
        if(!"[]".equals(r[9])||!"ASSEMBLED".equals(r[10]))return null;
        if(!Objects.equals(r[3],r[11])||!Objects.equals(r[4],r[12])||!Objects.equals(r[5],r[13])
                ||Boolean.TRUE.equals(r[14])||Boolean.TRUE.equals(r[15])||r[7]==null||decimal(r[7]).signum()<=0)
            throw conflict("整件交付与原销售订单的货品、颜色或基本单位不一致");
        return new Source((UUID)r[0],(UUID)r[1],(UUID)r[2],(UUID)r[3],(UUID)r[4],(UUID)r[5],decimal(r[6]),decimal(r[7]),(UUID)r[8]);
    }
    private void event(UUID claim,String kind,BigDecimal quantity,BigDecimal credit,UUID counter) {
        em.createNativeQuery("INSERT INTO sales_delivery_order_claim_events(claim_id,event_type,quantity,row_credit_qty,counter_event_id) VALUES(:claim,:kind,:quantity,:credit,:counter)")
                .setParameter("claim",claim).setParameter("kind",kind).setParameter("quantity",quantity).setParameter("credit",credit).setParameter("counter",counter).executeUpdate();
    }
    private List<Object[]> rows(String sql,Map<String,?> values) {
        var query=em.createNativeQuery(sql);values.forEach(query::setParameter);return NativeQueryResults.objectArrayRows(query);
    }
    private static Map<String,Object> parameters(Object... values) {
        Map<String,Object> result=new LinkedHashMap<>();for(int i=0;i<values.length;i+=2)result.put(values[i].toString(),values[i+1]);return result;
    }
    static BigDecimal availableClaim(BigDecimal effective,BigDecimal located,BigDecimal claimed,BigDecimal claimedHere) {
        return effective.subtract(claimed).min(located.subtract(claimedHere)).max(BigDecimal.ZERO);
    }
    private static BigDecimal sourceRowCap(UUID output,BigDecimal base,Object cap,BigDecimal rate) {
        if(output!=null&&cap!=null)return decimal(cap);
        if(output==null&&rate.compareTo(BigDecimal.ONE)==0)return base;
        throw conflict("原订单预留缺少不可变的商业数量额度，请核对原入库事实；不能反算或猜测历史权益");
    }
    static BigDecimal rowCredit(BigDecimal take,BigDecimal sourceBase,BigDecimal cap,BigDecimal rate,
            BigDecimal consumed,BigDecimal otherClaims,boolean uniqueSource) {
        if(cap.signum()<0||sourceBase.signum()<=0||rate.signum()<=0)throw conflict("原订单预留的数量额度无效");
        if(cap.multiply(rate).compareTo(sourceBase)==0) {
            try{return take.divide(rate).setScale(4,java.math.RoundingMode.UNNECESSARY).stripTrailingZeros();}
            catch(ArithmeticException e){throw conflict("该原预留的部分认领不能无损换算到原商业单位，请整笔认领或先核对来源");}
        }
        if(uniqueSource&&consumed.signum()==0&&otherClaims.signum()==0&&take.compareTo(sourceBase)==0)return cap;
        throw conflict("该原预留含采用尾差或多笔供给，无法证明部分商业额度；请整笔认领或先核对来源");
    }
    private static BigDecimal decimal(Object value) { return value==null?BigDecimal.ZERO:value instanceof BigDecimal n?n:new BigDecimal(value.toString()); }
    private static void exact(BigDecimal qty) { if(qty==null||qty.signum()<=0||qty.stripTrailingZeros().scale()>4||qty.compareTo(new BigDecimal("100000000000000"))>=0)throw conflict("订单实物认领数量须为原4位基本单位精确量"); }
    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT,message); }
}
