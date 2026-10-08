package com.uten.imp.features.notice;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Set;
import java.util.UUID;

/** Candidate lookup is only a filter; effective permissions remain authoritative. */
@Component
@RequiredArgsConstructor
class ServerAlertAudience {
    private final NoticePermissionCandidateQuery candidates;
    private final UserAccountRepository users;
    private final PermissionResolver permissions;

    List<UUID> receivers() {
        var possible = candidates.possibleUsers(Set.of(ServerStatusAlertScheduler.RECEIVE_AUTHORITY))
                .map(users::findAllById).orElseGet(users::findAll);
        return possible.stream()
                .filter(user -> !user.isDeleted() && "active".equals(user.getStatus()))
                .filter(user -> permissions.permsOf(user).containsAll(
                        Set.of("notice:read", ServerStatusAlertScheduler.RECEIVE_AUTHORITY)))
                .map(user -> user.getId()).distinct().toList();
    }
}
