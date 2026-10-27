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
        sync.syncLoginAccount(employee,"13800138000","old-hash","new-hash");
        assertEquals(original,account.getLoginAccount());
        verify(users,never()).findByLoginAccount(any());verify(users,never()).save(any());
        verifyNoInteractions(refresh,sessions);
    }

    @Test void ordinaryDisabledAccountStillFollowsItsEmployeePhone() {
        UUID employee=UUID.randomUUID();
        UserAccount account=new UserAccount();account.setEmployeeId(employee);account.setStatus("disabled");
        account.setLoginAccount("13800000001");
        when(users.findByEmployeeId(employee)).thenReturn(Optional.of(account));
        sync.syncLoginAccount(employee,"13800138000","old-hash","new-hash");
        assertEquals("13800138000",account.getLoginAccount());assertEquals("disabled",account.getStatus());
        verify(users).save(account);verify(refresh).revokeAllByUserId(account.getId());
        verify(sessions).revokeAllForUser(account.getId(),AuthSessionService.REASON_LOGIN_ACCOUNT_CHANGED);
    }

    @Test void anUnchangedLoginDoesNotRotateSessionsOrSaveAgain() {
        UUID employee=UUID.randomUUID();UserAccount account=new UserAccount();account.setLoginAccount("13800138000");
        when(users.findByEmployeeId(employee)).thenReturn(Optional.of(account));
        sync.syncLoginAccount(employee,"13800138000","old-hash","new-hash");
        verify(users,never()).save(any());verifyNoInteractions(refresh,sessions);
    }

    @Test void unchangedPrimaryPhoneNeverTouchesAnExplicitCustomLoginOrItsSessions() {
        UUID employee=UUID.randomUUID();
        sync.syncLoginAccount(employee,"13800138000","same-primary-hash","same-primary-hash");
        verifyNoInteractions(users,refresh,sessions);
    }

    @Test void fillingAnUnknownPrimaryPhoneStillSynchronizesAndRevokesTheOldSession() {
        UUID employee=UUID.randomUUID();
        UserAccount account=new UserAccount();account.setEmployeeId(employee);account.setStatus("active");
        account.setLoginAccount("custom-login");
        when(users.findByEmployeeId(employee)).thenReturn(Optional.of(account));
        sync.syncLoginAccount(employee,"13800138000",null,"new-primary-hash");
        assertEquals("13800138000",account.getLoginAccount());
        verify(users).save(account);verify(refresh).revokeAllByUserId(account.getId());
        verify(sessions).revokeAllForUser(account.getId(),AuthSessionService.REASON_LOGIN_ACCOUNT_CHANGED);
    }
}
