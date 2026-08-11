package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.lang.reflect.Method;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class LoginFailureRecorderTest {

    @Mock
    private UserAccountRepository userRepo;
    @Mock
    private SystemSettingsService settings;
    @Mock
    private AuditService audit;
    @Mock
    private TxSessionVars tx;

    private LoginFailureRecorder recorder;

    @BeforeEach
    void setUp() {
        recorder = new LoginFailureRecorder(userRepo, settings, audit, tx);
    }

    @Test
    void transactionIsIndependentFromTheThrowingLoginFlow() throws Exception {
        Method method = LoginFailureRecorder.class
                .getMethod("record", UUID.class, String.class);
        Transactional transactional = method.getAnnotation(Transactional.class);

        assertNotNull(transactional);
        assertEquals(Propagation.REQUIRES_NEW, transactional.propagation());
    }

    @Test
    void thresholdFailureLocksAnActiveAccountAndPersistsTheCounter() {
        UserAccount account = account("active", 2);
        when(userRepo.findByIdForUpdate(account.getId()))
                .thenReturn(Optional.of(account));
        when(settings.readInt("lockout_threshold", 5)).thenReturn(3);
        when(settings.readInt("lockout_minutes", 15)).thenReturn(20);

        recorder.record(account.getId(), account.getLoginAccount());

        verify(tx).bindActor(account.getId(), account.getLoginAccount());
        assertEquals(3, account.getFailedAttempts());
        assertEquals("locked", account.getStatus());
        assertNotNull(account.getLockedUntil());
        verify(userRepo).save(account);
        verify(audit).logExplicit(
                account.getId(),
                account.getLoginAccount(),
                "login_failed",
                "users",
                account.getId().toString(),
                "bad_password");
    }

    @Test
    void failureNeverTurnsDisabledAccountIntoTemporaryAutoUnlock() {
        UserAccount account = account("disabled", 10);
        when(userRepo.findByIdForUpdate(account.getId()))
                .thenReturn(Optional.of(account));

        recorder.record(account.getId(), account.getLoginAccount());

        assertEquals(11, account.getFailedAttempts());
        assertEquals("disabled", account.getStatus());
        assertNull(account.getLockedUntil());
    }

    private UserAccount account(String status, int failedAttempts) {
        UserAccount account = new UserAccount();
        account.setLoginAccount("E001");
        account.setStatus(status);
        account.setFailedAttempts(failedAttempts);
        return account;
    }
}
