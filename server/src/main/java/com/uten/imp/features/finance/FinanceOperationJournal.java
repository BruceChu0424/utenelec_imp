package com.uten.imp.features.finance;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.function.Consumer;
import java.util.function.Supplier;

/** Shared actor-owned receipt mechanism over the existing immutable finance journal.
 * Domain services retain authorization, transaction, source locks and business semantics. */
@Component @RequiredArgsConstructor
public class FinanceOperationJournal {
    public static final Set<String> SETTINGS_OPERATIONS=Set.of("SETTINGS_SAVE","ROLE_SAVE","ROLE_REMOVE");
    public static final Set<String> COMMAND_OPERATIONS=Set.of("PROCUREMENT_AP_POLICY_SAVE",
            "GL_REPORT_BINDING_REPLACE","GL_REPORT_BINDINGS_SEED","INVENTORY_COST_POLICY_SAVE",
            "INVENTORY_COST_PERIOD_CHOICE","INVENTORY_COST_POST","INVENTORY_COST_CLOSE","FINANCE_DOCUMENT_APPROVE","FINANCE_DOCUMENT_UNAPPROVE","FINANCE_DOCUMENT_UPDATE","FINANCE_DOCUMENT_GL_CONFIRM","FINANCE_DOCUMENT_DELETE");
    private final JdbcTemplate db;
    private final ObjectMapper json;
    private final SecurityContextCurrentUser current;
    public interface OriginalBodyCommand { }
    @com.fasterxml.jackson.databind.annotation.JsonDeserialize(using=WireCommandDeserializer.class)
    public record WireCommand(JsonNode body) { }
    public static final class WireCommandDeserializer extends com.fasterxml.jackson.databind.JsonDeserializer<WireCommand> {
        @Override public WireCommand deserialize(com.fasterxml.jackson.core.JsonParser parser,com.fasterxml.jackson.databind.DeserializationContext context)throws java.io.IOException{
            JsonNode raw=new com.uten.imp.common.finance.FinancialJsonNodeDeserializer().deserialize(parser,context);
            if(!raw.isObject())throw com.fasterxml.jackson.databind.JsonMappingException.from(parser,"请保留原完整财务请求对象");return new WireCommand(raw);
        }
    }
    /** New configuration commands retain their exact supplied object. Missing
     * fields remain missing and explicit null never acquires a primitive default. */
    public <T>T decodeOriginal(WireCommand wire,Class<T> type){
        if(wire==null||wire.body()==null||!wire.body().isObject()||!OriginalBodyCommand.class.isAssignableFrom(type))throw invalid("请保留原完整配置请求");
        requireOriginalShape(wire.body(),type);
        try{return com.uten.imp.common.finance.FinancialJsonResults.value(json,encode(wire.body()),type);}catch(Exception error){throw new ApiException(ErrorCode.MALFORMED_REQUEST,"配置请求字段格式不正确，本次未写入");}
    }
    private static void requireOriginalShape(JsonNode raw,Class<?> type){
        var fields=new HashMap<String,Class<?>>();for(var component:type.getRecordComponents())fields.put(component.getName(),component.getType());
        for(var field:raw.properties()){
            Class<?> expected=fields.get(field.getKey());JsonNode value=field.getValue();
            if(expected==null)throw new ApiException(ErrorCode.MALFORMED_REQUEST,"配置请求包含未知字段，本次未写入");if(value.isNull())continue;
            boolean valid=expected==Long.class?value.isIntegralNumber()&&value.canConvertToLong():expected==Boolean.class?value.isBoolean():List.class.isAssignableFrom(expected)?value.isArray():value.isTextual();
            if(!valid)throw new ApiException(ErrorCode.MALFORMED_REQUEST,"配置请求字段类型不正确，本次未写入");
        }
    }
    private record OriginalBodies(Object hashBody,Object receiptBody) { }
    private OriginalBodies originalBodies(Object typed,WireCommand wire,Class<?> type){
        if(wire==null)return new OriginalBodies(typed,typed);
        JsonNode raw=wire.body().deepCopy();
        // Preserve the established typed fingerprint for every valid schema,
        // including optional absent fields. The receipt still retains the exact
        // original object; requireOriginalReceipt prevents a different raw body
        // from being interpreted as this original outcome. Invalid/coerced field
        // shapes are sealed as supplied, with no invented primitive defaults.
        if(typed!=null)try{
            requireOriginalShape(raw,type);return new OriginalBodies(typed,raw);
        }catch(RuntimeException ignored){ }catch(Exception error){throw invalid("原配置请求无法完整读取");}
        return new OriginalBodies(exactCanonical(raw),raw);
    }
    public record Cancellation(UUID requestId,UUID actorId,String operation,String method,String path,
            @com.fasterxml.jackson.databind.annotation.JsonDeserialize(using=com.uten.imp.common.finance.FinancialJsonNodeDeserializer.class) JsonNode requestBody,
            @com.fasterxml.jackson.databind.annotation.JsonDeserialize(using=SubmittedChoicesDeserializer.class) Map<String,BusinessPrecisionContext.Choice> precisionChoices) {
        public Cancellation(UUID requestId,UUID actorId,String operation,String method,String path,JsonNode requestBody){this(requestId,actorId,operation,method,path,requestBody,null);}
    }
    /** Cancellation must prove an explicitly submitted choice; a missing/null
     * primitive scale cannot silently become Jackson's default integer zero. */
    public static final class SubmittedChoicesDeserializer extends com.fasterxml.jackson.databind.JsonDeserializer<Map<String,BusinessPrecisionContext.Choice>> {
        @Override public Map<String,BusinessPrecisionContext.Choice> deserialize(com.fasterxml.jackson.core.JsonParser parser,com.fasterxml.jackson.databind.DeserializationContext context)throws java.io.IOException{
            JsonNode raw=new com.uten.imp.common.finance.FinancialJsonNodeDeserializer().deserialize(parser,context);
            if(!raw.isObject()||raw.size()>32)throw com.fasterxml.jackson.databind.JsonMappingException.from(parser,"原数值选择必须为明确用途集合");
            var result=new TreeMap<String,BusinessPrecisionContext.Choice>();
            for(var field:raw.properties()){
                var choice=field.getValue();
                if(field.getKey().isBlank()||field.getKey().length()>200||!choice.isObject()||choice.size()!=2||!choice.path("scale").isIntegralNumber()||!choice.path("scale").canConvertToInt()||!choice.path("rounding").isTextual())
                    throw com.fasterxml.jackson.databind.JsonMappingException.from(parser,"原数值选择必须完整保留整数位数及取舍方式");
                result.put(field.getKey(),new BusinessPrecisionContext.Choice(choice.get("scale").intValue(),choice.get("rounding").textValue()));
            }
            return Collections.unmodifiableMap(result);
        }
    }

