package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.*;
import com.uten.imp.application.port.InventoryPositionPort.*;
import com.uten.imp.application.port.InventoryProductionCostPort.*;
import com.uten.imp.application.port.InventoryValuationPort.*;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.*;
import static com.uten.imp.features.stock.valuation.ValueMath.*;
import static com.uten.imp.features.stock.valuation.InventoryBusinessValueSupport.*;

/** Normal and excess loss are original material intervals, never a rounded unit-price estimate. */
@Service
@Transactional(propagation=Propagation.MANDATORY)
public class SubcontractLossValueService implements SubcontractMaterialValuePort {
    private final NamedParameterJdbcTemplate db;
    private final InventoryPositionPort positions;
    private final InventoryProductionCostPort costs;
    private final InventoryMutationLock mutex;
    private final InventoryBusinessValueSupport support;
    public SubcontractLossValueService(NamedParameterJdbcTemplate db,InventoryPositionPort positions,
            InventoryProductionCostPort costs,InventoryMutationLock mutex,InventoryBusinessValueSupport support){
        this.db=db;this.positions=positions;this.costs=costs;this.mutex=mutex;this.support=support;
    }

    @Override @Transactional(propagation=Propagation.MANDATORY,readOnly=true)
    public void validateWaste(UUID waste){
        for(var row:lines(waste)){
            if(row.get("order_item_id")==null)throw conflict("损耗须关联原实发明细及其委外订货来源");
            take(Owner.SUBCONTRACT_WIP,(UUID)row.get("material_issue_item_id"),(BigDecimal)row.get("qty_base"));
        }
    }

    @Override public void wasteRecorded(UUID waste,UUID actor,boolean reversal){
        var lines=lines(waste);List<InventoryKey> keys=new ArrayList<>();
        lines.forEach(row->{keys.add(new InventoryKey((UUID)row.get("goods_id"),(UUID)row.get("color_id")));
            keys.add(new InventoryKey((UUID)row.get("product_goods_id"),(UUID)row.get("product_color_id")));});mutex.lockAll(keys);
        Map<UUID,UUID> orders=new LinkedHashMap<>();
        for(var row:lines){
            UUID item=(UUID)row.get("id"),issue=(UUID)row.get("material_issue_item_id"),order=(UUID)row.get("order_item_id");
            BigDecimal qty=(BigDecimal)row.get("qty_base"),normal=(BigDecimal)row.get("normal_base"),excess=qty.subtract(normal);
            if(!reversal){
                UUID whole=result("SUBCONTRACT_WASTE_VALUE",item);
                if(whole==null){var sources=take(Owner.SUBCONTRACT_WIP,issue,qty);var source=positions.position(sources.getFirst().positionRootId());
                    whole=positions.move(new Move(context("SUBCONTRACT_WASTE_VALUE",item,waste,actor),source.pool(),Owner.SUBCONTRACT_WIP,item,sources)).positionRootId();}
                PoolKey pool=positions.position(whole).pool();
                if(normal.signum()>0&&result("SUBCONTRACT_NORMAL_LOSS",item)==null)
                    positions.move(new Move(context("SUBCONTRACT_NORMAL_LOSS",item,waste,actor),pool,Owner.COST_WIP,order,List.of(new Slice(whole,normal,item))));
                if(excess.signum()>0&&result("SUBCONTRACT_EXCESS_LOSS",item)==null)
                    positions.move(new Move(context("SUBCONTRACT_EXCESS_LOSS",item,waste,actor),pool,Owner.LOSS,item,List.of(new Slice(whole,excess,item))));
            }else{
                if(normal.signum()>0&&result("SUBCONTRACT_NORMAL_LOSS_REVERSE",item)==null){
                    UUID root=requiredResult("SUBCONTRACT_NORMAL_LOSS",item);PoolKey pool=positions.position(root).pool();
                    positions.returnConsumed(new ReturnConsumed(context("SUBCONTRACT_NORMAL_LOSS_REVERSE",item,waste,actor),pool,root,normal,Owner.SUBCONTRACT_WIP,issue));
                }
                if(excess.signum()>0&&result("SUBCONTRACT_EXCESS_LOSS_REVERSE",item)==null){
                    UUID root=requiredResult("SUBCONTRACT_EXCESS_LOSS",item);PoolKey pool=positions.position(root).pool();
                    positions.move(new Move(context("SUBCONTRACT_EXCESS_LOSS_REVERSE",item,waste,actor),pool,Owner.SUBCONTRACT_WIP,issue,List.of(new Slice(root,excess,item))));
                }
            }
            String eventType=excess.signum()>0?"SUBCONTRACT_EXCESS_LOSS":"SUBCONTRACT_NORMAL_LOSS";
            if(reversal)eventType+="_REVERSE";
            UUID eventId=db.queryForObject("SELECT id FROM stock_value_events WHERE source_doc_type=:type AND source_item_id=:id",Map.of("type",eventType,"id",item),UUID.class);
            orders.put(order,eventId);
        }
        for(var order:orders.entrySet())refresh(order.getKey(),order.getValue(),actor);
    }

