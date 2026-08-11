package com.uten.imp.config;

import com.uten.imp.audit.UserOperationAuditInterceptor;
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
        when(registry.addInterceptor(audit)).thenReturn(auditRegistration);
        when(registry.addInterceptor(export)).thenReturn(exportRegistration);
        when(auditRegistration.addPathPatterns(any(String[].class)))
                .thenReturn(auditRegistration);
        when(exportRegistration.addPathPatterns(any(String[].class)))
                .thenReturn(exportRegistration);

        new WebMvcConfig(export, audit).addInterceptors(registry);

        InOrder order = inOrder(registry);
        order.verify(registry).addInterceptor(audit);
        order.verify(registry).addInterceptor(export);
    }
}
