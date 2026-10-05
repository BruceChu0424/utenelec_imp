package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiCompletionPort;
import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.features.ai.client.AiHttpTransport;
import com.uten.imp.features.ai.client.AnthropicMessagesClient;
import com.uten.imp.features.ai.client.OpenAiChatClient;
import com.uten.imp.features.ai.gateway.AiCallLogService;
import com.uten.imp.features.ai.gateway.AiGateway;
import com.uten.imp.features.ai.provider.AiJsonMode;
import com.uten.imp.features.ai.provider.AiProviderRuntime;
import com.uten.imp.features.ai.provider.AiProviderPreset;
import com.uten.imp.features.ai.provider.AiProviderService;
import com.uten.imp.features.ai.provider.AiThinkingControl;
import com.uten.imp.features.ai.support.AiTestRuntimes;
import com.uten.imp.features.ai.support.FakeAiProviderServer;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/** Real loopback HTTP and both protocol adapters; no credentials, database or outbound provider. */
class AiChatAnswerContractHttpTest {
    private final ObjectMapper json = new ObjectMapper();
    private final AiProviderService providers = mock(AiProviderService.class);
    private final AiCallLogService logs = mock(AiCallLogService.class);
    private FakeAiProviderServer fake;
    private AiGateway gateway;
    private AiChatAnswerContract contract;

    @BeforeEach void setUp() {
        fake = FakeAiProviderServer.start();
        AiProperties properties = new AiProperties();
        AiHttpTransport transport = new AiHttpTransport(properties);
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        when(current.id()).thenReturn(Optional.empty());
        when(logs.captureResetGeneration()).thenReturn(1L);
        gateway = new AiGateway(providers, List.of(new OpenAiChatClient(transport), new AnthropicMessagesClient(transport)), logs, properties, current);
        // Source texts never enter the schema: only issued ids, intents and the page's closed action shapes.
        contract = AiChatAnswerContract.create(List.of(), List.of("guide.sales_quote", "knowledge.SALES_ORDER", "page.tables"),
                true, true, true, List.of(new AiChatPageSnapshot.PageAction("setLineField", "改行字段", "FORM", "LOW",
                        Map.of("type", "object", "additionalProperties", false,
                                "properties", Map.of("row", Map.of("type", "integer", "title", "行号", "minimum", 1),
                                        "value", Map.of("type", "string", "title", "新值", "maxLength", 80)),
                                "required", List.of("row", "value")))));
    }
    @AfterEach void close() { fake.close(); }

    @Test void openAiReallyReceivesStrictSchemaAndKeepsTheAdministratorTokenLimit() throws Exception {
        AiProviderRuntime base = AiTestRuntimes.openAi(fake, null, AiJsonMode.JSON_SCHEMA, AiThinkingControl.NONE, false, 30);
        use(new AiProviderRuntime(base.id(), base.name(), AiProviderPreset.OPENAI, base.region(), base.protocol(), base.endpoint(), base.model(),
                null, base.jsonMode(), AiThinkingControl.OPENAI_REASONING, false, false, 320, base.timeoutSeconds()));
        fake.enqueue(FakeAiProviderServer.openAiContent(contract.exampleJson()));
        assertThat(gateway.completeJson(request(8192)).json()).isEqualTo(contract.exampleJson());
        JsonNode sent = json.readTree(fake.lastChatRequest().body());
        assertThat(sent.path("response_format").path("type").asText()).isEqualTo("json_schema");
        assertThat(sent.path("response_format").path("json_schema").path("strict").asBoolean()).isTrue();
        assertThat(sent.path("response_format").path("json_schema").path("schema")).isEqualTo(json.valueToTree(contract.schema()));
        assertThat(sent.path("max_completion_tokens").asInt()).isEqualTo(320);
        assertThat(sent.has("max_tokens")).isFalse();
        assertThat(fake.lastChatRequest().header("Authorization")).isNull();
        assertNoBusinessReplyWasSent();
        assertThat(fake.chatRequestCount()).isEqualTo(1);
    }

    @Test void anthropicReallyReceivesTheSameClosedSchema() throws Exception {
        use(AiTestRuntimes.anthropic(fake, null, AiJsonMode.JSON_SCHEMA, false));
        fake.enqueue(FakeAiProviderServer.anthropicContent(contract.exampleJson()));
        assertThat(gateway.completeJson(request(8192)).json()).isEqualTo(contract.exampleJson());
        JsonNode sent = json.readTree(fake.lastChatRequest().body());
        assertThat(sent.path("output_config").path("format").path("type").asText()).isEqualTo("json_schema");
        assertThat(sent.path("output_config").path("format").path("schema")).isEqualTo(json.valueToTree(contract.schema()));
        assertThat(sent.path("max_tokens").asInt()).isEqualTo(4096);
        assertThat(fake.lastChatRequest().header("x-api-key")).isNull();
        assertNoBusinessReplyWasSent();
        assertThat(fake.chatRequestCount()).isEqualTo(1);
    }

