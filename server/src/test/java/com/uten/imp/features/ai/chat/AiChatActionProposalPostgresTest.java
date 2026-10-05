package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.features.ai.AiPlatformPostgresTestSupport;
import com.uten.imp.features.ai.support.FakeAiProviderServer;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/**
 * ADR-150 confirmation cards over the real HTTP/JWT/worker/gateway chain and a disposable PostgreSQL:
 * one-time consumption under concurrent clicks, receipt, cancel, expiry, identity change, the database
 * guard, snapshot validation and the step-up permission grant card.
 */
class AiChatActionProposalPostgresTest extends AiPlatformPostgresTestSupport {
    private static final String ROUTE = "/sales/orders/new";
    private static final String ACTION = """
            {"intent":"ACTION","reply":"已经改好了","usedSources":["page.actions"],"tool":"","arguments":{},
             "action":{"name":"setLineField","args":{"row":2,"field":"数量","value":"100"}}}
            """;
    private String admin;
    private Staff seller;
    private String token;

    @BeforeEach void salesWithFakeProvider() throws Exception {
        jdbc.update("""
                INSERT INTO department_permissions(department_id,permission_id)
                SELECT d.id,p.id FROM departments d CROSS JOIN permissions p
                WHERE d.code='DEPT_SALES' AND p.code IN ('ai:use','sales_order:view','sales_order:create','sales_order:edit')
                ON CONFLICT DO NOTHING
                """);
        admin = adminToken();
        resetToFakeDefaultProvider(admin);
        FAKE.reset();
        seller = newEmployee(adminToken(), "DEPT_SALES");
        token = fresh(seller);
    }

    static Map<String, Object> snapshot() {
        Map<String, Object> snapshot = new LinkedHashMap<>();
        snapshot.put("title", "新建销售订货单");
        snapshot.put("tables", List.of(Map.of("title", "货品明细", "totalRows", 2,
                "columns", List.of(Map.of("label", "货品"), Map.of("label", "数量"), Map.of("label", "单价"),
                        Map.of("label", "成本单价")),
                "rows", List.of(Map.of("no", 1, "cells", List.of("A001 螺丝", "20", "1.5", "0.731")),
                        Map.of("no", 2, "cells", List.of("A002 外壳", "50", "0", "0.552"))),
                "flaggedCells", List.of(Map.of("rowNo", 2, "rowLabel", "A002 外壳", "column", "单价", "value", "0",
                        "state", "REVIEW", "reason", "标价为0, 要先做报价单交给财务定价")))));
        snapshot.put("notices", List.of(Map.of("kind", "BANNER", "text", "MARKER-ZQ7 只在页面上出现")));
        snapshot.put("pageActions", List.of(Map.of("name", "setLineField", "title", "修改明细行", "kind", "FORM",
                "params", Map.of("type", "object", "additionalProperties", false,
                        "properties", Map.of("row", Map.of("type", "integer", "title", "行号", "minimum", 1, "maximum", 500),
                                "field", Map.of("type", "string", "title", "字段", "enum", List.of("数量", "单价")),
                                "value", Map.of("type", "string", "title", "新值", "maxLength", 40)),
                        "required", List.of("row", "field", "value")))));
        return snapshot;
    }

