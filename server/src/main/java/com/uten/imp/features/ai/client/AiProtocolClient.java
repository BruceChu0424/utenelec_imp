package com.uten.imp.features.ai.client;

import com.uten.imp.application.port.AiCompletionPort.AiContentPart;
import com.uten.imp.application.port.AiCompletionPort.AiReasoningEffort;
import com.uten.imp.features.ai.provider.AiProtocol;
import com.uten.imp.features.ai.provider.AiProviderRuntime;

import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * 一种接口协议的客户端(ADR-133)。新增协议 = 实现本接口并注册为 Bean, 网关按
 * {@link #protocol()} 选择。失败一律抛 {@code AiCompletionPort.AiCallException}(消息可直接给人看)。
 */
public interface AiProtocolClient {

    AiProtocol protocol();

    /** 一次对话补全; 返回模型回复的原始文本(JSON 提取由网关做)。 */
    ChatResponse chat(AiProviderRuntime runtime, ChatRequest request);

    /** 服务商的模型列表; 不支持列表的服务商抛 NOT_FOUND。 */
    List<String> listModels(AiProviderRuntime runtime);

    /**
     * 已由网关准备好的请求: 不可信文本已经包好隔离标记, 系统提示词已追加 JSON 与隔离说明。
     *
     * @param jsonSchema      服务商用 JSON_SCHEMA 方式时下发的 schema; 可为空
     * @param reasoningEffort 思考程度(按服务商「思考参数写法」映射, 见 {@link AiReasoningParams}); 为空等同 DEFAULT
     */
    record ChatRequest(String systemPrompt, List<AiContentPart> parts, String jsonSchemaName,
                       Map<String, Object> jsonSchema, int maxOutputTokens, AiReasoningEffort reasoningEffort) {
        public ChatRequest {
            Objects.requireNonNull(systemPrompt, "systemPrompt");
            parts = List.copyOf(Objects.requireNonNull(parts, "parts"));
            if (reasoningEffort == null) {
                reasoningEffort = AiReasoningEffort.DEFAULT;
            }
        }

        public ChatRequest(String systemPrompt, List<AiContentPart> parts, String jsonSchemaName,
                           Map<String, Object> jsonSchema, int maxOutputTokens) {
            this(systemPrompt, parts, jsonSchemaName, jsonSchema, maxOutputTokens, AiReasoningEffort.DEFAULT);
        }
    }

    /**
     * 回复。
     *
     * @param content   模型输出的文本
     * @param truncated 因输出长度上限被截断
     * @param stopReason 已知的协议停止原因; 不保留服务商返回的任意文本
     * @param thinkingOnly 返回了思考块但没有回答正文; 思考内容绝不能作为业务 JSON 使用
     */
    record ChatResponse(String content, Integer inputTokens, Integer outputTokens, int httpStatus, boolean truncated,
                        long latencyMs, String stopReason, boolean thinkingOnly) {
        public ChatResponse {
            stopReason = safeStopReason(stopReason);
        }

        public ChatResponse(String content, Integer inputTokens, Integer outputTokens, int httpStatus,
                            boolean truncated, long latencyMs) {
            this(content, inputTokens, outputTokens, httpStatus, truncated, latencyMs, null, false);
        }
    }

    /** Only protocol constants may enter diagnostics; an upstream field may contain arbitrary private text. */
    private static String safeStopReason(String value) {
        if (value == null || value.isBlank()) return null;
        return switch (value) {
            case "end_turn", "max_tokens", "stop_sequence", "tool_use", "pause_turn", "refusal",
                    "model_context_window_exceeded", "stop", "length", "tool_calls", "function_call",
                    "content_filter", "sensitive" -> value;
            default -> "unknown";
        };
    }

    /** Missing, malformed or negative usage is unknown, never a fabricated zero. */
    static Integer tokenCount(com.fasterxml.jackson.databind.JsonNode usage, String field) {
        var value = usage.path(field);
        return value.isIntegralNumber() && value.canConvertToInt() && value.intValue() >= 0 ? value.intValue() : null;
    }
}
