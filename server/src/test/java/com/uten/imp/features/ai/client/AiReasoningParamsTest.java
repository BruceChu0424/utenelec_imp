package com.uten.imp.features.ai.client;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiCompletionPort.AiReasoningEffort;
import com.uten.imp.application.port.AiCompletionPort.AiText;
import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.features.ai.provider.AiEndpointPolicy;
import com.uten.imp.features.ai.provider.AiJsonMode;
import com.uten.imp.features.ai.provider.AiProtocol;
import com.uten.imp.features.ai.provider.AiProviderPreset;
import com.uten.imp.features.ai.provider.AiProviderRuntime;
import com.uten.imp.features.ai.provider.AiRegion;
import com.uten.imp.features.ai.provider.AiThinkingControl;
import com.uten.imp.features.ai.support.FakeAiProviderServer;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.application.port.AiCompletionPort.AiReasoningEffort.DEFAULT;
import static com.uten.imp.application.port.AiCompletionPort.AiReasoningEffort.HIGH;
import static com.uten.imp.application.port.AiCompletionPort.AiReasoningEffort.LOW;
import static com.uten.imp.application.port.AiCompletionPort.AiReasoningEffort.MEDIUM;
import static com.uten.imp.application.port.AiCompletionPort.AiReasoningEffort.OFF;
import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-152 provider-neutral thinking depth mapped to each provider's own parameters, and the request body
 * the two protocol clients actually send (DEFAULT keeps the earlier behaviour for recognition purposes).
 */
class AiReasoningParamsTest {
    private static FakeAiProviderServer fake;
    private final ObjectMapper json = new ObjectMapper();

    @BeforeAll static void start() { fake = FakeAiProviderServer.start(); }
    @AfterAll static void stop() { fake.close(); }
    @BeforeEach void reset() { fake.reset(); }

    private static AiProviderRuntime runtime(AiProtocol protocol, AiThinkingControl control, int timeout) {
        return runtime(protocol, control, "m", false, 32768, timeout);
    }

    private static AiProviderRuntime runtime(AiProtocol protocol, AiThinkingControl control, String model,
                                             boolean temperature, int maxOutput, int timeout) {
        String base = protocol == AiProtocol.ANTHROPIC_MESSAGES ? fake.anthropicBaseUrl() : fake.openAiBaseUrl();
        return new AiProviderRuntime(UUID.randomUUID(), "x", AiProviderPreset.CUSTOM, AiRegion.LOCAL, protocol,
                AiEndpointPolicy.parse(base), model, null, AiJsonMode.JSON_OBJECT, control, temperature, false, maxOutput,
                timeout);
    }

    private static AiProviderRuntime openAi(AiThinkingControl control) {
        return runtime(AiProtocol.OPENAI_CHAT, control, 120);
    }

    @Test void openAiCompatibleMappingPerProvider() {
        var deepseek = openAi(AiThinkingControl.DEEPSEEK);
        assertThat(AiReasoningParams.openAi(deepseek, DEFAULT)).isEqualTo(Map.of("thinking", Map.of("type", "disabled")));
        assertThat(AiReasoningParams.openAi(deepseek, OFF)).isEqualTo(Map.of("thinking", Map.of("type", "disabled")));
        assertThat(AiReasoningParams.openAi(deepseek, MEDIUM))
                .isEqualTo(Map.of("thinking", Map.of("type", "enabled"), "reasoning_effort", "high"));
        assertThat(AiReasoningParams.openAi(deepseek, HIGH)).containsEntry("reasoning_effort", "max");
        var openAi = openAi(AiThinkingControl.OPENAI_REASONING);
        assertThat(AiReasoningParams.openAi(openAi, DEFAULT)).isEqualTo(Map.of("reasoning_effort", "none"));
        assertThat(AiReasoningParams.openAi(openAi, MEDIUM)).isEqualTo(Map.of("reasoning_effort", "medium"));
        // GLM-5.3 cannot switch thinking off: "no thinking" is its lightest level; DEFAULT sends nothing as before.
        var zhipu = openAi(AiThinkingControl.ZHIPU);
        assertThat(AiReasoningParams.openAi(zhipu, DEFAULT)).isEmpty();
        assertThat(AiReasoningParams.openAi(zhipu, OFF))
                .isEqualTo(Map.of("thinking", Map.of("type", "enabled"), "reasoning_effort", "low"));
        assertThat(AiReasoningParams.openAi(zhipu, MEDIUM)).containsEntry("reasoning_effort", "high");
        assertThat(AiReasoningParams.openAi(zhipu, HIGH)).containsEntry("reasoning_effort", "max");
        assertThat(AiReasoningParams.openAi(openAi(AiThinkingControl.NONE), HIGH)).isEmpty();
        assertThat(AiReasoningParams.openAi(openAi(AiThinkingControl.ANTHROPIC_EFFORT), HIGH)).isEmpty();
    }

