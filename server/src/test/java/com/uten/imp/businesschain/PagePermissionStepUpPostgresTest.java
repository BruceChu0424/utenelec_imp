package com.uten.imp.businesschain;

import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/** 高危页面授权必须与系统权限保存共用本人、本会话、一次性再认证门。 */
class PagePermissionStepUpPostgresTest extends AuthSessionPostgresTestSupport {
    @Test
    void assetDeleteGrantCannotBypassStepUpThroughThePageScope() throws Exception {
        String admin = adminToken();
        Employee target = newEmployee(admin, "DEPT_ENG");
        String department = jdbc.queryForObject("SELECT department_id::text FROM employees WHERE id=?::uuid",
                String.class, target.employeeId());
        MvcResult result = mvc.perform(json(put("/api/department-staff-permissions/employees/"
                        + target.employeeId() + "/permissions"),
                Map.of("changes", List.of(Map.of("code", "finance_asset:delete", "enabled", true,
                        "expectedVersion", 0))), admin)
                .param("surfaceKey", "finance.asset").param("departmentId", department)).andReturn();
        assertEquals(403, result.getResponse().getStatus(), body(result));
        assertEquals("REAUTH_REQUIRED", json(result).path("code").asText());
        assertEquals(0, jdbc.queryForObject("""
                SELECT count(*) FROM user_permission_overrides overrides
                JOIN permissions permission ON permission.id=overrides.permission_id
                WHERE overrides.user_id=?::uuid AND permission.code='finance_asset:delete'
                """, Integer.class, target.userId()));

        requireReauthentication(change(admin, target, true, 0, "wrong-token"));
        String foreign = stepUp(target.accessToken(), EMPLOYEE_PASSWORD);
        requireReauthentication(change(admin, target, true, 0, foreign));

        String otherSession = stepUp(admin, ADMIN_PASSWORD);
        admin = adminToken(); // 同账号重新登录会使旧会话失效；在新会话中尝试使用旧会话凭证。
        requireReauthentication(change(admin, target, true, 0, otherSession));

        String expired = stepUp(admin, ADMIN_PASSWORD);
        jdbc.update("UPDATE auth_sessions SET step_up_expires_at=now()-interval '1 minute' WHERE step_up_token_hash=?",
                com.uten.imp.common.util.HashUtil.sha256(expired));
        requireReauthentication(change(admin, target, true, 0, expired));
        assertEquals(0, overrides(target));
        assertEquals(0, auditChanges(target));

        String proof = stepUp(admin, ADMIN_PASSWORD);
        MvcResult granted = change(admin, target, true, 0, proof);
        assertEquals(200, granted.getResponse().getStatus(), body(granted));
        assertEquals("grant", effect(target));
        assertEquals(1, overrides(target));
        assertEquals(0, jdbc.queryForObject(
                "SELECT count(*) FROM auth_sessions WHERE step_up_token_hash=?", Integer.class,
                com.uten.imp.common.util.HashUtil.sha256(proof)));

        String refreshedAdmin = adminToken();
        requireReauthentication(change(refreshedAdmin, target, false, 1, null));
        assertEquals("grant", effect(target));
        MvcResult revoked = change(refreshedAdmin, target, false, 1, stepUp(refreshedAdmin, ADMIN_PASSWORD));
        assertEquals(200, revoked.getResponse().getStatus(), body(revoked));
        assertEquals("revoke", effect(target));
        assertEquals(2, auditChanges(target));
    }

    @Test
    void restrictedGrantPolicyCannotHideBehindTheLegacyLowRiskFlagAndTheBatchIsAtomic() throws Exception {
        String admin = adminToken();
        Employee target = newEmployee(admin, "DEPT_ENG");
        assertEquals(Boolean.FALSE, jdbc.queryForObject(
                "SELECT high_risk FROM permissions WHERE code='goods:cost:edit'", Boolean.class));
        MvcResult result = mvc.perform(json(put(endpoint(target)), Map.of("changes", List.of(
                Map.of("code", "goods:view", "enabled", true, "expectedVersion", 0),
                Map.of("code", "goods:cost:edit", "enabled", true, "expectedVersion", 0))), admin)
                .param("surfaceKey", "basic.goods").param("departmentId", department(target))).andReturn();
        requireReauthentication(result);
        assertEquals(0, overrides(target), "a mixed request cannot partially apply the ordinary row");
    }

    @Test
    void anOrganizationManagerCannotDelegateAssetDeleteEvenWithStepUp() throws Exception {
        Employee manager = newEmployee(adminToken(), "DEPT_ENG");
        Employee target = newEmployee(adminToken(), "DEPT_ENG");
        String department = department(manager);
        String previousManager = jdbc.queryForObject("SELECT manager_id::text FROM departments WHERE id=?::uuid",
                String.class, department);
        String admin = adminToken();
        assertEquals(200, change(admin, manager, true, 0, stepUp(admin, ADMIN_PASSWORD))
                .getResponse().getStatus());
        jdbc.update("UPDATE departments SET manager_id=?::uuid WHERE id=?::uuid", manager.employeeId(), department);
        try {
            String managerToken = login(manager.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
            MvcResult rejected = change(managerToken, target, true, 0, stepUp(managerToken, EMPLOYEE_PASSWORD));
            assertEquals(403, rejected.getResponse().getStatus(), body(rejected));
            assertEquals("FORBIDDEN", json(rejected).path("code").asText());
            assertTrue(json(rejected).path("message").asText().contains("不能"));
            assertEquals(0, overrides(target));
            assertEquals(0, jdbc.queryForObject(
                    "SELECT count(*) FROM manager_permission_delegations WHERE user_id=?::uuid",
                    Integer.class, target.userId()));
        } finally {
            jdbc.update("UPDATE departments SET manager_id=?::uuid WHERE id=?::uuid", previousManager, department);
        }
    }

    private MvcResult change(String token, Employee target, boolean enabled, int version, String stepUp) throws Exception {
        MockHttpServletRequestBuilder request = json(put(endpoint(target)), Map.of("changes", List.of(
                Map.of("code", "finance_asset:delete", "enabled", enabled, "expectedVersion", version))), token)
                .param("surfaceKey", "finance.asset").param("departmentId", department(target));
        if (stepUp != null) request.header("X-Uten-Step-Up", stepUp);
        return mvc.perform(request).andReturn();
    }

    private void requireReauthentication(MvcResult result) throws Exception {
        assertEquals(403, result.getResponse().getStatus(), body(result));
        assertEquals("REAUTH_REQUIRED", json(result).path("code").asText());
    }

    private int overrides(Employee target) {
        return jdbc.queryForObject("SELECT count(*) FROM user_permission_overrides WHERE user_id=?::uuid",
                Integer.class, target.userId());
    }

    private String effect(Employee target) {
        return jdbc.queryForObject("""
                SELECT overrides.effect FROM user_permission_overrides overrides
                JOIN permissions permission ON permission.id=overrides.permission_id
                WHERE overrides.user_id=?::uuid AND permission.code='finance_asset:delete'
                """, String.class, target.userId());
    }

    private int auditChanges(Employee target) {
        return jdbc.queryForObject("""
                SELECT count(*) FROM audit_log
                WHERE action='user_permission_override_change' AND target_id=?
                """, Integer.class, target.userId());
    }

    private String department(Employee target) {
        return jdbc.queryForObject("SELECT department_id::text FROM employees WHERE id=?::uuid",
                String.class, target.employeeId());
    }

    private static String endpoint(Employee target) {
        return "/api/department-staff-permissions/employees/" + target.employeeId() + "/permissions";
    }
}
