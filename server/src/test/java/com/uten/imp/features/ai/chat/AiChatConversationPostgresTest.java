package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.features.ai.AiPlatformPostgresTestSupport;
import com.uten.imp.features.ai.support.FakeAiProviderServer;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/**
 * ADR-152 on a disposable PostgreSQL with the full JWT/filter chain, the real worker and a fake provider:
 * per-account settings (whitelisted, stored with the account, reserved from the generic preference endpoint),
 * conversation memory across pages (owner-only, bounded by the setting, sensitive answers withheld,
 * identity change and clearing stop it) and the thinking-depth parameter reaching the provider.
 */
class AiChatConversationPostgresTest extends AiPlatformPostgresTestSupport {
    // ADR-153: a KNOWLEDGE reply must cite an issued knowledge source; these memory replies cite none.
    private static final String REPLY = """
            {"intent":"UNSUPPORTED","reply":"%s","usedSources":[],"tool":"","arguments":{},"action":{"name":"","args":{}}}""";
    private String admin;

    @BeforeEach void providerAndDepartment() throws Exception {
        jdbc.update("""
                INSERT INTO department_permissions(department_id,permission_id)
                SELECT d.id,p.id FROM departments d CROSS JOIN permissions p
                WHERE d.code='DEPT_PROD' AND p.code IN ('ai:use','production_execution:view')
                ON CONFLICT DO NOTHING
                """);
        admin = adminToken();
        resetToFakeDefaultProvider(admin);
        FAKE.reset();
    }

    private Staff staff() throws Exception {
        return newEmployee(adminToken(), "WS_ZHUSU");
    }

