package com.uten.imp.security;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.DeploymentProperties;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

class LocalNetworkGuardFilterTest {

    private final ObjectMapper objectMapper = new ObjectMapper().findAndRegisterModules();
    private final AuditService audit = mock(AuditService.class);

    @Test
    void privateSourceCanReachLoginBeforeAuthentication() throws Exception {
        LocalNetworkGuardFilter filter = localFilter(DeploymentProperties.DEFAULT_LOCAL_ALLOWED_CIDRS);
        MockHttpServletRequest request = request("POST", "/api/auth/login", "192.168.12.40");
        MockHttpServletResponse response = new MockHttpServletResponse();
        boolean[] reached = {false};

        filter.doFilter(request, response, (req, resp) -> reached[0] = true);

        assertTrue(reached[0]);
    }

    @Test
    void publicSourceCannotForgeForwardedHeaderToReachLogin() throws Exception {
        LocalNetworkGuardFilter filter = localFilter(DeploymentProperties.DEFAULT_LOCAL_ALLOWED_CIDRS);
        MockHttpServletRequest request = request("POST", "/api/auth/login", "203.0.113.25");
        request.addHeader("X-Forwarded-For", "192.168.1.20");
        MockHttpServletResponse response = new MockHttpServletResponse();
        boolean[] reached = {false};

        filter.doFilter(request, response, (req, resp) -> reached[0] = true);

        assertFalse(reached[0]);
        assertEquals(403, response.getStatus());
        JsonNode body = objectMapper.readTree(response.getContentAsByteArray());
        assertEquals(ErrorCode.FORBIDDEN.name(), body.path("code").asText());
        assertEquals(403, body.path("status").asInt());
        verify(audit).logSecurityEvent(
                request, null, null,
                "local_network_access_denied", "forbidden", 403);
    }

    @Test
    void productionCanNarrowTheDefaultPrivateRanges() throws Exception {
        LocalNetworkGuardFilter filter = localFilter("10.20.0.0/16,127.0.0.1/32");
        MockHttpServletRequest request = request("GET", "/api/auth/me", "192.168.1.8");
        MockHttpServletResponse response = new MockHttpServletResponse();
        boolean[] reached = {false};

        filter.doFilter(request, response, (req, resp) -> reached[0] = true);

        assertFalse(reached[0]);
        assertEquals(403, response.getStatus());
    }

    @Test
    void cloudSiteIsANoOpAndActuatorRemainsOutsideTheApiBoundary() throws Exception {
        DeploymentProperties cloud = new DeploymentProperties();
        cloud.setSite("cloud");
        LocalNetworkGuardFilter cloudFilter = filter(cloud);
        boolean[] cloudReached = {false};
        cloudFilter.doFilter(
                request("POST", "/api/auth/login", "203.0.113.25"),
                new MockHttpServletResponse(),
                (req, resp) -> cloudReached[0] = true);
        assertTrue(cloudReached[0]);

        LocalNetworkGuardFilter localFilter = localFilter(DeploymentProperties.DEFAULT_LOCAL_ALLOWED_CIDRS);
        boolean[] actuatorReached = {false};
        localFilter.doFilter(
                request("GET", "/actuator/health", "203.0.113.25"),
                new MockHttpServletResponse(),
                (req, resp) -> actuatorReached[0] = true);
        assertTrue(actuatorReached[0]);
    }

    @Test
    void invalidOrEmptyCidrConfigurationFailsClosed() {
        for (String invalid : java.util.List.of(
                "", "10.0.0.0/99", "company.example/24",
                "127.1/8", "1/32", "10..0.1/24",
                "1.2.3.4/0", "10.1.2.3/8", "192.168.1.1/24",
                "10.0.0.0/08", "10.0.0.0/+8", "010.0.0.0/8",
                "10.0.0.0/8, 192.168.0.0/16", "10.0.0.0/8,")) {
            DeploymentProperties properties = new DeploymentProperties();
            properties.setSite("local");
            properties.setLocalAllowedCidrs(invalid);
            LocalNetworkAccessPolicy policy = new LocalNetworkAccessPolicy(properties);
            assertThrows(IllegalStateException.class, policy::validateConfiguration, invalid);
        }
    }

    @Test
    void ipv4ShorthandAndIpv6ZoneIdentifiersAreNeverAcceptedAsLiterals() throws Exception {
        LocalNetworkGuardFilter filter = localFilter(DeploymentProperties.DEFAULT_LOCAL_ALLOWED_CIDRS);
        for (String nonLiteral : java.util.List.of("1", "127.1", "10..0.1", "fe80::1%3")) {
            MockHttpServletResponse response = new MockHttpServletResponse();
            boolean[] reached = {false};

            filter.doFilter(
                    request("POST", "/api/auth/login", nonLiteral),
                    response,
                    (req, resp) -> reached[0] = true);

            assertFalse(reached[0], nonLiteral);
            assertEquals(403, response.getStatus(), nonLiteral);
        }
    }

    private LocalNetworkGuardFilter localFilter(String cidrs) {
        DeploymentProperties properties = new DeploymentProperties();
        properties.setSite("local");
        properties.setLocalAllowedCidrs(cidrs);
        return filter(properties);
    }

    private LocalNetworkGuardFilter filter(DeploymentProperties properties) {
        LocalNetworkAccessPolicy policy = new LocalNetworkAccessPolicy(properties);
        policy.validateConfiguration();
        return new LocalNetworkGuardFilter(objectMapper, audit, policy);
    }

    private MockHttpServletRequest request(String method, String path, String remoteAddress) {
        MockHttpServletRequest request = new MockHttpServletRequest(method, path);
        request.setRemoteAddr(remoteAddress);
        return request;
    }
}
