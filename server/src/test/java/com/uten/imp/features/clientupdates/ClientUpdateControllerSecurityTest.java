package com.uten.imp.features.clientupdates;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.RequiresStepUp;
import com.uten.imp.security.StepUpExempt;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

class ClientUpdateControllerSecurityTest {
    @Configuration @EnableMethodSecurity static class Config {
        @Bean ClientReleaseService service() { return mock(ClientReleaseService.class); }
        @Bean ClientReleaseAdminController admin(ClientReleaseService service) { return new ClientReleaseAdminController(service); }
        @Bean ClientUpdateController client(ClientReleaseService service) { return new ClientUpdateController(service); }
    }

    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test void accountsWithoutDedicatedPermissionAndRestrictedSessionsCannotManageAnyReleaseEndpointOverHttp() throws Exception {
        try (var context = new AnnotationConfigApplicationContext(Config.class)) {
            MockMvc mvc = mvc(context);
            for (AuthUser user : java.util.List.of(
                    user(false, false, false, Set.of()), user(false, false, false, Set.of("authorization:manage")),
                    user(false, false, false, Set.of("server:update")), user(true, false, false, Set.of()),
                    user(true, false, false, Set.of("authorization:manage")),
                    user(false, true, false, Set.of(ClientReleaseService.PUBLISH_PERMISSION)),
                    user(false, false, true, Set.of(ClientReleaseService.PUBLISH_PERMISSION)),
                    AuthUser.visitor(UUID.randomUUID(), "visitor", "V1", Set.of(ClientReleaseService.PUBLISH_PERMISSION)))) {
                login(user);
                mvc.perform(post("/api/admin/client-releases/{id}/publish", UUID.randomUUID())).andExpect(status().isForbidden());
                mvc.perform(get("/api/admin/client-releases")).andExpect(status().isForbidden());
                mvc.perform(post("/api/admin/client-releases").contentType("application/json").content(createBody()))
                        .andExpect(status().isForbidden());
                mvc.perform(put("/api/admin/client-releases/{id}/package", UUID.randomUUID())
                        .contentType("application/octet-stream").content(new byte[] {1})).andExpect(status().isForbidden());
                mvc.perform(post("/api/admin/client-releases/{id}/withdraw", UUID.randomUUID())).andExpect(status().isForbidden());
            }
            verifyNoInteractions(context.getBean(ClientReleaseService.class));
        }
    }

    @Test void dedicatedPermissionAloneLetsRealEmployeeManageAndOrdinaryUserCanCheckOverHttp() throws Exception {
        try (var context = new AnnotationConfigApplicationContext(Config.class)) {
            MockMvc mvc = mvc(context);
            login(user(false, false, false, Set.of(ClientReleaseService.PUBLISH_PERMISSION)));
            mvc.perform(get("/api/admin/client-releases")).andExpect(status().isOk());
            mvc.perform(post("/api/admin/client-releases").contentType("application/json").content(createBody()))
                    .andExpect(status().isCreated());
            mvc.perform(put("/api/admin/client-releases/{id}/package", UUID.randomUUID())
                    .contentType("application/octet-stream").content(new byte[] {1})).andExpect(status().isOk());
            mvc.perform(post("/api/admin/client-releases/{id}/publish", UUID.randomUUID())).andExpect(status().isOk());
            mvc.perform(post("/api/admin/client-releases/{id}/withdraw", UUID.randomUUID())).andExpect(status().isOk());
            login(user(false, false, false, Set.of()));
            mvc.perform(get("/api/client-updates/check").param("platform", "windows").param("architecture", "x64").param("currentBuildNumber", "27"))
                    .andExpect(status().isOk());
        }
    }

    @Test void finalPublicationAndWithdrawalRequirePasswordWhilePrivateDraftPreparationDoesNot() throws Exception {
        assertThat(ClientReleaseAdminController.class.getMethod("create", ClientReleaseDto.Create.class).isAnnotationPresent(StepUpExempt.class)).isTrue();
        assertThat(ClientReleaseAdminController.class.getMethod("upload", UUID.class, jakarta.servlet.http.HttpServletRequest.class)
                .isAnnotationPresent(StepUpExempt.class)).isTrue();
        assertThat(ClientReleaseAdminController.class.getMethod("publish", UUID.class).isAnnotationPresent(RequiresStepUp.class)).isTrue();
        assertThat(ClientReleaseAdminController.class.getMethod("withdraw", UUID.class).isAnnotationPresent(RequiresStepUp.class)).isTrue();
    }

    @Test void downloadCatalogIsAvailableToOrdinaryStaffButNotVisitorUnboundAccountOrPasswordChangeSession() throws Exception {
        try (var context = new AnnotationConfigApplicationContext(Config.class)) {
            MockMvc mvc = mvc(context);
            for (AuthUser denied : java.util.List.of(
                    AuthUser.visitor(UUID.randomUUID(), "visitor", "V1", Set.of()),
                    user(false, true, false, Set.of()),
                    new AuthUser(UUID.randomUUID(), null, "unbound", Set.of(), false, true, false))) {
                login(denied);
                mvc.perform(get("/api/client-updates/downloads")).andExpect(status().isForbidden());
            }
            SecurityContextHolder.clearContext();
            mvc.perform(get("/api/client-updates/downloads")).andExpect(status().is4xxClientError());
            verifyNoInteractions(context.getBean(ClientReleaseService.class));
            login(user(false, false, false, Set.of()));
            mvc.perform(get("/api/client-updates/downloads")).andExpect(status().isOk());
        }
    }

    @Test void realSuperAdministratorDoesNotNeedEmployeeProfileForDownloadCatalog() throws Exception {
        try (var context = new AnnotationConfigApplicationContext(Config.class)) {
            login(new AuthUser(UUID.randomUUID(), null, "administrator", Set.of(), false, true, true));
            mvc(context).perform(get("/api/client-updates/downloads")).andExpect(status().isOk());
        }
    }

    private static MockMvc mvc(AnnotationConfigApplicationContext context) {
        return MockMvcBuilders.standaloneSetup(context.getBean(ClientReleaseAdminController.class), context.getBean(ClientUpdateController.class))
                .setControllerAdvice(new GlobalExceptionHandler()).build();
    }
    private static byte[] createBody() throws Exception {
        return new ObjectMapper().writeValueAsBytes(new ClientReleaseDto.Create(UUID.randomUUID(), "windows", "x64", "2.5.32", 2532,
                "更新说明", false, "uten.zip", "a".repeat(64), null));
    }
    private static AuthUser user(boolean admin, boolean change, boolean impersonated, Set<String> permissions) {
        return new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "operator", permissions, change, true, admin, false,
                impersonated ? UUID.randomUUID() : null);
    }
    private static void login(AuthUser user) {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
    }
}
