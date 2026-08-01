package com.uten.imp.features.sales.ret;

import com.uten.imp.features.sales.ret.dto.ReturnQualityDispositionRequest;
import org.aopalliance.intercept.MethodInvocation;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.authorization.AuthorizationDecision;
import org.springframework.security.authorization.method.PreAuthorizeAuthorizationManager;

import java.lang.reflect.Method;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SalesReturnQualitySecurityContractTest {

    private static final String DISPOSITION_AUTHORIZATION =
            "hasAuthority('sales_return_quality:view')"
                    + " and hasAuthority('sales_return_quality:handle')";

    @Test
    void dispositionRequiresViewAndHandleAtControllerAndService()
            throws Exception {
        assertDispositionAuthorization(dispositionControllerMethod());
        assertDispositionAuthorization(dispositionServiceMethod());
    }

    @Test
    void handleOnlyCannotAuthorizeServiceDisposition() throws Exception {
        AuthorizationDecision decision = authorize(
                dispositionServiceMethod(),
                "sales_return_quality:handle");

        assertNotNull(decision);
        assertFalse(decision.isGranted());
    }

    @Test
    void viewAndHandleAuthorizeServiceDisposition() throws Exception {
        AuthorizationDecision decision = authorize(
                dispositionServiceMethod(),
                "sales_return_quality:view",
                "sales_return_quality:handle");

        assertNotNull(decision);
        assertTrue(decision.isGranted());
    }

    private static Method dispositionControllerMethod()
            throws NoSuchMethodException {
        return SalesReturnController.class.getMethod(
                "dispose",
                UUID.class,
                UUID.class,
                ReturnQualityDispositionRequest.class);
    }

    private static Method dispositionServiceMethod()
            throws NoSuchMethodException {
        return SalesReturnQualityService.class.getMethod(
                "dispose",
                UUID.class,
                UUID.class,
                ReturnQualityDispositionRequest.class);
    }

    private static void assertDispositionAuthorization(Method method) {
        PreAuthorize annotation = method.getAnnotation(PreAuthorize.class);
        assertNotNull(annotation, "Disposition method must use @PreAuthorize");
        assertEquals(DISPOSITION_AUTHORIZATION, annotation.value());
    }

    private static AuthorizationDecision authorize(
            Method method, String... authorities) {
        TestingAuthenticationToken authentication =
                new TestingAuthenticationToken("quality-user", null, authorities);
        authentication.setAuthenticated(true);

        MethodInvocation invocation = mock(MethodInvocation.class);
        when(invocation.getMethod()).thenReturn(method);
        when(invocation.getThis()).thenReturn(mock(method.getDeclaringClass()));
        when(invocation.getArguments()).thenReturn(new Object[]{
                UUID.randomUUID(),
                UUID.randomUUID(),
                mock(ReturnQualityDispositionRequest.class)
        });

        PreAuthorizeAuthorizationManager manager =
                new PreAuthorizeAuthorizationManager();
        return manager.check(() -> authentication, invocation);
    }
}
