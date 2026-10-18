package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.features.auth.AuthSessionService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class RemoteMfaGuardFilterTest {
    static final Instant NOW=Instant.parse("2026-10-17T12:00:00Z");
    final RemoteAccessPolicy access=mock(RemoteAccessPolicy.class);
    final AuditService audit=mock(AuditService.class);
    final RemoteMfaGuardFilter filter=new RemoteMfaGuardFilter(new ObjectMapper().findAndRegisterModules(),audit,access,Clock.fixed(NOW, ZoneOffset.UTC));
    @AfterEach void clear(){ SecurityContextHolder.clearContext(); }

    @Test void remoteWriteNeedsCurrentServerProofAndCannotTrustClientMfaHeader() throws Exception {
        when(access.isRemoteRequest()).thenReturn(true);
        for(Instant proof:new Instant[]{null,NOW.minus(AuthSessionService.MFA_VALIDITY),NOW.plusSeconds(1)}) {
            var result=request("POST","/api/finance/payments",staff(proof,null));
            assertThat(result.getStatus()).isEqualTo(403);
            assertThat(result.getContentAsString()).contains("MFA_REQUIRED");
        }
        assertThat(request("POST","/api/finance/payments",staff(NOW.minusSeconds(10),null)).getStatus()).isEqualTo(204);
    }

    @Test void onlyExactRecoveryMethodsBypassMissingProof() throws Exception {
        when(access.isRemoteRequest()).thenReturn(true);
        assertThat(request("GET","/api/auth/mfa",staff(null,null)).getStatus()).isEqualTo(204);
        assertThat(request("POST","/api/auth/mfa/verify",staff(null,null)).getStatus()).isEqualTo(204);
        assertThat(request("POST","/api/auth/logout",staff(null,null)).getStatus()).isEqualTo(204);
        for(String path:new String[]{"/api/auth/mfa/enrollment","/api/auth/mfa/disable","/api/auth/mfa/verify/child","/api/auth/me"})
            assertThat(request("POST",path,staff(null,null)).getStatus()).isEqualTo(403);
        assertThat(request("GET","/api/auth/mfa/verify",staff(null,null)).getStatus()).isEqualTo(403);
        assertThat(request("GET","/%61pi/auth/me",staff(null,null)).getStatus()).isEqualTo(403);
        assertThat(request("GET","/api/%61uth/me",staff(null,null)).getStatus()).isEqualTo(403);
        assertThat(request("POST","/%61pi/auth/mfa/verify",staff(null,null)).getStatus()).isEqualTo(204);
    }

    @Test void localAndVisitorBoundaryRemainSeparateAndRemoteImpersonationIsRejected() throws Exception {
        assertThat(request("POST","/api/stock/in",staff(null,null)).getStatus()).isEqualTo(204);
        when(access.isRemoteRequest()).thenReturn(true);
        assertThat(request("GET","/api/visitor/me",AuthUser.visitor(UUID.randomUUID(),"V1","V1",Set.of())).getStatus()).isEqualTo(204);
        assertThat(request("POST","/api/auth/mfa/verify",staff(NOW,UUID.randomUUID())).getStatus()).isEqualTo(403);
    }

    @Test void auditFailureCannotOpenBoundary() throws Exception {
        when(access.isRemoteRequest()).thenReturn(true);
        doThrow(new IllegalStateException("unavailable")).when(audit).logSecurityEvent(any(),any(),any(),any(),any(),anyInt());
        assertThat(request("POST","/api/stock/in",staff(null,null)).getStatus()).isEqualTo(403);
    }

    private static AuthUser staff(Instant proof,UUID impersonatedBy) {
        return new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"E1", Set.of(),false,true,false,true,impersonatedBy,UUID.randomUUID(),proof,true);
    }
    private MockHttpServletResponse request(String method,String path,AuthUser user) throws Exception {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));
        var request=new MockHttpServletRequest(method,path);
        request.addHeader("X-MFA-Verified","true");
        var response=new MockHttpServletResponse();
        filter.doFilter(request,response,(q,r)->response.setStatus(204));
        return response;
    }
}
