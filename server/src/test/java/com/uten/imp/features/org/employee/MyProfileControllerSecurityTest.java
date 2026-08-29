package com.uten.imp.features.org.employee;

import com.uten.imp.audit.AuditRequestContextFilter;
import com.uten.imp.audit.UserOperationAuditInterceptor;
import com.uten.imp.config.WebMvcConfig;
import com.uten.imp.features.org.employee.dto.EmployeeDetail;
import com.uten.imp.security.ExportRateLimitInterceptor;
import com.uten.imp.security.ImpersonationWriteGuardFilter;
import com.uten.imp.security.JwtAuthFilter;
import com.uten.imp.security.LocalNetworkGuardFilter;
import com.uten.imp.security.RemoteAccessGuardFilter;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.FilterType;
import org.springframework.context.annotation.Import;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.web.bind.annotation.GetMapping;

import java.lang.reflect.Method;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(
        controllers = MyProfileController.class,
        excludeFilters = @ComponentScan.Filter(
                type = FilterType.ASSIGNABLE_TYPE,
                classes = {
                        WebMvcConfig.class,
                        AuditRequestContextFilter.class,
                        UserOperationAuditInterceptor.class,
                        ExportRateLimitInterceptor.class,
                        ImpersonationWriteGuardFilter.class,
                        JwtAuthFilter.class,
                        LocalNetworkGuardFilter.class,
                        RemoteAccessGuardFilter.class
                }))
@Import(MyProfileControllerSecurityTest.MethodSecurityConfiguration.class)
class MyProfileControllerSecurityTest {

    private static final String SELF_PROFILE = "profile:edit:self";
    private static final UUID EMPLOYEE_ID =
            UUID.fromString("50000000-0000-0000-0000-000000000001");

    @Autowired
    private MockMvc mvc;

    @MockitoBean
    private EmployeeQueryService queryService;

    @BeforeEach
    void setUp() {
        EmployeeDetail detail = new EmployeeDetail();
        detail.setId(EMPLOYEE_ID);
        detail.setFullName("本人");
        when(queryService.myDetail()).thenReturn(detail);
    }

    @Test
    void selfProfilePermissionCanReadObjectScopedEndpoint() throws Exception {
        mvc.perform(get("/api/profile/me")
                        .with(user("employee")
                                .authorities(new SimpleGrantedAuthority(SELF_PROFILE))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.id").value(EMPLOYEE_ID.toString()))
                .andExpect(jsonPath("$.fullName").value("本人"));

        verify(queryService).myDetail();
    }

    @Test
    void missingSelfProfilePermissionIsRejectedBeforeQuery() throws Exception {
        mvc.perform(get("/api/profile/me")
                        .with(user("employee")
                                .authorities(new SimpleGrantedAuthority("employee:view"))))
                .andExpect(status().isForbidden());

        verifyNoInteractions(queryService);
    }

    @Test
    void endpointAcceptsNoEmployeeIdAndDeclaresExactPermission() throws Exception {
        Method method = MyProfileController.class.getDeclaredMethod("me");

        assertEquals(0, method.getParameterCount());
        assertNotNull(method.getAnnotation(GetMapping.class));
        assertEquals(
                "hasAuthority('profile:edit:self')",
                method.getAnnotation(PreAuthorize.class).value());
    }

    @TestConfiguration(proxyBeanMethods = false)
    @EnableMethodSecurity
    static class MethodSecurityConfiguration {
    }
}
