package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockFilterChain;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.mock;

class GoodsHistoryAccountHttpGuardTest {
    private final ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();

    @AfterEach
    void clearIdentity() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void impersonationMayReadTheEffectiveAccountHistoryButCannotUndoOrRedo() throws Exception {
        var user = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "simulated",
                Set.of("goods:view", "goods:edit", "goods:delete"), false, true, false, false, UUID.randomUUID());
        authenticate(user);
        var filter = new ImpersonationWriteGuardFilter(mapper, mock(AuditService.class));
        var read = request("GET", "/api/master/goods/history");
        var readChain = new MockFilterChain();
        filter.doFilter(read, new MockHttpServletResponse(), readChain);
        assertSame(read, readChain.getRequest());

        for (String action : List.of("undo", "redo")) {
            var command = request("POST", "/api/master/goods/history/" + UUID.randomUUID() + "/" + action);
            var response = new MockHttpServletResponse();
            var chain = new MockFilterChain();
            filter.doFilter(command, response, chain);
            assertEquals(403, response.getStatus());
            assertEquals("IMPERSONATION_READ_ONLY", mapper.readTree(response.getContentAsString()).path("code").asText());
            assertNull(chain.getRequest());
        }
    }

    @Test
    void forcedPasswordChangeBlocksBothTheHistoryReadAndItsTwoCommands() throws Exception {
        authenticate(new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "temporary-password",
                Set.of("goods:view", "goods:edit", "goods:delete"), true, true, false));
        var filter = new PasswordChangeRequiredFilter(mapper, mock(AuditService.class));
        for (String action : List.of("read", "undo", "redo")) {
            var command = request(action.equals("read") ? "GET" : "POST",
                    "/api/master/goods/history" + (action.equals("read") ? "" : "/" + UUID.randomUUID() + "/" + action));
            var response = new MockHttpServletResponse();
            var chain = new MockFilterChain();
            filter.doFilter(command, response, chain);
            assertEquals(403, response.getStatus());
            assertEquals("PASSWORD_CHANGE_REQUIRED", mapper.readTree(response.getContentAsString()).path("code").asText());
            assertNull(chain.getRequest());
        }
    }

    @Test
    void encodedImpersonationRequestsKeepExactReadOnlyRecoveryAndNeverAllowBusinessWrites() throws Exception {
        authenticate(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"simulated",Set.of(),false,true,false,false,UUID.randomUUID()));
        var filter=new ImpersonationWriteGuardFilter(mapper,mock(AuditService.class));
        var recovery=request("POST","/%61pi/production/daily-reports/%63reate-receipt");
        var allowed=new MockFilterChain();
        filter.doFilter(recovery,new MockHttpServletResponse(),allowed);
        assertSame(recovery,allowed.getRequest());
        var write=request("POST","/%61pi/master/goods/history/"+UUID.randomUUID()+"/undo");
        var blocked=new MockFilterChain();var response=new MockHttpServletResponse();
        filter.doFilter(write,response,blocked);
        assertEquals(403,response.getStatus());assertNull(blocked.getRequest());
    }

    private static void authenticate(AuthUser user) {
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
    }

    private static MockHttpServletRequest request(String method, String path) {
        var request = new MockHttpServletRequest(method, "/app" + path);
        request.setContextPath("/app");
        return request;
    }
}
