package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryProductionCostPort;
import com.uten.imp.application.port.InventoryValuationPort;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;

import static com.uten.imp.features.stock.valuation.ValueMath.conflict;

/** Durable work is rechecked after its inventory locks; task replay remains strict. */
@Service
public class InventoryValueWorkService {
    // Separate two-key PostgreSQL advisory namespace; this nonblocking claim is
    // only between workers and never replaces the ordinary inventory/pool locks.
    private static final int REFRESH_CLAIM_NAMESPACE = 0x5657524B;
    private static final String REFRESH_KEYS_SQL = """
            WITH scope AS MATERIALIZED (
                SELECT execution_segment_id,source_kind,product_pool_id
                FROM stock_value_production_cost_objects WHERE execution_segment_id=:scope
            ), nodes AS (
                SELECT input_node_id AS id FROM stock_value_production_cost_inputs WHERE execution_segment_id=:scope
                UNION SELECT source_node_id FROM stock_value_production_cost_outputs WHERE execution_segment_id=:scope
                UNION SELECT id FROM stock_value_nodes
                    WHERE owner_kind='COST_WIP' AND owner_id=:scope AND active
            )
            SELECT pool.goods_id,pool.color_id FROM scope JOIN stock_value_pools pool ON pool.id=scope.product_pool_id
            UNION SELECT pool.goods_id,pool.color_id FROM nodes
                JOIN stock_value_nodes node ON node.id=nodes.id JOIN stock_value_pools pool ON pool.id=node.pool_id
            UNION SELECT issue.goods_id,issue.color_id FROM scope
                JOIN subcontract_receipt_material_consumptions used
                  ON scope.source_kind='SUBCONTRACT_RECEIPT_ITEM' AND used.receipt_item_id=scope.execution_segment_id
                JOIN subcontract_material_issue_items issue ON issue.id=used.issue_item_id
            UNION SELECT issue.goods_id,issue.color_id FROM scope
                JOIN subcontract_material_issue_items issue
                  ON scope.source_kind='SUBCONTRACT_ORDER_NORMAL_LOSS' AND issue.order_item_id=scope.execution_segment_id
            """;
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

