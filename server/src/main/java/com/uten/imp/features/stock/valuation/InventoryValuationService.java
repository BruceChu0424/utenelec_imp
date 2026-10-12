package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryValuationPort;
import com.uten.imp.features.stock.InventoryMutationLock;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.stock.valuation.ValueMath.*;

/** Actual value movement and bounded late-cost propagation. Physical quantities remain caller-owned. */
@Service
public class InventoryValuationService extends InventoryValueLedger implements InventoryValuationPort {
    public InventoryValuationService(NamedParameterJdbcTemplate db, InventoryMutationLock inventoryMutex) {
        super(db,inventoryMutex);
    }

    void requireUnusedProductionReceipt(PoolKey raw,BigDecimal before,UUID movement){
        PoolKey key=key(raw);requireHeld(key);Pool pool=lockPool(key);Node head=requireBefore(pool,before);
        var originals=db.queryForList("SELECT result_head_id,pool_id FROM stock_value_events WHERE movement_id=:movement AND operation='RECEIVE'",args("movement",movement));
        if(originals.size()!=1||head==null||!pool.id().equals(originals.getFirst().get("pool_id"))
                ||!Boolean.TRUE.equals(db.queryForObject("SELECT fn_stock_value_unused_receipt_head(:current,:original)",
                args("current",head.id(),"original",originals.getFirst().get("result_head_id")),Boolean.class)))
            throw conflict("该成品入库之后已有出库、使用或未撤回的后续入库，不能直接撤回原成本");
    }

    /** Complete only this already-locked physical pool's pending value projection. */
    void synchronizePoolProjection(PoolKey raw){
        PoolKey key=key(raw);requireHeld(key);Pool pool=lockPool(key);
        for(int batch=0;batch<1000;batch++){
            var tasks=db.queryForList("""
                    SELECT task.id FROM stock_value_tasks task
                    JOIN stock_value_edges edge ON edge.id=task.edge_id
                    JOIN stock_value_nodes child ON child.id=edge.child_node_id
                    WHERE child.pool_id=:pool AND task.status='PENDING'
                    ORDER BY task.task_sequence LIMIT 100
                    """,args("pool",pool.id()),UUID.class);
            if(tasks.isEmpty())return;
            boolean progress=false;for(UUID task:tasks)progress|=propagate(task).applied();
            if(!progress)throw conflict("本批成品成本正在等待前序传播，请稍后重试撤回");
        }
        throw conflict("本批成品成本传播尚未完成，请待后台处理后重试撤回");
    }