    @Test void oldTwelveHundredTokenTruncationIsReproducedAcrossTheRealProtocolAndGateway() throws Exception {
        use(AiTestRuntimes.openAi(fake, null));
        fake.enqueue(FakeAiProviderServer.openAiContent("{\"intent\":\"PAGE_HELP\",\"tool\":", 300, 1200, "length"),
                FakeAiProviderServer.openAiContent("{\"intent\":\"PAGE_HELP\",\"tool\":", 300, 1200, "length"));
        assertThatThrownBy(() -> gateway.completeJson(request(1200))).isInstanceOf(AiCompletionPort.AiCallException.class)
                .hasMessageContaining("最大输出长度");
        assertInvalidAttempts();
        for (var exchange : fake.requests()) assertThat(json.readTree(exchange.body()).path("max_tokens").asInt()).isEqualTo(1200);
    }

    @Test void emptyFinalContentIsInvalidRatherThanAUserQuestionError() {
        use(AiTestRuntimes.openAi(fake, null));
        fake.enqueue(FakeAiProviderServer.openAiContent(null), FakeAiProviderServer.openAiContent("   "));
        assertThatThrownBy(() -> gateway.completeJson(request(8192))).isInstanceOf(AiCompletionPort.AiCallException.class)
                .hasMessageContaining("没有返回内容");
        assertInvalidAttempts();
    }

    @Test void anthropicNaturalLanguageWithoutRoutingJsonIsRejectedAtTheGateway() {
        use(AiTestRuntimes.anthropic(fake, null, AiJsonMode.JSON_SCHEMA, false));
        fake.enqueue(FakeAiProviderServer.anthropicContent("请先填写客户，再核对数量。"),
                FakeAiProviderServer.anthropicContent("这是一张销售报价单。"));
        assertThatThrownBy(() -> gateway.completeJson(request(8192))).isInstanceOf(AiCompletionPort.AiCallException.class)
                .hasMessageContaining("JSON");
        assertInvalidAttempts();
    }

    @Test void hiddenReasoningJsonNeverSubstitutesForMissingFinalContent() {
        use(AiTestRuntimes.openAi(fake, null));
        String response = "{\"choices\":[{\"message\":{\"content\":null,\"reasoning_content\":\"{\\\"intent\\\":\\\"TOOL\\\"}\"},"
                + "\"finish_reason\":\"length\"}],\"usage\":{\"completion_tokens\":1200}}";
        fake.enqueue(FakeAiProviderServer.json(200, response), FakeAiProviderServer.json(200, response));
        assertThatThrownBy(() -> gateway.completeJson(request(1200))).isInstanceOf(AiCompletionPort.AiCallException.class);
        assertInvalidAttempts();
    }

    private void use(AiProviderRuntime runtime) {
        when(providers.resolveDefault()).thenReturn(new AiProviderService.Resolution(runtime, runtime.name(), runtime.model(), runtime.supportsVision(), null));
    }
    private AiCompletionPort.AiCompletionRequest request(int limit) {
        return new AiCompletionPort.AiCompletionRequest("ERP_CHAT_ANSWER", "Answer from the sources. Example JSON: " + contract.exampleJson(),
                List.of(new AiCompletionPort.AiText("这个页面怎么填写？请举个例子。", true)), contract.schemaName(), contract.schema(), limit, null);
    }
    private void assertNoBusinessReplyWasSent() {
        assertThat(fake.lastChatRequest().body()).doesNotContain("PRIVATE_SALES_REPLY", "PRIVATE_FIELD_FACT", "PRIVATE_EXAMPLE");
    }
    private void assertInvalidAttempts() {
        assertThat(fake.chatRequestCount()).isEqualTo(2);
        ArgumentCaptor<AiCallLogService.CallRecord> records = ArgumentCaptor.forClass(AiCallLogService.CallRecord.class);
        verify(logs, times(2)).record(records.capture());
        assertThat(records.getAllValues()).allSatisfy(record -> {
            assertThat(record.ok()).isFalse(); assertThat(record.errorCategory()).isEqualTo("INVALID_RESPONSE");
            assertThat(record.httpStatus()).isEqualTo(200);
        });
    }
}
