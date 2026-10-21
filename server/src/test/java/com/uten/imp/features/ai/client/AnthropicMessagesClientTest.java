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
import org.junit.jupiter.params.provider.ValueSource;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Anthropic Messages 协议客户端对假服务商的真实 HTTP 往返。 */
class AnthropicMessagesClientTest {

    @Test void missingUsageIsUnknownInsteadOfZero() {
        fake.enqueue(FakeAiProviderServer.json(200, "{\"content\":[{\"type\":\"text\",\"text\":\"{}\"}],\"stop_reason\":\"end_turn\"}"));
        var response = client.chat(AiTestRuntimes.anthropic(fake, KEY, AiJsonMode.JSON_OBJECT, false),
                new AiProtocolClient.ChatRequest("Return JSON", List.of(new AiText("hello", false)), null, null, 100));
        assertThat(response.inputTokens()).isNull(); assertThat(response.outputTokens()).isNull();
    }

    private static final String KEY = "sk-ant-test-0123456789abcdefghijkl";
    private static FakeAiProviderServer fake;
    private final ObjectMapper json = new ObjectMapper();
    private AnthropicMessagesClient client;

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
        client = new AnthropicMessagesClient(new AiHttpTransport(new AiProperties()));
    }

    @Test
    void sendsVersionHeaderKeyStructuredOutputAndNoTemperature() throws Exception {
        fake.enqueue(FakeAiProviderServer.anthropicContent("{\"ok\":true}", 77, 9, "end_turn"));
        Map<String, Object> schema = Map.of("type", "object", "properties", Map.of("ok", Map.of("type", "boolean")));

        AiProtocolClient.ChatResponse response = client.chat(
                AiTestRuntimes.anthropic(fake, KEY, AiJsonMode.JSON_SCHEMA, false),
                new AiProtocolClient.ChatRequest("system prompt",
                        List.of(new AiText("text part", false), new AiImage(new byte[]{9, 8}, "image/jpeg")),
                        "result", schema, 512));

        assertThat(response.content()).isEqualTo("{\"ok\":true}");
        assertThat(response.inputTokens()).isEqualTo(77);
        assertThat(response.outputTokens()).isEqualTo(9);
        assertThat(response.stopReason()).isEqualTo("end_turn");
        assertThat(response.thinkingOnly()).isFalse();
        FakeAiProviderServer.RecordedRequest sent = fake.lastChatRequest();
        assertThat(sent.path()).isEqualTo("/anthropic/v1/messages");
        assertThat(sent.header("x-api-key")).isEqualTo(KEY);
        assertThat(sent.header("anthropic-version")).isEqualTo("2023-06-01");
        assertThat(sent.header("Authorization")).isNull();
        JsonNode body = json.readTree(sent.body());
        assertThat(body.path("system").asText()).isEqualTo("system prompt");
        assertThat(body.path("stream").isBoolean()).isTrue();
        assertThat(body.path("stream").asBoolean()).isFalse();
        assertThat(body.path("max_tokens").asInt()).isEqualTo(512);
        assertThat(body.has("temperature")).isFalse();
        JsonNode content = body.path("messages").get(0).path("content");
        assertThat(content.get(0).path("text").asText()).isEqualTo("text part");
        assertThat(content.get(1).path("source").path("media_type").asText()).isEqualTo("image/jpeg");
        assertThat(content.get(1).path("source").path("data").asText()).isEqualTo("CQg=");
        assertThat(body.path("output_config").path("format").path("type").asText()).isEqualTo("json_schema");
        assertThat(body.path("output_config").path("format").path("schema").path("type").asText())
                .isEqualTo("object");
    }

    @Test
    void doesNotDuplicateV1WhenTheBaseUrlAlreadyEndsWithIt() {
        AiProviderRuntime withV1 = new AiProviderRuntime(UUID.randomUUID(), "x", AiProviderPreset.CUSTOM,
                AiRegion.LOCAL, AiProtocol.ANTHROPIC_MESSAGES, AiEndpointPolicy.parse(fake.rootUrl() + "/v1"),
                "m", KEY, AiJsonMode.JSON_OBJECT, AiThinkingControl.NONE, true, false, 256, 30);

        client.chat(withV1, new AiProtocolClient.ChatRequest("s", List.of(new AiText("x", false)), null, null, 64));

        assertThat(fake.lastChatRequest().path()).isEqualTo("/v1/messages");
    }

    @ParameterizedTest
    @ValueSource(strings = {"max_tokens", "model_context_window_exceeded"})
    void reportsTokenAndContextLimitsAsTruncated(String stopReason) {
        fake.enqueue(FakeAiProviderServer.anthropicContent("{\"lines\":[", 5, 64, stopReason));

        assertThat(client.chat(AiTestRuntimes.anthropic(fake, KEY, AiJsonMode.JSON_OBJECT, false),
                new AiProtocolClient.ChatRequest("s", List.of(new AiText("x", false)), null, null, 64)).truncated())
                .isTrue();
    }

    @Test void refusalRemainsContentFilteredEvenWhenTheProviderOmitsItsPayload() {
        fake.enqueue(FakeAiProviderServer.json(200, "{\"stop_reason\":\"refusal\"}"));
        assertThatThrownBy(() -> client.chat(AiTestRuntimes.anthropic(fake, KEY, AiJsonMode.JSON_OBJECT, false),
                new AiProtocolClient.ChatRequest("s", List.of(new AiText("x", false)), null, null, 64)))
                .isInstanceOf(AiCallException.class).satisfies(error -> {
                    assertThat(((AiCallException) error).isContentFiltered()).isTrue();
                    assertThat(((AiCallException) error).httpStatus()).isEqualTo(200);
                });
    }

    @Test
    void thinkingOnlyAtTheOutputLimitNeverBecomesBusinessJson() {
        fake.enqueue(FakeAiProviderServer.json(200, """
                {"content":[{"type":"thinking","thinking":"{}"}],
                 "stop_reason":"max_tokens","usage":{"input_tokens":2818,"output_tokens":1360}}
                """));

        var response = client.chat(AiTestRuntimes.anthropic(fake, KEY, AiJsonMode.JSON_OBJECT, false),
                new AiProtocolClient.ChatRequest("s", List.of(new AiText("x", false)), null, null, 1360));

        assertThat(response.content()).isEmpty();
        assertThat(response.thinkingOnly()).isTrue();
        assertThat(response.truncated()).isTrue();
        assertThat(response.stopReason()).isEqualTo("max_tokens");
        assertThat(response.httpStatus()).isEqualTo(200);
        assertThat(response.outputTokens()).isEqualTo(1360);
    }

    @Test
    void separatesThinkingFromTheFinalTextAndBoundsDiagnosticStopReasons() {
        fake.enqueue(FakeAiProviderServer.json(200, """
                {"content":[{"type":"thinking","thinking":"private reasoning"},
                 {"type":"text","text":"{}"}],"stop_reason":"end_turn"}
                """), FakeAiProviderServer.json(200, """
                {"content":[{"type":"redacted_thinking","data":"private reasoning"}],
                 "stop_reason":"private upstream prompt"}
                """));
        var runtime = AiTestRuntimes.anthropic(fake, KEY, AiJsonMode.JSON_OBJECT, false);
        var request = new AiProtocolClient.ChatRequest("s", List.of(new AiText("x", false)), null, null, 1360);

        var answered = client.chat(runtime, request);
        assertThat(answered.content()).isEqualTo("{}");
        assertThat(answered.thinkingOnly()).isFalse();
        assertThat(answered.stopReason()).isEqualTo("end_turn");
        var redactedOnly = client.chat(runtime, request);
        assertThat(redactedOnly.content()).isEmpty();
        assertThat(redactedOnly.thinkingOnly()).isTrue();
        assertThat(redactedOnly.stopReason()).isEqualTo("unknown");
    }

    @ParameterizedTest
    @ValueSource(strings = {"<html>private upstream response</html>", "[]", "null", "{\"content\":\"wrong envelope\"}"})
    void malformedSuccessResponseRetainsItsHttpStatusWithoutItsBody(String body) {
        fake.enqueue(FakeAiProviderServer.raw(200, body));

        assertThatThrownBy(() -> client.chat(AiTestRuntimes.anthropic(fake, KEY, AiJsonMode.JSON_OBJECT, false),
                new AiProtocolClient.ChatRequest("s", List.of(new AiText("x", false)), null, null, 64)))
                .isInstanceOf(AiCallException.class).satisfies(error -> {
                    AiCallException ai = (AiCallException) error;
                    assertThat(ai.category()).isEqualTo(AiErrorCategory.INVALID_RESPONSE);
                    assertThat(ai.httpStatus()).isEqualTo(200);
                    assertThat(ai.getMessage()).doesNotContain("private upstream", "wrong envelope");
                });
    }

    @Test void httpSuccessWithBusinessFailureIsAConfigurationErrorWithoutLeakingItsBody() {
        fake.enqueue(FakeAiProviderServer.json(200, "{\"code\":\"500\",\"msg\":\"private prompt " + KEY + "\"}"));
        assertThatThrownBy(() -> client.chat(AiTestRuntimes.anthropic(fake, KEY, AiJsonMode.JSON_OBJECT, false),
                new AiProtocolClient.ChatRequest("s", List.of(new AiText("hello", false)), null, null, 512)))
                .isInstanceOf(AiCallException.class).satisfies(error -> {
                    AiCallException ai = (AiCallException) error;
                    assertThat(ai.category()).isEqualTo(AiErrorCategory.BAD_REQUEST);
                    assertThat(ai.httpStatus()).isEqualTo(200);
                    assertThat(ai.getMessage()).contains("接口协议").doesNotContain(KEY, "private prompt");
                });
    }

    @ParameterizedTest(name = "HTTP {0} -> {1}")
    @CsvSource({"401, AUTH", "403, AUTH", "404, NOT_FOUND", "429, RATE_LIMIT", "529, SERVER", "400, BAD_REQUEST"})
    void mapsAnthropicErrors(int status, AiErrorCategory category) {
        fake.enqueue(FakeAiProviderServer.anthropicError(status, "invalid_request_error",
                "temperature is not supported"));

        assertThatThrownBy(() -> client.chat(AiTestRuntimes.anthropic(fake, KEY, AiJsonMode.JSON_OBJECT, true),
                new AiProtocolClient.ChatRequest("s", List.of(new AiText("x", false)), null, null, 64)))
                .isInstanceOf(AiCallException.class)
                .satisfies(error -> {
                    assertThat(((AiCallException) error).category()).isEqualTo(category);
                    if (category == AiErrorCategory.BAD_REQUEST) {
                        assertThat(error.getMessage()).contains("temperature is not supported");
                    }
                });
    }

    @Test
    void listsModels() {
        fake.models(List.of("claude-sonnet-5"));

        assertThat(client.listModels(AiTestRuntimes.anthropic(fake, KEY, AiJsonMode.JSON_OBJECT, false)))
                .containsExactly("claude-sonnet-5");
        assertThat(fake.requests().get(0).path()).isEqualTo("/anthropic/v1/models");
        assertThat(fake.requests().get(0).header("x-api-key")).isEqualTo(KEY);
    }
}
