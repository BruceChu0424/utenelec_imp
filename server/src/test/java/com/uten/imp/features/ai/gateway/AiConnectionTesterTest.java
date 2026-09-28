package com.uten.imp.features.ai.gateway;

import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.features.ai.client.AiHttpTransport;
import com.uten.imp.features.ai.client.AnthropicMessagesClient;
import com.uten.imp.features.ai.client.OpenAiChatClient;
import com.uten.imp.features.ai.provider.AiJsonMode;
import com.uten.imp.features.ai.provider.AiProviderDtos;
import com.uten.imp.features.ai.provider.AiProviderRuntime;
import com.uten.imp.features.ai.provider.AiProviderService;
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
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** 「测试连接」四步: 网络连通 / 密钥验证 / 模型可用 / JSON 输出。 */
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

    @Test
    void allFourStepsPassAndThePingIsLoggedAsAConnectionTest() {
        fake.models(List.of("fake-model"));

        AiProviderDtos.TestResult result = tester.test(AiTestRuntimes.openAi(fake, KEY));

        assertThat(result.ok()).isTrue();
        assertThat(result.summary()).isEqualTo("连接成功");
        assertThat(statuses(result)).containsExactly("NETWORK:OK", "AUTH:OK", "MODEL:OK", "JSON:OK");
        assertThat(result.steps()).allSatisfy(step -> assertThat(step.latencyMs()).isNotNull());
        assertThat(fake.lastChatRequest().body()).contains("Reply in JSON").contains("\"max_tokens\":64")
                .contains("\"thinking\":{\"type\":\"disabled\"}");
        ArgumentCaptor<AiCallLogService.CallRecord> record = ArgumentCaptor.forClass(AiCallLogService.CallRecord.class);
        verify(callLogs).record(record.capture());
        assertThat(record.getValue().purpose()).isEqualTo("CONNECTION_TEST");
    }

    @Test
    void missingModelListIsToleratedAndTheChatConfirmsTheKey() {
        fake.modelsStatus(404);

        AiProviderDtos.TestResult result = tester.test(AiTestRuntimes.openAi(fake, KEY));

        assertThat(result.ok()).isTrue();
        assertThat(statuses(result)).containsExactly("NETWORK:OK", "AUTH:OK", "MODEL:OK", "JSON:OK");
    }

    @Test
    void modelAbsentFromTheListOnlyWarnsUntilTheChatSucceeds() {
        fake.models(List.of("another-model"));

        AiProviderDtos.TestResult result = tester.test(AiTestRuntimes.openAi(fake, KEY));

        assertThat(result.ok()).isTrue();
        assertThat(statuses(result)).containsExactly("NETWORK:OK", "AUTH:OK", "MODEL:OK", "JSON:OK");

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
        assertThat(statuses(result)).containsExactly("NETWORK:OK", "AUTH:OK", "MODEL:OK", "JSON:FAILED");
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
