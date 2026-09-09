package com.uten.imp.features.admin.serverstatus;

import com.uten.imp.security.AuthUser;
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

class ServerStatusControllerSecurityTest {
    @Configuration @EnableMethodSecurity
    static class Config {
        @Bean ServerStatusService service() { return mock(ServerStatusService.class); }
        @Bean ServerStatusController controller(ServerStatusService service) { return new ServerStatusController(service); }
    }
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test void ordinaryModuleAndAuthorizationPermissionsDoNotGrantHostVisibility() {
        try(var context=new AnnotationConfigApplicationContext(Config.class)) {
            var controller=context.getBean(ServerStatusController.class);
            login(Set.of("sales_order:view","authorization:manage"));
            assertThatThrownBy(controller::current).isInstanceOf(AccessDeniedException.class);
            verify(context.getBean(ServerStatusService.class),never()).current();
        }
    }
    @Test void separatelyGrantedMonitorPermissionCanReadWithoutManagingPermissions() {
        try(var context=new AnnotationConfigApplicationContext(Config.class)) {
            login(Set.of("server_status:view"));
            assertThatCode(context.getBean(ServerStatusController.class)::current).doesNotThrowAnyException();
            verify(context.getBean(ServerStatusService.class)).current();
        }
    }
    @Test void visitorCannotReadEvenWithAnIncorrectlySuppliedMonitorAuthority() {
        try(var context=new AnnotationConfigApplicationContext(Config.class)) {
            AuthUser visitor=AuthUser.visitor(UUID.randomUUID(),"visitor-test","V-TEST",Set.of("server_status:view"));
            SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(visitor,null,visitor.getAuthorities()));
            assertThatThrownBy(context.getBean(ServerStatusController.class)::current).isInstanceOf(AccessDeniedException.class);
            verify(context.getBean(ServerStatusService.class),never()).current();
        }
    }
    private static void login(Set<String> permissions) {
        AuthUser user=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"monitor-test",Set.of(),permissions,false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));
    }
}