    @Test void pageActionCardIsConsumedOnceUnderConcurrentClicksAndKeepsOneReceipt() throws Exception {
        FAKE.defaultResponse(FakeAiProviderServer.openAiContent(ACTION));
        String job = submit(token, Map.of("message", "把第2行数量改成100", "pageContext", Map.of("route", ROUTE, "snapshot", snapshot())));
        JsonNode result = awaitSucceeded(token, job);
        assertThat(result.path("intent").asText()).isEqualTo("ACTION");
        assertThat(result.path("reply").asText()).contains("确认卡").doesNotContain("改好了");
        JsonNode card = result.path("actions").get(0);
        assertThat(card.path("status").asText()).isEqualTo("PROPOSED");
        assertThat(card.path("handler").asText()).isEqualTo("setLineField");
        assertThat(card.path("summaryLines").toString()).contains("行号: 2 (A002 外壳 50)", "字段: 数量", "新值: 100", "标黄");
        String proposal = card.path("proposalId").asText();

        // The snapshot reached the provider as untrusted data without the sensitive cost column, and is not retained.
        String sent = FAKE.lastChatRequest().body();
        assertThat(sent).contains("MARKER-ZQ7", "UNTRUSTED_DOCUMENT", "withheldSensitiveValues").doesNotContain("0.731", "0.552");
        assertThat(jdbc.queryForObject("SELECT input_bytes IS NULL FROM ai_jobs WHERE id=?::uuid", Boolean.class, job)).isTrue();
        assertThat(jdbc.queryForObject("SELECT result::text FROM ai_jobs WHERE id=?::uuid", String.class, job)).doesNotContain("MARKER-ZQ7");

        var start = new CountDownLatch(1);
        var pool = Executors.newFixedThreadPool(2);
        try {
            List<Future<Integer>> clicks = new ArrayList<>();
            for (int i = 0; i < 2; i++) clicks.add(pool.submit(() -> {
                start.await();
                return mvc.perform(authed(post("/api/ai/chat/actions/" + proposal + "/confirm"), token)).andReturn()
                        .getResponse().getStatus();
            }));
            start.countDown();
            List<Integer> statuses = new ArrayList<>();
            for (var click : clicks) statuses.add(click.get());
            assertThat(statuses).containsExactlyInAnyOrder(200, 409);
        } finally { pool.shutdownNow(); }
        assertThat(jdbc.queryForObject("SELECT status FROM ai_chat_action_proposals WHERE id=?::uuid", String.class, proposal))
                .isEqualTo("CONFIRMED");

        MvcResult receipt = mvc.perform(json(post("/api/ai/chat/actions/" + proposal + "/receipt"),
                Map.of("outcome", "SUCCEEDED"), token)).andReturn();
        assertEquals(200, receipt.getResponse().getStatus(), body(receipt));
        MvcResult same = mvc.perform(json(post("/api/ai/chat/actions/" + proposal + "/receipt"),
                Map.of("outcome", "SUCCEEDED"), token)).andReturn();
        assertEquals(200, same.getResponse().getStatus(), body(same));
        MvcResult contradicting = mvc.perform(json(post("/api/ai/chat/actions/" + proposal + "/receipt"),
                Map.of("outcome", "FAILED", "message", "late"), token)).andReturn();
        assertEquals(409, contradicting.getResponse().getStatus(), body(contradicting));
        JsonNode view = getJson("/api/ai/chat/actions/" + proposal, token);
        assertThat(view.path("status").asText()).isEqualTo("CONFIRMED");
        assertThat(view.path("outcome").asText()).isEqualTo("SUCCEEDED");
        assertThat(succeeded(token, job).path("actions").get(0).path("outcome").asText()).isEqualTo("SUCCEEDED");
        assertThat(jdbc.queryForList("SELECT action FROM audit_log WHERE target_id=? ORDER BY created_at", String.class, proposal))
                .contains("ai_action.propose", "ai_action.confirm", "ai_action.receipt");

        Staff stranger = newEmployee(adminToken(), "DEPT_SALES");
        MvcResult foreign = mvc.perform(authed(get("/api/ai/chat/actions/" + proposal), fresh(stranger))).andReturn();
        assertEquals(404, foreign.getResponse().getStatus(), body(foreign));
    }

