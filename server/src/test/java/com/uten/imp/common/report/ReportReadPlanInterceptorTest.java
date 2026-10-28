package com.uten.imp.common.report;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ReportReadPlanInterceptorTest {
    private final ReportReadPlanInterceptor interceptor = new ReportReadPlanInterceptor();
    private final MockHttpServletResponse response = new MockHttpServletResponse();

    static class PrivateQuery {
        @ReadOnlyReportQuery public void search() { }
    }
    @Test void explicitlyDeclaredPostReadsHonorRowsOnlyAndCloseTheirScope() throws Exception {
        var request=new MockHttpServletRequest("POST","/api/finance/reports/ar-ap/overview/search");
        for(String key:java.util.List.of("includeCount","includeFacets","includeTotals")) request.setParameter(key,"false");
        var handler=new org.springframework.web.method.HandlerMethod(new PrivateQuery(),PrivateQuery.class.getDeclaredMethod("search"));
        try {
            interceptor.preHandle(request,response,handler);
            assertThat(ReportReadPlan.current()).isEqualTo(ReportReadPlan.ROWS_ONLY);
        } finally {interceptor.afterCompletion(request,response,handler,null);}
        assertThat(ReportReadPlan.current()).isEqualTo(ReportReadPlan.ALL);
    }

    @Test
    void independentSwitchesAndFailureCompletionRestoreTheThread() {
        var request = new MockHttpServletRequest("GET", "/api/sales/reports/ORDER/detail");
        request.setParameter("includeCount", "false");
        request.setParameter("includeFacets", "true");
        request.setParameter("includeTotals", "false");
        interceptor.preHandle(request, response, this);
        assertThat(ReportReadPlan.current()).isEqualTo(new ReportReadPlan(false, true, false));
        interceptor.afterCompletion(request, response, this, new RuntimeException("read failed"));
        assertThat(ReportReadPlan.current()).isEqualTo(ReportReadPlan.ALL);
        interceptor.afterCompletion(request, response, this, null);
        assertThat(ReportReadPlan.current()).isEqualTo(ReportReadPlan.ALL);
    }

    @Test
    void malformedAndDuplicateSwitchesFailBeforeCreatingAScope() {
        for (String name : new String[]{"includeCount", "includeFacets", "includeTotals"}) {
            var request = new MockHttpServletRequest("GET", "/api/finance/reports/receipt/detail");
            request.setParameter(name, "0");
            assertThatThrownBy(() -> interceptor.preHandle(request, response, this)).isInstanceOf(ApiException.class);
            request.setParameter(name, "true", "false");
            assertThatThrownBy(() -> interceptor.preHandle(request, response, this)).isInstanceOf(ApiException.class);
            assertThat(ReportReadPlan.current()).isEqualTo(ReportReadPlan.ALL);
        }
    }

    @Test
    void defaultsAndPostRequestsKeepCompatibilityAndAsyncHandoffDoesNotLeak() {
        var get = new MockHttpServletRequest("GET", "/api/stock/reports/CHECK/summary");
        interceptor.preHandle(get, response, this);
        assertThat(ReportReadPlan.current()).isEqualTo(ReportReadPlan.ALL);
        interceptor.afterConcurrentHandlingStarted(get, response, this);
        assertThat(ReportReadPlan.current()).isEqualTo(ReportReadPlan.ALL);
        var post = new MockHttpServletRequest("POST", "/api/stock/reports/export");
        post.setParameter("includeCount", "invalid");
        interceptor.preHandle(post, response, this);
        assertThat(ReportReadPlan.current()).isEqualTo(ReportReadPlan.ALL);
    }
}
