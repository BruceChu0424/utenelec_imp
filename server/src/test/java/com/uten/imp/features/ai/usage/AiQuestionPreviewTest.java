package com.uten.imp.features.ai.usage;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiJobHandler;
import org.junit.jupiter.api.Test;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class AiQuestionPreviewTest {
    private final ObjectMapper json = new ObjectMapper();
    private AiJobHandler.AiJobInput input(String kind, byte[] bytes) {
        return new AiJobHandler.AiJobInput("source", "application/octet-stream", kind, bytes.length, bytes, "0".repeat(64));
    }
    @Test void capturesOnlyUserQuestionAndRedactsLabelledAndUnlabelledCredentials() throws Exception {
        String question = "查A001成本 api_key=private-value {\"password\":\"two word password\"} 密码是secret123 Bearer bearercredential123 sk-example-private-123";
        byte[] bytes = json.writeValueAsBytes(Map.of("request", Map.of("message", question), "systemPrompt", "do-not-log-this-system-prompt"));
        var result = AiQuestionPreview.capture("ERP_CHAT", Map.of(), input("JSON", bytes), json);
        assertThat(result.state()).isEqualTo("REDACTED");
        assertThat(result.question()).contains("查A001成本", "[已隐藏]").doesNotContain("private-value", "two word password", "secret123", "bearercredential123", "sk-example", "do-not-log");
    }
    @Test void documentBytesNeverBecomeAuditQuestions() {
        var result = AiQuestionPreview.capture("ERP_DOCUMENT_ROUTE", Map.of("message", "生成报价单"),
                input("CSV", "工资秘密,password=secret".getBytes(StandardCharsets.UTF_8)), json);
        assertThat(result.question()).isEqualTo("生成报价单");
        assertThat(result.state()).isEqualTo("CAPTURED");
        assertThat(AiQuestionPreview.capture("SALES_DOCUMENT_INTAKE", Map.of(), input("CSV", new byte[]{1,2,3}), json).question()).isNull();
    }
    @Test void shortCredentialsAfterChineseEnglishAndQuotedLabelsAreRedacted() throws Exception {
        for (String question : java.util.List.of("我的密码是ABC123", "password is secret", "{\"password\":\"xxx\"}")) {
            var result = AiQuestionPreview.capture("ERP_CHAT", Map.of(), input("JSON",
                    json.writeValueAsBytes(Map.of("request", Map.of("message", question)))), json);
            assertThat(result.state()).isEqualTo("REDACTED");
            assertThat(result.question()).contains("[已隐藏]").doesNotContain("ABC123", "secret", "xxx");
        }
    }
    @Test void boundsQuestionsAndDoesNotReadOtherEnvelopeFields() throws Exception {
        var result = AiQuestionPreview.capture("ERP_CHAT", Map.of(), input("JSON", json.writeValueAsBytes(
                Map.of("request", Map.of("message", "货".repeat(2001)), "reply", "secret-result"))), json);
        assertThat(result.question()).hasSize(2000).doesNotContain("secret-result");
        assertThat(AiQuestionPreview.capture("ERP_CHAT", Map.of(), input("JSON", "{}".getBytes(StandardCharsets.UTF_8)), json).state()).isEqualTo("UNAVAILABLE");
    }
}
