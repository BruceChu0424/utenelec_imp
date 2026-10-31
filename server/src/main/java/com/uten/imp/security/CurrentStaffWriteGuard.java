package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.AuthSessionService;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.StaffAuthenticationPolicy;
import com.uten.imp.features.auth.StepUpService;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.util.Arrays;
import java.util.Objects;

/** Rechecks the admitted HTTP identity after a sensitive writer obtains its business locks. */
@Component
@RequiredArgsConstructor
public class CurrentStaffWriteGuard {
    private final SecurityContextCurrentUser currentUser;
    private final AuthSessionService sessions;
    private final PermissionResolver permissions;
    private final ObjectProvider<StepUpService> stepUp;

    @Transactional(propagation=Propagation.MANDATORY)
    public void requireFresh(String... required) {
        verify(required);
    }

    @Transactional(propagation=Propagation.MANDATORY)
    public void requireFreshStepUp(String... required) {
        AuthUser actor=verify(required);
        // The existing conditional UPDATE revalidates token/session/expiry and
        // holds the session row until this write commits, serializing logout.
        stepUp.getObject().consumeFromCurrentRequest(actor);
    }

    private AuthUser verify(String... required) {
        if(required.length==0) throw new IllegalArgumentException("A write authority is required");
        AuthUser actor=currentUser.get().orElseThrow(CurrentStaffWriteGuard::changed);
        var admitted=VerifiedStaffRequest.current();
        if(actor.isVisitor() || actor.isMustChangePassword() || actor.getImpersonatedBy()!=null
                || admitted==null || !Objects.equals(admitted.userId(),actor.getId())
                || !Objects.equals(admitted.employeeId(),actor.getEmployeeId())
                || !Objects.equals(admitted.sessionId(),actor.getSessionId())) throw changed();
        var state=sessions.loadStaff(actor.getId(),actor.getSessionId(),actor.getId())
                .orElseThrow(CurrentStaffWriteGuard::changed);
        if(state.deleted() || !"active".equals(state.status()) || state.mustChangePassword()
                || !StaffAuthenticationPolicy.currentEmployee(state.employeeId(),state.employeeDeleted(),state.employeeStatus())
                || !Objects.equals(state.employeeId(),actor.getEmployeeId()) || state.superAdmin()!=actor.isSuperAdmin()
                || state.authVersion()!=admitted.authVersion() || state.authorizationEpoch()!=admitted.authorizationEpoch()
                || AuthSessionService.evaluate(state.session(),AuthSessionService.idleTimeoutMinutes(state.idleTimeoutRaw()),sessions.now())
                    !=AuthSessionService.Verdict.ACTIVE) throw changed();
        // Operating authority includes the super-admin mirror minus personal
        // revokes; task-recipient "granted" authority is deliberately different.
        if(!permissions.authorizationSnapshot(actor.getId(),state.employeeId(),state.superAdmin()).permissions()
                .containsAll(Arrays.asList(required))) throw changed();
        return actor;
    }

    private static ApiException changed() {
        return new ApiException(ErrorCode.FORBIDDEN,"登录会话、身份或操作权限已变化，请重新登录后再操作");
    }
}
