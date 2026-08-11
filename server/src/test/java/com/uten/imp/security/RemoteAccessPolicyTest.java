package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.DeploymentProperties;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.mockito.Mockito.mock;

class RemoteAccessPolicyTest {

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void cloudRejectsUnapprovedStaffAndLocalSiteDoesNot() {
        DeploymentProperties cloud = new DeploymentProperties();
        cloud.setSite("cloud");
        ApiException denied = assertThrows(
                ApiException.class,
                () -> new RemoteAccessPolicy(cloud).requireStaffAccess(false));
        assertEquals(ErrorCode.REMOTE_ACCESS_DENIED, denied.getCode());

        DeploymentProperties local = new DeploymentProperties();
        local.setSite("local");
        assertDoesNotThrow(() -> new RemoteAccessPolicy(local).requireStaffAccess(false));
    }

    @Test
    void visitorBoundaryRemainsPublicOnCloud() {
        DeploymentProperties cloud = new DeploymentProperties();
        cloud.setSite("cloud");
        AuthUser visitor = AuthUser.visitor(
                UUID.randomUUID(), "visitor-account", "V-001", Set.of("visitor:read"));

        assertDoesNotThrow(
                () -> new RemoteAccessPolicy(cloud).requireAuthenticatedAccess(visitor));
    }

    @Test
    void authenticatedGuardUsesTheSameDefinitiveRemoteAccessErrorCode() throws Exception {
        DeploymentProperties cloud = new DeploymentProperties();
        cloud.setSite("cloud");
        RemoteAccessPolicy policy = new RemoteAccessPolicy(cloud);
        ObjectMapper objectMapper = new ObjectMapper().findAndRegisterModules();
        RemoteAccessGuardFilter filter = new RemoteAccessGuardFilter(
                objectMapper, mock(AuditService.class), policy);
        AuthUser staff = new AuthUser(
                UUID.randomUUID(), UUID.randomUUID(), "E001",
                Set.of(), Set.of(), false, true, false, false, null);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(staff, null, staff.getAuthorities()));
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/api/auth/me");
        MockHttpServletResponse response = new MockHttpServletResponse();
        boolean[] reached = {false};

        filter.doFilter(request, response, (req, resp) -> reached[0] = true);

        assertFalse(reached[0]);
        assertEquals(403, response.getStatus());
        assertEquals(
                ErrorCode.REMOTE_ACCESS_DENIED.name(),
                objectMapper.readTree(response.getContentAsByteArray()).path("code").asText());
    }
}
