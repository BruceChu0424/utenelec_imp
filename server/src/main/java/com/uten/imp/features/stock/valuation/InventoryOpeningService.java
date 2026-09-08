package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryOpeningPort;
import com.uten.imp.application.port.InventoryLegacyResolutionEvidencePort;
import com.uten.imp.application.port.InventoryLegacyResolutionEvidencePort.ApprovedResolution;
import com.uten.imp.application.port.InventoryLegacyResolutionEvidencePort.ResolutionKind;
import com.uten.imp.application.port.InventoryValuationPort.*;
import com.uten.imp.features.stock.InventoryMutationLock;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.*;
import static com.uten.imp.features.stock.valuation.ValueMath.*;

/** Controlled legacy opening; no physical movement or GL is fabricated. */
@Service
public class InventoryOpeningService extends InventoryValueLedger implements InventoryOpeningPort {
    private final Optional<InventoryLegacyResolutionEvidencePort> resolutionEvidence;

    public InventoryOpeningService(NamedParameterJdbcTemplate db, InventoryMutationLock inventoryMutex) {
        this(db,inventoryMutex,Optional.empty());
    }

    @Autowired
    public InventoryOpeningService(NamedParameterJdbcTemplate db, InventoryMutationLock inventoryMutex,
                                   Optional<InventoryLegacyResolutionEvidencePort> resolutionEvidence) {
        super(db,inventoryMutex);
        this.resolutionEvidence=resolutionEvidence;
    }

    @Override @Transactional(propagation = Propagation.MANDATORY)
    public OpeningValue open(Opening command) {
        transaction();
        EventContext context=context(command.context());PoolKey key=key(command.pool());requireHeld(key);
        if(!"INVENTORY_OPENING".equals(context.sourceDocType()))throw invalid("库存开账须使用独立的开账来源事件");
        BigDecimal quantity=positive(command.expectedQtyBase(),"待开账的现存基本数量");
        BigDecimal recorded=command.expectedRecordedValueLocal()==null?null:decimal(command.expectedRecordedValueLocal(),"原记录金额",true);
        if(command.costFinal()&&command.knownCostLocal()==null)throw invalid("未提供核定成本，不能作为已核定开账");
        BigDecimal known=command.knownCostLocal()==null?null:sourceAmount(command.knownCostLocal(),"已核定开账原额",false);
        return performOpening(new OpeningIntent(context,key,quantity,recorded,known,
                command.costFinal()?"APPROVED_OPENING":"PENDING_REVIEW","OPENING",explanation(command.reason())));
    }

    @Override @Transactional(propagation = Propagation.MANDATORY)
    public EmptyCycleValue startEmptyCycle(EmptyCycle command){
        transaction();EventContext context=context(command.context());PoolKey key=key(command.pool());requireHeld(key);
        if(!"INVENTORY_EMPTY_CYCLE".equals(context.sourceDocType()))throw invalid("旧空库存须使用独立的新周期开账事件");
        BigDecimal recorded=command.expectedRecordedValueLocal()==null?null:decimal(command.expectedRecordedValueLocal(),"原记录金额",true);
        OpeningValue value=performOpening(new OpeningIntent(context,key,ZERO,recorded,ZERO,"EMPTY_CYCLE_START",
                "EMPTY_OPENING",explanation(command.reason())));
        return db.queryForObject("SELECT id,state FROM stock_value_legacy_balance_cases WHERE opening_event_id=:event",args("event",value.eventId()),
                (row,index)->new EmptyCycleValue(value,uuid(row,"id"),LegacyState.valueOf(row.getString("state"))));
    }

