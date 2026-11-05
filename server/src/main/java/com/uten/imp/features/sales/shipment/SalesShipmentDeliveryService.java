package com.uten.imp.features.sales.shipment;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.SalesDeliveryInventoryPort;
import com.uten.imp.common.delivery.DeliveryBom;
import com.uten.imp.common.delivery.DeliveryPlan;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.application.port.WarehouseUseValidationPort;
import com.uten.imp.application.port.WarehouseUse;
import com.uten.imp.features.sales.order.SalesOrderDeliveryService;
import com.uten.imp.features.sales.order.SalesOrderItem;
import com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.*;

/** Frozen physical frontier below a commercial shipment line. Never posts finished-product stock. */
@Service
@RequiredArgsConstructor
@Transactional(propagation=Propagation.MANDATORY)
public class SalesShipmentDeliveryService {
    private final EntityManager em;
    private final ObjectMapper mapper;
    private final SalesOrderDeliveryService deliveries;
    private final SalesDeliveryInventoryPort inventory;
    private final WarehouseUseValidationPort warehouses;
    private final com.uten.imp.application.port.WarehouseTaskScopePort warehouseTaskScopes;
    private final org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.SalesDeliveryFulfillmentPort> productionFulfillment;

    public record Pick(@jakarta.validation.constraints.NotNull UUID componentId, UUID warehouseId,
            @jakarta.validation.constraints.Size(max=200) String stockPlace) {}
    public record ProcessingWarehouseAction(@jakarta.validation.constraints.NotNull Long expectedVersion,
            UUID warehouseId,@jakarta.validation.constraints.Size(max=200) String stockPlace,
            @jakarta.validation.constraints.NotNull UUID requestId,
            @jakarta.validation.constraints.NotBlank @jakarta.validation.constraints.Size(max=2000) String evidence) {}
    public record Component(UUID id, UUID shipmentItemId, UUID orderItemId, List<String> path,
            UUID goodsId, String goodsCode, String goodsName, UUID colorId, UUID unitId, String unitName,
            BigDecimal quantity, BigDecimal originalQuantity, List<String> operations, BigDecimal processedQty,
            String processingEvidence, long revision, UUID warehouseId, String stockPlace,
            UUID movementId, List<SalesDeliveryInventoryPort.Choice> warehouseChoices,
            OffsetDateTime processingIssuedAt,OffsetDateTime processingReceivedAt,UUID processingWorkshopId,
            List<com.uten.imp.common.delivery.DeliveryProcessingTargets.Target> processingTargets) {
        public String getQuantityExact(){return quantity.stripTrailingZeros().toPlainString();}
        public String getOriginalQuantityExact(){return originalQuantity.stripTrailingZeros().toPlainString();}
        public String getProcessedQtyExact(){return processedQty.stripTrailingZeros().toPlainString();}
    }

