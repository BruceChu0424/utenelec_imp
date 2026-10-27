package com.uten.imp.config;

import com.uten.imp.audit.UserOperationAuditInterceptor;
import com.uten.imp.common.report.ReportReadPlanInterceptor;
import com.uten.imp.common.report.MasterReadScopeInterceptor;
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
        InterceptorRegistration candidateRegistration=mock(InterceptorRegistration.class);
        InterceptorRegistration printRegistration=mock(InterceptorRegistration.class);
        InterceptorRegistration legacyRegistration=mock(InterceptorRegistration.class);
        when(registry.addInterceptor(audit)).thenReturn(auditRegistration);
        when(registry.addInterceptor(export)).thenReturn(exportRegistration);
        when(registry.addInterceptor(any(ReportReadPlanInterceptor.class))).thenReturn(reportRegistration);
        when(reportRegistration.addPathPatterns(any(String[].class))).thenReturn(reportRegistration);
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
        order.verify(registry).addInterceptor(any(ReportReadPlanInterceptor.class));
        order.verify(registry).addInterceptor(any(com.uten.imp.common.report.NativeFacetCandidateInterceptor.class));
        order.verify(registry).addInterceptor(any(MasterReadScopeInterceptor.class));
        order.verify(registry).addInterceptor(any(com.uten.imp.common.report.PurchasePrintReadScopeInterceptor.class));
        order.verify(registry).addInterceptor(any(com.uten.imp.common.report.LegacyExportReadScopeInterceptor.class));
        order.verify(registry).addInterceptor(export);
        org.mockito.Mockito.verify(masterRegistration).addPathPatterns("/api/master/**");
        org.mockito.Mockito.verify(printRegistration).addPathPatterns(
                "/api/purchase/orders/*/print-data", "/api/subcontract/orders/*/print-data");
    }
}
