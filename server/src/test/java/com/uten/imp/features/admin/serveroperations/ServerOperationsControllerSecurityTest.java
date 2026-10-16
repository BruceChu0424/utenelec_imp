package com.uten.imp.features.admin.serveroperations;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.RequiresStepUp;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.context.SecurityContextHolder;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class ServerOperationsControllerSecurityTest {
    @Configuration @EnableMethodSecurity static class Config {
        @Bean ServerOperationsService service(){return mock(ServerOperationsService.class);}
        @Bean ServerOperationsController controller(ServerOperationsService s){return new ServerOperationsController(s);}
    }
    @AfterEach void clear(){SecurityContextHolder.clearContext();}
    @Test void delegatedUpdaterCanCheckAndScheduleButCannotReadOrChangeCredentials() {
        try(var context=new AnnotationConfigApplicationContext(Config.class)) {
            login(Set.of("server:update"),false,false,false);var controller=context.getBean(ServerOperationsController.class);
            assertThatCode(controller::status).doesNotThrowAnyException();
            assertThatCode(()->controller.check(null)).doesNotThrowAnyException();
            assertThatCode(()->controller.start(null)).doesNotThrowAnyException();
            assertThatCode(()->controller.schedule(null)).doesNotThrowAnyException();
            assertThatThrownBy(controller::source).isInstanceOf(AccessDeniedException.class);
            assertThatThrownBy(()->controller.save(null)).isInstanceOf(AccessDeniedException.class);
        }
    }
    @Test void monitorAndCleanupCannotUpdateAndAuthorizationManageAloneCannotConfigureSource() {
        try(var context=new AnnotationConfigApplicationContext(Config.class)) {
            var controller=context.getBean(ServerOperationsController.class);
            for(var perms:java.util.List.of(Set.of("server_status:view"),Set.of("server:cleanup"))) {
                login(perms,false,false,false);assertThatCode(controller::status).doesNotThrowAnyException();
                assertThatThrownBy(()->controller.check(null)).isInstanceOf(AccessDeniedException.class);
                assertThatThrownBy(()->controller.start(null)).isInstanceOf(AccessDeniedException.class);
            }
            login(Set.of("authorization:manage"),false,false,false);
            assertThatThrownBy(controller::source).isInstanceOf(AccessDeniedException.class);
            login(Set.of("authorization:manage"),true,false,false);
            assertThatCode(controller::source).doesNotThrowAnyException();
            assertThatCode(()->controller.save(null)).doesNotThrowAnyException();
        }
    }
    @Test void visitorsMustChangeAndImpersonationCannotWriteEvenWithPermissionStrings() {
        try(var context=new AnnotationConfigApplicationContext(Config.class)) {
            var controller=context.getBean(ServerOperationsController.class);
            login(Set.of("server:update","authorization:manage"),true,false,true);
            assertThatThrownBy(()->controller.start(null)).isInstanceOf(AccessDeniedException.class);
            assertThatThrownBy(()->controller.save(null)).isInstanceOf(AccessDeniedException.class);
            login(Set.of("server:update"),false,true,false);
            assertThatThrownBy(controller::status).isInstanceOf(AccessDeniedException.class);
            var visitor=AuthUser.visitor(UUID.randomUUID(),"v","V1",Set.of("server:update"));
            SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(visitor,null,visitor.getAuthorities()));
            assertThatThrownBy(controller::status).isInstanceOf(AccessDeniedException.class);
            assertThatThrownBy(()->controller.check(null)).isInstanceOf(AccessDeniedException.class);
        }
    }
    @Test void readOnlyChecksNeedNoPasswordButEveryMutationKeepsExistingStepUpGuard() throws Exception {
        assertThat(ServerOperationsController.class.getMethod("check",ServerOperationsDto.Check.class).isAnnotationPresent(RequiresStepUp.class)).isFalse();
        assertThat(ServerOperationsController.class.getMethod("schedule",ServerOperationsDto.SchedulePreview.class).isAnnotationPresent(RequiresStepUp.class)).isFalse();
        assertThat(ServerOperationsController.class.getMethod("save",ServerOperationsDto.SourceSave.class).isAnnotationPresent(RequiresStepUp.class)).isTrue();
        assertThat(ServerOperationsController.class.getMethod("start",ServerOperationsDto.UpdateStart.class).isAnnotationPresent(RequiresStepUp.class)).isTrue();
        assertThat(ServerOperationsController.class.getMethod("cancel",UUID.class,ServerOperationsDto.Cancel.class).isAnnotationPresent(RequiresStepUp.class)).isTrue();
    }
    private static void login(Set<String> perms,boolean admin,boolean change,boolean impersonated){
        var user=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"operator",perms,change,true,admin,false,impersonated?UUID.randomUUID():null);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));
    }
}