    public void registerOutput(UUID receiptItem,MovementValue output,PoolKey physicalPool,EventContext event){
        UUID order=db.queryForObject("SELECT order_item_id FROM subcontract_receipt_items WHERE id=:id",Map.of("id",receiptItem),UUID.class);
        if(order==null)throw conflict("委外损耗成本必须关联原订货明细");
        var source=order(order);
        if(physicalPool==null||physicalPool.warehouseId()==null
                ||!Objects.equals(source.get("goods_id"),physicalPool.goodsId())
                ||!Objects.equals(source.get("color_id"),physicalPool.colorId()))
            throw conflict("委外产出成本必须关联该订货目标件的真实入库仓库");
        PoolKey product=registeredProduct(order);
        if(product==null)product=physicalPool;
        support.ensureActive(product,event);
        costs.registerScope(new Scope(order,ScopeKind.SUBCONTRACT_ORDER_NORMAL_LOSS,product));
        // The first physical output anchors this order's immutable cost scope; later outputs keep their own warehouse.
        costs.registerOutput(order,physicalPool,new Output(output.valueNodeId(),output.movementId()));
        refresh(order,event.sourceEventId(),event.actorUserId());
    }

    public void refresh(UUID order,UUID event,UUID actor){
        if (!TransactionSynchronizationManager.isSynchronizationActive()) {
            refreshNow(order,event,actor);
            return;
        }
        FinalLossCosts pending=TransactionSynchronizationManager.getSynchronizations().stream()
                .filter(FinalLossCosts.class::isInstance).map(FinalLossCosts.class::cast)
                .findFirst().orElse(null);
        if(pending==null){
            pending=new FinalLossCosts();
            TransactionSynchronizationManager.registerSynchronization(pending);
        }
        pending.orders.put(order,new FinalLossCost(event,actor));
    }

    private record FinalLossCost(UUID event,UUID actor){}

    private final class FinalLossCosts implements TransactionSynchronization {
        private final Map<UUID,FinalLossCost> orders=new LinkedHashMap<>();
        @Override public void beforeCommit(boolean readOnly){
            // Stock-in and accepted loss occur in one transaction. Create only the
            // final cost revision, after the loss has fixed the actual output basis.
            while(!orders.isEmpty()){
                Map<UUID,FinalLossCost> batch=new LinkedHashMap<>(orders);
                orders.clear();
                batch.forEach((order,fact)->refreshNow(order,fact.event(),fact.actor()));
            }
        }
    }

    private void refreshNow(UUID order,UUID event,UUID actor){
        var source=order(order);PoolKey product=registeredProduct(order);
        // Loss facts already retain their exact COST_WIP inputs. The first physical output will collect them.
        if(product==null)return;
        var inputs=db.queryForList("""
                SELECT event.result_node_id,item.id,p.goods_id,p.color_id FROM subcontract_waste_items item
                JOIN subcontract_material_issue_items issue ON issue.id=item.material_issue_item_id
                JOIN stock_value_events event ON event.source_item_id=item.id AND event.source_doc_type='SUBCONTRACT_NORMAL_LOSS'
                JOIN stock_value_nodes node ON node.id=event.result_node_id JOIN stock_value_pools p ON p.id=node.pool_id
                WHERE issue.order_item_id=:id AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_inputs input WHERE input.input_node_id=node.id)
                ORDER BY item.id LIMIT 100
                """,Map.of("id",order));
        List<InventoryKey> keys=new ArrayList<>();keys.add(new InventoryKey(product.goodsId(),product.colorId()));
        inputs.forEach(row->keys.add(new InventoryKey((UUID)row.get("goods_id"),(UUID)row.get("color_id"))));mutex.lockAll(keys);
        EventContext context=context("SUBCONTRACT_NORMAL_COST",event,order,actor);support.ensureActive(product,context);
        costs.registerScope(new Scope(order,ScopeKind.SUBCONTRACT_ORDER_NORMAL_LOSS,product));
        var object=db.queryForMap("SELECT version,state FROM stock_value_production_cost_objects WHERE execution_segment_id=:id",Map.of("id",order));
        if("APPLYING".equals(object.get("state"))){
            db.update("UPDATE stock_value_production_cost_objects SET business_refresh_pending=TRUE,business_refresh_event_id=:event,business_refresh_actor_id=:actor WHERE execution_segment_id=:id",
                    Map.of("id",order,"event",event,"actor",actor));return;
        }
        var basis=db.queryForMap("SELECT * FROM v_subcontract_normal_loss_basis WHERE order_item_id=:id",Map.of("id",order));
        BigDecimal target=(BigDecimal)basis.get("target_qty_base");boolean complete=Boolean.TRUE.equals(basis.get("classification_complete"));
        UUID approval=(UUID)basis.get("approval_case_id");
        var additions=inputs.stream().map(row->new Input((UUID)row.get("result_node_id"),(UUID)row.get("id"),InputKind.NORMAL_LOSS)).toList();
        String hash=com.uten.imp.common.util.CanonicalFingerprint.sha256(List.of(order.toString(),target.toPlainString(),Boolean.toString(complete),source.get("basis_hash").toString()));
        costs.revise(new Revision(context,order,product,((Number)object.get("version")).longValue(),target,complete,approval==null?order:approval,hash,additions,List.of()));
        db.update("UPDATE stock_value_production_cost_objects SET business_refresh_pending=FALSE WHERE execution_segment_id=:id",Map.of("id",order));
    }

