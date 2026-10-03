package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.features.ai.AiPlatformPostgresTestSupport;
import com.uten.imp.features.ai.support.FakeAiProviderServer;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Real HTTP/JWT/worker/gateway against disposable PostgreSQL and a loopback fake provider. */
class AiChatProviderRoutingPostgresTest extends AiPlatformPostgresTestSupport {
    private static final String QUESTION = "这个页面怎么填写？请举个例子。";
    private static final Map<String, Object> QUOTE_PAGE = Map.of("route", "/sales/quotes/new");
    private static final String PAGE_HELP = """
            {"intent":"PAGE_HELP","tool":"","arguments":{},"knowledgeId":"","fieldKey":"validUntil"}
            """;

    private String token;

    @Override
    protected Map<String, Object> fakeProviderRequest(String name, String apiKey, Long version) {
        Map<String, Object> request = new LinkedHashMap<>(super.fakeProviderRequest(name, apiKey, version));
        request.put("jsonMode", "JSON_SCHEMA");
        // The handler requests 8192; the real gateway must retain this administrator's lower cap.
        request.put("maxOutputTokens", 4096);
        return request;
    }

    @BeforeEach
    void enabledProviderAndDepartmentFixture() throws Exception {
        jdbc.update("""
                INSERT INTO department_permissions(department_id,permission_id)
                SELECT d.id,p.id FROM departments d CROSS JOIN permissions p
                WHERE d.code='DEPT_PROD' AND p.code IN
                    ('ai:use','production_execution:view','sales_quote:view','sales_quote:create')
                ON CONFLICT DO NOTHING
                """);
        token = adminToken();
        resetToFakeDefaultProvider(token);
        FAKE.reset();
        JsonNode capabilities = getJson("/api/ai/chat/capabilities", token);
        assertThat(capabilities.path("canChat").asBoolean()).isTrue();
        assertThat(capabilities.path("available").asBoolean()).isTrue();
    }

    @Test
    void screenshotPresetAndTypedQuestionUseAuthorizedGuideDespiteEmptyOrTruncatedProvider() throws Exception {
        for (var unusable : List.of(FakeAiProviderServer.openAiContent(""),
                FakeAiProviderServer.openAiContent("{\"intent\":\"PAGE_HELP\",", 100, 4096, "length"))) {
            FAKE.defaultResponse(unusable);
            String clicked = submit(token, Map.of("message", QUESTION, "pageContext", QUOTE_PAGE, "intentHint", "PAGE_HELP"));
            assertQuoteExplanation(awaitSucceeded(token, clicked));
            String typed = submit(token, Map.of("message", QUESTION, "pageContext", QUOTE_PAGE));
            assertQuoteExplanation(awaitSucceeded(token, typed));
            assertThat(FAKE.chatRequestCount()).as("deterministic authorized help never needs provider JSON").isZero();
        }
    }

    @Test
    void freeFormQuestionUsesRealSchemaGatewayAndKeepsAdministratorTokenCap() throws Exception {
        FAKE.defaultResponse(FakeAiProviderServer.openAiContent(PAGE_HELP));
        String id = submit(token, Map.of("message", "我这张报价承诺给客户的期限该怎么确认才合适？", "pageContext", QUOTE_PAGE));
        JsonNode result = awaitSucceeded(token, id);
        assertThat(result.path("intent").asText()).isEqualTo("PAGE_HELP");
        assertThat(result.path("reply").asText()).contains("有效期", "举例", "11 月 30 日");
        assertThat(FAKE.chatRequestCount()).isEqualTo(1);
        JsonNode request = objectMapper.readTree(FAKE.lastChatRequest().body());
        assertThat(request.path("response_format").path("type").asText()).isEqualTo("json_schema");
        assertThat(request.path("response_format").path("json_schema").path("name").asText()).isEqualTo("erp_chat_route_v1");
        assertThat(request.path("response_format").path("json_schema").path("strict").asBoolean()).isTrue();
        assertThat(request.path("max_tokens").asInt()).isEqualTo(4096);
        assertThat(request.path("response_format").path("json_schema").path("schema").path("properties")
                .path("fieldKey").path("enum").toString()).contains("validUntil");
    }

