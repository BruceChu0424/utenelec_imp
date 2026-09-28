package com.uten.imp.features.sales.intake;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiCompletionPort.AiCallException;
import com.uten.imp.application.port.AiCompletionPort.AiCompletionRequest;
import com.uten.imp.application.port.AiCompletionPort.AiCompletionResult;
import com.uten.imp.application.port.AiJobHandler.AiJobContext;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Optional;

/**
 * 识别任务里调用 AI 的薄封装: 只经任务上下文调用(计入本任务调用次数、检查 ai:use), 解析返回的 JSON。
 * 可选步骤失败时降级为纯规则并记一条提示; 日志只记用途与失败类别, 从不记提示词或返回内容。
 */
final class IntakeAi {

    private static final Logger log = LoggerFactory.getLogger(IntakeAi.class);

    private final AiJobContext ctx;
    private final ObjectMapper json;
    private boolean used;
    private AiCallException lastFailure;

    IntakeAi(AiJobContext ctx, ObjectMapper json) {
        this.ctx = ctx;
        this.json = json;
    }

    /** 提交人有 ai:use、AI 服务可用、本任务还有调用次数。 */
    boolean usable() {
        return ctx.aiAllowed() && ctx.remainingAiCalls() > 0;
    }

    boolean allowed() {
        return ctx.aiAllowed();
    }

    boolean used() {
        return used;
    }

    AiCallException lastFailure() {
        return lastFailure;
    }

    /** 调用并解析为 JSON 对象; 失败或返回不是 JSON 对象时返回空(失败原因见 {@link #lastFailure()})。 */
    Optional<JsonNode> call(AiCompletionRequest request) {
        if (!usable()) {
            return Optional.empty();
        }
        try {
            AiCompletionResult result = ctx.completeJson(request);
            used = true;
            if (result == null || result.json() == null || result.json().isBlank()) {
                return Optional.empty();
            }
            JsonNode node = json.readTree(result.json());
            return node != null && node.isObject() ? Optional.of(node) : Optional.empty();
        } catch (AiCallException e) {
            lastFailure = e;
            log.warn("sales intake AI call failed: purpose={} category={}", request.purpose(), e.category());
            return Optional.empty();
        } catch (Exception e) {
            log.warn("sales intake AI returned unreadable JSON: purpose={}", request.purpose());
            return Optional.empty();
        }
    }

    /** JSON 字符串字段(空白/非字符串为 null)。 */
    static String text(JsonNode node, String field) {
        if (node == null) {
            return null;
        }
        JsonNode v = node.get(field);
        if (v == null || v.isNull()) {
            return null;
        }
        String s = v.isTextual() ? v.asText() : v.isNumber() ? v.asText() : null;
        if (s == null) {
            return null;
        }
        s = s.strip();
        if (s.isEmpty() || "null".equalsIgnoreCase(s)) {
            return null;
        }
        return s.length() > 500 ? s.substring(0, 500) : s;
    }

    /** JSON 数字字段(数字或可解析的文字); 其他为 null。 */
    static java.math.BigDecimal number(JsonNode node, String field) {
        if (node == null) {
            return null;
        }
        JsonNode v = node.get(field);
        if (v == null || v.isNull()) {
            return null;
        }
        if (v.isNumber()) {
            return v.decimalValue();
        }
        if (v.isTextual()) {
            return IntakeNumbers.parse(v.asText());
        }
        return null;
    }
}
