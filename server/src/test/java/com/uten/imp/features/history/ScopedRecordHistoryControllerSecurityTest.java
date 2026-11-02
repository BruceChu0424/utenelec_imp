package com.uten.imp.features.history;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.security.AuthUser;
import java.util.*;
import org.junit.jupiter.api.*;
import org.springframework.context.annotation.*;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.context.SecurityContextHolder;

class ScopedRecordHistoryControllerSecurityTest {
    @Configuration @EnableMethodSecurity(proxyTargetClass=true)
    static class Config {
        @Bean ScopedRecordHistoryService service() { return mock(ScopedRecordHistoryService.class); }
        @Bean AuditDetailViewRecorder audit() { return mock(AuditDetailViewRecorder.class); }
        @Bean CompanyFileHistoryController files(ScopedRecordHistoryService service,AuditDetailViewRecorder audit) { return new CompanyFileHistoryController(service,audit); }
        @Bean PermissionHistoryController permissions(ScopedRecordHistoryService service,AuditDetailViewRecorder audit) { return new PermissionHistoryController(service,audit); }
    }
    AnnotationConfigApplicationContext context;
    ScopedRecordHistoryService service;
    @BeforeEach void setup(){ context=new AnnotationConfigApplicationContext(Config.class);service=context.getBean(ScopedRecordHistoryService.class); }
    @AfterEach void close(){ SecurityContextHolder.clearContext();context.close(); }
    void login(boolean admin,Set<String> grants) {
        var user=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"history-security",grants,false,true,admin);
        SecurityContextHolder.getContext().setAuthentication(UsernamePasswordAuthenticationToken.authenticated(user,null,user.getAuthorities()));
    }
    @Test void inheritedPermissionListRequiresBothPrivilegesBeforeServiceInvocation() {
        var controller=context.getBean(PermissionHistoryController.class);
        for(var user:List.of(new AbstractMap.SimpleEntry<>(false,Set.of("authorization:manage")),new AbstractMap.SimpleEntry<>(true,Set.<String>of()),new AbstractMap.SimpleEntry<>(false,Set.of("account:support")))) {
            login(user.getKey(),user.getValue());
            assertThatThrownBy(()->controller.list(null,null,null,null,null,null,null,null,null,null,50)).isInstanceOf(AccessDeniedException.class);
        }
        verifyNoInteractions(service);
        login(true,Set.of("authorization:manage"));
        controller.list(null,null,null,null,null,null,null,null,null,null,50);
        verify(service).search(eq(ScopedRecordHistoryService.Area.PERMISSIONS),any());
    }
    @Test void fileDetailCannotUseAccountSupportOrUnrelatedViewPermission() {
        var controller=context.getBean(CompanyFileHistoryController.class);
        login(false,Set.of("account:support","goods:view"));
        assertThatThrownBy(()->controller.detail(5)).isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(service);
    }
}
