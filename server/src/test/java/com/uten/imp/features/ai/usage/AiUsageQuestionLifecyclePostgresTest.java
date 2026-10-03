package com.uten.imp.features.ai.usage;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.features.ai.AiPlatformPostgresTestSupport;
import com.uten.imp.features.ai.support.FakeAiProviderServer;
import org.junit.jupiter.api.Test;
import java.time.Duration;
import java.util.Map;
import java.util.List;
import static org.assertj.core.api.Assertions.*;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;

/** Accepted question metadata survives both local completion and a failed provider call. */
class AiUsageQuestionLifecyclePostgresTest extends AiPlatformPostgresTestSupport {
    @Test void localAndFailedQuestionsRemainBoundToTheirEmployeeAfterTemporaryInputIsReleased() throws Exception {
        Staff staff = aiUser();
        String token = login(staff.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
        String admin = adminToken();
        jdbc.update("DELETE FROM ai_providers");
        String local = submit(token, "你好");
        assertThat(terminal(token, local).path("status").asText()).isEqualTo("SUCCEEDED");
        String redacted = submit(token, "查我的工作台 api_key=private-question-credential");
        assertThat(terminal(token, redacted).path("status").asText()).isEqualTo("SUCCEEDED");
        assertThat(jdbc.queryForObject("SELECT audit_question FROM ai_jobs WHERE id=?::uuid", String.class, redacted))
                .contains("[已隐藏]").doesNotContain("private-question-credential");
        assertThat(jdbc.queryForObject("SELECT audit_question_state FROM ai_jobs WHERE id=?::uuid", String.class, redacted)).isEqualTo("REDACTED");

        resetToFakeDefaultProvider(admin);
        FAKE.defaultResponse(FakeAiProviderServer.openAiContent("invalid-json", 5, 2, "stop"));
        String failedQuestion = "请查询 A001 的库存数量";
        String failed = submit(token, failedQuestion);
        assertThat(terminal(token, failed).path("status").asText()).isEqualTo("FAILED");
        var persisted = jdbc.queryForMap("SELECT input_bytes IS NULL AS released,audit_question,submitted_by_user::text AS actor,submitted_by_employee::text AS employee FROM ai_jobs WHERE id=?::uuid", failed);
        assertThat(persisted.get("released")).isEqualTo(true);
        assertThat(persisted.get("audit_question")).isEqualTo(failedQuestion);
        assertThat(persisted.get("actor")).isEqualTo(staff.userId());
        assertThat(persisted.get("employee")).isEqualTo(staff.employeeId());

        var result = mvc.perform(authed(get("/api/admin/ai/usage-audit").param("userId", staff.userId()), adminToken())).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        JsonNode audit = json(result);
        assertThat(audit.path("summary").path("uses").asLong()).isEqualTo(3);
        assertThat(audit.path("summary").path("calls").asLong()).isEqualTo(2);
        assertThat(audit.path("summary").path("localUses").asLong()).isEqualTo(2);
        assertThat(audit.toString()).contains("你好", "[已隐藏]", failedQuestion).doesNotContain("private-question-credential", "input_bytes", "systemPrompt");
        var denied = mvc.perform(authed(get("/api/admin/ai/usage-audit").param("userId", staff.userId()), token)).andReturn();
        assertEquals(403, denied.getResponse().getStatus(), body(denied));
    }
    private String submit(String token, String message) throws Exception {
        var response = mvc.perform(json(post("/api/ai/chat/messages"), Map.of("message", message), token)).andReturn();
        assertEquals(202, response.getResponse().getStatus(), body(response));
        return json(response).path("jobId").asText();
    }
    private JsonNode terminal(String token, String id) throws Exception {
        long until = System.nanoTime() + Duration.ofSeconds(45).toNanos();
        while (System.nanoTime() < until) {
            JsonNode job = getJson("/api/ai/jobs/" + id, token);
            if (List.of("SUCCEEDED", "FAILED", "CANCELLED").contains(job.path("status").asText())) return job;
            Thread.sleep(100);
        }
        throw new AssertionError("AI worker did not finish");
    }
}