    @Test void cancelExpiryAndIdentityChangeVoidCardsAndTheDatabaseGuardsTheRows() throws Exception {
        FAKE.defaultResponse(FakeAiProviderServer.openAiContent(ACTION));
        String cancelled = card(token);
        JsonNode cancel = json(mvc.perform(authed(post("/api/ai/chat/actions/" + cancelled + "/cancel"), token)).andReturn());
        assertThat(cancel.path("status").asText()).isEqualTo("CANCELLED");
        MvcResult afterCancel = mvc.perform(authed(post("/api/ai/chat/actions/" + cancelled + "/confirm"), token)).andReturn();
        assertEquals(409, afterCancel.getResponse().getStatus(), body(afterCancel));

        String expired = UUID.randomUUID().toString();
        jdbc.update("""
                INSERT INTO ai_chat_action_proposals(id,actor_user_id,actor_auth_version,authorization_epoch,membership_hash,
                    action_type,handler,execution,route,target_type,target_ref,args,args_hash,title,summary,risk,
                    issued_at,expires_at)
                SELECT ?::uuid,actor_user_id,actor_auth_version,authorization_epoch,membership_hash,action_type,handler,
                    execution,route,target_type,target_ref,args,args_hash,title,summary,risk,
                    now()-interval '11 minutes',now()-interval '1 minute'
                FROM ai_chat_action_proposals WHERE id=?::uuid
                """, expired, cancelled);
        MvcResult late = mvc.perform(authed(post("/api/ai/chat/actions/" + expired + "/confirm"), token)).andReturn();
        assertEquals(409, late.getResponse().getStatus(), body(late));
        assertThat(body(late)).contains("AI_ACTION_EXPIRED");
        assertThat(jdbc.queryForObject("SELECT status FROM ai_chat_action_proposals WHERE id=?::uuid", String.class, expired))
                .isEqualTo("EXPIRED");

        String stale = card(token);
        jdbc.update("UPDATE users SET auth_version=auth_version+1 WHERE id=?::uuid", seller.userId());
        String renewed = fresh(seller);
        MvcResult changed = mvc.perform(authed(post("/api/ai/chat/actions/" + stale + "/confirm"), renewed)).andReturn();
        assertEquals(409, changed.getResponse().getStatus(), body(changed));
        assertThat(body(changed)).contains("AI_ACTION_AUTH_CHANGED");
        assertThat(jdbc.queryForMap("SELECT status,outcome FROM ai_chat_action_proposals WHERE id=?::uuid", stale))
                .containsEntry("status", "CANCELLED").containsEntry("outcome", "AUTH_CHANGED");

        assertThatThrownBy(() -> jdbc.update("UPDATE ai_chat_action_proposals SET args='{\"row\":9}'::jsonb WHERE id=?::uuid", stale))
                .hasMessageContaining("不能修改");
        assertThatThrownBy(() -> jdbc.update("UPDATE ai_chat_action_proposals SET status='CONFIRMED',confirmed_at=now() WHERE id=?::uuid", expired))
                .hasMessageContaining("已经处理过");
        assertThatThrownBy(() -> jdbc.update("""
                INSERT INTO ai_chat_action_proposals(id,actor_user_id,actor_auth_version,authorization_epoch,membership_hash,
                    action_type,handler,execution,target_type,args,args_hash,title,summary,risk,expires_at)
                SELECT gen_random_uuid(),actor_user_id,1,1,membership_hash,'PAGE_ACTION','x','CLIENT','PAGE','{}'::jsonb,
                    args_hash,'t','["l"]'::jsonb,'LOW',now()+interval '1 hour'
                FROM ai_chat_action_proposals WHERE id=?::uuid
                """, stale)).hasMessageContaining("ck_ai_action_proposal_window");
    }

    @Test void malformedOrIdentifierLikeSnapshotsAreRejectedBeforeAnyJob() throws Exception {
        long jobs = jdbc.queryForObject("SELECT count(*) FROM ai_jobs", Long.class);
        var uuidLabel = new LinkedHashMap<>(snapshot());
        uuidLabel.put("fields", List.of(Map.of("label", UUID.randomUUID().toString(), "value", "x")));
        var tooManyRows = new LinkedHashMap<>(snapshot());
        List<Map<String, Object>> rows = new ArrayList<>();
        for (int i = 1; i <= 31; i++) rows.add(Map.of("no", i, "cells", List.of("A" + i)));
        tooManyRows.put("tables", List.of(Map.of("columns", List.of(Map.of("label", "货品")), "rows", rows)));
        var urlAction = new LinkedHashMap<>(snapshot());
        urlAction.put("pageActions", List.of(Map.of("name", "open", "title", "https://evil.invalid/x", "kind", "VIEW")));
        for (var bad : List.of(uuidLabel, tooManyRows, urlAction)) {
            MvcResult rejected = mvc.perform(json(post("/api/ai/chat/messages"),
                    Map.of("message", "这页有什么", "pageContext", Map.of("route", ROUTE, "snapshot", bad)), token)).andReturn();
            assertEquals(422, rejected.getResponse().getStatus(), body(rejected));
        }
        assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_jobs", Long.class)).isEqualTo(jobs);
        assertThat(FAKE.chatRequestCount()).isZero();
    }

