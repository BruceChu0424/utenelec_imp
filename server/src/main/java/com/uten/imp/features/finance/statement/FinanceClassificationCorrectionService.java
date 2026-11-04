package com.uten.imp.features.finance.statement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.web.*;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceOpenItemClassificationContracts.*;
import static com.uten.imp.features.finance.statement.FinanceReceivableClassificationContracts.*;
import static com.uten.imp.features.finance.statement.FinanceOpenItemClassificationService.*;

/** One exact append-only metadata transaction. Never calls a cash, stock, debt or GL writer. */
@Service @RequiredArgsConstructor
public class FinanceClassificationCorrectionService {
    private final JdbcTemplate db;
    private final ObjectMapper json;
    private final FinanceOpenItemClassificationService base;
    private final FinanceReceivableClassificationService ar;
    private final SecurityContextCurrentUser current;
    public record Node(String kind,UUID objectId,UUID expectedBatchId,long expectedRevision,List<Map<String,String>> parts) { }
    public record Command(UUID requestId,List<UUID> ledgerIds,String expectedGraphFingerprint,String reason,List<Node> nodes) { }
    public record Resolve(Command original,String reason,String expectedCommandHash) { }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Map<String,Object> graph(List<UUID> ledgerIds){base.read();return readGraph(roots(ledgerIds));}

    private Map<String,Object> readGraph(List<UUID> roots){
        var nodes=new ArrayList<Map<String,Object>>();
        for(UUID id:roots)nodes.add(node("SOURCE",id));
        String placeholders=String.join(",",Collections.nCopies(roots.size(),"?"));
        var refs=db.queryForList("SELECT DISTINCT kind,object_id FROM v_finance_classification_actual_references WHERE ledger_id IN("+placeholders+") ORDER BY kind,object_id LIMIT 513",roots.toArray());
        if(refs.size()+roots.size()>512)throw invalid("关联图超过512个节点，请分批选择来源；当前输入与草稿保留，不能截断关联记录提交");
        for(var ref:refs)nodes.add(node(ref.get("kind").toString(),(UUID)ref.get("object_id")));
        Map<String,Object> first=fact(nodes.getFirst());
        for(var n:nodes)if("SOURCE".equals(n.get("kind"))){var f=fact(n);requireSourceVerified(f);if(!Objects.equals(first.get("direction"),f.get("direction"))||!Objects.equals(first.get("partyId"),f.get("partyId"))||!Objects.equals(first.get("currencyId"),f.get("currencyId")))throw invalid("同次更正须保留同一应收/应付方向、往来对象及实际币别");}
        var counterparts=new TreeMap<String,Object>();
        for(var n:nodes){var f=fact(n);for(String key:List.of("sourceLedgerId","targetLedgerId")){Object value=f.get(key);if(value instanceof UUID id&&!roots.contains(id)&&!("AR_OFFSET".equals(n.get("kind"))&&"sourceLedgerId".equals(key)&&"CUSTOMER_PREPAYMENT".equals(f.get("sourceOpenItemKind"))&&f.get("sourceLegacyImportId")==null))counterparts.put(id.toString(),node("SOURCE",id));}}
        var result=new LinkedHashMap<String,Object>();result.put("ledgerIds",roots);result.put("direction",first.get("direction"));result.put("partyId",first.get("partyId"));result.put("currencyId",first.get("currencyId"));result.put("nodes",nodes);result.put("readOnlySources",counterparts.values());
        result.put("graphFingerprint",base.fingerprint(result));return result;
    }

