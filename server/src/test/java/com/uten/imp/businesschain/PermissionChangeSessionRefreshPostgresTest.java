package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.security.JwtService;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/** Real HTTP + JWT filter + PostgreSQL: assignment invalidates authority, not login identity. */
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class PermissionChangeSessionRefreshPostgresTest extends AuthSessionPostgresTestSupport {
    private static final String ACTION = "sales_order_finance:confirm";
    private static final String VIEW = "sales_order_finance:view";
    @Autowired JwtService jwt;

    enum Source { PERSONAL, DEPARTMENT, BASELINE, CENTRAL_PAGE, MANAGER_PAGE }

    @ParameterizedTest
    @EnumSource(Source.class)
    void grantAndRevokeImmediatelyRejectOldAccessButTheSameSessionRefreshesIntoCurrentAuthority(Source source) throws Exception {
        Employee target = newEmployee(adminToken(), "DEPT_ENG");
        String department = department(target);
        List<String> originalDepartment = departmentCodes(department);
        List<String> originalBaseline = jdbc.queryForList("SELECT code FROM permissions WHERE baseline ORDER BY code", String.class);
        String originalManager = jdbc.queryForObject("SELECT manager_id::text FROM departments WHERE id=?::uuid", String.class, department);
        Employee manager = null;
        try {
            if (source == Source.MANAGER_PAGE) {
                manager = newEmployee(adminToken(), "DEPT_ENG");
                changePersonal(manager, true);
                jdbc.update("UPDATE departments SET manager_id=?::uuid WHERE id=?::uuid", manager.employeeId(), department);
            }
            Tokens initial = tokens(login(target.loginAccount(), EMPLOYEE_PASSWORD));
            assertEquals(200, me(initial.access()).getResponse().getStatus());
            assertFalse(profilePermissions(initial.access()).contains(ACTION));
            String sessionId = jwt.parse(initial.access()).get("sid", String.class);

            change(source, target, manager, true, originalDepartment, originalBaseline);

            assertEquals(401, me(initial.access()).getResponse().getStatus(), "a stale access token must never keep old authority");
            Tokens granted = refresh(initial.refresh());
            assertEquals(sessionId, jwt.parse(granted.access()).get("sid", String.class), "permission assignment preserves the login session");
            assertTrue(profilePermissions(granted.access()).containsAll(Set.of(ACTION, VIEW)));
            assertEquals(200, mvc.perform(get("/api/sales/orders/finance-confirmation/count")
                    .header("Authorization", "Bearer " + granted.access())).andReturn().getResponse().getStatus());

            change(source, target, manager, false, originalDepartment, originalBaseline);

            assertEquals(401, me(granted.access()).getResponse().getStatus(), "revocation is immediate for previously issued access");
            Tokens revoked = refresh(granted.refresh());
            assertEquals(sessionId, jwt.parse(revoked.access()).get("sid", String.class));
            assertFalse(profilePermissions(revoked.access()).contains(ACTION), "refresh may not restore a removed action");
            MvcResult decision = mvc.perform(json(post("/api/sales/orders/" + UUID.randomUUID() + "/finance-confirmation"),
                    Map.of(), revoked.access())).andReturn();
            assertEquals(403, decision.getResponse().getStatus(), "current read-only/no-action session cannot make a financial decision");
        } finally {
            if (source == Source.DEPARTMENT) restoreDepartment(department, originalDepartment);
            if (source == Source.BASELINE) restoreBaseline(originalBaseline);
            if (source == Source.MANAGER_PAGE) {
                jdbc.update("UPDATE departments SET manager_id=?::uuid WHERE id=?::uuid", originalManager, department);
            }
        }
    }

    @Test
    void disablingTheAccountStillRevokesItsLoginSessionAndRefreshCredentials() throws Exception {
        Employee target = newEmployee(adminToken(), "DEPT_ENG");
        Tokens active = tokens(login(target.loginAccount(), EMPLOYEE_PASSWORD));
        String administrator = adminToken();
        MvcResult disabled = mvc.perform(json(post("/api/admin/users/" + target.userId() + "/disable"), Map.of(), administrator)).andReturn();
        assertEquals(200, disabled.getResponse().getStatus(), body(disabled));
        assertEquals(401, me(active.access()).getResponse().getStatus());
        assertEquals(401, refreshResult(active.refresh()).getResponse().getStatus());
    }

    @Test
    void administratorPasswordResetStillEndsTheOldSessionAndCannotBeBypassedWithRefresh() throws Exception {
        Employee target = newEmployee(adminToken(), "DEPT_ENG");
        Tokens active = tokens(login(target.loginAccount(), EMPLOYEE_PASSWORD));
        String administrator = adminToken();
        MvcResult reset = mvc.perform(json(post("/api/admin/users/" + target.userId() + "/reset-password"), Map.of(), administrator)
                .header("X-Uten-Step-Up", stepUp(administrator, ADMIN_PASSWORD))).andReturn();
        assertEquals(200, reset.getResponse().getStatus());
        assertEquals(401, me(active.access()).getResponse().getStatus());
        assertEquals(401, refreshResult(active.refresh()).getResponse().getStatus());
        assertEquals(Boolean.TRUE, jdbc.queryForObject("SELECT must_change_password FROM users WHERE id=?::uuid", Boolean.class, target.userId()));
    }

    private void change(Source source, Employee target, Employee manager, boolean enabled,
            List<String> originalDepartment, List<String> originalBaseline) throws Exception {
        if (source == Source.PERSONAL) {
            changePersonal(target, enabled);
            return;
        }
        if (source == Source.CENTRAL_PAGE || source == Source.MANAGER_PAGE) {
            Employee actor = source == Source.MANAGER_PAGE ? manager : null;
            String token = actor == null ? adminToken() : login(actor.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
            String password = actor == null ? ADMIN_PASSWORD : EMPLOYEE_PASSWORD;
            String surface = jdbc.queryForObject("""
                    SELECT surface.surface_key FROM permission_surface_permissions mapping
                    JOIN permission_surfaces surface ON surface.id=mapping.surface_id AND surface.enabled
                    JOIN permissions permission ON permission.id=mapping.permission_id
                    WHERE permission.code=? ORDER BY surface.surface_key LIMIT 1
                    """, String.class, ACTION);
            long version = jdbc.queryForObject(source == Source.MANAGER_PAGE ? """
                    SELECT COALESCE((SELECT delegation.row_version FROM manager_permission_delegations delegation
                    JOIN permissions permission ON permission.id=delegation.permission_id
                    WHERE delegation.user_id=?::uuid AND permission.code=?),0)
                    """ : """
                    SELECT COALESCE((SELECT allocation.row_version FROM user_permission_overrides allocation
                    JOIN permissions permission ON permission.id=allocation.permission_id
                    WHERE allocation.user_id=?::uuid AND permission.code=?),0)
                    """, Long.class, target.userId(), ACTION);
            MockHttpServletRequestBuilder request = json(put("/api/department-staff-permissions/employees/"
                    + target.employeeId() + "/permissions"), Map.of("changes", List.of(Map.of(
                            "code", ACTION, "enabled", enabled, "expectedVersion", version))), token)
                    .param("surfaceKey", surface).param("departmentId", department(target))
                    .header("X-Uten-Step-Up", stepUp(token, password));
            MvcResult result = mvc.perform(request).andReturn();
            assertEquals(200, result.getResponse().getStatus(), body(result));
            return;
        }
        String token = adminToken();
        Set<String> codes = new LinkedHashSet<>(source == Source.BASELINE ? originalBaseline : originalDepartment);
        if (enabled) codes.add(ACTION);
        String endpoint = source == Source.BASELINE ? "/api/admin/permission-baseline"
                : "/api/admin/departments/" + department(target) + "/permissions";
        MvcResult result = mvc.perform(json(put(endpoint), Map.of("permissions", new ArrayList<>(codes)), token)
                .header("X-Uten-Step-Up", stepUp(token, ADMIN_PASSWORD))).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
    }

    private void changePersonal(Employee target, boolean enabled) throws Exception {
        String token = adminToken();
        MvcResult result = mvc.perform(json(put("/api/admin/users/" + target.userId() + "/permission-overrides"),
                Map.of("grants", enabled ? List.of(ACTION) : List.of(),
                        "revokes", enabled ? List.of() : List.of(ACTION)), token)
                .header("X-Uten-Step-Up", stepUp(token, ADMIN_PASSWORD))).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
    }

    private Set<String> profilePermissions(String access) throws Exception {
        MvcResult result = me(access);
        assertEquals(200, result.getResponse().getStatus(), body(result));
        Set<String> permissions = new LinkedHashSet<>();
        json(result).path("permissions").forEach(value -> permissions.add(value.asText()));
        return permissions;
    }

    private Tokens refresh(String refresh) throws Exception {
        MvcResult result = refreshResult(refresh);
        assertEquals(200, result.getResponse().getStatus(), "an active login session must refresh after an ordinary permission change");
        return tokens(json(result));
    }
    private MvcResult refreshResult(String refresh) throws Exception {
        return mvc.perform(json(post("/api/auth/refresh"), Map.of("refreshToken", refresh), null)).andReturn();
    }
    private Tokens tokens(JsonNode value) { return new Tokens(value.path("accessToken").asText(), value.path("refreshToken").asText()); }
    private record Tokens(String access, String refresh) {}
    private String department(Employee target) {
        return jdbc.queryForObject("SELECT department_id::text FROM employees WHERE id=?::uuid", String.class, target.employeeId());
    }
    private List<String> departmentCodes(String department) {
        return jdbc.queryForList("SELECT permission.code FROM department_permissions allocation JOIN permissions permission ON permission.id=allocation.permission_id WHERE allocation.department_id=?::uuid ORDER BY permission.code", String.class, department);
    }
    private void restoreDepartment(String department, List<String> original) {
        jdbc.update("DELETE FROM department_permissions WHERE department_id=?::uuid", department);
        for (String code : original) jdbc.update("INSERT INTO department_permissions(department_id,permission_id) SELECT ?::uuid,id FROM permissions WHERE code=?", department, code);
    }
    private void restoreBaseline(List<String> original) {
        Set<String> keep = Set.copyOf(original);
        for (String code : jdbc.queryForList("SELECT code FROM permissions WHERE baseline", String.class)) {
            if (!keep.contains(code)) jdbc.update("UPDATE permissions SET baseline=false WHERE code=?", code);
        }
    }
}
