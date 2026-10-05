package com.uten.imp.features.ai.gateway;

import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.features.ai.client.AiHttpTransport;
import com.uten.imp.features.ai.client.AnthropicMessagesClient;
import com.uten.imp.features.ai.client.OpenAiChatClient;
import com.uten.imp.features.ai.provider.AiJsonMode;
import com.uten.imp.features.ai.provider.AiProviderDtos;
import com.uten.imp.features.ai.provider.AiProviderRuntime;
import com.uten.imp.features.ai.provider.AiProviderService;
import com.uten.imp.features.ai.provider.AiThinkingControl;
import com.uten.imp.features.ai.support.AiTestRuntimes;
import com.uten.imp.features.ai.support.FakeAiProviderServer;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.time.Clock;
import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 「测试连接」: 网络连通 / 密钥验证 / 模型可用 / JSON 输出, 配置能调整思考程度时再加「思考程度」一步
 * (ADR-152: 按 AI 对话默认档带思考参数实测, 服务商拒绝就判失败)。
 */
class AiConnectionTesterTest {

    private static final String KEY = "sk-tester-0123456789abcdefghijklm";
    private static FakeAiProviderServer fake;
    private AiCallLogService callLogs;
    private AiConnectionTester tester;

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
        callLogs = mock(AiCallLogService.class);
        AiProperties properties = new AiProperties();
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.id()).thenReturn(Optional.empty());
        AiHttpTransport transport = new AiHttpTransport(properties);
        AiGateway gateway = new AiGateway(mock(AiProviderService.class),
                List.of(new OpenAiChatClient(transport), new AnthropicMessagesClient(transport)), callLogs,
                properties, currentUser);
        tester = new AiConnectionTester(gateway, Clock.systemUTC());
    }

    private static List<String> statuses(AiProviderDtos.TestResult result) {
        return result.steps().stream().map(step -> step.key() + ":" + step.status()).toList();
    }

    private List<String> chatBodies() {
        return fake.requests().stream().filter(request -> request.path().endsWith("/chat/completions")
                || request.path().endsWith("/messages")).map(FakeAiProviderServer.RecordedRequest::body).toList();
    }

    @Test
    void allStepsPassAndBothPingsAreLoggedAsConnectionTests() {
        fake.models(List.of("fake-model"));

        AiProviderDtos.TestResult result = tester.test(AiTestRuntimes.openAi(fake, KEY));

        assertThat(result.ok()).isTrue();
        assertThat(result.summary()).isEqualTo("连接成功");
        assertThat(statuses(result)).containsExactly("NETWORK:OK", "AUTH:OK", "MODEL:OK", "JSON:OK", "THINKING:OK");
        assertThat(result.steps()).allSatisfy(step -> assertThat(step.latencyMs()).isNotNull());
        List<String> bodies = chatBodies();
        assertThat(bodies).hasSize(2);
        assertThat(bodies.get(0)).contains("Reply in JSON").contains("\"max_tokens\":512")
                .contains("\"thinking\":{\"type\":\"disabled\"}");
        // The thinking ping uses the chat default (标准) exactly as a chat question would send it.
        assertThat(bodies.get(1)).contains("\"thinking\":{\"type\":\"enabled\"}").contains("\"reasoning_effort\":\"high\"")
                .doesNotContain("\"temperature\"");
        ArgumentCaptor<AiCallLogService.CallRecord> record = ArgumentCaptor.forClass(AiCallLogService.CallRecord.class);
        verify(callLogs, times(2)).record(record.capture());
        assertThat(record.getAllValues()).allSatisfy(value -> assertThat(value.purpose()).isEqualTo("CONNECTION_TEST"));
    }

    @Test
    void aModelThatRejectsTheThinkingParametersFailsTheThinkingStepWithAdvice() {
        fake.models(List.of("fake-model"));
        fake.enqueue(FakeAiProviderServer.openAiContent("{\"ok\": true}"),
                FakeAiProviderServer.openAiError(400, "reasoning_effort is not supported with this model"));

        AiProviderDtos.TestResult result = tester.test(AiTestRuntimes.openAi(fake, KEY));

        assertThat(result.ok()).isFalse();
        assertThat(statuses(result)).containsExactly("NETWORK:OK", "AUTH:OK", "MODEL:OK", "JSON:OK", "THINKING:FAILED");
        assertThat(result.summary()).contains("不接受思考程度参数").contains("不发送");

        // A provider that cannot adjust thinking (or a model known to reject it) is not probed at all.
        fake.reset();
        fake.models(List.of("fake-model"));
        AiProviderDtos.TestResult none = tester.test(AiTestRuntimes.openAi(fake, KEY, AiJsonMode.JSON_OBJECT,
                AiThinkingControl.DASHSCOPE, true, 30));
        assertThat(statuses(none)).containsExactly("NETWORK:OK", "AUTH:OK", "MODEL:OK", "JSON:OK");
        assertThat(chatBodies()).singleElement().asString().contains("\"enable_thinking\":false");
    }

    @Test
    void anUnfinishedThinkingProbeOnlyWarns() {
        fake.models(List.of("fake-model"));
        fake.enqueue(FakeAiProviderServer.openAiContent("{\"ok\": true}"),
                FakeAiProviderServer.openAiError(429, "rate limited"));

        AiProviderDtos.TestResult result = tester.test(AiTestRuntimes.openAi(fake, KEY));

        assertThat(result.ok()).isTrue();
        assertThat(statuses(result)).containsExactly("NETWORK:OK", "AUTH:OK", "MODEL:OK", "JSON:OK", "THINKING:WARN");
    }

    @Test
    void missingModelListIsToleratedAndTheChatConfirmsTheKey() {
        fake.modelsStatus(404);

        AiProviderDtos.TestResult result = tester.test(AiTestRuntimes.openAi(fake, KEY));

        assertThat(result.ok()).isTrue();
        assertThat(statuses(result)).containsExactly("NETWORK:OK", "AUTH:OK", "MODEL:OK", "JSON:OK", "THINKING:OK");
    }

    @Test
    void modelAbsentFromTheListOnlyWarnsUntilTheChatSucceeds() {
        fake.models(List.of("another-model"));

        AiProviderDtos.TestResult result = tester.test(AiTestRuntimes.openAi(fake, KEY));

        assertThat(result.ok()).isTrue();
        assertThat(statuses(result)).containsExactly("NETWORK:OK", "AUTH:OK", "MODEL:OK", "JSON:OK", "THINKING:OK");

        fake.reset();
        fake.models(List.of("another-model"));
        fake.enqueue(FakeAiProviderServer.openAiError(404, "The model does not exist"));
        AiProviderDtos.TestResult failed = tester.test(AiTestRuntimes.openAi(fake, KEY));
        assertThat(failed.ok()).isFalse();
        assertThat(statuses(failed)).containsExactly("NETWORK:OK", "AUTH:OK", "MODEL:FAILED");
        assertThat(failed.summary()).contains("接口地址或模型名称不对");
    }

    @Test
    void wrongKeyStopsAtTheAuthStepWithPlainAdvice() {
        fake.modelsStatus(401);

        AiProviderDtos.TestResult result = tester.test(AiTestRuntimes.openAi(fake, KEY));

        assertThat(result.ok()).isFalse();
        assertThat(statuses(result)).containsExactly("NETWORK:OK", "AUTH:FAILED");
        assertThat(result.summary()).contains("密钥无效").contains("重新复制密钥");
        assertThat(fake.chatRequestCount()).isZero();
    }

    @Test
    void nonJsonReplyFailsOnlyTheJsonStep() {
        fake.enqueue(FakeAiProviderServer.openAiContent("OK! Everything works."));

        AiProviderDtos.TestResult result = tester.test(AiTestRuntimes.openAi(fake, KEY));

        assertThat(result.ok()).isFalse();
        assertThat(statuses(result)).containsExactly("NETWORK:OK", "AUTH:OK", "MODEL:OK", "JSON:FAILED", "THINKING:OK");
        assertThat(result.summary()).contains("JSON");
    }

    @Test
    void unreachableHostFailsTheNetworkStep() {
        FakeAiProviderServer gone = FakeAiProviderServer.start();
        AiProviderRuntime runtime = AiTestRuntimes.openAi(gone, KEY);
        gone.close();

        AiProviderDtos.TestResult result = tester.test(runtime);

        assertThat(result.ok()).isFalse();
        assertThat(statuses(result)).containsExactly("NETWORK:FAILED");
    }

    @Test
    void anthropicProtocolIsTestedTheSameWay() {
        fake.models(List.of("fake-claude"));

        AiProviderDtos.TestResult result = tester.test(AiTestRuntimes.anthropic(fake, KEY, AiJsonMode.JSON_OBJECT,
                false));

        assertThat(result.ok()).isTrue();
        assertThat(fake.lastChatRequest().path()).isEqualTo("/anthropic/v1/messages");
    }

    @Test
    void modelListExplainsWhenUnavailable() {
        fake.models(List.of("b-model", "a-model"));
        assertThat(tester.models(AiTestRuntimes.openAi(fake, KEY)).models()).containsExactly("a-model", "b-model");

        fake.modelsStatus(404);
        AiProviderDtos.ModelsResult missing = tester.models(AiTestRuntimes.openAi(fake, KEY));
        assertThat(missing.models()).isEmpty();
        assertThat(missing.message()).contains("手动填写");
    }
}