    @Test void permissionGrantIsAServerCardThatNeedsStepUpAndGrantsOnce() throws Exception {
        Staff target = newEmployee(adminToken(), "DEPT_SALES");
        String code = jdbc.queryForObject("SELECT code FROM employees WHERE id=?::uuid", String.class, target.employeeId());
        FAKE.defaultResponse(FakeAiProviderServer.openAiContent(objectMapper.writeValueAsString(Map.of(
                "intent", "TOOL", "reply", "", "usedSources", List.of(), "tool", "prepare_permission_grant",
                "arguments", Map.of("employeeKeyword", code, "permissionKeyword", "goods:view"),
                "action", Map.of("name", "", "args", Map.of())))));
        String superAdmin = adminToken();
        JsonNode result = awaitSucceeded(superAdmin, submit(superAdmin, Map.of("message", "给" + code + "开通查看货品")));
        JsonNode card = result.path("actions").get(0);
        assertThat(card.path("actionType").asText()).isEqualTo("PERMISSION_GRANT");
        assertThat(card.path("execution").asText()).isEqualTo("SERVER");
        assertThat(card.path("requiresStepUp").asBoolean()).isTrue();
        assertThat(card.has("args")).isFalse();
        assertThat(card.path("summaryLines").toString()).contains(code, "只增加这一项授权");
        String proposal = card.path("proposalId").asText();

        MvcResult clientPath = mvc.perform(authed(post("/api/ai/chat/actions/" + proposal + "/confirm"), superAdmin)).andReturn();
        assertEquals(409, clientPath.getResponse().getStatus(), body(clientPath));
        MvcResult noStepUp = mvc.perform(json(post("/api/ai/chat/permission-grants/confirm"),
                Map.of("proposalId", proposal), superAdmin)).andReturn();
        assertEquals(403, noStepUp.getResponse().getStatus(), body(noStepUp));
        MvcResult granted = mvc.perform(json(post("/api/ai/chat/permission-grants/confirm"), Map.of("proposalId", proposal), superAdmin)
                .header(STEP_UP_HEADER, stepUp(superAdmin, ADMIN_PASSWORD))).andReturn();
        assertEquals(200, granted.getResponse().getStatus(), body(granted));
        assertThat(json(granted).path("status").asText()).isEqualTo("GRANTED");
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM user_permission_overrides o JOIN permissions p ON p.id=o.permission_id
                WHERE o.user_id=?::uuid AND p.code='goods:view' AND o.effect='grant'
                """, Long.class, target.userId())).isEqualTo(1);
        assertThat(jdbc.queryForMap("SELECT status,outcome FROM ai_chat_action_proposals WHERE id=?::uuid", proposal))
                .containsEntry("status", "CONFIRMED").containsEntry("outcome", "SUCCEEDED");
        String again = adminToken();
        MvcResult replay = mvc.perform(json(post("/api/ai/chat/permission-grants/confirm"), Map.of("proposalId", proposal), again)
                .header(STEP_UP_HEADER, stepUp(again, ADMIN_PASSWORD))).andReturn();
        assertEquals(409, replay.getResponse().getStatus(), body(replay));
    }

    private String card(String actorToken) throws Exception {
        JsonNode result = awaitSucceeded(actorToken, submit(actorToken, Map.of("message", "把第2行数量改成100",
                "pageContext", Map.of("route", ROUTE, "snapshot", snapshot()))));
        return result.path("actions").get(0).path("proposalId").asText();
    }
    private String fresh(Staff staff) throws Exception { return login(staff.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText(); }
    private String submit(String actorToken, Map<String, Object> request) throws Exception {
        MvcResult response = mvc.perform(json(post("/api/ai/chat/messages"), request, actorToken)).andReturn();
        assertEquals(202, response.getResponse().getStatus(), body(response));
        return json(response).path("jobId").asText();
    }
    private JsonNode awaitSucceeded(String actorToken, String id) throws Exception {
        long deadline = System.nanoTime() + Duration.ofSeconds(40).toNanos();
        JsonNode view = null;
        while (System.nanoTime() < deadline) {
            view = getJson("/api/ai/jobs/" + id, actorToken);
            String status = view.path("status").asText();
            if ("SUCCEEDED".equals(status)) return view.path("result");
            if (List.of("FAILED", "CANCELLED").contains(status)) throw new AssertionError(view.toString());
            Thread.sleep(100);
        }
        throw new AssertionError("Chat worker did not finish: " + view);
    }
    private JsonNode succeeded(String actorToken, String id) throws Exception { return awaitSucceeded(actorToken, id); }
}