    /** Costs have already moved back to the original WIP; remove only the exact unused physical receipt. */
    MovementValue reverseUnusedProductionReceipt(EventContext raw,UUID movement,PoolKey rawKey,BigDecimal before,UUID originalMovement){
        transaction();EventContext c=context(raw);PoolKey key=key(rawKey);requireHeld(key);
        Request request=request("POSITION_STORE_REVERSE",c,args("pool",keyText(key),"originalMovement",originalMovement));
        Event prior=replay("POSITION_STORE_REVERSE",c,request);if(prior!=null)return prior.movement(true);
        requireUnusedProductionReceipt(key,before,originalMovement);
        Pool pool=lockPool(key);Node current=requireBefore(pool,before);
        var original=db.queryForMap("SELECT * FROM stock_value_events WHERE movement_id=:movement AND operation='RECEIVE'",args("movement",originalMovement));
        Node source=node((UUID)original.get("result_node_id"),true),originalHead=node((UUID)original.get("result_head_id"),false);
        if(source.value().signum()!=0||Boolean.TRUE.equals(db.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM stock_value_production_cost_shares WHERE output_source_node_id=:source AND allocated_value_local<>0)
                    OR EXISTS(SELECT 1 FROM stock_value_production_cost_tasks WHERE output_source_node_id=:source AND status='PENDING')
                """,args("source",source.id()),Boolean.class)))throw conflict("成品已分配成本尚未完整回到原在制来源");
        var predecessors=db.queryForList("SELECT parent.id FROM stock_value_edges edge JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id WHERE edge.child_node_id=:head AND parent.kind='POOL'",
                args("head",originalHead.id()),UUID.class);
        if(predecessors.size()>1)throw conflict("成品原入库前置库存归属不唯一");
        Node predecessor=predecessors.isEmpty()?null:node(predecessors.getFirst(),false);
        BigDecimal qty=(BigDecimal)original.get("qty_base"),left=predecessor==null?ZERO:predecessor.qty();
        if(before.compareTo(originalHead.qty())!=0||before.subtract(qty).compareTo(left)!=0||current.value().compareTo(value(predecessor))!=0)
            throw conflict("成品撤回的原数量、成本传播或前置库存余额不一致");
        UUID event=UUID.randomUUID();
        Node archived=createDerivedNode(pool,"REVERSED_POOL_CURSOR",null,null,null,null,current.qty(),ZERO,current.qty(),current.value(),
                pending(current),true,true,event,List.of(whole(current)));
        Node next=createDerivedNode(pool,"POOL",null,null,null,null,left,ZERO,left,value(predecessor),pending(predecessor),true,true,event,
                List.of(predecessor==null?fraction(current,ZERO,ZERO,current.qty()):whole(predecessor)));
        deactivate(current);head(pool,next.id(),pool.headId());
        db.update("""
                INSERT INTO stock_value_events(id,operation,source_event_id,source_doc_type,source_doc_id,source_item_id,source_version,
                    actor_user_id,actor_employee_id,occurred_at,idempotency_key,request_hash,request_payload,pool_id,movement_id,
                    qty_base,qty_before,known_value_local,result_node_id,result_head_id,result_state,source_node_id,result_source_revision,position_store_reversal_of)
                VALUES(:id,'POSITION_STORE_REVERSE',:sourceEvent,:docType,:doc,:item,:version,:user,:employee,:at,:key,:hash,CAST(:payload AS jsonb),
                    :pool,:movement,:qty,:before,0,:result,:head,:state,:source,:revision,:original)
                """,args("id",event,"sourceEvent",c.sourceEventId(),"docType",c.sourceDocType(),"doc",c.sourceDocId(),"item",c.sourceItemId(),"version",c.sourceVersion(),
                "user",c.actorUserId(),"employee",c.actorEmployeeId(),"at",c.occurredAt(),"key",c.idempotencyKey(),"hash",request.hash(),"payload",request.json(),
                "pool",pool.id(),"movement",movement,"qty",qty,"before",before,"result",archived.id(),"head",next.id(),"state",state(source).name(),
                "source",source.id(),"revision",source.revision(),"original",original.get("id")));
        return new MovementValue(event,movement,archived.id(),next.id(),ZERO,state(source),false);
    }

    /** Withdraw the same unused SOURCE contribution; never reprice it from today's pool. */
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public MovementValue reverseReceive(ReverseReceive command){
        transaction();EventContext c=context(command.context());PoolKey key=key(command.pool());requireHeld(key);
        required(command.movementId(),"反向流水UUID");required(command.originalMovementId(),"原入库流水UUID");
        BigDecimal before=decimal(command.expectedQtyBefore(),"原库存基本量",false);
        Request request=request("POSITION_STORE_REVERSE",c,args("pool",keyText(key),"originalMovement",command.originalMovementId()));
        Event replay=replay("POSITION_STORE_REVERSE",c,request);if(replay!=null)return replay.movement(true);
        Pool pool=lockPool(key);Node current=requireBefore(pool,before);
        ReceiveWithdrawal plan=prepareReceiveWithdrawal(pool,current,before,command.originalMovementId(),c,true);
        var original=plan.original();Node source=plan.source(),previous=plan.previous();
        BigDecimal qty=plan.qty(),left=plan.left(),cost=plan.cost();
        UUID event=UUID.randomUUID();
        Node archived=createDerivedNode(pool,"REVERSED_POOL_CURSOR",null,null,null,null,current.qty(),ZERO,current.qty(),current.value(),pending(current),true,true,event,List.of(whole(current)));
        Node next=createDerivedNode(pool,"POOL",null,null,null,null,left,ZERO,left,value(previous),pending(previous),true,true,event,
            List.of(previous==null?fraction(current,ZERO,ZERO,current.qty()):whole(previous)));
        deactivate(current);head(pool,next.id(),pool.headId());
        db.update("""
            INSERT INTO stock_value_events(id,operation,source_event_id,source_doc_type,source_doc_id,source_item_id,source_version,
              actor_user_id,actor_employee_id,occurred_at,idempotency_key,request_hash,request_payload,pool_id,movement_id,
              qty_base,qty_before,known_value_local,result_node_id,result_head_id,result_state,source_node_id,result_source_revision,position_store_reversal_of)
            VALUES(:id,'POSITION_STORE_REVERSE',:sourceEvent,:docType,:doc,:item,:version,:user,:employee,:at,:key,:hash,CAST(:payload AS jsonb),
              :pool,:movement,:qty,:before,:cost,:result,:head,:state,:source,:revision,:original)
            """,args("id",event,"sourceEvent",c.sourceEventId(),"docType",c.sourceDocType(),"doc",c.sourceDocId(),"item",c.sourceItemId(),"version",c.sourceVersion(),
              "user",c.actorUserId(),"employee",c.actorEmployeeId(),"at",c.occurredAt(),"key",c.idempotencyKey(),"hash",request.hash(),"payload",request.json(),
              "pool",pool.id(),"movement",command.movementId(),"qty",qty,"before",before,"cost",cost,"result",archived.id(),"head",next.id(),"state",state(source).name(),
              "source",source.id(),"revision",source.revision(),"original",original.get("id")));
        posting(event,null,current.id(),"INVENTORY",pool.id(),cost.negate());
        posting(event,null,source.id(),"SOURCE",(UUID)original.get("source_event_id"),cost);
        return new MovementValue(event,command.movementId(),archived.id(),next.id(),cost,state(source),false);
    }

    @Override @Transactional(propagation = Propagation.MANDATORY)
    public MovementValue receive(Receive command) {
        transaction();
        EventContext c = context(command.context()); PoolKey key = key(command.pool());
        requireHeld(key);
        required(command.movementId(), "库存流水UUID");
        BigDecimal qty = positive(command.qtyBase(), "本次基本数量");
        BigDecimal before = decimal(command.expectedQtyBefore(), "前置库存数量", false);
        if (command.knownCostLocal() == null && command.costFinal()) throw invalid("缺少来源成本，不能标为最终成本");
        BigDecimal actualCost=command.knownCostLocal()==null?ZERO:sourceAmount(command.knownCostLocal(),"已确认成本原额",false);
        BigDecimal cost = projection(actualCost);
        Request request = request("RECEIVE", c, args("pool", keyText(key), "qty", qty.toPlainString(),
                "knownCost", command.knownCostLocal() == null ? null : sourceText(actualCost), "final", command.costFinal()));
        Event prior = replay("RECEIVE", c, request); if (prior != null) return prior.movement(true);
        Pool pool = lockPool(key);
        prior = replay("RECEIVE", c, request); if (prior != null) return prior.movement(true);
        Node head = requireBefore(pool, before);
        UUID eventId = UUID.randomUUID();
        Node source = createSourceNode(pool,command.movementId(),qty,cost,command.costFinal()?0:1,command.costFinal(),eventId);
        source=initialSource(source,actualCost);
        Node next = createDerivedNode(pool,"POOL",null,null,null,null,before.add(qty),ZERO,before.add(qty),value(head).add(cost),
                pending(head)+pending(source),true,true,eventId,poolContributions(head,source));
        if(head!=null)deactivate(head);
        head(pool, next.id(), pool.headId());
        State state = state(next);
        insertEvent(eventId, "RECEIVE", c, request, pool.id(), command.movementId(), qty, before,
                cost, source.id(), next.id(), state, null, null, null, null, null, null);
        posting(eventId, null, source.id(), "SOURCE", c.sourceEventId(), cost.negate());
        posting(eventId, null, next.id(), "INVENTORY", pool.id(), cost);
        return new MovementValue(eventId, command.movementId(), source.id(), next.id(), cost, state, false);
    }

    @Override @Transactional(propagation = Propagation.MANDATORY)
    public MovementValue issue(Issue command) {
        transaction();
        EventContext c = context(command.context()); PoolKey key = key(command.pool());
        requireHeld(key);
        required(command.movementId(), "库存流水UUID"); required(command.destinationId(), "价值去向UUID");
        if (command.destinationKind() == null) throw invalid("价值去向类型不能为空");
        BigDecimal qty = positive(command.qtyBase(), "本次基本数量");
        BigDecimal before = decimal(command.expectedQtyBefore(), "前置库存数量", false);
        Request request = request("ISSUE", c, args("pool", keyText(key), "qty", qty.toPlainString(),
                "destination", command.destinationKind().name(), "destinationId", command.destinationId()));
        Event prior = replay("ISSUE", c, request); if (prior != null) return prior.movement(true);
        Pool pool = lockPool(key);
        prior = replay("ISSUE", c, request); if (prior != null) return prior.movement(true);
        Node old = requireBefore(pool, before);
        if (old == null || qty.compareTo(before) > 0) throw conflict("库存数量不足以冻结本次出库成本");
        BigDecimal cost = interval(old.value(), ZERO, qty, before);
        UUID eventId = UUID.randomUUID(), issueId = UUID.randomUUID();
        Node issue = createDerivedNode(issueId,pool,"ISSUE_POSITION",command.destinationKind().name(),command.destinationId(),
                command.movementId(),issueId,qty,ZERO,qty,cost,pending(old),true,true,eventId,List.of(fraction(old,ZERO,qty,before)));
        BigDecimal left = before.subtract(qty);
        Node next = createDerivedNode(pool,"POOL",null,null,null,null,left,ZERO,left,old.value().subtract(cost),
                left.signum()==0?0:pending(old),true,true,eventId,List.of(fraction(old,qty,before,before)));
        deactivate(old); head(pool, next.id(), pool.headId());
        State state = state(issue);
        insertEvent(eventId, "ISSUE", c, request, pool.id(), command.movementId(), qty, before,
                cost, issue.id(), next.id(), state, null, null, null, null, null, null);
        posting(eventId, null, old.id(), "INVENTORY", pool.id(), cost.negate());
        posting(eventId, null, issue.id(), issue.ownerKind(), issue.ownerId(), cost);
        return new MovementValue(eventId, command.movementId(), issue.id(), next.id(), cost, state, false);
    }

    @Override @Transactional(propagation = Propagation.MANDATORY)
    public MovementValue returnIssue(ReturnIssue command) {
        transaction();
        EventContext c = context(command.context()); PoolKey target = key(command.pool());
        requireHeld(target);
        required(command.movementId(), "库存流水UUID"); required(command.originalIssueNodeId(), "原出库价值UUID");
        BigDecimal qty = positive(command.qtyBase(), "本次退回基本数量");
        BigDecimal before = decimal(command.expectedQtyBefore(), "前置库存数量", false);
        Request request = request("RETURN_ISSUE", c, args("pool", keyText(target), "qty", qty.toPlainString(),
                "originalIssue", command.originalIssueNodeId()));
        Event prior = replay("RETURN_ISSUE", c, request); if (prior != null) return prior.movement(true);
        Pool pool = lockPool(target);
        prior = replay("RETURN_ISSUE", c, request); if (prior != null) return prior.movement(true);
        Node inventory = requireBefore(pool, before);
        IssueRemainder original=prepareIssueReturn(target,command.originalIssueNodeId(),qty,true);
        Node root=original.root(),remaining=original.remaining();
        BigDecimal through = remaining.from().add(qty);
        BigDecimal cost = interval(remaining.value(), remaining.from(), through, remaining.qty());
        UUID eventId = UUID.randomUUID();
        Node returned = createDerivedNode(pool,"RETURN_SOURCE",null,null,command.movementId(),root.id(),qty,ZERO,ZERO,cost,
                pending(remaining),false,true,eventId,List.of(fraction(remaining,remaining.from(),through,remaining.qty())));
        // Carry the ORIGINAL basis along the remainder chain. Its owned range
        // shrinks; this is not a second asset. Exact cumulative return intervals
        // avoid re-averaging an already rounded remainder (e.g. 0.0002 / 3).
        Node nextRemainder = createDerivedNode(remaining.poolIdentity(),"ISSUE_POSITION",
                remaining.ownerKind(),remaining.ownerId(),null,root.id(),remaining.qty(),through,remaining.to(),
                remaining.value(),pending(remaining),true,true,eventId,List.of(whole(remaining)));
        deactivate(remaining);
        db.update("UPDATE stock_value_nodes SET return_head_id=:head WHERE id=:id", args("head", nextRemainder.id(), "id", root.id()));
        Node next = createDerivedNode(pool,"POOL",null,null,null,null,before.add(qty),ZERO,before.add(qty),
                value(inventory).add(cost),pending(inventory)+pending(returned),true,true,eventId,poolContributions(inventory,returned));
        if(inventory!=null)deactivate(inventory);
        head(pool, next.id(), pool.headId());
        State state = state(returned);
        insertEvent(eventId, "RETURN_ISSUE", c, request, pool.id(), command.movementId(), qty, before,
                cost, returned.id(), next.id(), state, root.id(), null, null, null, null, null);
        posting(eventId, null, remaining.id(), remaining.ownerKind(), remaining.ownerId(), cost.negate());
        posting(eventId, null, next.id(), "INVENTORY", pool.id(), cost);
        return new MovementValue(eventId, command.movementId(), returned.id(), next.id(), cost, state, false);
    }

    private record IssueRemainder(Node root,Node remaining) {}
    private IssueRemainder prepareIssueReturn(PoolKey target,UUID rootId,BigDecimal qty,boolean lock){
        Node root=node(rootId,lock);
        if(!"ISSUE_POSITION".equals(root.kind()) || !root.id().equals(root.rootIssueId())
                || root.movementId()==null || root.returnHeadId()==null || !sameGoods(root.key(),target))
            throw conflict("退回必须引用同货品、同颜色的原出库价值切片");
        Node remaining=node(root.returnHeadId(),lock);
        if(!remaining.active() || !Objects.equals(remaining.rootIssueId(),root.id())
                || !"ISSUE_POSITION".equals(remaining.kind())
                || qty.compareTo(remaining.to().subtract(remaining.from()))>0)
            throw conflict("退回数量超过原出库尚可退回数量");
        return new IssueRemainder(root,remaining);
    }

    private record ReceiveWithdrawal(Map<String,Object> original,Node source,Node previous,
                                     BigDecimal qty,BigDecimal left,BigDecimal cost) {}
    private ReceiveWithdrawal prepareReceiveWithdrawal(Pool pool,Node current,BigDecimal before,
                                                        UUID movement,EventContext context,boolean lock){
        var originals=db.queryForList("SELECT * FROM stock_value_events WHERE movement_id=:movement AND operation='RECEIVE'",args("movement",movement));
        if(originals.size()!=1 || current==null)throw conflict("原入库没有唯一已核定成本来源，不能猜测撤回");
        var original=originals.getFirst();
        if(!pool.id().equals(original.get("pool_id")) || context!=null &&
                (!Objects.equals(context.sourceDocType(),original.get("source_doc_type"))
                    || !Objects.equals(context.sourceDocId(),original.get("source_doc_id"))
                    || !Objects.equals(context.sourceItemId(),original.get("source_item_id"))))
            throw conflict("反向库存与原入库来源不一致");
        if(!Boolean.TRUE.equals(db.queryForObject("SELECT fn_stock_value_unused_receipt_head(:current,:original)",
                args("current",current.id(),"original",original.get("result_head_id")),Boolean.class)))
            throw conflict("原入库之后已有出库、使用或未撤回的后续入库，请先处理下游原成本");
        Node source=node((UUID)original.get("result_node_id"),lock),originalHead=node((UUID)original.get("result_head_id"),false);
        if(!"SOURCE".equals(source.kind()) || Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM stock_value_production_cost_outputs WHERE source_node_id=:source)",args("source",source.id()),Boolean.class)))
            throw conflict("此入库成本属于专用生产来源，不能通过通用库存反审");
        if(Boolean.TRUE.equals(db.queryForObject("""
                WITH RECURSIVE descendants(id) AS (
                    SELECT CAST(:source AS UUID) UNION
                    SELECT edge.child_node_id FROM stock_value_edges edge JOIN descendants parent ON parent.id=edge.parent_node_id
                    WHERE edge.interval_to>edge.interval_from)
                SELECT EXISTS(SELECT 1 FROM descendants child JOIN stock_value_nodes node ON node.id=child.id
                    WHERE node.kind='ISSUE_POSITION')
                """,args("source",source.id()),Boolean.class)))
            throw conflict("原入库已承接出库成本历史，即使数量已退回也不能直接抹去原取得来源");
        var predecessors=db.queryForList("SELECT parent.id FROM stock_value_edges edge JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id WHERE edge.child_node_id=:head AND parent.kind='POOL'",
                args("head",originalHead.id()),UUID.class);
        if(predecessors.size()>1)throw conflict("原入库前置库存来源不唯一");
        Node previous=predecessors.isEmpty()?null:node(predecessors.getFirst(),false);
        BigDecimal qty=(BigDecimal)original.get("qty_base"),left=previous==null?ZERO:previous.qty(),cost=source.value();
        if(before.compareTo(originalHead.qty())!=0 || before.subtract(qty).compareTo(left)!=0
                || current.value().compareTo(value(previous).add(cost))!=0)
            throw conflict("原实物、成本传播与前置库存不守恒，请核对后撤回");
        return new ReceiveWithdrawal(original,source,previous,qty,left,cost);
    }

    private Pool readActivePool(PoolKey key){
        Pool pool=findPool(key,false);
        if(pool==null && balance(key).empty())return new Pool(null,key,"ACTIVE",null);
        if(pool==null || !"ACTIVE".equals(pool.state()))throw conflict("库存缺少已核定成本池，请核对历史期初");
        return pool;
    }

    @Override @Transactional(readOnly=true,noRollbackFor=com.uten.imp.common.web.ApiException.class)
    public String requireIssueReturnsAvailable(List<IssueReturnSource> sources){
        if(sources==null || sources.size()>1000)throw invalid("原出库退回核对范围无效");
        Map<UUID,BigDecimal> cumulative=new HashMap<>();List<String> facts=new ArrayList<>();
        for(IssueReturnSource source:sources){
            if(source==null)throw invalid("原出库流水不能为空");
            PoolKey key=key(source.pool());required(source.originalMovementId(),"原出库流水UUID");
            BigDecimal qty=positive(source.qtyBase(),"本次退回基本数量");Pool pool=readActivePool(key);
            Node inventory=requireBefore(pool,balance(key).qty(),false);
            var roots=db.queryForList("SELECT event.result_node_id FROM stock_value_events event JOIN stock_value_nodes node ON node.id=event.result_node_id WHERE event.movement_id=:movement AND node.kind='ISSUE_POSITION' AND node.root_issue_id=node.id AND (event.operation='ISSUE' OR event.operation='POSITION_STORE_REVERSE' AND EXISTS(SELECT 1 FROM stock_value_events original WHERE original.id=event.position_store_reversal_of AND original.operation='RETURN_ISSUE'))",args("movement",source.originalMovementId()),UUID.class);
            if(roots.size()!=1)throw conflict("原出库没有唯一实际成本切片，不能猜测退回");
            BigDecimal total=cumulative.merge(roots.getFirst(),qty,BigDecimal::add);
            IssueRemainder original=prepareIssueReturn(key,roots.getFirst(),total,false);
            facts.add(keyText(key));facts.add(String.valueOf(inventory));facts.add(source.toString());facts.add(original.toString());
        }
        return com.uten.imp.common.util.CanonicalFingerprint.sha256(facts);
    }

    @Override @Transactional(readOnly=true,noRollbackFor=com.uten.imp.common.web.ApiException.class)
    public String requireReceivesReversible(List<ReceiveWithdrawalSource> sources){
        if(sources==null || sources.size()>1000)throw invalid("原入库撤回核对范围无效");
        Map<PoolKey,Node> cursors=new HashMap<>();Set<PoolKey> initialized=new HashSet<>();
        Set<UUID> seen=new HashSet<>();List<String> facts=new ArrayList<>();
        for(ReceiveWithdrawalSource source:sources){
            if(source==null)throw invalid("原入库流水不能为空");
            PoolKey key=key(source.pool());required(source.originalMovementId(),"原入库流水UUID");
            if(!seen.add(source.originalMovementId()))throw invalid("原入库流水不能重复");
            Pool pool=readActivePool(key);Node current;
            if(initialized.add(key)){current=requireBefore(pool,balance(key).qty(),false);cursors.put(key,current);}
            else current=cursors.get(key);
            ReceiveWithdrawal plan=prepareReceiveWithdrawal(pool,current,current==null?ZERO:current.qty(),source.originalMovementId(),null,false);
            facts.add(keyText(key));facts.add(String.valueOf(current));facts.add(source.toString());
            facts.add(plan.source().toString());facts.add(String.valueOf(plan.previous()));
            cursors.put(key,plan.previous());
        }
        return com.uten.imp.common.util.CanonicalFingerprint.sha256(facts);
    }

    private record TransferWithdrawal(Map<String,Object> original,Node source,Node previous,Node originalIssue,
                                      BigDecimal qty,BigDecimal left,BigDecimal cost) {}
    private TransferWithdrawal prepareTransferWithdrawal(Pool pool,Node current,BigDecimal before,UUID movement,EventContext context,boolean lock){
        var rows=db.queryForList("SELECT * FROM stock_value_events WHERE movement_id=:movement AND operation='RETURN_ISSUE'",args("movement",movement));
        if(rows.size()!=1 || current==null)throw conflict("调入缺少唯一原实际成本来源，不能猜测撤回");
        var original=rows.getFirst();
        if(!pool.id().equals(original.get("pool_id")) || !"STOCK_DOC".equals(original.get("source_doc_type"))
                || context!=null && (!Objects.equals(context.sourceDocId(),original.get("source_doc_id")) || !Objects.equals(context.sourceItemId(),original.get("source_item_id"))))
            throw conflict("调拨反向必须引用原同仓、同单、同明细的调入来源");
        if(!Boolean.TRUE.equals(db.queryForObject("SELECT fn_stock_value_unused_receipt_head(:current,:original)",args("current",current.id(),"original",original.get("result_head_id")),Boolean.class)))
            throw conflict("调入之后已有出库或未撤回的后续入库，请按来源先处理下游");
        Node source=node((UUID)original.get("result_node_id"),lock),originalHead=node((UUID)original.get("result_head_id"),false);
        Node issue=node((UUID)original.get("source_node_id"),lock);
        if(!"RETURN_SOURCE".equals(source.kind()) || !"ISSUE_POSITION".equals(issue.kind()) || !issue.id().equals(issue.rootIssueId())
                || !Objects.equals(source.rootIssueId(),issue.id()) || !sameGoods(source.key(),issue.key()) || !sameGoods(source.key(),pool.key()))
            throw conflict("调入与原调出实际成本切片归属不一致");
        if(!Boolean.TRUE.equals(db.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM stock_documents doc JOIN stock_document_items item ON item.doc_id=doc.id
                    JOIN stock_movements incoming ON incoming.id=:movement JOIN stock_movements outgoing ON outgoing.id=:outgoing
                    WHERE doc.id=:doc AND item.id=:item AND doc.doc_type='TRANSFER' AND NOT fn_is_production_linked_stock_document(doc.id)
                        AND incoming.source_doc_id=doc.id AND outgoing.source_doc_id=doc.id AND incoming.source_item_id=item.id AND outgoing.source_item_id=item.id
                        AND incoming.movement_type=7 AND incoming.direction=1 AND outgoing.movement_type=8 AND outgoing.direction=-1
                        AND incoming.warehouse_id=doc.to_warehouse_id AND outgoing.warehouse_id=doc.warehouse_id
                        AND incoming.qty=outgoing.qty AND incoming.goods_id=outgoing.goods_id AND incoming.color_id IS NOT DISTINCT FROM outgoing.color_id)
                """,args("movement",movement,"outgoing",issue.movementId(),"doc",original.get("source_doc_id"),"item",original.get("source_item_id")),Boolean.class)))
            throw conflict("调拨两仓的原实物流水、数量或来源不匹配");
        if(Boolean.TRUE.equals(db.queryForObject("""
                WITH RECURSIVE descendants(id) AS (SELECT CAST(:source AS UUID) UNION
                    SELECT edge.child_node_id FROM stock_value_edges edge JOIN descendants parent ON parent.id=edge.parent_node_id WHERE edge.interval_to>edge.interval_from)
                SELECT EXISTS(SELECT 1 FROM descendants child JOIN stock_value_nodes node ON node.id=child.id WHERE node.kind='ISSUE_POSITION')
                """,args("source",source.id()),Boolean.class)))throw conflict("原调入已承接出库成本历史，不能借其它库存撤回调拨");
        var predecessors=db.queryForList("SELECT parent.id FROM stock_value_edges edge JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id WHERE edge.child_node_id=:head AND parent.kind='POOL'",args("head",originalHead.id()),UUID.class);
        if(predecessors.size()>1)throw conflict("原调入前置库存来源不唯一");
        Node previous=predecessors.isEmpty()?null:node(predecessors.getFirst(),false);
        BigDecimal qty=(BigDecimal)original.get("qty_base"),left=previous==null?ZERO:previous.qty(),cost=source.value();
        if(before.compareTo(originalHead.qty())!=0 || before.subtract(qty).compareTo(left)!=0 || current.value().compareTo(value(previous).add(cost))!=0)
            throw conflict("原调入的数量、成本与前置库存不守恒，请核对后撤回");
        return new TransferWithdrawal(original,source,previous,issue,qty,left,cost);
    }

    @Override @Transactional(readOnly=true,noRollbackFor=com.uten.imp.common.web.ApiException.class)
    public String requireTransfersReversible(List<TransferWithdrawalSource> sources){
        if(sources==null || sources.size()>1000)throw invalid("调拨反向核对范围无效");
        Map<PoolKey,Node> cursors=new HashMap<>();Set<PoolKey> initialized=new HashSet<>();Set<UUID> seen=new HashSet<>();List<String> facts=new ArrayList<>();
        for(TransferWithdrawalSource source:sources){
            if(source==null)throw invalid("原调拨两腿流水不能为空");required(source.originalInMovementId(),"原调入流水UUID");required(source.originalOutMovementId(),"原调出流水UUID");
            if(!seen.add(source.originalInMovementId()))throw invalid("原调入流水不能重复");
            PoolKey key=key(source.targetPool()),origin=key(source.sourcePool());Pool pool=readActivePool(key),sourcePool=readActivePool(origin);
            Node sourceHead=requireBefore(sourcePool,balance(origin).qty(),false),current;
            if(initialized.add(key)){current=requireBefore(pool,balance(key).qty(),false);cursors.put(key,current);}else current=cursors.get(key);
            TransferWithdrawal plan=prepareTransferWithdrawal(pool,current,current==null?ZERO:current.qty(),source.originalInMovementId(),null,false);
            if(!plan.originalIssue().key().equals(origin) || !Objects.equals(plan.originalIssue().movementId(),source.originalOutMovementId()))throw conflict("原调出仓库或流水不属于同一调拨");
            facts.add(source.toString());facts.add(String.valueOf(current));facts.add(String.valueOf(sourceHead));facts.add(plan.source().toString());facts.add(String.valueOf(plan.previous()));
            cursors.put(key,plan.previous());
        }
        return com.uten.imp.common.util.CanonicalFingerprint.sha256(facts);
    }

    /** Withdraw this unused transferred contribution into its own IN_TRANSIT issue; the source warehouse then returns exactly that issue. */
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public MovementValue reverseTransferIn(ReverseTransferIn command){
        transaction();EventContext context=context(command.context());PoolKey key=key(command.pool());requireHeld(key);
        required(command.movementId(),"反向调入流水UUID");required(command.originalMovementId(),"原调入流水UUID");
        BigDecimal before=decimal(command.expectedQtyBefore(),"调入仓前置数量",false);
        Request request=request("POSITION_STORE_REVERSE",context,args("pool",keyText(key),"originalTransferIn",command.originalMovementId()));
        Event prior=replay("POSITION_STORE_REVERSE",context,request);if(prior!=null)return prior.movement(true);
        Pool pool=lockPool(key);Node current=requireBefore(pool,before);TransferWithdrawal plan=prepareTransferWithdrawal(pool,current,before,command.originalMovementId(),context,true);
        UUID event=UUID.randomUUID(),issueId=UUID.randomUUID();Node retained=retainValueReference(plan.source(),event);
        createDerivedNode(pool,"REVERSED_POOL_CURSOR",null,null,null,null,current.qty(),ZERO,current.qty(),current.value(),pending(current),true,true,event,List.of(whole(current)));
        Node issue=createDerivedNode(issueId,pool,"ISSUE_POSITION","IN_TRANSIT",context.sourceItemId(),command.movementId(),issueId,
                plan.qty(),ZERO,plan.qty(),plan.cost(),pending(retained),true,true,event,List.of(whole(retained)));
        Node next=createDerivedNode(pool,"POOL",null,null,null,null,plan.left(),ZERO,plan.left(),value(plan.previous()),pending(plan.previous()),true,true,event,
                List.of(plan.previous()==null?fraction(current,ZERO,ZERO,current.qty()):whole(plan.previous())));
        deactivate(current);head(pool,next.id(),pool.headId());
        db.update("""
                INSERT INTO stock_value_events(id,operation,source_event_id,source_doc_type,source_doc_id,source_item_id,source_version,
                    actor_user_id,actor_employee_id,occurred_at,idempotency_key,request_hash,request_payload,pool_id,movement_id,
                    qty_base,qty_before,known_value_local,result_node_id,result_head_id,result_state,source_node_id,result_source_revision,position_store_reversal_of)
                VALUES(:id,'POSITION_STORE_REVERSE',:sourceEvent,:type,:doc,:item,:version,:user,:employee,:at,:key,:hash,CAST(:payload AS jsonb),
                    :pool,:movement,:qty,:before,:value,:result,:head,:state,:source,:revision,:original)
                """,args("id",event,"sourceEvent",context.sourceEventId(),"type",context.sourceDocType(),"doc",context.sourceDocId(),"item",context.sourceItemId(),"version",context.sourceVersion(),
                    "user",context.actorUserId(),"employee",context.actorEmployeeId(),"at",context.occurredAt(),"key",context.idempotencyKey(),"hash",request.hash(),"payload",request.json(),
                    "pool",pool.id(),"movement",command.movementId(),"qty",plan.qty(),"before",before,"value",plan.cost(),"result",issue.id(),"head",next.id(),"state",state(issue).name(),
                    "source",plan.source().id(),"revision",plan.source().revision(),"original",plan.original().get("id")));
        posting(event,null,current.id(),"INVENTORY",pool.id(),plan.cost().negate());posting(event,null,issue.id(),"IN_TRANSIT",context.sourceItemId(),plan.cost());
        return new MovementValue(event,command.movementId(),issue.id(),next.id(),plan.cost(),state(issue),false);
    }

    @Override @Transactional(propagation = Propagation.MANDATORY)
    public AdjustmentValue adjustSource(SourceAdjustment command) {
        transaction(); EventContext c = context(command.context());
        required(command.sourceCostNodeId(), "来源成本节点UUID");
        requireHeld(node(command.sourceCostNodeId(), false).key());
        BigDecimal delta = sourceAmount(command.deltaLocal(), "追加本币原额", true);
        Request request = request("COST_ADJUST", c, args("sourceNode", command.sourceCostNodeId(),
                "delta", sourceText(delta), "markFinal", command.markFinal()));
        Event prior = replay("COST_ADJUST", c, request); if (prior != null) return adjustmentReplay(prior);
        Node source = node(command.sourceCostNodeId(), true);
        requireAdjustable(source);
        return adjustment("COST_ADJUST", c, request, source, delta,
                command.markFinal() || source.sourceFinal(), null, source.adjustmentHeadId());
    }

    @Override @Transactional(propagation = Propagation.MANDATORY)
    public AdjustmentValue reverseAdjustment(EventContext raw, UUID originalAdjustmentEventId) {
        transaction(); EventContext c = context(raw); required(originalAdjustmentEventId, "原成本调整UUID");
        Event original = event(originalAdjustmentEventId);
        if (!"COST_ADJUST".equals(original.operation())) throw conflict("只能按原正向成本调整事件追加反向");
        requireHeld(node(original.sourceNodeId(), false).key());
        Request request = request("COST_ADJUST_REVERSE", c, args("originalAdjustment", originalAdjustmentEventId));
        Event prior = replay("COST_ADJUST_REVERSE", c, request); if (prior != null) return adjustmentReplay(prior);
        Node source = node(original.sourceNodeId(), true); requireAdjustable(source);
        if (!original.id().equals(source.adjustmentHeadId()) || !jobComplete(original.id()))
            throw conflict("成本调整须按后进先出反向，且原传播必须已经完成");
        if (Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM stock_value_events WHERE reversal_of_event_id=:id)",
                args("id", original.id()), Boolean.class))) throw conflict("原成本调整已反向");
        BigDecimal originalActual=authority.installed?db.queryForObject("SELECT source_delta_exact FROM stock_value_events WHERE id=:id",args("id",original.id()),BigDecimal.class):original.knownValue();
        if(originalActual==null)throw conflict("原调整未保留未裁剪金额依据，不能猜测精确反向额");
        return adjustment("COST_ADJUST_REVERSE", c, request, source, originalActual.negate(),
                original.beforeFinal(), original.id(), original.previousAdjustmentId());
    }

    private AdjustmentValue adjustment(String operation, EventContext c, Request request, Node source,
                                       BigDecimal delta, boolean finalValue, UUID reverses, UUID newPreviousHead) {
        BigDecimal actualDelta=delta;ValueAuthorityStore.Change exactChange=authority.sourceChange(source.id(),actualDelta);
        if(exactChange!=null)delta=projection(exactChange.sourceAfter()).subtract(projection(exactChange.sourceBefore()));
        BigDecimal after = projectedAmount(source.value().add(delta), "来源累计投影", false);
        if(after.compareTo(assignedProductionValue(source))<0)throw conflict("对价冲减超过原资金来源金额，不能扣走已经承接的自有材料成本");
        finalValue=finalValue&&productionScopeAllowsFinal(source);
        UUID eventId = UUID.randomUUID(); int pending = finalValue ? 0 : 1;
        Node updated = revise(source, after, pending, finalValue, eventId, null,exactChange);
        db.update("UPDATE stock_value_nodes SET adjustment_head_id=:head WHERE id=:id", args("id", source.id(),
                "head", reverses == null ? eventId : newPreviousHead));
        db.update("""
                INSERT INTO stock_value_jobs(event_id,source_node_id,pending_tasks,clearing_remaining_local,status)
                VALUES (:event,:source,0,:delta,'PENDING')
                """, args("event", eventId, "source", source.id(), "delta", delta));
        int count = schedule(updated, eventId);
        if (count == 0) throw conflict("来源成本缺少已冻结的后继分配关系");
        db.update("UPDATE stock_value_jobs SET pending_tasks=:count WHERE event_id=:event", args("event", eventId, "count", count));
        insertEvent(eventId, operation, c, request, source.poolId(), null, null, null,
                delta, source.id(), null, State.PENDING, source.id(), updated.revision(),
                source.adjustmentHeadId(), reverses, source.sourceFinal(), finalValue,actualDelta);
        posting(eventId, null, source.id(), "SOURCE", c.sourceEventId(), delta.negate());
        posting(eventId, null, null, "CLEARING", eventId, delta);
        return new AdjustmentValue(eventId, source.id(), count, false);
    }

    /** Package-only, paired production transfer; its deferred task proof owns both ends. */
    void assignProductionCost(UUID eventId,EventContext raw,UUID inputNodeId,UUID outputSourceNodeId,
                              BigDecimal delta,boolean finalValue,UUID previousTaskId) {
        transaction();EventContext c=context(raw);Node input=node(inputNodeId,false),source=node(outputSourceNodeId,false);
        requireHeld(input.key());requireHeld(source.key());source=node(source.id(),true);
        if(!Set.of("SOURCE","RETURN_SOURCE").contains(source.kind())||source.movementId()==null||!"COST_WIP".equals(input.ownerKind())
                ||!c.sourceDocId().equals(input.ownerId()))throw conflict("生产成本分配必须来自本执行段的真实耗用并指向确切产出来源");
        Request request=request("COST_ALLOCATE",c,args("input",input.id(),"output",source.id(),"delta",delta.toPlainString(),"complete",finalValue));
        int pending=source.pending()+(finalValue?0:1)-(source.sourceFinal()?0:1);
        if(pending<0)throw conflict("成品来源的待核组成不一致");
        Node updated=revise(source,projectedAmount(source.value().add(delta),"成品累计投影",false),pending,finalValue,eventId,null,
                authority.productionChange(source.id(),eventId,previousTaskId));
        db.update("INSERT INTO stock_value_jobs(event_id,source_node_id,pending_tasks,clearing_remaining_local,status) VALUES (:event,:source,0,:delta,'PENDING')",
                args("event",eventId,"source",source.id(),"delta",delta));
        int count=schedule(updated,eventId);if(count==0)throw conflict("成品来源尚未建立确切的库存后继");
        db.update("UPDATE stock_value_jobs SET pending_tasks=:count WHERE event_id=:event",args("event",eventId,"count",count));
        insertEvent(eventId,"COST_ALLOCATE",c,request,source.poolId(),null,null,null,delta,source.id(),null,State.PENDING,
                source.id(),updated.revision(),null,null,source.sourceFinal(),finalValue);
        posting(eventId,null,input.id(),"COST_WIP",input.ownerId(),delta.negate());
        posting(eventId,null,null,"CLEARING",eventId,delta);
    }

    @Override @Transactional(readOnly = true)
    public List<PropagationWork> pendingWork(int limit) {
        return db.query("""
                SELECT t.id,t.event_id,p.warehouse_id,p.goods_id,p.color_id
                FROM stock_value_tasks t JOIN stock_value_edges e ON e.id=t.edge_id
                JOIN stock_value_nodes n ON n.id=e.child_node_id JOIN stock_value_pools p ON p.id=n.pool_id
                WHERE t.status='PENDING' ORDER BY t.task_sequence LIMIT :limit
                """, args("limit", Math.max(1, Math.min(limit, 100))), (r, i) -> new PropagationWork(
                uuid(r,"id"), uuid(r,"event_id"), new PoolKey(uuid(r,"warehouse_id"),uuid(r,"goods_id"),uuid(r,"color_id"))));
    }

    @Override @Transactional(propagation = Propagation.MANDATORY)
    public PropagationResult propagate(UUID taskId) {
        transaction(); required(taskId, "传播任务UUID");
        List<PoolKey> keys = db.query("""
                SELECT p.warehouse_id,p.goods_id,p.color_id
                FROM stock_value_tasks t JOIN stock_value_edges e ON e.id=t.edge_id
                JOIN stock_value_nodes n ON n.id=e.child_node_id JOIN stock_value_pools p ON p.id=n.pool_id
                WHERE t.id=:id
                """, args("id", taskId), (r, i) -> new PoolKey(uuid(r,"warehouse_id"),uuid(r,"goods_id"),uuid(r,"color_id")));
        if (keys.size()!=1) throw conflict("成本传播任务不存在");
        requireHeld(keys.getFirst());
        List<Map<String,Object>> rows = db.queryForList("SELECT * FROM stock_value_tasks WHERE id=:id FOR UPDATE", args("id", taskId));
        if (rows.size()!=1) throw conflict("成本传播任务不存在"); Map<String,Object> task=rows.getFirst();
        UUID eventId=(UUID)task.get("event_id");
        if ("APPLIED".equals(task.get("status"))) return new PropagationResult(false,true,false,jobComplete(eventId));
        Edge edge=edge((UUID)task.get("edge_id"), true);
        long revision=((Number)task.get("parent_revision")).longValue();
        if (revision!=edge.lastRevision()+1) {
            if (revision<=edge.lastRevision()) throw conflict("传播任务状态与边revision不一致，禁止重复入账");
            return new PropagationResult(false,false,true,false);
        }
        Node child=node(edge.childId(),true);
        BigDecimal target=(BigDecimal)task.get("target_amount_local");
        boolean targetPending=(Boolean)task.get("target_pending");
        BigDecimal delta=target.subtract(edge.allocated());
        int pending=child.pending()+(targetPending?1:0)-(edge.pending()?1:0);
        if (pending<0) throw conflict("成本待证来源计数不一致");
        BigDecimal beforeOwned=owned(child);
        Node after=revise(child,projectedAmount(child.value().add(delta),"节点累计投影",false),pending,
                child.sourceFinal(),eventId,taskId);
        BigDecimal ownedDelta=owned(after).subtract(beforeOwned);
        db.update("""
                UPDATE stock_value_edges SET last_parent_revision=:revision,allocated_amount_local=:target,
                    pending_contribution=:pending WHERE id=:id AND last_parent_revision=:before
                """, args("id",edge.id(),"revision",revision,"target",target,"pending",targetPending,"before",edge.lastRevision()));
        if (ownedDelta.signum()!=0) {
            if ("POOL".equals(after.kind())) {
                int affected=db.update("UPDATE stock_balances SET amount_local=amount_local+:delta WHERE warehouse_id=:warehouse AND goods_id=:goods AND "
                        +colorCondition("color_id",after.key()), poolArgs(after.key(),"delta",ownedDelta));
                if (affected!=1) throw conflict("价值调整不能证明唯一当前库存余额");
                posting(eventId,taskId,after.id(),"INVENTORY",after.poolId(),ownedDelta);
            } else posting(eventId,taskId,after.id(),after.ownerKind(),after.ownerId(),ownedDelta);
            posting(eventId,taskId,null,"CLEARING",eventId,ownedDelta.negate());
        }
        int children=schedule(after,eventId);
        db.update("""
                UPDATE stock_value_tasks SET status='APPLIED',applied_delta_local=:delta,applied_child_revision=:revision WHERE id=:id
                """,args("id",taskId,"delta",delta,"revision",after.revision()));
        List<Map<String,Object>> jobs=db.queryForList("""
                UPDATE stock_value_jobs SET pending_tasks=pending_tasks-1+:children,processed_tasks=processed_tasks+1,
                    clearing_remaining_local=clearing_remaining_local-:owned
                WHERE event_id=:event AND status='PENDING' RETURNING pending_tasks,clearing_remaining_local
                """,args("event",eventId,"children",children,"owned",ownedDelta));
        if(jobs.size()!=1)throw conflict("成本传播批次状态已变化");
        long left=((Number)jobs.getFirst().get("pending_tasks")).longValue();
        if(left==0){
            if(((BigDecimal)jobs.getFirst().get("clearing_remaining_local")).signum()!=0)
                throw conflict("成本传播尚有未分配差额，不能标记完成");
            db.update("UPDATE stock_value_jobs SET status='APPLIED' WHERE event_id=:event",args("event",eventId));
        }
        return new PropagationResult(true,false,false,left==0);
    }

    @Override @Transactional(readOnly = true)
    public PoolValue pool(PoolKey raw) {
        PoolKey key=key(raw); Pool p=findPool(key,false); Balance actual=balance(key);
        if(p==null || p.headId()==null){
            boolean legacy=p!=null&&"LEGACY_UNVERIFIED".equals(p.state()) || !actual.empty();
            return new PoolValue(p==null?null:p.id(),null,actual.qty(),legacy?null:ZERO,
                    legacy?State.LEGACY_UNVERIFIED:State.FINAL,propagationPending());
        }
        if("LEGACY_UNVERIFIED".equals(p.state()))return new PoolValue(p.id(),null,actual.qty(),null,State.LEGACY_UNVERIFIED,propagationPending());
        Node n=node(p.headId(),false);
        if(!n.active() || !"POOL".equals(n.kind()) || !n.poolId().equals(p.id())
                || actual.rows()!=1 || actual.qty().compareTo(n.qty())!=0 || actual.amount()==null || actual.amount().compareTo(n.value())!=0)
            return new PoolValue(p.id(),n.id(),actual.qty(),null,State.LEGACY_UNVERIFIED,propagationPending());
        return new PoolValue(p.id(),n.id(),n.qty(),n.value(),state(n),propagationPending());
    }

}
