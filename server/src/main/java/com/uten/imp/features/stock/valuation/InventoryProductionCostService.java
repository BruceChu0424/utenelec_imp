package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryProductionCostPort;
import com.uten.imp.application.port.InventoryValuationPort.*;
import com.uten.imp.features.stock.InventoryMutationLock;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.stock.valuation.ValueMath.*;

/** Per-execution approved allocation versions, never a second physical stock ledger. */
@Service
public class InventoryProductionCostService extends InventoryValueLedger implements InventoryProductionCostPort {
    private final InventoryValuationService values;
    private final boolean typedScopesInstalled;
    public InventoryProductionCostService(NamedParameterJdbcTemplate db,InventoryMutationLock mutex,InventoryValuationService values){
        super(db,mutex);this.values=values;
        this.typedScopesInstalled=Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='stock_value_production_cost_objects' AND column_name='source_kind')",Map.of(),Boolean.class));
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void registerScope(Scope scope){
        transaction();required(scope.sourceId(),"成本业务来源UUID");
        if(scope.kind()==null)throw invalid("成本业务来源类型不能为空");
        PoolKey product=key(scope.productPool());requireHeld(product);Pool pool=lockPool(product);
        db.update("INSERT INTO stock_value_production_cost_objects(execution_segment_id,product_pool_id,source_kind) VALUES (:id,:pool,:kind) ON CONFLICT DO NOTHING",
                args("id",scope.sourceId(),"pool",pool.id(),"kind",scope.kind().name()));
        var current=object(scope.sourceId(),true);
        if(!scope.kind().name().equals(current.get("source_kind"))||!pool.id().equals(current.get("product_pool_id")))
            throw conflict("同一成本来源不能改挂不同业务类型、货品或归属仓");
    }

