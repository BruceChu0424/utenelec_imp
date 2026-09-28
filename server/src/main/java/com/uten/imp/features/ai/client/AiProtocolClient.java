package com.uten.imp.features.ai.client;

import com.uten.imp.application.port.AiCompletionPort.AiContentPart;
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
     * @param jsonSchema 服务商用 JSON_SCHEMA 方式时下发的 schema; 可为空
     */
    record ChatRequest(String systemPrompt, List<AiContentPart> parts, String jsonSchemaName,
                       Map<String, Object> jsonSchema, int maxOutputTokens) {
        public ChatRequest {
            Objects.requireNonNull(systemPrompt, "systemPrompt");
            parts = List.copyOf(Objects.requireNonNull(parts, "parts"));
        }
    }

    /**
     * 回复。
     *
     * @param content   模型输出的文本
     * @param truncated 因输出长度上限被截断
     */
    record ChatResponse(String content, int inputTokens, int outputTokens, int httpStatus, boolean truncated,
                        long latencyMs) {
    }
}
