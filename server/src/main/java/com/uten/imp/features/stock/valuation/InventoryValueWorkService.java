package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryProductionCostPort;
import com.uten.imp.application.port.InventoryValuationPort;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import java.util.List;

/** Existing durable tasks are claimed by their row locks, one short transaction per task. */
@Service
public class InventoryValueWorkService {
    private final InventoryValuationPort values;
    private final InventoryProductionCostPort production;
    private final InventoryMutationLock mutex;
    private final TransactionTemplate tx;
    private org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate db;
    private InventoryBusinessValueSupport support;
    private ProductionInventoryValueService material;
    private SubcontractOwnMaterialCostService subcontract;
    @org.springframework.beans.factory.annotation.Autowired
    public void configureSourceRecalculations(org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate db,
            InventoryBusinessValueSupport support,ProductionInventoryValueService material,SubcontractOwnMaterialCostService subcontract){
        this.db=db;this.support=support;this.material=material;this.subcontract=subcontract;
    }
    public InventoryValueWorkService(InventoryValuationPort values,InventoryProductionCostPort production,
            InventoryMutationLock mutex,PlatformTransactionManager manager){
        this.values=values;this.production=production;this.mutex=mutex;this.tx=new TransactionTemplate(manager);
    }
    public int runBatch(){
        int applied=0;
        for(var pending:db.queryForList("""
                SELECT object.execution_segment_id,object.source_kind,object.business_refresh_event_id,object.business_refresh_actor_id
                FROM stock_value_production_cost_objects object
                WHERE object.business_refresh_pending AND object.state<>'APPLYING'
                ORDER BY object.execution_segment_id LIMIT 10
                """,java.util.Map.of())){
            tx.executeWithoutResult(status->{
                var scope=(java.util.UUID)pending.get("execution_segment_id");var event=(java.util.UUID)pending.get("business_refresh_event_id");
                var actor=(java.util.UUID)pending.get("business_refresh_actor_id");
                if(pending.get("source_kind").toString().startsWith("SUBCONTRACT_"))subcontract.refresh(scope,event,actor);
                else material.refresh(scope,event,actor);
            });
            applied++;
        }
        for(var dirty:production.pendingRecalculations(10)){
            var source=db.queryForList("""
                    SELECT event.actor_user_id,event.occurred_at,p.warehouse_id,p.goods_id,p.color_id
                    FROM stock_value_production_cost_objects object JOIN stock_value_pools p ON p.id=object.product_pool_id
                    JOIN stock_value_events event ON event.id=:event
                    WHERE object.execution_segment_id=:segment AND NOT EXISTS(
                        SELECT 1 FROM stock_value_jobs job WHERE job.event_id=:event AND job.status<>'APPLIED')
                    """,java.util.Map.of("event",dirty.sourceEventId(),"segment",dirty.executionSegmentId()));
            if(source.size()!=1)continue;var row=source.getFirst();var pool=InventoryBusinessValueSupport.pool(row);
            tx.executeWithoutResult(status->{
                mutex.lock(new InventoryKey(pool.goodsId(),pool.colorId()));
                production.recalculate(support.context("PRODUCTION_SOURCE_RECALCULATE",dirty.sourceEventId(),dirty.executionSegmentId(),
                        dirty.executionSegmentId(),(java.util.UUID)row.get("actor_user_id"),InventoryBusinessValueSupport.time(row.get("occurred_at"))),
                        dirty.executionSegmentId(),dirty.currentVersion());
            });applied++;
        }
        for(var work:production.pendingWork(50)){
            Boolean result=tx.execute(status->{
                mutex.lockAll(List.of(new InventoryKey(work.inputPool().goodsId(),work.inputPool().colorId()),
                        new InventoryKey(work.outputPool().goodsId(),work.outputPool().colorId())));
                return production.apply(work.taskId()).applied();
            });if(Boolean.TRUE.equals(result))applied++;
        }
        for(var work:values.pendingWork(50)){
            Boolean result=tx.execute(status->{
                mutex.lock(new InventoryKey(work.lockKey().goodsId(),work.lockKey().colorId()));
                return values.propagate(work.taskId()).applied();
            });if(Boolean.TRUE.equals(result))applied++;
        }
        return applied;
    }
}
