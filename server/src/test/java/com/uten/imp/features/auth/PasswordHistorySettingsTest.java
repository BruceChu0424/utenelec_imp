package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.SecurityProperties;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.dto.ChangePasswordRequest;
import com.uten.imp.features.auth.model.*;
import com.uten.imp.security.*;
import org.junit.jupiter.api.Test;
import org.springframework.security.crypto.password.PasswordEncoder;
import java.util.Optional;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class PasswordHistorySettingsTest {
    @Test
    void zeroHistoryMakesNoPageQueryAndNegativeValuesRemainInvalid() {
        PasswordHistoryRepository history = mock(PasswordHistoryRepository.class, CALLS_REAL_METHODS);
        UUID userId = UUID.randomUUID();
        assertTrue(history.findRecent(userId, 0).isEmpty());
        assertThrows(IllegalArgumentException.class, () -> history.findRecent(userId, -1));
        verify(history, never()).findByUserIdOrderByChangedAtDesc(any(), any());
    }

    @Test
    void currentPasswordCannotBeReusedWithHistoryDisabled() {
        UserAccountRepository users = mock(UserAccountRepository.class);
        PasswordHistoryRepository history = mock(PasswordHistoryRepository.class);
        PasswordEncoder encoder = mock(PasswordEncoder.class);
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        UserAccount user = new UserAccount();
        user.setId(UUID.randomUUID());
        user.setPasswordHash("hash");
        when(current.requireId()).thenReturn(user.getId());
        when(users.findById(user.getId())).thenReturn(Optional.of(user));
        when(encoder.matches("CurrentPassword!", "hash")).thenReturn(true);
        PasswordService service = new PasswordService(users, history,
                mock(RefreshTokenRepository.class), encoder, mock(PasswordPolicy.class),
                mock(SecurityProperties.class), mock(SystemSettingsService.class), current,
                mock(AuditService.class), mock(TokenIssuer.class), mock(TxSessionVars.class));
        ApiException error = assertThrows(ApiException.class, () -> service.changePassword(
                new ChangePasswordRequest("CurrentPassword!", "CurrentPassword!")));
        assertEquals(ErrorCode.PASSWORD_REUSE, error.getCode());
        verify(users, never()).save(any());
        verifyNoInteractions(history);
    }
}
