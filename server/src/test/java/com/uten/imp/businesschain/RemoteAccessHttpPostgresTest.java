package com.uten.imp.businesschain;

import com.uten.imp.config.props.DeploymentProperties;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/**
 * Real migrations + HTTP filter chain. 外网访问的唯一闸门是 {@code users.remote_access}
 * (权限设置 → 按员工 → 云端(外网)访问授权)：授权后账号密码即可从远程入口登录，
 * 未授权/被收回在登录、刷新与每个已认证远程请求上都被拒绝。
 */
class RemoteAccessHttpPostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired DeploymentProperties deployment;
    private final List<UUID> targets = new ArrayList<>();

    @BeforeEach
    void configureTransport() {
        deployment.setRemoteIngressEnabled(true);
    }

    @AfterEach
    void resetTransport() {
        deployment.setRemoteIngressEnabled(false);
        targets.forEach(id -> jdbc.update("UPDATE users SET remote_access=false WHERE id=?", id));
    }

    @Test
    void remoteAccessGrantNeedsSuperAdministratorButNoLongerAStepUpPassword() throws Exception {
        String admin = adminToken();
        Employee employee = newEmployee(admin);
        UUID id = UUID.fromString(employee.userId());
        targets.add(id);
        // 开通外网授权：仍然仅超管可操作，但不再要求再输登录密码。
        var granted = mvc.perform(json(put("/api/admin/users/" + id + "/remote-access"),
                Map.of("remoteAccess", true), admin)).andReturn();
        assertEquals(200, granted.getResponse().getStatus(), body(granted));
        assertTrue(jdbc.queryForObject("SELECT remote_access FROM users WHERE id=?", Boolean.class, id));
        // 授权变更已 bump 目标账号 auth_version, 旧 token 失效; 用新 token 验证普通员工仍无权操作。
        String freshEmployeeToken = login(employee.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
        var forbidden = mvc.perform(json(put("/api/admin/users/" + id + "/remote-access"),
                Map.of("remoteAccess", false), freshEmployeeToken)).andReturn();
        assertEquals(403, forbidden.getResponse().getStatus(), body(forbidden));
    }

    @Test
    void unauthorizedRemoteLoginIsDeniedButTheOfficePathStaysOpen() throws Exception {
        String admin = adminToken();
        Employee employee = newEmployee(admin);
        UUID id = UUID.fromString(employee.userId());
        targets.add(id);
        var denied = mvc.perform(json(remote(post("/api/auth/login")),
                Map.of("loginAccount", employee.loginAccount(), "password", EMPLOYEE_PASSWORD), null)).andReturn();
        assertEquals(403, denied.getResponse().getStatus(), body(denied));
        assertEquals("REMOTE_ACCESS_DENIED", json(denied).path("code").asText());
        assertFalse(json(denied).has("accessToken"));
        var wrongPassword = mvc.perform(json(remote(post("/api/auth/login")),
                Map.of("loginAccount", employee.loginAccount(), "password", "wrong-password"), null)).andReturn();
        assertEquals(401, wrongPassword.getResponse().getStatus(), body(wrongPassword));
        assertEquals("BAD_CREDENTIALS", json(wrongPassword).path("code").asText());
        assertEquals(200, me(login(employee.loginAccount(), EMPLOYEE_PASSWORD)
                .path("accessToken").asText()).getResponse().getStatus(),
                "Office sign-in must stay open for an employee without remote access");
    }

    @Test
    void authorizedEmployeeSignsInRemotelyWithPasswordOnly() throws Exception {
        String admin = adminToken();
        Employee employee = newEmployee(admin);
        UUID id = UUID.fromString(employee.userId());
        targets.add(id);
        mvc.perform(json(put("/api/admin/users/" + id + "/remote-access"),
                Map.of("remoteAccess", true), admin)).andReturn();
        var signedIn = mvc.perform(json(remote(post("/api/auth/login")),
                Map.of("loginAccount", employee.loginAccount(), "password", EMPLOYEE_PASSWORD), null)).andReturn();
        assertEquals(200, signedIn.getResponse().getStatus(), body(signedIn));
        String remoteToken = json(signedIn).path("accessToken").asText();
        assertFalse(remoteToken.isBlank());
        var allowed = mvc.perform(remote(get("/api/auth/me"))
                .header("Authorization", "Bearer " + remoteToken)).andReturn();
        assertEquals(200, allowed.getResponse().getStatus(), body(allowed));
    }

    @Test
    void revokingRemoteAccessEndsTheRemoteSessionImmediately() throws Exception {
        String admin = adminToken();
        Employee employee = newEmployee(admin);
        UUID id = UUID.fromString(employee.userId());
        targets.add(id);
        mvc.perform(json(put("/api/admin/users/" + id + "/remote-access"),
                Map.of("remoteAccess", true), admin)).andReturn();
        var signedIn = mvc.perform(json(remote(post("/api/auth/login")),
                Map.of("loginAccount", employee.loginAccount(), "password", EMPLOYEE_PASSWORD), null)).andReturn();
        assertEquals(200, signedIn.getResponse().getStatus(), body(signedIn));
        String remoteToken = json(signedIn).path("accessToken").asText();
        String refreshToken = json(signedIn).path("refreshToken").asText();
        var revoked = mvc.perform(json(put("/api/admin/users/" + id + "/remote-access"),
                Map.of("remoteAccess", false), admin)).andReturn();
        assertEquals(200, revoked.getResponse().getStatus(), body(revoked));
        var rejected = mvc.perform(remote(get("/api/auth/me"))
                .header("Authorization", "Bearer " + remoteToken)).andReturn();
        assertEquals(401, rejected.getResponse().getStatus(), body(rejected));
        var rejectedRefresh = mvc.perform(json(remote(post("/api/auth/refresh")),
                Map.of("refreshToken", refreshToken), null)).andReturn();
        // 刷新事务对「授权被收回」的远程请求保留显式策略响应, 不误判为盗用重放。
        assertEquals(403, rejectedRefresh.getResponse().getStatus(), body(rejectedRefresh));
        assertEquals("REMOTE_ACCESS_DENIED", json(rejectedRefresh).path("code").asText());
    }

    @Test
    void officeJwtCannotBypassTheRemoteGate() throws Exception {
        String admin = adminToken();
        Employee employee = newEmployee(admin);
        UUID id = UUID.fromString(employee.userId());
        targets.add(id);
        String token = login(employee.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
        var denied = mvc.perform(remote(get("/api/auth/me"))
                .header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(403, denied.getResponse().getStatus(), body(denied));
        assertEquals("REMOTE_ACCESS_DENIED", json(denied).path("code").asText());
        assertEquals(200, me(token).getResponse().getStatus(), "The office path must stay open");
    }

    @Test
    void externalCallerCannotSpoofItsWayThroughOfficeConnector() throws Exception {
        var result = mvc.perform(get("/api/platform/branding")
                .header("X-Uten-Request-Origin","LOCAL")
                .header("X-Forwarded-For","192.168.1.20")
                .header("X-Forwarded-Port","8082")
                .with(request -> {request.setRemoteAddr("203.0.113.77");request.setLocalPort(8080);return request;}))
                .andReturn();
        assertEquals(403,result.getResponse().getStatus(),body(result));
    }

    @Test
    void encodedApiPathsCannotBypassTheRemoteGate() throws Exception {
        String admin = adminToken();
        Employee employee = newEmployee(admin);
        UUID id = UUID.fromString(employee.userId());
        targets.add(id);
        String token = login(employee.loginAccount(), EMPLOYEE_PASSWORD).path("accessToken").asText();
        for (String path : List.of("/%61pi/auth/me", "/api/%61uth/me")) {
            var result = mvc.perform(remote(get(java.net.URI.create(path)))
                    .header("Authorization", "Bearer " + token)).andReturn();
            assertEquals(403, result.getResponse().getStatus(), body(result));
            assertEquals("REMOTE_ACCESS_DENIED", json(result).path("code").asText());
        }
        var local = mvc.perform(get(java.net.URI.create("/%61pi/auth/me"))
                .header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(200, local.getResponse().getStatus(), body(local));
    }

    @Test
    void encodedRemoteLoginAndRefreshRespectTheRemoteGate() throws Exception {
        String admin = adminToken();
        Employee employee = newEmployee(admin);
        UUID id = UUID.fromString(employee.userId());
        targets.add(id);
        var local = login(employee.loginAccount(), EMPLOYEE_PASSWORD);
        for (String path : List.of("/%61pi/auth/login", "/api/%61uth/login")) {
            var denied = mvc.perform(json(remote(post(java.net.URI.create(path))),
                    Map.of("loginAccount", employee.loginAccount(), "password", EMPLOYEE_PASSWORD), null)).andReturn();
            assertEquals(403, denied.getResponse().getStatus(), body(denied));
            assertEquals("REMOTE_ACCESS_DENIED", json(denied).path("code").asText());
            assertFalse(json(denied).has("accessToken"));
        }
        var deniedRefresh = mvc.perform(json(remote(post(java.net.URI.create("/%61pi/auth/refresh"))),
                Map.of("refreshToken", local.path("refreshToken").asText()), null)).andReturn();
        assertEquals(403, deniedRefresh.getResponse().getStatus(), body(deniedRefresh));
        assertEquals("REMOTE_ACCESS_DENIED", json(deniedRefresh).path("code").asText());
        assertEquals(200, me(local.path("accessToken").asText()).getResponse().getStatus(),
                "Rejected remote issuance must not revoke the office session");
        var localRefresh = mvc.perform(json(post("/api/auth/refresh"),
                Map.of("refreshToken", local.path("refreshToken").asText()), null)).andReturn();
        assertEquals(200, localRefresh.getResponse().getStatus(),
                "Rejected remote refresh must not consume the token");
    }

    private MockHttpServletRequestBuilder remote(MockHttpServletRequestBuilder builder) {
        return builder.with(request -> {request.setLocalPort(deployment.getRemoteIngressPort());request.setRemoteAddr("127.0.0.1");return request;});
    }
}
