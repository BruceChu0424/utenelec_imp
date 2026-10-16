package com.uten.imp.features.visitor.sms.settings;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.RequiresStepUp;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.*;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.context.SecurityContextHolder;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class SmsSettingsControllerSecurityTest {
    @Configuration @EnableMethodSecurity static class Config {
        @Bean SmsSettingsService service(){return mock(SmsSettingsService.class);}
        @Bean SmsSettingsController controller(SmsSettingsService service){return new SmsSettingsController(service);}
    }
    @AfterEach void clear(){SecurityContextHolder.clearContext();}
    @Test void onlyRealSuperAdminWithAuthorizationAuthorityCanReadOrSave() {
        try(var context=new AnnotationConfigApplicationContext(Config.class)) {
            var controller=context.getBean(SmsSettingsController.class);
            for(AuthUser denied:new AuthUser[]{
                    new AuthUser(UUID.randomUUID(),null,"manager",Set.of("authorization:manage"),false,true,false),
                    new AuthUser(UUID.randomUUID(),null,"admin",Set.of(),false,true,true),
                    new AuthUser(UUID.randomUUID(),null,"impersonated",Set.of("authorization:manage"),false,true,true,false,UUID.randomUUID()),
                    AuthUser.visitor(UUID.randomUUID(),"visitor","V",Set.of("authorization:manage"))}) {
                login(denied);assertThatThrownBy(controller::current).isInstanceOf(AccessDeniedException.class);
                assertThatThrownBy(()->controller.save(null)).isInstanceOf(AccessDeniedException.class);
            }
            login(new AuthUser(UUID.randomUUID(),null,"admin",Set.of("authorization:manage"),false,true,true));
            assertThatCode(controller::current).doesNotThrowAnyException();
            assertThatCode(()->controller.save(null)).doesNotThrowAnyException();
        }
    }
    @Test void saveUsesExistingOneTimeStepUpGuard() throws Exception {
        assertThat(SmsSettingsController.class.getMethod("save",SmsSettingsDto.Save.class).isAnnotationPresent(RequiresStepUp.class)).isTrue();
    }
    private static void login(AuthUser actor){SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor,null,actor.getAuthorities()));}
}
