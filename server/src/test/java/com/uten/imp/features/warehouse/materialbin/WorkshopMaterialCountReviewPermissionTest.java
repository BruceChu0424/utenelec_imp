package com.uten.imp.features.warehouse.materialbin;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.access.AccessDeniedException;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class WorkshopMaterialCountReviewPermissionTest {
    @Test void draftRecorderCannotPostAndReviewerCanPostWithoutEditingTheRecordedCount() {
        var db = mock(NamedParameterJdbcTemplate.class);
        var permission = mock(WorkshopMaterialPermissions.class);
        UUID id = UUID.randomUUID();
        Map<String, Object> row = new HashMap<>();
        row.put("id", id); row.put("status", "COUNTING"); row.put("draft_count_id", UUID.randomUUID());
        row.put("period_no", 1); row.put("next_status", "OPEN");
        when(db.queryForList(anyString(), anyMap())).thenReturn(List.of(row));
        var views = new WorkshopMaterialPeriodViews(db, new ObjectMapper(), permission);
        when(permission.has(WorkshopMaterialPermissions.COUNT)).thenReturn(true);
        assertThat(views.view(id).allowedActions()).contains("EDIT_COUNT").doesNotContain("SUBMIT_COUNT");
        when(permission.has(WorkshopMaterialPermissions.COUNT)).thenReturn(false);
        when(permission.has(WorkshopMaterialPermissions.COUNT_REVIEW)).thenReturn(true);
        assertThat(views.view(id).allowedActions()).contains("SUBMIT_COUNT").doesNotContain("EDIT_COUNT");
    }

    @Test void actualPostingEndpointRequiresWarehouseReviewInsteadOfTheOldRecordingPermission() throws Exception {
        var method = WorkshopMaterialCountController.class.getMethod("submit", UUID.class, WorkshopMaterialDtos.VersionRequest.class);
        assertThat(method.getAnnotation(PreAuthorize.class).value()).isEqualTo("hasAuthority('stock:count:warehouse_review')");
    }

    @Test void namedReviewerCanReadTheCountWithOnlyTheReviewAuthorityAndNoPrivilegeMeansDenied() {
        try (var context = new AnnotationConfigApplicationContext(SecurityConfig.class)) {
            var controller = context.getBean(WorkshopMaterialCountController.class);
            UUID id = UUID.randomUUID();
            SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("reviewer", "unused",
                    List.of(new SimpleGrantedAuthority("stock:count:warehouse_review"))));
            controller.periods(id); controller.period(id); controller.count(id);
            verify(context.getBean(WorkshopMaterialPeriodService.class)).list(id);
            verify(context.getBean(WorkshopMaterialPeriodService.class)).detail(id);
            verify(context.getBean(WorkshopMaterialCountService.class)).detail(id);
            SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("viewer", "unused", List.of()));
            assertThatThrownBy(() -> controller.count(id)).isInstanceOf(AccessDeniedException.class);
            assertThatThrownBy(() -> controller.periods(id)).isInstanceOf(AccessDeniedException.class);
            SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("recorder", "unused",
                    List.of(new SimpleGrantedAuthority("workshop_material:count"))));
            assertThatThrownBy(() -> controller.submit(id, new WorkshopMaterialDtos.VersionRequest(0L, "count-review-test")))
                    .isInstanceOf(AccessDeniedException.class);
        } finally { SecurityContextHolder.clearContext(); }
    }

    @TestConfiguration @EnableMethodSecurity
    static class SecurityConfig {
        @Bean WorkshopMaterialPeriodService periods() { return mock(WorkshopMaterialPeriodService.class); }
        @Bean WorkshopMaterialCountService counts() { return mock(WorkshopMaterialCountService.class); }
        @Bean WorkshopMaterialCountController controller(WorkshopMaterialPeriodService periods, WorkshopMaterialCountService counts) {
            return new WorkshopMaterialCountController(periods, counts);
        }
    }
}
