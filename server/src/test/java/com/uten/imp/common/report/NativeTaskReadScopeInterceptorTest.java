package com.uten.imp.common.report;

import java.util.List;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class NativeTaskReadScopeInterceptorTest {
    private static final String ID="12345678-1234-1234-1234-123456789abc";
    @Test void physicalReadsHaveFixedProfilesWithoutMatchingCommandsOrUnrelatedWarehouseApis() {
        for(String path:List.of("/api/master/warehouses/my-scope","/api/warehouse/task-center/inbound",
                "/api/warehouse/task-center/outbound/SALES:SALES_SHIPMENT:"+ID+":"+ID+"/detail",
                "/api/warehouse/document-history/subcontract-material-issues/"+ID,
                "/api/warehouse/document-history/purchase-receipts/facets","/api/warehouse/quality-results/PURCHASE/"+ID,
                "/api/warehouse/inbound/expectations/by-ids","/api/warehouse/inbound/arrival-exceptions/count",
                "/api/warehouse/production-finished-in/tasks/facets","/api/stock/count-requests/"+ID,
                "/api/stock/insights/health","/api/stock/insights/cycle-count","/api/stock/goods/"+ID+"/production-trace",
                "/api/production/reports/where-used/trace"))
            assertThat(NativeTaskReadScopeInterceptor.profile(path)).as(path).isEqualTo("native_warehouse_tasks");
        assertThat(NativeTaskReadScopeInterceptor.profile("/api/workshop-material/segments/"+ID+"/stock-readiness")).isEqualTo("native_workshop_tasks");
        for(String path:List.of("/api/warehouse/inbound/arrivals/batch","/api/warehouse/task-center/inbound/export",
                "/api/stock/count-requests/"+ID+"/approve","/api/stock/docs/"+ID+"/issue",
                "/api/warehouse/unknown","/api/stock/insights/learning"))
            assertThat(NativeTaskReadScopeInterceptor.profile(path)).as(path).isNull();
    }

    @Test void onlyExplicitBrowseMetadataUsesTheStaffPublicationProtocolIncludingBooleanAliases() {
        var authority=org.mockito.Mockito.mock(com.uten.imp.security.ReadScopeVersionAuthority.class);
        var users=org.mockito.Mockito.mock(com.uten.imp.security.SecurityContextCurrentUser.class);
        var interceptor=new NativeTaskReadScopeInterceptor(authority,users);
        for(String value:List.of("false","FALSE","off","NO","0","")) {
            var request=new org.springframework.mock.web.MockHttpServletRequest("GET","/api/master/warehouses/my-scope");
            request.addParameter("forRead",value);
            interceptor.preHandle(request,new org.springframework.mock.web.MockHttpServletResponse(),null);
            assertThat(request.getAttribute(ReadScopePublication.ATTRIBUTE)).isNull();
        }
        org.mockito.Mockito.verifyNoInteractions(authority,users);
        var subject=new com.uten.imp.security.AuthUser(java.util.UUID.randomUUID(),java.util.UUID.randomUUID(),"scope-reader",java.util.Set.of(),false,true,false);
        org.mockito.Mockito.when(users.get()).thenReturn(java.util.Optional.of(subject));
        org.mockito.Mockito.when(authority.scopeFor("native_warehouse_tasks",subject,false)).thenReturn("a".repeat(64));
        for(String value:List.of("true","TRUE","yes","1")) {
            var request=new org.springframework.mock.web.MockHttpServletRequest("GET","/api/master/warehouses/my-scope");
            request.addParameter("forRead",value);
            interceptor.preHandle(request,new org.springframework.mock.web.MockHttpServletResponse(),null);
            assertThat(request.getAttribute(ReadScopePublication.ATTRIBUTE)).isInstanceOf(ReadScopePublication.Proof.class);
        }
    }
}
