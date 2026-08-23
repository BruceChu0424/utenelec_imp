package com.uten.imp.features.sales.ret;

import com.uten.imp.features.sales.ret.dto.ReturnQualityDispositionRequest;
import com.uten.imp.features.sales.ret.dto.ReturnQualityCorrectionRequest;
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
                    + " and hasAuthority('sales_return_quality:dispose')";

    private static final String CORRECTION_AUTHORIZATION =
            "hasAuthority('sales_return_quality:view')"
                    + " and hasAuthority('sales_return_quality:correct')";

    @Test
    void dispositionRequiresViewAndDisposeAtControllerAndService()
            throws Exception {
        assertAuthorization(dispositionControllerMethod(), DISPOSITION_AUTHORIZATION);
        assertAuthorization(dispositionServiceMethod(), DISPOSITION_AUTHORIZATION);
    }

    @Test
    void correctionRequiresViewAndCorrectAtControllerAndService()
            throws Exception {
        assertAuthorization(correctionControllerMethod(), CORRECTION_AUTHORIZATION);
        assertAuthorization(correctionServiceMethod(), CORRECTION_AUTHORIZATION);
    }

    @Test
    void disposeOnlyCannotAuthorizeServiceDisposition() throws Exception {
        AuthorizationDecision decision = authorize(
                dispositionServiceMethod(),
                "sales_return_quality:dispose");

        assertNotNull(decision);
        assertFalse(decision.isGranted());
    }

    @Test
    void viewAndDisposeAuthorizeServiceDisposition() throws Exception {
        AuthorizationDecision decision = authorize(
                dispositionServiceMethod(),
                "sales_return_quality:view",
                "sales_return_quality:dispose");

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
    private static Method correctionControllerMethod()
            throws NoSuchMethodException {
        return SalesReturnController.class.getMethod(
                "correctQuality",
                UUID.class,
                UUID.class,
                ReturnQualityCorrectionRequest.class);
    }

    private static Method correctionServiceMethod()
            throws NoSuchMethodException {
        return SalesReturnQualityService.class.getMethod(
                "correct",
                UUID.class,
                UUID.class,
                ReturnQualityCorrectionRequest.class);
    }


    private static void assertAuthorization(Method method, String expected) {
        PreAuthorize annotation = method.getAnnotation(PreAuthorize.class);
        assertNotNull(annotation, "Quality action method must use @PreAuthorize");
        assertEquals(expected, annotation.value());
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