    private Map<String,Object> node(String kind,UUID id){
        String table,partTable,key;Map<String,Object> f;
        switch(kind){
            case "SOURCE" -> {table="finance_open_item_classification_batches";partTable="finance_open_item_classification_parts";key="ledger_id";f=base.sourceFact(id);}
            case "AP_PAYMENT" -> {table="finance_payment_classification_batches";partTable="finance_payment_classification_parts";key="payment_line_id";f=base.paymentFact(id);}
            case "AR_RECEIPT" -> {table="finance_receipt_classification_batches";partTable="finance_receipt_classification_parts";key="receipt_line_id";f=ar.receiptFact(id);}
            case "AP_OFFSET" -> {table="finance_supplier_offset_classification_batches";partTable="finance_supplier_offset_classification_parts";key="offset_id";f=base.offsetFact(id);}
            case "AR_OFFSET" -> {table="finance_customer_offset_classification_batches";partTable="finance_customer_offset_classification_parts";key="offset_id";f=ar.offsetFact(id);}
            case "AP_ADVANCE_TARGET" -> {table="finance_supplier_advance_target_classification_batches";partTable="finance_supplier_advance_target_classification_parts";key="application_id";f=db.queryForMap("SELECT a.id AS \"applicationId\",a.target_ledger_id AS \"targetLedgerId\",a.effective_date AS \"effectiveDate\",a.amount_original AS \"amountOriginal\",a.target_local AS \"targetLocal\",a.target_category AS \"originalCategory\",a.source_category AS \"assetSourceCategory\",a.source_local AS \"assetSourceLocal\",a.status,a.reversed_at AS \"reversedAt\" FROM finance_supplier_advance_applications a WHERE a.id=?",id);}
            default -> throw invalid("不支持的关联图节点");
        }
        var batch=base.latest(table,key,id);var result=new LinkedHashMap<String,Object>();result.put("kind",kind);result.put("objectId",id);result.put("expectedBatchId",batch==null?null:batch.get("id"));result.put("expectedRevision",batch==null?-1:batch.get("revision"));
        ReportQueryKit.includeDecimalTexts(f);result.put("fact",f);
        String actual=db.queryForObject("SELECT fn_finance_classification_node_fact(?,?)::text",String.class,kind,id);result.put("factFingerprint",base.fingerprint(actual));
        var parts=new ArrayList<Map<String,String>>();
        if(batch!=null)for(var p:base.parts(partTable,(UUID)batch.get("id")))parts.add(camelParts(p));
        else if("AP_ADVANCE_TARGET".equals(kind))parts.add(Map.of("category",f.get("originalCategory").toString(),"amountOriginal",f.get("amountOriginal").toString(),"targetLocal",f.get("targetLocal").toString()));
        result.put("parts",parts);return result;
    }

    @Transactional
    public Map<String,Object> preview(Command command){
        try{submit(command);db.execute("SET CONSTRAINTS ALL IMMEDIATE");return Map.of("status","VALIDATED","commandHash",base.fingerprint(command),"actorId",current.requireId());}
        finally{org.springframework.transaction.interceptor.TransactionAspectSupport.currentTransactionStatus().setRollbackOnly();}
    }

