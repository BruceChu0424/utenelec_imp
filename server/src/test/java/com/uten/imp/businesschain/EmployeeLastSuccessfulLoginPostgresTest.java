package com.uten.imp.businesschain;

import java.time.OffsetDateTime;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** The employee header reads committed successful-login facts, never session activity or reauthentication. */
class EmployeeLastSuccessfulLoginPostgresTest extends AuthSessionPostgresTestSupport {
    @Test
    void detailKeepsSuccessfulLoginTimestampAcrossActivityRefreshStepUpAndFailedCredentials() throws Exception {
        String administrator = adminToken();
        Employee employee = newEmployee(administrator);
        UUID accountId = UUID.fromString(employee.userId());
        OffsetDateTime previousLogin = OffsetDateTime.parse("2026-01-02T03:04:05Z");
        jdbc.update("UPDATE users SET last_login_at=? WHERE id=?", previousLogin, accountId);

        assertEquals(200, me(employee.accessToken()).getResponse().getStatus());
        var refreshed = mvc.perform(json(post("/api/auth/refresh"),
                Map.of("refreshToken", employee.refreshToken()), null)).andReturn();
        assertEquals(200, refreshed.getResponse().getStatus(), body(refreshed));
        String access = json(refreshed).path("accessToken").asText();
        assertEquals(200, stepUpResult(access, EMPLOYEE_PASSWORD).getResponse().getStatus());
        assertEquals(401, loginResult(employee.loginAccount(), "Wrong-Password-Only-For-Test!1").getResponse().getStatus());
        assertEquals(previousLogin.toInstant(), recordedLogin(accountId).toInstant());

        var before = mvc.perform(get("/api/org/employees/{id}", employee.employeeId())
                .header("Authorization", "Bearer " + administrator)).andReturn();
        assertEquals(200, before.getResponse().getStatus(), body(before));
        assertEquals(previousLogin.toInstant(), OffsetDateTime.parse(json(before).path("accountLastLoginAt").asText()).toInstant());

        login(employee.loginAccount(), EMPLOYEE_PASSWORD);
        OffsetDateTime successful = recordedLogin(accountId);
        assertNotNull(successful);
        assertTrue(successful.isAfter(previousLogin));
        var after = mvc.perform(get("/api/org/employees/{id}", employee.employeeId())
                .header("Authorization", "Bearer " + administrator)).andReturn();
        assertEquals(200, after.getResponse().getStatus(), body(after));
        assertEquals(successful.toInstant(), OffsetDateTime.parse(json(after).path("accountLastLoginAt").asText()).toInstant());
    }

    private OffsetDateTime recordedLogin(UUID accountId) {
        return jdbc.queryForObject("SELECT last_login_at FROM users WHERE id=?", OffsetDateTime.class, accountId);
    }
}
