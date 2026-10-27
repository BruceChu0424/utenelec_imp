package com.uten.imp.common.report;

import com.uten.imp.common.web.*;
import com.uten.imp.security.*;
import org.junit.jupiter.api.*;
import org.springframework.http.MediaType;
import org.springframework.http.server.*;
import org.springframework.mock.web.*;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class ReadScopePublicationTest {
    final AuthUser subject=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"reader",Set.of("sales_report:view"),false,true,false);
    final ReadScopeVersionAuthority authority=mock(ReadScopeVersionAuthority.class);
    final SecurityContextCurrentUser users=mock(SecurityContextCurrentUser.class);
    ReportReadPlanInterceptor interceptor;
    @BeforeEach void setup() {when(users.get()).thenReturn(Optional.of(subject));interceptor=new ReportReadPlanInterceptor(authority,users);}
    @Test void aMatchingProofPermitsRowsOnlyAndAMismatchForcesAllMetadataWithoutChangingThePredicate() {
        for(boolean matches:List.of(true,false)) {
            when(authority.scopeFor("sales",subject)).thenReturn("a".repeat(64));
            var request=new MockHttpServletRequest("GET","/api/sales/reports/ORDER/detail");
            request.addParameter("metadataReuse","true");request.addParameter("readScopeVersion",(matches?"a":"b").repeat(64));
            for(String flag:List.of("includeCount","includeFacets","includeTotals"))request.addParameter(flag,"false");
            var response=new MockHttpServletResponse();
            try {
                interceptor.preHandle(request,response,null);
                assertEquals(!matches,ReportReadPlan.current().includeCount());
                assertEquals(!matches,ReportReadPlan.current().includeFacets());
                assertEquals("a".repeat(64),ReportReadPlan.current().readScopeVersion());
                assertNull(response.getHeader(ReadScopePublication.HEADER));
            } finally {interceptor.afterCompletion(request,response,null,null);}
            assertEquals(ReportReadPlan.ALL,ReportReadPlan.current());
        }
    }
    @Test void aGrantRevokedDuringAQueryCannotPublishItsBodyOrItsOriginalProof() {
        when(authority.scopeFor("sales",subject)).thenReturn("a".repeat(64),"b".repeat(64));
        var request=new MockHttpServletRequest("GET","/api/sales/reports/ORDER/detail");var response=new MockHttpServletResponse();
        interceptor.preHandle(request,response,null);
        try {
            var body=new com.uten.imp.features.sales.report.ReportTableResponse(List.of(),List.of(),Map.of(),1,50,0,0);
            assertEquals("a".repeat(64),body.readScopeVersion());assertNotNull(body.statisticsGeneratedAt());
            var error=assertThrows(ApiException.class,() -> new ReportReadScopeAdvice(authority).beforeBodyWrite(body,null,
                    MediaType.APPLICATION_JSON,null,new ServletServerHttpRequest(request),new ServletServerHttpResponse(response)));
            assertEquals(ErrorCode.READ_SCOPE_CHANGED,error.getCode());assertNull(response.getHeader(ReadScopePublication.HEADER));
        } finally {interceptor.afterCompletion(request,response,null,null);}
    }
    @Test void successfulArrayLookupsPublishTheSameFreshProofAndErrorResponsesDoNotRecurse() {
        when(authority.scopeFor("client",subject)).thenReturn("a".repeat(64));
        var request=new MockHttpServletRequest("GET","/api/master/clients/lookup");var response=new MockHttpServletResponse();
        new MasterReadScopeInterceptor(authority,users).preHandle(request,response,null);
        var body=List.of(Map.of("id",UUID.randomUUID(),"name","授权标签"));
        assertSame(body,new ReportReadScopeAdvice(authority).beforeBodyWrite(body,null,MediaType.APPLICATION_JSON,null,
                new ServletServerHttpRequest(request),new ServletServerHttpResponse(response)));
        assertEquals("a".repeat(64),response.getHeader(ReadScopePublication.HEADER));
        response.setStatus(403);reset(authority);
        new ReportReadScopeAdvice(authority).beforeBodyWrite(Map.of("code","FORBIDDEN"),null,MediaType.APPLICATION_JSON,null,
                new ServletServerHttpRequest(request),new ServletServerHttpResponse(response));
        verifyNoInteractions(authority);
    }
    @Test void asyncRedispatchDoesNotReplaceTheOriginalAuthorizationWithANewerProof() {
        when(authority.scopeFor("sales",subject)).thenReturn("a".repeat(64),"b".repeat(64));
        var request=new MockHttpServletRequest("GET","/api/sales/reports/ORDER/detail");var response=new MockHttpServletResponse();
        interceptor.preHandle(request,response,null);interceptor.afterConcurrentHandlingStarted(request,response,null);
        interceptor.preHandle(request,response,null);
        try {assertEquals("a".repeat(64),ReportReadPlan.current().readScopeVersion());}
        finally {interceptor.afterCompletion(request,response,null,null);}
        verify(authority,times(1)).scopeFor("sales",subject);
    }
    @Test void everyPagedMasterReaderRejectsAChangedScopeBeforePublishingItsNextPrintPage() {
        var domains=Map.of("clients","client","suppliers","supplier","goods","master_goods","accounts","master_account",
                "currencies","master_currency","colors","master_color","units","master_unit","moulds","master_mould","warehouses","master_warehouse");
        for(var entry:domains.entrySet()) {
            reset(authority);
            when(authority.scopeFor(entry.getValue(),subject)).thenReturn("a".repeat(64),"b".repeat(64));
            var request=new MockHttpServletRequest("GET","/api/master/"+entry.getKey());
            var response=new MockHttpServletResponse();
            new MasterReadScopeInterceptor(authority,users).preHandle(request,response,null);
            var error=assertThrows(ApiException.class,()->new ReportReadScopeAdvice(authority).beforeBodyWrite(
                    Map.of("items",List.of(Map.of("name","退休范围"))),null,MediaType.APPLICATION_JSON,null,
                    new ServletServerHttpRequest(request),new ServletServerHttpResponse(response)),entry.getKey());
            assertEquals(ErrorCode.READ_SCOPE_CHANGED,error.getCode());
            assertNull(response.getHeader(ReadScopePublication.HEADER));
        }
    }
    @Test void settlementMethodPagesUseTheirOwnConfigurationScopeWithoutImposingAnotherMasterPermission() {
        when(authority.scopeFor("master_settlement_method",subject)).thenReturn("a".repeat(64));
        var request=new MockHttpServletRequest("GET","/api/master/reference-methods/settlement-admin/page");
        var response=new MockHttpServletResponse();
        new MasterReadScopeInterceptor(authority,users).preHandle(request,response,null);
        new ReportReadScopeAdvice(authority).beforeBodyWrite(Map.of("items",List.of()),null,MediaType.APPLICATION_JSON,null,
                new ServletServerHttpRequest(request),new ServletServerHttpResponse(response));
        assertEquals("a".repeat(64),response.getHeader(ReadScopePublication.HEADER));
    }
    @Test void nativePublicationKeepsItsActualHandlerTaskModeAndDoesNotBorrowTheBrowseProof() {
        for(boolean task:List.of(false,true)) {
            reset(authority);
            when(authority.scopeFor("native_warehouse_tasks",subject,task)).thenReturn("a".repeat(64));
            var request=new MockHttpServletRequest("POST","/api/warehouse/history/receipts/facets");
            var response=new MockHttpServletResponse();
            assertEquals("a".repeat(64),ReadScopePublication.capture(request,authority,users,"native_warehouse_tasks",task));
            var proof=(ReadScopePublication.Proof)request.getAttribute(ReadScopePublication.ATTRIBUTE);
            assertSame(subject,proof.subject());assertEquals(task,proof.businessTasks());
            var body=Map.of("items",List.of());
            assertSame(body,new ReportReadScopeAdvice(authority).beforeBodyWrite(body,null,MediaType.APPLICATION_JSON,null,
                    new ServletServerHttpRequest(request),new ServletServerHttpResponse(response)));
            assertEquals("native_warehouse_tasks:"+(task?"task":"browse"),response.getHeader("X-Uten-Read-Scope-Domain"));
            assertEquals("a".repeat(64),response.getHeader(ReadScopePublication.HEADER));
            verify(authority,times(2)).scopeFor("native_warehouse_tasks",subject,task);
            verify(authority,never()).scopeFor(anyString(),any());
        }
    }
    @Test void synchronousExportFamiliesKeepTheirOwnAuthorityUntilTheLastBytePublication() {
        var routes=Map.of("/api/master/goods/cost-sheets/actual/export","master_goods","/api/master/clients/export","client",
                "/api/master/warehouses/export","master_warehouse","/api/sales/reports/export","sales",
                "/api/admin/audit-logs/export","audit","/api/operations/workbench/purchase/export","native_purchase_owner");
        for(var route:routes.entrySet()) {
            reset(authority);
            if(route.getValue().startsWith("native_"))when(authority.scopeFor(route.getValue(),subject,false)).thenReturn("a".repeat(64),"b".repeat(64));
            else when(authority.scopeFor(route.getValue(),subject)).thenReturn("a".repeat(64),"b".repeat(64));
            var request=new MockHttpServletRequest("POST",route.getKey());var response=new MockHttpServletResponse();
            new LegacyExportReadScopeInterceptor(authority,users).preHandle(request,response,null);
            var failure=assertThrows(ApiException.class,()->new ReportReadScopeAdvice(authority).beforeBodyWrite(new byte[]{1,2,3},null,
                    MediaType.APPLICATION_OCTET_STREAM,null,new ServletServerHttpRequest(request),new ServletServerHttpResponse(response)));
            assertEquals(ErrorCode.READ_SCOPE_CHANGED,failure.getCode());assertEquals(0,response.getContentAsByteArray().length);
        }
    }
    @Test void aNativeScopeRevokedWhileCandidateRowsLoadPublishesNeitherRowsNorHeaders() {
        when(authority.scopeFor("native_workshop_tasks",subject,false)).thenReturn("a".repeat(64),"b".repeat(64));
        var request=new MockHttpServletRequest("POST","/api/production/workshop/tasks/facets");
        var response=new MockHttpServletResponse();
        ReadScopePublication.capture(request,authority,users,"native_workshop_tasks",false);
        var failure=assertThrows(ApiException.class,()->new ReportReadScopeAdvice(authority).beforeBodyWrite(
                Map.of("items",List.of("old authorized row")),null,MediaType.APPLICATION_JSON,null,
                new ServletServerHttpRequest(request),new ServletServerHttpResponse(response)));
        assertEquals(ErrorCode.READ_SCOPE_CHANGED,failure.getCode());
        assertNull(response.getHeader(ReadScopePublication.HEADER));assertNull(response.getHeader("X-Uten-Read-Scope-Domain"));
    }
}
