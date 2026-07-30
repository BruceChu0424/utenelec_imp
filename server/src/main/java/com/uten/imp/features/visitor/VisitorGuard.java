package com.uten.imp.features.visitor;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;

import java.util.UUID;

/** visitor staff 侧各 Service 共用的员工主体守卫。 */
@Component
class VisitorGuard {

    private final SecurityContextCurrentUser currentUser;

    VisitorGuard(SecurityContextCurrentUser currentUser) {
        this.currentUser = currentUser;
    }

    UUID requireStaff() {
        return requireStaffUser().getId();
    }

    AuthUser requireStaffUser() {
        var user = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (user.isVisitor()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "仅员工可访问");
        }
        return user;
    }
}