    /**
     * Tongyi thinking only works with streaming output and never with JSON mode (Model Studio error codes), and
     * every chat call here is non-streaming JSON: the dialect only switches thinking off, whatever the setting.
     */
    @Test void dashscopeNeverTurnsThinkingOnAndIsNotAdjustable() {
        var dashscope = openAi(AiThinkingControl.DASHSCOPE);
        for (var level : AiReasoningEffort.values()) {
            assertThat(AiReasoningParams.openAi(dashscope, level)).as(level.name()).isEqualTo(Map.of("enable_thinking", false));
        }
        assertThat(AiReasoningParams.supported(dashscope)).isFalse();
        assertThat(AiReasoningParams.maxOutputTokens(dashscope, 8192, HIGH)).isEqualTo(8192);
        assertThat(AiReasoningParams.timeoutSeconds(dashscope, OFF)).isEqualTo(120);
        assertThat(AiProviderPreset.DASHSCOPE.jsonMode()).isEqualTo(AiJsonMode.JSON_OBJECT);
    }

    @Test void anthropicMessagesUsesEffortOnly() {
        var zhipu = runtime(AiProtocol.ANTHROPIC_MESSAGES, AiThinkingControl.ZHIPU, 120);
        assertThat(AiReasoningParams.anthropicEffort(zhipu, DEFAULT)).isNull();
        assertThat(AiReasoningParams.anthropicEffort(zhipu, OFF)).isEqualTo("low");
        assertThat(AiReasoningParams.anthropicEffort(zhipu, MEDIUM)).isEqualTo("high");
        assertThat(AiReasoningParams.anthropicEffort(zhipu, HIGH)).isEqualTo("max");
        var claude = runtime(AiProtocol.ANTHROPIC_MESSAGES, AiThinkingControl.ANTHROPIC_EFFORT, "claude-sonnet-5", false, 32768, 120);
        assertThat(AiReasoningParams.anthropicEffort(claude, OFF)).isEqualTo("low");
        assertThat(AiReasoningParams.anthropicEffort(claude, MEDIUM)).isEqualTo("medium");
        assertThat(AiReasoningParams.anthropicEffort(claude, HIGH)).isEqualTo("high");
        assertThat(AiReasoningParams.anthropicEffort(runtime(AiProtocol.ANTHROPIC_MESSAGES, AiThinkingControl.DEEPSEEK, 120), HIGH)).isNull();
        assertThat(AiReasoningParams.anthropicEffort(runtime(AiProtocol.ANTHROPIC_MESSAGES, AiThinkingControl.NONE, 120), HIGH)).isNull();
    }

    /** Haiku 4.5, Sonnet 4.5 and older Claude models reject output_config.effort: no setting may send it. */
    @Test void claudeModelsThatRejectEffortAreNeverSentIt() {
        for (String model : List.of("claude-haiku-4-5-20251001", "claude-haiku-4-5", "claude-sonnet-4-5-20250929",
                "claude-sonnet-4-20250514", "claude-opus-4-1-20250805", "claude-opus-4-20250514",
                "claude-3-7-sonnet-20250219", "anthropic.claude-haiku-4-5", "us.anthropic.claude-sonnet-4-5-20250929-v1:0")) {
            var runtime = runtime(AiProtocol.ANTHROPIC_MESSAGES, AiThinkingControl.ANTHROPIC_EFFORT, model, false, 32768, 120);
            assertThat(AiReasoningParams.supported(runtime)).as(model).isFalse();
            for (var level : AiReasoningEffort.values()) {
                assertThat(AiReasoningParams.anthropicEffort(runtime, level)).as(model + " " + level).isNull();
            }
            assertThat(AiReasoningParams.maxOutputTokens(runtime, 8192, HIGH)).isEqualTo(8192);
        }
        for (String model : List.of("claude-sonnet-5", "claude-opus-4-5-20251101", "claude-sonnet-4-6", "claude-opus-4-8",
                "claude-opus-5-5", "claude-sonnet-5-5")) {
            var runtime = runtime(AiProtocol.ANTHROPIC_MESSAGES, AiThinkingControl.ANTHROPIC_EFFORT, model, false, 32768, 120);
            assertThat(AiReasoningParams.supported(runtime)).as(model).isTrue();
        }
    }

