package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.features.admin.workflow.WorkflowReviewerEligibility;
import com.uten.imp.application.port.ProcurementOrderApprovalPort;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.RemainingLine;
import com.uten.imp.application.port.ProcurementOrderTerminationSourcePort;
import com.uten.imp.application.port.TaskClaimMutationGuardPort;
import com.uten.imp.common.concurrency.ProcurementMutationLocks;
import com.uten.imp.common.finance.ExactDecimalText;
import com.uten.imp.common.finance.ProcurementOrderQuantityBounds;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.application.port.ProcurementClosureNoticePort;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;

/** Stops only future delivery obligations. Received stock, quality work, AP and supplier custody remain facts. */
@Service
public class ProcurementOrderClosureService {
    public static final String EVENT_CLOSED = "PROCUREMENT_ORDER_CLOSED";
    private final JdbcTemplate jdbc;
    private final EntityManager em;
    private final ObjectMapper mapper;
    private final Map<String, ProcurementOrderApprovalPort> ports;
    private final ProcurementMutationLocks locks;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final WorkflowReviewerEligibility reviewers;
    private final BusinessEventPublisher events;
    private final ProcurementClosureNoticePort notices;
    private final TaskClaimMutationGuardPort claims;
    private final ProcurementOrderTerminationSourcePort sources;
    @org.springframework.beans.factory.annotation.Autowired
    private org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.SubcontractPreStockReleasePort> preStockRelease;

    public ProcurementOrderClosureService(JdbcTemplate jdbc, EntityManager em, ObjectMapper mapper,
            List<ProcurementOrderApprovalPort> ports, ProcurementMutationLocks locks,
            SecurityContextCurrentUser currentUser, TxSessionVars tx, WorkflowReviewerEligibility reviewers,
            BusinessEventPublisher events, ProcurementClosureNoticePort notices, TaskClaimMutationGuardPort claims,
            ProcurementOrderTerminationSourcePort sources) {
        this.jdbc=jdbc; this.em=em; this.mapper=mapper;
        this.ports=ports.stream().collect(Collectors.toUnmodifiableMap(ProcurementOrderApprovalPort::orderType,Function.identity()));
        this.locks=locks; this.currentUser=currentUser; this.tx=tx; this.reviewers=reviewers;
        this.events=events; this.notices=notices; this.claims=claims; this.sources=sources;
    }

    public record ClosureRequest(@NotBlank String mode, @NotBlank @Size(max=1000) String reason,
                                 @NotBlank String expectedFingerprint) {}
    public record ClosurePreview(String orderType,UUID orderId,String billNo,String fingerprint,
                                 boolean canSubmit,String blockReason,List<ClosureLine> items,
                                 boolean canReorder,String blockReorderReason,boolean unverifiedQuantity,
                                 ClosureBlocker blocker) {}
    /** A known document target; navigation still requires the target department's live view permission. */
    public record ClosureBlocker(String kind,String orderType,UUID orderId,String billNo,UUID documentId) {}
    private record ClosureBlock(String reason,ClosureBlocker target) {}
    public record ClosureLine(UUID orderItemId,int lineNo,String goodsCode,String goodsName,String unitName,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal orderedQty,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal receivedQty,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal returnedQty,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal settledLossQty,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal remainingQty,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal giftQty,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal giftReceivedQty,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal giftReturnedQty,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal remainingGiftQty) {}

    @Transactional
    @PreAuthorize("hasAnyAuthority('purchase_order:view','subcontract_order:view')")
    public ClosurePreview preview(String rawType,UUID id) {
        tx.bind(); String type=kind(rawType); requirePermission(type,"view");
        var guard=locks.order(type,id);
        ports.get(type).requireFinanceSubmitterWritable(id);
        guard.verifyUnchanged();
        return facts(type,id);
    }

