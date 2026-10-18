package com.uten.imp.security;

import com.uten.imp.application.port.TaskAudiencePort;
import com.uten.imp.features.auth.BusinessTaskAudienceService;
import com.uten.imp.features.auth.PermissionResolver;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Import;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class BusinessTaskReadConfigurationTest {
    @AfterEach void clean() { SecurityContextHolder.clearContext(); }

    @Test void taskScopeRunsBeforeMethodAuthorizationAndAlwaysRestoresAdministrativeCapability() {
        try (var context = new AnnotationConfigApplicationContext(Config.class)) {
            var permissions = context.getBean(PermissionResolver.class);
            var endpoint = context.getBean(TaskEndpoint.class);
            AuthUser admin = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "finance-admin",
                    Set.of("subcontract_order:draw"), false, true, true);
            SecurityContextHolder.getContext().setAuthentication(
                    UsernamePasswordAuthenticationToken.authenticated(admin, null, admin.getAuthorities()));
            when(permissions.grantedPermsOf(admin.getId())).thenReturn(Set.of());
            assertThatThrownBy(endpoint::count).isInstanceOf(AccessDeniedException.class);
            assertThat(endpoint.manage()).isTrue();
            when(permissions.grantedPermsOf(admin.getId())).thenReturn(Set.of("subcontract_order:draw"));
            assertThat(endpoint.count()).isEqualTo(1);
            assertThat(new SecurityContextCurrentUser().get()).contains(admin);
        }
    }

    @Configuration(proxyBeanMethods = false)
    @EnableMethodSecurity
    @Import(BusinessTaskReadConfiguration.class)
    static class Config {
        @Bean PermissionResolver permissions() { return mock(PermissionResolver.class); }
        @Bean TaskAudiencePort audience(PermissionResolver permissions) { return new BusinessTaskAudienceService(permissions); }
        @Bean TaskEndpoint endpoint() { return new TaskEndpoint(); }
    }

    public static class TaskEndpoint {
        @BusinessTaskRead
        @PreAuthorize("hasAuthority('subcontract_order:draw')")
        public long count() { return 1; }

        @PreAuthorize("hasAuthority('subcontract_order:draw')")
        public boolean manage() { return true; }
    }
}
