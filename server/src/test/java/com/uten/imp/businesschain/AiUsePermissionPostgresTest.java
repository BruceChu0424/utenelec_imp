package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/** AI 使用权只复用公共页面授权，不授予业务或模型/密钥管理权限。 */
class AiUsePermissionPostgresTest extends AuthSessionPostgresTestSupport {
    private static final String SURFACE = "system.ai-assistant";

    @Test
    void explicitGrantEnablesChatAndRevocationClosesTheExistingSession() throws Exception {
        String admin = adminToken();
        Employee employee = newEmployee(admin, "DEPT_ENG");
        assertEquals(Boolean.FALSE, jdbc.queryForObject(
                "SELECT baseline FROM permissions WHERE code='ai:use'", Boolean.class));
        assertFalse(canChat(employee.accessToken()));
        assertEquals(403, mvc.perform(json(post("/api/ai/chat/messages"),
                Map.of("message", "怎么填写生产日报"), employee.accessToken())).andReturn().getResponse().getStatus());

        JsonNode before = detail(admin, employee);
        assertEquals("CENTRAL_OVERRIDE", before.path("settingMode").asText());
        assertEquals(1, before.path("groups").size());
        assertEquals(1, before.path("groups").get(0).path("permissions").size());
        assertEquals("ai:use", permission(before).path("code").asText());
        assertFalse(permission(before).path("effective").asBoolean());
        assertTrue(permission(before).path("description").asText().contains("业务权限"));
        setAi(admin, employee, true, permission(before).path("rowVersion").asLong());
        admin = adminToken(); // 中央授权推进全局授权代际，管理人的旧访问令牌也须刷新。

        String granted = login(employee.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
        assertTrue(canChat(granted));
        JsonNode me = json(me(granted));
        assertTrue(me.path("permissions").toString().contains("ai:use"));
        assertFalse(me.path("permissions").toString().contains("authorization:manage"));
        assertEquals(403, mvc.perform(get("/api/admin/ai/providers")
                .header("Authorization", "Bearer " + granted)).andReturn().getResponse().getStatus());
        assertEquals(403, mvc.perform(json(put(endpoint(employee)), Map.of("changes", List.of(
                Map.of("code", "authorization:manage", "enabled", true, "expectedVersion", 0))), admin)
                .param("surfaceKey", SURFACE).param("departmentId", department(employee)))
                .andReturn().getResponse().getStatus(), "AI scope cannot carry system-management grants");

        MvcResult accepted = mvc.perform(json(post("/api/ai/chat/messages"),
                Map.of("message", "怎么填写生产日报"), granted)).andReturn();
        assertEquals(202, accepted.getResponse().getStatus(), body(accepted));
        String jobId = json(accepted).path("jobId").asText();
        assertFalse(jobId.isBlank());

        JsonNode enabled = detail(admin, employee);
        assertTrue(permission(enabled).path("effective").asBoolean());
        setAi(admin, employee, false, permission(enabled).path("rowVersion").asLong());
        assertEquals(401, mvc.perform(json(post("/api/ai/chat/messages"),
                Map.of("message", "继续"), granted)).andReturn().getResponse().getStatus(),
                "the token held before revocation must fail the authorization-version check");
        String revoked = login(employee.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
        assertFalse(canChat(revoked));
        assertEquals(403, mvc.perform(json(post("/api/ai/chat/messages"),
                Map.of("message", "继续"), revoked)).andReturn().getResponse().getStatus());
        assertEquals(403, mvc.perform(get("/api/ai/jobs/" + jobId)
                .header("Authorization", "Bearer " + revoked)).andReturn().getResponse().getStatus());
        assertEquals("revoke", permission(detail(adminToken(), employee)).path("configuredEffect").asText());
    }

    @Test
    void existingDepartmentGrantRemainsEffectiveAndIndividualRevokeStillWins() throws Exception {
        String departmentCode = jdbc.queryForObject("""
                SELECT department.code FROM department_permissions granted
                JOIN departments department ON department.id=granted.department_id
                JOIN permissions permission ON permission.id=granted.permission_id
                WHERE permission.code='ai:use' AND NOT department.is_deleted
                ORDER BY department.code LIMIT 1
                """, String.class);
        String admin = adminToken();
        Employee employee = newEmployee(admin, departmentCode);
        assertTrue(canChat(employee.accessToken()), "V821 must preserve earlier explicit department grants");
        JsonNode before = detail(admin, employee);
        assertTrue(permission(before).path("targetBaseEffective").asBoolean());
        setAi(admin, employee, false, permission(before).path("rowVersion").asLong());
        String revoked = login(employee.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
        assertFalse(canChat(revoked));
        assertEquals("revoke", permission(detail(adminToken(), employee)).path("configuredEffect").asText());
    }

    private boolean canChat(String token) throws Exception {
        MvcResult result = mvc.perform(get("/api/ai/chat/capabilities")
                .header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result).path("canChat").asBoolean();
    }

    private JsonNode detail(String token, Employee employee) throws Exception {
        MvcResult result = mvc.perform(get(endpoint(employee)).param("surfaceKey", SURFACE)
                .param("departmentId", department(employee)).header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result);
    }

    private void setAi(String token, Employee employee, boolean enabled, long version) throws Exception {
        MvcResult result = mvc.perform(json(put(endpoint(employee)), Map.of("changes", List.of(
                Map.of("code", "ai:use", "enabled", enabled, "expectedVersion", version))), token)
                .param("surfaceKey", SURFACE).param("departmentId", department(employee))).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
    }

    private static JsonNode permission(JsonNode detail) {
        return detail.path("groups").get(0).path("permissions").get(0);
    }

    private String department(Employee employee) {
        return jdbc.queryForObject("SELECT department_id::text FROM employees WHERE id=?::uuid",
                String.class, employee.employeeId());
    }

    private static String endpoint(Employee employee) {
        return "/api/department-staff-permissions/employees/" + employee.employeeId() + "/permissions";
    }
}
