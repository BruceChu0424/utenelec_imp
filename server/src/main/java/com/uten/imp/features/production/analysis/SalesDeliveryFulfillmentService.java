package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.port.ProductionMutationFootprintPort;
import com.uten.imp.application.port.SalesDeliveryFulfillmentPort;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/** Exact source-order/path handoff, separate from manufacturing output and commercial quantities. */
@Service
@RequiredArgsConstructor
@Transactional(propagation=Propagation.MANDATORY)
public class SalesDeliveryFulfillmentService implements SalesDeliveryFulfillmentPort {
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ProductionMutationFootprintPort productionFootprints;
    private final FulfillmentMutationLocks mutationLocks;
    private final PreplanStockEntitlementService entitlements;
    private final MaterialAnalysisService analysis;
    private final ObjectMapper mapper;

    @Override @Transactional(propagation=Propagation.MANDATORY,readOnly=true)
    public FulfillmentMutationLockPlan discover(Collection<UUID> orderItemIds,Collection<UUID> shipmentIds) {
        Set<UUID> items=new LinkedHashSet<>(orderItemIds==null?List.of():orderItemIds);
        List<UUID> documents=ids(shipmentIds);
        List<String> versions=new ArrayList<>();
        Set<UUID> analyses=new LinkedHashSet<>();
        if(!documents.isEmpty())for(Object[] row:rows("""
                SELECT kit.shipment_item_id,kit.order_item_id,kit.xmin::text,allocation.id,
                    allocation.analysis_id,allocation.xmin::text
                FROM sales_delivery_fulfillment_groups kit
                LEFT JOIN sales_delivery_fulfillment_allocations allocation ON allocation.shipment_item_id=kit.shipment_item_id
                WHERE kit.shipment_id IN(:ids) ORDER BY kit.shipment_item_id,allocation.id
                ""","ids",documents)) {
            versions.add(java.util.Arrays.toString(row));items.add((UUID)row[1]);if(row[4]!=null)analyses.add((UUID)row[4]);
        }
        if(!items.isEmpty())for(Object[] row:rows("""
                SELECT source.id,source.analysis_id,source.xmin::text,header.xmin::text
                FROM production_material_analysis_items source
                JOIN production_material_analyses header ON header.id=source.analysis_id
                WHERE source.sales_order_item_id IN(:ids) AND source.delivery_plan_snapshot->>'mode'='BOM'
                ORDER BY source.id
                ""","ids",ids(items))) {
            versions.add(java.util.Arrays.toString(row));analyses.add((UUID)row[1]);
        }
        var dependencies=productionFootprints.forAnalyses(analyses);
        versions.add(dependencies.fingerprint());
        return new FulfillmentMutationLockPlan(dependencies.commercialSources(),dependencies.inventoryDimensions(),
                dependencies.mainWarehouseIds(),dependencies.analysisIds(),CanonicalFingerprint.sha256(versions));
    }