    @Transactional
    @PreAuthorize("hasAnyAuthority('purchase_order:submit_finance','subcontract_order:submit_finance')")
    public FinanceApproval submit(String rawType,UUID id,ClosureRequest request) {
        tx.bind(); String type=kind(rawType); requirePermission(type,"view"); requirePermission(type,"submit_finance");
        if(request==null) throw invalid("请选择直接结束或结束并重建剩余订单");
        String mode=request.mode();
        if (mode==null || !Set.of("CLOSE","CLOSE_AND_REORDER").contains(mode)) throw invalid("请选择直接结束或结束并重建剩余订单");
        String reason=request.reason()==null?"":request.reason().strip();
        if(reason.isEmpty()||reason.length()>1000) throw invalid("请填写结束原因，最多1000字");
        var guard=locks.ordersWithHeldPreStock(List.of(new com.uten.imp.common.concurrency.ProcurementMutationFootprint.OrderRef(type,id)));
        ProcurementOrderApprovalPort port=ports.get(type);
        port.requireFinanceSubmitterWritable(id); guard.verifyUnchanged();
        UUID completed=completedMatchingRequest(type,id,mode,reason,request.expectedFingerprint());
        if(completed!=null) return decision(completed);
        ClosurePreview preview=facts(type,id);
        if(!preview.canSubmit()) throw conflict(preview.blockReason());
        if(!preview.fingerprint().equals(request.expectedFingerprint())) throw conflict("订单收退货或物料事实已变化，请重新核对剩余数量后提交");
        if(mode.equals("CLOSE_AND_REORDER") && !preview.canReorder())
            throw conflict(preview.blockReorderReason());
        cancelLegacyPendingClosures(type,id);
        var snapshot=port.lockFinanceReconfirmationSnapshot(id);
        Map<String,Object> submitted=readMap(ProcurementApprovalSnapshot.json(snapshot,mapper));
        Map<String,Object> closure=new LinkedHashMap<>();
        closure.put("mode",mode);closure.put("reason",reason);closure.put("fingerprint",preview.fingerprint());closure.put("items",preview.items());
        closure.put("unverifiedQuantity",preview.unverifiedQuantity());
        closure.put("executionMode","DIRECT");
        closure.put("closedAt",jdbc.queryForObject("SELECT now()",OffsetDateTime.class));
        closure.put("closedByName",jdbc.queryForObject("SELECT full_name FROM employees WHERE id=?",String.class,currentUser.requireEmployeeId()));
        submitted.put("closureRequest",closure);
        String snapshotJson=json(submitted);
        UUID caseId=UUID.randomUUID();
        Integer attempt=jdbc.queryForObject("SELECT COALESCE(MAX(attempt),0)+1 FROM procurement_order_approval_cases WHERE order_type=? AND order_id=?",Integer.class,type,id);
        jdbc.update("""
                INSERT INTO procurement_order_approval_cases(id,order_type,order_id,attempt,bill_no_snapshot,
                    amount_snapshot,submission_snapshot,snapshot_hash,submitted_by_user_id,submitted_by_employee_id,
                    status,version,request_type,decided_at,decided_by_user_id,decided_by_employee_id,decided_txid)
                VALUES(?,?,?,?,?,?,CAST(? AS jsonb),?,?,?,'APPROVED',1,?,now(),?,?,txid_current())
                """,caseId,type,id,attempt,snapshot.billNo(),zero(snapshot.totalLocal()),snapshotJson,HashUtil.sha256(snapshotJson),
                currentUser.requireId(),currentUser.requireEmployeeId(),mode,currentUser.requireId(),currentUser.requireEmployeeId());
        return complete(type,id,caseId,1,preview,mode,currentUser.requireEmployeeId(),reason);
    }

