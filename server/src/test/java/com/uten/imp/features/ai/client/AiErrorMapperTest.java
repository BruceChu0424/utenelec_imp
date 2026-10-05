package com.uten.imp.features.ai.client;

import com.uten.imp.application.port.AiCompletionPort.AiCallException;
import com.uten.imp.application.port.AiCompletionPort.AiErrorCategory;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-153 revision: a provider's content review is told apart from configuration or protocol errors, so the chat
 * answers it as "this question cannot be handled" instead of "the service is unavailable, contact the administrator".
 * The call log still records it as BAD_REQUEST.
 */
class AiErrorMapperTest {

    private static byte[] body(String json) {
        return json.getBytes(StandardCharsets.UTF_8);
    }

    @Test void providerContentReviewIsRecognised() {
        for (String json : java.util.List.of(
                "{\"error\":{\"code\":\"1301\",\"message\":\"系统检测到输入或生成内容可能包含不安全或敏感内容，请您避免输入易产生敏感内容的提示语\"}}",
                "{\"error\":{\"code\":\"data_inspection_failed\",\"message\":\"Input data may contain inappropriate content.\"}}",
                "{\"error\":{\"message\":\"Content Exists Risk\",\"type\":\"invalid_request_error\"}}",
                "{\"error\":{\"code\":\"content_policy_violation\",\"message\":\"Your request was rejected by our safety system\"}}")) {
            AiCallException failure = AiErrorMapper.fromStatus(400, body(json), "sk-test");
            assertThat(failure.isContentFiltered()).as(json).isTrue();
            assertThat(failure.category()).isEqualTo(AiErrorCategory.BAD_REQUEST);
            assertThat(failure.getMessage()).isEqualTo(AiCallException.CONTENT_FILTERED_MESSAGE);
        }
    }

    @Test void otherBadRequestsStayConfigurationErrors() {
        AiCallException failure = AiErrorMapper.fromStatus(400,
                body("{\"error\":{\"code\":\"1210\",\"message\":\"API 调用参数有误，请检查文档\"}}"), "sk-test");
        assertThat(failure.isContentFiltered()).isFalse();
        assertThat(failure.getMessage()).startsWith("服务商不接受这个请求");
        assertThat(AiErrorMapper.fromStatus(500, body("{\"error\":{\"message\":\"敏感内容\"}}"), "k").isContentFiltered()).isFalse();
    }
}
