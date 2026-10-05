package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class WorkshopMaterialSettingsReadPermissionTest {
    private AnnotationConfigApplicationContext context;
    private WorkshopMaterialSettingsController settings;
    private WorkshopMaterialSettingsService settingsService;
    private WorkshopMaterialPositionController stock;
    private WorkshopMaterialPositionQueryService positions;

    @BeforeEach void openContext() {
        context = new AnnotationConfigApplicationContext(SecurityConfig.class);
        settings = context.getBean(WorkshopMaterialSettingsController.class);
        settingsService = context.getBean(WorkshopMaterialSettingsService.class);
        stock = context.getBean(WorkshopMaterialPositionController.class);
        positions = context.getBean(WorkshopMaterialPositionQueryService.class);
    }

    @AfterEach void closeContext() {
        SecurityContextHolder.clearContext();
        context.close();
    }

    @Test void setupOnlyCanReadSettingsWithoutAcquiringStockViewPermission() {
        signIn(WorkshopMaterialPermissions.SETUP);
        UUID workshop = UUID.randomUUID();
        var visible = new WorkshopMaterialDtos.SettingsView(workshop, "注塑车间",
                WorkshopMaterialDtos.STATUS_NOT_OPEN, false, false, null, null, null, null, null, null, null, null,
                0, null, null, null, List.of(), List.of("SETUP", "OPEN", "ENABLE_PERIODIC"));
        when(settingsService.list()).thenReturn(List.of(visible));

        assertThat(settings.list()).containsExactly(visible);
        verify(settingsService).list();
        context.getBean(WorkshopMachineController.class).list(workshop);
        verify(context.getBean(WorkshopMachineService.class)).list(workshop);
        assertThatThrownBy(() -> stock.position(UUID.randomUUID())).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> stock.materials(workshop)).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> stock.requestMaterials(workshop, null, null, 1, 50))
                .isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(positions);
    }

    @Test void unrelatedPermissionsDoNotReadSettings() {
        signIn("warehouse:view", "stock:view", WorkshopMaterialPermissions.REQUEST);
        assertThatThrownBy(settings::list).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> context.getBean(WorkshopMachineController.class).list(UUID.randomUUID()))
                .isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(settingsService, positions);
        verifyNoInteractions(context.getBean(WorkshopMachineService.class));
        signIn();
        assertThatThrownBy(settings::list).isInstanceOf(AccessDeniedException.class);
    }

    @Test void viewerRetainsReadsButDoesNotAcquireSetupOrOpeningCommands() {
        signIn(WorkshopMaterialPermissions.VIEW);
        UUID workshop = UUID.randomUUID();
        UUID bin = UUID.randomUUID();
        settings.list();
        stock.position(bin);
        context.getBean(WorkshopMachineController.class).list(workshop);
        verify(settingsService).list();
        verify(positions).position(bin);
        verify(context.getBean(WorkshopMachineService.class)).list(workshop);
        assertThatThrownBy(() -> settings.inProgressPending(List.of(workshop)))
                .isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> settings.update(workshop, new WorkshopMaterialDtos.SettingsRequest(
                null, 0L, true, null, null, true, java.time.LocalDate.of(2026, 10, 1), List.of(), "permission-test")))
                .isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> settings.batchEnable(new WorkshopMaterialDtos.BatchEnableRequest(
                List.of(new WorkshopMaterialDtos.BinItem(workshop, "NOT_OPEN", 0L)), null, null, false, null, List.of(),
                "permission-test-batch"))).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> settings.batchDisable(new WorkshopMaterialDtos.BatchDisableRequest(
                List.of(new WorkshopMaterialDtos.BinItem(workshop, "OPEN", 1L)), "permission-test-off")))
                .isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(settings::sourceWarehouses).isInstanceOf(AccessDeniedException.class);
        verifyNoMoreInteractions(settingsService);
    }

    @Test void setupReaderStillUsesTheExistingWorkshopObjectScopeIncludingNotYetEnabledMetadata() {
        UUID employee = UUID.randomUUID();
        UUID workshop = UUID.randomUUID();
        UUID production = UUID.randomUUID();
        var db = mock(NamedParameterJdbcTemplate.class);
        var currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), employee, "setter",
                Set.of(WorkshopMaterialPermissions.SETUP), false, true, false)));
        when(db.queryForList(anyString(), anyMap())).thenReturn(List.of(
                Map.of("member_id", workshop, "id", workshop, "parent_id", production, "is_production", false),
                Map.of("member_id", workshop, "id", production, "parent_id", UUID.randomUUID(), "is_production", true)));
        when(db.queryForList(anyString(), any(MapSqlParameterSource.class), eq(UUID.class))).thenAnswer(call -> {
            assertThat((String) call.getArgument(0)).contains("workshop.id = ANY");
            MapSqlParameterSource params = call.getArgument(1);
            assertThat(params.getValue("scopeWorkshops")).isEqualTo(workshop.toString());
            return List.of(workshop);
        });
        java.util.Map<String, Object> notOpened = new java.util.HashMap<>();
        notOpened.put("id", workshop);
        notOpened.put("name", "注塑车间");
        notOpened.put("periodic", false);
        when(db.queryForList(anyString(), eq(Map.of("ids", List.of(workshop))))).thenReturn(List.of(notOpened));
        var scope = new WorkshopMaterialScope(db, currentUser);
        var service = new WorkshopMaterialSettingsService(db, mock(WorkshopMaterialBinSupport.class),
                mock(WorkshopMaterialCommandLedger.class), scope, new WorkshopMaterialPermissions(currentUser),
                mock(WorkshopMaterialChoiceAdapter.class), mock(WorkshopBinService.class), currentUser);

        var rows = service.list();
        assertThat(rows).hasSize(1);
        assertThat(rows.getFirst().workshopDepartmentId()).isEqualTo(workshop);
        assertThat(rows.getFirst().status()).isEqualTo(WorkshopMaterialDtos.STATUS_NOT_OPEN);
        assertThat(rows.getFirst().periodicEnabled()).isFalse();
        assertThat(rows.getFirst().allowedActions()).containsExactly("SETUP", "OPEN", "ENABLE_PERIODIC");
        assertThatThrownBy(() -> service.detail(UUID.randomUUID())).isInstanceOf(ApiException.class)
                .hasMessageContaining("本车间");
    }

    private static void signIn(String... permissions) {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("tester", "unused",
                Arrays.stream(permissions).map(SimpleGrantedAuthority::new).toList()));
    }

    @TestConfiguration
    @EnableMethodSecurity
    static class SecurityConfig {
        @Bean WorkshopMaterialSettingsService settingsService() { return mock(WorkshopMaterialSettingsService.class); }
        @Bean WorkshopMaterialPositionQueryService positions() { return mock(WorkshopMaterialPositionQueryService.class); }
        @Bean WorkshopMachineService machines() { return mock(WorkshopMachineService.class); }
        @Bean WorkshopMaterialSettingsController settings(WorkshopMaterialSettingsService service) {
            return new WorkshopMaterialSettingsController(service);
        }
        @Bean WorkshopMaterialPositionController stock(WorkshopMaterialPositionQueryService service) {
            return new WorkshopMaterialPositionController(service);
        }
        @Bean WorkshopMachineController machineController(WorkshopMachineService service) {
            return new WorkshopMachineController(service);
        }
    }
}