    @Test void supportFollowsTheEffectiveProtocol() {
        assertThat(AiThinkingControl.ZHIPU.supportsEffort(AiProtocol.OPENAI_CHAT)).isTrue();
        assertThat(AiThinkingControl.ZHIPU.supportsEffort(AiProtocol.ANTHROPIC_MESSAGES)).isTrue();
        assertThat(AiThinkingControl.DEEPSEEK.supportsEffort(AiProtocol.ANTHROPIC_MESSAGES)).isFalse();
        assertThat(AiThinkingControl.ANTHROPIC_EFFORT.supportsEffort(AiProtocol.OPENAI_CHAT)).isFalse();
        assertThat(AiThinkingControl.DASHSCOPE.supportsEffort(AiProtocol.OPENAI_CHAT)).isFalse();
        assertThat(AiThinkingControl.NONE.supportsEffort(AiProtocol.OPENAI_CHAT)).isFalse();
        assertThat(AiProviderPreset.ZHIPU.thinkingControl()).isEqualTo(AiThinkingControl.ZHIPU);
        assertThat(AiProviderPreset.ANTHROPIC.thinkingControl()).isEqualTo(AiThinkingControl.ANTHROPIC_EFFORT);
    }

    @Test void thinkingRoomStaysWithinTheConfiguredMaximumOutput() {
        var zhipu = runtime(AiProtocol.ANTHROPIC_MESSAGES, AiThinkingControl.ZHIPU, 120);
        assertThat(AiReasoningParams.maxOutputTokens(zhipu, 8192, DEFAULT)).isEqualTo(8192);
        assertThat(AiReasoningParams.maxOutputTokens(zhipu, 8192, OFF)).isEqualTo(8192);
        assertThat(AiReasoningParams.maxOutputTokens(zhipu, 8192, MEDIUM)).isEqualTo(12288);
        assertThat(AiReasoningParams.maxOutputTokens(zhipu, 8192, HIGH)).isEqualTo(24576);
        assertThat(AiReasoningParams.maxOutputTokens(zhipu, 30000, HIGH)).as("never above the configured maximum").isEqualTo(32768);
        // The admin's maximum output (the model's limit and the cost cap) is never exceeded.
        var capped = runtime(AiProtocol.ANTHROPIC_MESSAGES, AiThinkingControl.ZHIPU, "m", false, 8192, 120);
        assertThat(AiReasoningParams.maxOutputTokens(capped, 8192, HIGH)).isEqualTo(8192);
        assertThat(AiReasoningParams.maxOutputTokens(capped, 4096, MEDIUM)).isEqualTo(8192);
        assertThat(AiReasoningParams.maxOutputTokens(capped, 20000, DEFAULT)).isEqualTo(8192);
        assertThat(AiReasoningParams.timeoutSeconds(zhipu, DEFAULT)).isEqualTo(120);
        assertThat(AiReasoningParams.timeoutSeconds(zhipu, OFF)).isEqualTo(60);
        assertThat(AiReasoningParams.timeoutSeconds(zhipu, MEDIUM)).isEqualTo(120);
        assertThat(AiReasoningParams.timeoutSeconds(zhipu, HIGH)).isEqualTo(180);
        assertThat(AiReasoningParams.describe(zhipu, HIGH)).isEqualTo("output_config.effort=max");
        // Unsupported provider: nothing changes and nothing is sent.
        var none = runtime(AiProtocol.OPENAI_CHAT, AiThinkingControl.NONE, 120);
        assertThat(AiReasoningParams.adjustable(none, HIGH)).isFalse();
        assertThat(AiReasoningParams.maxOutputTokens(none, 8192, HIGH)).isEqualTo(8192);
        assertThat(AiReasoningParams.timeoutSeconds(none, OFF)).isEqualTo(120);
        assertThat(AiReasoningParams.describe(none, HIGH)).isEqualTo("none");
    }

