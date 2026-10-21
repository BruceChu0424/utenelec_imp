package com.uten.imp.features.auth;

import com.uten.imp.application.port.TaskAudiencePort;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.BusinessTaskContext;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContext;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;

import java.util.HashSet;
import java.util.Set;

/**
 * A bounded read scope; the request's original security context is always restored.
 * Normal commands retain the administrator's full capability. Business tasks instead
 * reuse the ordinary permission and owner/warehouse/workshop policies with actual grants.
 * Display aggregates (workbench badges) browse under the session principal instead
 * ({@link #browsingRead}); the task rewriting stays suspended for the whole aggregation.
 */
@Service
public class BusinessTaskAudienceService implements TaskAudiencePort {
    private final PermissionResolver permissions;
    private final ThreadLocal<Boolean> reading = new ThreadLocal<>();
    private final ThreadLocal<Boolean> browsing = new ThreadLocal<>();

    public BusinessTaskAudienceService(PermissionResolver permissions) {
        this.permissions = permissions;
    }

    @Override
    public <T> T read(ReadQuery<T> work) {
        if (Boolean.TRUE.equals(browsing.get()) || Boolean.TRUE.equals(reading.get())) return work.read();
        SecurityContext original = SecurityContextHolder.getContext();
        Authentication authentication = original.getAuthentication();
        if (authentication == null || !authentication.isAuthenticated()
                || !(authentication.getPrincipal() instanceof AuthUser actor) || actor.isVisitor()) {
            return work.read();
        }
        Set<String> granted = new HashSet<>(permissions.grantedPermsOf(actor.getId()));
        // A task read cannot resurrect authority absent from this authenticated session.
        granted.retainAll(actor.getPermissions());
        if (!actor.isAccountNonLocked() || actor.isMustChangePassword()) granted.clear();
        AuthUser taskActor = new AuthUser(actor.getId(), actor.getEmployeeId(), actor.getLoginAccount(),
                Set.copyOf(granted), actor.isMustChangePassword(), actor.isAccountNonLocked(), false,
                actor.isRemoteAccess(), actor.getImpersonatedBy(), actor.getSessionId(),
                actor.getMfaVerifiedAt(), actor.isRemotePolicyEnabled());
        var taskAuthentication = UsernamePasswordAuthenticationToken.authenticated(
                taskActor, null, taskActor.getAuthorities());
        taskAuthentication.setDetails(authentication.getDetails());
        SecurityContext context = SecurityContextHolder.createEmptyContext();
        context.setAuthentication(taskAuthentication);
        reading.set(true);
        SecurityContextHolder.setContext(context);
        try (var ignored = BusinessTaskContext.open()) {
            return work.read();
        } finally {
            SecurityContextHolder.setContext(original);
            reading.remove();
        }
    }

    @Override
    public <T> T browsingRead(ReadQuery<T> work) {
        if (Boolean.TRUE.equals(browsing.get())) return work.read();
        browsing.set(true);
        try {
            return work.read();
        } finally {
            browsing.remove();
        }
    }
}
