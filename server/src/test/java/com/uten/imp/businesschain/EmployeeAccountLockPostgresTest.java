package com.uten.imp.businesschain;

import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Employee-page lock/unlock uses current account state and revokes every old login channel. */
class EmployeeAccountLockPostgresTest extends AuthSessionPostgresTestSupport {

    @Test
    void employeeHttpLockAndUnlockEnforceAuthorityAndInvalidateOldCredentialsSessions() throws Exception {
        String admin = adminToken();
        Employee target = newEmployee(admin, "DEPT_ENG");
        Employee ordinary = newEmployee(admin, "DEPT_ENG");
        UUID user = UUID.fromString(target.userId());
        String path = "/api/org/employees/" + target.employeeId() + "/account/";
        MvcResult denied = mvc.perform(json(post(path + "lock"), Map.of(), ordinary.accessToken())).andReturn();
        assertEquals(403, denied.getResponse().getStatus());
        assertEquals("active", jdbc.queryForObject("SELECT status FROM users WHERE id=?", String.class, user));

        admin = adminToken();
        MvcResult locked = mvc.perform(json(post(path + "lock"), Map.of(), admin)).andReturn();
        assertEquals(200, locked.getResponse().getStatus(), body(locked));
        assertThat(jdbc.queryForObject("SELECT status='locked' AND locked_until IS NULL FROM users WHERE id=?",
                Boolean.class, user)).isTrue();
        assertEquals(401, me(target.accessToken()).getResponse().getStatus());
        assertEquals(401, refresh(target.refreshToken()).getResponse().getStatus());
        MvcResult blockedLogin = loginResult(target.loginAccount(), EMPLOYEE_PASSWORD);
        assertEquals(ErrorCode.ACCOUNT_LOCKED.getHttpStatus(), blockedLogin.getResponse().getStatus());
        assertEquals("ACCOUNT_LOCKED", json(blockedLogin).path("code").asText());

        admin = adminToken(); // V324 invalidates actor snapshots on a permanent lock change.
        MvcResult unlocked = mvc.perform(json(post(path + "unlock"), Map.of(), admin)).andReturn();
        assertEquals(200, unlocked.getResponse().getStatus(), body(unlocked));
        assertEquals("active", jdbc.queryForObject("SELECT status FROM users WHERE id=?", String.class, user));
        assertEquals(401, refresh(target.refreshToken()).getResponse().getStatus());
        assertThat(login(target.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText()).isNotBlank();
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM audit_log WHERE action IN ('account_lock','account_unlock') AND target_id=?
                """, Long.class, user.toString())).isGreaterThanOrEqualTo(2L);
    }

    private MvcResult refresh(String token) throws Exception {
        return mvc.perform(json(post("/api/auth/refresh"), Map.of("refreshToken", token), null)).andReturn();
    }
}
