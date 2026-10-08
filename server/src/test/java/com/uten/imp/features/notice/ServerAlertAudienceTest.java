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
        when(candidates.possibleUsers(any())).thenReturn(Optional.empty());
        when(users.findAll()).thenReturn(List.of(allowed, revoked, noNotice, disabled));
        when(permissions.permsOf(allowed)).thenReturn(Set.of("notice:read", "server_status:alert:receive"));
        when(permissions.permsOf(revoked)).thenReturn(Set.of("notice:read"));
        when(permissions.permsOf(noNotice)).thenReturn(Set.of("server_status:alert:receive"));
        assertThat(new ServerAlertAudience(candidates, users, permissions).receivers())
                .containsExactly(allowed.getId());
        verify(permissions, never()).permsOf(disabled);
    }
    private static UserAccount user(String status) {
        var user = new UserAccount();
        user.setId(UUID.randomUUID()); user.setStatus(status);
        return user;
    }
}
