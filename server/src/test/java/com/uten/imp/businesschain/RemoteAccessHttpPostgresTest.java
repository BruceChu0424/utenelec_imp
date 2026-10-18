package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.DeploymentProperties;
import com.uten.imp.features.admin.UserAccountAdminService;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Real migrations + HTTP filter chain + concurrent grant transactions. */
class RemoteAccessHttpPostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired DeploymentProperties deployment;
    @Autowired UserAccountAdminService accounts;
    private final List<UUID> targets = new ArrayList<>();

    @BeforeEach
    void configureTransport() {
        deployment.setRemoteIngressEnabled(true);
        jdbc.update("UPDATE remote_access_policy SET enabled=false,max_users=10000,version=version+1 WHERE singleton_id=1");
    }

    @AfterEach
    void resetTransport() {
        deployment.setRemoteIngressEnabled(false);
        targets.forEach(id -> jdbc.update("UPDATE users SET remote_access=false WHERE id=?",id));
        jdbc.update("UPDATE remote_access_policy SET enabled=false,max_users=greatest(5,(SELECT count(*)::integer FROM users WHERE remote_access AND NOT is_deleted)),version=version+1 WHERE singleton_id=1");
    }

    @Test
    void onlyLocalSuperAdministratorCanChangePolicyWithFreshVersionAndStepUp() throws Exception {
        String admin = adminToken();
        long revision = jdbc.queryForObject("SELECT version FROM remote_access_policy WHERE singleton_id=1",Long.class);
        var body = Map.of("enabled",true,"maxUsers",5,"expectedVersion",revision);
        var noStepUp = mvc.perform(json(patch("/api/admin/remote-access/policy"),body,admin)).andReturn();
        assertEquals(403,noStepUp.getResponse().getStatus(),body(noStepUp));
        assertEquals("REAUTH_REQUIRED",json(noStepUp).path("code").asText());
        var saved = mvc.perform(json(patch("/api/admin/remote-access/policy"),body,admin)
                .header("X-Uten-Step-Up",stepUp(admin,ADMIN_PASSWORD))).andReturn();
        assertEquals(200,saved.getResponse().getStatus(),body(saved));
        assertTrue(json(saved).path("enabled").asBoolean());
        var stale = mvc.perform(json(patch("/api/admin/remote-access/policy"),body,admin)
                .header("X-Uten-Step-Up",stepUp(admin,ADMIN_PASSWORD))).andReturn();
        assertEquals(409,stale.getResponse().getStatus(),body(stale));
        Employee ordinary = newEmployee(admin);
        targets.add(UUID.fromString(ordinary.userId()));
        var forbidden = mvc.perform(get("/api/admin/remote-access/status")
                .header("Authorization","Bearer "+ordinary.accessToken())).andReturn();
        assertEquals(403,forbidden.getResponse().getStatus(),body(forbidden));
    }

    @Test
    void officeJwtCannotBypassRemoteMfaAndClosingPolicyTakesEffectOnNextRequest() throws Exception {
        String admin = adminToken();
        Employee employee = newEmployee(admin);
        UUID id = UUID.fromString(employee.userId());
        targets.add(id);
        jdbc.update("UPDATE users SET remote_access=true WHERE id=?",id);
        jdbc.update("UPDATE remote_access_policy SET enabled=true,version=version+1 WHERE singleton_id=1");
        String token = login(employee.loginAccount(),EMPLOYEE_PASSWORD).path("accessToken").asText();
        var mfaNeeded = mvc.perform(remote(get("/api/auth/me"))
                .header("Authorization","Bearer "+token)).andReturn();
        assertEquals(403,mfaNeeded.getResponse().getStatus(),body(mfaNeeded));
        assertEquals("MFA_REQUIRED",json(mfaNeeded).path("code").asText());
        var recoveryStatus = mvc.perform(remote(get("/api/auth/mfa"))
                .header("Authorization","Bearer "+token)).andReturn();
        assertEquals(200,recoveryStatus.getResponse().getStatus(),body(recoveryStatus));
        jdbc.update("UPDATE remote_access_policy SET enabled=false,version=version+1 WHERE singleton_id=1");
        var closed = mvc.perform(remote(get("/api/auth/mfa"))
                .header("Authorization","Bearer "+token)).andReturn();
        assertEquals(403,closed.getResponse().getStatus(),body(closed));
        assertEquals("REMOTE_ACCESS_DENIED",json(closed).path("code").asText());
        assertEquals(200,me(token).getResponse().getStatus(),"Closing remote access must retain the office path");
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
    void enrolledEmployeeCanLoginRemotelyAndResetImmediatelyRevokesTheVerifiedSession() throws Exception {
        String admin = adminToken();
        Employee employee = newEmployee(admin);
        UUID id = UUID.fromString(employee.userId());targets.add(id);
        jdbc.update("UPDATE users SET remote_access=true WHERE id=?",id);
        jdbc.update("UPDATE remote_access_policy SET enabled=true,version=version+1 WHERE singleton_id=1");
        String local = login(employee.loginAccount(),EMPLOYEE_PASSWORD).path("accessToken").asText();
        var enrollment = mvc.perform(json(post("/api/auth/mfa/enrollment"),Map.of(),local)
                .header("X-Uten-Step-Up",stepUp(local,EMPLOYEE_PASSWORD))).andReturn();
        assertEquals(200,enrollment.getResponse().getStatus(),"LAN enrollment should succeed");
        String secret = json(enrollment).path("secret").asText();
        assertFalse(secret.isBlank());
        assertEquals("no-store",enrollment.getResponse().getHeader("Cache-Control"));
        var confirmed = mvc.perform(json(post("/api/auth/mfa/confirm"),
                Map.of("otpCode",code(secret)),local)).andReturn();
        assertEquals(200,confirmed.getResponse().getStatus(),body(confirmed));
        assertTrue(json(confirmed).path("enabled").asBoolean());
        clock.advance(java.time.Duration.ofSeconds(30));
        var signedIn = mvc.perform(json(remote(post("/api/auth/login")),
                Map.of("loginAccount",employee.loginAccount(),"password",EMPLOYEE_PASSWORD,"otpCode",code(secret)),null))
                .andReturn();
        assertEquals(200,signedIn.getResponse().getStatus(),"Verified remote login should issue credentials");
        String remoteToken = json(signedIn).path("accessToken").asText();
        var allowed = mvc.perform(remote(get("/api/auth/me"))
                .header("Authorization","Bearer "+remoteToken)).andReturn();
        assertEquals(200,allowed.getResponse().getStatus(),body(allowed));
        var replay = mvc.perform(json(remote(post("/api/auth/mfa/verify")),
                Map.of("otpCode",code(secret)),remoteToken)).andReturn();
        assertEquals(422,replay.getResponse().getStatus(),body(replay));
        assertEquals("MFA_INVALID",json(replay).path("code").asText());
        var reset = mvc.perform(json(post("/api/auth/mfa/users/"+id+"/reset"),
                Map.of("reason","测试受控重绑"),admin)
                .header("X-Uten-Step-Up",stepUp(admin,ADMIN_PASSWORD))).andReturn();
        assertEquals(200,reset.getResponse().getStatus(),body(reset));
        var rejected = mvc.perform(remote(get("/api/auth/me"))
                .header("Authorization","Bearer "+remoteToken)).andReturn();
        assertEquals(401,rejected.getResponse().getStatus(),body(rejected));
    }

    @Test
    void encodedApiPathsCannotBypassRemoteMfaOrTheGlobalSwitch() throws Exception {
        String admin=adminToken();Employee employee=newEmployee(admin);
        UUID id=UUID.fromString(employee.userId());targets.add(id);
        jdbc.update("UPDATE users SET remote_access=true WHERE id=?",id);
        jdbc.update("UPDATE remote_access_policy SET enabled=true,version=version+1 WHERE singleton_id=1");
        String token=login(employee.loginAccount(),EMPLOYEE_PASSWORD).path("accessToken").asText();
        for(String path:List.of("/%61pi/auth/me","/api/%61uth/me")) {
            var result=mvc.perform(remote(get(java.net.URI.create(path))).header("Authorization","Bearer "+token)).andReturn();
            assertEquals(403,result.getResponse().getStatus(),body(result));
            assertEquals("MFA_REQUIRED",json(result).path("code").asText());
        }
        var local=mvc.perform(get(java.net.URI.create("/%61pi/auth/me")).header("Authorization","Bearer "+token)).andReturn();
        assertEquals(200,local.getResponse().getStatus(),body(local));
        jdbc.update("UPDATE remote_access_policy SET enabled=false,version=version+1 WHERE singleton_id=1");
        var disabled=mvc.perform(remote(get(java.net.URI.create("/%61pi/auth/mfa"))).header("Authorization","Bearer "+token)).andReturn();
        assertEquals(403,disabled.getResponse().getStatus(),body(disabled));
        assertEquals("REMOTE_ACCESS_DENIED",json(disabled).path("code").asText());
    }

    @Test
    void encodedRemoteLoginAndRefreshCannotIssueCredentialsWithoutMfa() throws Exception {
        String admin=adminToken();Employee employee=newEmployee(admin);
        UUID id=UUID.fromString(employee.userId());targets.add(id);
        jdbc.update("UPDATE users SET remote_access=true WHERE id=?",id);
        jdbc.update("UPDATE remote_access_policy SET enabled=true,version=version+1 WHERE singleton_id=1");
        var local=login(employee.loginAccount(),EMPLOYEE_PASSWORD);
        for(String path:List.of("/%61pi/auth/login","/api/%61uth/login")) {
            var denied=mvc.perform(json(remote(post(java.net.URI.create(path))),
                    Map.of("loginAccount",employee.loginAccount(),"password",EMPLOYEE_PASSWORD),null)).andReturn();
            assertEquals(403,denied.getResponse().getStatus(),body(denied));
            assertEquals("MFA_ENROLLMENT_REQUIRED",json(denied).path("code").asText());
            assertFalse(json(denied).has("accessToken"));
        }
        var deniedRefresh=mvc.perform(json(remote(post(java.net.URI.create("/%61pi/auth/refresh"))),
                Map.of("refreshToken",local.path("refreshToken").asText()),null)).andReturn();
        assertEquals(403,deniedRefresh.getResponse().getStatus(),body(deniedRefresh));
        assertEquals("MFA_REQUIRED",json(deniedRefresh).path("code").asText());
        assertEquals(200,me(local.path("accessToken").asText()).getResponse().getStatus(),"Rejected remote issuance must not revoke the office session");
        var localRefresh=mvc.perform(json(post("/api/auth/refresh"),
                Map.of("refreshToken",local.path("refreshToken").asText()),null)).andReturn();
        assertEquals(200,localRefresh.getResponse().getStatus(),"Rejected remote refresh must not consume the token");
    }

    @Test
    void simultaneousGrantsCannotOverrunConfiguredCapacity() throws Exception {
        String admin = adminToken();
        Employee first = newEmployee(admin);
        Employee second = newEmployee(admin);
        UUID firstId = UUID.fromString(first.userId()),secondId = UUID.fromString(second.userId());
        targets.add(firstId);targets.add(secondId);
        int existing = jdbc.queryForObject("SELECT count(*) FROM users WHERE remote_access AND NOT is_deleted",Integer.class);
        jdbc.update("UPDATE remote_access_policy SET max_users=?,version=version+1 WHERE singleton_id=1",existing+1);
        UUID adminId = jdbc.queryForObject("SELECT id FROM users WHERE login_account=?",UUID.class,ADMIN_LOGIN);
        UUID employeeId = jdbc.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,adminId);
        AuthUser actor = new AuthUser(adminId,employeeId,ADMIN_LOGIN,Set.of("authorization:manage"),false,true,true);
        var ready = new CountDownLatch(2);
        var start = new CountDownLatch(1);
        try (var pool = Executors.newFixedThreadPool(2)) {
            var a = pool.submit(() -> grant(firstId,actor,ready,start));
            var b = pool.submit(() -> grant(secondId,actor,ready,start));
            assertTrue(ready.await(5,TimeUnit.SECONDS));start.countDown();
            List<String> results = List.of(a.get(15,TimeUnit.SECONDS),b.get(15,TimeUnit.SECONDS));
            assertEquals(1,results.stream().filter("granted"::equals).count(),results.toString());
            assertEquals(1,results.stream().filter("CONFLICT"::equals).count(),results.toString());
        }
        assertEquals(existing+1,jdbc.queryForObject("SELECT count(*) FROM users WHERE remote_access AND NOT is_deleted",Integer.class));
    }

    private String grant(UUID target,AuthUser actor,CountDownLatch ready,CountDownLatch start) throws Exception {
        var request = new MockHttpServletRequest("PUT","/api/admin/users/"+target+"/remote-access");
        request.setRemoteAddr("127.0.0.1");request.setLocalPort(8080);
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor,null,actor.getAuthorities()));
        try {
            ready.countDown();assertTrue(start.await(5,TimeUnit.SECONDS));
            accounts.setRemoteAccess(target,true);return "granted";
        } catch (ApiException denied) {
            return denied.getCode().name();
        } finally {
            RequestContextHolder.resetRequestAttributes();SecurityContextHolder.clearContext();
        }
    }

    private MockHttpServletRequestBuilder remote(MockHttpServletRequestBuilder builder) {
        return builder.with(request -> {request.setLocalPort(deployment.getRemoteIngressPort());request.setRemoteAddr("127.0.0.1");return request;});
    }

    /** Independent RFC6238 fixture; the production algorithm has its own RFC vector tests. */
    private String code(String secret) throws Exception {
        var decoded = new java.io.ByteArrayOutputStream();
        int bits=0,buffer=0;
        for (char character:secret.toCharArray()) {
            int digit="ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".indexOf(character);
            if (digit<0) throw new IllegalArgumentException("Invalid fixture secret");
            buffer=(buffer<<5)|digit;bits+=5;
            if(bits>=8){bits-=8;decoded.write((buffer>>bits)&255);}
        }
        var mac=javax.crypto.Mac.getInstance("HmacSHA1");
        mac.init(new javax.crypto.spec.SecretKeySpec(decoded.toByteArray(),"HmacSHA1"));
        byte[] digest=mac.doFinal(java.nio.ByteBuffer.allocate(8).putLong(clock.instant().getEpochSecond()/30).array());
        int offset=digest[digest.length-1]&15;
        int binary=((digest[offset]&127)<<24)|((digest[offset+1]&255)<<16)
                |((digest[offset+2]&255)<<8)|(digest[offset+3]&255);
        return String.format(java.util.Locale.ROOT,"%06d",binary%1_000_000);
    }
}