    /** Preserve the established application fingerprint and lock namespace byte-for-byte. */
    public Map<String,Object> execute(UUID application,UUID request,String operation,Object payload,
            Consumer<String> authorizeReplay,Supplier<Map<String,Object>> work){
        if(request==null)throw invalid("请保留原请求编号，使用当前客户端核对后重试");
        if(application==null&&!SETTINGS_OPERATIONS.contains(operation)&&!COMMAND_OPERATIONS.contains(operation))
            throw new IllegalArgumentException("Finance operation scope required");
        if(!TransactionSynchronizationManager.isActualTransactionActive())
            throw new IllegalStateException("Finance command and receipt require the same transaction");
        db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,7111))",rs->{},"finance-application-operation:"+request);
        String encoded=encode(Arrays.asList(operation,application,payload));
        // New edit commands retain the raw business body in their receipt, but
        // object key order is not part of that new protocol's intent identity.
        if("FINANCE_DOCUMENT_UPDATE".equals(operation))try{encoded=encode(exactCanonical(com.uten.imp.common.finance.FinancialJsonResults.tree(json,encoded)));}catch(Exception error){throw invalid("原财务编辑请求无法完整读取");}
        String hash=ImmutableDocumentStore.digest(encoded.getBytes(StandardCharsets.UTF_8));
        var rows=db.queryForList("SELECT application_id,actor_id,operation,payload_hash,result::text FROM finance_application_operations WHERE request_id=?",request);
        if(!rows.isEmpty()){
            var old=rows.getFirst();
            if(!current.requireId().equals(old.get("actor_id"))||!Objects.equals(application,old.get("application_id"))
                    ||!hash.equals(old.get("payload_hash")))throw conflict("原请求编号已用于不同内容，不能重新解释原请求");
            authorizeReplay.accept(old.get("operation").toString());return decode(old.get("result").toString());
        }
        var result=work.get();
        db.update("INSERT INTO finance_application_operations(request_id,application_id,actor_id,operation,payload_hash,result) VALUES(?,?,?,?,?,?::jsonb)",
                request,application,current.requireId(),operation,hash,encode(result));
        return result;
    }

    /** New HTTP commands freeze method, path and original typed body, then execute once. */
    public Map<String,Object> command(UUID request,String operation,String method,String path,Object body,Supplier<?> work){
        return command(request,operation,method,path,body,work,ignored->{});
    }
    public Map<String,Object> command(UUID request,String operation,String method,String path,Object body,Supplier<?> work,Consumer<String> authorizeReplay){
        return commandOriginal(request,operation,method,path,body,null,work,authorizeReplay);
    }
    public Map<String,Object> commandOriginal(UUID request,String operation,String method,String path,Object body,WireCommand original,Supplier<?> work){
        return commandOriginal(request,operation,method,path,body,original,work,ignored->{});
    }
    private Map<String,Object> commandOriginal(UUID request,String operation,String method,String path,Object body,WireCommand original,Supplier<?> work,Consumer<String> authorizeReplay){
        if(!COMMAND_OPERATIONS.contains(operation)||!(Set.of("PUT","POST").contains(method)||"FINANCE_DOCUMENT_DELETE".equals(operation)&&"DELETE".equals(method))||path==null
                ||!(path.startsWith("/finance/")||operation.equals("FINANCE_DOCUMENT_UNAPPROVE")&&path.matches("/documents/finance(?:Receipt|Payment|Expense|OtherIncome|BankTransfer)/[0-9a-f-]{36}/unapprove")))
            throw new IllegalArgumentException("Unknown finance command");
        var bodies=originalBodies(body,original,body.getClass());
        var payload=new LinkedHashMap<String,Object>();payload.put("method",method);payload.put("path",path);payload.put("requestBody",bodies.hashBody());
        var receiptPayload=new LinkedHashMap<>(payload);receiptPayload.put("requestBody",bodies.receiptBody());
        boolean precise=reviewOperation(operation);
        var choices=precise?validatedChoices(BusinessPrecisionContext.choices()):null;
        if(precise){payload.put("precisionChoices",choices);receiptPayload.put("precisionChoices",choices);}
        var result=outcome(decode(encode(execute(null,request,operation,payload,authorizeReplay,()->{
            if(!precise)return envelope(request,operation,receiptPayload,"SUCCEEDED",work.get());
            try(var scope=BusinessPrecisionContext.use(choices)){
                Object value=work.get();var receipt=envelope(request,operation,receiptPayload,"SUCCEEDED",value);
                receipt.put("precisionContext",Map.of("available",true,"choices",choices,"usedChoices",BusinessPrecisionContext.usedChoices()));
                return receipt;
            }catch(RuntimeException error){throw error;}catch(Exception error){throw new IllegalStateException("原数值选择上下文无法恢复",error);}
        }))));
        if(original!=null)requireOriginalReceipt(result,original.body());return result;
    }

    /** Seal the exact original identity under the same lock. It either returns
     * the already committed result or permanently prevents every late write. */
    public Map<String,Object> cancelCommand(UUID routedRequest,Cancellation cancellation,String operation,String method,String path,Class<?> bodyType){
        return cancelCommand(routedRequest,cancellation,operation,method,path,bodyType,ignored->{});
    }
    public Map<String,Object> cancelCommand(UUID routedRequest,Cancellation cancellation,String operation,String method,String path,Class<?> bodyType,Consumer<String> authorizeReplay){
        if(!COMMAND_OPERATIONS.contains(operation))throw new IllegalArgumentException("Unknown finance command");
        boolean raw=OriginalBodyCommand.class.isAssignableFrom(bodyType);OriginalBodies bodies;
        if(raw){
            requireCancellationIdentity(routedRequest,cancellation,operation,method,path);
            var original=cancellation.requestBody();
            try{if(original==null||!original.isObject()||!routedRequest.equals(UUID.fromString(original.path("requestId").asText())))throw new IllegalArgumentException();}
            catch(Exception error){throw invalid("取消核对缺少原配置请求编号");}
            Object typed=null;try{typed=decodeOriginal(new WireCommand(original),bodyType);}catch(ApiException invalidOriginal){/* Invalid original intent still can be sealed without any default. */}
            bodies=originalBodies(typed,new WireCommand(original),bodyType);
        }else{Object body=cancellationBody(routedRequest,cancellation,operation,method,path,bodyType);bodies=new OriginalBodies(body,body);}
        var payload=new LinkedHashMap<String,Object>();payload.put("method",method);payload.put("path",path);payload.put("requestBody",bodies.hashBody());
        var receiptPayload=new LinkedHashMap<>(payload);receiptPayload.put("requestBody",bodies.receiptBody());
        boolean precise=reviewOperation(operation);
        var choices=precise?validatedChoices(cancellation.precisionChoices()):null;
        if(precise){payload.put("precisionChoices",choices);receiptPayload.put("precisionChoices",choices);}
        var result=outcome(decode(encode(execute(null,routedRequest,operation,payload,authorizeReplay,()->{
            var receipt=envelope(routedRequest,operation,receiptPayload,"CANCELLED_UNWRITTEN",Map.of("cancelled",true));
            if(precise)receipt.put("precisionContext",Map.of("available",true,"choices",choices,"usedChoices",Map.of()));
            return receipt;
        }))));
        if(raw)requireOriginalReceipt(result,cancellation.requestBody());return result;
    }
    private void requireOriginalReceipt(Map<String,Object> result,JsonNode original){
        try{if(!encode(canonical(original)).equals(encode(canonical(com.uten.imp.common.finance.FinancialJsonResults.tree(json,encode(result.get("requestBody")))))))throw conflict("原配置回执正文与本次完整原请求不一致");}
        catch(ApiException error){throw error;}catch(Exception error){throw conflict("原配置回执正文无法完整核对");}
    }

    private static boolean reviewOperation(String operation){return Set.of("FINANCE_DOCUMENT_APPROVE","FINANCE_DOCUMENT_UNAPPROVE","FINANCE_DOCUMENT_UPDATE","FINANCE_DOCUMENT_GL_CONFIRM","FINANCE_DOCUMENT_DELETE").contains(operation);}
    private static Map<String,BusinessPrecisionContext.Choice> validatedChoices(Map<String,BusinessPrecisionContext.Choice> choices){
        if(choices==null)throw invalid("请保留原提交的数值选择，未选择时也须明确保留空集合");
        try(var scope=BusinessPrecisionContext.use(choices)){return Collections.unmodifiableMap(new TreeMap<>(BusinessPrecisionContext.choices()));}
        catch(RuntimeException error){throw error;}catch(Exception error){throw new IllegalStateException("原数值选择无法核对",error);}
    }

    /** Legacy adapters validate the same identity but keep their own established
     * fingerprint payload and lock order rather than translating old IDs. */
    public <T>T cancellationBody(UUID routedRequest,Cancellation cancellation,String operation,String method,String path,Class<T> bodyType){
        return cancellationBodyForIdentityField(routedRequest,cancellation,operation,method,path,"requestId",bodyType);
    }
    /** The field name belongs to a reviewed protocol, never to the incoming request. */
    public <T>T cancellationBodyForIdentityField(UUID routedRequest,Cancellation cancellation,String operation,String method,String path,String identityField,Class<T> bodyType){
        if(!"requestId".equals(identityField)&&!"importId".equals(identityField))
            throw new IllegalArgumentException("Unsupported finance original identity field");
        requireCancellationIdentity(routedRequest,cancellation,operation,method,path);
        T body;
        try{
            if(cancellation.requestBody()==null||!cancellation.requestBody().isObject())throw new IllegalArgumentException();
            body=com.uten.imp.common.finance.FinancialJsonResults.value(json,encode(cancellation.requestBody()),bodyType);
        }catch(Exception error){throw invalid("请保留原完整请求正文核对，不能猜补取消内容");}
        JsonNode typed;try{typed=com.uten.imp.common.finance.FinancialJsonResults.tree(json,encode(body));}catch(Exception error){throw invalid("原取消核对正文无法完整读取");}
        if(!routedRequest.toString().equals(typed.path(identityField).asText())
                ||!encode(canonical(cancellation.requestBody())).equals(encode(canonical(typed))))
            throw invalid("取消核对的原请求正文不完整或身份不一致");
        return body;
    }
    private void requireCancellationIdentity(UUID routedRequest,Cancellation cancellation,String operation,String method,String path){
        if(cancellation==null||routedRequest==null||!routedRequest.equals(cancellation.requestId())||cancellation.actorId()==null)
            throw invalid("请保留原取消核对请求身份");
        if(!current.requireId().equals(cancellation.actorId()))throw new ApiException(ErrorCode.FORBIDDEN,"只能核对并取消本人原请求");
        var actor=current.get().orElseThrow(()->new ApiException(ErrorCode.FORBIDDEN,"当前登录身份无效"));
        if(actor.isVisitor()||actor.isMustChangePassword()||!actor.isAccountNonLocked()||actor.getImpersonatedBy()!=null)
            throw new ApiException(ErrorCode.FORBIDDEN,"当前身份仅可按原读取权限核对结果，不能停止原财务请求");
        if(!Objects.equals(operation,cancellation.operation())
                ||!Objects.equals(method,cancellation.method())||!Objects.equals(path,cancellation.path()))
            throw invalid("取消核对的动作或来源路径与原请求不一致");
    }

    public Map<String,Object> legacyCancellation(UUID request,Cancellation cancellation,String operation,String method,String path,Class<?> type,java.util.function.Function<Object,Object> legacyPayload){
        if(!SETTINGS_OPERATIONS.contains(operation))throw new IllegalArgumentException("Unknown application settings operation");
        Object body=cancellationBody(request,cancellation,operation,method,path,type);
        var stored=execute(null,request,operation,legacyPayload.apply(body),ignored->{},()->cancellationOutcome(request,operation,method,path,body,Map.of("cancelled",true),true));
        if("CANCELLED_UNWRITTEN".equals(stored.get("outcome")))return stored;
        return cancellationOutcome(request,operation,method,path,body,stored,false);
    }
    public Map<String,Object> cancellationOutcome(UUID request,String operation,String method,String path,Object body,Object result,boolean cancelled){
        var payload=new LinkedHashMap<String,Object>();payload.put("method",method);payload.put("path",path);payload.put("requestBody",body);
        return decode(encode(envelope(request,operation,payload,cancelled?"CANCELLED_UNWRITTEN":"SUCCEEDED",result)));
    }

    private Map<String,Object> envelope(UUID request,String operation,Map<String,Object> payload,String outcome,Object result){
        var envelope=new LinkedHashMap<String,Object>();envelope.put("found",true);envelope.put("requestId",request);
        envelope.put("actorId",current.requireId());envelope.put("operation",operation);envelope.putAll(payload);
        envelope.put("outcome",outcome);envelope.put("result",result);return envelope;
    }
    private static Map<String,Object> outcome(Map<String,Object> result){
        // Pre-cancellation candidate receipts are already immutable successful
        // results. Decorate the response without rewriting any stored bytes.
        if(!result.containsKey("outcome")){var copy=new LinkedHashMap<>(result);copy.put("outcome","SUCCEEDED");return copy;}
        return result;
    }
    private static Object canonical(JsonNode value){
        if(value.isObject()){var result=new TreeMap<String,Object>();value.properties().forEach(field->result.put(field.getKey(),canonical(field.getValue())));return result;}
        if(value.isArray()){var result=new ArrayList<Object>();value.forEach(child->result.add(canonical(child)));return result;}
        if(value.isNull())return null;if(value.isNumber())return value.decimalValue().stripTrailingZeros();
        if(value.isBoolean())return value.booleanValue();return value.asText();
    }
    private static Object exactCanonical(JsonNode value){
        if(value.isObject()){var result=new TreeMap<String,Object>();value.properties().forEach(field->result.put(field.getKey(),exactCanonical(field.getValue())));return result;}
        if(value.isArray()){var result=new ArrayList<Object>();value.forEach(child->result.add(exactCanonical(child)));return result;}
        if(value.isNull())return null;if(value.isNumber())return value.numberValue();if(value.isBoolean())return value.booleanValue();return value.asText();
    }

    /** Exact supplied-object identity for new adapters over their established journals.
     * Existing typed hashes and their historic rows keep their original algorithms. */
    public String originalBodyFingerprint(JsonNode body){
        if(body==null||!body.isObject())throw invalid("请保留原完整财务请求对象");
        return ImmutableDocumentStore.digest(encode(exactCanonical(body)).getBytes(StandardCharsets.UTF_8));
    }

    public void requireOriginalBodyMatch(JsonNode expected,JsonNode actual){
        if(expected==null||!expected.isObject()||actual==null||!actual.isObject()
                ||!originalBodyFingerprint(expected).equals(originalBodyFingerprint(actual)))
            throw conflict("原操作回执正文与完整原请求不一致，请保留原请求核对");
    }

    /** A missing receipt is not proof that an in-flight transaction did not write. */
    public Map<String,Object> commandReceipt(UUID request,Set<String> allowed){
        var stored=legacyReceipt(request,allowed);if(!Boolean.TRUE.equals(stored.get("found")))return Map.of("found",false);
        @SuppressWarnings("unchecked")var result=(Map<String,Object>)stored.get("result");
        if(!Boolean.TRUE.equals(result.get("found"))||!request.toString().equals(Objects.toString(result.get("requestId"),""))
                ||!current.requireId().toString().equals(Objects.toString(result.get("actorId"),""))
                ||!stored.get("operation").equals(result.get("operation")))throw conflict("原操作回执身份不完整，请保留原请求核对");
        return outcome(result);
    }

    /** Existing application/settings callers retain their original envelope contract. */
    public Map<String,Object> legacyReceipt(UUID request,Set<String> allowed){
        if(request==null)throw invalid("请保留原请求编号");
        var rows=db.queryForList("SELECT operation,result::text FROM finance_application_operations WHERE request_id=? AND actor_id=? AND application_id IS NULL",request,current.requireId());
        if(rows.isEmpty()||!allowed.contains(rows.getFirst().get("operation")))return Map.of("found",false);
        var row=rows.getFirst();return Map.of("found",true,"actorId",current.requireId(),"operation",row.get("operation"),"result",decode(row.get("result").toString()));
    }
    private String encode(Object value){try{return json.writeValueAsString(value);}catch(Exception error){throw new IllegalStateException("原财务记录无法保存",error);}}
    private Map<String,Object> decode(String value){try{return com.uten.imp.common.finance.FinancialJsonResults.object(json,value);}catch(Exception error){throw conflict("原财务记录无法完整读取");}}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
