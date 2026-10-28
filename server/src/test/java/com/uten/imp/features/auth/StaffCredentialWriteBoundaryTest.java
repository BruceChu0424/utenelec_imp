package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.DeploymentProperties;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.model.*;
import com.uten.imp.security.RemoteAccessPolicy;
import com.uten.imp.security.TxSessionVars;
import java.time.OffsetDateTime;
import java.util.Optional;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class StaffCredentialWriteBoundaryTest {
    @Test void aPasswordFailureCannotBeAppliedToAConcurrentResetCredentialGeneration() {
        var users=mock(UserAccountRepository.class,call->call.getMethod().getName().equals("existsAuthenticatableEmployee")
                ? true : RETURNS_DEFAULTS.answer(call));
        var before=new UserAccount();before.setEmployeeId(UUID.randomUUID());before.setLoginAccount("reset-race-staff");before.setPasswordHash("old-fixture-hash");
        var reset=new UserAccount();reset.setId(before.getId());reset.setEmployeeId(before.getEmployeeId());reset.setLoginAccount(before.getLoginAccount());
        reset.setPasswordHash("new-fixture-hash");reset.setMustChangePassword(true);reset.setFailedAttempts(0);
        when(users.findByLoginAccount(before.getLoginAccount())).thenReturn(Optional.of(before));
        when(users.findByIdForUpdate(before.getId())).thenReturn(Optional.of(reset));
        var settings=mock(SystemSettingsService.class);
        when(settings.readInt(com.uten.imp.features.admin.systemsetting.SystemSettingKey.LOCKOUT_THRESHOLD)).thenReturn(1);
        when(settings.readInt(com.uten.imp.features.admin.systemsetting.SystemSettingKey.LOCKOUT_MINUTES)).thenReturn(15);
        var audit=mock(AuditService.class);var recorder=new LoginFailureRecorder(users,settings,audit,mock(TxSessionVars.class));
        var passwords=mock(org.springframework.security.crypto.password.PasswordEncoder.class);
        when(passwords.encode(anyString())).thenReturn("dummy-fixture-hash");
        var deployment=new DeploymentProperties();deployment.setSite("local");
        var login=new LoginService(users,passwords,mock(com.uten.imp.security.LoginRateLimiter.class),audit,
                recorder,new RemoteAccessPolicy(deployment),mock(StaffLoginTransaction.class));
        assertEquals(ErrorCode.BAD_CREDENTIALS,assertThrows(ApiException.class,
                ()->login.login(new com.uten.imp.features.auth.dto.LoginRequest(before.getLoginAccount(),"old-attempt"),"192.0.2.1")).getCode());
        assertEquals(0,reset.getFailedAttempts());assertEquals("active",reset.getStatus());
        assertEquals("new-fixture-hash",reset.getPasswordHash());verify(users,never()).save(any());
    }

    @Test void aFailureFinishingAfterAccountClosureCannotMutateTheRetainedAccount() {
        var users=mock(UserAccountRepository.class);var user=new UserAccount();
        user.setDeleted(true);user.setStatus("disabled");user.setFailedAttempts(7);
        when(users.findByIdForUpdate(user.getId())).thenReturn(Optional.of(user));
        var recorder=new LoginFailureRecorder(users,mock(SystemSettingsService.class),mock(AuditService.class),mock(TxSessionVars.class));
        recorder.record(user.getId(),"closed-staff-fixture","bad_password",user.getPasswordHash(),user.getAuthVersion());
        assertEquals(7,user.getFailedAttempts());assertEquals("disabled",user.getStatus());
        verify(users,never()).save(any());
    }

    @Test void anExpiredBruteLockStillRequiresPasswordLoginAndCannotCommitAnUndeliverableRefresh() {
        var users=mock(UserAccountRepository.class);var tokens=mock(RefreshTokenRepository.class);
        var tokenService=mock(RefreshTokenService.class);var sessions=mock(AuthSessionService.class);
        var deployment=new DeploymentProperties();deployment.setSite("local");
        var transaction=new StaffRefreshTransaction(users,tokens,tokenService,new RemoteAccessPolicy(deployment),sessions);
        var user=new UserAccount();user.setStatus("locked");user.setLockedUntil(OffsetDateTime.now().minusMinutes(1));
        var token=new RefreshToken();token.setUserId(user.getId());token.setSessionId(UUID.randomUUID());
        token.setTokenHash(HashUtil.sha256("locked-staff-refresh-fixture"));token.setExpiresAt(OffsetDateTime.now().plusHours(1));
        var identity=mock(RefreshTokenRepository.Identity.class);when(identity.getUserId()).thenReturn(user.getId());when(identity.getSessionId()).thenReturn(token.getSessionId());
        when(tokens.findIdentityByTokenHash(token.getTokenHash())).thenReturn(Optional.of(identity));
        when(users.findByIdForUpdate(user.getId())).thenReturn(Optional.of(user));
        when(tokens.findAndLockByTokenHash(token.getTokenHash())).thenReturn(Optional.of(token));
        when(sessions.lockAndEvaluateForRefresh(token.getSessionId(),user.getId(),null)).thenReturn(AuthSessionService.RefreshVerdict.active());
        lenient().when(tokenService.issueInSession(any(),any(),any(),any())).thenReturn(new RefreshTokenService.IssuedRefreshToken("unreturned-fixture",UUID.randomUUID(),token.getSessionId(),token.getExpiresAt()));
        ApiException error=assertThrows(ApiException.class,()->transaction.rotate("locked-staff-refresh-fixture"));
        assertEquals(ErrorCode.ACCOUNT_LOCKED,error.getCode());
        assertNull(token.getRevokedAt());assertNull(token.getReplacedBy());
        verifyNoInteractions(tokenService);
    }
}
