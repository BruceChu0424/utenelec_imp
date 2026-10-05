package com.uten.imp.features.ai.client;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.application.port.AiCompletionPort.AiCallException;
import com.uten.imp.application.port.AiCompletionPort.AiContentPart;
import com.uten.imp.application.port.AiCompletionPort.AiErrorCategory;
import com.uten.imp.application.port.AiCompletionPort.AiImage;
import com.uten.imp.application.port.AiCompletionPort.AiText;
import com.uten.imp.features.ai.provider.AiJsonMode;
import com.uten.imp.features.ai.provider.AiProtocol;
import com.uten.imp.features.ai.provider.AiProviderPreset;
import com.uten.imp.features.ai.provider.AiProviderRuntime;
import com.uten.imp.features.ai.provider.AiThinkingControl;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Base64;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * OpenAI Chat Completions 兼容协议(DeepSeek、通义、Kimi、智谱、豆包、硅基流动、OpenAI、Gemini 兼容端点、
 * Ollama、vLLM): {@code POST {base}/chat/completions}, {@code Authorization: Bearer}(没有密钥时不发)。
 */
@Component
public class OpenAiChatClient implements AiProtocolClient {

    private final AiHttpTransport transport;
    private final ObjectMapper json = new ObjectMapper();

    public OpenAiChatClient(AiHttpTransport transport) {
        this.transport = transport;
    }

    @Override
    public AiProtocol protocol() {
        return AiProtocol.OPENAI_CHAT;
    }

    @Override
    public ChatResponse chat(AiProviderRuntime runtime, ChatRequest request) {
        byte[] body = requestBody(runtime, request);
        AiHttpTransport.Exchange exchange = transport.send(runtime, "POST", "/chat/completions",
                headers(runtime), body);
        if (!exchange.success()) {
            throw AiErrorMapper.fromStatus(exchange.status(), exchange.body(), runtime.apiKey());
        }
        JsonNode root = parse(exchange.body());
        AiProtocolEnvelope.requireSuccess(root, exchange.status(), root.path("choices").path(0).path("message").isObject());
        JsonNode choice = root.path("choices").path(0);
        // 服务商的内容审核截断了回答(智谱 sensitive, OpenAI/Azure content_filter): 不是格式错误。
        if (Set.of("sensitive", "content_filter").contains(choice.path("finish_reason").asText(""))) {
            throw AiCallException.contentFiltered(exchange.status());
        }
        JsonNode content = choice.path("message").path("content");
        String text = contentText(content);
        boolean truncated = "length".equals(choice.path("finish_reason").asText(""));
        JsonNode usage = root.path("usage");
        return new ChatResponse(text, AiProtocolClient.tokenCount(usage, "prompt_tokens"),
                AiProtocolClient.tokenCount(usage, "completion_tokens"), exchange.status(), truncated, exchange.latencyMs());
    }

    @Override
    public List<String> listModels(AiProviderRuntime runtime) {
        AiHttpTransport.Exchange exchange = transport.send(runtime, "GET", "/models", headers(runtime), null);
        if (!exchange.success()) {
            throw AiErrorMapper.fromStatus(exchange.status(), exchange.body(), runtime.apiKey());
        }
        List<String> models = new ArrayList<>();
        JsonNode root = parse(exchange.body());
        AiProtocolEnvelope.requireSuccess(root, exchange.status(), root.path("data").isArray());
        for (JsonNode item : root.path("data")) {
            String id = item.path("id").asText("");
            if (!id.isBlank() && id.length() <= 128) {
                models.add(id);
            }
        }
        return models;
    }

