package com.uten.imp.security;

import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.security.web.firewall.RequestRejectedException;
import static org.junit.jupiter.api.Assertions.*;

class SecurityRequestPathTest {
    @Test void containerMappingCombinesServletAndPathInfoAndNeverDecodesTwice() {
        var request=new MockHttpServletRequest("GET","/%61pi/%61uth/me");
        request.setServletPath("/api");request.setPathInfo("/auth/me");
        assertEquals("/api/auth/me",SecurityRequestPath.withinApplication(request));
        request.setRequestURI("/%2561pi/auth/me");request.setServletPath("/%61pi");
        assertEquals("/%61pi/auth/me",SecurityRequestPath.withinApplication(request));
        assertFalse(SecurityRequestPath.isApi(SecurityRequestPath.withinApplication(request)));
    }

    @Test void syntheticFallbackDecodesOnceAndRespectsTheContextBoundary() {
        for(String raw:new String[]{"/%61pi/auth/me","/api/%61uth/me"}) {
            var request=new MockHttpServletRequest("GET",raw);
            assertEquals("/api/auth/me",SecurityRequestPath.withinApplication(request));
        }
        var context=new MockHttpServletRequest("GET","/erp/%61pi/auth/me");context.setContextPath("/erp");
        assertEquals("/api/auth/me",SecurityRequestPath.withinApplication(context));
        context.setServletPath("/api");context.setPathInfo("/auth/me");
        assertEquals("/api/auth/me",SecurityRequestPath.withinApplication(context));
        var nearContext=new MockHttpServletRequest("GET","/erpevil/api/auth/me");nearContext.setContextPath("/erp");
        assertThrows(RequestRejectedException.class,()->SecurityRequestPath.withinApplication(nearContext));
        assertTrue(SecurityRequestPath.isHealth(SecurityRequestPath.withinApplication(
                new MockHttpServletRequest("GET","/actuator/%68ealth/readiness"))));
    }

    @Test void ambiguousSyntheticPathsAreRejectedInsteadOfSkippingGuards() {
        for(String path:new String[]{"/%GGapi/auth/me","//api/auth/me","/api/../auth/me","/api;v=1/auth/me","/api\\auth/me"}) {
            assertThrows(RequestRejectedException.class,()->SecurityRequestPath.withinApplication(new MockHttpServletRequest("GET",path)),path);
        }
    }
}
