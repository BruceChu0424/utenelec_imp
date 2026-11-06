package com.uten.imp.config;

import com.uten.imp.audit.UserOperationAuditInterceptor;
import com.uten.imp.common.report.ReportReadPlanInterceptor;
import com.uten.imp.common.report.MasterReadScopeInterceptor;
import com.uten.imp.common.report.NativeTaskReadScopeInterceptor;
import com.uten.imp.security.ExportRateLimitInterceptor;
import org.junit.jupiter.api.Test;
import org.mockito.InOrder;
import org.springframework.web.servlet.config.annotation.InterceptorRegistration;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class WebMvcConfigInterceptorOrderTest {

    @Test
    void requestAuditEntersTheChainBeforeExportRateLimiting() {
        ExportRateLimitInterceptor export = mock(ExportRateLimitInterceptor.class);
        UserOperationAuditInterceptor audit =
                mock(UserOperationAuditInterceptor.class);
        InterceptorRegistry registry = mock(InterceptorRegistry.class);
        InterceptorRegistration auditRegistration =
                mock(InterceptorRegistration.class);
        InterceptorRegistration exportRegistration =
                mock(InterceptorRegistration.class);
        InterceptorRegistration reportRegistration = mock(InterceptorRegistration.class);
        InterceptorRegistration masterRegistration = mock(InterceptorRegistration.class);
        InterceptorRegistration businessRegistration = mock(InterceptorRegistration.class);
        InterceptorRegistration candidateRegistration=mock(InterceptorRegistration.class);
        InterceptorRegistration taskRegistration=mock(InterceptorRegistration.class);
        InterceptorRegistration printRegistration=mock(InterceptorRegistration.class);
        InterceptorRegistration legacyRegistration=mock(InterceptorRegistration.class);
        when(registry.addInterceptor(audit)).thenReturn(auditRegistration);
        when(registry.addInterceptor(export)).thenReturn(exportRegistration);
        when(registry.addInterceptor(any(ReportReadPlanInterceptor.class))).thenReturn(reportRegistration);
        when(registry.addInterceptor(any(NativeTaskReadScopeInterceptor.class))).thenReturn(taskRegistration);
        when(taskRegistration.addPathPatterns(any(String[].class))).thenReturn(taskRegistration);
        when(reportRegistration.addPathPatterns(any(String[].class))).thenReturn(reportRegistration);
        when(registry.addInterceptor(any(com.uten.imp.common.report.BusinessDocumentReadScopeInterceptor.class))).thenReturn(businessRegistration);
        when(businessRegistration.addPathPatterns(any(String[].class))).thenReturn(businessRegistration);
        when(registry.addInterceptor(any(MasterReadScopeInterceptor.class))).thenReturn(masterRegistration);
        when(registry.addInterceptor(any(com.uten.imp.common.report.NativeFacetCandidateInterceptor.class))).thenReturn(candidateRegistration);
        when(candidateRegistration.addPathPatterns(any(String[].class))).thenReturn(candidateRegistration);
        when(registry.addInterceptor(any(com.uten.imp.common.report.PurchasePrintReadScopeInterceptor.class))).thenReturn(printRegistration);
        when(printRegistration.addPathPatterns(any(String[].class))).thenReturn(printRegistration);
        when(registry.addInterceptor(any(com.uten.imp.common.report.LegacyExportReadScopeInterceptor.class))).thenReturn(legacyRegistration);
        when(legacyRegistration.addPathPatterns(any(String[].class))).thenReturn(legacyRegistration);
        when(masterRegistration.addPathPatterns(any(String[].class))).thenReturn(masterRegistration);
        when(auditRegistration.addPathPatterns(any(String[].class)))
                .thenReturn(auditRegistration);
        when(exportRegistration.addPathPatterns(any(String[].class)))
                .thenReturn(exportRegistration);

        new WebMvcConfig(export, audit).addInterceptors(registry);

        InOrder order = inOrder(registry);
        order.verify(registry).addInterceptor(audit);
        order.verify(registry).addInterceptor(any(NativeTaskReadScopeInterceptor.class));
        order.verify(registry).addInterceptor(any(ReportReadPlanInterceptor.class));
        order.verify(registry).addInterceptor(any(com.uten.imp.common.report.NativeFacetCandidateInterceptor.class));
        order.verify(registry).addInterceptor(any(com.uten.imp.common.report.BusinessDocumentReadScopeInterceptor.class));
        order.verify(registry).addInterceptor(any(MasterReadScopeInterceptor.class));
        order.verify(registry).addInterceptor(any(com.uten.imp.common.report.PurchasePrintReadScopeInterceptor.class));
        order.verify(registry).addInterceptor(any(com.uten.imp.common.report.LegacyExportReadScopeInterceptor.class));
        order.verify(registry).addInterceptor(export);
        org.mockito.Mockito.verify(registry,org.mockito.Mockito.times(1)).addInterceptor(any(NativeTaskReadScopeInterceptor.class));
        org.mockito.Mockito.verify(taskRegistration).addPathPatterns("/api/**");
        org.mockito.Mockito.verify(businessRegistration).addPathPatterns(
                "/api/expense-claims/**", "/api/platform-columns/expense_claim/**", "/api/platform-columns/expense_claim_item/**",
                "/api/finance/asset-opening-groups/summaries", "/api/finance/accounting-imports/summaries",
                "/api/finance/auxiliary-imports/summaries", "/api/finance/chart/imports/summaries",
                "/api/finance/expense-analysis/note-imports/summaries",
                "/api/finance/payable-statement-adjustments", "/api/finance/statement-documents/reviews/*/summary",
                "/api/finance/statement-documents/reviews/*/original-table");
        org.mockito.Mockito.verify(masterRegistration).addPathPatterns("/api/master/**");
        org.mockito.Mockito.verify(printRegistration).addPathPatterns(
                "/api/purchase/orders/*/print-data", "/api/subcontract/orders/*/print-data");
    }

    @Test
    void actualRegistryContainsOneNativeTaskFenceAfterAuditAndBeforeTheReportPlan() {
        var audit=mock(UserOperationAuditInterceptor.class);
        var registry=new VisibleRegistry();
        new WebMvcConfig(mock(ExportRateLimitInterceptor.class),audit).addInterceptors(registry);
        var chain=registry.configured().stream().map(value ->
                value instanceof org.springframework.web.servlet.handler.MappedInterceptor mapped
                        ? mapped.getInterceptor() : value).toList();
        org.assertj.core.api.Assertions.assertThat(chain).filteredOn(NativeTaskReadScopeInterceptor.class::isInstance).hasSize(1);
        org.assertj.core.api.Assertions.assertThat(chain.get(0)).isSameAs(audit);
        org.assertj.core.api.Assertions.assertThat(chain.get(1)).isInstanceOf(NativeTaskReadScopeInterceptor.class);
        org.assertj.core.api.Assertions.assertThat(chain.get(2)).isInstanceOf(ReportReadPlanInterceptor.class);
        org.assertj.core.api.Assertions.assertThat(chain.get(3)).isInstanceOf(com.uten.imp.common.report.NativeFacetCandidateInterceptor.class);
    }

    private static final class VisibleRegistry extends InterceptorRegistry {
        java.util.List<?> configured() { return getInterceptors(); }
    }
}