    @Transactional
    public Map<String,Object> submit(Command command){
        base.read();requireRequest(command==null?null:command.requestId());base.lock();
        String hash=base.fingerprint(command);var previous=db.queryForList("SELECT * FROM finance_classification_corrections WHERE request_id=?",command.requestId());
        if(!previous.isEmpty()){var receipt=previous.getFirst();if(!Objects.equals(receipt.get("created_by"),current.requireId())||!hash.equals(receipt.get("command_hash")))throw conflict("原请求已由另一操作人或不同完整内容提交，请保留原请求核对");return receipt(receipt);}
        var terminalRows=db.queryForList("SELECT * FROM finance_classification_request_receipts WHERE request_id=?",command.requestId());
        if(!terminalRows.isEmpty()){matchReceipt(terminalRows.getFirst(),hash);throw conflict("原更正请求已有终局封口回执，绝不会重新执行；请核对原结果后重新读取完整图");}
        var roots=roots(command.ledgerIds());String reason=reference(command.reason());
        // Money callers take this same family lock before touching ledger balances. Metadata never locks styles or periods.
        db.query("SELECT id FROM ar_ap_ledger WHERE id IN("+String.join(",",Collections.nCopies(roots.size(),"?"))+") ORDER BY id FOR UPDATE",rs->{},roots.toArray());
        var graph=readGraph(roots);if(!Objects.equals(command.expectedGraphFingerprint(),graph.get("graphFingerprint")))throw conflict("完整关联图或真实业务状态已变化，请重新读取并核对；原输入和未知请求保留");
        if(command.nodes()==null||command.nodes().size()!=list(graph.get("nodes")).size())throw invalid("须提交完整来源及全部实际关联行，不能只更正闲置或当前可见部分");
        var expected=new LinkedHashMap<String,Map<String,Object>>();for(var n:list(graph.get("nodes")))expected.put(key(n.get("kind").toString(),(UUID)n.get("objectId")),n);
        var commands=new LinkedHashMap<String,Node>();
        for(var n:command.nodes()){
            if(n==null||n.objectId()==null||commands.put(key(n.kind(),n.objectId()),n)!=null)throw invalid("更正节点缺失或重复");
            var old=expected.get(key(n.kind(),n.objectId()));if(old==null||!Objects.equals(n.expectedBatchId(),old.get("expectedBatchId"))||n.expectedRevision()!=((Number)old.get("expectedRevision")).longValue())throw conflict("关联行当前分类版本已变化");
            base.write(switch(n.kind()){case "AP_PAYMENT" -> "finance_payment:approve";case "AR_RECEIPT","AR_OFFSET" -> "finance_receipt:approve";default -> "AP".equals(graph.get("direction"))?"supplier_settlement:confirm":"finance_receipt:approve";});
        }
        UUID correction=UUID.randomUUID();db.update("INSERT INTO finance_classification_corrections(id,request_id,created_by,direction,party_id,currency_id,reason,graph_fingerprint,command_hash,command,status) VALUES(?,?,?,?,?,?,?,?,?,?::jsonb,'BUILDING')",correction,command.requestId(),current.requireId(),graph.get("direction"),graph.get("partyId"),graph.get("currencyId"),reason,graph.get("graphFingerprint"),hash,encode(command));
        var planned=new HashMap<String,UUID>();
        for(var n:command.nodes()){UUID batch=UUID.randomUUID();planned.put(key(n.kind(),n.objectId()),batch);db.update("INSERT INTO finance_classification_correction_nodes(correction_id,kind,object_id,old_batch_id,new_batch_id,fact)VALUES(?,?,?,?,?,'{}'::jsonb)",correction,n.kind(),n.objectId(),n.expectedBatchId(),batch);}
        // Sources first, then all dependent batches. Deferred constraints inspect the completed graph only.
        for(var n:command.nodes())if("SOURCE".equals(n.kind()))base.classifySource(n.objectId(),new SourceInput(planned.get(key(n.kind(),n.objectId())),n.expectedRevision(),null,reason,convert(n.parts(),Part.class)));
        for(var n:command.nodes()){
            UUID id=n.objectId(),batch=planned.get(key(n.kind(),id));var f=fact(expected.get(key(n.kind(),id)));
            switch(n.kind()){
                case "SOURCE" -> { }
                case "AP_PAYMENT" -> base.classifyPayment(id,new PaymentInput(batch,n.expectedRevision(),sourceBatch((UUID)f.get("ledgerId")),reason,convert(n.parts(),PaymentPart.class)));
                case "AR_RECEIPT" -> ar.classifyReceipt(id,new ReceiptInput(batch,n.expectedRevision(),sourceBatch((UUID)f.get("ledgerId")),reason,convert(n.parts(),ReceiptPart.class)));
                case "AP_OFFSET" -> base.classifyOffset(id,new OffsetInput(batch,n.expectedRevision(),sourceBatch((UUID)f.get("sourceLedgerId")),sourceBatch((UUID)f.get("targetLedgerId")),reason,convert(n.parts(),OffsetPart.class)));
                case "AR_OFFSET" -> {boolean prepay="CUSTOMER_PREPAYMENT".equals(f.get("sourceOpenItemKind"))&&f.get("sourceLegacyImportId")==null;ar.classifyOffset(id,new CustomerOffsetInput(batch,n.expectedRevision(),prepay?null:sourceBatch((UUID)f.get("sourceLedgerId")),sourceBatch((UUID)f.get("targetLedgerId")),reason,convert(n.parts(),OffsetPart.class)));}
                case "AP_ADVANCE_TARGET" -> {
                    db.update("INSERT INTO finance_supplier_advance_target_classification_batches(id,application_id,revision,correction_id,target_classification_id,created_by)VALUES(?,?,?,?,?,?)",batch,id,n.expectedRevision()+1,correction,sourceBatch((UUID)f.get("targetLedgerId")),current.requireId());
                    if(n.parts()==null||n.parts().isEmpty()||n.parts().size()>2)throw invalid("请完整填写预付应用目标归属");
                    for(var p:n.parts())db.update("INSERT INTO finance_supplier_advance_target_classification_parts(batch_id,category,amount_original,target_local)VALUES(?,?,?,?)",batch,p.get("category"),nonnegative(decimal(p,"amountOriginal"),true),nonnegative(decimal(p,"targetLocal"),false));
                }
                default -> throw invalid("不支持的更正节点");
            }
        }
        var result=new LinkedHashMap<String,Object>();result.put("correctionId",correction);result.put("requestId",command.requestId());result.put("status","APPLIED");result.put("nodes",planned);result.put("actorId",current.requireId());result.put("commandHash",hash);
        db.update("UPDATE finance_classification_corrections SET status='APPLIED',result=?::jsonb WHERE id=?",encode(result),correction);
        db.update("INSERT INTO finance_classification_request_receipts(request_id,created_by,command_hash,status,correction_id)VALUES(?,?,?,'APPLIED',?)",command.requestId(),current.requireId(),hash,correction);
        db.query("SELECT fn_assert_finance_classification_correction(?)",rs->{},correction);return receipt(Map.of("result",encode(result)));
    }