    private OpeningValue performOpening(OpeningIntent intent){
        EventContext context=intent.context();PoolKey key=intent.key();BigDecimal quantity=intent.qty(),recorded=intent.recorded();
        BigDecimal actualKnown=intent.known()==null?ZERO:intent.known();BigDecimal known=projection(actualKnown);boolean finalValue=!"PENDING_REVIEW".equals(intent.mode());
        Request request=request(intent.operation(),context,args("pool",keyText(key),"qty",quantity.toPlainString(),
                "recorded",recorded==null?null:recorded.toPlainString(),"known",intent.known()==null?null:sourceText(actualKnown),
                "mode",intent.mode(),"reason",intent.reason()));
        Event prior=replay(intent.operation(),context,request);if(prior!=null)return openingReplay(prior);
        Pool pool=findPool(key,true);
        Balance actual=balance(key);
        if(actual.rows()!=1||actual.qty().compareTo(quantity)!=0
                || (actual.amount()==null?recorded!=null:recorded==null||actual.amount().compareTo(recorded)!=0))
            throw conflict("现存数量或原记录金额已变化，请重新核对开账依据");
        if(quantity.signum()==0&&actual.empty()&&pool==null)throw conflict("当前没有旧库存价值残留，无需建立历史差额案件");
        if(pool==null){
            db.update("""
                    INSERT INTO stock_value_pools(id,warehouse_id,goods_id,color_id,state,legacy_qty,legacy_amount_local)
                    VALUES (:id,:warehouse,:goods,:color,'LEGACY_UNVERIFIED',:qty,:amount)
                    """,poolArgs(key,"id",UUID.randomUUID(),"qty",actual.qty(),"amount",actual.amount()));
            pool=findPool(key,true);
        }
        if(pool==null||pool.headId()!=null||!"LEGACY_UNVERIFIED".equals(pool.state()))
            throw conflict("该库存已经建立价值基准，后续只能按原来源追加成本调整");
        UUID eventId=UUID.randomUUID(),sourceId=UUID.randomUUID(),headId=UUID.randomUUID();
        db.update("""
                INSERT INTO stock_value_openings(event_id,pool_id,source_node_id,head_node_id,stock_balance_id,
                    observed_qty,observed_recorded_value,before_balance,known_value_local,opening_mode,reason)
                SELECT :event,:pool,:source,:head,b.id,:qty,:recorded,to_jsonb(b),:known,:mode,:reason
                FROM stock_balances b WHERE b.warehouse_id=:warehouse AND b.goods_id=:goods AND
                """+colorCondition("b.color_id",key),poolArgs(key,"event",eventId,"pool",pool.id(),"source",sourceId,
                "head",headId,"qty",quantity,"recorded",recorded,"known",intent.known()==null?null:known,"mode",intent.mode(),"reason",intent.reason()));
        Node source=createNode(sourceId,pool,"SOURCE",null,null,null,null,quantity,ZERO,ZERO,known,
                finalValue?0:1,false,finalValue,eventId);
        authority.initialSource(source.id(),actualKnown);
        Node head=createNode(headId,pool,"POOL",null,null,null,null,quantity,ZERO,quantity,known,pending(source),true,true,eventId);
        edge(source,head,ZERO,BigDecimal.ONE,BigDecimal.ONE,eventId);
        State state=state(head);
        insertEvent(eventId,intent.operation(),context,request,pool.id(),null,quantity,quantity,known,source.id(),head.id(),state,
                source.id(),1L,null,null,null,finalValue);
        posting(eventId,null,source.id(),"SOURCE",context.sourceEventId(),known.negate());
        posting(eventId,null,head.id(),"INVENTORY",pool.id(),known);
        if(quantity.signum()==0){
            UUID caseId=UUID.randomUUID();
            db.update("""
                    INSERT INTO stock_value_legacy_balance_cases(id,opening_event_id,pool_id,observed_recorded_value,
                        original_balance,original_pool,opened_by_user_id,opened_by_employee_id)
                    SELECT :id,:event,p.id,o.observed_recorded_value,o.before_balance,to_jsonb(p),:user,:employee
                    FROM stock_value_openings o JOIN stock_value_pools p ON p.id=o.pool_id WHERE o.event_id=:event
                    """,args("id",caseId,"event",eventId,"user",context.actorUserId(),"employee",context.actorEmployeeId()));
            insertCaseEvent(UUID.randomUUID(),caseId,"OPENED",context,request,intent.reason(),null,null);
        }
        if(db.update("UPDATE stock_value_pools SET state='ACTIVE',head_node_id=:head WHERE id=:id AND state='LEGACY_UNVERIFIED' AND head_node_id IS NULL",
                args("head",head.id(),"id",pool.id()))!=1)throw conflict("开账状态已变化，禁止重复建立期初成本");
        if(db.update("UPDATE stock_balances SET amount_local=:known WHERE warehouse_id=:warehouse AND goods_id=:goods AND "
                +colorCondition("color_id",key)+" AND qty=:qty AND amount_local IS NOT DISTINCT FROM CAST(:recorded AS numeric)",
                poolArgs(key,"known",known,"qty",quantity,"recorded",recorded))!=1)throw conflict("旧库存基准已变化，开账已全部撤回");
        return new OpeningValue(eventId,pool.id(),source.id(),head.id(),quantity,known,state,false);
    }