    @Transactional(readOnly=true,propagation=Propagation.MANDATORY)
    public boolean isClosureCase(UUID caseId) {
        return Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM procurement_order_approval_cases WHERE id=? AND request_type<>'ORDER')",Boolean.class,caseId));
    }

    /** Closure is owned by procurement; historical pending requests must be rechecked there. */
    @Transactional(propagation=Propagation.MANDATORY)
    public FinanceApproval approve(String type,UUID orderId,UUID caseId,long version,String remark) {
        throw conflict("结束订单已改由采购或委外直接办理，请回原订单重新核对剩余数量后结束");
    }

    @Transactional(propagation=Propagation.MANDATORY)
    public FinanceApproval reject(String type,UUID orderId,UUID caseId,long version,String reason) {
        throw conflict("结束订单已改由采购或委外直接办理，无需财务审批或退回");
    }

    private FinanceApproval complete(String type,UUID orderId,UUID caseId,long version,ClosurePreview current,
            String mode,UUID employee,String reason) {
        UUID actor=currentUser.requireId();
        List<RemainingLine> remaining=current.items().stream().map(line->new RemainingLine(line.orderItemId(),line.remainingQty(),line.remainingGiftQty())).toList();
        ports.get(type).cancelUnfulfilledWorkForTermination(orderId);
        sources.apply(type,orderId,caseId,remaining);
        UUID replacement=null;
        if(mode.equals("CLOSE_AND_REORDER")) {
            replacement=ports.get(type).createRemainingDraft(orderId,remaining,employee);
            sources.linkReplacement(type,orderId,replacement,caseId);
            jdbc.update("UPDATE procurement_order_approval_cases SET replacement_order_id=? WHERE id=?",replacement,caseId);
        }
        int closed=jdbc.update("UPDATE "+prefix(type)+"_orders SET termination_case_id=?,is_closed=TRUE,updated_at=now(),updated_by=?"
                +" WHERE id=? AND termination_case_id IS NULL",caseId,actor,orderId);
        if(closed!=1) throw conflict("订单结束状态已变化，请刷新");
        if(type.equals("SUBCONTRACT")&&preStockRelease!=null) {
            preStockRelease.ifAvailable(port->port.releaseHeldPreStock(current.items().stream().map(ClosureLine::orderItemId).toList()));
        }
        jdbc.update("UPDATE inbound_expectations SET status='CLOSED',updated_at=now() WHERE order_type=? AND order_id=? AND status<>'CANCELED'",type,orderId);
        notices.resolveArrivalExpectationNotices(type,orderId);
        Map<String,Object> audit=new LinkedHashMap<>();audit.put("requestType",mode);audit.put("fingerprint",current.fingerprint());
        audit.put("executionMode","DIRECT");audit.put("replacementOrderId",replacement);audit.put("items",current.items());
        event(caseId,"CLOSED",reason,audit);
        publish(EVENT_CLOSED,caseId,type,"APPROVED",version);
        em.clear();
        return decision(caseId);
    }

    /** A retry after an unknown HTTP outcome returns the original result without replaying mutations. */
    UUID completedMatchingRequest(String type,UUID order,String mode,String reason,String fingerprint) {
        return firstId("""
                SELECT c.id FROM procurement_order_approval_cases c
                JOIN %s_orders h ON h.id=c.order_id AND h.termination_case_id=c.id
                WHERE c.order_type=? AND c.order_id=? AND c.status='APPROVED' AND c.request_type=?
                  AND c.submission_snapshot #>> '{closureRequest,executionMode}'='DIRECT'
                  AND c.submission_snapshot #>> '{closureRequest,fingerprint}'=?
                  AND c.submission_snapshot #>> '{closureRequest,reason}'=?
                """.formatted(prefix(type)),type,order,mode,fingerprint,reason);
    }

    private void cancelLegacyPendingClosures(String type,UUID order) {
        List<UUID> pending=jdbc.queryForList("""
                SELECT id FROM procurement_order_approval_cases WHERE order_type=? AND order_id=?
                  AND status='PENDING' AND request_type<>'ORDER' ORDER BY id FOR UPDATE
                """,UUID.class,type,order);
        for(UUID id:pending) {
            jdbc.update("UPDATE procurement_order_approval_cases SET status='CANCELED',version=version+1,updated_at=now() WHERE id=? AND status='PENDING'",id);
            event(id,"CANCELED","结束订单改由采购或委外直接办理，重新核对后执行",Map.of("sourceAction","DIRECT_CLOSURE"));
            notices.resolveReviewNotices("PROCUREMENT_APPROVAL_CASE",id,"DIRECT_CLOSURE");
            claims.releaseAfterBusinessResolution("PROCUREMENT_FINANCE_APPROVE",id.toString());
        }
    }

    private ClosurePreview facts(String type,UUID id) {
        String prefix=prefix(type);
        List<Map<String,Object>> headers=jdbc.queryForList("SELECT id,bill_no,legacy_id,status,is_deleted,is_closed,termination_case_id FROM "+prefix+"_orders WHERE id=?",id);
        if(headers.size()!=1||Boolean.TRUE.equals(headers.getFirst().get("is_deleted"))) throw new ApiException(ErrorCode.NOT_FOUND,"订货单不存在");
        Map<String,Object> header=headers.getFirst();
        List<ClosureLine> items=new ArrayList<>();
        List<Map<String,Object>> rows=jdbc.queryForList("""
                SELECT i.*,COALESCE(NULLIF(i.goods_code_snapshot,''),g.code) AS goods_code,
                    COALESCE(NULLIF(i.goods_name_snapshot,''),g.name) AS goods_name,u.name AS unit_name,
                    %2$s AS settled_loss FROM %1$s_order_items i LEFT JOIN goods g ON g.id=i.goods_id
                    LEFT JOIN units u ON u.id=i.unit_id WHERE i.order_id=? AND NOT i.is_deleted ORDER BY i.line_no NULLS LAST,i.id
                """.formatted(prefix,type.equals("SUBCONTRACT")?"fn_subcontract_settled_loss_qty(i.id)":"0::numeric"),id);
        boolean standaloneLegacy=header.get("legacy_id")!=null
                && rows.stream().noneMatch(row->row.get(type.equals("PURCHASE")?"request_item_id":"application_item_id")!=null)
                && !Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM "+prefix+"_order_item_sources s JOIN "+prefix+"_order_items i ON i.id=s.order_item_id WHERE i.order_id=?)",Boolean.class,id))
                && !Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM production_material_supply_pegs p JOIN "+prefix+"_order_items i ON i.id=p.supply_item_id WHERE i.order_id=?)",Boolean.class,id));
        boolean unverified=false;
        for(Map<String,Object> row:rows) {
            UUID itemId=(UUID)row.get("id");
            BigDecimal rate=decimal(row,"unit_rate");
            BigDecimal retained=null;
            try {
                if(rate.signum()<=0) throw conflict("订单单位换算率尚未核验，请先核对原始计量依据");
                var bound=ProcurementOrderQuantityBounds.receipts(em,type,itemId);
                retained=bound.retainedBase().divide(rate,4,RoundingMode.CEILING);
            } catch(ApiException unknownBasis) {
                if(!standaloneLegacy) throw unknownBasis;
                unverified=true;
            }
            BigDecimal ordered=decimal(row,"qty"),loss=decimal(row,"settled_loss");
            BigDecimal gift=type.equals("PURCHASE")&&"CHARGED_PLUS_GIFT_V1".equals(row.get("quantity_semantics"))?decimal(row,"gift_qty"):BigDecimal.ZERO;
            BigDecimal giftReceived=decimal(row,"gift_received_qty"),giftReturned=decimal(row,"gift_returned_qty");
            items.add(new ClosureLine(itemId,row.get("line_no")==null?0:((Number)row.get("line_no")).intValue(),
                    (String)row.get("goods_code"),(String)row.get("goods_name"),(String)row.get("unit_name"),ordered,
                    decimal(row,"received_qty"),decimal(row,"returned_qty"),loss,retained==null?null:ordered.subtract(retained).subtract(loss).max(BigDecimal.ZERO),
                    gift,giftReceived,giftReturned,retained==null?null:gift.subtract(giftReceived).add(giftReturned).max(BigDecimal.ZERO)));
        }
        Map<String,Object> fingerprint=new LinkedHashMap<>();fingerprint.put("order",id);fingerprint.put("items",rows);
        if(((Number)header.get("status")).intValue()==1) fingerprint.put("commercial",ProcurementApprovalSnapshot.json(ports.get(type).lockFinanceReconfirmationSnapshot(id),mapper));
        fingerprint.put("receipts",jdbc.queryForList("SELECT to_jsonb(i)::text AS item,to_jsonb(h)::text AS header FROM "+prefix+"_receipt_items i JOIN "+prefix+"_receipts h ON h.id=i.receipt_id JOIN "+prefix+"_order_items oi ON oi.id=i.order_item_id WHERE oi.order_id=? ORDER BY i.id",id));
        fingerprint.put("returns",jdbc.queryForList("SELECT to_jsonb(i)::text AS item,to_jsonb(h)::text AS header FROM "+prefix+"_return_items i JOIN "+prefix+"_returns h ON h.id=i.return_id JOIN "+prefix+"_order_items oi ON oi.id=i.order_item_id WHERE oi.order_id=? ORDER BY i.id",id));
        fingerprint.put("inspection",jdbc.queryForList("SELECT to_jsonb(i)::text AS item FROM procurement_inspection_items i JOIN "+prefix+"_receipt_items ri ON ri.id=i.receipt_item_id JOIN "+prefix+"_order_items oi ON oi.id=ri.order_item_id WHERE i.receipt_type=? AND oi.order_id=? ORDER BY i.id",type,id));
        fingerprint.put("iqcReturns",jdbc.queryForList("SELECT to_jsonb(r)::text AS rejection FROM procurement_iqc_rejection_cases r JOIN "+prefix+"_order_items oi ON oi.id=r.order_item_id WHERE r.receipt_type=? AND oi.order_id=? ORDER BY r.id",type,id));
        fingerprint.put("sources",jdbc.queryForList("SELECT to_jsonb(s)::text AS source FROM "+prefix+"_order_item_sources s JOIN "+prefix+"_order_items i ON i.id=s.order_item_id WHERE i.order_id=? ORDER BY s.id",id));
        if(type.equals("SUBCONTRACT")) {
            fingerprint.put("custody",jdbc.queryForList("SELECT to_jsonb(p)::text AS plan FROM subcontract_material_plan_items p JOIN subcontract_material_plans h ON h.id=p.plan_id WHERE h.order_id=? ORDER BY p.id",id));
            fingerprint.put("issued",jdbc.queryForList("SELECT to_jsonb(i)::text AS item,to_jsonb(h)::text AS header FROM subcontract_material_issue_items i JOIN subcontract_material_issues h ON h.id=i.issue_id JOIN subcontract_order_items oi ON oi.id=i.order_item_id WHERE oi.order_id=? ORDER BY i.id",id));
        }
        String billNo=(String)header.get("bill_no");
        ClosureBlock downstream=downstreamBlock(type,id,billNo);
        String blocked=null;
        ClosureBlocker blocker=null;
        boolean hasRemaining=items.stream().anyMatch(line->zero(line.remainingQty()).signum()>0||zero(line.remainingGiftQty()).signum()>0);
        boolean naturallyClosed=Boolean.TRUE.equals(header.get("is_closed")) || (!unverified&&!hasRemaining);
        boolean importedHistory=header.get("legacy_id")!=null;
        String historicalReadOnly="历史原始单据仅供核对，不能申请提前结束或按剩余量重建";
        if(importedHistory) blocked=historicalReadOnly;
        else if(((Number)header.get("status")).intValue()!=1) blocked="仅已生效订货单可取消剩余数量并结束";
        else if(header.get("termination_case_id")!=null) blocked="该订单已取消剩余数量并结束";
        else if(naturallyClosed) blocked="该订单已完成，没有待取消的剩余数量";
        else if(!hasPermission(type,"submit_finance")) blocked="没有采购或委外订单办理权限";
        else if(downstream!=null) { blocked=downstream.reason();blocker=downstream.target(); }
        else {
            UUID pending=firstId("SELECT id FROM procurement_order_approval_cases WHERE order_type=? AND order_id=? AND status='PENDING' AND request_type='ORDER' ORDER BY attempt DESC LIMIT 1",type,id);
            if(pending!=null) {
                blocked="订单已有待处理财务审批";
                blocker=new ClosureBlocker("FINANCE",type,id,billNo,pending);
            }
        }
        String blockReorder=importedHistory?historicalReadOnly:naturallyClosed?"该订单已完成，没有可重建的剩余数量":unverified?"计量依据尚未核验，不能按剩余量重建":hasRemaining?null:"当前没有可重建的剩余数量";
        return new ClosurePreview(type,id,billNo,HashUtil.sha256(json(fingerprint)),blocked==null,blocked,List.copyOf(items),
                !importedHistory&&!naturallyClosed&&!unverified&&hasRemaining,blockReorder,unverified,blocker);
    }

    private ClosureBlock downstreamBlock(String type,UUID order,String billNo) {
        String prefix=prefix(type);
        UUID document=firstId("SELECT i.receipt_id FROM procurement_inspection_items i JOIN "+prefix+"_receipt_items ri ON ri.id=i.receipt_item_id JOIN "+prefix+"_order_items oi ON oi.id=ri.order_item_id WHERE i.receipt_type=? AND oi.order_id=? AND i.status NOT IN ('RESOLVED','REVERSED') ORDER BY i.receipt_id,i.id LIMIT 1",type,order);
        if(document!=null) return block("QUALITY_INSPECTION",type,order,billNo,document,
                "还有未完成的到货质检，请先完成质检和不合格品实物处置；订单结束后不能直接改写已核定的实收量");
        document=firstId("SELECT i.receipt_id FROM procurement_inspection_items i JOIN "+prefix+"_receipt_items ri ON ri.id=i.receipt_item_id JOIN "+prefix+"_order_items oi ON oi.id=ri.order_item_id WHERE i.receipt_type=? AND oi.order_id=? AND i.status<>'REVERSED' AND i.failed_base_qty>0 AND NOT EXISTS(SELECT 1 FROM procurement_iqc_rejection_cases r WHERE r.inspection_item_id=i.id AND NOT r.is_deleted AND r.return_recorded_at IS NOT NULL AND r.failed_base_qty=i.failed_base_qty) ORDER BY i.receipt_id,i.id LIMIT 1",type,order);
        if(document!=null) return block("WAREHOUSE_IQC_RETURN",type,order,billNo,document,
                "还有IQC不合格品未完成实物退回，请先处理后再核定剩余量；财务贷项可继续按原记录办理");
        document=firstId("SELECT h.id FROM "+prefix+"_receipt_items i JOIN "+prefix+"_receipts h ON h.id=i.receipt_id JOIN "+prefix+"_order_items oi ON oi.id=i.order_item_id WHERE oi.order_id=? AND h.status=0 AND h.legacy_id IS NULL AND NOT h.is_deleted AND NOT i.is_deleted ORDER BY h.id LIMIT 1",order);
        if(document!=null) return block("WAREHOUSE_RECEIPT",type,order,billNo,document,
                "还有未完成的收货草稿，请先在仓库完成收货或删除草稿后再结束");
        document=firstId("SELECT h.id FROM "+prefix+"_return_items i JOIN "+prefix+"_returns h ON h.id=i.return_id JOIN "+prefix+"_order_items oi ON oi.id=i.order_item_id WHERE oi.order_id=? AND h.status=0 AND h.legacy_id IS NULL AND NOT h.is_deleted AND NOT i.is_deleted ORDER BY h.id LIMIT 1",order);
        if(document!=null) return block("WAREHOUSE_RETURN",type,order,billNo,document,
                "还有未完成的退货草稿，请先完成退货或删除草稿后再核定剩余量");
        if(type.equals("SUBCONTRACT")) {
            document=firstId("SELECT h.id FROM subcontract_material_issue_items i JOIN subcontract_material_issues h ON h.id=i.issue_id JOIN subcontract_order_items oi ON oi.id=i.order_item_id WHERE oi.order_id=? AND h.status=0 AND h.legacy_id IS NULL AND NOT h.is_deleted AND NOT i.is_deleted ORDER BY h.id LIMIT 1",order);
            if(document!=null) return block("SUBCONTRACT_DRAW",type,order,billNo,document,
                    "还有待仓库发出的委外领料，请先撤回或完成这次发料后再结束");
        }
        document=firstId("SELECT id FROM procurement_arrival_exceptions WHERE order_type=? AND order_id=? AND status NOT IN ('RECEIPT_POSTED','CLOSED','CANCELED') ORDER BY id LIMIT 1",type,order);
        if(document!=null) return block("ARRIVAL_EXCEPTION",type,order,billNo,document,
                "还有未办结的到货异常或供应商退回，请先处理后再结束");
        return null;
    }

    private ClosureBlock block(String kind,String type,UUID order,String billNo,UUID document,String reason) {
        return new ClosureBlock(reason,new ClosureBlocker(kind,type,order,billNo,document));
    }
    private UUID firstId(String sql,Object...args) {
        List<UUID> ids=jdbc.queryForList(sql,UUID.class,args);
        return ids.isEmpty()?null:ids.getFirst();
    }

    private FinanceApproval decision(UUID id) {
        return jdbc.queryForObject("SELECT status,attempt,version,rejection_reason,submitted_at FROM procurement_order_approval_cases WHERE id=?",
                (rs,n)->new FinanceApproval(id,rs.getString(1),rs.getInt(2),rs.getLong(3),null,null,null,rs.getString(4),rs.getObject(5,OffsetDateTime.class),List.of()),id);
    }
    private void event(UUID id,String type,String reason,Map<String,?> data) {
        jdbc.update("INSERT INTO procurement_order_approval_events(id,case_id,event_type,actor_user_id,actor_employee_id,reason,event_snapshot) VALUES(?,?,?,?,?,?,CAST(? AS jsonb))",
                UUID.randomUUID(),id,type,currentUser.requireId(),currentUser.requireEmployeeId(),reason,json(data));
    }
    private void publish(String event,UUID id,String type,String status,long version) {
        events.publishOnce(event,"PROCUREMENT_APPROVAL_CASE",id,Map.of("orderType",type,"status",status,"version",version),event+":"+id+":"+version);
    }
    private boolean hasPermission(String type,String action) {
        return currentUser.get().map(user->user.isSuperAdmin()||user.getPermissions().contains(prefix(type)+"_order:"+action)).orElse(false);
    }
    private void requirePermission(String type,String action) {
        if(!hasPermission(type,action)) throw new ApiException(ErrorCode.FORBIDDEN,"没有该订货单的操作权限");
    }
    private static String kind(String type) {return ProcurementApprovalProjectionQuery.requireOrderType(type);}
    private static String prefix(String type) {return "PURCHASE".equals(type)?"purchase":"subcontract";}
    private static BigDecimal zero(BigDecimal value) {return value==null?BigDecimal.ZERO:value;}
    private static BigDecimal decimal(Map<String,Object> row,String key) {Object value=row.get(key);return value instanceof BigDecimal d?d:value instanceof Number n?new BigDecimal(n.toString()):BigDecimal.ZERO;}
    private String json(Object value) {try{return mapper.writeValueAsString(value);}catch(JsonProcessingException e){throw new IllegalStateException("结束审批快照无法序列化",e);}}
    private Map<String,Object> readMap(String json) {try{return mapper.readValue(json,new com.fasterxml.jackson.core.type.TypeReference<LinkedHashMap<String,Object>>(){});}catch(JsonProcessingException e){throw new IllegalStateException(e);}}
    private static ApiException conflict(String message) {return new ApiException(ErrorCode.CONFLICT,message);}
    private static ApiException invalid(String message) {return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