    public boolean isBom(UUID orderItemId) {
        if(orderItemId==null)return false;
        Number value=(Number)em.createNativeQuery("SELECT count(*) FROM sales_order_items WHERE id=:id AND (delivery_plan->>'mode'='BOM' OR COALESCE(delivery_plan->'processes','[]'::jsonb) @> '[{\"required\":true}]'::jsonb)")
                .setParameter("id",orderItemId).getSingleResult();
        return value.intValue()>0;
    }
    public Set<UUID> bomItemIds(List<SalesShipmentItem> items){
        if(items.isEmpty())return Set.of();
        Set<UUID> result=new HashSet<>();
        for(var row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
            SELECT shipment_item.id FROM sales_shipment_items shipment_item
            JOIN sales_order_items sale ON sale.id=shipment_item.order_item_id
            WHERE shipment_item.id IN(:ids) AND (sale.delivery_plan->>'mode'='BOM'
              OR COALESCE(sale.delivery_plan->'processes','[]'::jsonb) @> '[{"required":true}]'::jsonb)
            """).setParameter("ids",items.stream().map(SalesShipmentItem::getId).toList())))result.add((UUID)row[0]);
        return Set.copyOf(result);
    }

    /** Rebuild only unprocessed drafts. Stable order paths retain their own IDs and processing history. */
    public void synchronize(SalesShipment shipment,List<SalesShipmentItem> items){
        em.flush();
        requireCanRevise(shipment.getId());
        Set<UUID> retained=new HashSet<>();
        for(var line:items){
            if(line.getOrderItemId()==null)continue;
            SalesOrderItem sale=em.find(SalesOrderItem.class,line.getOrderItemId());
            deliveries.requireNoUnreviewedWork(sale);
            if(!isBom(line.getOrderItemId()))continue;
            DeliveryBom.Preview preview=deliveries.resolveOrderItem(sale,line.getQty());
            if(retained.size()+preview.items().size()>10000)throw conflict("单张出货单实际交付路径超过10000条，请分单办理，不能截断物料清单");
            var targetResolver=new com.uten.imp.common.delivery.DeliveryProcessingTargets.Resolver(preview.root(),preview.deliveryPlan());
            for(var item:preview.items()){
                String path=json(item.path());
                List<Object[]> existing=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT id,required_qty,goods_id,color_id,unit_id,required_operations,processing_completed_qty,movement_id,
                      original_required_qty,adoption_scale,adoption_rounding,processing_targets
                    FROM sales_shipment_delivery_components
                    WHERE shipment_item_id=:item AND bom_path=CAST(:path AS jsonb) FOR UPDATE
                    """).setParameter("item",line.getId()).setParameter("path",path));
                UUID id=existing.isEmpty()?UUID.randomUUID():(UUID)existing.getFirst()[0];
                String operations=json(item.operations());
                BigDecimal physical;
                Integer scale=null;String rounding=null;
                if(!existing.isEmpty()&&((BigDecimal)existing.getFirst()[8]).compareTo(item.quantity())==0){
                    physical=(BigDecimal)existing.getFirst()[1];
                    scale=existing.getFirst()[9]==null?null:((Number)existing.getFirst()[9]).intValue();rounding=(String)existing.getFirst()[10];
                }else{
                    String precisionKey="delivery.physical:"+com.uten.imp.common.util.CanonicalFingerprint.sha256(
                        List.of(sale.getGoodsId().toString(),path));
                    physical=com.uten.imp.common.finance.BusinessPrecisionContext.limit(item.quantity(),precisionKey,"实际交付数量："+item.name(),4);
                    if(physical.compareTo(item.quantity())!=0){
                        var choice=com.uten.imp.common.finance.BusinessPrecisionContext.choices().get(precisionKey);
                        if(choice==null)throw conflict("实物数量缺少明确的精度采用记录");
                        scale=choice.scale();rounding=choice.rounding();
                    }
                }
                if(physical.signum()<=0||physical.compareTo(new BigDecimal("100000000000000"))>=0)
                    throw conflict("本次散件数量超出库存账可保存范围，请核对单位和数量，不能静默舍入为零或溢出");
                var targetRows=targetResolver.resolve(item.path(),physical);
                String targets=json(targetRows);
                if(!existing.isEmpty()&&com.uten.imp.common.delivery.DeliveryProcessingTargets.fingerprint(targets(existing.getFirst()[11]))
                        .equals(com.uten.imp.common.delivery.DeliveryProcessingTargets.fingerprint(targetRows)))targets=existing.getFirst()[11].toString();
                if(!existing.isEmpty()){
                    Object[] old=existing.getFirst();
                    boolean changed=((BigDecimal)old[1]).compareTo(physical)!=0||((BigDecimal)old[8]).compareTo(item.quantity())!=0
                            ||!Objects.equals(old[2],item.goodsId())||!Objects.equals(old[3],item.path().isEmpty()?sale.getColorId():item.colorId())
                            ||!Objects.equals(old[4],item.unitId())||!sameJson(old[5],operations);
                    if(changed&&(((BigDecimal)old[6]).signum()>0||old[7]!=null))throw conflict("该散件已有加工或出货事实，不能重建数量与来源");
                    if(old[7]!=null) {retained.add(id);continue;}
                }
                em.createNativeQuery("""
                    INSERT INTO sales_shipment_delivery_components(id,shipment_id,shipment_item_id,order_item_id,bom_path,
                      bom_fingerprint,goods_id,color_id,unit_id,goods_code_snapshot,goods_name_snapshot,unit_name_snapshot,
                      required_qty,original_required_qty,adoption_scale,adoption_rounding,required_operations,processing_targets)
                    VALUES(:id,:shipment,:item,:orderItem,CAST(:path AS jsonb),:fingerprint,:goods,:color,:unit,:code,:name,:unitName,
                      :quantity,:originalQuantity,:scale,:rounding,CAST(:operations AS jsonb),CAST(:targets AS jsonb))
                    ON CONFLICT(id) DO UPDATE SET required_qty=EXCLUDED.required_qty,
                      goods_id=EXCLUDED.goods_id,color_id=EXCLUDED.color_id,unit_id=EXCLUDED.unit_id,
                      goods_code_snapshot=EXCLUDED.goods_code_snapshot,goods_name_snapshot=EXCLUDED.goods_name_snapshot,
                      unit_name_snapshot=EXCLUDED.unit_name_snapshot,required_operations=EXCLUDED.required_operations,
                      original_required_qty=EXCLUDED.original_required_qty,adoption_scale=EXCLUDED.adoption_scale,adoption_rounding=EXCLUDED.adoption_rounding,
                      processing_targets=EXCLUDED.processing_targets,
                      bom_fingerprint=EXCLUDED.bom_fingerprint,updated_at=now(),revision=sales_shipment_delivery_components.revision+1
                    """).setParameter("id",id).setParameter("shipment",shipment.getId()).setParameter("item",line.getId())
                        .setParameter("orderItem",line.getOrderItemId()).setParameter("path",path)
                        .setParameter("fingerprint",preview.bomFingerprint()).setParameter("goods",item.goodsId())
                        .setParameter("color",item.path().isEmpty()?sale.getColorId():item.colorId()).setParameter("unit",item.unitId())
                        .setParameter("code",item.code()).setParameter("name",item.name()).setParameter("unitName",item.unitName())
                        .setParameter("quantity",physical).setParameter("originalQuantity",item.quantity()).setParameter("scale",scale)
                        .setParameter("rounding",rounding).setParameter("operations",operations).setParameter("targets",targets).executeUpdate();
                retained.add(id);
            }
        }
        var all=NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT id FROM sales_shipment_delivery_components WHERE shipment_id=:id FOR UPDATE")
                .setParameter("id",shipment.getId()));
        for(var row:all)if(!retained.contains((UUID)row[0]))em.createNativeQuery("DELETE FROM sales_shipment_delivery_components WHERE id=:id")
                .setParameter("id",row[0]).executeUpdate();
    }
    public List<Component> components(UUID shipmentId, boolean includeChoices){
        return componentRows(shipmentId,includeChoices,null);
    }
    private List<Component> componentRows(UUID shipmentId,boolean includeChoices,UUID componentId){
        var choiceScope=includeChoices?warehouseTaskScopes.current(null):null;
        Map<String,List<SalesDeliveryInventoryPort.Choice>> choiceCache=new HashMap<>();
        var query=em.createNativeQuery("""
            SELECT id,shipment_item_id,order_item_id,bom_path,goods_id,goods_code_snapshot,goods_name_snapshot,
              color_id,unit_id,unit_name_snapshot,required_qty,required_operations,processing_completed_qty,
              processing_evidence,revision,warehouse_id,stock_place,movement_id,original_required_qty,
              processing_issued_at,processing_received_at,processing_workshop_id,processing_targets
            FROM sales_shipment_delivery_components WHERE shipment_id=:id
            """+(componentId==null?"":" AND id=:component")+" ORDER BY shipment_item_id,bom_path::text,id").setParameter("id",shipmentId);
        if(componentId!=null)query.setParameter("component",componentId);
        var rows=NativeQueryResults.objectArrayRows(query);
        Map<UUID,BigDecimal> own=includeChoices?inventory.ownedQuantities(rows.stream().map(r->(UUID)r[0]).toList()):Map.of();
        return rows.stream().map(r->new Component((UUID)r[0],(UUID)r[1],(UUID)r[2],strings(r[3]),(UUID)r[4],
                (String)r[5],(String)r[6],(UUID)r[7],(UUID)r[8],(String)r[9],(BigDecimal)r[10],(BigDecimal)r[18],strings(r[11]),
                (BigDecimal)r[12],(String)r[13],((Number)r[14]).longValue(),(UUID)r[15],(String)r[16],(UUID)r[17],
                includeChoices?choiceCache.computeIfAbsent(r[4]+"|"+r[7],ignored->inventory.choices((UUID)r[4],(UUID)r[7]).stream()
                    .filter(c->!choiceScope.active()||choiceScope.warehouseIds().contains(c.warehouseId())).toList()).stream()
                    .map(c->new SalesDeliveryInventoryPort.Choice(c.warehouseId(),c.warehouseName(),c.availableQty().add(
                        Objects.equals(c.warehouseId(),r[15])?own.getOrDefault((UUID)r[0],BigDecimal.ZERO):BigDecimal.ZERO))).toList():List.of(),
                timestamp(r[19]),timestamp(r[20]),(UUID)r[21],targets(r[22]))).toList();
    }
    public void post(SalesShipment shipment,List<SalesShipmentItem> parentItems,WarehouseWorkTransitionRequest request,OffsetDateTime at){
        for(var parent:parentItems)if(parent.getOrderItemId()!=null)
            deliveries.requireNoUnreviewedWork(em.find(SalesOrderItem.class,parent.getOrderItemId()));
        var rows=components(shipment.getId(),false);
        if(rows.isEmpty()){if(!bomItemIds(parentItems).isEmpty())throw conflict("散件出货清单缺失，请重新核对原出货单");return;}
        Map<UUID,Pick> picks=new HashMap<>();
        for(var p:request.getDeliveryComponents()==null?List.<Pick>of():request.getDeliveryComponents())
            if(p.componentId()==null||picks.put(p.componentId(),p)!=null)throw conflict("散件勾选重复或缺少身份");
        if(!picks.keySet().equals(rows.stream().map(Component::id).collect(java.util.stream.Collectors.toSet())))
            throw conflict("必须完整核对本单全部交付散件，不能只提交当前可见行");
        Set<UUID> actual=rows.stream().map(Component::shipmentItemId).collect(java.util.stream.Collectors.toSet());
        if(!actual.equals(bomItemIds(parentItems)))throw conflict("散件清单与原出货订单行不一致");
        Map<String,Component> frozen=new HashMap<>();
        for(var c:rows)frozen.put(c.shipmentItemId()+"|"+json(c.path()),c);
        int expected=0;
        for(var parent:parentItems)if(actual.contains(parent.getId())){
            SalesOrderItem sale=em.find(SalesOrderItem.class,parent.getOrderItemId());
            var preview=deliveries.resolveOrderItem(sale,parent.getQty());
            var targetResolver=new com.uten.imp.common.delivery.DeliveryProcessingTargets.Resolver(preview.root(),preview.deliveryPlan());
            for(var item:preview.items()){
                Component c=frozen.get(parent.getId()+"|"+json(item.path()));expected++;
                verifyFrozenComponent(c,item,sale,targetResolver);
            }
        }
        if(expected!=rows.size())throw conflict("冻结交付路径与当前方案不一致，不能遗漏或追加物料");
        List<SalesDeliveryInventoryPort.Component> posted=new ArrayList<>();
        for(var c:rows){
            if(c.movementId()!=null)throw conflict("散件已有出库事实，请核对原请求结果");
            if(!c.operations().isEmpty()&&c.processedQty().compareTo(c.quantity())!=0)throw conflict("必要加工尚未完成："+c.goodsName());
            if(!c.operations().isEmpty()&&c.processingReceivedAt()==null)throw conflict("加工实物尚未由仓库收回核对："+c.goodsName());
            Pick pick=picks.get(c.id());UUID warehouse=pick.warehouseId()==null?request.getWarehouseId():pick.warehouseId();
            if(warehouse==null)warehouse=c.warehouseId();if(warehouse==null)warehouse=shipment.getWarehouseId();
            if(warehouse==null)throw conflict("请为全部散件选择实际发出仓");
            warehouseTaskScopes.current(warehouse);
            warehouses.require(warehouse,"散件实际发出仓",WarehouseUse.GOOD_OUT);
            if(pick.stockPlace()!=null&&pick.stockPlace().length()>200)throw conflict("库位最多200字");
            em.createNativeQuery("UPDATE sales_shipment_delivery_components SET warehouse_id=:warehouse,stock_place=:place,updated_at=now() WHERE id=:id AND movement_id IS NULL")
                    .setParameter("warehouse",warehouse).setParameter("place",pick.stockPlace()).setParameter("id",c.id()).executeUpdate();
            posted.add(new SalesDeliveryInventoryPort.Component(c.id(),c.goodsId(),c.colorId(),c.unitId(),c.quantity(),warehouse));
        }
        Map<UUID,Component> byId=new HashMap<>();rows.forEach(c->byId.put(c.id(),c));
        Map<UUID,BigDecimal> rowQuantities=new HashMap<>();parentItems.forEach(p->rowQuantities.put(p.getId(),p.getQty()));
        productionFulfillment.getObject().prepare(shipment.getId(),posted.stream()
            .map(c->bridgeComponent(byId.get(c.id()),rowQuantities.get(byId.get(c.id()).shipmentItemId()),c.warehouseId())).toList());
        inventory.post(shipment.getId(),posted,at);
        productionFulfillment.getObject().complete(shipment.getId());
    }
    public void requirePosted(UUID shipmentId,Set<UUID> parentIds){
        if(parentIds.isEmpty())return;
        List<Component> rows=components(shipmentId,false);
        if(!rows.stream().map(Component::shipmentItemId).collect(java.util.stream.Collectors.toSet()).equals(parentIds)
                ||rows.stream().anyMatch(c->c.movementId()==null))throw conflict("按BOM交付必须由仓库完整核对全部散件后出库");
    }
    public void resolveCommercialWarehouses(SalesShipment shipment,List<SalesShipmentItem> items,WarehouseWorkTransitionRequest request){
        Map<UUID,Pick> picks=new HashMap<>();
        if(request.getDeliveryComponents()!=null)for(var pick:request.getDeliveryComponents())picks.put(pick.componentId(),pick);
        List<Component> components=components(shipment.getId(),false);
        Set<UUID> bom=bomItemIds(items);
        for(var item:items)if(bom.contains(item.getId())){
            UUID warehouse=null;
            for(var component:components)if(component.shipmentItemId().equals(item.getId())){
                Pick pick=picks.get(component.id());
                if(pick!=null&&pick.warehouseId()!=null){warehouse=pick.warehouseId();break;}
                if(component.warehouseId()!=null)warehouse=component.warehouseId();
            }
            if(warehouse==null)warehouse=request.getWarehouseId();
            if(warehouse==null)warehouse=shipment.getWarehouseId();
            if(warehouse!=null)item.setWarehouseId(warehouse);
        }
    }
    public void reverse(UUID shipmentId,OffsetDateTime at){inventory.reverse(shipmentId,at);productionFulfillment.getObject().reverse(shipmentId);}
    public void requireNoProcessing(UUID shipmentId){
        Number count=(Number)em.createNativeQuery("""
            SELECT count(*) FROM sales_shipment_delivery_components c WHERE c.shipment_id=:id AND c.movement_id IS NULL
              AND (c.processing_issued_at IS NOT NULL OR c.processing_started_at IS NOT NULL OR c.processing_completed_qty>0 OR EXISTS(SELECT 1 FROM stock_reservations r
                WHERE r.owner_type IN('SALES_DELIVERY_PROCESSING','SALES_DELIVERY_COMPONENT_SHIPMENT') AND r.owner_id=c.id AND r.status=0 AND NOT r.is_deleted))
            """).setParameter("id",shipmentId).getSingleResult();
        if(count.longValue()>0)throw conflict("散件已经开工或报工，请先按加工任务处理实物占用，不能撤审、删除或改写来源");
    }
    public void requireCanRevise(UUID shipmentId){
        requireNoProcessing(shipmentId);
        Number count=(Number)em.createNativeQuery("""
            SELECT count(*) FROM sales_shipment_delivery_components c WHERE c.shipment_id=:id AND (
              c.movement_id IS NOT NULL OR EXISTS(SELECT 1 FROM sales_delivery_processing_actions a WHERE a.component_id=c.id)
              OR EXISTS(SELECT 1 FROM sales_delivery_warehouse_actions a WHERE a.component_id=c.id)
              OR EXISTS(SELECT 1 FROM sales_delivery_fulfillment_groups g WHERE g.shipment_item_id=c.shipment_item_id)
              OR EXISTS(SELECT 1 FROM sales_delivery_order_claims claim WHERE claim.component_id=c.id))
            """).setParameter("id",shipmentId).getSingleResult();
        if(count.longValue()>0)throw conflict("本单已有交付派工或实物交接历史，请先退回未加工实物并取消本单，再新建出货单，保留原来源证据");
    }
    /** Terminal draft cancellation retains immutable component/handover history. */
    public void cancelPrepared(UUID shipmentId){
        requireNoProcessing(shipmentId);
        productionFulfillment.getObject().cancelPreparedShipment(shipmentId);
    }
    public Component warehouseProcessing(UUID shipmentId,UUID componentId,String action,ProcessingWarehouseAction request,UUID actor){
        String hash=com.uten.imp.common.util.CanonicalFingerprint.sha256(List.of(shipmentId.toString(),componentId.toString(),action,json(request)));
        var prior=NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT component_id,action_type,request_hash,actor_employee_id FROM sales_delivery_warehouse_actions WHERE request_id=:id")
                .setParameter("id",request.requestId()));
        if(!prior.isEmpty()){
            var p=prior.getFirst();if(!Objects.equals(p[0],componentId)||!Objects.equals(p[1],action)||!Objects.equals(p[2],hash)||!Objects.equals(p[3],actor))
                throw conflict("同一仓库操作编号已用于不同内容，请先核对原请求");
            return component(shipmentId,componentId);
        }
        var locked=NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT id,processing_started_at FROM sales_shipment_delivery_components WHERE id=:id AND shipment_id=:shipment FOR UPDATE")
                .setParameter("id",componentId).setParameter("shipment",shipmentId));
        if(locked.size()!=1)throw conflict("该散件不属于当前仓库任务");
        var c=component(shipmentId,componentId);
        if(c.revision()!=request.expectedVersion()||c.movementId()!=null)throw conflict("散件任务版本已变化，请刷新核对后办理");
        if(c.operations().isEmpty())throw conflict("该交付件没有待加工工序");
        UUID warehouse=request.warehouseId()==null?c.warehouseId():request.warehouseId();
        if(warehouse==null)throw conflict("请先选择实际发出加工的来源仓");
        warehouseTaskScopes.current(warehouse);warehouses.require(warehouse,"加工实物来源仓",WarehouseUse.GOOD_OUT);
        String update;
        if("ISSUE".equals(action)){
            if(c.processingIssuedAt()!=null||c.processingWorkshopId()==null)throw conflict("请先派工；已发至加工的实物不能重复发出");
            var parent=em.find(SalesShipmentItem.class,c.shipmentItemId());
            var sale=em.find(SalesOrderItem.class,c.orderItemId());
            var preview=deliveries.resolveOrderItem(sale,parent.getQty());
            var current=preview.items().stream().filter(i->json(i.path()).equals(json(c.path()))).findFirst()
                    .orElseThrow(()->conflict("原交付路径已变化，请先核对备货来源"));
            verifyFrozenComponent(c,current,sale,new com.uten.imp.common.delivery.DeliveryProcessingTargets.Resolver(preview.root(),preview.deliveryPlan()));
            productionFulfillment.getObject().prepare(shipmentId,List.of(bridgeComponent(shipmentId,
                new SalesDeliveryInventoryPort.Component(c.id(),c.goodsId(),c.colorId(),c.unitId(),c.quantity(),warehouse))));
            inventory.reserveForProcessing(c.id(),warehouse,c.goodsId(),c.colorId(),c.unitId(),c.quantity(),request.requestId());
            update="processing_issued_at=now(),processing_issued_by=:actor,stock_place=:place";
        }else if("RECEIVE".equals(action)){
            if(c.processingIssuedAt()==null||c.processingReceivedAt()!=null||c.processedQty().compareTo(c.quantity())!=0)
                throw conflict("必须有完整加工报工与原发出实物，才能收回仓库");
            if(!Objects.equals(warehouse,c.warehouseId()))throw conflict("加工收回必须对应原实物来源仓");
            inventory.requireProcessingReservation(c.id(),warehouse,c.goodsId(),c.colorId(),c.quantity());
            update="processing_received_at=now(),processing_received_by=:actor,stock_place=:place";
        }else if("CANCEL_ISSUE".equals(action)){
            if(c.processingIssuedAt()==null||c.processedQty().signum()!=0||locked.getFirst()[1]!=null)
                throw conflict("请先撤销未报工开工，再按实际退回实物取消加工发出");
            if(!Objects.equals(warehouse,c.warehouseId()))throw conflict("退回的加工实物必须对应原来源仓");
            inventory.releaseProcessing(c.id());
            productionFulfillment.getObject().cancelPreparedComponent(c.id());
            update="processing_issued_at=NULL,processing_issued_by=NULL,stock_place=:place";
        }else throw conflict("未知仓库加工动作");
        var command=em.createNativeQuery("UPDATE sales_shipment_delivery_components SET "+update+",revision=revision+1,updated_at=now() WHERE id=:id AND revision=:version")
                .setParameter("id",componentId).setParameter("version",request.expectedVersion()).setParameter("place",request.stockPlace());
        if(!"CANCEL_ISSUE".equals(action))command.setParameter("actor",actor);
        if(command.executeUpdate()!=1)throw conflict("散件办理状态已变化，本次未提交");
        em.createNativeQuery("""
                INSERT INTO sales_delivery_warehouse_actions(request_id,shipment_id,component_id,action_type,
                    workshop_id,responsible_id,request_hash,evidence,actor_employee_id)
                SELECT :request,:shipment,id,:action,processing_workshop_id,processing_responsible_id,:hash,:evidence,:actor
                FROM sales_shipment_delivery_components WHERE id=:component AND shipment_id=:shipment
                """)
                .setParameter("request",request.requestId()).setParameter("shipment",shipmentId).setParameter("component",componentId)
                .setParameter("action",action).setParameter("hash",hash).setParameter("evidence",request.evidence()).setParameter("actor",actor).executeUpdate();
        return component(shipmentId,componentId);
    }
    private Component component(UUID shipment,UUID id){return componentRows(shipment,true,id).stream().findFirst().orElseThrow(()->conflict("散件来源不存在"));}
    public void requirePickingWarehouseScope(List<SalesShipmentItem> items,WarehouseWorkTransitionRequest request){
        if(bomItemIds(items).isEmpty())return;
        if(request.getWarehouseId()!=null)warehouseTaskScopes.current(request.getWarehouseId());
        if(request.getDeliveryComponents()!=null)for(var pick:request.getDeliveryComponents())
            if(pick.warehouseId()!=null)warehouseTaskScopes.current(pick.warehouseId());
    }
    private com.uten.imp.application.port.SalesDeliveryFulfillmentPort.Component bridgeComponent(UUID shipmentId,SalesDeliveryInventoryPort.Component physical){
        var c=component(shipmentId,physical.id());
        BigDecimal qty=(BigDecimal)em.createNativeQuery("SELECT qty FROM sales_shipment_items WHERE id=:id AND shipment_id=:shipment AND NOT is_deleted")
                .setParameter("id",c.shipmentItemId()).setParameter("shipment",shipmentId).getSingleResult();
        return bridgeComponent(c,qty,physical.warehouseId());
    }
    private com.uten.imp.application.port.SalesDeliveryFulfillmentPort.Component bridgeComponent(Component c,BigDecimal qty,UUID warehouse){
        return new com.uten.imp.application.port.SalesDeliveryFulfillmentPort.Component(c.id(),c.shipmentItemId(),c.orderItemId(),
            c.path().stream().map(UUID::fromString).toList(),c.goodsId(),c.colorId(),c.unitId(),c.quantity(),warehouse,qty);
    }
    private static void verifyFrozenComponent(Component c,DeliveryBom.Item item,SalesOrderItem sale,com.uten.imp.common.delivery.DeliveryProcessingTargets.Resolver targets){
        UUID color=item.path().isEmpty()?sale.getColorId():item.colorId();
        if(c==null||!Objects.equals(c.goodsId(),item.goodsId())||!Objects.equals(c.colorId(),color)
                ||!Objects.equals(c.unitId(),item.unitId())||c.originalQuantity().compareTo(item.quantity())!=0
                ||!new TreeSet<>(c.operations()).equals(item.operations().stream().map(Enum::name)
                    .collect(java.util.stream.Collectors.toCollection(TreeSet::new))))
            throw conflict("原BOM、交付数量或必要工序已变化，请先重新核对备货清单");
        var required=targets.resolve(item.path(),c.quantity());
        if(!com.uten.imp.common.delivery.DeliveryProcessingTargets.fingerprint(required)
                .equals(com.uten.imp.common.delivery.DeliveryProcessingTargets.fingerprint(c.processingTargets())))
            throw conflict("必要工序的实际对象或用量已变化，请先重新核对原交付清单");
    }
    private List<com.uten.imp.common.delivery.DeliveryProcessingTargets.Target> targets(Object value){
        try{return mapper.readValue(value.toString(),mapper.getTypeFactory().constructCollectionType(List.class,com.uten.imp.common.delivery.DeliveryProcessingTargets.Target.class));}
        catch(JsonProcessingException e){throw conflict("加工对象快照格式不完整，请保留原单核对");}
    }
    public Map<String,Object> warehouseRequestOutcome(UUID shipmentId,UUID requestId){
        var found=NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT component_id,action_type,request_hash FROM sales_delivery_warehouse_actions WHERE shipment_id=:shipment AND request_id=:request")
                .setParameter("shipment",shipmentId).setParameter("request",requestId));
        if(found.isEmpty())return Map.of("found",false);
        return Map.of("found",true,"componentId",found.getFirst()[0],"action",found.getFirst()[1],"requestHash",found.getFirst()[2]);
    }
    private static OffsetDateTime timestamp(Object value){return value==null?null:com.uten.imp.common.util.NativeValueConverters.toOffsetDateTime(value);}
    private List<String> strings(Object value){try{return mapper.readValue(value.toString(),mapper.getTypeFactory().constructCollectionType(List.class,String.class));}
        catch(JsonProcessingException e){throw conflict("交付清单快照格式损坏，请保留原单核对");}}
    private boolean sameJson(Object old,String json){try{return mapper.readTree(old.toString()).equals(mapper.readTree(json));}
        catch(JsonProcessingException e){return false;}}
    private String json(Object value){try{return mapper.writeValueAsString(value);}catch(JsonProcessingException e){throw new IllegalArgumentException(e);}}
    private static ApiException conflict(String value){return new ApiException(ErrorCode.CONFLICT,value);}
}