    @Override public void prepare(UUID shipmentId,List<Component> components) {
        tx.bind();
        for(Component component:components) {
            // Whole-product processing retains its original order reservation and
            // uses the sales-owned reservation-claim adapter, not a BOM-kit source.
            if(component.path().isEmpty())continue;
            Object[] identity=validateComponent(shipmentId,component);
            ensureKit(shipmentId,component,(String)identity[0]);
            List<Object[]> allocations=allocations(component.shipmentItemId());
            mutationLocks.requireAnalysesCovered(allocations.stream().map(r->(UUID)r[1]).toList());
            BigDecimal preceding=BigDecimal.ZERO;
            for(Object[] allocation:allocations) {
                BigDecimal end=preceding.add(decimal(allocation[3]));
                BigDecimal capacity=proportionalSlice(component.quantity(),preceding,end,component.orderRowQty());
                preceding=end;
                BigDecimal already=decimal(em.createNativeQuery("""
                        SELECT COALESCE(sum(handoff.quantity),0) FROM sales_delivery_entitlement_handoffs handoff
                        WHERE handoff.component_id=:component AND handoff.allocation_id=:allocation
                          AND NOT EXISTS(SELECT 1 FROM sales_delivery_entitlement_restores restored WHERE restored.handoff_id=handoff.id)
                        """).setParameter("component",component.componentId()).setParameter("allocation",allocation[0]).getSingleResult());
                BigDecimal left=capacity.subtract(already).max(BigDecimal.ZERO);
                if(left.signum()==0)continue;
                var material=rows("""
                        SELECT id FROM production_material_analysis_materials
                        WHERE analysis_id=:analysis AND analysis_item_id=:source AND node_key=:path
                          AND delivery_frontier AND NOT delivery_context AND goods_id=:goods
                          AND color_id IS NOT DISTINCT FROM CAST(:color AS uuid) AND unit_id=:unit
                        FOR UPDATE
                        """,q->q.setParameter("analysis",allocation[1]).setParameter("source",allocation[2])
                        .setParameter("path",path(component.path())).setParameter("goods",component.goodsId())
                        .setParameter("color",component.colorId()).setParameter("unit",component.unitId()));
                if(material.size()!=1)throw conflict("原分析的交付物料路径已变化，不能转交私有到货");
                UUID materialId=(UUID)material.getFirst()[0];
                for(var lot:entitlements.listAvailableBeneficiaryLotsForProduction((UUID)allocation[1],materialId,
                        component.warehouseId(),component.goodsId(),component.colorId(),true)) {
                    if(left.signum()==0)break;
                    if(!Objects.equals(lot.warehouseId(),component.warehouseId()))continue;
                    if(!Boolean.TRUE.equals(em.createNativeQuery("SELECT fn_preplan_reservation_has_qualified_origin(:id)")
                            .setParameter("id",lot.stockReservationId()).getSingleResult()))continue;
                    BigDecimal take=left.min(lot.remainingQty());if(take.signum()==0)continue;
                    handoff(component,(UUID)allocation[0],materialId,lot,take,null);
                    left=left.subtract(take);
                }
                if(left.signum()>0)for(Object[] alias:rows("""
                        SELECT alias.id,target.id,target.analysis_id,
                            GREATEST(fn_preplan_aggregate_alias_qty(alias.id)-COALESCE((SELECT sum(prior.quantity)
                               FROM sales_delivery_entitlement_handoffs prior WHERE prior.aggregate_alias_id=alias.id
                                 AND NOT EXISTS(SELECT 1 FROM sales_delivery_entitlement_restores restored WHERE restored.handoff_id=prior.id)),0),0)
                        FROM preplan_aggregate_material_aliases alias
                        JOIN production_material_analysis_materials target ON target.id=alias.aggregate_material_id
                        WHERE alias.source_material_id=:id AND fn_preplan_aggregate_alias_valid(alias.id)
                        ORDER BY alias.created_at,alias.id
                        ""","id",materialId)) {
                    mutationLocks.requireAnalysesCovered(List.of((UUID)alias[2]));
                    BigDecimal aliasLeft=left.min(decimal(alias[3]));
                    for(var lot:entitlements.listAvailableBeneficiaryLotsForProduction((UUID)alias[2],(UUID)alias[1],
                            component.warehouseId(),component.goodsId(),component.colorId(),true)) {
                        if(aliasLeft.signum()==0)break;
                        if(!Objects.equals(lot.warehouseId(),component.warehouseId())
                                ||!Boolean.TRUE.equals(em.createNativeQuery("SELECT fn_preplan_reservation_has_qualified_origin(:id)")
                                  .setParameter("id",lot.stockReservationId()).getSingleResult()))continue;
                        BigDecimal take=aliasLeft.min(lot.remainingQty());if(take.signum()==0)continue;
                        handoff(component,(UUID)allocation[0],materialId,lot,take,(UUID)alias[0]);
                        aliasLeft=aliasLeft.subtract(take);left=left.subtract(take);
                    }
                    if(left.signum()==0)break;
                }
            }
        }
    }