    private String tokenOf(Staff staff) throws Exception {
        return login(staff.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
    }

    private String staffToken() throws Exception {
        return tokenOf(staff());
    }

    private String submit(String token, Map<String, Object> request) throws Exception {
        MvcResult response = mvc.perform(json(post("/api/ai/chat/messages"), request, token)).andReturn();
        assertEquals(202, response.getResponse().getStatus(), body(response));
        return json(response).path("jobId").asText();
    }

    private JsonNode await(String token, String id) throws Exception {
        long until = System.nanoTime() + Duration.ofSeconds(40).toNanos();
        JsonNode view = null;
        while (System.nanoTime() < until) {
            view = getJson("/api/ai/jobs/" + id, token);
            if ("SUCCEEDED".equals(view.path("status").asText())) return view.path("result");
            if ("FAILED".equals(view.path("status").asText())) throw new AssertionError(view.toString());
            Thread.sleep(100);
        }
        throw new AssertionError("Chat did not finish: " + view);
    }

    private JsonNode ask(String token, String conversation, String message, String answer) throws Exception {
        FAKE.defaultResponse(FakeAiProviderServer.openAiContent(REPLY.formatted(answer)));
        return await(token, submit(token, Map.of("message", message, "conversationId", conversation, "locale", "zh")));
    }

    private JsonNode settings(String token, Object change, int status) throws Exception {
        MvcResult response = mvc.perform(json(patch("/api/ai/chat/settings"), change, token)).andReturn();
        assertEquals(status, response.getResponse().getStatus(), body(response));
        return json(response);
    }

    @Test void settingsAreWhitelistedStoredWithTheAccountAndNotWritableThroughGenericPreferences() throws Exception {
        String token = staffToken();
        JsonNode capabilities = getJson("/api/ai/chat/capabilities", token);
        assertThat(capabilities.path("settings").path("detail").asText()).isEqualTo("STANDARD");
        assertThat(capabilities.path("settings").path("memoryTurns").asInt()).isEqualTo(6);
        assertThat(capabilities.path("reasoningEffortSupported").asBoolean()).as("CUSTOM provider has no dialect").isFalse();

        JsonNode saved = settings(token, Map.of("detail", "CONCISE", "memoryTurns", 3, "sendKey", "CTRL_ENTER"), 200);
        assertThat(saved.path("settings").path("detail").asText()).isEqualTo("CONCISE");
        assertThat(saved.path("settings").path("reasoning").asText()).isEqualTo("FAST");
        String stored = jdbc.queryForObject("""
                SELECT pref_value::text FROM user_preferences WHERE pref_key = 'ai.chat.settings'
                ORDER BY updated_at DESC LIMIT 1
                """, String.class);
        assertThat(stored).contains("\"detail\": \"CONCISE\"", "\"memoryTurns\": 3", "\"sendKey\": \"CTRL_ENTER\"");
        // A new session (another device) reads the same settings.
        assertThat(getJson("/api/ai/chat/capabilities", token).path("settings").path("memoryTurns").asInt()).isEqualTo(3);

        for (Object invalid : List.of(Map.of("detail", "VERBOSE"), Map.of("memoryTurns", 50), Map.of("sensitiveFields", true),
                Map.of(), List.of("detail"))) {
            settings(token, invalid, 422);
        }
        MvcResult generic = mvc.perform(json(put("/api/user/preferences/ai.chat.settings"),
                Map.of("memoryTurns", 99, "pageAware", true), token)).andReturn();
        assertEquals(422, generic.getResponse().getStatus(), body(generic));
        assertThat(getJson("/api/ai/chat/capabilities", token).path("settings").path("memoryTurns").asInt()).isEqualTo(3);
    }

    @Test void conversationIsCarriedAcrossPagesBoundedRestoredAndClearedOnlyForItsOwner() throws Exception {
        String token = staffToken();
        String conversation = UUID.randomUUID().toString();
        JsonNode first = ask(token, conversation, "TASK-A01 和 TASK-B02 哪些缺料", "缺料的是 TASK-A01 和 TASK-B02。");
        assertThat(first.path("conversationId").asText()).isEqualTo(conversation);
        assertThat(first.path("reply").asText()).contains("TASK-A01");
        JsonNode second = ask(token, conversation, "那第一个呢，为什么", "刚才的 TASK-A01 还缺外壳。");
        assertThat(second.path("reply").asText()).as("a remembered code marked as earlier passes the guard").contains("TASK-A01");
        // Third question on another page: the earlier turns reach the provider as memory, not as page facts.
        FAKE.defaultResponse(FakeAiProviderServer.openAiContent(REPLY.formatted("刚才的 TASK-A01 对应订单还要看发货单。")));
        await(token, submit(token, Map.of("message", "刚才那个任务对应的订单能发货吗", "conversationId", conversation,
                "pageContext", Map.of("route", "/production/workshop-tasks", "snapshot", Map.of("title", "我的车间任务")))));
        String prompt = objectMapper.readTree(FAKE.lastChatRequest().body()).toString();
        assertThat(prompt).contains("CONVERSATION HISTORY (source id", "Q: TASK-A01 和 TASK-B02 哪些缺料", "缺料的是 TASK-A01 和 TASK-B02",
                "Q: 那第一个呢，为什么", "It is memory, not the current page");

        // The memory setting bounds how many earlier turns the model sees.
        settings(token, Map.of("memoryTurns", 0), 200);
        ask(token, conversation, "那 B02 呢", "你想查什么？");
        assertThat(objectMapper.readTree(FAKE.lastChatRequest().body()).toString()).doesNotContain("CONVERSATION HISTORY (source id");
        settings(token, Map.of("memoryTurns", 3), 200);

        // After a refresh the latest conversation is restored, oldest first.
        JsonNode restored = getJson("/api/ai/chat/conversations/current", token);
        assertThat(restored.path("conversationId").asText()).isEqualTo(conversation);
        assertThat(restored.path("turns").size()).isEqualTo(4);
        assertThat(restored.path("turns").get(0).path("result").path("question").asText()).isEqualTo("TASK-A01 和 TASK-B02 哪些缺料");
        assertThat(restored.path("turns").get(2).path("result").path("pageTitle").asText()).isNotBlank();

        // Someone else never sees or continues it.
        String stranger = staffToken();
        assertThat(getJson("/api/ai/chat/conversations/current?conversationId=" + conversation, stranger)
                .path("turns").size()).isZero();
        ask(stranger, conversation, "继续", "你想查什么？");
        assertThat(objectMapper.readTree(FAKE.lastChatRequest().body()).toString()).doesNotContain("TASK-A01");

        // Clearing archives the owner's records: not restored, not carried, the usage audit row stays.
        MvcResult cleared = mvc.perform(authed(delete("/api/ai/chat/conversations"), token)).andReturn();
        assertEquals(200, cleared.getResponse().getStatus(), body(cleared));
        assertThat(json(cleared).path("cleared").asInt()).isEqualTo(4);
        assertThat(getJson("/api/ai/chat/conversations/current", token).path("turns").size()).isZero();
        ask(token, conversation, "那第一个呢", "你想查什么？");
        assertThat(objectMapper.readTree(FAKE.lastChatRequest().body()).toString()).doesNotContain("TASK-A01", "CONVERSATION HISTORY (source id");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_jobs WHERE archive_reason='AI_CHAT_CLEARED_BY_USER'"
                + " AND archived_by LIKE 'user:%'", Long.class)).isGreaterThanOrEqualTo(4);
    }

    @Test void sensitiveAnswersAreCarriedOnlyAsTheirQuestionAndIdentityChangeStopsCarrying() throws Exception {
        Staff owner = staff();
        String token = tokenOf(owner);
        String conversation = UUID.randomUUID().toString();
        FAKE.defaultResponse(FakeAiProviderServer.openAiContent(REPLY.formatted("先领料再生产。")));
        String id = submit(token, Map.of("message", "上一轮的敏感问题", "conversationId", conversation));
        await(token, id);
        jdbc.update("UPDATE ai_jobs SET result = jsonb_set(jsonb_set(result, '{reply}', '\"PRIVATE_COST_765432\"'),"
                + " '{replyShareable}', 'false') WHERE id = ?::uuid", id);
        ask(token, conversation, "那这个呢", "你想查什么？");
        String prompt = objectMapper.readTree(FAKE.lastChatRequest().body()).toString();
        assertThat(prompt).contains("Q: 上一轮的敏感问题", "该回答含敏感数据，未带入").doesNotContain("PRIVATE_COST", "765432");

        // Identity change (department move): earlier turns are neither carried nor restored.
        jdbc.update("UPDATE employees SET department_id=(SELECT id FROM departments WHERE code='WS_WJTZ') WHERE id=?::uuid",
                owner.employeeId());
        String moved = tokenOf(owner);
        assertThat(getJson("/api/ai/chat/capabilities", moved).path("canChat").asBoolean()).isTrue();
        JsonNode view = getJson("/api/ai/chat/conversations/current?conversationId=" + conversation, moved);
        assertThat(view.path("turns").size()).isZero();
        assertThat(view.path("hiddenTurns").asInt()).isEqualTo(2);
        ask(moved, conversation, "那这个呢", "你想查什么？");
        assertThat(objectMapper.readTree(FAKE.lastChatRequest().body()).toString())
                .doesNotContain("上一轮的敏感问题", "CONVERSATION HISTORY (source id");
    }

    /**
     * A tool answer whose business data moved since (the real production tool re-queries and its digest no longer
     * matches) is not a permission change: restore shows its question with dataChanged, memory carries the question
     * and the marker, never the old values, and nothing is counted as hidden.
     */
    @Test void aToolAnswerWhoseDataChangedKeepsItsQuestionInMemoryAndRestore() throws Exception {
        String token = staffToken();
        String conversation = UUID.randomUUID().toString();
        FAKE.defaultResponse(FakeAiProviderServer.openAiContent(REPLY.formatted("先领料再生产。")));
        String id = submit(token, Map.of("message", "我车间在产的有哪些", "conversationId", conversation));
        await(token, id);
        // Rewrite the stored turn as an answer of the real production tool whose snapshot no longer matches.
        jdbc.update("""
                UPDATE ai_jobs SET result = result
                    || jsonb_build_object('_tool', 'production_in_progress', '_domain', 'PRODUCTION', 'intent', 'TOOL',
                                          'reply', '在产 OLD_TASK_77 个', 'replyShareable', true,
                                          '_toolEvidence', jsonb_build_object('scope', 'WORKSHOP', 'keyword', '',
                                                                              'snapshot', repeat('0', 64)))
                WHERE id = ?::uuid
                """, id);
        JsonNode view = getJson("/api/ai/chat/conversations/current?conversationId=" + conversation, token);
        assertThat(view.path("hiddenTurns").asInt()).as("data change is not a permission change").isZero();
        JsonNode turn = view.path("turns").get(0).path("result");
        assertThat(turn.path("question").asText()).isEqualTo("我车间在产的有哪些");
        assertThat(turn.path("dataChanged").asBoolean()).isTrue();
        assertThat(turn.has("reply")).isFalse();
        assertThat(view.toString()).doesNotContain("OLD_TASK_77");

        ask(token, conversation, "那第一个呢", "你想查什么？");
        String prompt = objectMapper.readTree(FAKE.lastChatRequest().body()).toString();
        assertThat(prompt).contains("Q: 我车间在产的有哪些", "(tool: 查询正在生产的产品)", "业务数据已变化")
                .doesNotContain("OLD_TASK_77");
    }

    @Test void thinkingDepthReachesTheProviderOnlyWhenItsDialectSupportsIt() throws Exception {
        String token = staffToken();
        settings(token, Map.of("reasoning", "DEEP"), 200);
        ask(token, UUID.randomUUID().toString(), "生产流程是什么", "先领料再生产。");
        JsonNode body = objectMapper.readTree(FAKE.lastChatRequest().body());
        assertThat(body.has("reasoning_effort")).as("NONE dialect sends nothing").isFalse();
        assertThat(body.path("max_tokens").asInt()).as("no thinking room without a dialect").isEqualTo(8192);

        // A stored FAST setting changes nothing on a provider that cannot adjust thinking (the panel locks it).
        settings(token, Map.of("reasoning", "FAST"), 200);
        ask(token, UUID.randomUUID().toString(), "生产流程是什么", "先领料再生产。");
        body = objectMapper.readTree(FAKE.lastChatRequest().body());
        assertThat(body.path("max_tokens").asInt()).isEqualTo(8192);
        assertThat(body.has("reasoning_effort")).isFalse();

        jdbc.update("UPDATE ai_providers SET thinking_control='ZHIPU', max_output_tokens=32768 WHERE is_default");
        assertThat(getJson("/api/ai/chat/capabilities", token).path("reasoningEffortSupported").asBoolean()).isTrue();
        settings(token, Map.of("reasoning", "DEEP"), 200);
        ask(token, UUID.randomUUID().toString(), "生产流程是什么", "先领料再生产。");
        body = objectMapper.readTree(FAKE.lastChatRequest().body());
        assertThat(body.path("thinking").path("type").asText()).isEqualTo("enabled");
        assertThat(body.path("reasoning_effort").asText()).isEqualTo("max");
        assertThat(body.path("max_tokens").asInt()).isEqualTo(8192 + 16384);

        settings(token, Map.of("reasoning", "FAST"), 200);
        ask(token, UUID.randomUUID().toString(), "生产流程是什么", "先领料再生产。");
        body = objectMapper.readTree(FAKE.lastChatRequest().body());
        assertThat(body.path("reasoning_effort").asText()).isEqualTo("low");
        assertThat(body.path("max_tokens").asInt()).as("the answer budget does not shrink with the depth").isEqualTo(8192);

        // The configured maximum output is a hard limit: the thinking room never goes beyond it.
        jdbc.update("UPDATE ai_providers SET max_output_tokens=8192 WHERE is_default");
        settings(token, Map.of("reasoning", "DEEP"), 200);
        ask(token, UUID.randomUUID().toString(), "生产流程是什么", "先领料再生产。");
        assertThat(objectMapper.readTree(FAKE.lastChatRequest().body()).path("max_tokens").asInt()).isEqualTo(8192);

        // Tongyi (non-streaming JSON calls): thinking stays off and the setting is reported as not adjustable.
        jdbc.update("UPDATE ai_providers SET thinking_control='DASHSCOPE' WHERE is_default");
        assertThat(getJson("/api/ai/chat/capabilities", token).path("reasoningEffortSupported").asBoolean()).isFalse();
        ask(token, UUID.randomUUID().toString(), "生产流程是什么", "先领料再生产。");
        body = objectMapper.readTree(FAKE.lastChatRequest().body());
        assertThat(body.path("enable_thinking").asBoolean(true)).isFalse();
        assertThat(body.has("thinking_budget")).isFalse();

        // OpenAI reasoning dialect with "fixed output" on: no temperature next to a real reasoning effort.
        jdbc.update("UPDATE ai_providers SET thinking_control='OPENAI_REASONING', send_temperature=true WHERE is_default");
        ask(token, UUID.randomUUID().toString(), "生产流程是什么", "先领料再生产。");
        body = objectMapper.readTree(FAKE.lastChatRequest().body());
        assertThat(body.path("reasoning_effort").asText()).isEqualTo("high");
        assertThat(body.has("temperature")).isFalse();
    }
}
