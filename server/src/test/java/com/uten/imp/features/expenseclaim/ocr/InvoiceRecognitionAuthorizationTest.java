package com.uten.imp.features.expenseclaim.ocr;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.config.props.ExpenseOcrProperties;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

class InvoiceRecognitionAuthorizationTest {
    @Configuration @EnableMethodSecurity
    static class Config {
        @Bean @SuppressWarnings("unchecked") ObjectProvider<InvoiceOcrClient> ocrProvider() { return mock(ObjectProvider.class); }
        @Bean InvoiceRecognitionService recognition(ObjectProvider<InvoiceOcrClient> provider) {
            return new InvoiceRecognitionService(provider, new ExpenseOcrProperties());
        }
    }

    @Test void anAuthenticatedUserStillNeedsExpenseApplyBeforeAnyUploadProcessing() {
        try (var context = new AnnotationConfigApplicationContext(Config.class)) {
            var service = context.getBean(InvoiceRecognitionService.class);
            SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(
                    "ordinary-staff", null, List.of(new SimpleGrantedAuthority("attachment:upload"))));
            var file = new MockMultipartFile("file", "x.png", "image/png", new byte[0]);
            assertThatThrownBy(() -> service.recognize(file)).isInstanceOf(AccessDeniedException.class);
            SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(
                    "applicant", null, List.of(new SimpleGrantedAuthority("expense:apply"))));
            assertThatThrownBy(() -> service.recognize(file)).isInstanceOf(ApiException.class).hasMessageContaining("请选择");
        } finally {
            SecurityContextHolder.clearContext();
        }
    }
}
