package com.uten.imp.features.subcontract.material_issue;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.responses.ApiResponses;
import org.junit.jupiter.api.Test;
import org.springframework.aop.support.AopUtils;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.lang.reflect.Method;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;

class SubcontractMaterialIssueManualCreateRetirementTest {

    @Test
    void manualCreateAlwaysConflictsWithoutCallingTheLegacyService() {
        SubcontractMaterialIssueService service =
                mock(SubcontractMaterialIssueService.class);
        SubcontractMaterialIssueController controller =
                new SubcontractMaterialIssueController(
                        service, mock(AuditDetailViewRecorder.class));

        ApiException error = assertThrows(
                ApiException.class,
                () -> controller.create(null));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(error.getMessage())
                .contains("旧委外发料手工新建已关闭")
                .contains("仓库管理 → 委外出仓");
        verifyNoInteractions(service);
    }

    @Test
    void methodSecurityRejectsOrdinaryUserButStaleAuthorityStillGetsConflict() {
        try (AnnotationConfigApplicationContext context =
                     new AnnotationConfigApplicationContext(MethodSecurityConfig.class)) {
            SubcontractMaterialIssueController controller =
                    context.getBean(SubcontractMaterialIssueController.class);

            SecurityContextHolder.getContext().setAuthentication(
                    UsernamePasswordAuthenticationToken.authenticated(
                            "ordinary-user", "n/a", List.of()));
            assertThrows(AccessDeniedException.class, () -> controller.create(null));

            SecurityContextHolder.getContext().setAuthentication(
                    UsernamePasswordAuthenticationToken.authenticated(
                            "legacy-client",
                            "n/a",
                            List.of(new SimpleGrantedAuthority(
                                    "subcontract_material_issue:create"))));
            ApiException error = assertThrows(
                    ApiException.class,
                    () -> controller.create(null));
            assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        } finally {
            SecurityContextHolder.clearContext();
        }
    }

    @Test
    void openApiMarksCompatibilityPostDeprecatedWith403And409Only() throws Exception {
        Method method = AopUtils.getMostSpecificMethod(
                SubcontractMaterialIssueController.class.getMethod(
                        "create",
                        com.uten.imp.features.subcontract.material_issue.dto
                                .MaterialIssueSaveRequest.class),
                SubcontractMaterialIssueController.class);
        Operation operation = method.getAnnotation(Operation.class);
        ApiResponses responses = method.getAnnotation(ApiResponses.class);

        assertThat(operation).isNotNull();
        assertThat(operation.deprecated()).isTrue();
        assertThat(operation.description()).contains("不再创建单据");
        assertThat(responses).isNotNull();
        assertThat(responses.value())
                .extracting(response -> response.responseCode())
                .containsExactly("403", "409");
    }

    @Configuration(proxyBeanMethods = false)
    @EnableMethodSecurity
    static class MethodSecurityConfig {

        @Bean
        SubcontractMaterialIssueController materialIssueController() {
            return new SubcontractMaterialIssueController(
                    mock(SubcontractMaterialIssueService.class),
                    mock(AuditDetailViewRecorder.class));
        }
    }
}
