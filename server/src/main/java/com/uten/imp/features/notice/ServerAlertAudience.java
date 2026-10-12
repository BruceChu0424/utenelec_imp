package com.uten.imp.features.notice;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Set;
import java.util.UUID;

/** Candidate lookup is only a filter; current effective grants remain authoritative. */
@Component
@RequiredArgsConstructor
class ServerAlertAudience {
    private final NoticePermissionCandidateQuery candidates;
    private final UserAccountRepository users;
    private final PermissionResolver permissions;

    List<UUID> receivers() {
        Set<String> required = Set.of("notice:read", ServerStatusAlertScheduler.RECEIVE_AUTHORITY);
        List<UUID> possible = candidates.possibleUsers(Set.of(ServerStatusAlertScheduler.RECEIVE_AUTHORITY))
                .map(ids -> ids.stream().sorted().toList())
                .orElseGet(() -> users.findAll().stream()
                        .filter(user -> !user.isDeleted() && "active".equals(user.getStatus()))
                        .map(user -> user.getId()).distinct().toList());
        // Read actual grants in one coherent SQL snapshot. Never dereference
        // detached users' employee/department proxies or perform per-user RBAC.
        return permissions.usersGrantedAll(possible, required);
    }
}
