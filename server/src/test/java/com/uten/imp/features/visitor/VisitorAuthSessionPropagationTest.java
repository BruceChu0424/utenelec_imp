package com.uten.imp.features.visitor;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.SmsProperties;
import com.uten.imp.features.org.employee.EmployeeSensitiveRepository;
import com.uten.imp.features.visitor.dto.VisitorAuthDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.JwtService;
import com.uten.imp.security.LoginRateLimiter;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;

import java.time.OffsetDateTime;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anySet;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class VisitorAuthSessionPropagationTest {

    @Test
    void visitorLoginSignsAndAuditsTheNewServerSession() {
        UUID sessionId = UUID.randomUUID();
        VisitorAccount account = new VisitorAccount();
        account.setVisitorNo("V800015");
        account.setName("访客");
        account.setAvatarSeed("seed");
        account.setStatus("active");
        VisitorAccountRepository accounts = mock(VisitorAccountRepository.class);
        when(accounts.findByPhoneHash("phone-hash")).thenReturn(Optional.of(account));
        when(accounts.save(account)).thenReturn(account);
        VisitorSmsService sms = mock(VisitorSmsService.class);
        VisitorRefreshTokenService refresh = mock(VisitorRefreshTokenService.class);
        when(refresh.issueNewSession(account.getId(), "ua")).thenReturn(
                new VisitorRefreshTokenService.IssuedRefreshToken(
                        "refresh", UUID.randomUUID(), sessionId,
                        OffsetDateTime.now().plusDays(7)));
        EmployeeSensitiveRepository employees = mock(EmployeeSensitiveRepository.class);
        when(employees.findByPhoneHash("phone-hash")).thenReturn(Optional.empty());
        TxSessionVars tx = mock(TxSessionVars.class);
        when(tx.hmac("13800138000")).thenReturn("phone-hash");
        JwtService jwt = mock(JwtService.class);
        when(jwt.issueVisitorAccess(
                eq(account.getId()),
                eq("V800015"),
                eq("seed"),
                anySet(),
                eq(sessionId))).thenReturn("access");
        AuditService audit = mock(AuditService.class);
        VisitorAuthService service = new VisitorAuthService(
                accounts,
                sms,
                refresh,
                mock(VisitorRefreshTokenRepository.class),
                mock(VisitorRefreshTransaction.class),
                mock(VisitorRefreshCompromiseService.class),
                employees,
                jwt,
                mock(SecurityContextCurrentUser.class),
                tx,
                mock(SmsProperties.class),
                audit,
                mock(LoginRateLimiter.class),
                mock(MasterCodeService.class),
                mock(VisitorAccountCreationLock.class),
                mock(com.uten.imp.features.auth.AuthSessionService.class));

        VisitorAuthDto.VisitorTokenResponse result = service.login(
                "13800138000", "123456", "ua", "127.0.0.1");

        assertEquals("access", result.accessToken());
        assertEquals("refresh", result.refreshToken());
        verify(audit).logCommitted(
                eq(account.getId()),
                eq("138****8000"),
                eq("visitor_login"),
                eq("visitor_account"),
                eq(account.getId().toString()),
                eq("success"),
                eq(sessionId));
    }

    @Test
    void visitorMeReturnsCurrentAccountProfileForVisitorPrincipalOnly() {
        UUID visitorId = UUID.randomUUID();
        VisitorAccount account = new VisitorAccount();
        account.setId(visitorId);
        account.setVisitorNo("V800015");
        account.setName("访客");
        account.setAvatarSeed("seed");
        account.setStatus("active");
        AuthUser principal = mock(AuthUser.class);
        when(principal.isVisitor()).thenReturn(true);
        when(principal.getId()).thenReturn(visitorId);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenReturn(Optional.of(principal));
        VisitorAccountRepository accounts = mock(VisitorAccountRepository.class);
        when(accounts.findById(visitorId)).thenReturn(Optional.of(account));
        VisitorAuthService service = new VisitorAuthService(
                accounts,
                mock(VisitorSmsService.class),
                mock(VisitorRefreshTokenService.class),
                mock(VisitorRefreshTokenRepository.class),
                mock(VisitorRefreshTransaction.class),
                mock(VisitorRefreshCompromiseService.class),
                mock(EmployeeSensitiveRepository.class),
                mock(JwtService.class),
                currentUser,
                mock(TxSessionVars.class),
                mock(SmsProperties.class),
                mock(AuditService.class),
                mock(LoginRateLimiter.class),
                mock(MasterCodeService.class),
                mock(VisitorAccountCreationLock.class),
                mock(com.uten.imp.features.auth.AuthSessionService.class));

        VisitorAuthDto.MeResponse me = service.me();

        assertEquals(visitorId, me.visitorId());
        assertEquals("V800015", me.visitorNo());
        assertEquals("访客", me.name());
        assertEquals("active", me.status());

        when(principal.isVisitor()).thenReturn(false);
        assertEquals(
                ErrorCode.FORBIDDEN,
                assertThrows(ApiException.class, service::me).getCode());
    }

    @Test
    void visitorRefreshRotationKeepsSessionAndReplacementLink() {
        String raw = "visitor-refresh";
        UUID sessionId = UUID.randomUUID();
        VisitorRefreshToken current = new VisitorRefreshToken();
        current.setVisitorAccountId(UUID.randomUUID());
        current.setSessionId(sessionId);
        current.setTokenHash(HashUtil.sha256(raw));
        current.setExpiresAt(OffsetDateTime.now().plusHours(1));
        VisitorAccount account = new VisitorAccount();
        account.setStatus("active");
        VisitorRefreshTokenRepository repository = mock(VisitorRefreshTokenRepository.class);
        when(repository.findAndLockByTokenHash(current.getTokenHash()))
                .thenReturn(Optional.of(current));
        VisitorAccountRepository accounts = mock(VisitorAccountRepository.class);
        when(accounts.findById(current.getVisitorAccountId()))
                .thenReturn(Optional.of(account));
        VisitorRefreshTokenService tokenService = mock(VisitorRefreshTokenService.class);
        UUID replacementId = UUID.randomUUID();
        when(tokenService.issueInSession(account.getId(), "new-ua", sessionId, current.getExpiresAt()))
                .thenReturn(new VisitorRefreshTokenService.IssuedRefreshToken(
                        "replacement", replacementId, sessionId,
                        current.getExpiresAt()));
        com.uten.imp.features.auth.AuthSessionService sessions =
                mock(com.uten.imp.features.auth.AuthSessionService.class);
        when(sessions.lockAndEvaluateForRefresh(sessionId, null, current.getVisitorAccountId()))
                .thenReturn(com.uten.imp.features.auth.AuthSessionService.Verdict.ACTIVE);
        VisitorRefreshTransaction transaction = new VisitorRefreshTransaction(
                repository, tokenService, accounts, sessions);

        VisitorRefreshTransaction.Outcome outcome = transaction.rotate(raw, "new-ua");

        assertEquals(sessionId, outcome.sessionId());
        assertEquals("replacement", outcome.newRefreshToken());
        verify(tokenService).revoke(current, replacementId);
    }
}
