package com.uten.imp.features.finance.report;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.SecurityContextCurrentUser;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

class FinanceStatementHeadersHttpTest {
    private final FinanceReportService service=mock(FinanceReportService.class);
    private final XlsxExportService xlsx=mock(XlsxExportService.class);
    private final WorkbookDownloadService download=mock(WorkbookDownloadService.class);
    private final SecurityContextCurrentUser current=mock(SecurityContextCurrentUser.class);
    private FinanceReportController controller() {
        when(current.get()).thenReturn(Optional.empty());
        return new FinanceReportController(service,xlsx,download,mock(AuditService.class),current);
    }
    @Test void overviewReadUsesPrivatePhoneBodyAndRegularAggregateHeaderQuery() throws Exception {
        when(service.arApOverview(any(),any(),any(),any(),any(),any(),eq(1),eq(50),anyMap(),any(),any()))
                .thenAnswer(invocation->{
                    assertThat(com.uten.imp.common.report.ReportReadPlan.current().includeCount()).isFalse();
                    assertThat(com.uten.imp.common.report.ReportReadPlan.current().includeFacets()).isFalse();
                    return new ReportTableResponse(List.of(),List.of(),Map.of(),1,50,0,0).withColumnSearchKeys(Set.of("phone"));
                });
        var mvc=MockMvcBuilders.standaloneSetup(controller()).addInterceptors(new com.uten.imp.common.report.ReportReadPlanInterceptor()).build();
        mvc.perform(post("/api/finance/reports/ar-ap/overview/search")
                .param("f.search.receivable",">=25").param("sort","receivable").param("order","desc")
                .param("includeCount","false").param("includeFacets","false").param("includeTotals","false")
                .contentType(MediaType.APPLICATION_JSON).content("{\"columnSearch\":{\"phone\":\"1234 5678\"}}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.columnSearchKeys[0]").value("phone"));
        verify(service).arApOverview(isNull(),isNull(),isNull(),isNull(),isNull(),isNull(),eq(1),eq(50),
                argThat(filters->filters.get("search.phone").equals("1234 5678")&&filters.get("search.receivable").equals(">=25")),
                eq("receivable"),eq("desc"));
    }
    @Test void overviewSpecificExportRoutePreservesBodyFilters() throws Exception {
        when(service.export(anyString(),anyMap(),any(),any())).thenReturn(new ExportPayload(List.of(),List.of(),0));
        when(xlsx.build(anyList(),anyList(),any(),anyString())).thenReturn(new byte[]{1,2});
        when(download.protect(any(),any())).thenReturn(new byte[]{1,2});
        var mvc=MockMvcBuilders.standaloneSetup(controller()).build();
        mvc.perform(post("/api/finance/reports/export").param("report","ar-ap/overview")
                .param("f.search.receivable",">=25").contentType(MediaType.APPLICATION_JSON)
                .content("{\"password\":\"fixture\",\"sensitiveFilter\":{\"columnSearch\":{\"phone\":\"1234 5678\"}}}"))
                .andExpect(status().isOk()).andExpect(content().bytes(new byte[]{1,2}));
        verify(service).export(eq("ar-ap/overview"),argThat(parameters->
                parameters.get("f.search.phone").equals("1234 5678")&&parameters.get("f.search.receivable").equals(">=25")),
                isNull(),isNull());
    }
    @Test void contactSearchCannotEnterTheGetUrl() {
        var mvc=MockMvcBuilders.standaloneSetup(controller()).build();
        assertThatThrownBy(()->mvc.perform(get("/api/finance/reports/ar-ap/overview").param("f.search.phone","1234")))
                .hasRootCauseInstanceOf(ApiException.class);
        verifyNoInteractions(service);
    }
}
