package com.uten.imp.features.clientupdates;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

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

    @Test void ordinaryUsersPermissionOnlyAccountsVisitorsAndImpersonationCannotPublishOverHttp() throws Exception {
        try (var context = new AnnotationConfigApplicationContext(Config.class)) {
            MockMvc mvc = mvc(context);
            for (AuthUser user : java.util.List.of(
                    user(false, false, false, Set.of()), user(false, false, false, Set.of("authorization:manage")),
                    user(true, true, false, Set.of("authorization:manage")), user(true, false, true, Set.of("authorization:manage")),
                    AuthUser.visitor(UUID.randomUUID(), "visitor", "V1", Set.of("authorization:manage")))) {
                login(user);
                mvc.perform(post("/api/admin/client-releases/{id}/publish", UUID.randomUUID())).andExpect(status().isForbidden());
                mvc.perform(get("/api/admin/client-releases")).andExpect(status().isForbidden());
            }
            verifyNoInteractions(context.getBean(ClientReleaseService.class));
        }
    }

    @Test void authorizedRealAdministratorCanManageAndOrdinaryUserCanCheckOverHttp() throws Exception {
        try (var context = new AnnotationConfigApplicationContext(Config.class)) {
            MockMvc mvc = mvc(context);
            login(user(true, false, false, Set.of("authorization:manage")));
            mvc.perform(get("/api/admin/client-releases")).andExpect(status().isOk());
            mvc.perform(post("/api/admin/client-releases/{id}/publish", UUID.randomUUID())).andExpect(status().isOk());
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

    private static MockMvc mvc(AnnotationConfigApplicationContext context) {
        return MockMvcBuilders.standaloneSetup(context.getBean(ClientReleaseAdminController.class), context.getBean(ClientUpdateController.class))
                .setControllerAdvice(new GlobalExceptionHandler()).build();
    }
    private static AuthUser user(boolean admin, boolean change, boolean impersonated, Set<String> permissions) {
        return new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "operator", permissions, change, true, admin, false,
                impersonated ? UUID.randomUUID() : null);
    }
    private static void login(AuthUser user) {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
    }
}
