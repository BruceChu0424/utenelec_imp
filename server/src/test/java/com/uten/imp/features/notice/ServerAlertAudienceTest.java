package com.uten.imp.features.notice;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class ServerAlertAudienceTest {
    @Test void candidateGrantsCannotOverrideRevocationOrDisabledAccount() {
        var candidates = mock(NoticePermissionCandidateQuery.class);
        var users = mock(UserAccountRepository.class);
        var permissions = mock(PermissionResolver.class);
        var allowed = user("active");
        var revoked = user("active");
        var noNotice = user("active");
        var disabled = user("disabled");
        var deleted = user("active");deleted.setDeleted(true);
        when(candidates.possibleUsers(any())).thenReturn(Optional.empty());
        when(users.findAll()).thenReturn(List.of(allowed, revoked, noNotice, disabled, deleted));
        UUID allowedId=allowed.getId();
        List<UUID> activeIds=List.of(allowedId,revoked.getId(),noNotice.getId());
        when(permissions.usersGrantedAll(activeIds,
                Set.of("notice:read",ServerStatusAlertScheduler.RECEIVE_AUTHORITY))).thenReturn(List.of(allowedId));
        assertThat(new ServerAlertAudience(candidates, users, permissions).receivers()).containsExactly(allowed.getId());
        verify(permissions,never()).permsOf(any(UserAccount.class));
        verify(permissions,times(1)).usersGrantedAll(anyList(),eq(Set.of("notice:read",ServerStatusAlertScheduler.RECEIVE_AUTHORITY)));
    }
    @Test void completeCandidateShapeAvoidsLoadingDetachedUserEntitiesEntirely() {
        var candidates=mock(NoticePermissionCandidateQuery.class);
        var users=mock(UserAccountRepository.class);
        var permissions=mock(PermissionResolver.class);
        UUID allowed=UUID.randomUUID(),revoked=UUID.randomUUID();
        when(candidates.possibleUsers(any())).thenReturn(Optional.of(Set.of(allowed,revoked)));
        when(permissions.usersGrantedAll(anyList(),anySet())).thenReturn(List.of(allowed));
        assertThat(new ServerAlertAudience(candidates,users,permissions).receivers()).containsExactly(allowed);
        verifyNoInteractions(users);
        verify(permissions,never()).permsOf(any(UserAccount.class));
    }
    private static UserAccount user(String status) {
        var user=spy(new UserAccount());user.setId(UUID.randomUUID());user.setStatus(status);
        doThrow(new AssertionError("Detached employee proxy must never be dereferenced")).when(user).getEmployee();
        return user;
    }
}
