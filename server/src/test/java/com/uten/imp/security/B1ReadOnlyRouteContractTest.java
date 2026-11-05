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
            var readPaths=new ArrayList<>(List.of("/api/master/clients/search-context","/api/master/suppliers/search-context","/api/sales/orders/shippable-lines/selection",
                    "/api/purchase/orders/print-authorization","/api/subcontract/orders/print-authorization","/api/quality/pending-disposals/query"));
            for(String prefix:List.of("/api/master/goods/","/api/business-references/goods/"))
                for(String action:List.of("search","search-category-ids","facets","facet-values"))readPaths.add(prefix+action);
            readPaths.addAll(List.of("/api/master/clients/access-candidates/query", "/api/admin/data-handovers/candidates/query",
                    "/api/sales/orders/delivery-preview"));
            for(String path:readPaths) {
                var request=new MockHttpServletRequest("POST","/app"+path);request.setContextPath("/app");
                var chain=new MockFilterChain();filter.doFilter(request,new MockHttpServletResponse(),chain);assertSame(request,chain.getRequest());
                for(String method:List.of("PUT","PATCH","DELETE"))assertFalse(ImpersonationWriteGuardFilter.readOnlyB1Query(method,path));
            }
            for(String path:List.of("/api/master/clients/search-context/save","/api/sales/orders/shippable-lines/selection/confirm",
                    "/api/subcontract/orders/print-authorization/confirm","/api/subcontract/orders/"+UUID.randomUUID()+"/submit-finance",
                    "/api/quality/pending-disposals/query/confirm","/api/quality/pending-disposals/decide",
                    "/api/operations/workbench/subcontract/export","/api/report-export-jobs","/api/report-export-jobs/"+UUID.randomUUID()+"/download",
                    "/api/master/goods/search/save","/api/business-references/goods/search/confirm",
                    "/api/master/goods/facet-values/save","/api/business-references/goods/facets/save",
                    "/api/master/clients/access-candidates/query/save", "/api/admin/data-handovers/candidates/query/confirm",
                    "/api/sales/orders/delivery-preview/confirm",
                    "/api/production/delivery-processing-tasks/"+UUID.randomUUID()+"/reports")) {
                var chain=new MockFilterChain();var response=new MockHttpServletResponse();
                filter.doFilter(new MockHttpServletRequest("POST",path),response,chain);assertEquals(403,response.getStatus());assertNull(chain.getRequest());
            }
            var rules=new MockHttpServletRequest("PUT","/api/sales/orders/delivery-bom/rules/"+UUID.randomUUID());
            var rulesResponse=new MockHttpServletResponse();var rulesChain=new MockFilterChain();
            filter.doFilter(rules,rulesResponse,rulesChain);assertEquals(403,rulesResponse.getStatus());assertNull(rulesChain.getRequest());
        } finally {SecurityContextHolder.clearContext();}
    }
}