    @Override @Transactional(readOnly=true)
    public Scope scope(UUID sourceId){
        var current=object(sourceId,false);Pool pool=poolById((UUID)current.get("product_pool_id"),false);
        return new Scope(sourceId,ScopeKind.valueOf(Objects.toString(current.get("source_kind"),"PRODUCTION_EXECUTION")),pool.key());
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void registerOutput(UUID segment,PoolKey product,Output output){
        transaction();required(segment,"生产执行段UUID");product=key(product);requireHeld(product);
        requireHeld(node(output.finishedSourceNodeId(),false).key());Pool pool=lockPool(product);
        db.update("INSERT INTO stock_value_production_cost_objects(execution_segment_id,product_pool_id) SELECT :segment,:pool WHERE NOT EXISTS(SELECT 1 FROM stock_value_production_cost_objects WHERE execution_segment_id=:segment) ON CONFLICT DO NOTHING",
                args("segment",segment,"pool",pool.id()));
        Map<String,Object> object=object(segment,true);
        if(!pool.id().equals(object.get("product_pool_id")))throw conflict("同执行段不能绑定不同产出产品和归属池");
        bindOutput(segment,product,output);
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public Revised revise(Revision command){
        transaction();EventContext c=context(command.context());required(command.executionSegmentId(),"生产执行段UUID");
        PoolKey product=key(command.productPool());requireHeld(product);
        BigDecimal target=decimal(command.approvedTargetQtyBase(),"当前批准目标产量",false);
        if(command.expectedVersion()<0)throw invalid("原生产成本版本无效");
        required(command.approvalEvidenceId(),"分配批准依据UUID");
        if(command.approvalEvidenceHash()==null||!command.approvalEvidenceHash().matches("[0-9a-f]{64}"))throw invalid("分配批准依据摘要无效");
        List<Input> inputs=command.inputs()==null?List.of():List.copyOf(command.inputs());
        List<Output> outputs=command.outputs()==null?List.of():List.copyOf(command.outputs());
        if(inputs.size()>100||outputs.size()>100)throw invalid("每次最多登记100个新增耗用或产出来源，其余来源请分批登记");
        List<Map<String,Object>> inputBody=inputs.stream().map(i->{required(i.consumedPositionRootId(),"真实耗用价值UUID");required(i.approvedPostingId(),"真实耗用posting UUID");
            if(i.kind()==null)throw invalid("耗用/正常损耗/确认加工费类型不能为空");return args("node",i.consumedPositionRootId(),"posting",i.approvedPostingId(),"kind",i.kind().name());}).sorted(Comparator.comparing(m->m.get("node").toString())).toList();
        List<Map<String,Object>> outputBody=outputs.stream().map(o->{required(o.finishedSourceNodeId(),"成品来源UUID");required(o.movementId(),"成品movement UUID");
            return args("source",o.finishedSourceNodeId(),"movement",o.movementId());}).sorted(Comparator.comparing(m->m.get("source").toString())).toList();
        Request request=request("PRODUCTION_COST_REVISION",c,args("segment",command.executionSegmentId(),"product",keyText(product),
                "previousVersion",command.expectedVersion(),"target",target.toPlainString(),"complete",command.scopeComplete(),
                "approval",command.approvalEvidenceId(),"approvalHash",command.approvalEvidenceHash(),"inputs",inputBody,"outputs",outputBody));
        Map<String,Object> replay=revisionReplay(c,request);if(replay!=null)return revisionResult(replay,true);
        // Every mutable input/target key is checked before row locks. Registered
        // immutable facts need no new I lock just to snapshot their known value.
        for(Input input:inputs)requireHeld(node(input.consumedPositionRootId(),false).key());
        for(Output output:outputs)requireHeld(node(output.finishedSourceNodeId(),false).key());
        Pool pool=lockPool(product);
        db.update("INSERT INTO stock_value_production_cost_objects(execution_segment_id,product_pool_id) SELECT :segment,:pool WHERE NOT EXISTS(SELECT 1 FROM stock_value_production_cost_objects WHERE execution_segment_id=:segment) ON CONFLICT DO NOTHING",
                args("segment",command.executionSegmentId(),"pool",pool.id()));
        Map<String,Object> object=object(command.executionSegmentId(),true);
        replay=revisionReplay(c,request);if(replay!=null)return revisionResult(replay,true);
        if(!pool.id().equals(object.get("product_pool_id"))||number(object,"version")!=command.expectedVersion())throw conflict("执行段产出归属或成本方案版本已变化");
        if(hasTasks((UUID)object.get("current_revision_id")))throw conflict("原成本版本正在分批执行，请先完成或重试原任务");
        for(Input input:inputs)registerInput(command.executionSegmentId(),input);
        for(Output output:outputs)bindOutput(command.executionSegmentId(),product,output);
        Map<String,Object> snapshot=snapshot(command.executionSegmentId());
        BigDecimal outputQty=(BigDecimal)snapshot.get("output_qty");
        UUID revision=UUID.randomUUID();long version=command.expectedVersion()+1;
        db.update("""
                INSERT INTO stock_value_production_cost_revisions(id,execution_segment_id,version,previous_version,
                    source_event_id,source_doc_type,source_doc_id,source_item_id,source_version,actor_user_id,actor_employee_id,
                    occurred_at,idempotency_key,request_hash,request_payload,target_qty_base,output_qty_base,scope_complete,
                    approval_evidence_id,approval_evidence_hash,input_snapshot,output_snapshot)
                VALUES (:id,:segment,:version,:previous,:sourceEvent,:docType,:doc,:item,:sourceVersion,:user,:employee,
                    :at,:key,:hash,CAST(:payload AS jsonb),:target,:outputQty,:complete,:approval,:approvalHash,
                    CAST(:inputs AS jsonb),CAST(:outputs AS jsonb))
                """,args("id",revision,"segment",command.executionSegmentId(),"version",version,"previous",command.expectedVersion(),
                "sourceEvent",c.sourceEventId(),"docType",c.sourceDocType(),"doc",c.sourceDocId(),"item",c.sourceItemId(),"sourceVersion",c.sourceVersion(),
                "user",c.actorUserId(),"employee",c.actorEmployeeId(),"at",c.occurredAt(),"key",c.idempotencyKey(),"hash",request.hash(),"payload",request.json(),
                "target",target,"outputQty",outputQty,"complete",command.scopeComplete(),"approval",command.approvalEvidenceId(),"approvalHash",command.approvalEvidenceHash(),
                "inputs",snapshot.get("inputs").toString(),"outputs",snapshot.get("outputs").toString()));
        boolean invalidBasis=target.signum()>0&&outputQty.compareTo(target)>0;
        db.update("""
                INSERT INTO stock_value_production_cost_tasks(id,revision_id,execution_segment_id,input_node_id,output_source_node_id,
                    input_revision,input_value_local,input_pending,output_from,output_to,denominator,desired_value_local%s)
                SELECT gen_random_uuid(),r.id,r.execution_segment_id,(i->>'node')::uuid,(o->>'source')::uuid,
                    (i->>'revision')::bigint,(i->>'value')::numeric,(i->>'pending')::integer,
                    (o->>'from')::numeric,(o->>'to')::numeric,r.target_qty_base,
                    CASE WHEN r.target_qty_base=0 THEN 0 WHEN r.output_qty_base>r.target_qty_base THEN
                        coalesce((SELECT allocated_value_local FROM stock_value_production_cost_shares
                            WHERE input_node_id=(i->>'node')::uuid AND output_source_node_id=(o->>'source')::uuid),0) ELSE
                        round((i->>'value')::numeric*((i->>'quantityBasis')::numeric-(i->>'returnedQty')::numeric)*(o->>'to')::numeric/(r.target_qty_base*(i->>'quantityBasis')::numeric),4)
                        -round((i->>'value')::numeric*((i->>'quantityBasis')::numeric-(i->>'returnedQty')::numeric)*(o->>'from')::numeric/(r.target_qty_base*(i->>'quantityBasis')::numeric),4) END%s
                FROM stock_value_production_cost_revisions r CROSS JOIN LATERAL jsonb_array_elements(r.input_snapshot) i
                    CROSS JOIN LATERAL jsonb_array_elements(r.output_snapshot) o WHERE r.id=:revision
                """.formatted(consumptionReturnsInstalled?",input_returned_qty,input_quantity_basis,input_return_cursor_id":"",
                    consumptionReturnsInstalled?",(i->>'returnedQty')::numeric,(i->>'quantityBasis')::numeric,(i->>'returnCursor')::uuid":""),args("revision",revision));
        long pending=taskCount(revision);CostState next=pending>0?CostState.APPLYING:invalidBasis?CostState.PENDING_BASIS:
                target.signum()==0?CostState.PENDING_CLASSIFICATION:
                command.scopeComplete()&&outputQty.signum()>0&&inputs.isEmpty()
                    &&"SUBCONTRACT_ORDER_NORMAL_LOSS".equals(object.get("source_kind"))?CostState.FINAL:CostState.PROVISIONAL;
        if(db.update("UPDATE stock_value_production_cost_objects SET version=:version,current_revision_id=:revision,state=:state WHERE execution_segment_id=:segment AND version=:previous",
                args("segment",command.executionSegmentId(),"version",version,"revision",revision,"state",next.name(),"previous",command.expectedVersion()))!=1)
            throw conflict("生产成本方案版本已变化");
        // Clear only the exact observed revisions captured by this plan. A later
        // source update remains dirty and will create the next forward version.
        db.update("""
                UPDATE stock_value_production_cost_dirty d SET cleared_revision=greatest(d.cleared_revision,least(d.observed_revision,(i->>'revision')::bigint))
                FROM stock_value_production_cost_revisions r CROSS JOIN LATERAL jsonb_array_elements(r.input_snapshot) i
                WHERE r.id=:revision AND d.input_node_id=(i->>'node')::uuid
                """,args("revision",revision));
        return new Revised(revision,command.executionSegmentId(),version,pending,next,false);
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public Revised recalculate(EventContext c,UUID segment,long expectedVersion){
        transaction();Map<String,Object> object=object(segment,false);
        Map<String,Object> plan=plan((UUID)object.get("current_revision_id"));Pool pool=poolById((UUID)object.get("product_pool_id"),false);
        return revise(new Revision(c,segment,pool.key(),expectedVersion,(BigDecimal)plan.get("target_qty_base"),
                (Boolean)plan.get("scope_complete"),(UUID)plan.get("approval_evidence_id"),plan.get("approval_evidence_hash").toString(),List.of(),List.of()));
    }

    @Override @Transactional(readOnly=true)
    public List<Work> pendingWork(int limit){
        return db.query("""
                SELECT t.id,t.execution_segment_id,ip.warehouse_id iw,ip.goods_id ig,ip.color_id ic,
                    op.warehouse_id ow,op.goods_id og,op.color_id oc
                FROM stock_value_production_cost_tasks t JOIN stock_value_nodes i ON i.id=t.input_node_id
                JOIN stock_value_pools ip ON ip.id=i.pool_id JOIN stock_value_nodes o ON o.id=t.output_source_node_id
                JOIN stock_value_pools op ON op.id=o.pool_id WHERE t.status='PENDING' ORDER BY t.task_sequence LIMIT :limit
                """,args("limit",Math.max(1,Math.min(limit,100))),(r,i)->new Work(uuid(r,"id"),uuid(r,"execution_segment_id"),
                new PoolKey(uuid(r,"iw"),uuid(r,"ig"),uuid(r,"ic")),new PoolKey(uuid(r,"ow"),uuid(r,"og"),uuid(r,"oc"))));
    }

    @Override @Transactional(readOnly=true)
    public List<Recalculation> pendingRecalculations(int limit){
        return db.query("""
                SELECT DISTINCT ON (d.execution_segment_id) d.execution_segment_id,d.source_event_id,o.version
                FROM stock_value_production_cost_dirty d JOIN stock_value_production_cost_objects o USING(execution_segment_id)
                WHERE d.observed_revision>d.cleared_revision AND o.state<>'APPLYING'
                    AND NOT COALESCE((to_jsonb(o)->>'business_refresh_pending')::boolean,FALSE)
                ORDER BY d.execution_segment_id,d.observed_revision DESC,d.input_node_id LIMIT :limit
                """,args("limit",Math.max(1,Math.min(limit,100))),(r,i)->new Recalculation(uuid(r,"execution_segment_id"),uuid(r,"source_event_id"),r.getLong("version")));
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public Applied apply(UUID taskId){
        transaction();required(taskId,"生产分配任务UUID");Map<String,Object> observed=task(taskId,false);
        Node input=node((UUID)observed.get("input_node_id"),false),output=node((UUID)observed.get("output_source_node_id"),false);
        requireHeld(input.key());requireHeld(output.key());UUID segment=(UUID)observed.get("execution_segment_id");
        Map<String,Object> object=object(segment,true),task=task(taskId,true);
        if("APPLIED".equals(task.get("status")))return new Applied(false,true,!hasTasks((UUID)task.get("revision_id")));
        if(!Objects.equals(task.get("revision_id"),object.get("current_revision_id")))throw conflict("旧分配任务不属于当前执行段成本版本");
        input=node(input.id(),true);output=node(output.id(),true);Map<String,Object> plan=plan((UUID)task.get("revision_id"));
        List<Map<String,Object>> previousShares=db.queryForList("SELECT allocated_value_local,last_task_id FROM stock_value_production_cost_shares WHERE input_node_id=:input AND output_source_node_id=:output",
                args("input",input.id(),"output",output.id()));
        BigDecimal beforeShare=previousShares.isEmpty()?ZERO:(BigDecimal)previousShares.getFirst().get("allocated_value_local");
        UUID previousTaskId=previousShares.isEmpty()?null:(UUID)previousShares.getFirst().get("last_task_id");
        BigDecimal desired=(BigDecimal)task.get("desired_value_local"),delta=desired.subtract(beforeShare),distributed=input.distributed().add(delta);
        if(distributed.signum()<0)throw conflict("生产分配回退超过该来源已分配金额");
        boolean complete=(Boolean)plan.get("scope_complete")&&((BigDecimal)plan.get("target_qty_base")).signum()>0
                &&((BigDecimal)plan.get("output_qty_base")).compareTo((BigDecimal)plan.get("target_qty_base"))<=0
                &&Boolean.TRUE.equals(db.queryForObject("""
                SELECT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(input_snapshot) i WHERE (i->>'pending')::integer>0)
                  AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_tasks WHERE revision_id=:revision
                    AND output_source_node_id=:output AND status='PENDING' AND id<>:task)
                FROM stock_value_production_cost_revisions WHERE id=:revision
                """,args("revision",plan.get("id"),"output",output.id(),"task",taskId),Boolean.class));
        if(complete&&typedScopesInstalled)complete=Boolean.TRUE.equals(db.queryForObject("""
                SELECT NOT EXISTS(SELECT 1 FROM stock_value_production_cost_outputs output
                    JOIN stock_value_production_cost_objects object ON object.execution_segment_id=output.execution_segment_id
                    LEFT JOIN stock_value_production_cost_revisions revision ON revision.id=object.current_revision_id
                    WHERE output.source_node_id=:output AND (revision.id IS NULL OR NOT revision.scope_complete
                        OR revision.target_qty_base<=0 OR revision.output_qty_base>revision.target_qty_base
                        OR object.business_refresh_pending
                        OR EXISTS(SELECT 1 FROM jsonb_array_elements(revision.input_snapshot) source WHERE (source->>'pending')::integer>0)
                        OR EXISTS(SELECT 1 FROM stock_value_production_cost_tasks task WHERE task.revision_id=revision.id
                            AND task.output_source_node_id=:output AND task.status='PENDING' AND task.id<>:task)))
                """,args("output",output.id(),"task",taskId),Boolean.class));
        EventContext c=new EventContext((UUID)plan.get("id"),"PRODUCTION_COST_ALLOCATION",segment,taskId,number(plan,"version"),
                (UUID)plan.get("actor_user_id"),(UUID)plan.get("actor_employee_id"),taskId.toString(),
                ((java.sql.Timestamp)plan.get("occurred_at")).toInstant().atOffset(java.time.ZoneOffset.UTC));
        // The value event owns both sides; any source, proof or CAS failure rolls
        // back the input distribution, target revision, job and share together.
        values.assignProductionCost(taskId,c,input.id(),output.id(),delta,complete,previousTaskId);
        ValueBounds shareBounds=authority.productionDesiredShare(taskId,previousTaskId);
        db.update("""
                INSERT INTO stock_value_production_cost_shares(input_node_id,output_source_node_id,allocated_value_local,last_task_id)
                VALUES (:input,:output,:desired,:task) ON CONFLICT(input_node_id,output_source_node_id) DO UPDATE
                SET allocated_value_local=excluded.allocated_value_local,last_task_id=excluded.last_task_id
                """,args("input",input.id(),"output",output.id(),"desired",desired,"task",taskId));
        if(db.update("UPDATE stock_value_nodes SET distributed_value_local=:after WHERE id=:node AND distributed_value_local=:before",
                args("node",input.id(),"after",distributed,"before",input.distributed()))!=1)throw conflict("在制分配投影已变化");
        db.update("""
                UPDATE stock_value_production_cost_tasks SET status='APPLIED',before_share_local=:share,
                    before_distributed_local=:before,after_distributed_local=:after,value_event_id=:event,
                    previous_task_id=:previous,exact_basis_task_id=:basis,
                    exact_share_lower=:lower,exact_share_upper=:upper,exact_share_scale=:scale WHERE id=:id
                """,args("id",taskId,"share",beforeShare,"before",input.distributed(),"after",distributed,"event",taskId,
                "previous",previousTaskId,"basis",((BigDecimal)plan.get("target_qty_base")).signum()>0
                        &&((BigDecimal)plan.get("output_qty_base")).compareTo((BigDecimal)plan.get("target_qty_base"))>0
                        ?(previousTaskId==null?null:task(previousTaskId,false).get("exact_basis_task_id")):taskId,
                "lower",ValueAuthorityStore.lower(shareBounds),"upper",ValueAuthorityStore.upper(shareBounds),"scale",ValueAuthorityStore.scale(shareBounds)));
        boolean done=!hasTasks((UUID)plan.get("id"));
        if(done){CostState state=((BigDecimal)plan.get("target_qty_base")).signum()==0?CostState.PENDING_CLASSIFICATION:
                    ((BigDecimal)plan.get("output_qty_base")).compareTo((BigDecimal)plan.get("target_qty_base"))>0?CostState.PENDING_BASIS:
                    (Boolean)plan.get("scope_complete")&&Boolean.TRUE.equals(db.queryForObject(
                            "SELECT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(input_snapshot) i WHERE (i->>'pending')::integer>0) FROM stock_value_production_cost_revisions WHERE id=:id",args("id",plan.get("id")),Boolean.class))?CostState.FINAL:CostState.PROVISIONAL;
            db.update("UPDATE stock_value_production_cost_objects SET state=:state WHERE execution_segment_id=:segment AND current_revision_id=:revision",
                    args("segment",segment,"revision",plan.get("id"),"state",state.name()));}
        return new Applied(true,false,done);
    }

    @Override @Transactional(readOnly=true)
    public CostPosition position(UUID segment){
        Map<String,Object> object=object(segment,false),plan=plan((UUID)object.get("current_revision_id"));
        Map<String,Object> amount=db.queryForMap("""
                SELECT coalesce(sum(n.basis_value_local-round(n.basis_value_local*coalesce((to_jsonb(n)->>'returned_consumption_qty')::numeric,0)/n.quantity_basis,4)),0) actual,coalesce(sum(n.distributed_value_local),0) allocated,
                    coalesce(sum(greatest(n.owned_value_local,0)),0) held,coalesce(sum(least(n.owned_value_local,0)),0) adjustment,
                    coalesce(bool_or(n.pending_parents>0),false) unknown
                FROM stock_value_production_cost_inputs i JOIN stock_value_nodes n ON n.id=i.input_node_id WHERE i.execution_segment_id=:segment
                """,args("segment",segment));
        BigDecimal target=(BigDecimal)plan.get("target_qty_base"),held=(BigDecimal)amount.get("held"),adjustment=(BigDecimal)amount.get("adjustment");
        CostState state=CostState.valueOf(object.get("state").toString());
        boolean inFlight=propagationPending()||Boolean.TRUE.equals(object.get("business_refresh_pending"));boolean pending=state!=CostState.FINAL||(Boolean)amount.get("unknown")||inFlight;
        if(state==CostState.FINAL&&pending)state=CostState.APPLYING;
        return new CostPosition(segment,number(object,"version"),target,(BigDecimal)amount.get("actual"),(BigDecimal)amount.get("allocated"),
                target.signum()==0?ZERO:held,adjustment,target.signum()==0?held:ZERO,state,pending);
    }

    private void registerInput(UUID segment,Input input){Node n=node(input.consumedPositionRootId(),false);
        if(!n.active()||!"ISSUE_POSITION".equals(n.kind())||!"COST_WIP".equals(n.ownerKind())||!segment.equals(n.ownerId())
                ||!n.id().equals(n.rootIssueId())||n.from().signum()!=0||n.to().compareTo(n.qty())!=0)
            throw conflict("投入必须是本执行段已确认实耗/正常损耗/加工费的完整成本位置，不能把领退差当实耗");
        db.update("INSERT INTO stock_value_production_cost_inputs(input_node_id,execution_segment_id,approved_posting_id,input_kind) VALUES (:node,:segment,:posting,:kind) ON CONFLICT DO NOTHING",
                args("node",n.id(),"segment",segment,"posting",input.approvedPostingId(),"kind",input.kind().name()));
        if(!Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM stock_value_production_cost_inputs WHERE input_node_id=:node AND execution_segment_id=:segment AND approved_posting_id=:posting AND input_kind=:kind)",
                args("node",n.id(),"segment",segment,"posting",input.approvedPostingId(),"kind",input.kind().name()),Boolean.class)))throw conflict("原耗用posting已经关联不同成本来源");
    }
    private void bindOutput(UUID segment,PoolKey product,Output output){Node n=node(output.finishedSourceNodeId(),false);
        if(!Set.of("SOURCE","RETURN_SOURCE").contains(n.kind())||!output.movementId().equals(n.movementId())||!sameGoods(n.key(),product))throw conflict("产出必须引用本产品确切的已入库来源及movement UUID");
        if(!Boolean.TRUE.equals(db.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM stock_value_production_cost_outputs WHERE source_node_id=:node
                    AND execution_segment_id=:segment AND movement_id=:movement)
                OR EXISTS(SELECT 1 FROM stock_value_nodes n JOIN stock_value_events e ON e.id=n.creation_event_id
                    WHERE n.id=:node AND e.created_txid=txid_current())
                """,args("node",n.id(),"segment",segment,"movement",output.movementId()),Boolean.class)))
            throw conflict("成品执行归属须在原实物入库事务内登记；旧未证来源不能在事后改挂到成本批次");
        db.update("INSERT INTO stock_value_production_cost_outputs(source_node_id,execution_segment_id,movement_id,qty_base) VALUES (:node,:segment,:movement,:qty) ON CONFLICT DO NOTHING",
                args("node",n.id(),"segment",segment,"movement",output.movementId(),"qty",n.qty()));
        if(!Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM stock_value_production_cost_outputs WHERE source_node_id=:node AND execution_segment_id=:segment AND movement_id=:movement)",
                args("node",n.id(),"segment",segment,"movement",output.movementId()),Boolean.class)))throw conflict("该产出来源已经归属其它执行段");
    }
    private Map<String,Object> snapshot(UUID segment){return db.queryForMap("""
            SELECT (SELECT coalesce(jsonb_agg(jsonb_build_object('node',n.id,'revision',n.revision,'value',n.basis_value_local,'pending',n.pending_parents,
                    'returnedQty',coalesce((to_jsonb(n)->>'returned_consumption_qty')::numeric,0),'quantityBasis',n.quantity_basis,
                    'returnCursor',to_jsonb(n)->>'consumption_return_head_id') ORDER BY n.id),'[]'::jsonb)
                FROM stock_value_production_cost_inputs i JOIN stock_value_nodes n ON n.id=i.input_node_id WHERE i.execution_segment_id=:segment) inputs,
                coalesce(jsonb_agg(jsonb_build_object('source',s.source_node_id,'movement',s.movement_id,'qty',s.qty_base,
                    'from',s.through_qty-s.qty_base,'to',s.through_qty) ORDER BY s.output_sequence),'[]'::jsonb) outputs,
                coalesce(sum(s.qty_base),0) output_qty
            FROM (SELECT o.*,sum(qty_base) OVER(ORDER BY output_sequence) through_qty
                FROM stock_value_production_cost_outputs o WHERE execution_segment_id=:segment
                    AND (to_jsonb(o)->>'withdrawn_movement_id') IS NULL) s
            """,args("segment",segment));}
    private Map<String,Object> object(UUID id,boolean lock){List<Map<String,Object>> rows=db.queryForList("SELECT * FROM stock_value_production_cost_objects WHERE execution_segment_id=:id"+(lock?" FOR UPDATE":""),args("id",id));
        if(rows.size()!=1)throw conflict("生产成本对象尚未建立");return rows.getFirst();}
    private Map<String,Object> plan(UUID id){List<Map<String,Object>> rows=db.queryForList("SELECT * FROM stock_value_production_cost_revisions WHERE id=:id",args("id",id));if(rows.size()!=1)throw conflict("生产成本批准方案不存在");return rows.getFirst();}
    private Map<String,Object> task(UUID id,boolean lock){List<Map<String,Object>> rows=db.queryForList("SELECT * FROM stock_value_production_cost_tasks WHERE id=:id"+(lock?" FOR UPDATE":""),args("id",id));if(rows.size()!=1)throw conflict("生产成本分配任务不存在");return rows.getFirst();}
    private long taskCount(UUID revision){return db.queryForObject("SELECT count(*) FROM stock_value_production_cost_tasks WHERE revision_id=:revision AND status='PENDING'",args("revision",revision),Long.class);}
    private boolean hasTasks(UUID revision){return revision!=null&&Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM stock_value_production_cost_tasks WHERE revision_id=:revision AND status='PENDING')",args("revision",revision),Boolean.class));}
    private Map<String,Object> revisionReplay(EventContext c,Request request){List<Map<String,Object>> rows=db.queryForList("SELECT * FROM stock_value_production_cost_revisions WHERE source_item_id=:item AND (source_event_id=:event OR idempotency_key=:key)",args("item",c.sourceItemId(),"event",c.sourceEventId(),"key",c.idempotencyKey()));
        if(rows.isEmpty())return null;if(rows.size()!=1||!request.hash().equals(rows.getFirst().get("request_hash")))throw conflict("同一生产成本请求对应不同版本、来源或分配方案");return rows.getFirst();}
    private Revised revisionResult(Map<String,Object> plan,boolean replayed){long count=taskCount((UUID)plan.get("id"));CostState state=count>0?CostState.APPLYING:
            ((BigDecimal)plan.get("target_qty_base")).signum()==0?CostState.PENDING_CLASSIFICATION:
            ((BigDecimal)plan.get("output_qty_base")).compareTo((BigDecimal)plan.get("target_qty_base"))>0?CostState.PENDING_BASIS:
            (Boolean)plan.get("scope_complete")?CostState.FINAL:CostState.PROVISIONAL;
        return new Revised((UUID)plan.get("id"),(UUID)plan.get("execution_segment_id"),number(plan,"version"),count,state,replayed);}
    private static long number(Map<String,Object> row,String column){return ((Number)row.get(column)).longValue();}
}
