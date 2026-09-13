package com.uten.imp.features.stock.valuation;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.InventoryValuationPort.*;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.ZoneOffset;
import java.time.temporal.ChronoUnit;
import java.util.*;
import static com.uten.imp.features.stock.valuation.ValueMath.*;

/** Package-private fact/projection operations shared by the restricted movement and opening services. */
abstract class InventoryValueLedger {
    private static final ObjectMapper JSON = new ObjectMapper();
    protected final NamedParameterJdbcTemplate db;
    protected final InventoryMutationLock inventoryMutex;
    protected final boolean productionCostInstalled;
    protected final boolean consumptionReturnsInstalled;
    protected final ValueAuthorityStore authority;

    protected InventoryValueLedger(NamedParameterJdbcTemplate db, InventoryMutationLock inventoryMutex) {
        this.db=db;
        this.inventoryMutex=inventoryMutex;
        this.authority=new ValueAuthorityStore(db);
        this.productionCostInstalled=Boolean.TRUE.equals(db.queryForObject(
                "SELECT to_regclass('public.stock_value_production_cost_objects') IS NOT NULL",Map.of(),Boolean.class));
        this.consumptionReturnsInstalled=Boolean.TRUE.equals(db.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=to_regclass('public.stock_value_nodes')
                    AND attname='returned_consumption_qty' AND NOT attisdropped)
                """,Map.of(),Boolean.class));
    }

    protected Pool lockPool(PoolKey key) {
        Pool result=findPool(key,true);
        if(result==null){
            Balance actual=balance(key);
            String status=actual.empty()?"ACTIVE":"LEGACY_UNVERIFIED";
            db.update("""
                    INSERT INTO stock_value_pools(id,warehouse_id,goods_id,color_id,state,legacy_qty,legacy_amount_local)
                    VALUES (:id,:warehouse,:goods,:color,:state,:qty,:amount) ON CONFLICT DO NOTHING
                    """,poolArgs(key,"id",UUID.randomUUID(),"state",status,"qty",actual.empty()?null:actual.qty(),"amount",actual.empty()?null:actual.amount()));
            result=findPool(key,true);
        }
        if(result==null || !"ACTIVE".equals(result.state()))throw conflict("历史期初成本未核定，禁止把旧库存金额作为实际成本；请走受控开账");
        return result;
    }

    protected Node requireBefore(Pool pool, BigDecimal expected) {
        Balance actual=balance(pool.key());
        if(actual.rows()>1 || actual.qty().compareTo(expected)!=0)throw conflict("库存数量已变化，请按锁内最新数量重新提交");
        if(pool.headId()==null){if(!actual.empty())throw conflict("非空库存缺少已核定价值基准");return null;}
        Node head=node(pool.headId(),true);
        if(!head.active() || !"POOL".equals(head.kind()) || head.qty().compareTo(expected)!=0
                || actual.amount()==null || head.value().compareTo(actual.amount())!=0)
            throw conflict("库存数量/已记录金额与价值池不一致，必须先核对");
        return head;
    }

    protected Balance balance(PoolKey key) {
        List<Map<String,Object>> rows=db.queryForList("SELECT qty,amount_local FROM stock_balances WHERE warehouse_id=:warehouse AND goods_id=:goods AND "
                +colorCondition("color_id",key),poolArgs(key));
        if(rows.isEmpty())return new Balance(0,ZERO,ZERO);
        if(rows.size()!=1)throw conflict("库存维度存在重复余额，不能计价");
        return new Balance(1,(BigDecimal)rows.getFirst().get("qty"),(BigDecimal)rows.getFirst().get("amount_local"));
    }

    protected Pool findPool(PoolKey key,boolean lock) {
        List<Pool> rows=db.query("SELECT * FROM stock_value_pools WHERE warehouse_id=:warehouse AND goods_id=:goods AND "
                +colorCondition("color_id",key)+(lock?" FOR UPDATE":""),poolArgs(key),(r,i)->poolRow(r));
        return rows.isEmpty()?null:rows.getFirst();
    }
    protected Pool poolById(UUID id,boolean lock) {
        List<Pool> rows=db.query("SELECT * FROM stock_value_pools WHERE id=:id"+(lock?" FOR UPDATE":""),args("id",id),(r,i)->poolRow(r));
        if(rows.size()!=1)throw conflict("价值库存池不存在"); return rows.getFirst();
    }
    protected static Pool poolRow(ResultSet r)throws SQLException{return new Pool(uuid(r,"id"),new PoolKey(uuid(r,"warehouse_id"),uuid(r,"goods_id"),uuid(r,"color_id")),r.getString("state"),uuid(r,"head_node_id"));}
    protected Node node(UUID id,boolean lock){
        List<Node> rows=db.query("SELECT n.*,p.warehouse_id,p.goods_id,p.color_id FROM stock_value_nodes n JOIN stock_value_pools p ON p.id=n.pool_id WHERE n.id=:id"
                +(lock?" FOR UPDATE OF n":""),args("id",id),(r,i)->nodeRow(r));
        if(rows.size()!=1)throw conflict("价值来源节点不存在");return rows.getFirst();
    }
    protected static Node nodeRow(ResultSet r)throws SQLException{
        return new Node(uuid(r,"id"),uuid(r,"pool_id"),new PoolKey(uuid(r,"warehouse_id"),uuid(r,"goods_id"),uuid(r,"color_id")),
                r.getString("kind"),r.getString("owner_kind"),uuid(r,"owner_id"),uuid(r,"movement_id"),uuid(r,"root_issue_id"),
                r.getBigDecimal("quantity_basis"),r.getBigDecimal("range_from"),r.getBigDecimal("range_to"),r.getBigDecimal("basis_value_local"),
                r.getInt("pending_parents"),r.getLong("revision"),r.getBoolean("active"),r.getBoolean("source_final"),uuid(r,"return_head_id"),uuid(r,"adjustment_head_id"),
                "COST_WIP".equals(r.getString("owner_kind"))?r.getBigDecimal("distributed_value_local"):ZERO,
                hasColumn(r,"returned_consumption_qty")?r.getBigDecimal("returned_consumption_qty"):ZERO,
                hasColumn(r,"consumption_return_head_id")?uuid(r,"consumption_return_head_id"):null,
                hasColumn(r,"bound_lower")&&r.getBigDecimal("bound_lower")!=null&&r.getBigDecimal("bound_upper")!=null&&r.getObject("bound_scale")!=null
                    ?new ValueBounds(r.getBigDecimal("bound_lower"),r.getBigDecimal("bound_upper"),r.getInt("bound_scale")):null,
                hasColumn(r,"bound_revision")?r.getObject("bound_revision",Long.class):null);
    }
    private static boolean hasColumn(ResultSet r,String name)throws SQLException{
        var metadata=r.getMetaData();for(int i=1;i<=metadata.getColumnCount();i++)if(name.equals(metadata.getColumnLabel(i)))return true;return false;
    }

    /** A SOURCE starts with its own separately validated acquisition amount, not input edges. */
    protected Node createSourceNode(Pool pool,UUID movement,BigDecimal qty,BigDecimal value,
                                    int pending,boolean finalValue,UUID event){
        return createSourceNode(UUID.randomUUID(),pool,movement,qty,value,pending,finalValue,event);
    }
    protected Node createSourceNode(UUID id,Pool pool,UUID movement,BigDecimal qty,BigDecimal value,
                                    int pending,boolean finalValue,UUID event){
        return insertNode(id,pool.identity(),"SOURCE",null,null,movement,null,qty,ZERO,ZERO,value,pending,
                false,finalValue,event,null,null);
    }
    protected Node initialSource(Node source,BigDecimal actual){
        authority.initialSource(source.id(),actual);
        return authority.installed?source.withBound(ValueBounds.exact(actual)):source;
    }

    protected record Contribution(Node parent,BigDecimal from,BigDecimal to,BigDecimal denominator){}
    private record PreparedContribution(Contribution input,BigDecimal projected,ValueBounds bound){}
    protected static Contribution whole(Node parent){return new Contribution(parent,ZERO,BigDecimal.ONE,BigDecimal.ONE);}
    protected static Contribution fraction(Node parent,BigDecimal from,BigDecimal to,BigDecimal denominator){
        return new Contribution(parent,from,to,denominator);
    }
    protected static List<Contribution> poolContributions(Node previous,Node incoming){
        return previous==null?List.of(whole(incoming)):List.of(whole(previous),whole(incoming));
    }

    protected Node createDerivedNode(Pool pool,String kind,String ownerKind,UUID ownerId,UUID movement,UUID rootIssue,
                                     BigDecimal qty,BigDecimal from,BigDecimal to,BigDecimal value,int pending,
                                     boolean active,boolean finalValue,UUID event,List<Contribution> inputs){
        return createDerivedNode(UUID.randomUUID(),pool,kind,ownerKind,ownerId,movement,rootIssue,
                qty,from,to,value,pending,active,finalValue,event,inputs);
    }

    /** Immutable location already proved by the caller's current operation. */
    protected Node createDerivedNode(PoolIdentity pool,String kind,String ownerKind,UUID ownerId,UUID movement,UUID rootIssue,
                                     BigDecimal qty,BigDecimal from,BigDecimal to,BigDecimal value,int pending,
                                     boolean active,boolean finalValue,UUID event,List<Contribution> inputs){
        return createDerivedNode(UUID.randomUUID(),pool,kind,ownerKind,ownerId,movement,rootIssue,
                qty,from,to,value,pending,active,finalValue,event,inputs);
    }

    protected Node createDerivedNode(UUID id,Pool pool,String kind,String ownerKind,UUID ownerId,UUID movement,UUID rootIssue,
                                     BigDecimal qty,BigDecimal from,BigDecimal to,BigDecimal value,int pending,
                                     boolean active,boolean finalValue,UUID event,List<Contribution> inputs){
        return createDerivedNode(id,pool.identity(),kind,ownerKind,ownerId,movement,rootIssue,
                qty,from,to,value,pending,active,finalValue,event,inputs);
    }

    /**
     * Compute the entire expression in the established input order, then persist
     * a complete child and every immutable input edge before exposing its Node.
     * There is no partially initialized derived-node API: omitting an input edge
     * cannot be disguised by a broad numerical bound. V517's ALWAYS/deferred
     * expression and lifecycle checks still validate the final facts at commit.
     */
    private Node createDerivedNode(UUID id,PoolIdentity pool,String kind,String ownerKind,UUID ownerId,UUID movement,UUID rootIssue,
                                     BigDecimal qty,BigDecimal from,BigDecimal to,BigDecimal value,int pending,
                                     boolean active,boolean finalValue,UUID event,List<Contribution> inputs){
        if("SOURCE".equals(kind))throw conflict("取得来源必须使用独立的原额初始化入口");
        if(inputs==null||inputs.isEmpty())throw conflict("派生价值节点必须保留完整输入来源");
        List<PreparedContribution> prepared=new ArrayList<>(inputs.size());
        Set<UUID> parents=new HashSet<>();
        ValueBounds total=authority.installed?ValueBounds.exact(ZERO):null;
        for(Contribution input:List.copyOf(inputs)){
            Node parent=Objects.requireNonNull(input.parent(),"value contribution parent");
            if(!parents.add(parent.id()))throw conflict("同一父价值节点不能在一个派生节点中重复分摊");
            ValueBounds parentBound=nodeBound(parent);
            // Unknown remains unknown even for a zero-width interval, matching
            // the original edge semantics and the database's parent-bound guard.
            ValueBounds contribution=parentBound==null?null:parentBound.weighted(
                    input.from(),input.to(),input.denominator(),ValueBounds.DEFAULT_SCALE);
            total=total==null||contribution==null?null:total.add(contribution);
            prepared.add(new PreparedContribution(input,interval(parent.value(),input.from(),input.to(),input.denominator()),contribution));
        }
        UUID returnHead="ISSUE_POSITION".equals(kind)&&id.equals(rootIssue)?id:null;
        Node child=insertNode(id,pool,kind,ownerKind,ownerId,movement,rootIssue,qty,from,to,value,pending,
                active,finalValue,event,total,returnHead);
        // Child must already exist: edge parent/child FKs and the BEFORE sequence
        // and fan-out guard are immediate. Parent order and edge facts stay intact.
        for(PreparedContribution part:prepared)insertEdge(part,child,event);
        return child;
    }

    private Node insertNode(UUID id,PoolIdentity p,String kind,String ownerKind,UUID ownerId,UUID movementId,UUID rootIssueId,
                            BigDecimal qty,BigDecimal from,BigDecimal to,BigDecimal value,int pending,boolean active,
                            boolean finalValue,UUID event,ValueBounds initial,UUID returnHead){
        db.update("""
                INSERT INTO stock_value_nodes(id,pool_id,kind,owner_kind,owner_id,movement_id,root_issue_id,
                    quantity_basis,range_from,range_to,initial_known_value,initial_pending,creation_event_id,
                    basis_value_local,pending_parents,active,source_final,return_head_id%s)
                VALUES (:id,:pool,:kind,:ownerKind,:owner,:movement,:root,:qty,:start,:end,:value,:pending,:event,:value,:pending,:active,:final,:returnHead%s)
                """.formatted(authority.installed?",value_model,initial_bound_lower,initial_bound_upper,bound_lower,bound_upper,initial_bound_scale,bound_scale,bound_revision":"",
                        authority.installed?",'EXACT_SOURCE_SHARES',:lower,:upper,:lower,:upper,:scale,:scale,1":""),
                args("id",id,"pool",p.id(),"kind",kind,"ownerKind",ownerKind,"owner",ownerId,"movement",movementId,"root",rootIssueId,
                "qty",qty,"start",from,"end",to,"value",value,"pending",pending,"event",event,"active",active,"final",finalValue,
                "returnHead",returnHead,"lower",ValueAuthorityStore.lower(initial),"upper",ValueAuthorityStore.upper(initial),"scale",ValueAuthorityStore.scale(initial)));
        return new Node(id,p.id(),p.key(),kind,ownerKind,ownerId,movementId,rootIssueId,qty,from,to,value,pending,1,active,
                finalValue,returnHead,null,ZERO,ZERO,null,initial,authority.installed?1L:null);
    }
    private void insertEdge(PreparedContribution part,Node child,UUID event){
        Contribution input=part.input();Node parent=input.parent();ValueBounds contribution=part.bound();
        db.update("""
                INSERT INTO stock_value_edges(id,parent_node_id,child_node_id,interval_from,interval_to,denominator,
                    creation_event_id,initial_parent_revision,initial_allocated_amount,last_parent_revision,
                    allocated_amount_local,pending_contribution%s)
                VALUES (:id,:parent,:child,:start,:end,:denom,:event,:revision,:amount,:revision,:amount,:pending%s)
                """.formatted(authority.installed?",initial_bound_lower,initial_bound_upper,allocated_bound_lower,allocated_bound_upper,bound_scale,bound_parent_revision":"",
                        authority.installed?",:lower,:upper,:lower,:upper,:scale,:revision":""),
                args("id",UUID.randomUUID(),"parent",parent.id(),"child",child.id(),"start",input.from(),"end",input.to(),"denom",input.denominator(),
                "event",event,"revision",parent.revision(),"amount",part.projected(),
                "pending",parent.pending()>0&&input.to().compareTo(input.from())>0,"lower",ValueAuthorityStore.lower(contribution),
                "upper",ValueAuthorityStore.upper(contribution),"scale",ValueAuthorityStore.scale(contribution)));
    }
    protected Edge edge(UUID id,boolean lock){
        List<Edge> rows=db.query("SELECT * FROM stock_value_edges WHERE id=:id"+(lock?" FOR UPDATE":""),args("id",id),(r,i)->edgeRow(r));
        if(rows.size()!=1)throw conflict("成本分配边不存在");return rows.getFirst();
    }
    protected static Edge edgeRow(ResultSet r)throws SQLException{return new Edge(uuid(r,"id"),uuid(r,"parent_node_id"),uuid(r,"child_node_id"),
            r.getBigDecimal("interval_from"),r.getBigDecimal("interval_to"),r.getBigDecimal("denominator"),r.getLong("last_parent_revision"),
            r.getBigDecimal("allocated_amount_local"),r.getBoolean("pending_contribution"));}
    protected void deactivate(Node node){
        if(db.update("UPDATE stock_value_nodes SET active=false WHERE id=:id AND active",args("id",node.id()))!=1)
            throw conflict("价值位置已经转移，不能重复使用");
    }
    protected void head(Pool pool,UUID head,UUID expected){
        if(db.update("UPDATE stock_value_pools SET head_node_id=:head WHERE id=:id AND head_node_id IS NOT DISTINCT FROM CAST(:before AS uuid)",
                args("id",pool.id(),"head",head,"before",expected))!=1)throw conflict("价值池头已变化");
    }

    protected Node revise(Node before,BigDecimal value,int pending,boolean finalValue,UUID event,UUID task){
        return revise(before,value,pending,finalValue,event,task,task==null?null:authority.edgeChange(before.id(),task));
    }
    protected Node revise(Node before,BigDecimal value,int pending,boolean finalValue,UUID event,UUID task,ValueAuthorityStore.Change exactChange){
        if("POOL".equals(before.kind())&&before.qty().signum()==0&&value.signum()!=0)
            throw conflict("零数量库存不得承接后补价值残留");
        long revision=before.revision()+1;
        boolean exact=authority.installed&&exactChange!=null;
        Map<String,Object> parameters=args("id",before.id(),"revision",revision,"event",event,"task",task,"beforeValue",before.value(),"afterValue",value,
                "beforePending",before.pending(),"afterPending",pending,"beforeFinal",before.sourceFinal(),"afterFinal",finalValue,
                "value",value,"pending",pending,"final",finalValue,"before",before.revision());
        if(exact)parameters.putAll(ValueAuthorityStore.revisionArgs(exactChange));
        // The exact revision fact precedes the node CAS, as required by V517's
        // immutable-source guard. Both representations of this revision are atomic.
        db.update("""
                INSERT INTO stock_value_node_revisions(node_id,revision,event_id,task_id,before_value,after_value,
                    before_pending,after_pending,before_final,after_final%s)
                VALUES (:id,:revision,:event,:task,:beforeValue,:afterValue,:beforePending,:afterPending,:beforeFinal,:afterFinal%s)
                """.formatted(exact?",before_source_amount_exact,after_source_amount_exact,before_bound_lower,before_bound_upper,before_bound_scale,after_bound_lower,after_bound_upper,after_bound_scale":"",
                        exact?",:sourceBefore,:sourceAfter,:beforeLower,:beforeUpper,:beforeScale,:afterLower,:afterUpper,:afterScale":""),parameters);
        if(db.update("""
                UPDATE stock_value_nodes SET basis_value_local=:value,pending_parents=:pending,source_final=:final,revision=:revision%s
                WHERE id=:id AND revision=:before
                """.formatted(exact?",source_amount_exact=:sourceAfter,bound_lower=:afterLower,bound_upper=:afterUpper,bound_scale=:afterScale,bound_revision=:revision":""),parameters)!=1)
            throw conflict("价值节点revision已变化");
        if(productionCostInstalled&&"COST_WIP".equals(before.ownerKind()))db.update("""
                INSERT INTO stock_value_production_cost_dirty(input_node_id,execution_segment_id,source_event_id,observed_revision)
                VALUES (:node,:segment,:event,:revision) ON CONFLICT(input_node_id) DO UPDATE
                SET observed_revision=excluded.observed_revision,source_event_id=excluded.source_event_id
                WHERE stock_value_production_cost_dirty.observed_revision<excluded.observed_revision
                """,args("node",before.id(),"segment",before.ownerId(),"event",event,"revision",revision));
        authority.reviseEdge(exactChange);
        return new Node(before.id(),before.poolId(),before.key(),before.kind(),before.ownerKind(),before.ownerId(),before.movementId(),before.rootIssueId(),
                before.qty(),before.from(),before.to(),value,pending,revision,before.active(),finalValue,before.returnHeadId(),before.adjustmentHeadId(),before.distributed(),before.returnedQty(),before.consumptionReturnHeadId(),
                exact?exactChange.after():before.exactBound(),exact?Long.valueOf(revision):before.boundRevision());
    }
    protected int schedule(Node parent,UUID event){
        List<Edge> edges=db.query("SELECT * FROM stock_value_edges WHERE parent_node_id=:id ORDER BY id",args("id",parent.id()),(r,i)->edgeRow(r));
        if(edges.size()>2)throw conflict("库存核心后继超过有界二分规则");
        int count=0;
        for(Edge e:edges){
            count+=db.update("""
                    INSERT INTO stock_value_tasks(id,event_id,edge_id,parent_revision,target_amount_local,target_pending)
                    VALUES (:id,:event,:edge,:revision,:amount,:pending) ON CONFLICT(edge_id,parent_revision) DO NOTHING
                    """,args("id",UUID.randomUUID(),"event",event,"edge",e.id(),"revision",parent.revision(),
                    "amount",interval(parent.value(),e.from(),e.to(),e.denominator()),"pending",parent.pending()>0&&e.to().compareTo(e.from())>0));
        }
        return count;
    }
    protected void posting(UUID event,UUID task,UUID node,String ownerKind,UUID ownerId,BigDecimal delta){
        if(delta.signum()==0)return;
        db.update("""
                INSERT INTO stock_value_postings(id,event_id,task_id,node_id,owner_kind,owner_id,amount_delta_local)
                VALUES (:id,:event,:task,:node,:kind,:owner,:delta)
                """,args("id",UUID.randomUUID(),"event",event,"task",task,"node",node,"kind",ownerKind,"owner",ownerId,"delta",delta));
    }

    protected void insertEvent(UUID id,String operation,EventContext c,Request request,UUID pool,UUID movement,
                             BigDecimal qty,BigDecimal before,BigDecimal known,UUID result,UUID head,State state,
                             UUID sourceNode,Long sourceRevision,UUID previous,UUID reverses,Boolean beforeFinal,Boolean afterFinal){
        insertEvent(id,operation,c,request,pool,movement,qty,before,known,result,head,state,sourceNode,sourceRevision,previous,reverses,beforeFinal,afterFinal,null);
    }
    protected void insertEvent(UUID id,String operation,EventContext c,Request request,UUID pool,UUID movement,
                             BigDecimal qty,BigDecimal before,BigDecimal known,UUID result,UUID head,State state,
                             UUID sourceNode,Long sourceRevision,UUID previous,UUID reverses,Boolean beforeFinal,Boolean afterFinal,BigDecimal sourceDeltaExact){
        db.update("""
                INSERT INTO stock_value_events(id,operation,source_event_id,source_doc_type,source_doc_id,source_item_id,source_version,
                    actor_user_id,actor_employee_id,occurred_at,idempotency_key,request_hash,request_payload,pool_id,movement_id,
                    qty_base,qty_before,known_value_local,result_node_id,result_head_id,result_state,source_node_id,result_source_revision,
                    previous_adjustment_id,reversal_of_event_id,before_source_final,after_source_final%s)
                VALUES (:id,:op,:sourceEvent,:docType,:doc,:item,:version,:user,:employee,:at,:key,:hash,CAST(:payload AS jsonb),
                    :pool,:movement,:qty,:before,:known,:result,:head,:state,:sourceNode,:sourceRevision,:previous,:reverses,:beforeFinal,:afterFinal%s)
                """.formatted(authority.installed?",source_delta_exact":"",authority.installed?",:sourceDeltaExact":""),args("id",id,"op",operation,"sourceEvent",c.sourceEventId(),"docType",c.sourceDocType(),"doc",c.sourceDocId(),"item",c.sourceItemId(),
                "version",c.sourceVersion(),"user",c.actorUserId(),"employee",c.actorEmployeeId(),"at",c.occurredAt(),"key",c.idempotencyKey(),
                "hash",request.hash(),"payload",request.json(),"pool",pool,"movement",movement,"qty",qty,"before",before,"known",known,
                "result",result,"head",head,"state",state.name(),"sourceNode",sourceNode,"sourceRevision",sourceRevision,"previous",previous,
                "reverses",reverses,"beforeFinal",beforeFinal,"afterFinal",afterFinal,"sourceDeltaExact",sourceDeltaExact));
    }
    protected Event replay(String operation,EventContext c,Request request){
        List<Event> rows=db.query("SELECT * FROM stock_value_events WHERE operation=:op AND source_item_id=:item AND (source_event_id=:event OR idempotency_key=:key)",
                args("op",operation,"event",c.sourceEventId(),"item",c.sourceItemId(),"key",c.idempotencyKey()),(r,i)->eventRow(r));
        if(rows.isEmpty())return null;
        if(rows.size()!=1)throw conflict("来源事件与幂等键指向不同的库存价值动作");
        if(!request.hash().equals(rows.getFirst().hash()))throw conflict("同一幂等键对应不同库存价值请求");
        return rows.getFirst();
    }
    protected Event event(UUID id){
        List<Event> rows=db.query("SELECT * FROM stock_value_events WHERE id=:id",args("id",id),(r,i)->eventRow(r));
        if(rows.size()!=1)throw conflict("原库存价值事件不存在");return rows.getFirst();
    }
    protected static Event eventRow(ResultSet r)throws SQLException{return new Event(uuid(r,"id"),r.getString("operation"),r.getString("request_hash"),
            uuid(r,"movement_id"),r.getBigDecimal("known_value_local"),uuid(r,"result_node_id"),uuid(r,"result_head_id"),State.valueOf(r.getString("result_state")),
            uuid(r,"source_node_id"),uuid(r,"previous_adjustment_id"),r.getBoolean("before_source_final"));}
    protected AdjustmentValue adjustmentReplay(Event event){
        Long pending=db.queryForObject("SELECT pending_tasks FROM stock_value_jobs WHERE event_id=:id",args("id",event.id()),Long.class);
        return new AdjustmentValue(event.id(),event.sourceNodeId(),pending==null?0:pending,true);
    }
    protected boolean jobComplete(UUID event){return Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM stock_value_jobs WHERE event_id=:id AND status='APPLIED')",args("id",event),Boolean.class));}
    protected boolean propagationPending(){
        // Conservative publication fence, indexed and constant-size. It never
        // blocks physical operations and cannot label a distant affected leaf
        // FINAL before its queued ancestors have propagated.
        return Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM stock_value_jobs WHERE status='PENDING')"
                +(productionCostInstalled?" OR EXISTS(SELECT 1 FROM stock_value_production_cost_tasks WHERE status='PENDING') OR EXISTS(SELECT 1 FROM stock_value_production_cost_dirty WHERE observed_revision>cleared_revision)":""),Map.of(),Boolean.class));
    }
    protected State state(Node n){return (effectivePending(n)||propagationPending()
            ||(authority.installed&&nodeBound(n)==null))?State.PENDING:State.FINAL;}
    private ValueBounds nodeBound(Node node){
        if(!authority.installed)return null;
        // This is an explicit value returned by the current operation, not a
        // transaction-wide cache. Legacy/stale bound revisions keep the old lookup.
        return Objects.equals(node.boundRevision(),node.revision())?node.exactBound():
                authority.bound(new com.uten.imp.application.port.InventoryValueAuthorityPort.ValueReference(node.id(),node.revision()));
    }
    protected static boolean effectivePending(Node n){
        if(n.kind().equals("POOL")&&n.qty().signum()==0)return false;
        if(n.kind().equals("ISSUE_POSITION")&&n.from().compareTo(n.to())==0)return false;
        return n.pending()>0;
    }
    protected static BigDecimal owned(Node n){
        if(!n.active())return ZERO;
        if(n.kind().equals("POOL"))return n.value();
        if(n.kind().equals("ISSUE_POSITION"))return interval(n.value(),n.from(),n.to(),n.qty()).subtract(n.distributed())
                .subtract(interval(n.value(),ZERO,n.returnedQty(),n.qty()));
        return ZERO;
    }
    protected static BigDecimal value(Node n){return n==null?ZERO:n.value();}
    protected static int pending(Node n){return n!=null&&n.pending()>0?1:0;}
    protected void requireAdjustable(Node node){
        if(!"SOURCE".equals(node.kind()))throw conflict("只能调整原取得成本或受控开账来源，不能直接改库存池或销售金额");
        boolean opening=node.movementId()==null&&Boolean.TRUE.equals(db.queryForObject(
                "SELECT EXISTS(SELECT 1 FROM stock_value_openings WHERE source_node_id=:id AND observed_qty>0)",args("id",node.id()),Boolean.class));
        boolean acquisition=node.movementId()==null&&!opening&&Boolean.TRUE.equals(db.queryForObject(
                "SELECT to_regclass('public.stock_value_acquisition_sources') IS NOT NULL",Map.of(),Boolean.class))
                &&Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM stock_value_acquisition_sources WHERE source_node_id=:id)",args("id",node.id()),Boolean.class));
        if(node.movementId()==null&&!opening&&!acquisition)
            throw conflict("只能调整原取得成本或受控开账来源，不能直接改库存池或销售金额");
        if(productionCostInstalled&&Boolean.TRUE.equals(db.queryForObject(
                "SELECT EXISTS(SELECT 1 FROM stock_value_production_cost_outputs WHERE source_node_id=:id)",args("id",node.id()),Boolean.class))
                &&!Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM stock_value_acquisition_sources WHERE source_node_id=:id)",args("id",node.id()),Boolean.class)))
            throw conflict("成品成本须由原耗用和费用分配版本调整，不能单边追加金额");
    }

    protected BigDecimal assignedProductionValue(Node source){return productionCostInstalled?db.queryForObject(
            "SELECT coalesce(sum(allocated_value_local),0) FROM stock_value_production_cost_shares WHERE output_source_node_id=:id",args("id",source.id()),BigDecimal.class):ZERO;}
    protected boolean productionScopeAllowsFinal(Node source){return !productionCostInstalled||!Boolean.TRUE.equals(db.queryForObject("""
            SELECT EXISTS(SELECT 1 FROM stock_value_production_cost_outputs o
                JOIN stock_value_production_cost_objects c ON c.execution_segment_id=o.execution_segment_id
                JOIN stock_value_production_cost_revisions r ON r.id=c.current_revision_id
                WHERE o.source_node_id=:id AND NOT r.scope_complete)
            """,args("id",source.id()),Boolean.class));}
    protected BigDecimal sourceAmount(BigDecimal value,String label,boolean negativeAllowed){
        if(!authority.installed)return decimal(value,label,negativeAllowed);
        BigDecimal result=com.uten.imp.common.util.FinancialExactAmount.book(value,label);
        if(!negativeAllowed&&result.signum()<0)throw invalid(label+"不能为负");return result;
    }
    protected BigDecimal projection(BigDecimal exact){return exact.setScale(4,java.math.RoundingMode.HALF_UP);}
    protected String sourceText(BigDecimal exact){return exact.scale()<=4?exact.setScale(4).toPlainString():exact.stripTrailingZeros().toPlainString();}
    protected BigDecimal projectedAmount(BigDecimal value,String label,boolean negativeAllowed){
        if(!authority.installed)return decimal(value,label,negativeAllowed);
        if(value==null||(!negativeAllowed&&value.signum()<0))throw invalid(label+"无效");
        try{return value.setScale(4,java.math.RoundingMode.UNNECESSARY);}catch(ArithmeticException invalidScale){throw invalid(label+"不是四位兼容投影");}
    }

    protected static EventContext context(EventContext c){
        if(c==null)throw invalid("价值来源上下文不能为空");
        required(c.sourceEventId(),"来源事件UUID");required(c.sourceDocId(),"来源单据UUID");required(c.sourceItemId(),"来源明细UUID");
        required(c.actorUserId(),"责任账号UUID");required(c.actorEmployeeId(),"责任员工UUID");
        if(c.sourceVersion()<0||c.sourceDocType()==null||!c.sourceDocType().matches("[A-Z][A-Z0-9_]{0,79}"))throw invalid("价值来源版本或类型无效");
        if(c.idempotencyKey()==null||!c.idempotencyKey().matches("[A-Za-z0-9._:-]{8,160}"))throw invalid("价值幂等键须为8到160位稳定标识");
        if(c.occurredAt()==null)throw invalid("稳定来源发生时间不能为空");
        return new EventContext(c.sourceEventId(),c.sourceDocType(),c.sourceDocId(),c.sourceItemId(),c.sourceVersion(),c.actorUserId(),c.actorEmployeeId(),
                c.idempotencyKey(),c.occurredAt().toInstant().truncatedTo(ChronoUnit.MICROS).atOffset(ZoneOffset.UTC));
    }
    protected static PoolKey key(PoolKey k){if(k==null)throw invalid("库存维度不能为空");required(k.warehouseId(),"仓库UUID");required(k.goodsId(),"货品UUID");return k;}
    protected static void required(UUID value,String field){if(value==null)throw invalid(field+"不能为空");}
    protected static void transaction(){if(!TransactionSynchronizationManager.isActualTransactionActive())throw conflict("库存价值必须在已持库存锁的业务事务内执行");}
    protected void requireHeld(PoolKey key){inventoryMutex.requireHeld(new InventoryKey(key.goodsId(), key.colorId()));}
    protected static boolean sameGoods(PoolKey a,PoolKey b){return a.goodsId().equals(b.goodsId())&&Objects.equals(a.colorId(),b.colorId());}
    protected static String keyText(PoolKey k){return k.warehouseId()+"/"+k.goodsId()+"/"+Objects.toString(k.colorId(),"null");}
    protected static String colorCondition(String column,PoolKey k){return column+(k.colorId()==null?" IS NULL":"=:color");}
    protected static Map<String,Object> poolArgs(PoolKey k,Object...extra){Map<String,Object> p=args(extra);p.put("warehouse",k.warehouseId());p.put("goods",k.goodsId());p.put("color",k.colorId());return p;}
    protected static Map<String,Object> args(Object...values){Map<String,Object> p=new HashMap<>();for(int i=0;i<values.length;i+=2)p.put((String)values[i],values[i+1]);return p;}
    protected static UUID uuid(ResultSet row,String column)throws SQLException{return row.getObject(column,UUID.class);}
    protected static Request request(String operation,EventContext c,Map<String,Object> body){
        Map<String,Object> canonical=new TreeMap<>(body);
        canonical.putAll(args("operation",operation,"sourceEvent",c.sourceEventId(),"sourceDocType",c.sourceDocType(),"sourceDoc",c.sourceDocId(),
                "sourceItem",c.sourceItemId(),"sourceVersion",c.sourceVersion(),"actorUser",c.actorUserId(),"actorEmployee",c.actorEmployeeId(),
                "occurredAt",c.occurredAt().toInstant().toString()));
        try{String json=JSON.writeValueAsString(canonical);String hash=HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(json.getBytes(StandardCharsets.UTF_8)));return new Request(hash,json);}
        catch(JsonProcessingException|NoSuchAlgorithmException e){throw new IllegalStateException(e);}
    }

    /** Identity only: cannot be mistaken for a fresh balance, active state or pool-head lock. */
    protected record PoolIdentity(UUID id,PoolKey key){}
    protected record Pool(UUID id,PoolKey key,String state,UUID headId){
        PoolIdentity identity(){return new PoolIdentity(id,key);}
    }
    protected record Balance(int rows,BigDecimal qty,BigDecimal amount){boolean empty(){return qty.signum()==0&&amount!=null&&amount.signum()==0;}}
    protected record Request(String hash,String json){}
    protected record Node(UUID id,UUID poolId,PoolKey key,String kind,String ownerKind,UUID ownerId,UUID movementId,UUID rootIssueId,
                        BigDecimal qty,BigDecimal from,BigDecimal to,BigDecimal value,int pending,long revision,boolean active,boolean sourceFinal,
                        UUID returnHeadId,UUID adjustmentHeadId,BigDecimal distributed,BigDecimal returnedQty,UUID consumptionReturnHeadId,
                        ValueBounds exactBound,Long boundRevision){
        PoolIdentity poolIdentity(){return new PoolIdentity(poolId,key);}
        Node withBound(ValueBounds bound){return new Node(id,poolId,key,kind,ownerKind,ownerId,movementId,rootIssueId,qty,from,to,value,pending,revision,
                active,sourceFinal,returnHeadId,adjustmentHeadId,distributed,returnedQty,consumptionReturnHeadId,bound,revision);}
    }
    protected record Edge(UUID id,UUID parentId,UUID childId,BigDecimal from,BigDecimal to,BigDecimal denominator,long lastRevision,BigDecimal allocated,boolean pending){}
    protected record Event(UUID id,String operation,String hash,UUID movementId,BigDecimal knownValue,UUID resultNodeId,UUID resultHeadId,State state,
                         UUID sourceNodeId,UUID previousAdjustmentId,boolean beforeFinal){
        MovementValue movement(boolean replayed){return new MovementValue(id,movementId,resultNodeId,resultHeadId,knownValue,state,replayed);}
    }
}
