package com.uten.imp.features.notice;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * Candidate lookup is only a filter; current effective grants remain authoritative.
 *
 * <p>例外口径（ADR-063 2026-10-09 追加修订）：本池面向超管本身，超管的全量目录镜像算持有
 * 接收权。批量授权语句与业务任务卡发卡池共用、刻意不做超管镜像展开，故真实授予筛完后
 * 必须把活跃超管并回（2026-10-17 修复：批量重构丢了这一步，超管也不再收到任何
 * 服务器状态告警）。
 */
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
        LinkedHashSet<UUID> audience =
                new LinkedHashSet<>(permissions.usersGrantedAll(possible, required));
        audience.addAll(users.findActiveSuperAdminIds());
        return List.copyOf(audience);
    }
}