    private Object[] validateComponent(UUID shipmentId,Component c) {
        List<Object[]> found=rows("""
                SELECT component.bom_fingerprint,component.shipment_item_id,component.order_item_id,
                    component.goods_id,component.color_id,component.unit_id,component.required_qty,
                    component.bom_path::text,item.qty,component.warehouse_id,component.movement_id
                FROM sales_shipment_delivery_components component JOIN sales_shipment_items item ON item.id=component.shipment_item_id
                WHERE component.id=:id AND component.shipment_id=:shipment AND NOT item.is_deleted FOR UPDATE OF component
                """,q->q.setParameter("id",c.componentId()).setParameter("shipment",shipmentId));
        if(found.size()!=1||c.warehouseId()==null)throw conflict("散件交付实物来源不完整");
        Object[] row=found.getFirst();
        if(!Objects.equals(row[1],c.shipmentItemId())||!Objects.equals(row[2],c.orderItemId())
                ||!Objects.equals(row[3],c.goodsId())||!Objects.equals(row[4],c.colorId())||!Objects.equals(row[5],c.unitId())
                ||decimal(row[6]).compareTo(c.quantity())!=0||decimal(row[8]).compareTo(c.orderRowQty())!=0
                ||!jsonPathsEqual(row[7],c.path())||row[10]!=null)
            throw conflict("散件实物与冻结订单路径、数量或单位不一致");
        if(row[9]!=null&&!Objects.equals(row[9],c.warehouseId())) {
            var held=rows("SELECT id FROM stock_reservations WHERE owner_id=:id AND owner_type IN('SALES_DELIVERY_COMPONENT_SHIPMENT','SALES_DELIVERY_PROCESSING') AND status=0 AND NOT is_deleted","id",c.componentId());
            if(!held.isEmpty())throw conflict("散件已有实际占用，不能更换来源仓");
        }
        em.createNativeQuery("UPDATE sales_shipment_delivery_components SET warehouse_id=:warehouse WHERE id=:id")
                .setParameter("warehouse",c.warehouseId()).setParameter("id",c.componentId()).executeUpdate();
        return row;
    }

    private void ensureKit(UUID shipmentId,Component c,String fingerprint) {
        var existing=rows("SELECT order_qty,state,order_item_id FROM sales_delivery_fulfillment_groups WHERE shipment_item_id=:id FOR UPDATE","id",c.shipmentItemId());
        if(!existing.isEmpty()) {
            Object[] group=existing.getFirst();
            if(decimal(group[0]).compareTo(c.orderRowQty())!=0||!Objects.equals(group[2],c.orderItemId())||!"PREPARED".equals(group[1]))
                throw conflict("该散件套数已有冻结来源分配，请按原单据受控回退后另建");
            return;
        }
        var sources=rows("""
                SELECT source.id,source.analysis_id,
                    GREATEST(source.requested_qty-source.submitted_qty-source.approved_qty-source.root_fulfilled_qty-
                      COALESCE((SELECT sum(allocation.order_qty) FROM sales_delivery_fulfillment_allocations allocation
                        JOIN sales_delivery_fulfillment_groups kit ON kit.shipment_item_id=allocation.shipment_item_id
                        WHERE allocation.analysis_item_id=source.id AND kit.state='PREPARED'),0),0)
                FROM production_material_analysis_items source JOIN production_material_analyses header ON header.id=source.analysis_id
                WHERE source.sales_order_item_id=:id AND NOT source.is_deleted AND NOT header.is_deleted AND header.status<>'CANCELLED'
                  AND source.source_type='SALES_ORDER_ITEM' AND source.delivery_plan_snapshot->>'mode'='BOM'
                  AND source.delivery_plan_snapshot->>'bomFingerprint'=:fingerprint
                ORDER BY header.analyzed_at,source.created_at,source.id FOR UPDATE OF source
                """,q->q.setParameter("id",c.orderItemId()).setParameter("fingerprint",fingerprint));
        mutationLocks.requireAnalysesCovered(sources.stream().map(r->(UUID)r[1]).toList());
        em.createNativeQuery("""
                INSERT INTO sales_delivery_fulfillment_groups(shipment_item_id,shipment_id,order_item_id,order_qty,state,created_by)
                VALUES(:item,:shipment,:orderItem,:qty,'PREPARED',:actor)
                """).setParameter("item",c.shipmentItemId()).setParameter("shipment",shipmentId).setParameter("orderItem",c.orderItemId())
                .setParameter("qty",c.orderRowQty()).setParameter("actor",currentUser.requireId()).executeUpdate();
        BigDecimal left=c.orderRowQty();int position=0;
        for(Object[] source:sources) {
            BigDecimal take=left.min(decimal(source[2]));if(take.signum()==0)continue;
            em.createNativeQuery("""
                    INSERT INTO sales_delivery_fulfillment_allocations(shipment_item_id,analysis_id,analysis_item_id,position,order_qty,created_by)
                    VALUES(:item,:analysis,:source,:position,:qty,:actor)
                    """).setParameter("item",c.shipmentItemId()).setParameter("analysis",source[1]).setParameter("source",source[0])
                    .setParameter("position",position++).setParameter("qty",take).setParameter("actor",currentUser.requireId()).executeUpdate();
            left=left.subtract(take);if(left.signum()==0)break;
        }
        // Unanalysed sales units are physically fulfilled from proven public stock;
        // they do not acquire an invented analysis or another order's entitlement.
    }

