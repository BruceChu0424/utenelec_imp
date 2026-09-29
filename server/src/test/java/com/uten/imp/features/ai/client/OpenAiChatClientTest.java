package com.uten.imp.features.ai.client;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiCompletionPort.AiCallException;
import com.uten.imp.application.port.AiCompletionPort.AiErrorCategory;
import com.uten.imp.application.port.AiCompletionPort.AiImage;
import com.uten.imp.application.port.AiCompletionPort.AiText;
import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.features.ai.provider.AiEndpointPolicy;
import com.uten.imp.features.ai.provider.AiJsonMode;
import com.uten.imp.features.ai.provider.AiProtocol;
import com.uten.imp.features.ai.provider.AiProviderPreset;
import com.uten.imp.features.ai.provider.AiProviderRuntime;
import com.uten.imp.features.ai.provider.AiRegion;
import com.uten.imp.features.ai.provider.AiThinkingControl;
import com.uten.imp.features.ai.support.AiTestRuntimes;
import com.uten.imp.features.ai.support.FakeAiProviderServer;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** OpenAI 兼容协议客户端对假服务商(JDK HttpServer)的真实 HTTP 往返。 */
class OpenAiChatClientTest {

    private static final String KEY = "sk-test-0123456789abcdefghijklmnop";
    private static FakeAiProviderServer fake;
    private final ObjectMapper json = new ObjectMapper();
    private OpenAiChatClient client;

    @BeforeAll
    static void startFake() {
        fake = FakeAiProviderServer.start();
    }

    @AfterAll
    static void stopFake() {
        fake.close();
    }

    @BeforeEach
    void setUp() {
        fake.reset();
        client = new OpenAiChatClient(new AiHttpTransport(new AiProperties()));
    }

    private static AiProtocolClient.ChatRequest request(String text) {
        return new AiProtocolClient.ChatRequest("Extract data. Respond with a single JSON object.",
                List.of(new AiText(text, false)), null, null, 256);
    }

    @Test
    void sendsBearerKeyJsonModeThinkingOffAndParsesContentAndUsage() throws Exception {
        fake.enqueue(FakeAiProviderServer.openAiContent("{\"ok\":true}", 321, 12, "stop"));

        AiProtocolClient.ChatResponse response = client.chat(AiTestRuntimes.openAi(fake, KEY), request("hello"));

        assertThat(response.content()).isEqualTo("{\"ok\":true}");
        assertThat(response.inputTokens()).isEqualTo(321);
        assertThat(response.outputTokens()).isEqualTo(12);
        assertThat(response.truncated()).isFalse();
        FakeAiProviderServer.RecordedRequest sent = fake.lastChatRequest();
        assertThat(sent.path()).isEqualTo("/v1/chat/completions");
        assertThat(sent.header("Authorization")).isEqualTo("Bearer " + KEY);
        JsonNode body = json.readTree(sent.body());
        assertThat(body.path("model").asText()).isEqualTo("fake-model");
        assertThat(body.path("messages").get(0).path("role").asText()).isEqualTo("system");
        assertThat(body.path("messages").get(1).path("content").asText()).isEqualTo("hello");
        assertThat(body.path("max_tokens").asInt()).isEqualTo(256);
        assertThat(body.has("max_completion_tokens")).isFalse();
        assertThat(body.path("temperature").asInt()).isZero();
        assertThat(body.path("response_format").path("type").asText()).isEqualTo("json_object");
        assertThat(body.path("thinking").path("type").asText()).isEqualTo("disabled");
    }

