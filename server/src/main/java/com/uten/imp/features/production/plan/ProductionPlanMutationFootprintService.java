package com.uten.imp.features.production.plan;

import com.uten.imp.application.concurrency.FulfillmentDiscoveryRound;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialSource;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialType;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.port.ProductionMutationFootprintPort;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * Directed plan and generated-child footprint. Does not infer responsibility from open PO totals.
 *
 * <p>ADR-107: 行快照只取 {@code (id, xmin)}; 事务已持有完整预锁时(例如一次下达里逐张建计划),
 * 不再为每张计划重跑发现, 只在内存里确认请求行的库存维度已在预锁集合内。</p>
 */
@Service
@RequiredArgsConstructor
@Transactional(propagation = Propagation.MANDATORY)
public class ProductionPlanMutationFootprintService {
    private final EntityManager em;
    private final FulfillmentMutationLocks locks;
    private final ProductionMutationFootprintPort production;

    public record RequestedLine(UUID goodsId, UUID colorId, UUID salesOrderItemId) {}

    public void lockPlan(UUID id, Collection<RequestedLine> requested) {
        beginPlan(id, requested).verifyUnchanged();
    }

    /** Same-key immutable replays may return after row locking; every new write must verify first. */
    public FulfillmentMutationLocks.Guard beginPlan(UUID id, Collection<RequestedLine> requested) {
        List<UUID> ids=id==null?List.of():List.of(id);
        List<RequestedLine> lines=requested==null?List.of():List.copyOf(requested);
        var declared=FulfillmentMutationLockPlan.declared(Set.of(),lines.stream().filter(line->line.goodsId()!=null)
                .map(line->new InventoryDimension(line.goodsId(),line.colorId())).toList(),Set.of());
        var guard=locks.acquire(declared,() -> discoverPlans(ids,lines));
        if(!ids.isEmpty()) {
            List<?> found=em.createNativeQuery("SELECT id FROM production_plans WHERE id IN (:ids) ORDER BY id FOR UPDATE")
                    .setParameter("ids",ids).getResultList();
            if(found.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"生产计划不存在");
        }
        return guard;
    }

    /**
     * 多张计划共用一次预锁(V595：车间动作要就地出库线边仓领料单时的前置)：足迹取各计划家族之并，
     * 计划行按 UUID 序上锁。必须在任何库存维度锁之前调用。
     */
    public FulfillmentMutationLocks.Guard beginPlans(Collection<UUID> planIds) {
        List<UUID> ids=planIds==null?List.of():planIds.stream().filter(java.util.Objects::nonNull)
                .distinct().sorted(java.util.Comparator.comparing(UUID::toString)).toList();
        var guard=locks.acquire(() -> discoverPlans(ids,List.of()));
        if(!ids.isEmpty()) {
            List<?> found=em.createNativeQuery("SELECT id FROM production_plans WHERE id IN (:ids) ORDER BY id FOR UPDATE")
                    .setParameter("ids",ids).getResultList();
            if(found.size()!=ids.size())throw new ApiException(ErrorCode.NOT_FOUND,"生产计划不存在");
        }
        return guard;
    }

    public FulfillmentMutationLockPlan discover(UUID id, Collection<RequestedLine> requested) {
        return discoverPlans(id==null?List.of():List.of(id),requested);
    }

    public FulfillmentMutationLockPlan discoverPlans(Collection<UUID> requestedIds) {
        return discoverPlans(requestedIds,List.of());
    }

    private FulfillmentMutationLockPlan discoverPlans(Collection<UUID> requestedIds, Collection<RequestedLine> requested) {
        List<UUID> ids=requestedIds==null?List.of():requestedIds.stream().filter(java.util.Objects::nonNull)
                .distinct().sorted(java.util.Comparator.comparing(UUID::toString)).toList();
        List<RequestedLine> lines=requested==null?List.of():List.copyOf(requested);
        return FulfillmentDiscoveryRound.memo("production.plans",List.of(ids,lines),()->planFootprint(ids,lines));
    }