    static BigDecimal proportionalSlice(BigDecimal total,BigDecimal begin,BigDecimal end,BigDecimal rootQty) {
        if(rootQty.signum()<=0||begin.signum()<0||end.compareTo(begin)<0||end.compareTo(rootQty)>0)throw conflict("交付套数分配不正确");
        if(total.stripTrailingZeros().scale()>4)throw conflict("实际交付数量尚未按库存精度确认，不能分配私有实物");
        // These are ownership quotas, not recalculated customer quantities. Cumulative
        // four-place stock quanta preserve the already accepted physical total exactly;
        // a terminal slice receives the frozen total's tail, and each actual handoff is
        // additionally capped by that source node's proven remaining qualified lot.
        return total.multiply(end).divide(rootQty,4,RoundingMode.DOWN)
                .subtract(total.multiply(begin).divide(rootQty,4,RoundingMode.DOWN));
    }

    private void handoff(Component c,UUID allocationId,UUID materialId,PreplanStockEntitlementService.AvailableLot lot,BigDecimal qty,UUID aliasId) {
        UUID target=UUID.randomUUID(),id=UUID.randomUUID();String key="DELIVERY:"+id;
        UUID release=entitlements.appendReleaseLot(id,lot,qty,lot.reallocationId(),key+":RELEASE");
        entitlements.consumePhysicalForFormalize(lot.stockReservationId(),qty);
        int inserted=em.createNativeQuery("""
                INSERT INTO stock_reservations(id,owner_type,owner_id,purpose,goods_id,color_id,warehouse_id,qty,
                    consumed_qty,released_qty,status,source,source_doc_type,source_doc_id,supply_type,supply_id,idempotency_key)
                SELECT :id,'SALES_DELIVERY_COMPONENT_SHIPMENT',component.id,'SALES_DELIVERY_COMPONENT_SHIPMENT',
                    component.goods_id,component.color_id,:warehouse,:qty,0,0,0,0,'SALES_SHIPMENT',component.shipment_id,
                    'STOCK_BALANCE',balance.id,:key
                FROM sales_shipment_delivery_components component JOIN v_stock_operable_balances balance
                    ON balance.goods_id=component.goods_id AND balance.color_id IS NOT DISTINCT FROM component.color_id AND balance.warehouse_id=:warehouse
                WHERE component.id=:component AND fn_warehouse_is_good_stock_leaf(balance.warehouse_id)
                """).setParameter("id",target).setParameter("warehouse",c.warehouseId()).setParameter("qty",qty)
                .setParameter("key",key).setParameter("component",c.componentId()).executeUpdate();
        if(inserted!=1)throw conflict("私有到货的实际良品仓来源已变化");
        em.createNativeQuery("""
                INSERT INTO sales_delivery_entitlement_handoffs(id,component_id,allocation_id,source_analysis_id,source_material_id,
                    entitlement_analysis_id,entitlement_material_id,aggregate_alias_id,
                    source_entitlement_event_id,source_reservation_id,target_reservation_id,release_event_id,quantity,created_by)
                VALUES(:id,:component,:allocation,:analysis,:material,:entitlementAnalysis,:entitlementMaterial,:alias,:origin,:source,:target,:release,:qty,:actor)
                """).setParameter("id",id).setParameter("component",c.componentId()).setParameter("allocation",allocationId)
                .setParameter("analysis",lot.beneficiaryAnalysisId()).setParameter("material",materialId).setParameter("origin",lot.entitlementEventId())
                .setParameter("entitlementAnalysis",lot.beneficiaryAnalysisId()).setParameter("entitlementMaterial",lot.beneficiaryAnalysisMaterialId()).setParameter("alias",aliasId)
                .setParameter("source",lot.stockReservationId()).setParameter("target",target).setParameter("release",release)
                .setParameter("qty",qty).setParameter("actor",currentUser.requireId()).executeUpdate();
    }

