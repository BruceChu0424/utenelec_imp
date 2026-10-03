package com.uten.imp.features.ai.usage;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;

@Component
public class AiUsageAdminAccess {
    private final SecurityContextCurrentUser current;
    public AiUsageAdminAccess(SecurityContextCurrentUser current) { this.current = current; }
    public AuthUser require() {
        return current.get().filter(actor -> !actor.isVisitor() && actor.isSuperAdmin()
                && actor.getPermissions().contains("authorization:manage") && actor.getImpersonatedBy() == null
                && !actor.isMustChangePassword() && actor.isAccountNonLocked())
                .orElseThrow(() -> new ApiException(ErrorCode.FORBIDDEN, "这项暂时不能查看或修改"));
    }
}