    private OpeningValue openingReplay(Event event){
        List<OpeningValue> rows=db.query("SELECT pool_id,observed_qty FROM stock_value_openings WHERE event_id=:id",args("id",event.id()),
                (r,index)->new OpeningValue(event.id(),uuid(r,"pool_id"),event.resultNodeId(),event.resultHeadId(),
                        r.getBigDecimal("observed_qty"),event.knownValue(),event.state(),true));
        if(rows.size()!=1)throw conflict("开账事件缺少原库存依据，禁止重建或猜测");
        return rows.getFirst();
    }

    @Override @Transactional(readOnly=true)
    public LegacyCaseView legacyCase(UUID caseId){return caseRow(caseId,false);}

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public LegacyCaseAction noteLegacyCase(EventContext raw,UUID caseId,String note){
        transaction();EventContext context=caseContext(raw);String reason=explanation(note);
        Request request=request("LEGACY_NOTE",context,args("case",caseId,"note",reason));
        LegacyCaseAction prior=caseReplay("NOTE",context,request);if(prior!=null)return prior;
        LegacyCaseView current=caseRow(caseId,true);UUID event=UUID.randomUUID();
        prior=caseReplay("NOTE",context,request);if(prior!=null)return prior;
        insertCaseEvent(event,caseId,"NOTE",context,request,reason,null,null);
        return new LegacyCaseAction(event,caseId,current.state(),false);
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public LegacyCaseAction closeLegacyCase(EventContext raw,UUID caseId,UUID approvedResolutionDecisionId){
        transaction();EventContext context=caseContext(raw);required(approvedResolutionDecisionId,"库存历史差额审批决定UUID");
        Request request=request("LEGACY_RESOLVE",context,args("case",caseId,"approval",approvedResolutionDecisionId));
        LegacyCaseAction prior=caseReplay("RESOLVED",context,request);if(prior!=null)return prior;
        LegacyCaseView current=caseRow(caseId,true);
        prior=caseReplay("RESOLVED",context,request);if(prior!=null)return prior;
        if(current.state()!=LegacyState.OPEN)throw conflict("该历史金额核对已办结，请查看原财务依据");
        InventoryLegacyResolutionEvidencePort authority=resolutionEvidence.orElseThrow(
                ()->conflict("库存历史差额的财务审批证据尚未接入，不能用普通有效凭证代替批准"));
        ApprovedResolution evidence=authority.findApproved(caseId,approvedResolutionDecisionId)
                .orElseThrow(()->conflict("未取得本案有效的财务批准及前向账务处理证据"));
        validateEvidence(evidence,caseId,approvedResolutionDecisionId);
        Request evidenceSnapshot=request("APPROVED_LEGACY_RESOLUTION",context,args("case",caseId,
                "approvalDecision",evidence.approvalDecisionId(),"decisionVersion",evidence.decisionVersion(),
                "approvedByUser",evidence.approvedByUserId(),"approvedByEmployee",evidence.approvedByEmployeeId(),
                "approvedAt",evidence.approvedAt().toInstant().toString(),"kind",evidence.kind().name(),
                "adjustmentLocal",evidence.approvedAdjustmentLocal().toPlainString(),"forwardGlEvent",evidence.forwardGlEventId(),
                "explanation",evidence.explanation(),"evidenceHash",evidence.evidenceHash()));
        UUID eventId=UUID.randomUUID();
        insertCaseEvent(eventId,caseId,"RESOLVED",context,request,evidence.explanation(),approvedResolutionDecisionId,evidenceSnapshot.json());
        if(db.update("""
                UPDATE stock_value_legacy_balance_cases SET state='RESOLVED',version=version+1,resolution_event_id=:event
                WHERE id=:id AND state='OPEN' AND version=:version
                """,args("event",eventId,"id",caseId,"version",current.version()))!=1)throw conflict("历史核对状态已变化，请刷新");
        return new LegacyCaseAction(eventId,caseId,LegacyState.RESOLVED,false);
    }

    private LegacyCaseView caseRow(UUID id,boolean lock){
        required(id,"历史余额案件UUID");
        List<LegacyCaseView> rows=db.query("""
                SELECT c.*,p.warehouse_id,p.goods_id,p.color_id,e.approval_decision_id
                FROM stock_value_legacy_balance_cases c JOIN stock_value_pools p ON p.id=c.pool_id
                LEFT JOIN stock_value_legacy_balance_case_events e ON e.id=c.resolution_event_id
                WHERE c.id=:id
                """+(lock?" FOR UPDATE OF c":""),args("id",id),(r,i)->new LegacyCaseView(uuid(r,"id"),
                new PoolKey(uuid(r,"warehouse_id"),uuid(r,"goods_id"),uuid(r,"color_id")),uuid(r,"opening_event_id"),
                r.getBigDecimal("observed_recorded_value"),LegacyState.valueOf(r.getString("state")),r.getLong("version"),
                uuid(r,"approval_decision_id"),r.getObject("created_at",OffsetDateTime.class)));
        if(rows.size()!=1)throw conflict("历史余额核对记录不存在");return rows.getFirst();
    }

    private LegacyCaseAction caseReplay(String kind,EventContext context,Request request){
        List<Map<String,Object>> rows=db.queryForList("""
                SELECT e.id,e.case_id,e.request_hash,c.state FROM stock_value_legacy_balance_case_events e
                JOIN stock_value_legacy_balance_cases c ON c.id=e.case_id
                WHERE e.event_type=:kind AND e.source_item_id=:item AND (e.source_event_id=:event OR e.idempotency_key=:key)
                """,args("kind",kind,"item",context.sourceItemId(),"event",context.sourceEventId(),"key",context.idempotencyKey()));
        if(rows.isEmpty())return null;
        if(rows.size()!=1||!request.hash().equals(rows.getFirst().get("request_hash")))throw conflict("同一历史核对幂等键对应不同内容");
        var row=rows.getFirst();return new LegacyCaseAction((UUID)row.get("id"),(UUID)row.get("case_id"),LegacyState.valueOf((String)row.get("state")),true);
    }

    private void insertCaseEvent(UUID eventId,UUID caseId,String type,EventContext c,Request request,String note,UUID approval,String evidence){
        db.update("""
                INSERT INTO stock_value_legacy_balance_case_events(id,case_id,event_type,source_event_id,source_doc_id,
                    source_item_id,source_version,actor_user_id,actor_employee_id,occurred_at,idempotency_key,request_hash,
                    request_payload,note,approval_decision_id,approval_evidence)
                VALUES (:id,:case,:type,:source,:doc,:item,:version,:user,:employee,:at,:key,:hash,CAST(:payload AS jsonb),:note,:approval,CAST(:evidence AS jsonb))
                """,args("id",eventId,"case",caseId,"type",type,"source",c.sourceEventId(),"doc",c.sourceDocId(),"item",c.sourceItemId(),
                "version",c.sourceVersion(),"user",c.actorUserId(),"employee",c.actorEmployeeId(),"at",c.occurredAt(),"key",c.idempotencyKey(),
                "hash",request.hash(),"payload",request.json(),"note",note,"approval",approval,"evidence",evidence));
    }

    private static EventContext caseContext(EventContext raw){
        EventContext context=context(raw);
        if(!"INVENTORY_LEGACY_RECONCILIATION".equals(context.sourceDocType()))throw invalid("历史金额核对须有独立的核对事件来源");
        return context;
    }
    private static String explanation(String raw){String text=raw==null?"":raw.trim();if(text.isEmpty()||text.length()>1000)throw invalid("须说明核定依据或待核对原因（1至1000字）");return text;}
    private static void validateEvidence(ApprovedResolution evidence,UUID caseId,UUID decision){
        if(!caseId.equals(evidence.caseId())||!decision.equals(evidence.approvalDecisionId())||evidence.decisionVersion()<1
                ||evidence.approvedByUserId()==null||evidence.approvedByEmployeeId()==null||evidence.approvedAt()==null||evidence.kind()==null
                ||evidence.evidenceHash()==null||!evidence.evidenceHash().matches("[0-9a-f]{64}"))throw conflict("财务批准证据与本案不一致");
        BigDecimal amount=decimal(evidence.approvedAdjustmentLocal(),"财务批准的前向调整金额",true);explanation(evidence.explanation());
        if(evidence.kind()==ResolutionKind.FORWARD_ADJUSTMENT&&(amount.signum()==0||evidence.forwardGlEventId()==null)
                ||evidence.kind()==ResolutionKind.NO_ADJUSTMENT_REQUIRED&&(amount.signum()!=0||evidence.forwardGlEventId()!=null))
            throw conflict("财务批准的处理方式与前向账务证据不一致");
    }
    private record OpeningIntent(EventContext context,PoolKey key,BigDecimal qty,BigDecimal recorded,BigDecimal known,String mode,String operation,String reason){}

}
