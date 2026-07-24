package com.uten.imp.features.profilechange;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;

/** profilechange 三个 Service 共用的访问守卫。 */
@Component
class ProfileChangeAccess {

    private final SecurityContextCurrentUser currentUser;

    ProfileChangeAccess(SecurityContextCurrentUser currentUser) {
        this.currentUser = currentUser;
    }

    AuthUser requireStaff() {
        AuthUser u = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (u.isVisitor()) throw new ApiException(ErrorCode.FORBIDDEN, "仅员工可访问");
        return u;
    }

    AuthUser requireHr() {
        AuthUser u = requireStaff();
        if (!u.getPermissions().contains("profile:review") && !u.isSuperAdmin()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "无 profile:review 权限");
        }
        return u;
    }

    boolean hasReviewPerm() {
        return currentUser.get()
                .map(u -> u.isSuperAdmin() || u.getPermissions().contains("profile:review"))
                .orElse(false);
    }
}
