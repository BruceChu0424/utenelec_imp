package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.config.props.SecurityProperties;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.dto.ChangePasswordRequest;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.PasswordHistoryRepository;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.PasswordPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.mockito.InOrder;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.security.crypto.password.PasswordEncoder;

import java.lang.reflect.Method;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class PasswordAccessInvalidationTest {

    @Test
    void passwordChangeFlushesThenBumpsAndReloadsBeforeIssuingReplacementToken() {
        UserAccountRepository users = mock(UserAccountRepository.class);
        PasswordHistoryRepository history = mock(PasswordHistoryRepository.class);
        RefreshTokenRepository refreshTokens = mock(RefreshTokenRepository.class);
        PasswordEncoder encoder = mock(PasswordEncoder.class);
        PasswordPolicy policy = mock(PasswordPolicy.class);
        SystemSettingsService settings = mock(SystemSettingsService.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        AuditService audit = mock(AuditService.class);
        TokenIssuer tokenIssuer = mock(TokenIssuer.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        UserAccount user = new UserAccount();
        user.setLoginAccount("E1001");
        user.setPasswordHash("old-hash");
        user.setMustChangePassword(true);
        UserAccount refreshedUser = new UserAccount();
        refreshedUser.setId(user.getId());
        refreshedUser.setLoginAccount("E1001");
        refreshedUser.setPasswordHash("new-hash");
        refreshedUser.setMustChangePassword(false);
        refreshedUser.setAuthVersion(1);
        TokenResponse replacement = new TokenResponse(
                "access",
                "refresh",
                900,
                false,
                null);

        when(currentUser.requireId()).thenReturn(user.getId());
        when(users.findById(user.getId()))
                .thenReturn(java.util.Optional.of(user))
                .thenReturn(java.util.Optional.of(refreshedUser));
        when(encoder.matches("old-password", "old-hash")).thenReturn(true);
        when(settings.readInt("password_history_size", 5)).thenReturn(5);
        when(history.findRecent(user.getId(), 5)).thenReturn(List.of());
        when(encoder.encode("new-password")).thenReturn("new-hash");
        when(users.save(user)).thenReturn(user);
        when(users.bumpAuthVersion(user.getId())).thenReturn(1);
        when(tokenIssuer.issueTokens(refreshedUser)).thenReturn(replacement);

        PasswordService service = new PasswordService(
                users,
                history,
                refreshTokens,
                encoder,
                policy,
                mock(SecurityProperties.class),
                settings,
                currentUser,
                audit,
                tokenIssuer,
                tx);

        TokenResponse actual = service.changePassword(new ChangePasswordRequest(
                "old-password",
                "new-password"));

        assertEquals(replacement, actual);
        assertEquals("new-hash", user.getPasswordHash());
        assertFalse(user.isMustChangePassword());
        assertNotNull(user.getLastPasswordChangedAt());
        InOrder order = inOrder(users, refreshTokens, tokenIssuer);
        order.verify(users).save(user);
        order.verify(users).bumpAuthVersion(user.getId());
        order.verify(refreshTokens).revokeAllByUserId(user.getId());
        order.verify(users).findById(user.getId());
        order.verify(tokenIssuer).issueTokens(refreshedUser);
        assertEquals(1, refreshedUser.getAuthVersion());
        assertFalse(refreshedUser.isMustChangePassword());
    }

    @Test
    void nativeAuthVersionBumpFlushesPendingPasswordStateAndClearsPersistenceContext()
            throws Exception {
        Method bump = UserAccountRepository.class.getMethod(
                "bumpAuthVersion",
                UUID.class);
        Modifying modifying = bump.getAnnotation(Modifying.class);

        assertNotNull(modifying);
        assertTrue(modifying.flushAutomatically());
        assertTrue(modifying.clearAutomatically());
    }
}