    @Override public void complete(UUID shipmentId) { projectFulfillment(shipmentId,false); }
    @Override public void reverse(UUID shipmentId) {
        tx.bind();
        restoreHandoffs("component.shipment_id=:id",shipmentId,"REVERSE");
        projectFulfillment(shipmentId,true);
    }
    private void projectFulfillment(UUID shipmentId,boolean reverse) {
        tx.bind();Set<UUID> changed=new LinkedHashSet<>();
        for(Object[] group:rows("SELECT shipment_item_id,state FROM sales_delivery_fulfillment_groups WHERE shipment_id=:id ORDER BY shipment_item_id FOR UPDATE","id",shipmentId)) {
            String state=(String)group[1];if(reverse?"REVERSED".equals(state):"COMPLETED".equals(state))continue;
            if(reverse?!"COMPLETED".equals(state):!"PREPARED".equals(state))throw conflict("交付来源的履约状态不正确");
            String missing=reverse?"reversal_movement_id IS NULL":"movement_id IS NULL OR reversal_movement_id IS NOT NULL";
            if(!rows("SELECT id FROM sales_shipment_delivery_components WHERE shipment_item_id=:id AND ("+missing+")","id",group[0]).isEmpty())
                throw conflict("交付件的实际出库或反向尚未全部完成，不能回写套数履约");
            List<Object[]> allocations=allocations((UUID)group[0]);mutationLocks.requireAnalysesCovered(allocations.stream().map(r->(UUID)r[1]).toList());
            for(Object[] allocation:allocations) {
                UUID counter=null;
                if(reverse)counter=(UUID)em.createNativeQuery("SELECT id FROM sales_delivery_fulfillment_events WHERE allocation_id=:id AND event_type='FULFILL'")
                        .setParameter("id",allocation[0]).getSingleResult();
                em.createNativeQuery("INSERT INTO sales_delivery_fulfillment_events(allocation_id,event_type,order_qty,counter_event_id,created_by) VALUES(:allocation,:type,:qty,:counter,:actor)")
                        .setParameter("allocation",allocation[0]).setParameter("type",reverse?"REVERSE":"FULFILL").setParameter("qty",allocation[3])
                        .setParameter("counter",counter).setParameter("actor",currentUser.requireId()).executeUpdate();
                changed.add((UUID)allocation[1]);
            }
            em.createNativeQuery("UPDATE sales_delivery_fulfillment_groups SET state=:state,updated_at=now() WHERE shipment_item_id=:id")
                    .setParameter("state",reverse?"REVERSED":"COMPLETED").setParameter("id",group[0]).executeUpdate();
        }
        for(UUID id:ids(changed))analysis.refreshFrozenForDelivery(id);
    }
    @Override public void cancelPreparedComponent(UUID componentId) {tx.bind();restoreHandoffs("component.id=:id",componentId,"CANCEL_ISSUE");}
    @Override public void cancelPreparedShipment(UUID shipmentId) {
        tx.bind();restoreHandoffs("component.shipment_id=:id",shipmentId,"CANCEL_ISSUE");
        if(!rows("SELECT shipment_item_id FROM sales_delivery_fulfillment_groups WHERE shipment_id=:id AND state='COMPLETED'","id",shipmentId).isEmpty())
            throw conflict("已出货履约只能按原单据红冲");
        em.createNativeQuery("UPDATE sales_delivery_fulfillment_groups SET state='CANCELLED',updated_at=now() WHERE shipment_id=:id AND state='PREPARED'")
                .setParameter("id",shipmentId).executeUpdate();
    }
    private void restoreHandoffs(String condition,UUID id,String reason) {
        for(Object[] handoff:rows("""
                SELECT handoff.id,handoff.entitlement_analysis_id,handoff.entitlement_material_id,handoff.source_reservation_id,
                    handoff.target_reservation_id,handoff.release_event_id,handoff.quantity,origin.reallocation_id,origin.source_exact_peg_id,
                    component.movement_id,component.reversal_movement_id,component.processing_completed_qty,component.processing_started_at
                FROM sales_delivery_entitlement_handoffs handoff
                JOIN sales_shipment_delivery_components component ON component.id=handoff.component_id
                JOIN preplan_stock_entitlement_events origin ON origin.id=handoff.source_entitlement_event_id
                WHERE %s AND NOT EXISTS(SELECT 1 FROM sales_delivery_entitlement_restores restored WHERE restored.handoff_id=handoff.id)
                ORDER BY handoff.source_reservation_id,handoff.id FOR UPDATE OF component
                """.formatted(condition),"id",id)) {
            mutationLocks.requireAnalysesCovered(List.of((UUID)handoff[1]));
            if("REVERSE".equals(reason)?handoff[10]==null:handoff[9]!=null||decimal(handoff[11]).signum()>0||handoff[12]!=null)
                throw conflict("私有加工或发货实物尚未按原来源退回，不能释放权益");
            if("CANCEL_ISSUE".equals(reason)) {
                int released=em.createNativeQuery("UPDATE stock_reservations SET released_qty=qty,status=1,updated_at=now() WHERE id=:id AND consumed_qty=0 AND status=0 AND NOT is_deleted")
                        .setParameter("id",handoff[4]).executeUpdate();
                if(released!=1)throw conflict("私有散件占用已被使用，不能直接归还");
            }
            entitlements.restorePhysicalAfterFormalRelease((UUID)handoff[3],decimal(handoff[6]));
            UUID restored=entitlements.appendRestoreFromCounter(UUID.randomUUID(),(UUID)handoff[3],(UUID)handoff[5],
                    (UUID)handoff[1],(UUID)handoff[2],decimal(handoff[6]),(UUID)handoff[7],(UUID)handoff[8],"DELIVERY-RESTORE:"+handoff[0]);
            em.createNativeQuery("INSERT INTO sales_delivery_entitlement_restores(handoff_id,restore_event_id,reason,created_by) VALUES(:id,:event,:reason,:actor)")
                    .setParameter("id",handoff[0]).setParameter("event",restored).setParameter("reason",reason).setParameter("actor",currentUser.requireId()).executeUpdate();
        }
    }
    private List<Object[]> allocations(UUID itemId) {
        return rows("SELECT id,analysis_id,analysis_item_id,order_qty FROM sales_delivery_fulfillment_allocations WHERE shipment_item_id=:id ORDER BY position,id","id",itemId);
    }
    private boolean jsonPathsEqual(Object json,List<UUID> paths) {try{return mapper.readTree(json.toString()).equals(mapper.valueToTree(paths));}catch(Exception ex){throw conflict("冻结BOM路径不正确");}}
    private static String path(List<UUID> ids){return ids.stream().map(UUID::toString).collect(java.util.stream.Collectors.joining("/"));}
    private List<Object[]> rows(String sql,String name,Object value){return rows(sql,q->q.setParameter(name,value));}
    private List<Object[]> rows(String sql,java.util.function.Consumer<jakarta.persistence.Query> bind){var query=em.createNativeQuery(sql);bind.accept(query);return NativeQueryResults.objectArrayRows(query);}
    private static List<UUID> ids(Collection<UUID> ids){return ids==null?List.of():ids.stream().filter(Objects::nonNull).distinct().sorted(Comparator.comparing(UUID::toString)).toList();}
    private static BigDecimal decimal(Object value){return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