    byte[] requestBody(AiProviderRuntime runtime, ChatRequest request) {
        ObjectNode body = json.createObjectNode();
        body.put("model", runtime.model());
        body.put("stream", false);
        ArrayNode messages = body.putArray("messages");
        messages.addObject().put("role", "system").put("content", request.systemPrompt());
        ObjectNode user = messages.addObject().put("role", "user");
        boolean hasImage = request.parts().stream().anyMatch(AiImage.class::isInstance);
        if (!hasImage) {
            StringBuilder text = new StringBuilder();
            for (AiContentPart part : request.parts()) {
                if (!text.isEmpty()) {
                    text.append("\n\n");
                }
                text.append(((AiText) part).text());
            }
            user.put("content", text.toString());
        } else {
            ArrayNode parts = user.putArray("content");
            for (AiContentPart part : request.parts()) {
                if (part instanceof AiText text) {
                    if (!text.text().isEmpty()) {
                        parts.addObject().put("type", "text").put("text", text.text());
                    }
                } else if (part instanceof AiImage image) {
                    parts.addObject().put("type", "image_url").putObject("image_url")
                            .put("url", "data:" + image.mediaType() + ";base64,"
                                    + Base64.getEncoder().encodeToString(image.bytes()));
                }
            }
        }
        if (usesCompletionTokens(runtime)) {
            body.put("max_completion_tokens", request.maxOutputTokens());
        } else {
            body.put("max_tokens", request.maxOutputTokens());
        }
        if (runtime.sendTemperature() && AiReasoningParams.allowsTemperature(runtime, request.reasoningEffort())) {
            body.put("temperature", 0);
        }
        if (runtime.jsonMode() == AiJsonMode.JSON_SCHEMA && request.jsonSchema() != null) {
            ObjectNode schema = body.putObject("response_format").put("type", "json_schema")
                    .putObject("json_schema");
            schema.put("name", request.jsonSchemaName() == null || request.jsonSchemaName().isBlank()
                    ? "result" : request.jsonSchemaName());
            JsonNode schemaNode = json.valueToTree(request.jsonSchema());
            schema.put("strict", strictCompatible(schemaNode));
            schema.set("schema", schemaNode);
        } else if (runtime.jsonMode() != AiJsonMode.NONE) {
            body.putObject("response_format").put("type", "json_object");
        }
        AiReasoningParams.applyOpenAi(body, runtime, request.reasoningEffort());
        try {
            return json.writeValueAsBytes(body);
        } catch (Exception e) {
            throw new AiCallException(AiErrorCategory.BAD_REQUEST, "AI 请求组装失败");
        }
    }

    /**
     * schema 是否满足 OpenAI 严格模式的结构要求: 每一层对象都写了 {@code additionalProperties: false}, 并且
     * {@code required} 列全了 {@code properties} 的每个键(可空字段写成含 {@code "null"} 的类型联合)。不满足时
     * 发 {@code strict: false}(schema 仍作为输出形状的指引), 否则服务商直接 400 拒绝整个请求。
     */
    static boolean strictCompatible(JsonNode schema) {
        if (schema == null || !schema.isObject()) {
            return true;
        }
        JsonNode properties = schema.path("properties");
        if (isObjectType(schema) || properties.isObject()) {
            if (!schema.path("additionalProperties").isBoolean() || schema.path("additionalProperties").asBoolean()) {
                return false;
            }
            Set<String> required = new HashSet<>();
            schema.path("required").forEach(name -> required.add(name.asText()));
            for (Map.Entry<String, JsonNode> field : properties.properties()) {
                if (!required.contains(field.getKey()) || !strictCompatible(field.getValue())) {
                    return false;
                }
            }
        }
        if (!strictCompatible(schema.get("items"))) {
            return false;
        }
        for (String combinator : List.of("anyOf", "oneOf", "allOf")) {
            for (JsonNode option : schema.path(combinator)) {
                if (!strictCompatible(option)) {
                    return false;
                }
            }
        }
        for (String definitions : List.of("$defs", "definitions")) {
            for (JsonNode definition : schema.path(definitions)) {
                if (!strictCompatible(definition)) {
                    return false;
                }
            }
        }
        return true;
    }

    private static boolean isObjectType(JsonNode schema) {
        JsonNode type = schema.path("type");
        if (type.isTextual()) {
            return "object".equals(type.asText());
        }
        for (JsonNode option : type) {
            if ("object".equals(option.asText())) {
                return true;
            }
        }
        return false;
    }

    /** OpenAI 的推理类模型只认 max_completion_tokens(同时发 max_tokens 会被拒)。 */
    private static boolean usesCompletionTokens(AiProviderRuntime runtime) {
        return runtime.preset() == AiProviderPreset.OPENAI
                || runtime.thinkingControl() == AiThinkingControl.OPENAI_REASONING;
    }

    private static Map<String, String> headers(AiProviderRuntime runtime) {
        Map<String, String> headers = new LinkedHashMap<>();
        if (runtime.hasApiKey()) {
            headers.put("Authorization", "Bearer " + runtime.apiKey());
        }
        return headers;
    }

    private static String contentText(JsonNode content) {
        if (content.isTextual()) {
            return content.asText();
        }
        if (content.isArray()) {
            StringBuilder text = new StringBuilder();
            for (JsonNode part : content) {
                if (part.path("text").isTextual()) {
                    text.append(part.path("text").asText());
                }
            }
            return text.toString();
        }
        return "";
    }

    private JsonNode parse(byte[] body) {
        try {
            JsonNode node = json.readTree(body);
            if (node == null || !node.isObject()) {
                throw new AiCallException(AiErrorCategory.INVALID_RESPONSE, "AI 服务返回的内容无法识别");
            }
            return node;
        } catch (AiCallException e) {
            throw e;
        } catch (Exception e) {
            throw new AiCallException(AiErrorCategory.INVALID_RESPONSE, "AI 服务返回的内容无法识别");
        }
    }
}