    @Test
    void omitsAuthorizationWithoutKeyAndUsesProviderSpecificThinkingSwitches() throws Exception {
        client.chat(AiTestRuntimes.openAi(fake, null, AiJsonMode.NONE, AiThinkingControl.DASHSCOPE, false, 30),
                request("x"));
        FakeAiProviderServer.RecordedRequest sent = fake.lastChatRequest();
        JsonNode body = json.readTree(sent.body());
        assertThat(sent.header("Authorization")).isNull();
        assertThat(body.path("enable_thinking").asBoolean(true)).isFalse();
        assertThat(body.has("temperature")).isFalse();
        assertThat(body.has("response_format")).isFalse();

        AiProviderRuntime openAi = new AiProviderRuntime(UUID.randomUUID(), "OpenAI", AiProviderPreset.OPENAI,
                AiRegion.LOCAL, AiProtocol.OPENAI_CHAT, AiEndpointPolicy.parse(fake.openAiBaseUrl()), "gpt-x", KEY,
                AiJsonMode.JSON_SCHEMA, AiThinkingControl.OPENAI_REASONING, true, true, 4096, 30);
        client.chat(openAi, new AiProtocolClient.ChatRequest("sys", List.of(new AiText("x", false)), "invoice",
                Map.of("type", "object", "properties", Map.of("ok", Map.of("type", "boolean"))), 128));
        body = json.readTree(fake.lastChatRequest().body());
        assertThat(body.path("reasoning_effort").asText()).isEqualTo("none");
        assertThat(body.path("max_completion_tokens").asInt()).isEqualTo(128);
        assertThat(body.has("max_tokens")).isFalse();
        assertThat(body.path("response_format").path("type").asText()).isEqualTo("json_schema");
        assertThat(body.path("response_format").path("json_schema").path("name").asText()).isEqualTo("invoice");
        // 没写 additionalProperties:false / required 的 schema 不满足严格模式: 发 strict=false, 否则 OpenAI 直接 400。
        assertThat(body.path("response_format").path("json_schema").path("strict").asBoolean(true)).isFalse();
        assertThat(body.path("response_format").path("json_schema").path("schema").path("type").asText())
                .isEqualTo("object");
    }

