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
import com.uten.imp.features.ai.provider.AiProviderRuntime;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Anthropic Messages 协议(Claude, 以及 DeepSeek/Kimi/智谱的 Anthropic 兼容端点):
 * {@code POST {base}/v1/messages}, 请求头 {@code x-api-key} 与 {@code anthropic-version: 2023-06-01}。
 * JSON_SCHEMA 方式用 {@code output_config.format}; 只有允许时才发温度(新模型对非默认温度返回 400)。
 */
@Component
public class AnthropicMessagesClient implements AiProtocolClient {

    static final String API_VERSION = "2023-06-01";

    private final AiHttpTransport transport;
    private final ObjectMapper json = new ObjectMapper();

    public AnthropicMessagesClient(AiHttpTransport transport) {
        this.transport = transport;
    }

    @Override
    public AiProtocol protocol() {
        return AiProtocol.ANTHROPIC_MESSAGES;
    }

    @Override
    public ChatResponse chat(AiProviderRuntime runtime, ChatRequest request) {
        AiHttpTransport.Exchange exchange = transport.send(runtime, "POST", versionedPath(runtime, "/messages"),
                headers(runtime), requestBody(runtime, request));
        if (!exchange.success()) {
            throw AiErrorMapper.fromStatus(exchange.status(), exchange.body(), runtime.apiKey());
        }
        JsonNode root = parse(exchange.body());
        AiProtocolEnvelope.requireSuccess(root, exchange.status(), root.path("content").isArray());
        StringBuilder text = new StringBuilder();
        for (JsonNode block : root.path("content")) {
            if ("text".equals(block.path("type").asText()) && block.path("text").isTextual()) {
                text.append(block.path("text").asText());
            }
        }
        boolean truncated = "max_tokens".equals(root.path("stop_reason").asText(""));
        JsonNode usage = root.path("usage");
        return new ChatResponse(text.toString(), AiProtocolClient.tokenCount(usage, "input_tokens"),
                AiProtocolClient.tokenCount(usage, "output_tokens"), exchange.status(), truncated, exchange.latencyMs());
    }

    @Override
    public List<String> listModels(AiProviderRuntime runtime) {
        AiHttpTransport.Exchange exchange = transport.send(runtime, "GET", versionedPath(runtime, "/models"),
                headers(runtime), null);
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

    /** 接口地址本身已经以 /v1 结尾时不再重复。 */
    static String versionedPath(AiProviderRuntime runtime, String suffix) {
        return runtime.endpoint().path().endsWith("/v1") ? suffix : "/v1" + suffix;
    }

    byte[] requestBody(AiProviderRuntime runtime, ChatRequest request) {
        ObjectNode body = json.createObjectNode();
        body.put("model", runtime.model());
        body.put("stream", false);
        body.put("max_tokens", request.maxOutputTokens());
        body.put("system", request.systemPrompt());
        ArrayNode content = body.putArray("messages").addObject().put("role", "user").putArray("content");
        for (AiContentPart part : request.parts()) {
            if (part instanceof AiText text) {
                if (!text.text().isEmpty()) {
                    content.addObject().put("type", "text").put("text", text.text());
                }
            } else if (part instanceof AiImage image) {
                content.addObject().put("type", "image").putObject("source")
                        .put("type", "base64")
                        .put("media_type", image.mediaType())
                        .put("data", Base64.getEncoder().encodeToString(image.bytes()));
            }
        }
        if (runtime.sendTemperature()) {
            body.put("temperature", 0);
        }
        if (runtime.jsonMode() == AiJsonMode.JSON_SCHEMA && request.jsonSchema() != null) {
            body.putObject("output_config").putObject("format")
                    .put("type", "json_schema")
                    .set("schema", json.valueToTree(request.jsonSchema()));
        }
        try {
            return json.writeValueAsBytes(body);
        } catch (Exception e) {
            throw new AiCallException(AiErrorCategory.BAD_REQUEST, "AI 请求组装失败");
        }
    }

    private static Map<String, String> headers(AiProviderRuntime runtime) {
        Map<String, String> headers = new LinkedHashMap<>();
        if (runtime.hasApiKey()) {
            headers.put("x-api-key", runtime.apiKey());
        }
        headers.put("anthropic-version", API_VERSION);
        return headers;
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
