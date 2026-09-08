package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryCostSourceEvidencePort;
import com.uten.imp.application.port.InventoryCostSourceEvidencePort.Evidence;
import com.uten.imp.application.port.InventoryPositionPort;
import com.uten.imp.application.port.InventoryValuationPort.*;
import com.uten.imp.features.stock.InventoryMutationLock;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.stock.valuation.ValueMath.*;

/** Bounded custody transfers retaining original-cost intervals and exact source facts. */
@Service
public class InventoryPositionService extends InventoryValueLedger implements InventoryPositionPort {
    private final Optional<InventoryCostSourceEvidencePort> sourceEvidence;

    @Autowired
    public InventoryPositionService(NamedParameterJdbcTemplate db, InventoryMutationLock mutex,
                                    Optional<InventoryCostSourceEvidencePort> sourceEvidence) {
        super(db, mutex);
        this.sourceEvidence = sourceEvidence;
    }

    @Override @Transactional(propagation = Propagation.MANDATORY)
    public PositionValue acquire(Acquire command) {
        transaction();
        EventContext c=context(command.context()); PoolKey key=key(command.pool()); requireHeld(key);
        required(command.approvedEvidenceId(),"已批准取得成本依据UUID");
        if(command.approvedEvidenceVersion()<1)throw invalid("取得成本依据版本无效");
        owner(command.owner(),command.ownerId());
        List<Slice> slices=slices(command.carried(),true);
        Request request=request("POSITION_ACQUIRE",c,args("pool",keyText(key),"evidence",command.approvedEvidenceId(),
                "evidenceVersion",command.approvedEvidenceVersion(),"owner",command.owner().name(),
                "ownerId",command.ownerId(),"slices",sliceBody(slices)));
        Event prior=replay("POSITION_ACQUIRE",c,request);if(prior!=null)return result(prior,true);
        Evidence proof=sourceEvidence.flatMap(p->p.approved(command.approvedEvidenceId(),command.approvedEvidenceVersion()))
                .orElseThrow(()->conflict("尚无已批准的取得成本依据，不能把缺少来源当成零成本"));
        validateEvidence(proof,command);
        requireSourceLocks(slices,key);
        Pool pool=lockPool(key);
        prior=replay("POSITION_ACQUIRE",c,request);if(prior!=null)return result(prior,true);
        if(Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM stock_value_acquisition_sources WHERE evidence_id=:id)",
                args("id",proof.id()),Boolean.class)))throw conflict("本取得成本依据已经建立价值来源，请沿原位置流转");
        List<Take> takes=take(slices,key);
        if(totalQty(takes).compareTo(decimal(proof.carriedQtyBase(),"须承接的原实物数量",false))!=0)
            throw conflict("承接数量与批准的补回/在外实物来源不一致");
        BigDecimal qty=positive(proof.qtyBase(),"取得基本数量");
        BigDecimal actualNewCost=proof.knownValueLocal()==null?ZERO:sourceAmount(proof.knownValueLocal(),"已知取得成本原额",false);
        BigDecimal newCost=projection(actualNewCost);
        UUID eventId=UUID.randomUUID();
        Node source=createNode(pool,"SOURCE",null,null,null,null,qty,ZERO,ZERO,newCost,proof.complete()?0:1,false,proof.complete(),eventId);
        authority.initialSource(source.id(),actualNewCost);
        Node position=newPosition(pool,command.owner(),command.ownerId(),qty,
                newCost.add(totalValue(takes)),pending(source)+totalPending(takes),eventId);
        edge(source,position,ZERO,BigDecimal.ONE,BigDecimal.ONE,eventId);
        transfer(takes,position,eventId);
        db.update("""
                INSERT INTO stock_value_acquisition_sources(source_node_id,event_id,evidence_id,evidence_version,
                    authority_type,authority_id,authority_version,evidence_hash,quantity_basis,carried_qty_base,
                    initial_known_value,initial_complete)
                VALUES (:source,:event,:evidence,:version,:type,:authority,:authorityVersion,:hash,:qty,:carried,:value,:complete)
                """,args("source",source.id(),"event",eventId,"evidence",proof.id(),"version",proof.version(),
                "type",proof.authorityType(),"authority",proof.authorityId(),"authorityVersion",proof.authorityVersion(),
                "hash",proof.evidenceHash(),"qty",qty,"carried",proof.carriedQtyBase(),"value",proof.knownValueLocal()==null?null:newCost,"complete",proof.complete()));
        State state=state(position);
        insertEvent(eventId,"POSITION_ACQUIRE",c,request,pool.id(),null,qty,null,position.value(),position.id(),null,state,
                source.id(),1L,null,null,null,null);
        posting(eventId,null,source.id(),"SOURCE",proof.authorityId(),newCost.negate());
        posting(eventId,null,position.id(),position.ownerKind(),position.ownerId(),position.value());
        return new PositionValue(eventId,position.id(),source.id(),qty,position.value(),state,false);
    }

    @Override @Transactional(propagation = Propagation.MANDATORY)
    public PositionValue move(Move command) {
        return move(command,false);
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public PositionValue restoreUnallocatedConsumed(RestoreConsumed command){
        transaction();requireHeld(key(command.pool()));
        Node root=node(command.originalPositionRootId(),true);requireRoot(root);
        if(!"COST_WIP".equals(root.ownerKind())||!root.active()||!root.id().equals(root.returnHeadId())||root.returnedQty().signum()!=0
                ||root.distributed().signum()!=0||Boolean.TRUE.equals(db.queryForObject(
                    "SELECT EXISTS(SELECT 1 FROM stock_value_production_cost_inputs WHERE input_node_id=:id)",args("id",root.id()),Boolean.class)))
            throw conflict("已登记或已分摊的实耗须完成原成本回退，不能直接恢复领料");
        return move(new Move(command.context(),command.pool(),Owner.WIP,command.originalIssuePostingId(),
                List.of(new Slice(root.id(),root.qty(),command.reversalPostingId()))),true);
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public PositionValue returnConsumed(ReturnConsumed command){
        transaction();if(!consumptionReturnsInstalled)throw conflict("实耗反向来源迁移尚未完成");
        EventContext c=context(command.context());PoolKey key=key(command.pool());requireHeld(key);
        if(command.materialOwner()!=Owner.WIP&&command.materialOwner()!=Owner.SUBCONTRACT_WIP)
            throw invalid("实耗纠正必须恢复到原生产或委外材料位置");
        required(command.materialOwnerId(),"原材料位置UUID");
        BigDecimal qty=positive(command.qtyBase(),"本次恢复的实耗基本量");
        Request request=request("CONSUMPTION_RETURN",c,args("pool",keyText(key),"root",command.originalPositionRootId(),
                "qty",qty.toPlainString(),"owner",command.materialOwner().name(),"ownerId",command.materialOwnerId()));
        Event prior=replay("CONSUMPTION_RETURN",c,request);if(prior!=null)return result(prior,true);
        Node root=node(command.originalPositionRootId(),true);requireRoot(root);
        if(!root.active()||!"COST_WIP".equals(root.ownerKind())||!root.key().equals(key))
            throw conflict("实耗纠正必须引用同一原始耗用成本位置");
        BigDecimal through=root.returnedQty().add(qty);if(through.compareTo(root.qty())>0)throw conflict("本次恢复超过原实耗尚未反向数量");
        Node source=root.consumptionReturnHeadId()==null?root:node(root.consumptionReturnHeadId(),true);
        if(source.value().compareTo(root.value())!=0||pending(source)!=pending(root))
            throw conflict("原实耗金额正在传播，请待原来源更新完成后重试");
        Pool pool=lockPool(key);UUID event=UUID.randomUUID();
        BigDecimal cost=interval(source.value(),root.returnedQty(),through,root.qty());
        Node restored=newPosition(pool,command.materialOwner(),command.materialOwnerId(),qty,cost,pending(source),event);
        Node cursor=createNode(pool,"COST_RETURN_CURSOR",null,null,null,root.id(),root.qty(),through,root.qty(),
                source.value(),pending(source),true,true,event);
        edge(source,restored,root.returnedQty(),through,root.qty(),event);
        edge(source,cursor,ZERO,BigDecimal.ONE,BigDecimal.ONE,event);
        if(!source.id().equals(root.id()))deactivate(source);
        if(db.update("""
                UPDATE stock_value_nodes SET returned_consumption_qty=:through,consumption_return_head_id=:head
                WHERE id=:root AND returned_consumption_qty=:before AND consumption_return_head_id IS NOT DISTINCT FROM CAST(:oldHead AS uuid)
                """,args("root",root.id(),"through",through,"head",cursor.id(),"before",root.returnedQty(),"oldHead",root.consumptionReturnHeadId()))!=1)
            throw conflict("原实耗已被其它反向更改，请重新读取");
        State state=state(restored);
        insertEvent(event,"CONSUMPTION_RETURN",c,request,pool.id(),null,qty,root.returnedQty(),cost,restored.id(),cursor.id(),state,
                root.id(),source.revision(),null,null,null,null);
        posting(event,null,root.id(),"COST_WIP",root.ownerId(),cost.negate());
        posting(event,null,restored.id(),restored.ownerKind(),restored.ownerId(),cost);
        return new PositionValue(event,restored.id(),null,qty,cost,state,false);
    }

    private PositionValue move(Move command,boolean restoringUnallocatedConsumed) {
        transaction(); EventContext c=context(command.context()); PoolKey key=key(command.pool());requireHeld(key);
        owner(command.owner(),command.ownerId()); List<Slice> slices=slices(command.sources(),false);
        Request request=request("POSITION_MOVE",c,args("pool",keyText(key),"owner",command.owner().name(),
                "ownerId",command.ownerId(),"slices",sliceBody(slices)));
        Event prior=replay("POSITION_MOVE",c,request);if(prior!=null)return result(prior,true);
        requireSourceLocks(slices,key); Pool pool=lockPool(key);
        prior=replay("POSITION_MOVE",c,request);if(prior!=null)return result(prior,true);
        List<Take> takes=take(slices,key,restoringUnallocatedConsumed);UUID eventId=UUID.randomUUID();BigDecimal qty=totalQty(takes);
        Node position=newPosition(pool,command.owner(),command.ownerId(),qty,totalValue(takes),totalPending(takes),eventId);
        transfer(takes,position,eventId);State state=state(position);
        insertEvent(eventId,"POSITION_MOVE",c,request,pool.id(),null,qty,null,position.value(),position.id(),null,state,
                null,null,null,null,null,null);
        posting(eventId,null,position.id(),position.ownerKind(),position.ownerId(),position.value());
        return new PositionValue(eventId,position.id(),null,qty,position.value(),state,false);
    }

    @Override @Transactional(propagation = Propagation.MANDATORY)
    public MovementValue store(Store command) {
        transaction();EventContext c=context(command.context());PoolKey key=key(command.pool());requireHeld(key);
        required(command.movementId(),"库存流水UUID");List<Slice> slices=slices(command.sources(),false);
        BigDecimal before=decimal(command.expectedQtyBefore(),"前置库存数量",false);
        Map<String,Object> body=args("pool",keyText(key),"slices",sliceBody(slices));
        if(command.pendingOwnMaterialCost())body.put("pendingOwnMaterialCost",true);
        Request request=request("POSITION_STORE",c,body);
        Event prior=replay("POSITION_STORE",c,request);if(prior!=null)return prior.movement(true);
        requireSourceLocks(slices,key);Pool pool=lockPool(key);
        prior=replay("POSITION_STORE",c,request);if(prior!=null)return prior.movement(true);
        Node inventory=requireBefore(pool,before);List<Take> takes=take(slices,key);
        // Pending quality is not qualified physical inventory. Rejected/lost and
        // consumed positions need their actual business transition first.
        for(Take t:takes)if(!Set.of("QUALITY_PASSED","WIP","SUBCONTRACT_WIP","IN_TRANSIT","EXTERNAL").contains(t.head().ownerKind()))
            throw conflict("该价值位置尚未完成允许入仓的业务处置");
        UUID eventId=UUID.randomUUID();BigDecimal qty=totalQty(takes),cost=totalValue(takes);
        Node source=createNode(pool,"RETURN_SOURCE",null,null,command.movementId(),null,
                qty,ZERO,ZERO,cost,totalPending(takes)+(command.pendingOwnMaterialCost()?1:0),false,!command.pendingOwnMaterialCost(),eventId);
        transfer(takes,source,eventId);
        Node next=createNode(pool,"POOL",null,null,null,null,before.add(qty),ZERO,before.add(qty),
                value(inventory).add(cost),pending(inventory)+pending(source),true,true,eventId);
        if(inventory!=null){edge(inventory,next,ZERO,BigDecimal.ONE,BigDecimal.ONE,eventId);deactivate(inventory);}
        edge(source,next,ZERO,BigDecimal.ONE,BigDecimal.ONE,eventId);head(pool,next.id(),pool.headId());
        State state=state(source);
        insertEvent(eventId,"POSITION_STORE",c,request,pool.id(),command.movementId(),qty,before,cost,source.id(),next.id(),state,
                null,null,null,null,null,null);
        posting(eventId,null,next.id(),"INVENTORY",pool.id(),cost);
        return new MovementValue(eventId,command.movementId(),source.id(),next.id(),cost,state,false);
    }

    @Override @Transactional(readOnly=true)
    public PositionView position(UUID rootId) {
        required(rootId,"价值位置UUID");
        List<Node> rows=db.query("""
                SELECT n.*,p.warehouse_id,p.goods_id,p.color_id FROM stock_value_nodes root
                JOIN stock_value_nodes n ON n.id=root.return_head_id JOIN stock_value_pools p ON p.id=n.pool_id
                WHERE root.id=:root AND root.kind='ISSUE_POSITION' AND root.root_issue_id=root.id
                """,args("root",rootId),(r,i)->nodeRow(r));
        if(rows.size()!=1)throw conflict("必须引用准确的原价值位置UUID");Node remaining=rows.getFirst();
        BigDecimal net=owned(remaining);boolean costWip="COST_WIP".equals(remaining.ownerKind());
        return new PositionView(rootId,remaining.id(),remaining.key(),Owner.valueOf(remaining.ownerKind()),remaining.ownerId(),
                costWip?null:remaining.to().subtract(remaining.from()),costWip?net.max(ZERO):net,costWip?net.min(ZERO):ZERO,
                costWip?State.PENDING:state(remaining));
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public MovementValue reverseStore(ReverseStore command){
        transaction();EventContext c=context(command.context());PoolKey key=key(command.pool());requireHeld(key);
        required(command.movementId(),"撤回库存流水UUID");required(command.originalMovementId(),"原入库流水UUID");
        BigDecimal before=decimal(command.expectedQtyBefore(),"撤回前库存基本量",false);
        Request request=request("POSITION_STORE_REVERSE",c,args("pool",keyText(key),"originalMovement",command.originalMovementId()));
        Event replay=replay("POSITION_STORE_REVERSE",c,request);if(replay!=null)return replay.movement(true);
        var originals=db.queryForList("SELECT * FROM stock_value_events WHERE movement_id=:id AND operation='POSITION_STORE'",args("id",command.originalMovementId()));
        if(originals.size()!=1)throw conflict("原合格入库缺少唯一成本归属，不能猜测撤回金额");
        var original=originals.getFirst();UUID originalId=(UUID)original.get("id");
        Pool pool=lockPool(key);Node current=requireBefore(pool,before);
        if(!pool.id().equals(original.get("pool_id"))||current==null||!Boolean.TRUE.equals(db.queryForObject(
                "SELECT fn_stock_value_unused_receipt_head(:current,:original)",args("current",current.id(),"original",original.get("result_head_id")),Boolean.class)))
            throw conflict("原入库之后已有出库、调拨或其它未撤回入库，不能直接撤回原成本");
        Node originalHead=node((UUID)original.get("result_head_id"),false),source=node((UUID)original.get("result_node_id"),false);
        if(!Boolean.TRUE.equals(db.queryForObject("SELECT fn_stock_value_stored_cost_reversible(:source)",args("source",source.id()),Boolean.class)))
            throw conflict("该入库包含生产或委外材料成本，须先按专用来源完成成本撤回");
        var predecessors=db.queryForList("""
                SELECT parent_node_id FROM stock_value_edges edge JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id
                WHERE edge.child_node_id=:head AND parent.kind='POOL' ORDER BY edge.id
                """,args("head",originalHead.id()),UUID.class);
        if(predecessors.size()>1)throw conflict("原入库前置库存归属不唯一");
        Node predecessor=predecessors.isEmpty()?null:node(predecessors.getFirst(),false);
        var transfers=db.queryForList("SELECT * FROM stock_value_position_transfers WHERE event_id=:event ORDER BY source_root_id,id",args("event",originalId));
        if(transfers.isEmpty()||transfers.size()>100)throw conflict("原入库来源切片缺失或超过单次核对范围");
        UUID eventId=UUID.randomUUID();BigDecimal cost=ZERO,qty=ZERO;
        for(var transfer:transfers){
            UUID rootId=(UUID)transfer.get("source_root_id");Node root=node(rootId,true);requireRoot(root);Node held=node(root.returnHeadId(),true);
            if(!"QUALITY_PASSED".equals(held.ownerKind())||!held.active()||!held.key().equals(key))
                throw conflict("原合格来源位置已变更，不能把其它价值当作供应商费用归还");
            BigDecimal partQty=(BigDecimal)transfer.get("qty_base"),from=(BigDecimal)transfer.get("range_from"),to=(BigDecimal)transfer.get("range_to");
            if(held.from().compareTo(to)<0)throw conflict("原入库切片尚未全部离开原合格位置");
            BigDecimal amount=interval(held.value(),from,to,held.qty());
            Node restored=newPosition(pool,Owner.QUALITY_PASSED,held.ownerId(),partQty,amount,pending(held),eventId);
            Node remainder=createNode(pool,"ISSUE_POSITION",held.ownerKind(),held.ownerId(),null,root.id(),held.qty(),held.from(),held.to(),held.value(),pending(held),true,true,eventId);
            edge(held,restored,from,to,held.qty(),eventId);edge(held,remainder,ZERO,BigDecimal.ONE,BigDecimal.ONE,eventId);deactivate(held);
            if(db.update("UPDATE stock_value_nodes SET return_head_id=:next WHERE id=:root AND return_head_id=:before",
                    args("next",remainder.id(),"root",root.id(),"before",held.id()))!=1)throw conflict("原合格位置已变化，请重新读取");
            db.update("""
                    INSERT INTO stock_value_position_transfers(id,event_id,source_slice_id,source_root_id,source_node_id,remaining_node_id,
                        target_node_id,qty_base,range_from,range_to,quantity_basis,source_revision,initial_value_local,reversal_of_transfer_id)
                    VALUES(:id,:event,:slice,:root,:source,:remaining,:target,:qty,:from,:to,:basis,:revision,:amount,:original)
                    """,args("id",UUID.randomUUID(),"event",eventId,"slice",transfer.get("source_slice_id"),"root",root.id(),"source",held.id(),
                    "remaining",remainder.id(),"target",restored.id(),"qty",partQty,"from",from,"to",to,"basis",held.qty(),"revision",held.revision(),
                    "amount",amount,"original",transfer.get("id")));
            posting(eventId,null,restored.id(),restored.ownerKind(),restored.ownerId(),amount);cost=cost.add(amount);qty=qty.add(partQty);
        }
        BigDecimal remainingQty=predecessor==null?ZERO:predecessor.qty(),remainingValue=value(predecessor);
        if(qty.compareTo((BigDecimal)original.get("qty_base"))!=0||cost.compareTo(source.value())!=0
                ||before.compareTo(originalHead.qty())!=0||before.subtract(qty).compareTo(remainingQty)!=0
                ||current.value().compareTo(remainingValue.add(cost))!=0)
            throw conflict("原入库成本尚未完成来源传播或余额核对，不能按混合均价撤回");
        Node archived=createNode(pool,"REVERSED_POOL_CURSOR",null,null,null,null,current.qty(),ZERO,current.qty(),current.value(),pending(current),true,true,eventId);
        edge(current,archived,ZERO,BigDecimal.ONE,BigDecimal.ONE,eventId);
        Node next=createNode(pool,"POOL",null,null,null,null,remainingQty,ZERO,remainingQty,remainingValue,pending(predecessor),true,true,eventId);
        if(predecessor==null)edge(current,next,ZERO,ZERO,current.qty(),eventId);else edge(predecessor,next,ZERO,BigDecimal.ONE,BigDecimal.ONE,eventId);
        deactivate(current);head(pool,next.id(),pool.headId());State state=state(source);
        db.update("""
                INSERT INTO stock_value_events(id,operation,source_event_id,source_doc_type,source_doc_id,source_item_id,source_version,
                    actor_user_id,actor_employee_id,occurred_at,idempotency_key,request_hash,request_payload,pool_id,movement_id,
                    qty_base,qty_before,known_value_local,result_node_id,result_head_id,result_state,source_node_id,result_source_revision,position_store_reversal_of)
                VALUES(:id,'POSITION_STORE_REVERSE',:sourceEvent,:docType,:doc,:item,:version,:user,:employee,:at,:key,:hash,CAST(:payload AS jsonb),
                    :pool,:movement,:qty,:before,:amount,:result,:head,:state,:source,:revision,:original)
                """,args("id",eventId,"sourceEvent",c.sourceEventId(),"docType",c.sourceDocType(),"doc",c.sourceDocId(),"item",c.sourceItemId(),"version",c.sourceVersion(),
                "user",c.actorUserId(),"employee",c.actorEmployeeId(),"at",c.occurredAt(),"key",c.idempotencyKey(),"hash",request.hash(),"payload",request.json(),
                "pool",pool.id(),"movement",command.movementId(),"qty",qty,"before",before,"amount",cost,"result",archived.id(),"head",next.id(),"state",state.name(),
                "source",source.id(),"revision",source.revision(),"original",originalId));
        posting(eventId,null,current.id(),"INVENTORY",pool.id(),cost.negate());
        return new MovementValue(eventId,command.movementId(),archived.id(),next.id(),cost,state,false);
    }

    private PositionValue result(Event e,boolean replayed){Node root=node(e.resultNodeId(),false);
        return new PositionValue(e.id(),root.id(),e.sourceNodeId(),root.qty(),e.knownValue(),e.state(),replayed);}
    private Node newPosition(Pool pool,Owner owner,UUID ownerId,BigDecimal qty,BigDecimal value,int pending,UUID event){
        UUID id=UUID.randomUUID();Node position=createNode(id,pool,"ISSUE_POSITION",owner.name(),ownerId,null,id,
                qty,ZERO,qty,value,pending,true,true,event);
        db.update("UPDATE stock_value_nodes SET return_head_id=:id WHERE id=:id",args("id",id));return position;
    }
    private void requireSourceLocks(List<Slice> slices,PoolKey target){
        // Read the complete, immutable key set before taking any row locks.
        for(Slice s:slices){Node root=node(s.positionRootId(),false);requireRoot(root);requireHeld(root.key());
            if(!sameGoods(root.key(),target))throw conflict("实物价值携转必须保持原货品和颜色；跨产品须使用生产成本分配");}
    }
    private List<Take> take(List<Slice> slices,PoolKey target){
        return take(slices,target,false);
    }
    private List<Take> take(List<Slice> slices,PoolKey target,boolean restoringUnallocatedConsumed){
        List<Take> result=new ArrayList<>();
        for(Slice s:slices){Node root=node(s.positionRootId(),true);requireRoot(root);Node head=node(root.returnHeadId(),true);
            if("COST_WIP".equals(head.ownerKind())&&!restoringUnallocatedConsumed)throw conflict("已确认实耗成本须通过生产分配版本处理，不能再次按实物携转");
            BigDecimal through=head.from().add(s.qtyBase());
            if(!head.active()||!sameGoods(head.key(),target)||through.compareTo(head.to())>0)
                throw conflict("原价值位置已转移或本次数量超过剩余数量");
            result.add(new Take(s,root,head,through,interval(head.value(),head.from(),through,head.qty())));}
        return result;
    }
    private void transfer(List<Take> takes,Node target,UUID event){
        for(Take t:takes){Node old=t.head();
            Node remainder=createNode(poolById(old.poolId(),false),"ISSUE_POSITION",old.ownerKind(),old.ownerId(),null,t.root().id(),
                    old.qty(),t.through(),old.to(),old.value(),pending(old),true,true,event);
            edge(old,target,old.from(),t.through(),old.qty(),event);
            edge(old,remainder,ZERO,BigDecimal.ONE,BigDecimal.ONE,event);deactivate(old);
            if(db.update("UPDATE stock_value_nodes SET return_head_id=:head WHERE id=:root AND return_head_id=:before",
                    args("root",t.root().id(),"head",remainder.id(),"before",old.id()))!=1)
                throw conflict("原价值位置已变化，请重新读取来源");
            db.update("""
                    INSERT INTO stock_value_position_transfers(id,event_id,source_slice_id,source_root_id,source_node_id,
                        remaining_node_id,target_node_id,qty_base,range_from,range_to,quantity_basis,source_revision,initial_value_local)
                    VALUES (:id,:event,:slice,:root,:source,:remaining,:target,:qty,:from,:to,:basis,:revision,:value)
                    """,args("id",UUID.randomUUID(),"event",event,"slice",t.slice().sourceSliceId(),"root",t.root().id(),
                    "source",old.id(),"remaining",remainder.id(),"target",target.id(),"qty",t.slice().qtyBase(),
                    "from",old.from(),"to",t.through(),"basis",old.qty(),"revision",old.revision(),"value",t.value()));
            posting(event,null,old.id(),old.ownerKind(),old.ownerId(),t.value().negate());
        }
    }
    private static void requireRoot(Node n){if(!"ISSUE_POSITION".equals(n.kind())||!n.id().equals(n.rootIssueId())||n.returnHeadId()==null)
        throw conflict("必须引用准确的原价值位置UUID");}
    private static void owner(Owner owner,UUID id){if(owner==null)throw invalid("价值位置类型不能为空");required(id,"价值位置归属UUID");}
    private static List<Slice> slices(List<Slice> raw,boolean emptyAllowed){
        if(raw==null)raw=List.of();if(raw.size()>100||(!emptyAllowed&&raw.isEmpty()))throw invalid("每次价值携转须有1到100个明确来源切片");
        Set<UUID> roots=new HashSet<>(),facts=new HashSet<>();List<Slice> result=new ArrayList<>();
        for(Slice s:raw){if(s==null)throw invalid("价值来源切片不能为空");required(s.positionRootId(),"原价值位置UUID");required(s.sourceSliceId(),"业务来源切片UUID");
            if(!roots.add(s.positionRootId())||!facts.add(s.sourceSliceId()))throw invalid("同一原位置或业务切片不能在一次操作中重复，请先按来源归并");
            result.add(new Slice(s.positionRootId(),positive(s.qtyBase(),"本次来源基本数量"),s.sourceSliceId()));}
        result.sort(Comparator.comparing(s->s.positionRootId().toString()));return List.copyOf(result);
    }
    private static List<Map<String,Object>> sliceBody(List<Slice> slices){return slices.stream().map(s->Map.<String,Object>of(
            "root",s.positionRootId(),"qty",s.qtyBase().toPlainString(),"fact",s.sourceSliceId())).toList();}
    private static BigDecimal totalQty(List<Take> takes){return takes.stream().map(t->t.slice().qtyBase()).reduce(ZERO,BigDecimal::add);}
    private static BigDecimal totalValue(List<Take> takes){return takes.stream().map(Take::value).reduce(ZERO,BigDecimal::add);}
    private static int totalPending(List<Take> takes){return takes.stream().mapToInt(t->pending(t.head())).sum();}
    private static void validateEvidence(Evidence e,Acquire c){
        if(!c.approvedEvidenceId().equals(e.id())||e.version()!=c.approvedEvidenceVersion()||!c.pool().equals(e.pool())
                ||e.authorityId()==null||e.authorityVersion()<1||e.authorityType()==null||!e.authorityType().matches("[A-Z][A-Z0-9_]{0,79}")
                ||e.evidenceHash()==null||!e.evidenceHash().matches("[0-9a-f]{64}")||(e.complete()&&e.knownValueLocal()==null))
            throw conflict("取得成本依据的身份、版本或批准证据不完整");
        BigDecimal qty=positive(e.qtyBase(),"取得基本数量"),carried=decimal(e.carriedQtyBase(),"须承接的原实物数量",false);
        if(carried.compareTo(qty)>0)throw conflict("须承接的原实物数量超过本次取得数量");
    }
    private record Take(Slice slice,Node root,Node head,BigDecimal through,BigDecimal value){}
}
