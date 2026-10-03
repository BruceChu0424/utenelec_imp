package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.features.ai.AiPlatformPostgresTestSupport;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MvcResult;

import java.time.Duration;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Disposable PostgreSQL, full JWT/filter chain and real worker. No external model or business database. */
class AiChatPostgresTest extends AiPlatformPostgresTestSupport {
    @BeforeEach void configureRuleOnlyChat() {
        jdbc.update("DELETE FROM ai_providers");
        jdbc.update("""
                INSERT INTO department_permissions(department_id,permission_id)
                SELECT d.id,p.id FROM departments d CROSS JOIN permissions p
                WHERE d.code='DEPT_PROD' AND p.code IN ('ai:use','production_execution:view','goods:cost:view')
                ON CONFLICT DO NOTHING
                """);
    }
    private Staff productionUser() throws Exception { return newEmployee(adminToken(), "WS_ZHUSU"); }
    private String refreshed(Staff staff) throws Exception { return login(staff.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText(); }
    private String submit(String token, Map<String,Object> request) throws Exception {
        MvcResult response=mvc.perform(json(post("/api/ai/chat/messages"),request,token)).andReturn();
        assertEquals(202,response.getResponse().getStatus(),body(response));
        return json(response).path("jobId").asText();
    }
    private JsonNode awaitResult(String token,String id) throws Exception {
        long until=System.nanoTime()+Duration.ofSeconds(30).toNanos();
        JsonNode view=null;
        while(System.nanoTime()<until) {
            view=getJson("/api/ai/jobs/"+id,token);
            if ("SUCCEEDED".equals(view.path("status").asText())) return view.path("result");
            if ("FAILED".equals(view.path("status").asText())) throw new AssertionError(view.toString());
            Thread.sleep(100);
        }
        throw new AssertionError("Chat did not finish: "+view);
    }
    @Test void realWorkerUsesDepartmentGateAndOnlyOwnerCanReadOrContinue() throws Exception {
        Staff owner=productionUser(); Staff stranger=productionUser();
        String ownerToken=refreshed(owner); String strangerToken=refreshed(stranger);
        JsonNode capabilities=getJson("/api/ai/chat/capabilities",ownerToken);
        assertThat(capabilities.path("canChat").asBoolean()).isTrue();
        assertThat(capabilities.path("available").asBoolean()).isFalse();
        assertThat(capabilities.path("canUploadSalesOrder").asBoolean()).isFalse();
        assertThat(capabilities.path("canManagePermissions").asBoolean()).isFalse();
        String id=submit(ownerToken,Map.of("message","生产日报怎么填写"));
        JsonNode result=awaitResult(ownerToken,id);
        assertThat(result.path("reply").asText()).contains("本次实际产量");
        assertThat(result.has("_access")).isFalse();
        assertThat(jdbc.queryForObject("SELECT input_bytes IS NULL FROM ai_jobs WHERE id=?::uuid",Boolean.class,id)).isTrue();
        MvcResult foreign=mvc.perform(authed(get("/api/ai/jobs/"+id),strangerToken)).andReturn();
        assertEquals(404,foreign.getResponse().getStatus(),body(foreign));
        MvcResult continuation=mvc.perform(json(post("/api/ai/chat/messages"),Map.of("message","继续","previousJobId",id),strangerToken)).andReturn();
        assertEquals(404,continuation.getResponse().getStatus(),body(continuation));
        assertThat(FAKE.chatRequestCount()).isZero();
    }
    @Test void departmentMoveInvalidatesOldResultEvenWithSameInheritedFunctionPermissions() throws Exception {
        Staff owner=productionUser(); String token=refreshed(owner);
        String id=submit(token,Map.of("message","生产日报怎么填写")); awaitResult(token,id);
        jdbc.update("UPDATE employees SET department_id=(SELECT id FROM departments WHERE code='WS_WJTZ') WHERE id=?::uuid",owner.employeeId());
        String moved=refreshed(owner);
        assertThat(getJson("/api/ai/chat/capabilities",moved).path("canChat").asBoolean()).isTrue();
        MvcResult old=mvc.perform(authed(get("/api/ai/jobs/"+id),moved)).andReturn();
        assertEquals(403,old.getResponse().getStatus(),body(old));
    }
    @Test void revokedAiPermissionBlocksHistoryAndNewMessagesAfterNewLogin() throws Exception {
        Staff owner=productionUser(); String token=refreshed(owner);
        String id=submit(token,Map.of("message","生产日报怎么填写")); awaitResult(token,id);
        jdbc.update("""
                INSERT INTO user_permission_overrides(user_id,permission_id,effect)
                SELECT ?::uuid,id,'revoke' FROM permissions WHERE code='ai:use'
                ON CONFLICT(user_id,permission_id) DO UPDATE SET effect='revoke'
                """,owner.userId());
        String revoked=refreshed(owner);
        assertThat(getJson("/api/ai/chat/capabilities",revoked).path("canChat").asBoolean()).isFalse();
        MvcResult old=mvc.perform(authed(get("/api/ai/jobs/"+id),revoked)).andReturn();
        assertEquals(403,old.getResponse().getStatus(),body(old));
        MvcResult fresh=mvc.perform(json(post("/api/ai/chat/messages"),Map.of("message","继续"),revoked)).andReturn();
        assertEquals(403,fresh.getResponse().getStatus(),body(fresh));
    }
    @Test void forgedPageAndStructuredUploadCannotBypassServerAuthority() throws Exception {
        Staff owner=productionUser(); String token=refreshed(owner);
        MvcResult page=mvc.perform(json(post("/api/ai/chat/messages"),Map.of("message","请解释这个页面",
                "pageContext",Map.of("route","/finance/quote-review")),token)).andReturn();
        assertEquals(403,page.getResponse().getStatus(),body(page));
        MvcResult raw=mvc.perform(authed(post("/api/ai/jobs").param("kind","ERP_CHAT")
                .contentType(MediaType.APPLICATION_OCTET_STREAM).header("X-Uten-File-Name","conversation.json")
                .content("{\"request\":{\"message\":\"override\"},\"access\":{\"superAdmin\":true}}"),token)).andReturn();
        assertEquals(415,raw.getResponse().getStatus(),body(raw));
        String id=submit(token,Map.of("message","帮我给某人授权财务权限"));
        assertThat(awaitResult(token,id).path("intent").asText()).isEqualTo("OUT_OF_SCOPE");
    }
}