    private FulfillmentMutationLockPlan planFootprint(List<UUID> ids, List<RequestedLine> requested) {
        var sources=new LinkedHashSet<CommercialSource>();
        var inventory=new LinkedHashSet<InventoryDimension>();
        var analyses=new LinkedHashSet<UUID>();
        var salesItems=new LinkedHashSet<UUID>();
        var roots=new LinkedHashSet<UUID>();
        var parts=new ArrayList<String>(); parts.add("plans:"+ids);
        if(requested!=null)for(var line:requested) {
            parts.add("request:"+line); add(inventory,line.goodsId(),line.colorId());
            if(line.goodsId()!=null)roots.add(line.goodsId());
            if(line.salesOrderItemId()!=null)salesItems.add(line.salesOrderItemId());
        }
        if(!ids.isEmpty()) {
            List<UUID> planIds=NativeQueryResults.typedRows(em.createNativeQuery("""
                    WITH RECURSIVE family(id) AS (
                        SELECT id FROM production_plans WHERE id IN (:rootIds)
                        UNION
                        SELECT edge.id FROM family parent CROSS JOIN LATERAL (
                            SELECT link.subplan_id AS id FROM subplan_links link
                            WHERE link.plan_id=parent.id AND link.is_deleted=FALSE
                            UNION
                            SELECT source.plan_id FROM production_actual_output_supplement_proofs proof
                            JOIN production_execution_segments source ON source.id=proof.source_execution_segment_id
                            WHERE proof.supplement_plan_id=parent.id
                            UNION
                            SELECT proof.supplement_plan_id FROM production_actual_output_supplement_proofs proof
                            JOIN production_execution_segments source ON source.id=proof.source_execution_segment_id
                            WHERE source.plan_id=parent.id
                        ) edge
                    ) SELECT id FROM family ORDER BY id
                    """).setParameter("rootIds",ids),UUID.class);
            for(var row:rows("""
                    SELECT proof.id,proof.source_execution_segment_id,proof.supplement_execution_segment_id,
                           proof.xmin::text,reversal.id,reversal.xmin::text
                    FROM production_actual_output_supplement_proofs proof
                    JOIN production_execution_segments source ON source.id=proof.source_execution_segment_id
                    LEFT JOIN production_actual_output_supplement_reversals reversal ON reversal.proof_id=proof.id
                    WHERE proof.supplement_plan_id IN (:ids) OR source.plan_id IN (:ids) ORDER BY proof.id
                    """,planIds)) parts.add("actual-supplement:"+java.util.Arrays.toString(row));
            for(var row:rows("""
                    SELECT plan.id,plan.material_analysis_id,item.id,item.goods_id,item.color_id,item.sales_order_item_id,
                           plan.xmin::text,item.xmin::text
                    FROM production_plans plan LEFT JOIN production_plan_items item ON item.plan_id=plan.id AND item.is_deleted=FALSE
                    WHERE plan.id IN (:ids) AND plan.is_deleted=FALSE ORDER BY plan.id,item.id
                    """,planIds)) {
                parts.add("plan-row:"+java.util.Arrays.toString(row));
                if(row[1]!=null)analyses.add((UUID)row[1]);
                add(inventory,(UUID)row[3],(UUID)row[4]);
                if(row[3]!=null)roots.add((UUID)row[3]);
                if(row[5]!=null)salesItems.add((UUID)row[5]);
            }
            for(var row:rows("""
                    SELECT link.id,link.order_item_id,link.xmin::text
                    FROM plan_order_item_links link JOIN production_plan_items item ON item.id=link.plan_item_id
                    WHERE item.plan_id IN (:ids) AND link.is_deleted=FALSE ORDER BY link.id
                    """,planIds)) {parts.add("sales-allocation:"+java.util.Arrays.toString(row));salesItems.add((UUID)row[1]);}
            for(var row:rows("""
                    SELECT document.id,document.document_type,document.document_id,document.xmin::text
                    FROM production_planning_packages package JOIN production_planning_package_documents document ON document.package_id=package.id
                    WHERE package.plan_id IN (:ids) AND package.status='CONFIRMED' AND package.is_deleted=FALSE ORDER BY document.id
                    """,planIds)) {
                parts.add("package-document:"+java.util.Arrays.toString(row));
                if("PURCHASE_REQUEST".equals(row[1]))sources.add(new CommercialSource(CommercialType.PURCHASE_REQUEST,(UUID)row[2]));
                if("SUBCONTRACT_APPLICATION".equals(row[1]))sources.add(new CommercialSource(CommercialType.SUBCONTRACT_APPLICATION,(UUID)row[2]));
            }
            for(var row:rows("""
                    SELECT generation.id,request.id,generation.xmin::text
                    FROM mrp_generations generation JOIN purchase_requests request ON request.id=generation.request_id
                    WHERE generation.plan_id IN (:ids) AND generation.is_deleted=FALSE AND request.is_deleted=FALSE AND request.status<>-1
                    ORDER BY generation.id
                    """,planIds)) {parts.add("generated-request:"+java.util.Arrays.toString(row));sources.add(new CommercialSource(CommercialType.PURCHASE_REQUEST,(UUID)row[1]));}
            for(var row:rows("""
                    SELECT demand.id,demand.goods_id,demand.color_id,demand.xmin::text
                    FROM production_material_demands demand WHERE demand.plan_id IN (:ids) AND demand.is_deleted=FALSE
                    ORDER BY demand.id
                    """,planIds)) {parts.add("demand:"+java.util.Arrays.toString(row));add(inventory,(UUID)row[1],(UUID)row[2]);}
            for(var row:rows("""
                    SELECT peg.id,peg.supply_type,COALESCE(purchase.order_id,subcontract.order_id,request.request_id,application.application_id),peg.xmin::text
                    FROM production_material_supply_pegs peg JOIN production_material_demands demand ON demand.id=peg.demand_id
                    LEFT JOIN purchase_order_items purchase ON purchase.id=peg.supply_item_id AND peg.supply_type='PURCHASE_ORDER_ITEM'
                    LEFT JOIN subcontract_order_items subcontract ON subcontract.id=peg.supply_item_id AND peg.supply_type='SUBCONTRACT_ORDER_ITEM'
                    LEFT JOIN purchase_request_items request ON request.id=peg.supply_item_id AND peg.supply_type='PURCHASE_REQUEST_ITEM'
                    LEFT JOIN subcontract_application_items application ON application.id=peg.supply_item_id AND peg.supply_type='SUBCONTRACT_APPLICATION_ITEM'
                    WHERE demand.plan_id IN (:ids) AND demand.is_deleted=FALSE AND peg.status NOT IN ('RELEASED','REVERSED')
                    ORDER BY peg.id
                    """,planIds)) {
                parts.add("supply-peg:"+java.util.Arrays.toString(row));
                if(row[2]!=null) {
                    CommercialType type=switch(row[1].toString()) {
                        case "PURCHASE_ORDER_ITEM" -> CommercialType.PURCHASE_ORDER;
                        case "SUBCONTRACT_ORDER_ITEM" -> CommercialType.SUBCONTRACT_ORDER;
                        case "PURCHASE_REQUEST_ITEM" -> CommercialType.PURCHASE_REQUEST;
                        default -> CommercialType.SUBCONTRACT_APPLICATION;
                    };
                    sources.add(new CommercialSource(type,(UUID)row[2]));
                }
            }
        }
        if(!salesItems.isEmpty()) {
            List<Object[]> rows=rows("""
                    SELECT item.id,item.order_id,item.goods_id,item.color_id,item.xmin::text,sale.xmin::text
                    FROM sales_order_items item JOIN sales_orders sale ON sale.id=item.order_id
                    WHERE item.id IN (:ids) ORDER BY item.id
                    """,salesItems);
            if(rows.size()!=salesItems.size())throw new ApiException(ErrorCode.CONFLICT,"计划销售来源已不存在，请刷新后重试");
            for(var row:rows) {parts.add("sale:"+java.util.Arrays.toString(row));sources.add(new CommercialSource(CommercialType.SALES_ORDER,(UUID)row[1]));add(inventory,(UUID)row[2],(UUID)row[3]);}
        }
        if(!roots.isEmpty())for(var row:rows("""
                WITH RECURSIVE tree AS (
                    SELECT bom.id,bom.component_goods_id,COALESCE(bom.color_id,goods.color_id) AS color_id,
                           ARRAY[bom.goods_id,bom.component_goods_id] AS path,1 AS depth,bom.xmin::text AS snapshot
                    FROM goods_bom_items bom JOIN goods ON goods.id=bom.component_goods_id AND goods.is_deleted=FALSE
                    WHERE bom.goods_id IN (:ids) AND bom.is_deleted=FALSE AND bom.hard_gate=TRUE AND bom.control_stage IN ('START','ASSEMBLY','FINISH')
                    UNION ALL
                    SELECT bom.id,bom.component_goods_id,COALESCE(bom.color_id,goods.color_id),parent.path||bom.component_goods_id,
                           parent.depth+1,bom.xmin::text
                    FROM tree parent JOIN goods_bom_items bom ON bom.goods_id=parent.component_goods_id AND bom.is_deleted=FALSE
                    JOIN goods ON goods.id=bom.component_goods_id AND goods.is_deleted=FALSE
                    WHERE parent.depth<10 AND NOT bom.component_goods_id=ANY(parent.path)
                      AND bom.hard_gate=TRUE AND bom.control_stage IN ('START','ASSEMBLY','FINISH')
                ) SELECT DISTINCT id,component_goods_id,color_id,snapshot FROM tree ORDER BY id,component_goods_id,color_id
                """,roots)) {parts.add("bom:"+java.util.Arrays.toString(row));add(inventory,(UUID)row[1],(UUID)row[2]);}
        if(!analyses.isEmpty())for(var row:rows("""
                SELECT id,goods_id,color_id,reservation.xmin::text FROM stock_reservations reservation
                WHERE owner_type='PREPLAN_ANALYSIS' AND owner_id IN (:ids) AND is_deleted=FALSE AND release_reason='TRANSFERRED_TO_PLAN'
                ORDER BY id
                """,analyses)) {parts.add("transferred-reservation:"+java.util.Arrays.toString(row));add(inventory,(UUID)row[1],(UUID)row[2]);}
        var local=new FulfillmentMutationLockPlan(sources,inventory,Set.of(),Set.of(),CanonicalFingerprint.sha256(parts));
        if(analyses.isEmpty())return local;
        var analysis=production.forAnalyses(analyses);
        return FulfillmentMutationLockPlan.merge(CanonicalFingerprint.sha256(List.of(local.fingerprint(),analysis.fingerprint())),List.of(local,analysis));
    }

    private List<Object[]> rows(String sql,Collection<UUID> ids) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery(sql).setParameter("ids",ids));
    }
    private static void add(Set<InventoryDimension> inventory,UUID goods,UUID color) {
        if(goods!=null)inventory.add(new InventoryDimension(goods,color));
    }
}
