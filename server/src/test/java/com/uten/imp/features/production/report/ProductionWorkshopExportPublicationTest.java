package com.uten.imp.features.production.report;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.*;
import com.uten.imp.common.web.*;
import com.uten.imp.security.*;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.test.util.ReflectionTestUtils;
import java.util.*;
import java.util.function.Supplier;
import static org.mockito.Mockito.*;
import static org.junit.jupiter.api.Assertions.*;

class ProductionWorkshopExportPublicationTest {
    @Test void synchronousFallbackRechecksWorkshopScopeBeforeReturningAnyFile() {
        var service=mock(ProductionReportService.class); var xlsx=mock(XlsxExportService.class);
        var downloads=mock(WorkbookDownloadService.class); var users=mock(SecurityContextCurrentUser.class);
        var audit=mock(AuditService.class); var scopes=mock(ReadScopeVersionAuthority.class);
        @SuppressWarnings("unchecked") ObjectProvider<ReadScopeVersionAuthority> provider=mock(ObjectProvider.class);
        var actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"fixture",
                Set.of("production_execution:view","production_report:export"),false,true,false);
        when(users.get()).thenReturn(Optional.of(actor));when(provider.getObject()).thenReturn(scopes);
        var controller=new ProductionReportController(service,mock(ProductionWhereUsedQueryService.class),xlsx,downloads,audit,users);
        ReflectionTestUtils.setField(controller,"scopeVersions",provider);
        when(service.export(anyString(),anyMap(),isNull(),isNull())).thenReturn(new ExportPayload(List.of(),List.of(),0));
        when(xlsx.buildSource(any(),isNull(),eq("view_production"))).thenAnswer(call ->
                new XlsxExportService.SourceWorkbook(call.<Supplier<ExportPayload>>getArgument(0).get(),new byte[]{1}));
        when(downloads.protect(any(),eq(""))).thenReturn(new byte[]{2});
        when(scopes.scopeFor("native_workshop_tasks",actor)).thenReturn("before","after");
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->controller.export(
                "workshop-tasks",Map.of("status","IN_PROGRESS"),null,null,new ExportPasswordRequest(""))).getCode());
        verifyNoInteractions(audit);
        when(scopes.scopeFor("native_workshop_tasks",actor)).thenReturn("same");
        assertArrayEquals(new byte[]{2},controller.export("workshop-tasks",
                Map.of("status","IN_PROGRESS"),null,null,new ExportPasswordRequest("")).getBody());
    }
}
