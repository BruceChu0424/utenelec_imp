package com.uten.imp.features.admin.serverstatus;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.RequiresStepUp;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.context.SecurityContextHolder;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class ServerStorageControllerSecurityTest {
    @Configuration @EnableMethodSecurity static class Config {
        @Bean ServerStorageService service() { return mock(ServerStorageService.class); }
        @Bean ServerStorageController controller(ServerStorageService service) { return new ServerStorageController(service); }
    }
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }
    @Test void explicitCleanupGrantReadsAndCleansButMonitorOnlyReads() {
        try (var context = new AnnotationConfigApplicationContext(Config.class)) {
            var controller = context.getBean(ServerStorageController.class);
            login(Set.of("server_status:view"));
            assertThatCode(controller::summary).doesNotThrowAnyException();
            assertThatThrownBy(() -> controller.preview(null)).isInstanceOf(AccessDeniedException.class);
            login(Set.of("server:cleanup"));
            assertThatCode(() -> controller.preview(null)).doesNotThrowAnyException();
            assertThatCode(controller::summary).doesNotThrowAnyException();
        }
    }
    @Test void broadAuthorizationManagerCannotReadOrMutateServerFiles() {
        try (var context = new AnnotationConfigApplicationContext(Config.class)) {
            login(Set.of("authorization:manage"));
            var controller = context.getBean(ServerStorageController.class);
            assertThatThrownBy(controller::summary).isInstanceOf(AccessDeniedException.class);
            assertThatThrownBy(() -> controller.delete(null)).isInstanceOf(AccessDeniedException.class);
            verifyNoInteractions(context.getBean(ServerStorageService.class));
        }
    }
    @Test void previewAndExecutionBothDeclareExistingStepUpGuard() throws Exception {
        assertThat(ServerStorageController.class.getMethod("preview", ServerStorageView.PreviewRequest.class)
                .isAnnotationPresent(RequiresStepUp.class)).isTrue();
        assertThat(ServerStorageController.class.getMethod("delete", ServerStorageView.DeleteRequest.class)
                .isAnnotationPresent(RequiresStepUp.class)).isTrue();
    }
    private static void login(Set<String> permissions) {
        var user = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "ops-test", permissions, false, true, false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
    }
}