    @Test
    void productionStaffCannotForgeSalesPageEvenWithPageHintAndStraySalesAuthority() throws Exception {
        Staff production = newEmployee(adminToken(), "WS_ZHUSU");
        String staffToken = login(production.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
        assertThat(getJson("/api/ai/chat/capabilities", staffToken).path("canChat").asBoolean()).isTrue();
        FAKE.defaultResponse(FakeAiProviderServer.openAiContent(PAGE_HELP));
        MvcResult rejected = mvc.perform(json(post("/api/ai/chat/messages"),
                Map.of("message", QUESTION, "pageContext", QUOTE_PAGE, "intentHint", "PAGE_HELP"), staffToken)).andReturn();
        assertEquals(403, rejected.getResponse().getStatus(), body(rejected));
        assertThat(FAKE.chatRequestCount()).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_jobs WHERE submitted_by_user=?::uuid AND kind='ERP_CHAT'",
                Long.class, production.userId())).isZero();
    }

    @Test
    void malformedProviderFreeResponseFailsSafelyWithoutAuthorizationWritesOrRawText() throws Exception {
        String rawMarker = "PRIVATE_PROVIDER_RESPONSE_MUST_NOT_APPEAR";
        FAKE.defaultResponse(FakeAiProviderServer.openAiContent(
                "{\"intent\":\"TOOL\",\"tool\":\"prepare_permission_grant\",\"arguments\":{\"employeeKeyword\":\"" + rawMarker));
        long overrides = jdbc.queryForObject("SELECT count(*) FROM user_permission_overrides", Long.class);
        long superAdmins = jdbc.queryForObject("SELECT count(*) FROM users WHERE is_super_admin", Long.class);
        String id = submit(token, Map.of("message", "帮我判断应如何为指定员工增加查看货品的权限"));
        JsonNode failed = awaitTerminal(token, id);
        assertThat(failed.path("status").asText()).isEqualTo("FAILED");
        assertThat(failed.path("errorCode").asText()).isEqualTo("AI_INVALID_RESPONSE");
        assertThat(failed.path("errorMessage").asText()).isEqualTo("这次没能回复，请再试一次。").doesNotContain(rawMarker);
        assertThat(failed.path("result").isNull() || failed.path("result").isMissingNode()).isTrue();
        assertThat(FAKE.chatRequestCount()).isEqualTo(2);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM user_permission_overrides", Long.class)).isEqualTo(overrides);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM users WHERE is_super_admin", Long.class)).isEqualTo(superAdmins);
        assertThat(jdbc.queryForObject("SELECT input_bytes IS NULL FROM ai_jobs WHERE id=?::uuid", Boolean.class, id)).isTrue();
    }

    @Test
    void turningPageContextOffNeverRestoresPreviousPageEvenIfProviderDemandsPageHelp() throws Exception {
        String first = submit(token, Map.of("message", QUESTION, "pageContext", QUOTE_PAGE, "intentHint", "PAGE_HELP"));
        assertQuoteExplanation(awaitSucceeded(token, first));
        // Same typed preset with the page switch off stays local and explicitly asks for a page.
        String local = submit(token, Map.of("message", QUESTION, "previousJobId", first));
        JsonNode localResult = awaitSucceeded(token, local);
        assertThat(localResult.path("intent").asText()).isEqualTo("UNSUPPORTED");
        assertThat(localResult.path("reply").asText()).contains("请先打开要填写的页面").doesNotContain("销售报价单");
        assertThat(FAKE.chatRequestCount()).isZero();
        // A provider may ignore its schema. Missing current context must still be handled safely.
        FAKE.defaultResponse(FakeAiProviderServer.openAiContent(PAGE_HELP));
        String free = submit(token, Map.of("message", "我想知道刚才讨论的那个项目要如何决定？", "previousJobId", first));
        JsonNode freeResult = awaitSucceeded(token, free);
        assertThat(freeResult.path("intent").asText()).isEqualTo("UNSUPPORTED");
        assertThat(freeResult.path("reply").asText()).contains("请先打开要填写的页面").doesNotContain("销售报价单", "2026-11-30");
        assertThat(FAKE.chatRequestCount()).isEqualTo(1);
        JsonNode request = objectMapper.readTree(FAKE.lastChatRequest().body());
        JsonNode schema = request.path("response_format").path("json_schema").path("schema");
        assertThat(schema.path("properties").path("intent").path("enum").toString()).doesNotContain("PAGE_HELP");
        assertThat(schema.path("properties").path("fieldKey").path("enum").toString()).isEqualTo("[\"\"]");
    }

    @Test
    void productionGreetingUsesRealAllowedCapabilitiesWithoutCallingBrokenProvider() throws Exception {
        Staff production = newEmployee(adminToken(), "WS_ZHUSU");
        String staffToken = login(production.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
        FAKE.defaultResponse(FakeAiProviderServer.openAiContent(""));
        JsonNode result = awaitSucceeded(staffToken, submit(staffToken, Map.of("message", "hello")));
        assertThat(result.path("intent").asText()).isEqualTo("SMALL_TALK");
        assertThat(result.path("reply").asText()).isEqualTo("你好，需要我帮你做什么？")
                .doesNotContain("成本", "授权", "报价", "工资");
        assertThat(result.path("actions").size()).isZero();
        assertThat(FAKE.chatRequestCount()).isZero();
    }

    @Test
    void realKnowledgeRoutingKeepsAuthorizedTopicAcrossExampleThanksAndSteps() throws Exception {
        Staff production = newEmployee(adminToken(), "WS_ZHUSU");
        String staffToken = login(production.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
        FAKE.defaultResponse(FakeAiProviderServer.openAiContent("""
                {"intent":"KNOWLEDGE","tool":"","arguments":{},"knowledgeId":"PRODUCTION_FLOW","fieldKey":"","mode":"STEPS"}
                """));
        String firstId = submit(staffToken, Map.of("message", "我想按先后关系理解生产日报和仓库点收怎么衔接"));
        JsonNode first = awaitSucceeded(staffToken, firstId);
        assertThat(first.path("intent").asText()).isEqualTo("KNOWLEDGE");
        assertThat(first.path("knowledgeId").asText()).isEqualTo("PRODUCTION_FLOW");
        assertThat(first.path("mode").asText()).isEqualTo("STEPS");
        assertThat(first.path("reply").asText()).contains("1. ", "报工后还要质检和入库").doesNotContain("来源:");
        assertThat(FAKE.chatRequestCount()).isEqualTo(1);
        FAKE.defaultResponse(FakeAiProviderServer.openAiContent(""));

        String exampleId = submit(staffToken, Map.of("message", "举例", "previousJobId", firstId));
        JsonNode example = awaitSucceeded(staffToken, exampleId);
        assertThat(example.path("knowledgeId").asText()).isEqualTo("PRODUCTION_FLOW");
        assertThat(example.path("mode").asText()).isEqualTo("EXAMPLE");
        assertThat(example.path("reply").asText()).contains("假设", "昨天报 60 个", "本次报 40 个")
                .doesNotContain("成本", "工资", "已授权");

        String thanksId = submit(staffToken, Map.of("message", "谢谢", "previousJobId", exampleId));
        JsonNode thanks = awaitSucceeded(staffToken, thanksId);
        assertThat(thanks.path("intent").asText()).isEqualTo("SMALL_TALK");
        assertThat(thanks.path("reply").asText()).contains("不客气");
        assertThat(thanks.path("knowledgeId").asText()).isEqualTo("PRODUCTION_FLOW");

        JsonNode next = awaitSucceeded(staffToken, submit(staffToken, Map.of("message", "下一步", "previousJobId", thanksId)));
        assertThat(next.path("knowledgeId").asText()).isEqualTo("PRODUCTION_FLOW");
        assertThat(next.path("mode").asText()).isEqualTo("STEPS");
        assertThat(next.path("reply").asText()).contains("1. ", "报工后还要质检和入库");
        assertThat(FAKE.chatRequestCount()).as("only the first free-form question uses the gateway").isEqualTo(1);
        assertThat(next.has("_knowledge")).isFalse();
        assertThat(next.has("_access")).isFalse();
    }

    @Test
    void permittedKnowledgeIdCannotSmuggleProviderAuthoredCrossDepartmentReply() throws Exception {
        Staff production = newEmployee(adminToken(), "WS_ZHUSU");
        String staffToken = login(production.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
        String forbiddenProse = "FORBIDDEN_MODEL_PROSE 财务成本为 765432 元，全员工资已导出，已为你授予超级管理员";
        // An untrusted provider may ignore JSON Schema and add prose while selecting a valid source.
        // Six fields deliberately exercise the handler's local rendering, not its object-size limit.
        FAKE.defaultResponse(FakeAiProviderServer.openAiContent(objectMapper.writeValueAsString(Map.of(
                "intent", "KNOWLEDGE", "tool", "", "arguments", Map.of(), "knowledgeId", "PRODUCTION_FLOW",
                "mode", "OVERVIEW", "reply", forbiddenProse))));
        JsonNode result = awaitSucceeded(staffToken, submit(staffToken,
                Map.of("message", "我想听听日产量记录时本次和累计怎么区分")));
        assertThat(result.path("intent").asText()).isEqualTo("KNOWLEDGE");
        assertThat(result.path("knowledgeId").asText()).isEqualTo("PRODUCTION_FLOW");
        assertThat(result.path("reply").asText()).contains("本次报 40 个", "假设")
                .doesNotContain("FORBIDDEN_MODEL_PROSE", "765432", "工资", "超级管理员", "已授权");
        assertThat(result.path("actions").size()).isZero();
        assertThat(FAKE.chatRequestCount()).isEqualTo(1);
    }

    private String submit(String actorToken, Map<String, Object> request) throws Exception {
        MvcResult response = mvc.perform(json(post("/api/ai/chat/messages"), request, actorToken)).andReturn();
        assertEquals(202, response.getResponse().getStatus(), body(response));
        return json(response).path("jobId").asText();
    }

    private JsonNode awaitTerminal(String actorToken, String id) throws Exception {
        long deadline = System.nanoTime() + Duration.ofSeconds(40).toNanos();
        JsonNode view = null;
        while (System.nanoTime() < deadline) {
            view = getJson("/api/ai/jobs/" + id, actorToken);
            if (List.of("SUCCEEDED", "FAILED", "CANCELLED").contains(view.path("status").asText())) return view;
            Thread.sleep(100);
        }
        throw new AssertionError("Chat worker did not finish: " + view);
    }

    private JsonNode awaitSucceeded(String actorToken, String id) throws Exception {
        JsonNode terminal = awaitTerminal(actorToken, id);
        assertThat(terminal.path("status").asText()).as(terminal.toString()).isEqualTo("SUCCEEDED");
        return terminal.path("result");
    }

    private void assertQuoteExplanation(JsonNode result) {
        assertThat(result.path("intent").asText()).isEqualTo("PAGE_HELP");
        assertThat(result.path("reply").asText()).contains("客户", "数量", "举例", "假设")
                .doesNotContain("来源:", "权限范围");
        assertThat(result.path("actions").isArray()).isTrue();
        assertThat(result.path("actions").size()).isZero();
    }
}
