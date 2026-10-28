package com.uten.imp.businesschain;

import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

import java.sql.Timestamp;
import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/** 高危页面授权与系统权限保存共用本人、本会话、空闲五分钟失效的再认证。 */
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
        expireStepUpProof(expired);
        requireReauthentication(change(admin, target, true, 0, expired));
        assertEquals(0, overrides(target));
        assertEquals(0, auditChanges(target));

        String proof = stepUp(admin, ADMIN_PASSWORD);
        MvcResult granted = change(admin, target, true, 0, proof);
        assertEquals(200, granted.getResponse().getStatus(), body(granted));
        assertEquals("grant", effect(target));
        assertEquals(List.of("finance_asset:delete=grant", "finance_asset:view=grant"),
                activeOverrideEffects(target));
        assertEquals(1, jdbc.queryForObject(
                "SELECT count(*) FROM auth_sessions WHERE step_up_token_hash=?", Integer.class,
                com.uten.imp.common.util.HashUtil.sha256(proof)));

        String refreshedAdmin = adminToken();
        requireReauthentication(change(refreshedAdmin, target, false, 1, null));
        assertEquals("grant", effect(target));
        MvcResult revoked = change(refreshedAdmin, target, false, 1, stepUp(refreshedAdmin, ADMIN_PASSWORD));
        assertEquals(200, revoked.getResponse().getStatus(), body(revoked));
        assertEquals("revoke", effect(target));
        assertEquals(List.of("finance_asset:delete=revoke", "finance_asset:view=grant"),
                activeOverrideEffects(target));
        assertEquals(2, auditChanges(target));
    }

    @Test
    void expiredProofIsRejectedWhenTheSessionClockLagsTheDatabaseClock() throws Exception {
        Instant originalTime = clock.instant();
        Instant databaseTime = jdbc.queryForObject("SELECT now()", OffsetDateTime.class).toInstant();
        // A slow context startup leaves the fixed session clock behind PostgreSQL's wall clock.
        // Make that difference explicit so the expiry scenario never depends on machine speed.
        clock.advance(Duration.between(originalTime, databaseTime.minus(Duration.ofMinutes(10))));
        try {
            String admin = adminToken();
            Employee target = newEmployee(admin, "DEPT_ENG");
            String expired = stepUp(admin, ADMIN_PASSWORD);
            expireStepUpProof(expired);

            requireReauthentication(change(admin, target, true, 0, expired));
            assertEquals(0, overrides(target));
            assertEquals(0, auditChanges(target));
        } finally {
            clock.advance(Duration.between(clock.instant(), originalTime));
        }
    }

    @Test
    void restrictedGrantPolicyCannotHideBehindTheLegacyLowRiskFlagAndTheBatchIsAtomic() throws Exception {
        String admin = adminToken();
        Employee target = newEmployee(admin, "DEPT_ENG");
        assertEquals(Boolean.FALSE, jdbc.queryForObject(
                "SELECT high_risk FROM permissions WHERE code='goods:cost:edit'", Boolean.class));
        // Establish the sensitive read through a separate, explicitly authenticated grant.
        // The following request then isolates cost:edit's policy from the read's own policy.
        MvcResult readGranted = mvc.perform(json(put(endpoint(target)), Map.of("changes", List.of(
                Map.of("code", "goods:cost:view", "enabled", true, "expectedVersion", 0))), admin)
                .param("surfaceKey", "basic.goods").param("departmentId", department(target))
                .header("X-Uten-Step-Up", stepUp(admin, ADMIN_PASSWORD))).andReturn();
        assertEquals(200, readGranted.getResponse().getStatus(), body(readGranted));
        assertEquals(List.of("goods:cost:view=grant"), activeOverrideEffects(target));
        int existingOverrides = overrides(target), existingAudits = auditChanges(target);
        admin = adminToken();
        MvcResult currentAdmin = me(admin);
        assertEquals(200, currentAdmin.getResponse().getStatus(), body(currentAdmin));

        MvcResult result = mvc.perform(json(put(endpoint(target)), Map.of("changes", List.of(
                Map.of("code", "goods:view", "enabled", true, "expectedVersion", 0),
                Map.of("code", "goods:cost:edit", "enabled", true, "expectedVersion", 0))), admin)
                .param("surfaceKey", "basic.goods").param("departmentId", department(target))).andReturn();
        requireReauthentication(result);
        assertEquals(List.of("goods:cost:view=grant"), activeOverrideEffects(target));
        assertEquals(existingOverrides, overrides(target), "a mixed request cannot partially apply the ordinary row");
        assertEquals(existingAudits, auditChanges(target), "the refused mixed request must add no authorization audit");
    }

    @Test
    void aMissingSensitiveCostReadCannotBeSilentlyGrantedWithoutStepUp() throws Exception {
        String admin = adminToken();
        Employee target = newEmployee(admin, "DEPT_ENG");
        MvcResult before = me(target.accessToken());
        assertEquals(200, before.getResponse().getStatus(), body(before));
        assertFalse(json(before).path("permissions").toString().contains("\"goods:cost:view\""));

        MvcResult rejected = mvc.perform(json(put(endpoint(target)), Map.of("changes", List.of(
                Map.of("code", "goods:view", "enabled", true, "expectedVersion", 0),
                Map.of("code", "goods:cost:edit", "enabled", true, "expectedVersion", 0))), admin)
                .param("surfaceKey", "basic.goods").param("departmentId", department(target))).andReturn();

        assertEquals(400, rejected.getResponse().getStatus(), body(rejected));
        assertEquals("BUSINESS", json(rejected).path("code").asText());
        assertTrue(json(rejected).path("message").asText().contains("查看货品成本"));
        assertEquals(0, overrides(target), "neither the ordinary row nor the sensitive read may be partially granted");
        assertEquals(0, auditChanges(target));
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

    private void expireStepUpProof(String proof) {
        // AuthSessionService compares expiry with the injected clock, not database now().
        assertEquals(1, jdbc.update(
                "UPDATE auth_sessions SET step_up_expires_at=? WHERE step_up_token_hash=?",
                Timestamp.from(clock.instant().minusSeconds(1)),
                com.uten.imp.common.util.HashUtil.sha256(proof)));
    }

    private int overrides(Employee target) {
        return jdbc.queryForObject("SELECT count(*) FROM user_permission_overrides WHERE user_id=?::uuid",
                Integer.class, target.userId());
    }

    private List<String> activeOverrideEffects(Employee target) {
        return jdbc.queryForList("""
                SELECT permission.code || '=' || overrides.effect
                FROM user_permission_overrides overrides
                JOIN permissions permission ON permission.id=overrides.permission_id
                WHERE overrides.user_id=?::uuid AND overrides.active
                ORDER BY permission.code
                """, String.class, target.userId());
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
