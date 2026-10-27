package com.uten.imp.features.operations.workbench;

import com.uten.imp.application.port.ExportLimitPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPasswordRequest;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.security.access.prepost.PreAuthorize;

import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class FulfillmentWorkbenchExportControllerTest {
    @Test void subcontractDownloadRetainsTheCurrentFiltersProjectionAndIndependentAuthority() {
        var queries=mock(FulfillmentWorkbenchQueryService.class);var writer=mock(XlsxExportService.class);
        var users=mock(SecurityContextCurrentUser.class);when(users.get()).thenReturn(Optional.empty());
        var limits=mock(ExportLimitPort.class);when(limits.exportMaxRows()).thenReturn(500);
        var columns=List.of(new ExportColumn("goods","委外件名称",ExportColumn.TEXT));
        List<Map<String,Object>> rows=List.of(Map.of("goods","轴套"));
        var payload=new ExportPayload(columns,rows,1);
        when(queries.exportSubcontract(eq("IN_PROGRESS"),eq("轴套"),eq(""),isNull(),isNull(),any(),eq(500)))
                .thenReturn(payload);
        when(writer.build(eq(columns),eq(rows),isNull(),eq("view_subcontract"))).thenReturn(new byte[]{4,5});
        var controller=new FulfillmentWorkbenchExportController(queries,writer,new WorkbookDownloadService(),users,mock(AuditService.class),limits);
        var response=controller.subcontract("IN_PROGRESS","","轴套",null,null,"docNo","desc",null,null,null,null,
                Map.of("f.planNo","WL-1","search.goodsCode","ABC_20%"),new ExportPasswordRequest(""));
        assertArrayEquals(new byte[]{4,5},response.getBody());
        assertTrue(response.getHeaders().getFirst("Content-Disposition").contains("subcontract_tasks.xlsx"));
        var table=ArgumentCaptor.forClass(FulfillmentWorkbenchTableQuery.class);
        verify(queries).exportSubcontract(eq("IN_PROGRESS"),eq("轴套"),eq(""),isNull(),isNull(),table.capture(),eq(500));
        assertEquals(Map.of("planNo","WL-1","search.goodsCode","ABC_20%"),table.getValue().filters());
        var method=java.util.Arrays.stream(FulfillmentWorkbenchExportController.class.getDeclaredMethods())
                .filter(candidate->candidate.getName().equals("subcontract")).findFirst().orElseThrow();
        assertTrue(method.getAnnotation(PreAuthorize.class).value().contains("subcontract_report:export"));
        assertTrue(method.getAnnotation(PreAuthorize.class).value().contains("subcontract_order:view"));
    }
    @Test
    void everyDownloadUsesTheCurrentConfiguredLimitAndNeverWritesATruncatedWorkbook() {
        var queries = mock(FulfillmentWorkbenchQueryService.class);
        var writer = mock(XlsxExportService.class);
        var user = mock(SecurityContextCurrentUser.class);
        when(user.get()).thenReturn(Optional.empty());
        var audit = mock(AuditService.class);
        var limits = mock(ExportLimitPort.class);
        when(limits.exportMaxRows()).thenReturn(2, 1);
        var columns = List.of(new ExportColumn("goodsName", "货品名称", ExportColumn.TEXT));
        List<Map<String, Object>> rows = List.of(Map.of("goodsName", "开关一"), Map.of("goodsName", "开关二"));
        var payload = new ExportPayload(columns, rows, 2);
        when(queries.exportPurchase(eq("WAITING_ORDER"), eq("开关"), eq(""), isNull(), isNull(), any(), eq(2)))
                .thenReturn(payload);
        when(queries.exportPurchase(eq("WAITING_ORDER"), eq("开关"), eq(""), isNull(), isNull(), any(), eq(1)))
                .thenThrow(new ApiException(ErrorCode.VALIDATION_FAILED, "导出超过系统设置的 1 行上限"));
        byte[] bytes = {1, 2, 3};
        when(writer.build(eq(columns), eq(rows), isNull(), eq("view_purchase"))).thenReturn(bytes);
        var controller = new FulfillmentWorkbenchExportController(queries, writer, new WorkbookDownloadService(), user, audit, limits);

        var response = download(controller);
        assertArrayEquals(bytes, response.getBody());
        assertEquals(200, response.getStatusCode().value());
        var exceeded = assertThrows(ApiException.class, () -> download(controller));
        assertEquals(ErrorCode.VALIDATION_FAILED, exceeded.getCode());
        verify(limits, times(2)).exportMaxRows();
        var table = ArgumentCaptor.forClass(FulfillmentWorkbenchTableQuery.class);
        verify(queries).exportPurchase(eq("WAITING_ORDER"), eq("开关"), eq(""), isNull(), isNull(), table.capture(), eq(2));
        assertEquals(Map.of("search.goods", "开关", "supplierName", "华东"), table.getValue().filters());
        assertEquals("docNo", table.getValue().sort());
        verify(writer, times(1)).build(anyList(), anyList(), any(), anyString());
        verifyNoInteractions(audit);
    }

    @Test
    void endpointRequiresBothExportAuthorityAndADepartmentReadAuthority() {
        var method = java.util.Arrays.stream(FulfillmentWorkbenchExportController.class.getDeclaredMethods())
                .filter(candidate -> candidate.getName().equals("purchase")).findFirst().orElseThrow();
        assertEquals("hasAuthority('purchase_report:export') and hasAnyAuthority('purchase_request:view','purchase_order:view','purchase_receipt:view','purchase_return:view')",
                method.getAnnotation(PreAuthorize.class).value());
    }

    private static org.springframework.http.ResponseEntity<byte[]> download(FulfillmentWorkbenchExportController controller) {
        return controller.purchase("WAITING_ORDER", "", "开关", null, null, "docNo", "asc",
                null, null, null, null, Map.of("search.goods", "开关", "f.supplierName", "华东"), new ExportPasswordRequest(""));
    }
}
