package com.uten.imp.features.auth;

import com.uten.imp.application.port.WebsiteActorAuthorityPort;
import com.uten.imp.features.auth.model.UserAccountRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

@Service
@RequiredArgsConstructor
public class WebsiteActorAuthorityAdapter implements WebsiteActorAuthorityPort {
    private final UserAccountRepository users;
    private final PermissionResolver permissions;
    private final AuthSessionService sessions;

    @Override
    @Transactional(readOnly=true)
    public Set<String> currentPermissions(UUID actorId,UUID authSessionId) {
        if(actorId==null || authSessionId==null)return Set.of();
        var origin=sessions.loadStaff(actorId,authSessionId,actorId).orElse(null);
        if(origin==null || origin.session()==null || origin.session().revokedAt()!=null
                || !origin.session().absoluteExpiresAt().isAfter(sessions.now()))return Set.of();
        var account=users.findById(actorId).orElse(null);
        if(account==null || account.isDeleted() || !"active".equals(account.getStatus())
                || account.isMustChangePassword() || account.getEmployeeId()==null)return Set.of();
        var employee=account.getEmployee();
        if(employee==null || employee.isDeleted()
                || !Set.of("active","probation","onLeave").contains(employee.getStatus()))return Set.of();
        // Mirrors current staff operation authority, including current super-admin status.
        // Notification recipient selection deliberately retains its separate granted-authority policy.
        Set<String> resolved=permissions.permsOf(account);
        if(!resolved.contains("website:view"))return Set.of();
        return resolved.stream().filter(WEBSITE_PERMISSIONS::contains).collect(Collectors.toUnmodifiableSet());
    }
}
