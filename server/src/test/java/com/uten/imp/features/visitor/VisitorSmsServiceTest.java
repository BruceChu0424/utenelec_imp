package com.uten.imp.features.visitor;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.visitor.sms.SmsGateway;
import com.uten.imp.features.visitor.sms.SmsSendResult;
import org.junit.jupiter.api.Test;
import org.mockito.InOrder;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.lang.reflect.Method;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class VisitorSmsServiceTest {

    @Test
    void commitsLocalIssuanceBeforeCallingTheExternalGateway() {
        VisitorOtpVerifier verifier = mock(VisitorOtpVerifier.class);
        SmsGateway gateway = mock(SmsGateway.class);
        SystemSettingsService settings = mock(SystemSettingsService.class);
        VisitorSmsIssuanceTransaction issuance =
                mock(VisitorSmsIssuanceTransaction.class);
        VisitorSmsService service = new VisitorSmsService(
                verifier, gateway, settings, issuance);
        UUID issuanceId = UUID.randomUUID();
        when(issuance.prepare(eq("13800138000"), eq("login"), any()))
                .thenReturn(new VisitorSmsIssuanceTransaction.Issuance(issuanceId));
        when(gateway.sendCode(eq("13800138000"), any()))
                .thenReturn(SmsSendResult.ACCEPTED);

        String code = service.send("13800138000", "login");

        assertTrue(code.matches("\\d{6}"));
        InOrder order = inOrder(issuance, gateway);
        order.verify(issuance).prepare("13800138000", "login", code);
        order.verify(gateway).sendCode("13800138000", code);
        verify(issuance, never()).reject(any());
    }

    @Test
    void definitiveProviderRejectionRemovesTheUnsentIssuance() {
        VisitorOtpVerifier verifier = mock(VisitorOtpVerifier.class);
        SmsGateway gateway = mock(SmsGateway.class);
        SystemSettingsService settings = mock(SystemSettingsService.class);
        VisitorSmsIssuanceTransaction issuance =
                mock(VisitorSmsIssuanceTransaction.class);
        VisitorSmsService service = new VisitorSmsService(
                verifier, gateway, settings, issuance);
        UUID issuanceId = UUID.randomUUID();
        when(issuance.prepare(eq("13800138000"), eq("login"), any()))
                .thenReturn(new VisitorSmsIssuanceTransaction.Issuance(issuanceId));
        when(gateway.sendCode(eq("13800138000"), any()))
                .thenReturn(SmsSendResult.REJECTED);

        assertThrows(ApiException.class, () -> service.send("13800138000", "login"));

        verify(issuance).reject(issuanceId);
    }

    @Test
    void uncertainProviderOutcomeKeepsTheIssuedOtpAndDoesNotRetry() {
        VisitorOtpVerifier verifier = mock(VisitorOtpVerifier.class);
        SmsGateway gateway = mock(SmsGateway.class);
        SystemSettingsService settings = mock(SystemSettingsService.class);
        VisitorSmsIssuanceTransaction issuance =
                mock(VisitorSmsIssuanceTransaction.class);
        VisitorSmsService service = new VisitorSmsService(
                verifier, gateway, settings, issuance);
        UUID issuanceId = UUID.randomUUID();
        when(issuance.prepare(eq("13800138000"), eq("login"), any()))
                .thenReturn(new VisitorSmsIssuanceTransaction.Issuance(issuanceId));
        when(gateway.sendCode(eq("13800138000"), any()))
                .thenReturn(SmsSendResult.UNCERTAIN);

        String code = service.send("13800138000", "login");

        assertEquals(6, code.length());
        verify(gateway).sendCode("13800138000", code);
        verify(issuance, never()).reject(any());
    }

    @Test
    void transactionBoundaryCommitsIssuanceBeforeExternalIo() throws Exception {
        Method authFacade = VisitorAuthService.class.getMethod(
                "sendCode",
                String.class,
                String.class);
        Method send = VisitorSmsService.class.getMethod(
                "send",
                String.class,
                String.class);
        Method prepare = VisitorSmsIssuanceTransaction.class.getMethod(
                "prepare",
                String.class,
                String.class,
                String.class);
        Method reject = VisitorSmsIssuanceTransaction.class.getMethod(
                "reject",
                UUID.class);

        assertNull(authFacade.getAnnotation(Transactional.class));
        assertNull(send.getAnnotation(Transactional.class));
        assertEquals(
                Propagation.REQUIRES_NEW,
                prepare.getAnnotation(Transactional.class).propagation());
        assertEquals(
                Propagation.REQUIRES_NEW,
                reject.getAnnotation(Transactional.class).propagation());
    }
}
