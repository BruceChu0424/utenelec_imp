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
import jakarta.validation.Validator;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Map;
import java.util.TreeMap;
import java.util.UUID;

/** Existing single-document services remain the accounting/permission authority. */
@Service
@RequiredArgsConstructor
public class FinanceBatchEntryService {
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
        String key = request.idempotencyKey();
        String hash = digest(type + ":" + canonical(json.valueToTree(request.documents())));
        Map<String, Object> args = Map.of("actor", actor, "key", key);
        db.queryForObject("""
                SELECT count(*) FROM (SELECT pg_advisory_xact_lock(hashtextextended(:lock, 991))) acquired
                """, Map.of("lock", "FINANCE-BATCH:" + actor + ":" + key), Long.class);
        var previous = db.queryForList("""
                SELECT request_hash, result::text AS result FROM finance_batch_entry_commands
                WHERE actor_id=:actor AND idempotency_key=:key
                """, args);
        if (!previous.isEmpty()) {
            var saved = previous.getFirst();
            if (!hash.equals(saved.get("request_hash"))) {
                throw new ApiException(ErrorCode.CONFLICT, "本次提交内容与原请求不同，请先核对原批次结果");
            }
            try {
                return json.readTree(saved.get("result").toString());
            } catch (com.fasterxml.jackson.core.JsonProcessingException error) {
                throw new IllegalStateException("钱流批次回执无法读取", error);
            }
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
        db.update("""
                INSERT INTO finance_batch_entry_commands(actor_id,idempotency_key,document_type,request_hash,result)
                VALUES (:actor,:key,:type,:hash,CAST(:result AS jsonb))
                """, Map.of("actor", actor, "key", key, "type", type, "hash", hash, "result", result.toString()));
        audit.logCommitted(actor, currentUser.get().orElseThrow().getLoginAccount(),
                "create_finance_batch", "finance_" + type.replace('-', '_'), null,
                "已创建 " + results.size() + " 张单据");
        return result;
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
