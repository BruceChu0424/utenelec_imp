package com.uten.imp.features.finance;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.bank_transfer.FinanceBankTransferService;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferSaveRequest;
import com.uten.imp.features.finance.expense.FinanceExpenseService;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseSaveRequest;
import com.uten.imp.features.finance.other_income.FinanceOtherIncomeService;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeSaveRequest;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest;
import com.uten.imp.features.finance.receipt.FinanceReceiptService;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.CurrentAuthorityGuard;
import jakarta.validation.Validator;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
import java.util.TreeMap;
import java.util.UUID;

/** Existing single-document services remain the accounting/permission authority. */
@Service
@RequiredArgsConstructor
public class FinanceBatchEntryService {
    private static final String SUCCEEDED="SUCCEEDED";
    private static final String CANCELLED="CANCELLED_UNWRITTEN";
    private final NamedParameterJdbcTemplate db;
    private final ObjectMapper json;
    private final Validator validator;
    private final SecurityContextCurrentUser currentUser;
    private final AuditService audit;
    private final FinanceReceiptService receipts;
    private final FinancePaymentService payments;
    private final FinanceExpenseService expenses;
    private final FinanceOtherIncomeService incomes;
    private final FinanceBankTransferService transfers;

    @Transactional
    public JsonNode create(String type, FinanceBatchEntryController.Request request) {
        UUID actor = currentUser.requireId();
        validateRequest(type,request);
        String key = request.idempotencyKey();
        String hash = requestHash(type,request);
        Map<String, Object> args = Map.of("actor", actor, "key", key);
        lock(actor,key);
        var previous = db.queryForList("""
                SELECT request_hash, outcome, result::text AS result FROM finance_batch_entry_commands
                WHERE actor_id=:actor AND idempotency_key=:key
                """, args);
        if (!previous.isEmpty()) {
            var saved = previous.getFirst();
            if (!hash.equals(saved.get("request_hash"))) {
                throw new ApiException(ErrorCode.CONFLICT, "本次提交内容与原请求不同，请先核对原批次结果");
            }
            if(CANCELLED.equals(saved.get("outcome")))throw new CancelledBatch(cancelledDetails(type,key,actor,hash));
            return decode(saved.get("result").toString());
        }
        ArrayNode results = json.createArrayNode();
        int index = 0;
        for (JsonNode document : FinanceEntryGrouping.group(request.documents(), key)) {
            index++;
            try {
                Object result = switch (type) {
                    case "receipts" -> receipts.create(convert(document, FinanceReceiptSaveRequest.class));
                    case "payments" -> payments.create(convert(document, FinancePaymentSaveRequest.class));
                    case "expenses" -> expenses.create(convert(document, FinanceExpenseSaveRequest.class));
                    case "incomes" -> incomes.create(convert(document, FinanceOtherIncomeSaveRequest.class));
                    case "bank-transfers" -> transfers.create(convert(document, FinanceBankTransferSaveRequest.class));
                    default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "不支持的钱流单据类型");
                };
                results.add(json.valueToTree(result));
            } catch (ApiException error) {
                throw new ApiException(error.getCode(), "第 " + index + " 组：" + error.getMessage());
            }
        }
        ObjectNode result = json.createObjectNode().set("items", results);
        int storedReceipt=db.update("""
                INSERT INTO finance_batch_entry_commands(actor_id,idempotency_key,document_type,request_hash,result,outcome,original_body)
                VALUES (:actor,:key,:type,:hash,CAST(:result AS jsonb),'SUCCEEDED',CAST(:body AS jsonb))
                """, Map.of("actor", actor, "key", key, "type", type, "hash", hash, "result", result.toString(),"body",json.valueToTree(request).toString()));
        if(storedReceipt!=1)throw new IllegalStateException("批次与原请求回执未共同保存，本次已回滚");
        audit.logCommitted(actor, currentUser.get().orElseThrow().getLoginAccount(),
                "create_finance_batch", "finance_" + type.replace('-', '_'), null,
                "已创建 " + results.size() + " 张单据");
        return decode(result.toString());
    }

    /** Absence remains unknown: this read never authorizes editing or seals a command. */
    @Transactional(readOnly=true)
    public Map<String,Object> receipt(String type,String key) {
        readAccess(type);validateKey(key);
        var rows=db.queryForList("""
                SELECT document_type,request_hash,outcome,original_body::text AS original_body,result::text AS result
                FROM finance_batch_entry_commands WHERE actor_id=:actor AND idempotency_key=:key
                """,Map.of("actor",currentUser.requireId(),"key",key));
        if(rows.isEmpty()||!type.equals(rows.getFirst().get("document_type")))return Map.of("found",false);
        return envelope(type,key,currentUser.requireId(),rows.getFirst(),null);
    }

    /** Same actor/key lock as creation; a terminal unwritten receipt wins over every late original POST. */
    @Transactional
    public Map<String,Object> cancelUnwritten(String type,String key,FinanceBatchEntryController.Cancellation cancellation) {
        readAccess(type);validateKey(key);UUID actor=currentUser.requireId();
        var identity=currentUser.get().orElseThrow(()->new ApiException(ErrorCode.FORBIDDEN));
        if(identity.isVisitor()||identity.isMustChangePassword()||!identity.isAccountNonLocked()||identity.getImpersonatedBy()!=null)
            throw new ApiException(ErrorCode.FORBIDDEN,"当前身份不能取消原财务批次，请由本人核对");
        if(cancellation==null||cancellation.actorId()==null||cancellation.requestBody()==null||!cancellation.requestBody().isObject())
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"请保留本人原批次身份及完整正文核对");
        if(!actor.equals(cancellation.actorId()))throw new ApiException(ErrorCode.FORBIDDEN,"只能核对并取消本人原批次");
        JsonNode original=cancellation.requestBody().deepCopy();
        if(!key.equals(original.path("idempotencyKey").textValue())||original.properties().stream().anyMatch(field->!java.util.Set.of("idempotencyKey","documents").contains(field.getKey())))
            throw new ApiException(ErrorCode.CONFLICT,"取消核对必须保留原批次编号和完整正文");
        // A request rejected by creation validation (including >500 rows) still
        // needs a permanent fence. Do not rerun current business/shape admission
        // here or discard/reconstruct the original rejected body.
        String hash=requestHash(type,original.get("documents"));lock(actor,key);
        var rows=db.queryForList("""
                SELECT document_type,request_hash,outcome,original_body::text AS original_body,result::text AS result
                FROM finance_batch_entry_commands WHERE actor_id=:actor AND idempotency_key=:key
                """,Map.of("actor",actor,"key",key));
        if(!rows.isEmpty()) {
            var stored=rows.getFirst();
            if(!type.equals(stored.get("document_type"))||!hash.equals(stored.get("request_hash")))
                throw new ApiException(ErrorCode.CONFLICT,"原批次已用于不同内容，请保留原请求核对");
            return envelope(type,key,actor,stored,original);
        }
        String body=original.toString();
        int storedCancellation=db.update("""
                INSERT INTO finance_batch_entry_commands(actor_id,idempotency_key,document_type,request_hash,result,outcome,original_body)
                VALUES(:actor,:key,:type,:hash,'{"cancelled":true}'::jsonb,'CANCELLED_UNWRITTEN',CAST(:body AS jsonb))
                """,Map.of("actor",actor,"key",key,"type",type,"hash",hash,"body",body));
        if(storedCancellation!=1)throw new IllegalStateException("原批次取消证据尚未保存，请保留原请求核对");
        return envelope(type,key,actor,Map.of("request_hash",hash,"outcome",CANCELLED,"original_body",body,"result","{\"cancelled\":true}"),null);
    }

    private void lock(UUID actor,String key) {
        db.queryForObject("""
                SELECT count(*) FROM (SELECT pg_advisory_xact_lock(hashtextextended(:lock, 991))) acquired
                """,Map.of("lock","FINANCE-BATCH:"+actor+":"+key),Long.class);
    }
    private void validateRequest(String type,FinanceBatchEntryController.Request request) {
        permission(type);if(request==null||!validator.validate(request).isEmpty())
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"请保留完整原批次编号及明细");
    }
    private static void validateKey(String key) {
        if(key==null||!key.matches("[A-Za-z0-9._:-]{8,120}"))throw new ApiException(ErrorCode.VALIDATION_FAILED,"原批次编号无效");
    }
    private void readAccess(String type){CurrentAuthorityGuard.requireAll(permission(type)+":view");}
    private static String permission(String type) {
        if(type==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"不支持的钱流单据类型");
        return switch(type){case "receipts"->"finance_receipt";case "payments"->"finance_payment";case "expenses"->"finance_expense";
            case "incomes"->"finance_other_income";case "bank-transfers"->"finance_bank_transfer";
            default->throw new ApiException(ErrorCode.VALIDATION_FAILED,"不支持的钱流单据类型");};
    }
    private String requestHash(String type,FinanceBatchEntryController.Request request){return requestHash(type,json.valueToTree(request.documents()));}
    private String requestHash(String type,JsonNode documents){return digest(type+":"+canonical(documents==null?com.fasterxml.jackson.databind.node.NullNode.getInstance():documents));}
    private Map<String,Object> envelope(String type,String key,UUID actor,Map<String,Object> row,JsonNode verifiedBody) {
        String outcome=Objects.toString(row.get("outcome"),SUCCEEDED);
        if(!SUCCEEDED.equals(outcome)&&!CANCELLED.equals(outcome))throw new IllegalStateException("原批次结果状态无效");
        JsonNode body=row.get("original_body")==null?verifiedBody:decode(row.get("original_body").toString());
        JsonNode result=decode(row.get("result").toString());
        if(SUCCEEDED.equals(outcome)&&(!result.isObject()||!result.path("items").isArray()||result.path("items").isEmpty()))
            throw new IllegalStateException("原成功批次缺少真实单据回执");
        var value=new LinkedHashMap<String,Object>();value.putAll(cancelledDetails(type,key,actor,row.get("request_hash").toString()));
        value.put("outcome",outcome);value.put("requestBody",body);value.put("requestBodyAvailable",body!=null);
        value.put("result",result);return value;
    }
    private static Map<String,Object> cancelledDetails(String type,String key,UUID actor,String hash) {
        return Map.of("found",true,"requestId",key,"idempotencyKey",key,"actorId",actor,
                "operation","FINANCE_BATCH_CREATE","method","POST","path","/finance/"+type+"/batch","requestHash",hash,"outcome",CANCELLED);
    }
    private JsonNode decode(String text){try{return com.uten.imp.common.finance.FinancialJsonResults.tree(json,text);}catch(com.fasterxml.jackson.core.JsonProcessingException error){throw new IllegalStateException("原批次回执无法完整读取",error);}}
    public static final class CancelledBatch extends ApiException {
        private final Map<String,Object> details;
        CancelledBatch(Map<String,Object> details){super(ErrorCode.CONFLICT,"原批次已确认未写并取消，请核对原回执后编辑");this.details=details;}
        @Override public Map<String,Object> details(){return details;}
    }

    private <T> T convert(JsonNode node, Class<T> type) {
        final T request;
        try {
            request = json.treeToValue(node, type);
        } catch (com.fasterxml.jackson.core.JsonProcessingException | IllegalArgumentException error) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "单据字段格式不正确");
        }
        var violations = validator.validate(request);
        if (!violations.isEmpty()) {
            var violation = violations.iterator().next();
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    violation.getPropertyPath() + "：" + violation.getMessage());
        }
        return request;
    }

    static JsonNode canonical(JsonNode node) {
        if (node.isObject()) {
            var sorted = new TreeMap<String, JsonNode>();
            node.properties().forEach(e -> sorted.put(e.getKey(), canonical(e.getValue())));
            ObjectNode result = com.fasterxml.jackson.databind.node.JsonNodeFactory.instance.objectNode();
            sorted.forEach(result::set);
            return result;
        }
        if (node.isArray()) {
            ArrayNode result = com.fasterxml.jackson.databind.node.JsonNodeFactory.instance.arrayNode();
            node.forEach(value -> result.add(canonical(value)));
            return result;
        }
        return node;
    }

    private static String digest(String text) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(text.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException error) {
            throw new IllegalStateException(error);
        }
    }
}
