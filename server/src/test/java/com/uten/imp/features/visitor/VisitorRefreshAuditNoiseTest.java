package com.uten.imp.features.visitor;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.SmsProperties;
import com.uten.imp.features.org.employee.EmployeeSensitiveRepository;
import com.uten.imp.features.visitor.dto.VisitorAuthDto;
import com.uten.imp.security.JwtService;
import com.uten.imp.security.LoginRateLimiter;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anySet;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class VisitorRefreshAuditNoiseTest {

    @Test
    void successfulAutomaticRotationDoesNotCreateUserActivity() {
        VisitorRefreshTransaction refresh = mock(VisitorRefreshTransaction.class);
        AuditService audit = mock(AuditService.class);
        JwtService jwt = mock(JwtService.class);
        VisitorAccount account = new VisitorAccount();
        UUID visitorId = UUID.randomUUID();
        UUID sessionId = UUID.randomUUID();
        account.setId(visitorId);
        account.setVisitorNo("V778899");
        account.setName("赵访客");
        account.setAvatarSeed("Z");
        when(refresh.rotate("raw", "web")).thenReturn(new VisitorRefreshTransaction.Outcome(
                false, visitorId, UUID.randomUUID(), sessionId, account, "replacement"));
        when(jwt.issueVisitorAccess(
                org.mockito.ArgumentMatchers.eq(visitorId),
                org.mockito.ArgumentMatchers.eq("V778899"),
                org.mockito.ArgumentMatchers.eq("Z"),
                anySet(),
                org.mockito.ArgumentMatchers.eq(sessionId))).thenReturn("access");
        VisitorAuthService service = service(refresh, jwt, audit);

        VisitorAuthDto.VisitorTokenResponse result = service.refresh("raw", "web");

        assertEquals("access", result.accessToken());
        assertEquals("replacement", result.refreshToken());
        verifyNoInteractions(audit);
    }

    @Test
    void failedRotationStillCreatesSecurityEvidence() {
        VisitorRefreshTransaction refresh = mock(VisitorRefreshTransaction.class);
        AuditService audit = mock(AuditService.class);
        when(refresh.rotate("bad", "web"))
                .thenThrow(new ApiException(ErrorCode.UNAUTHORIZED));
        VisitorAuthService service = service(refresh, mock(JwtService.class), audit);

        assertThrows(ApiException.class, () -> service.refresh("bad", "web"));

        verify(audit).logExplicit(
                null, null, "visitor_refresh_failed",
                "visitor_refresh_tokens", null, "unauthorized");
    }

    private VisitorAuthService service(
            VisitorRefreshTransaction refresh,
            JwtService jwt,
            AuditService audit) {
        return new VisitorAuthService(
                mock(VisitorAccountRepository.class),
                mock(VisitorSmsService.class),
                mock(VisitorRefreshTokenService.class),
                mock(VisitorRefreshTokenRepository.class),
                refresh,
                mock(VisitorRefreshCompromiseService.class),
                mock(EmployeeSensitiveRepository.class),
                jwt,
                mock(TxSessionVars.class),
                mock(SmsProperties.class),
                audit,
                mock(LoginRateLimiter.class),
                mock(MasterCodeService.class),
                mock(VisitorAccountCreationLock.class));
    }
}