    /** GPT-5 reasoning models reject temperature unless reasoning_effort is none. */
    @Test void temperatureIsOnlySentWhereTheThinkingLevelAllowsIt() throws Exception {
        var client = new OpenAiChatClient(new AiHttpTransport(new AiProperties()));
        var openAi = runtime(AiProtocol.OPENAI_CHAT, AiThinkingControl.OPENAI_REASONING, "gpt-5.6-luna", true, 32768, 30);
        for (var level : List.of(LOW, MEDIUM, HIGH)) {
            fake.enqueue(FakeAiProviderServer.openAiContent("{}"));
            client.chat(openAi, new AiProtocolClient.ChatRequest("s", List.of(new AiText("x", false)), null, null, 64, level));
            JsonNode body = json.readTree(fake.lastChatRequest().body());
            assertThat(body.has("temperature")).as(level.name()).isFalse();
            assertThat(body.path("reasoning_effort").asText()).isNotEqualTo("none");
        }
        for (var level : List.of(DEFAULT, OFF)) {
            fake.enqueue(FakeAiProviderServer.openAiContent("{}"));
            client.chat(openAi, new AiProtocolClient.ChatRequest("s", List.of(new AiText("x", false)), null, null, 64, level));
            JsonNode body = json.readTree(fake.lastChatRequest().body());
            assertThat(body.path("temperature").asInt(-1)).as(level.name()).isZero();
            assertThat(body.path("reasoning_effort").asText()).isEqualTo("none");
        }
        // DeepSeek ignores temperature while thinking; other dialects follow the admin switch.
        var deepseek = runtime(AiProtocol.OPENAI_CHAT, AiThinkingControl.DEEPSEEK, "m", true, 32768, 30);
        assertThat(AiReasoningParams.allowsTemperature(deepseek, HIGH)).isFalse();
        assertThat(AiReasoningParams.allowsTemperature(deepseek, OFF)).isTrue();
        assertThat(AiReasoningParams.allowsTemperature(runtime(AiProtocol.OPENAI_CHAT, AiThinkingControl.ZHIPU, "m", true, 32768, 30), HIGH)).isTrue();
    }

    @Test void clientsWriteTheMappedParametersIntoTheRequestBody() throws Exception {
        var openAi = new OpenAiChatClient(new AiHttpTransport(new AiProperties()));
        var request = new AiProtocolClient.ChatRequest("s", List.of(new AiText("x", false)), null, null, 64, HIGH);
        fake.enqueue(FakeAiProviderServer.openAiContent("{}"));
        openAi.chat(runtime(AiProtocol.OPENAI_CHAT, AiThinkingControl.ZHIPU, 30), request);
        JsonNode body = json.readTree(fake.lastChatRequest().body());
        assertThat(body.path("thinking").path("type").asText()).isEqualTo("enabled");
        assertThat(body.path("reasoning_effort").asText()).isEqualTo("max");

        fake.enqueue(FakeAiProviderServer.openAiContent("{}"));
        openAi.chat(runtime(AiProtocol.OPENAI_CHAT, AiThinkingControl.DASHSCOPE, 30), request);
        body = json.readTree(fake.lastChatRequest().body());
        assertThat(body.path("enable_thinking").asBoolean(true)).isFalse();
        assertThat(body.has("thinking_budget")).isFalse();

        var anthropic = new AnthropicMessagesClient(new AiHttpTransport(new AiProperties()));
        fake.enqueue(FakeAiProviderServer.anthropicContent("{}"));
        var withSchema = new AiProtocolClient.ChatRequest("s", List.of(new AiText("x", false)), "r",
                Map.of("type", "object"), 64, MEDIUM);
        var claude = new AiProviderRuntime(UUID.randomUUID(), "c", AiProviderPreset.CUSTOM, AiRegion.LOCAL,
                AiProtocol.ANTHROPIC_MESSAGES, AiEndpointPolicy.parse(fake.anthropicBaseUrl()), "claude-sonnet-5", null,
                AiJsonMode.JSON_SCHEMA, AiThinkingControl.ANTHROPIC_EFFORT, false, false, 8192, 30);
        anthropic.chat(claude, withSchema);
        body = json.readTree(fake.lastChatRequest().body());
        assertThat(body.path("output_config").path("effort").asText()).isEqualTo("medium");
        assertThat(body.path("output_config").path("format").path("type").asText()).isEqualTo("json_schema");
        assertThat(body.has("thinking")).as("budget_tokens is never sent").isFalse();

        fake.enqueue(FakeAiProviderServer.anthropicContent("{}"));
        var haiku = new AiProviderRuntime(UUID.randomUUID(), "c", AiProviderPreset.ANTHROPIC, AiRegion.LOCAL,
                AiProtocol.ANTHROPIC_MESSAGES, AiEndpointPolicy.parse(fake.anthropicBaseUrl()), "claude-haiku-4-5-20251001", null,
                AiJsonMode.JSON_SCHEMA, AiThinkingControl.ANTHROPIC_EFFORT, false, false, 8192, 30);
        anthropic.chat(haiku, withSchema);
        body = json.readTree(fake.lastChatRequest().body());
        assertThat(body.path("output_config").has("effort")).as("Haiku 4.5 rejects effort").isFalse();

        fake.enqueue(FakeAiProviderServer.anthropicContent("{}"));
        anthropic.chat(runtime(AiProtocol.ANTHROPIC_MESSAGES, AiThinkingControl.ZHIPU, 30),
                new AiProtocolClient.ChatRequest("s", List.of(new AiText("x", false)), null, null, 64));
        body = json.readTree(fake.lastChatRequest().body());
        assertThat(body.has("output_config")).as("DEFAULT keeps the earlier body").isFalse();
    }
}
