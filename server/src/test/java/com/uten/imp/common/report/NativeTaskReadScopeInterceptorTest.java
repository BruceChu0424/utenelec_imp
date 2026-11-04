package com.uten.imp.common.report;

import java.util.List;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class NativeTaskReadScopeInterceptorTest {
    private static final String ID="12345678-1234-1234-1234-123456789abc";
    @Test void pagedDirectoriesKeepTheirOriginalReadProfileAndDoNotClassifyCommands() {
        for(String path:List.of("/api/admin/users/provision-candidates", "/api/admin/users/provision-candidates/page",
                "/api/admin/impersonation/targets", "/api/admin/impersonation/targets/page",
                "/api/admin/impersonation/targets/departments", "/api/company-files/principals",
                "/api/company-files/principals/page", "/api/notices/audience/employees/page", "/api/admin/audit-logs/actors"))
            assertThat(NativeTaskReadScopeInterceptor.profile(path)).isEqualTo("native_feature");
        for(String path:List.of("/api/admin/impersonation/enter", "/api/admin/impersonation/start",
                "/api/company-files/principals/page/save", "/api/admin/users/provision-candidates/page/confirm"))
            assertThat(NativeTaskReadScopeInterceptor.profile(path)).isNull();
    }
    @Test void dedicatedEmployeeCandidateReadsKeepAProfileWithoutMatchingAdjacentCommands() {
        for(String path:List.of("/api/master/clients/access-candidates", "/api/master/clients/access-candidates/query",
                "/api/admin/data-handovers/candidates", "/api/admin/data-handovers/candidates/query")) {
            assertThat(NativeTaskReadScopeInterceptor.profile(path)).isEqualTo("native_feature");
            assertThat(NativeTaskReadScopeInterceptor.profile(path+"/save")).isNull();
        }
        assertThat(NativeTaskReadScopeInterceptor.profile("/api/admin/data-handovers")).isNull();
    }
    @Test void businessReferencesKeepTheOriginalResourceRevocationDomains() {
        for (String path : List.of("/api/business-references/clients", "/api/business-references/clients/search-context"))
            assertThat(NativeTaskReadScopeInterceptor.profile(path)).isEqualTo("client");
        for (String path : List.of("/api/business-references/goods", "/api/business-references/goods/search-category-ids",
                "/api/business-references/goods/facet-values"))
            assertThat(NativeTaskReadScopeInterceptor.profile(path)).isEqualTo("master_goods");
        assertThat(NativeTaskReadScopeInterceptor.profile("/api/business-references/suppliers")).isEqualTo("supplier");
        assertThat(NativeTaskReadScopeInterceptor.profile("/api/business-references/accounts")).isEqualTo("master_account");
        assertThat(NativeTaskReadScopeInterceptor.profile("/api/business-references/warehouses")).isEqualTo("master_warehouse");
        // Existing helpers continue through MasterReadScopeInterceptor, not a feature-wide override.
        for (String path : List.of("/api/master/clients/lookup", "/api/master/clients/dict",
                "/api/master/goods/lookup", "/api/master/suppliers/lookup"))
            assertThat(NativeTaskReadScopeInterceptor.profile(path)).isNull();
        assertThat(NativeTaskReadScopeInterceptor.profile("/api/business-references/suppliers/delete")).isNull();
        assertThat(NativeTaskReadScopeInterceptor.profile("/api/production/workshop-assignment-defaults"))
                .isEqualTo("native_workshop_tasks");
        assertThat(NativeTaskReadScopeInterceptor.profile("/api/production/workshop-assignment-defaults/delete")).isNull();
    }
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