    @Transactional(readOnly=true)
    public Map<String,Object> receipt(UUID requestId){base.read();var rows=db.queryForList("SELECT * FROM finance_classification_request_receipts WHERE request_id=? AND created_by=?",requestId,current.requireId());if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"本人原请求尚无终局回执，请保留原内容与请求编号；未找到不能证明未写");var terminal=rows.getFirst();if("ABANDONED".equals(terminal.get("status")))return terminalReceipt(terminal);return receipt(db.queryForMap("SELECT * FROM finance_classification_corrections WHERE id=?",terminal.get("correction_id")));}

    /** Explicit metadata resolution, not an absent-read shortcut. The immutable UUID receipt fences a POST arriving later. */
    @Transactional
    public Map<String,Object> resolve(UUID requestId,Resolve input){
        base.read();requireRequest(requestId);if(input==null||input.original()==null||!requestId.equals(input.original().requestId()))throw invalid("请保留原请求编号与完整原命令，不能以当前编辑内容替代未知请求");
        String reason=reference(input.reason()),hash=base.fingerprint(input.original());if(!Objects.equals(hash,input.expectedCommandHash()))throw conflict("原完整命令校验与服务器原预览不一致，不能封口另一请求");base.lock();
        var applied=db.queryForList("SELECT * FROM finance_classification_corrections WHERE request_id=?",requestId);
        if(!applied.isEmpty()){matchReceipt(applied.getFirst(),hash);return receipt(applied.getFirst());}
        var terminal=db.queryForList("SELECT * FROM finance_classification_request_receipts WHERE request_id=?",requestId);
        if(terminal.isEmpty()){db.update("INSERT INTO finance_classification_request_receipts(request_id,created_by,command_hash,status,reason)VALUES(?,?,?,'ABANDONED',?)",requestId,current.requireId(),hash,reason);terminal=db.queryForList("SELECT * FROM finance_classification_request_receipts WHERE request_id=?",requestId);}
        matchReceipt(terminal.getFirst(),hash);return terminalReceipt(terminal.getFirst());
    }
    private void matchReceipt(Map<String,Object> receipt,String hash){if(!Objects.equals(receipt.get("created_by"),current.requireId())||!Objects.equals(receipt.get("command_hash"),hash))throw conflict("原请求属于另一操作人或不同完整命令，请保留原内容核对，不能封口另一请求");}
    private Map<String,Object> terminalReceipt(Map<String,Object> row){var result=new LinkedHashMap<String,Object>();result.put("requestId",row.get("request_id").toString());result.put("actorId",row.get("created_by").toString());result.put("commandHash",row.get("command_hash"));result.put("status",row.get("status"));result.put("createdAt",row.get("created_at").toString());return result;}
    private Map<String,Object> receipt(Map<String,Object> row){try{return json.readValue(row.get("result").toString(),json.getTypeFactory().constructMapType(LinkedHashMap.class,String.class,Object.class));}catch(Exception e){throw new IllegalStateException("分类更正回执读取失败",e);}}
    private UUID sourceBatch(UUID ledger){var value=base.latest("finance_open_item_classification_batches","ledger_id",ledger);if(value==null)throw invalid("抵销对端尚未明确分类，请将该实际来源一并纳入更正");return (UUID)value.get("id");}
    private <T> List<T> convert(List<Map<String,String>> parts,Class<T> type){if(parts==null)throw invalid("请完整填写所有金额轴");try{return parts.stream().map(p->json.convertValue(p,type)).toList();}catch(IllegalArgumentException ex){throw invalid("金额原文无效或金额轴不完整，请保留原文核对");}}
    private String encode(Object value){try{return json.writeValueAsString(value);}catch(Exception ex){throw new IllegalStateException("分类更正完整请求保存失败",ex);}}
    private static List<UUID> roots(List<UUID> ids){if(ids==null||ids.isEmpty()||ids.size()>64||ids.stream().anyMatch(Objects::isNull)||new HashSet<>(ids).size()!=ids.size())throw invalid("请选择1至64个明确且不重复的原往来来源");return ids.stream().sorted().toList();}
    @SuppressWarnings("unchecked") private static Map<String,Object> fact(Map<String,Object> n){return (Map<String,Object>)n.get("fact");}
    @SuppressWarnings("unchecked") private static List<Map<String,Object>> list(Object value){return (List<Map<String,Object>>)value;}
    private static String key(String kind,UUID id){return kind+":"+id;}
    private static BigDecimal decimal(Map<String,String> p,String key){try{return new BigDecimal(Objects.requireNonNull(p.get(key)));}catch(Exception e){throw invalid("请填写完整精确金额原文："+key);}}
    private static Map<String,String> camelParts(Map<String,Object> row){var out=new LinkedHashMap<String,String>();for(String name:List.of("category","source_category","target_category","amount_original","amount_local","cash_local","book_local","write_off_original","write_off_local","source_local","target_local"))if(row.get(name)!=null){var segments=name.split("_");var key=new StringBuilder(segments[0]);for(int i=1;i<segments.length;i++)key.append(Character.toUpperCase(segments[i].charAt(0))).append(segments[i].substring(1));out.put(key.toString(),row.get(name).toString());}return out;}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
