package com.uten.imp.security;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.*;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.mock;
class B1ReadOnlyRouteContractTest {
    @Test void onlyExactB1ReadPostsMayRunUnderImpersonation() throws Exception {
        var principal=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"fixture",Set.of("client:view","sales_order:view"),false,true,false,false,UUID.randomUUID());
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(principal,null,principal.getAuthorities()));
        var filter=new ImpersonationWriteGuardFilter(new ObjectMapper(),mock(AuditService.class));
        try {
            for(String path:List.of("/api/master/clients/search-context","/api/master/suppliers/search-context","/api/sales/orders/shippable-lines/selection")) {
                var request=new MockHttpServletRequest("POST","/app"+path);request.setContextPath("/app");
                var chain=new MockFilterChain();filter.doFilter(request,new MockHttpServletResponse(),chain);assertSame(request,chain.getRequest());
                for(String method:List.of("PUT","PATCH","DELETE"))assertFalse(ImpersonationWriteGuardFilter.readOnlyB1Query(method,path));
            }
            for(String path:List.of("/api/master/clients/search-context/save","/api/sales/orders/shippable-lines/selection/confirm",
                    "/api/report-export-jobs","/api/report-export-jobs/"+UUID.randomUUID()+"/download")) {
                var chain=new MockFilterChain();var response=new MockHttpServletResponse();
                filter.doFilter(new MockHttpServletRequest("POST",path),response,chain);assertEquals(403,response.getStatus());assertNull(chain.getRequest());
            }
        } finally {SecurityContextHolder.clearContext();}
    }
}
