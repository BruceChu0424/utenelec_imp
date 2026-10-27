package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.dto.LoginRequest;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.LoginRateLimiter;
import com.uten.imp.security.RemoteAccessPolicy;
import org.junit.jupiter.api.Test;
import org.springframework.security.crypto.password.PasswordEncoder;
import java.util.Optional;
import java.util.function.Supplier;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class RemoteMfaLoginTest {
    final UserAccountRepository users=mock(UserAccountRepository.class);
    final PasswordEncoder passwords=mock(PasswordEncoder.class);
    final RemoteAccessPolicy access=mock(RemoteAccessPolicy.class);
    final RemoteMfaService mfa=mock(RemoteMfaService.class);
    final StaffLoginTransaction login=mock(StaffLoginTransaction.class);
    final LoginService service=new LoginService(users,passwords,mock(LoginRateLimiter.class),mock(AuditService.class),
            mock(LoginFailureRecorder.class),access,login,mfa);

    @Test void passwordAndEligibilityAreCheckedBeforeFactorAndTokenIssuance() {
        var user=user();
        when(passwords.matches("password","hash")).thenReturn(true);
        when(access.isRemoteRequest()).thenReturn(true);
        when(mfa.remoteLogin(eq(user.getId()),eq("123456"),any())).thenAnswer(inv->inv.<Supplier<TokenResponse>>getArgument(2).get());
        service.login(new LoginRequest("E1","password","123456"),"192.0.2.1");
        var order=inOrder(passwords,access,mfa,login);
        order.verify(passwords).matches("password","hash");
        order.verify(access).requireStaffAccess(user);
        order.verify(access).isRemoteRequest();
        order.verify(mfa).remoteLogin(eq(user.getId()),eq("123456"),any());
        order.verify(login).completeRemote(user.getId(),"hash");
        verify(login,never()).complete(any(),any());
    }

    @Test void wrongPasswordAndDeniedRemoteEligibilityNeverConsumeOtp() {
        var user=user();
        assertThatThrownBy(()->service.login(new LoginRequest("E1","wrong","123456"),"192.0.2.1"))
                .isInstanceOfSatisfying(ApiException.class,ex->assertThat(ex.getCode()).isEqualTo(ErrorCode.BAD_CREDENTIALS));
        verifyNoInteractions(mfa,login);
        when(passwords.matches("password","hash")).thenReturn(true);
        doThrow(new ApiException(ErrorCode.REMOTE_ACCESS_DENIED)).when(access).requireStaffAccess(user);
        assertThatThrownBy(()->service.login(new LoginRequest("E1","password","123456"),"192.0.2.1"))
                .isInstanceOfSatisfying(ApiException.class,ex->assertThat(ex.getCode()).isEqualTo(ErrorCode.REMOTE_ACCESS_DENIED));
        verifyNoInteractions(mfa,login);
    }

    @Test void localLoginRetainsExistingNonMfaContractAndNeverConsumesOptionalCode() {
        var user=user();when(passwords.matches("password","hash")).thenReturn(true);
        service.login(new LoginRequest("E1","password","123456"),"192.168.1.4");
        verify(login).complete(user.getId(),"hash");verifyNoInteractions(mfa);
    }

    private UserAccount user(){var u=new UserAccount();u.setLoginAccount("E1");u.setPasswordHash("hash");u.setMustChangePassword(false);u.setRemoteAccess(true);
        u.setEmployeeId(java.util.UUID.randomUUID());when(users.existsAuthenticatableEmployee(eq(u.getEmployeeId()),anyCollection())).thenReturn(true);
        when(users.findByLoginAccount("E1")).thenReturn(Optional.of(u));return u;}
}
