package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.config.props.DeploymentProperties;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.mock;

class TrustedRequestOriginPolicyTest {
    private final DeploymentProperties deployment = new DeploymentProperties();
    private final LocalNetworkAccessPolicy network = new LocalNetworkAccessPolicy(deployment);
    private final TrustedRequestOriginPolicy origins = new TrustedRequestOriginPolicy(deployment, network);

    @Test
    void forgedOriginAndForwardingHeadersCannotOpenOfficeEntry() throws Exception {
        deployment.setLocalAllowedCidrs("192.168.23.0/24,127.0.0.1/32");
        deployment.setRemoteIngressEnabled(true);
        MockHttpServletRequest request = request(8080,"203.0.113.40");
        request.addHeader("X-Uten-Request-Origin","LOCAL");
        request.addHeader("X-Forwarded-For","192.168.23.50");
        request.addHeader("X-Forwarded-Port","8082");
        request.addHeader("Forwarded","for=192.168.23.50;host=company.example:8082");
        assertEquals(TrustedRequestOriginPolicy.Origin.UNKNOWN,origins.resolve(request));
        var response = new MockHttpServletResponse();
        var filter = new LocalNetworkGuardFilter(new ObjectMapper().findAndRegisterModules(),mock(AuditService.class),network,origins);
        filter.doFilter(request,response,(req,res) -> fail("External caller must not reach authentication"));
        assertEquals(403,response.getStatus());
    }

    @Test
    void dedicatedRemoteConnectorCannotBeDowngradedByOfficeLookingAddressOrHeaders() throws Exception {
        deployment.setRemoteIngressEnabled(true);
        var request = request(8082,"127.0.0.1");
        request.addHeader("X-Uten-Request-Origin","LOCAL");
        request.addHeader("X-Forwarded-For","192.168.1.2");
        assertEquals(TrustedRequestOriginPolicy.Origin.REMOTE,origins.resolve(request));
        var filter = new LocalNetworkGuardFilter(new ObjectMapper().findAndRegisterModules(),mock(AuditService.class),network,origins);
        filter.doFilter(request,new MockHttpServletResponse(),(req,res) -> assertTrue(origins.isRemoteRequest()));
        assertEquals(TrustedRequestOriginPolicy.Origin.UNKNOWN,origins.current(),"Thread reuse must not inherit a prior origin");
    }

    @Test
    void disabledRemoteConnectorNeverGrantsRemoteTransportIdentity() {
        deployment.setLocalAllowedCidrs("192.168.23.0/24");
        assertEquals(TrustedRequestOriginPolicy.Origin.UNKNOWN,origins.resolve(request(8082,"203.0.113.40")));
        assertEquals(TrustedRequestOriginPolicy.Origin.UNKNOWN,origins.current());
    }

    @Test
    void failingRequestAlsoReleasesOriginBinding() {
        deployment.setRemoteIngressEnabled(true);
        var filter = new LocalNetworkGuardFilter(new ObjectMapper().findAndRegisterModules(),mock(AuditService.class),network,origins);
        assertThrows(IllegalStateException.class,() -> filter.doFilter(request(8082,"127.0.0.1"),
                new MockHttpServletResponse(),(req,res) -> {throw new IllegalStateException("test");}));
        assertEquals(TrustedRequestOriginPolicy.Origin.UNKNOWN,origins.current());
    }

    private MockHttpServletRequest request(int port,String source) {
        var request = new MockHttpServletRequest("GET","/api/auth/me");
        request.setLocalPort(port);
        request.setRemoteAddr(source);
        return request;
    }
}
