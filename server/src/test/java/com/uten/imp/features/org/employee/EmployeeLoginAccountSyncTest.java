package com.uten.imp.features.org.employee;

import com.uten.imp.features.auth.AuthSessionService;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.*;

class EmployeeLoginAccountSyncTest {
    private final UserAccountRepository users=mock(UserAccountRepository.class);
    private final RefreshTokenRepository refresh=mock(RefreshTokenRepository.class);
    private final AuthSessionService sessions=mock(AuthSessionService.class);
    private final EmployeeLoginAccountSync sync=new EmployeeLoginAccountSync(users,refresh,sessions);

    @Test void archivedUnopenedAccountNeverReclaimsAReleasedLoginName() {
        UUID employee=UUID.randomUUID();
        UserAccount account=new UserAccount();account.setEmployeeId(employee);account.setDeleted(true);
        account.setStatus("disabled");account.setLoginAccount("archived-"+account.getId());
        String original=account.getLoginAccount();
        when(users.findByEmployeeId(employee)).thenReturn(Optional.of(account));
        sync.syncLoginAccount(employee,"13800138000");
        assertEquals(original,account.getLoginAccount());
        verify(users,never()).findByLoginAccount(any());verify(users,never()).save(any());
        verifyNoInteractions(refresh,sessions);
    }

    @Test void ordinaryDisabledAccountStillFollowsItsEmployeePhone() {
        UUID employee=UUID.randomUUID();
        UserAccount account=new UserAccount();account.setEmployeeId(employee);account.setStatus("disabled");
        account.setLoginAccount("13800000001");
        when(users.findByEmployeeId(employee)).thenReturn(Optional.of(account));
        sync.syncLoginAccount(employee,"13800138000");
        assertEquals("13800138000",account.getLoginAccount());assertEquals("disabled",account.getStatus());
        verify(users).save(account);verify(refresh).revokeAllByUserId(account.getId());
        verify(sessions).revokeAllForUser(account.getId(),AuthSessionService.REASON_LOGIN_ACCOUNT_CHANGED);
    }

    @Test void anUnchangedLoginDoesNotRotateSessionsOrSaveAgain() {
        UUID employee=UUID.randomUUID();UserAccount account=new UserAccount();account.setLoginAccount("13800138000");
        when(users.findByEmployeeId(employee)).thenReturn(Optional.of(account));
        sync.syncLoginAccount(employee,"13800138000");
        verify(users,never()).save(any());verifyNoInteractions(refresh,sessions);
    }
}
