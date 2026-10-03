package com.uten.imp.security;

import org.junit.jupiter.api.Test;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

class IqcReceiptReadOnlyRouteContractTest {
    @Test void onlyTheTwoFullOriginalIqcReportQueriesAreReadOnlyExceptions(){
        String prefix="/api/procurement/inspection/PURCHASE/"+UUID.randomUUID();
        assertTrue(ImpersonationWriteGuardFilter.readOnlyIqcReportReceipt("POST",prefix+"/decide-batch/receipt"));
        assertTrue(ImpersonationWriteGuardFilter.readOnlyIqcReportReceipt("POST",prefix.replace("PURCHASE","SUBCONTRACT")+"/pass-batch/receipt"));
        for(String path:java.util.List.of(prefix+"/decide-batch",prefix+"/pass-batch",prefix+"/receipt",
                "/api/stock/docs/issue-batch/receipt",prefix+"/decide-batch/receipt/reverse",prefix+"/decide-batch/receipt/../dispose")){
            assertFalse(ImpersonationWriteGuardFilter.readOnlyIqcReportReceipt("POST",path));
        }
        assertFalse(ImpersonationWriteGuardFilter.readOnlyIqcReportReceipt("DELETE",prefix+"/decide-batch/receipt"));
    }

    @Test void actualImpersonationFilterAllowsOriginalBodyReadButBlocksQualityWriteWithTheSameIdentity()throws Exception {
        var user=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"simulated-inspector",
                java.util.Set.of("procurement_inspection:view","procurement_inspection:handle"),
                false,true,false,false,UUID.randomUUID());
        var context=org.springframework.security.core.context.SecurityContextHolder.getContext();
        context.setAuthentication(new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(
                user,null,user.getAuthorities()));
        var filter=new ImpersonationWriteGuardFilter(new com.fasterxml.jackson.databind.ObjectMapper(),
                org.mockito.Mockito.mock(com.uten.imp.audit.AuditService.class));
        String prefix="/app/api/procurement/inspection/PURCHASE/"+UUID.randomUUID();
        try {
            var read=new org.springframework.mock.web.MockHttpServletRequest("POST",prefix+"/decide-batch/receipt");
            read.setContextPath("/app");
            var readResponse=new org.springframework.mock.web.MockHttpServletResponse();
            var readChain=new org.springframework.mock.web.MockFilterChain();
            filter.doFilter(read,readResponse,readChain);
            assertSame(read,readChain.getRequest());
            var write=new org.springframework.mock.web.MockHttpServletRequest("POST",prefix+"/decide-batch");
            write.setContextPath("/app");
            var writeResponse=new org.springframework.mock.web.MockHttpServletResponse();
            var writeChain=new org.springframework.mock.web.MockFilterChain();
            filter.doFilter(write,writeResponse,writeChain);
            assertNull(writeChain.getRequest());assertEquals(403,writeResponse.getStatus());
        }finally{org.springframework.security.core.context.SecurityContextHolder.clearContext();}
    }
}