    /** A zero result means this invocation did no work, not that another worker has drained the queue. */
    public int runBatch(){
        int applied=0;
        List<UUID> pendingScopes=db.queryForList("""
                SELECT execution_segment_id FROM stock_value_production_cost_objects
                WHERE business_refresh_pending AND state<>'APPLYING'
                ORDER BY execution_segment_id LIMIT 10
                """,Map.of(),UUID.class);
        for(UUID scope:pendingScopes) {
            if(refreshScope(scope,()->refreshPendingBusiness(scope)))applied++;
        }
        // Discovery is deliberately scope-only authority. Events and versions in
        // this projection can become stale while a worker waits for inventory.
        for(var dirty:production.pendingRecalculations(10)) {
            UUID scope=dirty.executionSegmentId();
            if(refreshScope(scope,()->recalculatePendingSource(scope)))applied++;
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

    /**
     * One scope's durable precision closure can still belong to another committed
     * transaction (V1025: its whole-target verification stays queued until the task
     * loops apply it). That scope answers busy for now; the remaining loops of this
     * same invocation still apply and complete the blocking work, and the skipped
     * refresh runs on the next cycle. One busy scope must not starve every queue.
     */
    private boolean refreshScope(UUID scope,Supplier<Boolean> operation) {
        try{
            return withRefreshLocks(scope,operation);
        }catch(org.springframework.dao.ConcurrencyFailureException busy){
            return false;
        }
    }

    private boolean withRefreshLocks(UUID scope,Supplier<Boolean> operation) {
        return Boolean.TRUE.equals(tx.execute(status->{
            boolean claimed=Boolean.TRUE.equals(db.queryForObject("""
                    SELECT pg_try_advisory_xact_lock(:namespace,hashtext(CAST(:scope AS text)))
                    """,Map.of("namespace",REFRESH_CLAIM_NAMESPACE,"scope",scope),Boolean.class));
            if(!claimed)return false;
            if(Boolean.TRUE.equals(db.queryForObject("SELECT to_regprocedure('public.fn_inventory_value_try_refresh_root(uuid)') IS NOT NULL",Map.of(),Boolean.class))
                    &&!Boolean.TRUE.equals(db.queryForObject("SELECT fn_inventory_value_try_refresh_root(:scope)",Map.of("scope",scope),Boolean.class)))return false;
            Set<InventoryKey> observed=refreshKeys(scope);
            if(observed.isEmpty())return false;
            mutex.lockAll(observed);
            // A business transaction can introduce a new input while we wait for
            // inventory. Do not acquire that key late and invert the lock order.
            // Roll back this claim/lock attempt; the durable pending marker stays
            // intact and the next invocation discovers the complete footprint.
            if(!observed.containsAll(refreshKeys(scope))) {
                status.setRollbackOnly();
                return false;
            }
            // No business row lock was taken before inventory. Domain refresh
            // keeps its established inventory -> pool -> cost-object order.
            return operation.get();
        }));
    }

    private Set<InventoryKey> refreshKeys(UUID scope) {
        return Set.copyOf(db.query(REFRESH_KEYS_SQL,Map.of("scope",scope),
                (row,index)->new InventoryKey(row.getObject("goods_id",UUID.class),row.getObject("color_id",UUID.class))));
    }

    private boolean refreshPendingBusiness(UUID scope) {
        var rows=db.queryForList("""
                SELECT source_kind,business_refresh_event_id,business_refresh_actor_id,
                    nullif(to_jsonb(stock_value_production_cost_objects)->'business_refresh_precision_policy','null'::jsonb) business_precision_policy,
                    to_jsonb(stock_value_production_cost_objects)->>'business_refresh_precision_version' precision_version,
                    (to_jsonb(stock_value_production_cost_objects)->>'business_refresh_precision_root_id')::uuid precision_root
                FROM stock_value_production_cost_objects
                WHERE execution_segment_id=:scope AND business_refresh_pending AND state<>'APPLYING'
                """,Map.of("scope",scope));
        if(rows.isEmpty())return false;
        var pending=rows.getFirst();
        UUID event=(UUID)pending.get("business_refresh_event_id"),actor=(UUID)pending.get("business_refresh_actor_id");
        if(event==null||actor==null)throw conflict("待处理成本刷新缺少原事件或操作人，不能构造替代来源");
        try(var precision=InventoryValueLedger.bindBusinessRefreshPrecision(db,pending.get("business_precision_policy"),pending.get("precision_version"),
                (UUID)pending.get("precision_root")==null?scope:(UUID)pending.get("precision_root"))){
            if(pending.get("source_kind").toString().startsWith("SUBCONTRACT_"))subcontract.refresh(scope,event,actor);
            else material.refresh(scope,event,actor);
        }
        return true;
    }

    private boolean recalculatePendingSource(UUID scope) {
        if(Boolean.TRUE.equals(db.queryForObject("SELECT to_regprocedure('public.fn_inventory_value_production_inputs_ready(uuid)') IS NOT NULL",Map.of(),Boolean.class))
                &&!Boolean.TRUE.equals(db.queryForObject("SELECT fn_inventory_value_production_inputs_ready(:scope)",Map.of("scope",scope),Boolean.class)))return false;
        var rows=db.queryForList("""
                WITH candidate AS MATERIALIZED (
                    SELECT dirty.source_event_id,object.version
                    FROM stock_value_production_cost_dirty dirty
                    JOIN stock_value_production_cost_objects object USING(execution_segment_id)
                    WHERE dirty.execution_segment_id=:scope AND dirty.observed_revision>dirty.cleared_revision
                      AND object.state<>'APPLYING' AND NOT object.business_refresh_pending
                    ORDER BY dirty.observed_revision DESC,dirty.input_node_id LIMIT 1
                )
                SELECT candidate.source_event_id,candidate.version,event.actor_user_id,event.occurred_at
                FROM candidate JOIN stock_value_events event ON event.id=candidate.source_event_id
                WHERE NOT EXISTS(SELECT 1 FROM stock_value_jobs job
                    WHERE job.event_id=candidate.source_event_id AND job.status<>'APPLIED')
                """,Map.of("scope",scope));
        if(rows.isEmpty())return false;
        var source=rows.getFirst();UUID event=(UUID)source.get("source_event_id");
        production.recalculate(support.context("PRODUCTION_SOURCE_RECALCULATE",event,scope,scope,
                        (UUID)source.get("actor_user_id"),InventoryBusinessValueSupport.time(source.get("occurred_at"))),
                scope,((Number)source.get("version")).longValue());
        return true;
    }

    /** Snapshot of durable work, including work another transaction has claimed but not committed. */
    public boolean hasPendingWork() {
        return Boolean.TRUE.equals(db.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM stock_value_production_cost_objects WHERE business_refresh_pending)
                    OR EXISTS(SELECT 1 FROM stock_value_production_cost_dirty dirty JOIN stock_value_production_cost_objects object USING(execution_segment_id)
                        WHERE object.current_revision_id IS NOT NULL AND dirty.observed_revision>dirty.cleared_revision)
                    OR EXISTS(SELECT 1 FROM stock_value_production_cost_tasks WHERE status='PENDING')
                    OR EXISTS(SELECT 1 FROM stock_value_tasks WHERE status='PENDING')
                    OR EXISTS(SELECT 1 FROM stock_value_jobs WHERE status<>'APPLIED')
                """,Map.of(),Boolean.class));
    }
}
