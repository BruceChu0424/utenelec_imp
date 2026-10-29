package com.uten.imp.features.reporting.export;

import com.uten.imp.features.operations.workbench.WorkbenchReportExportSource;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.*;
import com.uten.imp.security.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.io.TempDir;
import java.nio.file.Path;
import java.time.OffsetDateTime;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class ReportExportServiceTest {
    @TempDir Path directory;
    final UUID owner=UUID.randomUUID();
    final AuthUser user=new AuthUser(owner,UUID.randomUUID(),"fixture",Set.of("sales_report:view","sales_report:export"),false,true,false);
    ReportExportRepository repository;
    SubmitterPrincipalRestorer restorer;
    SecurityContextCurrentUser users;
    ObjectMapper mapper=new ObjectMapper();
    ReportExportService service;
    ReportExportBuildIdentity buildIdentity;
    ExportRateLimiter rateLimiter;
    ReadScopeVersionAuthority readScopes;
    org.springframework.beans.factory.ObjectProvider<com.uten.imp.common.export.ExportProjectionAccessGuard> projectionAccess;
    @BeforeEach void setup() {
        repository=mock(ReportExportRepository.class);restorer=mock(SubmitterPrincipalRestorer.class);users=mock(SecurityContextCurrentUser.class);
        when(users.get()).thenReturn(Optional.of(user));
        when(restorer.restore(owner,1,1L)).thenReturn(user);
        when(restorer.currentStamps(owner)).thenReturn(Optional.of(new SubmitterPrincipalRestorer.AuthorizationStamps(1,1)));
        buildIdentity=mock(ReportExportBuildIdentity.class);when(buildIdentity.revision()).thenReturn("fixture-build");rateLimiter=mock(ExportRateLimiter.class);
        readScopes=mock(ReadScopeVersionAuthority.class);when(readScopes.scopeFor(anyString(),any())).thenReturn("a".repeat(64));
        projectionAccess=mock();
        service=new ReportExportService(repository,users,restorer,mapper,buildIdentity,rateLimiter,readScopes,projectionAccess,directory.toString());
    }
    ReportExportRequest request(UUID id) {return new ReportExportRequest(id,"sales","ORDER/detail",Map.of("dateFrom","2020-01-01"),null,null,null);}
    ReportExportRepository.Job job(ReportExportRequest request) throws Exception {
        return new ReportExportRepository.Job(request.id(),owner,1,1,mapper.writeValueAsString(request),"PENDING",false,0,0,
                OffsetDateTime.now(),null,null,null,null,null,0,ReportExportBuildIdentity.CONTRACT,"fixture-build","a".repeat(64));
    }
    @Test void sameIdentityAndConditionsRecoverTheOriginalTaskWithoutAnotherInsert() throws Exception {
        var request=request(UUID.randomUUID());when(repository.find(request.id())).thenReturn(Optional.of(job(request)));
        assertEquals(request.id(),service.submit(request).id());
        verify(repository,never()).insert(any(),any(),anyLong(),anyLong(),anyString(),anyString(),anyString());
        verify(repository,never()).active(any());
    }
    @Test void unitReceiptCarriesTheExactPersistedRequestOnlyForItsCurrentOwnerAndScope() throws Exception {
        var unitUser=new AuthUser(owner,user.getEmployeeId(),"unit-export",Set.of("unit:export"),false,true,false);
        when(users.get()).thenReturn(Optional.of(unitUser));when(restorer.restore(owner,1,1L)).thenReturn(unitUser);
        String filter="{ \"keyword\" : \"M&1\", \"nullFields\":[\"name\"], \"status\":\"使用\" }";
        var request=new ReportExportRequest(UUID.randomUUID(),"master","unit",Map.of("filter",filter),null,null,null);
        var row=job(request);when(repository.find(request.id())).thenReturn(Optional.of(row));
        var view=service.get(request.id());
        assertEquals(request,view.request());
        assertEquals(filter,view.request().parameters().get("filter"),"opaque original filter string must not be normalized/replaced");
        assertThrows(UnsupportedOperationException.class,()->view.request().parameters().put("filter","{}"));
        var wire=mapper.copy().registerModule(new com.fasterxml.jackson.datatype.jsr310.JavaTimeModule());
        var encoded=wire.readTree(wire.writeValueAsString(view));
        assertEquals(request.id().toString(),encoded.path("id").asText());
        assertEquals("PENDING",encoded.path("status").asText());
        assertEquals(request.id().toString(),encoded.path("request").path("id").asText());
        assertFalse(encoded.path("request").has("password"));
        when(readScopes.scopeFor(anyString(),any())).thenReturn("b".repeat(64));
        assertEquals(request.id(),service.get(request.id()).id(),"existing metadata behavior survives scope retirement");
        assertNull(service.get(request.id()).request(),"retired data/projection filters are not returned as a receipt proof");
        when(users.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),user.getEmployeeId(),"other",Set.of("unit:export"),false,true,false)));
        assertEquals(ErrorCode.NOT_FOUND,assertThrows(ApiException.class,()->service.get(request.id())).getCode());
    }
    @Test void oldConsumersAndOtherReportDomainsKeepTheirExistingMetadataContract() throws Exception {
        var request=request(UUID.randomUUID());when(repository.find(request.id())).thenReturn(Optional.of(job(request)));
        var view=service.get(request.id());
        assertEquals(request.id(),view.id());assertEquals("sales",view.domain());assertEquals("xlsx",view.format());
        assertNull(view.request(),"new proof is not a generic private filter disclosure");
        var oldConstructor=new ReportExportService.View(view.id(),view.domain(),view.report(),view.format(),view.status(),
                view.cancelRequested(),view.rows(),view.bytes(),view.snapshotAt(),view.error(),view.createdAt(),view.finishedAt());
        assertNull(oldConstructor.request());assertEquals(view.id(),oldConstructor.id());
    }
    @Test void nativeProjectionRoundTripKeepsSameJobIdempotencyAndStillRejectsChangedLayout() throws Exception {
        mapper=com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration.domainObjectMapper();
        var unitUser=new AuthUser(owner,user.getEmployeeId(),"unit-export",Set.of("unit:export"),false,true,false);
        when(users.get()).thenReturn(Optional.of(unitUser));when(restorer.restore(owner,1,1L)).thenReturn(unitUser);
        var master=mock(com.uten.imp.application.port.MasterReportExportPort.class);
        when(master.projection(any())).thenAnswer(call->((ReportExportRequest)call.getArgument(0)).columnProjection());
        when(projectionAccess.getObject()).thenReturn(mock(com.uten.imp.common.export.ExportProjectionAccessGuard.class));
        service=new ReportExportService(repository,users,restorer,mapper,buildIdentity,rateLimiter,readScopes,projectionAccess,master,null,directory.toString());
        UUID id=UUID.randomUUID();
        String projection="""
                {"tableKey":"master.unit","scope":"master_unit","columns":[
                {"key":"code","label":"编号","width":120.5,"type":"text"},
                {"key":"name","label":"单位名称","width":220,"type":"text"},
                {"key":"status","label":"状态","width":72,"type":"text"}]}
                """;
        var columns=mapper.readValue(projection,com.uten.imp.common.export.TableColumnProjection.class);
        var request=new ReportExportRequest(id,"master","unit",Map.of("filter","{}"),null,null,columns);
        var stored=job(request);when(repository.find(id)).thenReturn(Optional.of(stored));
        assertEquals(request,service.decode(stored.request()));
        assertEquals(id,service.submit(request).id());
        verify(repository,never()).insert(any(),any(),anyLong(),anyLong(),anyString(),anyString(),anyString());
        var changed=mapper.readValue(projection.replace("120.5","121.5"),com.uten.imp.common.export.TableColumnProjection.class);
        var other=new ReportExportRequest(id,"master","unit",request.parameters(),null,null,changed);
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->service.submit(other)).getCode());
    }
    @Test void aDifferentRequestCannotReuseTheSameIdentity() throws Exception {
        UUID id=UUID.randomUUID();when(repository.find(id)).thenReturn(Optional.of(job(request(id))));
        var changed=new ReportExportRequest(id,"sales","ORDER/summary",Map.of(),null,null,null);
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> service.submit(changed)).getCode());
        verify(repository,never()).insert(any(),any(),anyLong(),anyLong(),anyString(),anyString(),anyString());
    }
    @Test void anotherUserCannotProbeTheTaskAndPermissionChangesCloseDownloadAuthorization() throws Exception {
        var request=request(UUID.randomUUID());when(repository.find(request.id())).thenReturn(Optional.of(job(request)));
        when(users.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"other",user.getPermissions(),false,true,false)));
        assertEquals(ErrorCode.NOT_FOUND,assertThrows(ApiException.class,() -> service.get(request.id())).getCode());
        when(users.get()).thenReturn(Optional.of(user));
        when(restorer.restore(owner,1,1L)).thenThrow(new SubmitterPrincipalRestorer.PrincipalChangedException("revoked"));
        assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,() -> service.authorized(request.id())).getCode());
    }
    @Test void impersonationCannotCreateOrDownloadExportTasks() throws Exception {
        var impersonated=new AuthUser(owner,user.getEmployeeId(),"fixture",user.getPermissions(),false,true,false,false,UUID.randomUUID());
        when(users.get()).thenReturn(Optional.of(impersonated));
        assertThrows(ApiException.class,() -> service.submit(request(UUID.randomUUID())));
        var request=request(UUID.randomUUID());when(repository.find(request.id())).thenReturn(Optional.of(job(request)));
        assertEquals(ErrorCode.IMPERSONATION_READ_ONLY,assertThrows(ApiException.class,() -> service.authorized(request.id())).getCode());
    }
    @Test void disabledStorageAndCredentialParametersNeverCreateAJob() {
        var disabled=new ReportExportService(repository,users,restorer,mapper,buildIdentity,rateLimiter,readScopes,projectionAccess,"");
        assertFalse(disabled.available());assertThrows(ApiException.class,() -> disabled.submit(request(UUID.randomUUID())));
        var credential=new ReportExportRequest(UUID.randomUUID(),"sales","ORDER/detail",Map.of("password","do-not-persist"),null,null,null);
        assertThrows(ApiException.class,() -> service.submit(credential));
        verify(repository,never()).insert(any(),any(),anyLong(),anyLong(),anyString(),anyString(),anyString());
    }
    @Test void recentTasksCheckStampsOnceAndNeverListAnOldAuthorizationGeneration() throws Exception {
        var request=request(UUID.randomUUID());var current=job(request);
        var old=new ReportExportRepository.Job(UUID.randomUUID(),owner,1,0,current.request(),"PENDING",false,0,0,
                OffsetDateTime.now(),null,null,null,null,null,0,ReportExportBuildIdentity.CONTRACT,"fixture-build","a".repeat(64));
        when(repository.recent(owner)).thenReturn(List.of(current,old));
        assertEquals(List.of(current.id()),service.recent().stream().map(ReportExportService.View::id).toList());
        verify(restorer).currentStamps(owner);verify(restorer,never()).restore(any(),anyLong(),any());
    }
    @Test void queuedTasksNeverSilentlyChangeReaderAfterAnUpgrade() throws Exception {
        var queued=job(request(UUID.randomUUID()));
        assertDoesNotThrow(() -> service.requireCompatibleReader(queued));
        when(buildIdentity.revision()).thenReturn("updated-build");
        var error=assertThrows(ApiException.class,() -> service.requireCompatibleReader(queued));
        assertEquals(ErrorCode.CONFLICT,error.getCode());
    }
    @Test void aDataScopeChangeWithTheSameRoleStampsBlocksTheFileButKeepsTheOriginalTaskReadable() throws Exception {
        var request=request(UUID.randomUUID());var row=job(request);
        when(repository.find(request.id())).thenReturn(Optional.of(row));
        assertDoesNotThrow(() -> service.requireCurrentAccess(row));
        when(readScopes.scopeFor(anyString(),any())).thenReturn("b".repeat(64));
        assertEquals(request.id(),service.get(request.id()).id());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> service.authorizedArtifact(request.id())).getCode());
        verify(restorer,times(2)).restore(owner,1,1L);
    }
    @Test void exportPermissionRetainsTheOriginalSixDomainContractWhileWhereUsedStillRequiresItsOwnView() {
        for(String domain:List.of("sales","purchase","subcontract","production","stock","finance")) {
            var exportOnly=new AuthUser(owner,user.getEmployeeId(),"export-only",Set.of(domain+"_report:export"),false,true,false);
            assertDoesNotThrow(()->ReportExportService.authorizeDomain(exportOnly,domain));
            assertThrows(ApiException.class,()->ReportExportService.authorizeDomain(exportOnly,"where_used"));
        }
        var independent=new AuthUser(owner,user.getEmployeeId(),"engineer",Set.of("production_where_used:view","production_where_used:export"),false,true,false);
        assertDoesNotThrow(()->ReportExportService.authorizeDomain(independent,"where_used"));
    }
    @Test void purchaseTasksKeepTheirIndependentReadAuthorityAndStrictFilterContract() {
        var request=new ReportExportRequest(UUID.randomUUID(),"workbench_purchase","tasks",Map.of("search.goods","开关_20%"),null,null,null);
        var permitted=new AuthUser(owner,user.getEmployeeId(),"tasks",Set.of("purchase_order:view","purchase_report:export"),false,true,false);
        assertDoesNotThrow(()->ReportExportService.authorizeRequest(permitted,request));
        assertDoesNotThrow(()->WorkbenchReportExportSource.validate(request));
        var reportOnly=new AuthUser(owner,user.getEmployeeId(),"reports",Set.of("purchase_report:view","purchase_report:export"),false,true,false);
        assertThrows(ApiException.class,()->ReportExportService.authorizeRequest(reportOnly,request));
        assertEquals("view_purchase",ReportExportSource.scope(request));
        assertThrows(ApiException.class,()->WorkbenchReportExportSource.validate(new ReportExportRequest(UUID.randomUUID(),"workbench_purchase","tasks",
                Map.of("dateFrom","2026-10-26","dateTo","2026-10-01"),null,null,null)));
        assertThrows(ApiException.class,()->WorkbenchReportExportSource.validate(new ReportExportRequest(UUID.randomUUID(),"workbench_purchase","tasks",
                Map.of("dateFrom","not-a-date"),null,null,null)));
    }

    @Test void subcontractTasksKeepIndependentOwnerAuthorityAndOnlyTheMatchingProgressOrHistoryProjection() {
        var permitted=new AuthUser(owner,user.getEmployeeId(),"tasks",Set.of("subcontract_order:view","subcontract_report:export"),false,true,false);
        var purchaseOnly=new AuthUser(owner,user.getEmployeeId(),"purchase",Set.of("purchase_order:view","purchase_report:export"),false,true,false);
        for(String stage:List.of("IN_PROGRESS","COMPLETED")) {
            var request=new ReportExportRequest(UUID.randomUUID(),"workbench_subcontract","tasks",Map.of("status",stage,"search.goodsCode","A_20%"),null,null,null);
            assertDoesNotThrow(()->ReportExportService.authorizeRequest(permitted,request));
            assertThrows(ApiException.class,()->ReportExportService.authorizeRequest(purchaseOnly,request));
            assertDoesNotThrow(()->WorkbenchReportExportSource.validate(request));
            assertEquals("view_subcontract",ReportExportSource.scope(request));
        }
        for(String stage:List.of("","WAITING_ORDER","DRAW_OPEN"))
            assertThrows(ApiException.class,()->WorkbenchReportExportSource.validate(new ReportExportRequest(UUID.randomUUID(),
                    "workbench_subcontract","tasks",Map.of("status",stage),null,null,null)));
    }

    @Test void taskArtifactsRecheckTheNativeOwnerGenerationAfterAMakerOrHandoverChange() throws Exception {
        for(String module:List.of("purchase","subcontract")) {
            var actor=new AuthUser(owner,user.getEmployeeId(),"tasks",Set.of(module+"_order:view",module+"_report:export"),false,true,false);
            when(users.get()).thenReturn(Optional.of(actor));
            when(restorer.restore(owner,1,1L)).thenReturn(actor);
            var request=new ReportExportRequest(UUID.randomUUID(),"workbench_"+module,"tasks",Map.of("status","COMPLETED"),null,null,null);
            var row=job(request);when(repository.find(request.id())).thenReturn(Optional.of(row));
            when(readScopes.scopeFor("native_"+module+"_owner",actor)).thenReturn("a".repeat(64));
            assertEquals(row,service.authorizedArtifact(request.id()));
            when(readScopes.scopeFor("native_"+module+"_owner",actor)).thenReturn("b".repeat(64));
            assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->service.authorizedArtifact(request.id())).getCode());
            assertEquals(row,service.authorized(request.id()));
        }
    }
}
