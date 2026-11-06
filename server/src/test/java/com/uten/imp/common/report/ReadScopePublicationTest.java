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
    @Test void sharedGoodsCostRoutesKeepTheirOwningAuthority() throws Exception {
        var path=java.nio.file.Path.of("../contracts/read-scope-domains/goods-cost-v1.json");
        if(!java.nio.file.Files.exists(path))path=java.nio.file.Path.of("contracts/read-scope-domains/goods-cost-v1.json");
        var fixture=new com.fasterxml.jackson.databind.ObjectMapper().readTree(java.nio.file.Files.readString(path));
        assertEquals(1,fixture.get("schemaVersion").asInt());
        for(var entry:fixture.get("cases")) {
            reset(authority);
            String domain=entry.get("domain").asText();
            when(authority.scopeFor(domain,subject)).thenReturn(domain);
            var request=new MockHttpServletRequest(entry.get("method").asText(),"/api"+entry.get("path").asText());
            var response=new MockHttpServletResponse();
            new MasterReadScopeInterceptor(authority,users).preHandle(request,response,null);
            new LegacyExportReadScopeInterceptor(authority,users).preHandle(request,response,null);
            var proof=(ReadScopePublication.Proof)request.getAttribute(ReadScopePublication.ATTRIBUTE);
            assertNotNull(proof,entry.toString());assertEquals(domain,proof.domain(),entry.toString());
            new ReportReadScopeAdvice(authority).beforeBodyWrite(Map.of("items",List.of()),null,MediaType.APPLICATION_JSON,null,
                    new ServletServerHttpRequest(request),new ServletServerHttpResponse(response));
            assertEquals(domain,response.getHeader(ReadScopePublication.HEADER),entry.toString());
            verify(authority,times(2)).scopeFor(domain,subject);
        }
    }
    @Test void completeSummaryAndOriginalRoutesPublishTheirOwnAuthorityAndOriginalBodyUsesTheSamePlan() {
        var routes=java.util.Map.ofEntries(
                java.util.Map.entry("/api/production/overproduction-rate/requests/facets","native_production_owner"),
                java.util.Map.entry("/api/business-columns/summaries","native_feature"),
                java.util.Map.entry("/api/platform-columns/expense_claim/definitions/summaries","native_feature"),
                java.util.Map.entry("/api/subcontract/short-deliveries/supplier-summary/goods/summaries","native_subcontract_owner"),
                java.util.Map.entry("/api/notices/00000000-0000-4000-8000-000000000001/blessings/summaries","native_feature"),
                java.util.Map.entry("/api/master/goods/periodic-bom/preparation/summaries","master_goods"),
                java.util.Map.entry("/api/master/goods/periodic-bom/preparation/products/00000000-0000-4000-8000-000000000001","master_goods"),
                java.util.Map.entry("/api/master/goods/periodic-bom/preparation/material-options","master_goods"),
                java.util.Map.entry("/api/workshop-material/settings/in-progress-pending/summaries","native_workshop_tasks"),
                java.util.Map.entry("/api/workshop-material/settings/in-progress-pending/products/00000000-0000-4000-8000-000000000001","native_workshop_tasks"),
                java.util.Map.entry("/api/workshop-material/choices/material-options","native_workshop_tasks"),
                java.util.Map.entry("/api/workshop-material/choices/pending","native_workshop_tasks"),
                java.util.Map.entry("/api/workshop-material/segments/00000000-0000-4000-8000-000000000001/material-changes","native_workshop_tasks"),
                java.util.Map.entry("/api/finance/asset-opening-groups/summaries","finance"),
                java.util.Map.entry("/api/finance/accounting-imports/summaries","finance"),
                java.util.Map.entry("/api/finance/auxiliary-imports/summaries","finance"),
                java.util.Map.entry("/api/finance/chart/imports/summaries","finance"),
                java.util.Map.entry("/api/finance/expense-analysis/note-imports/summaries","finance"),
                java.util.Map.entry("/api/finance/payable-statement-adjustments","finance"),
                java.util.Map.entry("/api/finance/statement-documents/reviews/00000000-0000-4000-8000-000000000001/summary","finance"),
                java.util.Map.entry("/api/finance/statement-documents/reviews/00000000-0000-4000-8000-000000000001/original-table","finance"));
        for(var route:routes.entrySet()) {
            reset(authority);String domain=route.getValue();String proofText="e".repeat(64);
            when(authority.scopeFor(domain,subject)).thenReturn(proofText);
            when(authority.scopeFor(domain,subject,false)).thenReturn(proofText);
            var request=new MockHttpServletRequest("GET",route.getKey());var response=new MockHttpServletResponse();
            new NativeTaskReadScopeInterceptor(authority,users).preHandle(request,response,null);
            new MasterReadScopeInterceptor(authority,users).preHandle(request,response,null);
            new BusinessDocumentReadScopeInterceptor(authority,users).preHandle(request,response,null);
            boolean original=route.getKey().endsWith("/original-table");
            try {
                if(original)interceptor.preHandle(request,response,null);
                var proof=(ReadScopePublication.Proof)request.getAttribute(ReadScopePublication.ATTRIBUTE);
                assertNotNull(proof,route.getKey());assertEquals(domain,proof.domain(),route.getKey());
                if(original)assertEquals(proofText,ReportReadPlan.current().readScopeVersion());
                new ReportReadScopeAdvice(authority).beforeBodyWrite(Map.of("items",List.of(),"readScopeVersion",proofText),null,MediaType.APPLICATION_JSON,null,
                        new ServletServerHttpRequest(request),new ServletServerHttpResponse(response));
                assertEquals(proofText,response.getHeader(ReadScopePublication.HEADER),route.getKey());
            } finally {if(original)interceptor.afterCompletion(request,response,null,null);}
        }
    }
    @Test void typedWhereUsedKeepsTheFirstNativeProfileAndRechecksItBeforePublishing() {
        when(authority.scopeFor("native_warehouse_tasks",subject,false)).thenReturn("a".repeat(64),"b".repeat(64));
        var request=new MockHttpServletRequest("GET","/api/production/reports/where-used/trace");
        var response=new MockHttpServletResponse();
        new NativeTaskReadScopeInterceptor(authority,users).preHandle(request,response,null);
        interceptor.preHandle(request,response,null);
        try {
            var proof=(ReadScopePublication.Proof)request.getAttribute(ReadScopePublication.ATTRIBUTE);
            assertEquals("native_warehouse_tasks",proof.domain());
            assertFalse(proof.businessTasks());
            assertEquals("a".repeat(64),ReportReadPlan.current().readScopeVersion());
            var error=assertThrows(ApiException.class,()->new ReportReadScopeAdvice(authority).beforeBodyWrite(
                    Map.of("items",List.of()),null,MediaType.APPLICATION_JSON,null,
                    new ServletServerHttpRequest(request),new ServletServerHttpResponse(response)));
            assertEquals(ErrorCode.READ_SCOPE_CHANGED,error.getCode());
            assertNull(response.getHeader(ReadScopePublication.HEADER));
            verify(authority,times(2)).scopeFor("native_warehouse_tasks",subject,false);
            verify(authority,never()).scopeFor("production",subject);
        } finally {interceptor.afterCompletion(request,response,null,null);}
        assertEquals(ReportReadPlan.ALL,ReportReadPlan.current());
    }
    @Test void ordinaryProductionReportsKeepTheirOriginalDomainWhenTheNativeFenceDoesNotMatch() {
        when(authority.scopeFor("production",subject)).thenReturn("a".repeat(64));
        var request=new MockHttpServletRequest("GET","/api/production/reports/plan/summary");
        var response=new MockHttpServletResponse();
        new NativeTaskReadScopeInterceptor(authority,users).preHandle(request,response,null);
        interceptor.preHandle(request,response,null);
        try {
            assertEquals("production",((ReadScopePublication.Proof)request.getAttribute(ReadScopePublication.ATTRIBUTE)).domain());
            var body=Map.of("items",List.of());
            assertSame(body,new ReportReadScopeAdvice(authority).beforeBodyWrite(body,null,MediaType.APPLICATION_JSON,null,
                    new ServletServerHttpRequest(request),new ServletServerHttpResponse(response)));
            assertEquals("a".repeat(64),response.getHeader(ReadScopePublication.HEADER));
            verify(authority,times(2)).scopeFor("production",subject);
            verify(authority,never()).scopeFor("native_warehouse_tasks",subject,false);
        } finally {interceptor.afterCompletion(request,response,null,null);}
        assertEquals(ReportReadPlan.ALL,ReportReadPlan.current());
    }
    @Test void costVersionPagesUseTheCompositeGoodsAndCustomerPublicationProof() {
        for(String suffix:List.of("","/versions","/00000000-0000-4000-8000-000000000001",
                "/00000000-0000-4000-8000-000000000001/snapshots","/snapshots/00000000-0000-4000-8000-000000000001","/templates")) {
        when(authority.scopeFor("master_goods_cost",subject)).thenReturn("a".repeat(64),"b".repeat(64));
        var request=new MockHttpServletRequest("GET","/api/master/goods/cost-sheets"+suffix);
        var response=new MockHttpServletResponse();
        new MasterReadScopeInterceptor(authority,users).preHandle(request,response,null);
        var error=assertThrows(ApiException.class,()->new ReportReadScopeAdvice(authority).beforeBodyWrite(Map.of("items",List.of()),
                null,MediaType.APPLICATION_JSON,null,new ServletServerHttpRequest(request),new ServletServerHttpResponse(response)));
        assertEquals(ErrorCode.READ_SCOPE_CHANGED,error.getCode());
        }
    }
    @Test void aPrivatePostReadCapturesAndRechecksTheSameReportScope() throws Exception {
        when(authority.scopeFor("finance",subject)).thenReturn("a".repeat(64),"b".repeat(64));
        var request=new MockHttpServletRequest("POST","/api/finance/reports/ar-ap/overview/search");
        request.setParameter("metadataReuse","true");request.setParameter("readScopeVersion","a".repeat(64));
        for(String key:List.of("includeCount","includeFacets","includeTotals"))request.setParameter(key,"false");
        var handler=new org.springframework.web.method.HandlerMethod(new ReportReadPlanInterceptorTest.PrivateQuery(),
                ReportReadPlanInterceptorTest.PrivateQuery.class.getDeclaredMethod("search"));
        var response=new MockHttpServletResponse();
        try {
            interceptor.preHandle(request,response,handler);
            assertFalse(ReportReadPlan.current().includeCount());
            assertEquals("a".repeat(64),ReportReadPlan.current().readScopeVersion());
            var error=assertThrows(ApiException.class,()->new ReportReadScopeAdvice(authority).beforeBodyWrite(Map.of("rows",List.of()),
                    null,MediaType.APPLICATION_JSON,null,new ServletServerHttpRequest(request),new ServletServerHttpResponse(response)));
            assertEquals(ErrorCode.READ_SCOPE_CHANGED,error.getCode());
        } finally {interceptor.afterCompletion(request,response,handler,null);}
        assertEquals(ReportReadPlan.ALL,ReportReadPlan.current());
    }
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
        var routes=Map.of("/api/master/goods/cost-sheets/actual/export","master_goods","/api/master/goods/cost-sheets/export","master_goods_cost","/api/master/clients/export","client",
                "/api/master/warehouses/export","master_warehouse","/api/sales/reports/export","sales",
                "/api/admin/audit-logs/export","audit","/api/operations/workbench/purchase/export","native_purchase_owner",
                "/api/operations/workbench/subcontract/export","native_subcontract_owner");
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
    @Test void bothProcurementPrintSnapshotsKeepTheOriginalOwnerProofUntilJsonPublication() {
        for(String module:List.of("purchase","subcontract")) for(boolean revoked:List.of(false,true)) {
            reset(authority);
            String domain="native_"+module+"_owner";
            when(authority.scopeFor(domain,subject,false)).thenReturn("a".repeat(64),(revoked?"b":"a").repeat(64));
            var request=new MockHttpServletRequest("GET","/app/api/"+module+"/orders/"+UUID.randomUUID()+"/print-data");
            request.setContextPath("/app");
            var response=new MockHttpServletResponse();
            new PurchasePrintReadScopeInterceptor(authority,users).preHandle(request,response,null);
            var proof=(ReadScopePublication.Proof)request.getAttribute(ReadScopePublication.ATTRIBUTE);
            assertEquals(domain,proof.domain());assertFalse(proof.businessTasks());
            var body=Map.of("billNo","原始打印单据","lines",List.of());
            var advice=new ReportReadScopeAdvice(authority);
            if(revoked) {
                var failure=assertThrows(ApiException.class,()->advice.beforeBodyWrite(body,null,MediaType.APPLICATION_JSON,null,
                        new ServletServerHttpRequest(request),new ServletServerHttpResponse(response)));
                assertEquals(ErrorCode.READ_SCOPE_CHANGED,failure.getCode());
                assertNull(response.getHeader(ReadScopePublication.HEADER));
                assertNull(response.getHeader("X-Uten-Read-Scope-Domain"));
            } else {
                assertSame(body,advice.beforeBodyWrite(body,null,MediaType.APPLICATION_JSON,null,
                        new ServletServerHttpRequest(request),new ServletServerHttpResponse(response)));
                assertEquals("a".repeat(64),response.getHeader(ReadScopePublication.HEADER));
                assertEquals(domain+":browse",response.getHeader("X-Uten-Read-Scope-Domain"));
            }
            verify(authority,times(2)).scopeFor(domain,subject,false);
        }
    }
    @Test void procurementPrintAndExportScopesDoNotMatchOtherMethodsOrNeighborRoutes() {
        var print=new PurchasePrintReadScopeInterceptor(authority,users);
        var export=new LegacyExportReadScopeInterceptor(authority,users);
        for(String path:List.of("/api/subcontract/orders/not-an-id/print-data","/api/subcontract/orders/"+UUID.randomUUID()+"/print-data/save",
                "/api/operations/workbench/subcontract/export/confirm")) {
            var request=new MockHttpServletRequest("GET",path);var response=new MockHttpServletResponse();
            print.preHandle(request,response,null);export.preHandle(request,response,null);
            assertNull(request.getAttribute(ReadScopePublication.ATTRIBUTE));
        }
        var request=new MockHttpServletRequest("POST","/api/subcontract/orders/"+UUID.randomUUID()+"/print-data");
        print.preHandle(request,new MockHttpServletResponse(),null);
        assertNull(request.getAttribute(ReadScopePublication.ATTRIBUTE));verifyNoInteractions(authority);
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

    @ReadOnlyReportQuery public void nativeCandidateHandler() { }
    @Test void declaredNativeCandidateOwnershipPrecedesTheBroaderReportPlanWithoutChangingLegacyGets() throws Exception {
        String nativeProof="a".repeat(64);
        when(authority.scopeFor("native_purchase_owner",subject,false)).thenReturn(nativeProof);
        when(authority.scopeFor("purchase",subject)).thenReturn("old-purchase-profile");
        var request=new MockHttpServletRequest("POST","/api/purchase/reports/order/detail");request.setContentType("application/x-www-form-urlencoded");request.setParameter("__facetField","billNo");
        var response=new MockHttpServletResponse();var handler=new org.springframework.web.method.HandlerMethod(this,getClass().getMethod("nativeCandidateHandler"));
        var nativeInterceptor=new NativeFacetCandidateInterceptor(authority,users);
        nativeInterceptor.preHandle(request,response,handler);interceptor.preHandle(request,response,handler);
        try {
            var proof=(ReadScopePublication.Proof)request.getAttribute(ReadScopePublication.ATTRIBUTE);
            assertEquals("native_purchase_owner",proof.domain());assertEquals(nativeProof,ReportReadPlan.current().readScopeVersion());
            var scope=com.uten.imp.common.web.NativeFacetCandidates.current();scope.completeRecords(Map.of("中文原单%_",2L));scope.snapshot(nativeProof,"b".repeat(64),"c".repeat(64));
            var page=scope.result(Map.of(),nativeProof);
            new ReportReadScopeAdvice(authority).beforeBodyWrite(page,null,MediaType.APPLICATION_JSON,null,new ServletServerHttpRequest(request),new ServletServerHttpResponse(response));
            assertEquals(page.readScopeVersion(),response.getHeader(ReadScopePublication.HEADER));assertEquals("native_purchase_owner:browse",response.getHeader("X-Uten-Read-Scope-Domain"));
            verify(authority,never()).scopeFor("purchase",subject);
        } finally {interceptor.afterCompletion(request,response,handler,null);nativeInterceptor.afterCompletion(request,response,handler,null);}
        var legacy=new MockHttpServletRequest("GET","/api/purchase/reports/order/detail");
        nativeInterceptor.preHandle(legacy,response,handler);interceptor.preHandle(legacy,response,handler);
        try {assertFalse(com.uten.imp.common.web.NativeFacetCandidates.active());assertEquals("purchase",((ReadScopePublication.Proof)legacy.getAttribute(ReadScopePublication.ATTRIBUTE)).domain());}
        finally {interceptor.afterCompletion(legacy,response,handler,null);}
    }

    @Test void overproductionLegacyFacetReauthorizesProductionOwnersAndRejectsLateLossAsScopeChanged() {
        String path="/api/production/overproduction-rate/requests/facets";
        assertEquals("native_production_owner",NativeFacetRoutes.find(path).profile());
        when(authority.scopeFor("native_production_owner",subject,false)).thenReturn("opening-owner","revoked-owner");
        var request=new MockHttpServletRequest("GET",path);var response=new MockHttpServletResponse();
        new NativeTaskReadScopeInterceptor(authority,users).preHandle(request,response,null);
        var error=assertThrows(ApiException.class,()->new ReportReadScopeAdvice(authority).beforeBodyWrite(
                Map.of("plan",List.of(NativeFacets.bucket("private-plan",1))),null,MediaType.APPLICATION_JSON,null,
                new ServletServerHttpRequest(request),new ServletServerHttpResponse(response)));
        assertEquals(ErrorCode.READ_SCOPE_CHANGED,error.getCode());assertNull(response.getHeader(ReadScopePublication.HEADER));
        verify(authority,never()).scopeFor(eq("native_feature"),any(),anyBoolean());
    }

    @Test void overproductionAndPrivateSupplierHeaderRetireTheirOwningProofOnLateScopeLoss() {
        for(var route:List.of(
                new String[]{"GET","/api/production/overproduction-rate/requests/facets","native_production_owner"},
                new String[]{"POST","/api/production/overproduction-rate/requests/facets","native_production_owner"},
                new String[]{"GET","/api/subcontract/short-deliveries/supplier-summary/goods/summaries","native_subcontract_owner"})) {
            reset(authority);
            String method=route[0],domain=route[2];
            String before="a".repeat(64),after="b".repeat(64);
            when(authority.scopeFor(domain,subject)).thenReturn(before,after);
            when(authority.scopeFor(domain,subject,false)).thenReturn(before,after);
            var request=new MockHttpServletRequest(method,route[1]);
            if(method.equals("POST")) {
                request.setContentType("application/x-www-form-urlencoded");
                request.addParameter("__facetField","plan");
            }
            var response=new MockHttpServletResponse();
            var candidates=new NativeFacetCandidateInterceptor(authority,users);
            new NativeTaskReadScopeInterceptor(authority,users).preHandle(request,response,null);
            candidates.preHandle(request,response,null);
            try {
                var proof=(ReadScopePublication.Proof)request.getAttribute(ReadScopePublication.ATTRIBUTE);
                assertNotNull(proof,method);assertEquals(domain,proof.domain(),method);
                var error=assertThrows(ApiException.class,()->new ReportReadScopeAdvice(authority).beforeBodyWrite(
                        Map.of("items",List.of()),null,MediaType.APPLICATION_JSON,null,
                        new ServletServerHttpRequest(request),new ServletServerHttpResponse(response)));
                assertEquals(ErrorCode.READ_SCOPE_CHANGED,error.getCode(),method);
                assertNull(response.getHeader(ReadScopePublication.HEADER),method);
                verify(authority,never()).scopeFor("native_feature",subject);
                verify(authority,never()).scopeFor("native_feature",subject,false);
            } finally {candidates.afterCompletion(request,response,null,null);}
        }
    }
    @Test void sharedCompleteSummaryFixtureKeepsExactOwningPublicationProfiles() throws Exception {
        var path=java.nio.file.Path.of(System.getProperty("uten.completeSummary.fixture","../contracts/read-scope-domains/complete-summary-v1.json"));
        if(!java.nio.file.Files.exists(path))path=java.nio.file.Path.of("contracts/read-scope-domains/complete-summary-v1.json");
        var fixture=new com.fasterxml.jackson.databind.ObjectMapper().readTree(java.nio.file.Files.readString(path));
        assertEquals(1,fixture.path("schemaVersion").asInt());assertEquals(14,fixture.path("cases").size());
        for(var entry:fixture.path("cases")) {
            reset(authority);
            String domain=entry.path("profile").asText(),version="c".repeat(64);
            when(authority.scopeFor(domain,subject)).thenReturn(version);
            when(authority.scopeFor(domain,subject,false)).thenReturn(version);
            var request=new MockHttpServletRequest(entry.path("method").asText(),"/api"+entry.path("path").asText());
            var response=new MockHttpServletResponse();var candidates=new NativeFacetCandidateInterceptor(authority,users);
            if(request.getMethod().equals("POST")) {request.setContentType("application/x-www-form-urlencoded");request.addParameter("__facetField","plan");}
            new NativeTaskReadScopeInterceptor(authority,users).preHandle(request,response,null);
            candidates.preHandle(request,response,null);
            new BusinessDocumentReadScopeInterceptor(authority,users).preHandle(request,response,null);
            try {
                var proof=(ReadScopePublication.Proof)request.getAttribute(ReadScopePublication.ATTRIBUTE);
                assertNotNull(proof,entry.toString());assertEquals(domain,proof.domain(),entry.toString());
                new ReportReadScopeAdvice(authority).beforeBodyWrite(Map.of("items",List.of()),null,MediaType.APPLICATION_JSON,null,
                        new ServletServerHttpRequest(request),new ServletServerHttpResponse(response));
                assertEquals(version,response.getHeader(ReadScopePublication.HEADER),entry.toString());
                assertEquals(entry.path("headerDomain").isNull()?null:entry.path("headerDomain").asText(),response.getHeader("X-Uten-Read-Scope-Domain"),entry.toString());
            } finally {candidates.afterCompletion(request,response,null,null);}
        }
        assertEquals(8,fixture.path("unclassified").size());
        for(var entry:fixture.path("unclassified")) {
            var request=new MockHttpServletRequest(entry.path("method").asText(),"/api"+entry.path("path").asText());
            var response=new MockHttpServletResponse();
            new NativeTaskReadScopeInterceptor(authority,users).preHandle(request,response,null);
            new BusinessDocumentReadScopeInterceptor(authority,users).preHandle(request,response,null);
            assertNull(request.getAttribute(ReadScopePublication.ATTRIBUTE),entry.toString());
        }
    }
}
