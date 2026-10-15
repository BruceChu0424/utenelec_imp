package com.uten.imp.features.production.report;

import com.uten.imp.application.port.MaterialTraceabilityReadPort;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.context.SecurityContextHolder;

import java.time.LocalDate;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

/** Executes the real controller's method-security proxy; SQL object authorization has separate PG cases. */
class MaterialTraceabilityControllerSecurityTest {
    private AnnotationConfigApplicationContext context;
    private MaterialTraceabilityController controller;
    private MaterialTraceabilityReadPort query;

    @Configuration(proxyBeanMethods = false)
    @EnableMethodSecurity
    static class SecurityConfiguration {
        @Bean MaterialTraceabilityReadPort query() { return mock(MaterialTraceabilityReadPort.class); }
        @Bean MaterialTraceabilityController controller(MaterialTraceabilityReadPort query) {
            return new MaterialTraceabilityController(query);
        }
    }

    @BeforeEach void start() {
        context = new AnnotationConfigApplicationContext(SecurityConfiguration.class);
        controller = context.getBean(MaterialTraceabilityController.class);
        query = context.getBean(MaterialTraceabilityReadPort.class);
    }

    @AfterEach void close() {
        SecurityContextHolder.clearContext();
        if (context != null) context.close();
    }

    @ParameterizedTest
    @ValueSource(strings = {"", "stock:view", "production_plan:view", "goods:view", "production_report:view"})
    void otherReadPermissionsCannotDiscoverSubjectsOrTraceKnownIds(String permission) {
        login(permission.isEmpty() ? Set.of() : Set.of(permission));
        assertThatThrownBy(() -> controller.subjects("goods", "material", false, 1, 10))
                .isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> controller.trace("GOODS", UUID.randomUUID(), "usage", null, null, 1, 10))
                .isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(query);
    }

    @Test void dedicatedPermissionKeepsTheExistingIndependentSubjectSearchAndForwardsExactCriteria() {
        login(Set.of("production_where_used:view"));
        var expected = new PageResponse<MaterialTraceabilityReadPort.Subject>(List.of(), 3, 7, 0L, 0);
        when(query.subjects("goods", "exact material", true, 3, 7)).thenReturn(expected);
        assertThat(controller.subjects("goods", "exact material", true, 3, 7)).isSameAs(expected);
        verify(query).subjects("goods", "exact material", true, 3, 7);
        verifyNoMoreInteractions(query);
    }

    @Test void traceEntryUsesDedicatedPermissionAndLeavesPhysicalAndObjectGatesToTheReadPort() {
        login(Set.of("production_where_used:view"));
        UUID id = UUID.randomUUID();
        LocalDate from = LocalDate.of(2026, 10, 1), to = LocalDate.of(2026, 10, 15);
        var expected = new MaterialTraceabilityReadPort.Result(List.of(), 2, 9, 0L, 0,
                null, List.of(), false, List.of());
        when(query.trace("PURCHASE_ORDER", id, "materials", from, to, 2, 9)).thenReturn(expected);
        assertThat(controller.trace("PURCHASE_ORDER", id, "materials", from, to, 2, 9)).isSameAs(expected);
        verify(query).trace("PURCHASE_ORDER", id, "materials", from, to, 2, 9);
        verifyNoMoreInteractions(query);
    }

    private static void login(Set<String> permissions) {
        AuthUser actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "trace-controller-test",
                permissions, false, true, false);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(actor, "unused", actor.getAuthorities()));
    }
}