    @Override @Transactional(propagation=Propagation.MANDATORY,readOnly=true)
    public WasteValue wasteValue(UUID item){
        var row=db.queryForMap("SELECT * FROM v_subcontract_waste_actual_value WHERE waste_item_id=:id",Map.of("id",item));
        return new WasteValue((UUID)row.get("order_item_id"),(UUID)row.get("normal_value_node_id"),(UUID)row.get("excess_value_node_id"),
                (BigDecimal)row.get("normal_value_local"),(BigDecimal)row.get("excess_value_local"),Boolean.TRUE.equals(row.get("complete"))?State.FINAL:State.PENDING);
    }

    private PoolKey registeredProduct(UUID order){
        var scopes=db.queryForList("""
                SELECT object.source_kind,pool.warehouse_id,pool.goods_id,pool.color_id
                FROM stock_value_production_cost_objects object
                JOIN stock_value_pools pool ON pool.id=object.product_pool_id
                WHERE object.execution_segment_id=:id
                """,Map.of("id",order));
        if(scopes.isEmpty())return null;
        if(scopes.size()!=1||!ScopeKind.SUBCONTRACT_ORDER_NORMAL_LOSS.name().equals(scopes.getFirst().get("source_kind")))
            throw conflict("委外订货正常损耗成本来源类型已变化，请核对原成本对象");
        return pool(scopes.getFirst());
    }
    private Map<String,Object> order(UUID id){return db.queryForMap("SELECT item.id,item.goods_id,item.color_id,md5(to_jsonb(item)::text) basis_hash FROM subcontract_order_items item WHERE item.id=:id",Map.of("id",id));}
    private List<Map<String,Object>> lines(UUID waste){return db.queryForList("""
            SELECT item.*,item.qty*COALESCE(item.unit_rate,1) qty_base,
                LEAST(item.qty,COALESCE(item.standard_qty,0))*COALESCE(item.unit_rate,1) normal_base,issue.order_item_id,
                target.goods_id product_goods_id,target.color_id product_color_id
            FROM subcontract_waste_items item JOIN subcontract_material_issue_items issue ON issue.id=item.material_issue_item_id
            JOIN subcontract_order_items target ON target.id=issue.order_item_id WHERE item.waste_id=:id AND NOT item.is_deleted ORDER BY item.id
            """,Map.of("id",waste));}
    private List<Slice> take(Owner owner,UUID id,BigDecimal qty){
        BigDecimal left=qty;List<Slice> result=new ArrayList<>();
        for(var row:db.queryForList("""
                SELECT root.id,head.range_to-head.range_from qty FROM stock_value_nodes root JOIN stock_value_nodes head ON head.id=root.return_head_id
                WHERE root.root_issue_id=root.id AND head.owner_kind=:owner AND head.owner_id=:id AND head.range_to>head.range_from ORDER BY root.created_at,root.id
                """,Map.of("owner",owner.name(),"id",id))){
            if(left.signum()==0)break;BigDecimal take=left.min((BigDecimal)row.get("qty"));result.add(new Slice((UUID)row.get("id"),take,(UUID)row.get("id")));left=left.subtract(take);
        }
        if(left.signum()!=0)throw conflict("损耗必须使用原实发尚未耗用的材料位置，缺少历史来源时不得用名义价格猜成本");return result;
    }
    private UUID result(String type,UUID item){var ids=db.queryForList("SELECT result_node_id FROM stock_value_events WHERE source_doc_type=:type AND source_item_id=:id",Map.of("type",type,"id",item),UUID.class);return ids.isEmpty()?null:ids.getFirst();}
    private UUID requiredResult(String type,UUID item){UUID root=result(type,item);if(root==null)throw conflict("损耗反向缺少原材料成本切片");return root;}
    private EventContext context(String type,UUID event,UUID doc,UUID actor){return support.context(type,UUID.nameUUIDFromBytes((type+":"+event).getBytes(StandardCharsets.UTF_8)),doc,event,actor,
            db.queryForObject("SELECT transaction_timestamp()",Map.of(),java.time.OffsetDateTime.class));}
}