    @Test
    void strictModeIsSentOnlyForSchemasThatMeetItsRules() throws Exception {
        AiProviderRuntime openAi = new AiProviderRuntime(UUID.randomUUID(), "OpenAI", AiProviderPreset.OPENAI,
                AiRegion.LOCAL, AiProtocol.OPENAI_CHAT, AiEndpointPolicy.parse(fake.openAiBaseUrl()), "gpt-x", KEY,
                AiJsonMode.JSON_SCHEMA, AiThinkingControl.OPENAI_REASONING, true, true, 4096, 30);
        Map<String, Object> line = Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("partNo", Map.of("type", List.of("string", "null")),
                        "qty", Map.of("type", List.of("number", "null"))),
                "required", List.of("partNo", "qty"));
        Map<String, Object> strictSchema = Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("clientName", Map.of("type", List.of("string", "null")),
                        "lines", Map.of("type", "array", "items", line)),
                "required", List.of("clientName", "lines"));

        client.chat(openAi, new AiProtocolClient.ChatRequest("sys", List.of(new AiText("x", false)), "intake",
                strictSchema, 128));
        assertThat(json.readTree(fake.lastChatRequest().body()).path("response_format").path("json_schema")
                .path("strict").asBoolean()).isTrue();

        // 嵌套对象漏了一个 required(「没有就不填」的写法): 整个请求降为 strict=false。
        Map<String, Object> looseLine = Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("partNo", Map.of("type", "string"), "qty", Map.of("type", "number")),
                "required", List.of("partNo"));
        client.chat(openAi, new AiProtocolClient.ChatRequest("sys", List.of(new AiText("x", false)), "intake",
                Map.of("type", "object", "additionalProperties", false,
                        "properties", Map.of("lines", Map.of("type", "array", "items", looseLine)),
                        "required", List.of("lines")), 128));
        assertThat(json.readTree(fake.lastChatRequest().body()).path("response_format").path("json_schema")
                .path("strict").asBoolean(true)).isFalse();

        assertThat(OpenAiChatClient.strictCompatible(json.valueToTree(Map.of("type", "object",
                "properties", Map.of("a", Map.of("type", "string")), "required", List.of("a"))))).isFalse();
        assertThat(OpenAiChatClient.strictCompatible(json.valueToTree(Map.of("anyOf", List.of(
                Map.of("type", "string"), Map.of("type", "object", "properties", Map.of("a", Map.of("type", "string")),
                        "required", List.of("a"), "additionalProperties", true)))))).isFalse();
        assertThat(OpenAiChatClient.strictCompatible(json.valueToTree(Map.of("type", "string")))).isTrue();
    }

    @Test
    void aStrictSchemaRejectionIsABadRequestWithTheSanitizedReason() {
        fake.enqueue(FakeAiProviderServer.openAiError(400, "Invalid schema for response_format 'intake': In context="
                + "(), 'required' is required to be supplied and to be an array including every key in properties."));
        AiProviderRuntime openAi = new AiProviderRuntime(UUID.randomUUID(), "OpenAI", AiProviderPreset.OPENAI,
                AiRegion.LOCAL, AiProtocol.OPENAI_CHAT, AiEndpointPolicy.parse(fake.openAiBaseUrl()), "gpt-x", KEY,
                AiJsonMode.JSON_SCHEMA, AiThinkingControl.OPENAI_REASONING, true, true, 4096, 30);

        assertThatThrownBy(() -> client.chat(openAi, new AiProtocolClient.ChatRequest("sys",
                List.of(new AiText("x", false)), "intake", Map.of("type", "object"), 128)))
                .isInstanceOf(AiCallException.class)
                .satisfies(error -> {
                    AiCallException ai = (AiCallException) error;
                    assertThat(ai.category()).isEqualTo(AiErrorCategory.BAD_REQUEST);
                    assertThat(ai.httpStatus()).isEqualTo(400);
                    assertThat(ai.getMessage()).startsWith("服务商不接受这个请求: Invalid schema");
                });
    }

    @Test
    void sendsImagesAsDataUrlParts() throws Exception {
        client.chat(AiTestRuntimes.openAi(fake, KEY), new AiProtocolClient.ChatRequest("sys",
                List.of(new AiText("look", false), new AiImage(new byte[]{1, 2, 3}, "image/png")), null, null, 64));

        JsonNode content = json.readTree(fake.lastChatRequest().body()).path("messages").get(1).path("content");
        assertThat(content.isArray()).isTrue();
        assertThat(content.get(0).path("type").asText()).isEqualTo("text");
        assertThat(content.get(1).path("image_url").path("url").asText()).isEqualTo("data:image/png;base64,AQID");
    }

    @Test
    void reportsTruncationAndEmptyContent() {
        fake.enqueue(FakeAiProviderServer.openAiContent("{\"lines\":[", 10, 4096, "length"),
                FakeAiProviderServer.openAiContent(null, 10, 0, "stop"));

        assertThat(client.chat(AiTestRuntimes.openAi(fake, KEY), request("x")).truncated()).isTrue();
        assertThat(client.chat(AiTestRuntimes.openAi(fake, KEY), request("x")).content()).isEmpty();
    }

    @ParameterizedTest(name = "HTTP {0} -> {1}")
    @CsvSource({
            "401, AUTH",
            "403, AUTH",
            "402, QUOTA",
            "404, NOT_FOUND",
            "429, RATE_LIMIT",
            "500, SERVER",
            "503, SERVER",
            "400, BAD_REQUEST",
            "422, BAD_REQUEST",
    })
    void mapsProviderErrorsToPlainCategories(int status, AiErrorCategory category) {
        fake.enqueue(FakeAiProviderServer.openAiError(status, "provider says no"));

        assertThatThrownBy(() -> client.chat(AiTestRuntimes.openAi(fake, KEY), request("x")))
                .isInstanceOf(AiCallException.class)
                .satisfies(error -> {
                    AiCallException ai = (AiCallException) error;
                    assertThat(ai.category()).isEqualTo(category);
                    assertThat(ai.httpStatus()).isEqualTo(status);
                    assertThat(ai.getMessage()).doesNotContain(KEY);
                });
    }

    @Test
    void badRequestReflectsOnlyTheSanitizedProviderMessageWithoutTheKey() {
        fake.enqueue(FakeAiProviderServer.openAiError(400,
                "Unsupported parameter: temperature for key " + KEY + " \n\u0007 and more " + "x".repeat(300)));

        assertThatThrownBy(() -> client.chat(AiTestRuntimes.openAi(fake, KEY), request("x")))
                .isInstanceOf(AiCallException.class)
                .satisfies(error -> {
                    String message = error.getMessage();
                    assertThat(message).startsWith("服务商不接受这个请求: Unsupported parameter: temperature");
                    assertThat(message).doesNotContain(KEY).doesNotContain("\u0007").doesNotContain("\n");
                    assertThat(message.length()).isLessThanOrEqualTo("服务商不接受这个请求: ".length() + 120);
                });
    }

    @Test
    void neverFollowsRedirects() {
        fake.enqueue(FakeAiProviderServer.redirect("http://169.254.169.254/latest/meta-data"));

        assertThatThrownBy(() -> client.chat(AiTestRuntimes.openAi(fake, KEY), request("x")))
                .isInstanceOf(AiCallException.class)
                .satisfies(error -> {
                    assertThat(((AiCallException) error).category()).isEqualTo(AiErrorCategory.NETWORK);
                    assertThat(error.getMessage()).contains("跳转");
                });
        assertThat(fake.requests()).hasSize(1);
    }

    @Test
    void unparsableBodyIsInvalidResponse() {
        fake.enqueue(FakeAiProviderServer.raw(200, "<html>gateway</html>"));

        assertThatThrownBy(() -> client.chat(AiTestRuntimes.openAi(fake, KEY), request("x")))
                .isInstanceOf(AiCallException.class)
                .extracting(error -> ((AiCallException) error).category())
                .isEqualTo(AiErrorCategory.INVALID_RESPONSE);
    }

    @Test
    void timesOutWithinTheProviderTimeout() {
        fake.enqueue(FakeAiProviderServer.openAiContent("{}").withDelay(3_000));
        AiProviderRuntime quick = AiTestRuntimes.openAi(fake, KEY, AiJsonMode.JSON_OBJECT, AiThinkingControl.NONE,
                true, 1);

        long started = System.nanoTime();
        assertThatThrownBy(() -> client.chat(quick, request("x")))
                .isInstanceOf(AiCallException.class)
                .extracting(error -> ((AiCallException) error).category())
                .isEqualTo(AiErrorCategory.TIMEOUT);
        assertThat((System.nanoTime() - started) / 1_000_000).isLessThan(3_000);
    }

    @Test
    void listsModelsAndMapsMissingListEndpoint() {
        fake.models(List.of("deepseek-flash", "deepseek-v4-pro"));
        assertThat(client.listModels(AiTestRuntimes.openAi(fake, KEY))).containsExactly("deepseek-flash",
                "deepseek-v4-pro");
        assertThat(fake.requests().get(0).path()).isEqualTo("/v1/models");

        fake.modelsStatus(404);
        assertThatThrownBy(() -> client.listModels(AiTestRuntimes.openAi(fake, KEY)))
                .isInstanceOf(AiCallException.class)
                .extracting(error -> ((AiCallException) error).category())
                .isEqualTo(AiErrorCategory.NOT_FOUND);
    }

    @Test
    void blocksPolicyViolationsBeforeAnyNetworkCall() {
        AiProviderRuntime publicAsLocal = new AiProviderRuntime(UUID.randomUUID(), "x", AiProviderPreset.CUSTOM,
                AiRegion.MAINLAND, AiProtocol.OPENAI_CHAT, AiEndpointPolicy.parse(fake.openAiBaseUrl()), "m", KEY,
                AiJsonMode.JSON_OBJECT, AiThinkingControl.NONE, true, false, 256, 30);

        assertThatThrownBy(() -> client.chat(publicAsLocal, request("x")))
                .isInstanceOf(AiCallException.class)
                .extracting(error -> ((AiCallException) error).category())
                .isEqualTo(AiErrorCategory.BLOCKED);
        assertThat(fake.requests()).isEmpty();
    }
}
